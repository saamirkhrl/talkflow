#!/bin/bash
# Builds talkflow.app and publishes it as a GitHub release in two forms:
#   talkflow-macos.dmg  what the website's download button gives people: open
#                       it and drag talkflow onto Applications. Its window
#                       (background, arrow, icon positions) is laid out by
#                       Finder, so build it in a logged-in desktop session.
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
# The window people see when they open it: the app, a shortcut to Applications
# and an arrow between them, on a background drawn by scripts/dmg-background.swift.
# Finder keeps a folder's look in a .DS_Store file and only Finder writes that
# reliably, so the layout is set by asking Finder (osascript) on a read-write
# copy of the image, which is then converted to the compressed, read-only DMG.
# That needs a logged-in desktop session; without one the script stops here
# rather than ship a plain DMG.
#
# Layout, in points. The window's content area is DMG_W x DMG_H; icon positions
# are the icon centers measured from its top-left. The background arrow is
# drawn from the same numbers, so the two always line up.
DMG_W=660
DMG_H=400
DMG_APP_X=180
DMG_APPLICATIONS_X=480
DMG_ICON_Y=210
DMG_ICON_SIZE=128
DMG_WINDOW_X=200     # where the window opens on screen
DMG_WINDOW_Y=120
DMG_TITLEBAR=28      # Finder's window bounds include the title bar

DMG_TMP=""
DMG_DEV=""
detach_dmg() {
    local i
    if [ -n "$DMG_DEV" ]; then
        for i in 1 2 3 4 5; do
            hdiutil detach "$DMG_DEV" -quiet 2>/dev/null && { DMG_DEV=""; break; }
            sleep 2
        done
        if [ -n "$DMG_DEV" ]; then
            hdiutil detach "$DMG_DEV" -force -quiet 2>/dev/null \
                || echo "warning: could not detach $DMG_DEV; run: hdiutil detach $DMG_DEV -force" >&2
            DMG_DEV=""
        fi
    fi
}
cleanup_dmg() {
    detach_dmg
    if [ -n "$DMG_TMP" ]; then rm -rf "$DMG_TMP"; DMG_TMP=""; fi
}
# Runs on success, on a failed command (set -e) and on Ctrl-C, so a half-made
# image is never left mounted.
trap cleanup_dmg EXIT

DMG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/talkflow-dmg.XXXXXX")"
# A name no other mounted volume can have (a stale "talkflow" from an earlier
# run or a downloaded copy would otherwise make Finder mount this one as
# "talkflow 1"). It is renamed to "talkflow" before the image is closed.
DMG_VOL="talkflow-layout-$$-$RANDOM"

echo "    background"
mkdir -p "$DMG_TMP/bg" "$DMG_TMP/stage/.background"
swift scripts/dmg-background.swift "$DMG_TMP/bg" "$DMG_W" "$DMG_H" \
    "$DMG_APP_X" "$DMG_ICON_Y" "$DMG_APPLICATIONS_X" "$DMG_ICON_Y"
# One TIFF holding the 1x and the 2x drawing: Finder picks the sharp one on Retina.
tiffutil -cathidpicheck "$DMG_TMP/bg/background.png" "$DMG_TMP/bg/background@2x.png" \
    -out "$DMG_TMP/stage/.background/background.tiff"
chflags hidden "$DMG_TMP/stage/.background"
ditto "$APP" "$DMG_TMP/stage/talkflow.app"
ln -s /Applications "$DMG_TMP/stage/Applications"

echo "    read-write image"
DMG_RW="$DMG_TMP/talkflow-rw.dmg"
DMG_USED_MB="$(du -sm "$DMG_TMP/stage" | cut -f1)"
hdiutil create -quiet -volname "$DMG_VOL" -srcfolder "$DMG_TMP/stage" -fs HFS+ \
    -format UDRW -size "$((DMG_USED_MB + 16))m" -ov "$DMG_RW"
# Left browsable (no -nobrowse): Finder has to see the volume to lay it out.
ATTACH_OUT="$(hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen)"
DMG_DEV="$(printf '%s\n' "$ATTACH_OUT" | awk '/^\/dev\/disk[0-9]+[[:space:]]/ { print $1; exit }')"
DMG_MNT="/Volumes/$DMG_VOL"
[ -n "$DMG_DEV" ] && [ -d "$DMG_MNT" ] \
    || { echo "error: could not mount the read-write image at $DMG_MNT" >&2; exit 1; }

echo "    window layout (Finder)"
DMG_BOUNDS="$DMG_WINDOW_X, $DMG_WINDOW_Y, $((DMG_WINDOW_X + DMG_W)), $((DMG_WINDOW_Y + DMG_H + DMG_TITLEBAR))"
if ! osascript <<APPLESCRIPT
with timeout of 120 seconds
    tell application "Finder"
        tell disk "$DMG_VOL"
            open
            tell container window
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                try
                    set sidebar width to 0
                end try
                set bounds to {$DMG_BOUNDS}
            end tell
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to $DMG_ICON_SIZE
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item "talkflow.app" of container window to {$DMG_APP_X, $DMG_ICON_Y}
            set position of item "Applications" of container window to {$DMG_APPLICATIONS_X, $DMG_ICON_Y}
            update without registering applications
            delay 2
            close
        end tell
    end tell
end timeout
APPLESCRIPT
then
    echo "error: Finder did not lay out the installer window. This step needs a logged-in" >&2
    echo "       desktop session, and Automation access for this terminal to control Finder" >&2
    echo "       (System Settings > Privacy & Security > Automation). Not shipping a plain DMG." >&2
    exit 1
fi
# Finder writes .DS_Store a moment after it is told to.
for _ in $(seq 1 20); do [ -s "$DMG_MNT/.DS_Store" ] && break; sleep 1; done
[ -s "$DMG_MNT/.DS_Store" ] || { echo "error: Finder never wrote the window layout (.DS_Store); not shipping a plain DMG" >&2; exit 1; }
sleep 2
# Give the volume its real name, so the one people mount is "talkflow".
diskutil rename "$DMG_MNT" talkflow >/dev/null
sync
detach_dmg

echo "    compressing"
hdiutil convert "$DMG_RW" -quiet -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"
cleanup_dmg
trap - EXIT
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
