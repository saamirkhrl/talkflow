#!/bin/bash
# Installs the latest talkflow release on a Mac:
#
#   curl -fsSL https://<this site>/install.sh | bash
#
# Downloads the release zip from GitHub, puts talkflow.app in /Applications
# (or ~/Applications when /Applications is not writable) and opens it. The
# setup window then asks for the permissions it needs and installs the speech
# engine. To build from source instead, see the README.
set -euo pipefail

REPO="saamirkhrl/talkflow"
URL="https://github.com/$REPO/releases/latest/download/talkflow-macos.zip"

say() { printf '==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "talkflow runs on macOS only. A Windows version is coming."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "talkflow needs macOS 13 or newer (this Mac has $(sw_vers -productVersion))."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say "Downloading the latest talkflow"
curl -fL --progress-bar -o "$work/talkflow.zip" "$URL" || fail "could not download $URL"
ditto -x -k "$work/talkflow.zip" "$work" || fail "the download is not a valid zip"
app="$work/talkflow.app"
[ -d "$app" ] || fail "the download does not contain talkflow.app"

# A build for the other kind of Mac would install and then not open.
arch=$(uname -m)
archs=$(lipo -archs "$app/Contents/MacOS/talkflowd" 2>/dev/null || echo "")
case " $archs " in
    *" $arch "*) ;;
    *) fail "this release does not run on $arch Macs yet. See https://github.com/$REPO/releases" ;;
esac

dest="/Applications"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

if pgrep -fiq "talkflow.app/Contents/MacOS/talkflowd"; then
    say "Quitting the running talkflow"
    pkill -fi "talkflow.app/Contents/MacOS/talkflowd" || true
    sleep 1
fi

say "Installing to $dest/talkflow.app"
rm -rf "$dest/talkflow.app"
ditto "$app" "$dest/talkflow.app"
# Downloads from a browser are quarantined; this one was not, but an older
# copy might have been. talkflow is not notarized, so clear it either way.
xattr -dr com.apple.quarantine "$dest/talkflow.app" 2>/dev/null || true

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$dest/talkflow.app/Contents/Info.plist" 2>/dev/null || echo "?")
say "Opening talkflow $version"
open "$dest/talkflow.app"
echo "Hold fn and speak. If the setup window does not appear, open talkflow from $dest."
