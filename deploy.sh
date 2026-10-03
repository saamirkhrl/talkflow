#!/bin/bash
# Builds talkflowd, installs it into /Applications/talkflow.app, re-signs with the
# stable local dev identity (keeps Accessibility/Input Monitoring/Mic grants across
# rebuilds; the identity is a self-signed code-signing cert of that name in the
# login keychain, check it with: security find-certificate -c "talkflow Local Dev"
# and recreate it via Keychain Access > Certificate Assistant), and restarts
# the LaunchAgent.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Applications/talkflow.app"
UID_NUM=$(id -u)

echo "==> Building"
cd "$PROJECT_DIR"
swift build -c release

echo "==> Stopping running instance"
launchctl bootout "gui/$UID_NUM/com.samir.talkflow" 2>/dev/null || true
# -i: the bundle on disk is "TalkFlow.app", and a case-sensitive match missed
# every copy not started by the LaunchAgent (one opened from Finder kept
# running the previous build next to the new one).
pkill -if "talkflow.app/Contents/MacOS/talkflowd" 2>/dev/null || true
sleep 1

echo "==> Installing bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT_DIR/.build/release/talkflowd" "$APP/Contents/MacOS/talkflowd"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
codesign --force --deep --sign "talkflow Local Dev" "$APP"

echo "==> Restarting"
: > ~/Library/Logs/talkflow/talkflow.log
launchctl bootstrap "gui/$UID_NUM" ~/Library/LaunchAgents/com.samir.talkflow.plist

sleep 1
echo "==> Status"
ps aux | grep talkflowd | grep -v grep
echo "==> Log"
cat ~/Library/Logs/talkflow/talkflow.log
