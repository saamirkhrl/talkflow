#!/bin/bash
# Builds talkflow-diarize, the helper that tells the speakers in a recording
# apart (Helpers/talkflow-diarize, a Swift package over FluidAudio).
#
#   scripts/build-diarize-macos.sh [out-dir]       default: .build/diarize-helper
#   scripts/build-diarize-macos.sh --check <file>  only check an existing binary
#
# Writes <out-dir>/talkflow-diarize and <out-dir>/talkflow-diarize-NOTICES.txt.
# release.sh, deploy.sh and the macos-engine workflow call it.
#
# Apple Silicon only: the speaker models run on the Neural Engine and the
# helper reports "unsupported" (exit 6) elsewhere. So this builds arm64 only,
# and SKIPS (message, exit 0, nothing written) when the host is not arm64 or
# its Swift is older than 6.2 (the package needs 6.2 to leave the unused TTS
# code out). The app then ships without the helper and labels the other
# voices "Everyone else". Callers must treat a missing binary as normal.
#
# Needs: the Swift toolchain (Xcode or the Command Line Tools) and network on
# the first build, to fetch FluidAudio at the version pinned in Package.resolved.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$PROJECT_DIR/Helpers/talkflow-diarize"

fail() { echo "error: $*" >&2; exit 1; }

# Fails unless $1 is an arm64 Mach-O executable whose `check` command runs.
# `check` exits 0 (supported) or 6 (this Mac is unsupported); both mean the
# binary itself works. Anything else is a broken build.
check_binary() {
    local bin="$1"
    [ -x "$bin" ] || fail "$bin is missing or not executable"
    local archs
    archs="$(lipo -archs "$bin" 2>/dev/null)" || fail "$bin is not a Mach-O file"
    [ "$archs" = "arm64" ] || fail "$bin should be arm64 only (has: $archs)"
    file "$bin" | grep -q "Mach-O 64-bit executable arm64" || fail "$bin is not an arm64 executable"
    local rc=0
    "$bin" check >/dev/null 2>&1 || rc=$?
    { [ "$rc" -eq 0 ] || [ "$rc" -eq 6 ]; } || fail "'$bin check' exited $rc (expected 0 or 6)"
    echo "    ok: $bin (arm64), check exit $rc"
}

if [ "${1:-}" = "--check" ]; then
    [ -n "${2:-}" ] || fail "usage: $0 --check <talkflow-diarize>"
    check_binary "$2"
    exit 0
fi

OUT="${1:-$PROJECT_DIR/.build/diarize-helper}"

if [ "$(uname)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "==> Speaker helper skipped: it is built on an Apple Silicon Mac only (this is $(uname)/$(uname -m))"
    exit 0
fi
command -v swift >/dev/null 2>&1 || { echo "==> Speaker helper skipped: swift was not found"; exit 0; }
SWIFT_VER="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
SWIFT_MAJOR="${SWIFT_VER%%.*}"
SWIFT_MINOR="${SWIFT_VER#*.}"
if [ -z "$SWIFT_VER" ] || [ "$SWIFT_MAJOR" -lt 6 ] || { [ "$SWIFT_MAJOR" -eq 6 ] && [ "$SWIFT_MINOR" -lt 2 ]; }; then
    echo "==> Speaker helper skipped: Swift ${SWIFT_VER:-unknown} is older than 6.2"
    exit 0
fi

echo "==> Building talkflow-diarize (Swift $SWIFT_VER, arm64)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
# Incremental: SwiftPM rebuilds only what changed, so a second run is quick.
swift build -c release --arch arm64 --package-path "$PKG" >&2
BIN="$(swift build -c release --arch arm64 --package-path "$PKG" --show-bin-path)/talkflow-diarize"
[ -x "$BIN" ] || fail "no talkflow-diarize at $BIN"

# Written beside the destination and renamed over it: deploy.sh may call this
# while an earlier copy is being used.
cp "$BIN" "$OUT/talkflow-diarize.new"
# Stripping voids the linker's signature and Apple Silicon refuses unsigned
# code, so sign ad hoc; the app signature (release.sh, deploy.sh) signs it again.
strip -S "$OUT/talkflow-diarize.new"
codesign --force --sign - "$OUT/talkflow-diarize.new" 2>/dev/null
chmod 755 "$OUT/talkflow-diarize.new"
mv -f "$OUT/talkflow-diarize.new" "$OUT/talkflow-diarize"
cp "$PKG/THIRD-PARTY-NOTICES.txt" "$OUT/talkflow-diarize-NOTICES.txt"
check_binary "$OUT/talkflow-diarize"
echo "    $(du -h "$OUT/talkflow-diarize" | cut -f1)  $OUT/talkflow-diarize"
