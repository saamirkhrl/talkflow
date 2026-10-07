#!/bin/bash
# Builds talkflow from source and installs it as a macOS app, then opens it.
# The first launch walks you through the permissions and the speech engine.
#
#   ./install.sh
#
# Needs macOS 13+ and the Swift toolchain (xcode-select --install), plus git
# and cmake to build the speech engine (whisper.cpp's whisper-server, from a
# pinned tag, by scripts/build-whisper-macos.sh) into the app. cmake comes from
# https://cmake.org/download/, `brew install cmake` or `pip3 install cmake`;
# only the build needs it. Without cmake, a whisper-server already installed
# with Homebrew is used instead, if there is one.
#
# For development and testing, these override where and as what it installs, so
# a test copy can sit next to a working install without sharing its permissions
# or its login item:
#   TALKFLOW_APP_DIR     folder to install into   (default /Applications)
#   TALKFLOW_APP_NAME    app name                 (default talkflow)
#   TALKFLOW_BUNDLE_ID   bundle identifier        (default from Packaging/Info.plist)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="${TALKFLOW_APP_NAME:-talkflow}"
APP_DIR="${TALKFLOW_APP_DIR:-/Applications}"
BUNDLE_ID="${TALKFLOW_BUNDLE_ID:-}"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "talkflow is a macOS app."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 13 ] || fail "talkflow needs macOS 13 or newer (this is $(sw_vers -productVersion))."
command -v swift >/dev/null 2>&1 || fail "Swift was not found. Install the Command Line Tools with:  xcode-select --install"

# /Applications is writable for admin users; fall back to ~/Applications if not.
if [ -z "${TALKFLOW_APP_DIR:-}" ] && [ ! -w "$APP_DIR" ]; then
    APP_DIR="$HOME/Applications"
fi
mkdir -p "$APP_DIR"
APP="$APP_DIR/$APP_NAME.app"

echo "==> Building (the first build takes a minute or two)"
cd "$PROJECT_DIR"
swift build -c release

# The speech engine. Built into the app when cmake is here; otherwise only a
# Homebrew whisper-server that is already installed can stand in for it.
ENGINE="$PROJECT_DIR/.build/whisper-engine"
HOMEBREW_ENGINE=""
for candidate in /opt/homebrew/bin/whisper-server /usr/local/bin/whisper-server; do
    [ -x "$candidate" ] && { HOMEBREW_ENGINE="$candidate"; break; }
done
NO_ENGINE_HELP="Install cmake (https://cmake.org/download/, or: brew install cmake, or: pip3 install cmake) and run ./install.sh again, or download the ready-made app from https://talkflow.live"
if command -v cmake >/dev/null 2>&1; then
    if ! "$PROJECT_DIR/scripts/build-whisper-macos.sh" "$ENGINE"; then
        [ -n "$HOMEBREW_ENGINE" ] || fail "the speech engine did not build (see above). $NO_ENGINE_HELP"
        echo "warning: the speech engine did not build; talkflow will use Homebrew's $HOMEBREW_ENGINE" >&2
    fi
elif [ -n "$HOMEBREW_ENGINE" ]; then
    echo "warning: cmake not found, so the speech engine is not built into the app; talkflow will use Homebrew's $HOMEBREW_ENGINE" >&2
else
    fail "cmake is needed to build the speech engine. $NO_ENGINE_HELP"
fi

echo "==> Installing to $APP"
pkill -f "$APP/Contents/MacOS/talkflowd" 2>/dev/null || true
sleep 1
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT_DIR/.build/release/talkflowd" "$APP/Contents/MacOS/talkflowd"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ -x "$ENGINE/whisper-server" ]; then
    mkdir -p "$APP/Contents/Helpers"
    # Renamed into place rather than written over: an earlier install's
    # engine may be running from this path.
    cp "$ENGINE/whisper-server" "$APP/Contents/Helpers/whisper-server.new"
    mv -f "$APP/Contents/Helpers/whisper-server.new" "$APP/Contents/Helpers/whisper-server"
    cp "$ENGINE/whisper.cpp-LICENSE.txt" "$APP/Contents/Resources/whisper.cpp-LICENSE.txt"
fi

PLIST="$APP/Contents/Info.plist"
if [ -n "$BUNDLE_ID" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
    # A copy under a different identity must not register itself to open at login.
    /usr/libexec/PlistBuddy -c "Add :TalkflowDisableLoginItem bool true" "$PLIST"
fi
if [ "$APP_NAME" != "talkflow" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PLIST"
fi

# macOS ties each permission to the app's code signature. A stable identity keeps
# the grants across rebuilds; with none, an ad-hoc signature works but the
# permissions have to be granted again after each rebuild.
if security find-certificate -c "talkflow Local Dev" >/dev/null 2>&1; then
    echo "==> Signing with the 'talkflow Local Dev' identity"
    codesign --force --deep --sign "talkflow Local Dev" "$APP"
else
    echo "==> Signing ad hoc"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Opening talkflow"
open "$APP"

cat <<MSG

talkflow is installed at $APP and setup is open.
Follow the window: it asks for three permissions and sets up the speech engine.
Afterwards, look for the bars icon in your menu bar. Hold Fn and speak.
MSG
