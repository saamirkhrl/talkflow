#!/bin/bash
# Builds talkflow.app and publishes it as a GitHub release in two forms:
#   talkflow-macos.dmg  what the website's download button gives people: open
#                       it and drag talkflow onto Applications.
#   talkflow-macos.zip  what the in-app updater (Sources/talkflowd/Updater.swift)
#                       and the website's install.sh unpack.
# and then attaches talkflow-release.json, the manifest every app checks for
# updates (scripts/release-manifest.py, docs/releases.md).
#
#   ./release.sh 0.2.0            build, tag v0.2.0, publish the release
#   ./release.sh 0.2.0 --dry-run  build and zip only, publish nothing
#
# Sets CFBundleShortVersionString in Packaging/Info.plist to the version given
# and bumps CFBundleVersion; commit that change along with the release. The zip
# is signed ad hoc - the updater re-signs it on each Mac with the local
# "talkflow Local Dev" identity when that Mac has one, so permissions survive.
#
# The app carries its own speech engine, whisper.cpp's whisper-server, at
# talkflow.app/Contents/Helpers/whisper-server, built from a pinned tag by
# scripts/build-whisper-macos.sh. Users need no Homebrew.
#
# Prerequisites on the release machine: the Swift toolchain and Command Line
# Tools (xcode-select --install), git, cmake 3.23+ (https://cmake.org/download/,
# or brew install cmake) for the engine, and to publish, gh (signed in) and
# python3.
set -euo pipefail

VERSION="${1:-}"
DRY_RUN="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <major.minor.patch> [--dry-run]" >&2; exit 2; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$PROJECT_DIR/Packaging/Info.plist"
OUT="$PROJECT_DIR/.build/release-artifacts"
APP="$OUT/talkflow.app"
# Always these names: the website links to
# github.com/<repo>/releases/latest/download/<name>, which GitHub serves from
# whichever release is newest.
ZIP="$OUT/talkflow-macos.zip"
DMG="$OUT/talkflow-macos.dmg"
# One binary for Apple Silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)

if [ "$DRY_RUN" != "--dry-run" ]; then
    command -v gh >/dev/null || { echo "error: the GitHub CLI (gh) is needed to publish" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "error: python3 is needed to write the release manifest" >&2; exit 1; }
    gh release view "v$VERSION" >/dev/null 2>&1 && { echo "error: release v$VERSION already exists" >&2; exit 1; }
fi

# First, so a missing cmake stops the release before anything is changed.
ENGINE="$PROJECT_DIR/.build/whisper-engine"
"$PROJECT_DIR/scripts/build-whisper-macos.sh" "$ENGINE"

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/talkflowd"
cp "$PLIST" "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$ENGINE/whisper-server" "$APP/Contents/Helpers/whisper-server"
cp "$ENGINE/whisper.cpp-LICENSE.txt" "$APP/Contents/Resources/whisper.cpp-LICENSE.txt"
# Inside out: the engine first, then the app, whose signature seals it. The
# updater's `codesign --force --deep` on each Mac re-signs both the same way.
codesign --force --sign - --identifier com.samir.talkflow.whisper-server "$APP/Contents/Helpers/whisper-server"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" || { echo "error: $APP does not verify" >&2; exit 1; }
"$APP/Contents/Helpers/whisper-server" --help >/dev/null 2>&1 || { echo "error: the bundled whisper-server does not run" >&2; exit 1; }
"$PROJECT_DIR/scripts/build-whisper-macos.sh" --check "$APP/Contents/Helpers/whisper-server"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
echo "    $(du -h "$ZIP" | cut -f1)  $ZIP"

echo "==> Making $DMG"
# The window people see when they open it: the app, and a shortcut to
# Applications to drag it onto.
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/talkflow.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "talkflow" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
hdiutil verify -quiet "$DMG"
echo "    $(du -h "$DMG" | cut -f1)  $DMG"

if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "==> Dry run: nothing published. Revert Packaging/Info.plist if this was only a test."
    exit 0
fi

echo "==> Publishing v$VERSION"
gh release create "v$VERSION" "$DMG" "$ZIP" --title "talkflow $VERSION" --generate-notes --target "$(git rev-parse HEAD)"

echo "==> Attaching talkflow-release.json"
# The release is already public, so a failure here does not undo it: the
# Release manifest workflow also writes the manifest, or rerun the command.
MANIFEST_CMD=(python3 "$PROJECT_DIR/scripts/release-manifest.py" "v$VERSION" --upload --out "$OUT/talkflow-release.json")
"${MANIFEST_CMD[@]}" || echo "warning: the manifest was not uploaded; rerun: ${MANIFEST_CMD[*]}" >&2
echo "==> Done. Commit Packaging/Info.plist (version $VERSION, build $BUILD)."
