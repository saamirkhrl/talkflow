#!/bin/bash
# Builds talkflow.app, zips it, and publishes it as a GitHub release that the
# in-app updater (Sources/talkflowd/Updater.swift) picks up.
#
#   ./release.sh 0.2.0            build, tag v0.2.0, publish the release
#   ./release.sh 0.2.0 --dry-run  build and zip only, publish nothing
#
# Sets CFBundleShortVersionString in Packaging/Info.plist to the version given
# and bumps CFBundleVersion; commit that change along with the release. The zip
# is signed ad hoc - the updater re-signs it on each Mac with the local
# "talkflow Local Dev" identity when that Mac has one, so permissions survive.
set -euo pipefail

VERSION="${1:-}"
DRY_RUN="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <major.minor.patch> [--dry-run]" >&2; exit 2; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$PROJECT_DIR/Packaging/Info.plist"
OUT="$PROJECT_DIR/.build/release-artifacts"
APP="$OUT/talkflow.app"
# Always this name: the website links to
# github.com/<repo>/releases/latest/download/talkflow-macos.zip, which GitHub
# serves from whichever release is newest.
ZIP="$OUT/talkflow-macos.zip"
# One binary for Apple Silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)

if [ "$DRY_RUN" != "--dry-run" ]; then
    command -v gh >/dev/null || { echo "error: the GitHub CLI (gh) is needed to publish" >&2; exit 1; }
    gh release view "v$VERSION" >/dev/null 2>&1 && { echo "error: release v$VERSION already exists" >&2; exit 1; }
fi

echo "==> Version $VERSION"
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
# sed rather than PlistBuddy, which rewrites the whole file's indentation.
sed -i '' -E "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>[^<]*</string>|<string>$VERSION</string>|;}" "$PLIST"
sed -i '' -E "/<key>CFBundleVersion<\/key>/{n;s|<string>[^<]*</string>|<string>$BUILD</string>|;}" "$PLIST"

echo "==> Building (universal)"
cd "$PROJECT_DIR"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/talkflowd"
for arch in arm64 x86_64; do
    lipo "$BIN" -verify_arch "$arch" || { echo "error: $BIN has no $arch slice" >&2; exit 1; }
done

echo "==> Assembling $APP"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/talkflowd"
cp "$PLIST" "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
echo "    $(du -h "$ZIP" | cut -f1)  $ZIP"

if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "==> Dry run: nothing published. Revert Packaging/Info.plist if this was only a test."
    exit 0
fi

echo "==> Publishing v$VERSION"
gh release create "v$VERSION" "$ZIP" --title "talkflow $VERSION" --generate-notes --target "$(git rev-parse HEAD)"
echo "==> Done. Commit Packaging/Info.plist (version $VERSION, build $BUILD)."
