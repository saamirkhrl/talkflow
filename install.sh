#!/bin/bash
# Builds talkflow from source and installs it as a macOS app, then opens it.
# The first launch walks you through the permissions and the speech engine.
#
#   ./install.sh
#
# Needs macOS 13+ and the Swift toolchain (xcode-select --install).
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

echo "==> Installing to $APP"
pkill -f "$APP/Contents/MacOS/talkflowd" 2>/dev/null || true
sleep 1
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT_DIR/.build/release/talkflowd" "$APP/Contents/MacOS/talkflowd"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
