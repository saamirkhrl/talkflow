#!/bin/bash
# Builds the speech engine that ships inside talkflow.app: whisper.cpp's
# whisper-server from the pinned tag below, as one universal (arm64 + x86_64)
# executable with everything linked in statically.
#
#   scripts/build-whisper-macos.sh [out-dir]     default: .build/whisper-engine
#   scripts/build-whisper-macos.sh --check <file> only check an existing binary
#
# Writes <out-dir>/whisper-server and <out-dir>/whisper.cpp-LICENSE.txt.
# release.sh, deploy.sh and install.sh call it; .github/workflows/macos-engine.yml
# builds and smoke-tests it on every change.
#
# - arm64 uses Metal (the GPU) with the shader source embedded in the binary
#   (GGML_METAL_EMBED_LIBRARY), so there is no separate .metallib to ship.
# - x86_64 runs on the CPU with Accelerate, using AVX2/FMA/F16C, which every
#   Intel Mac that runs macOS 13 has. Metal is off there.
# - BUILD_SHARED_LIBS=OFF: libwhisper and ggml are linked into the executable,
#   so it loads nothing but macOS's own libraries and frameworks.
# - GGML_NATIVE=OFF: built for the architecture, not for this Mac's CPU, so it
#   runs on every Apple Silicon and Intel Mac.
# - OpenMP off and Homebrew prefixes ignored, so nothing from the build
#   machine's Homebrew can end up as a runtime dependency.
#
# Needs: git, cmake (3.23 or newer) and the Command Line Tools
# (xcode-select --install). Only the build machine needs cmake; the app never
# needs Homebrew or anything else to run the engine.
#
# The result is cached: a second run with the same tag and the same copy of
# this script reuses it. Delete <out-dir> to force a rebuild.
set -euo pipefail

WHISPER_CPP_TAG="v1.9.4"
# The commit that tag pointed to when it was pinned. A moved tag fails the build.
WHISPER_CPP_COMMIT="927cfce34f31707e17f2bff35c349632fb9e2c3a"
MACOS_MIN="13.0"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/build-whisper-macos.sh"

fail() { echo "error: $*" >&2; exit 1; }

# Fails unless $1 is a universal arm64 + x86_64 Mach-O that loads only
# macOS's own libraries (/usr/lib, /System) or paths relative to itself.
check_binary() {
    local bin="$1"
    [ -x "$bin" ] || fail "$bin is missing or not executable"
    local archs
    archs="$(lipo -archs "$bin")"
    for arch in arm64 x86_64; do
        [[ " $archs " == *" $arch "* ]] || fail "$bin has no $arch slice (has: $archs)"
    done
    for arch in arm64 x86_64; do
        # The first line of otool -L is the file name itself.
        local bad
        bad="$(otool -arch "$arch" -L "$bin" | tail -n +2 | awk '{print $1}' \
            | grep -Ev '^(/usr/lib/|/System/|@rpath/|@loader_path/|@executable_path/)' || true)"
        [ -z "$bad" ] || fail "$bin ($arch) loads libraries from outside macOS: $bad"
        local rpaths
        rpaths="$(otool -arch "$arch" -l "$bin" | grep -A2 LC_RPATH | awk '/ path /{print $2}' \
            | grep -Ev '^(@loader_path|@executable_path)(/|$)' || true)"
        [ -z "$rpaths" ] || fail "$bin ($arch) has an absolute LC_RPATH: $rpaths"
    done
    echo "    ok: $bin ($archs), only system libraries"
}

if [ "${1:-}" = "--check" ]; then
    [ -n "${2:-}" ] || fail "usage: $0 --check <whisper-server>"
    check_binary "$2"
    exit 0
fi

OUT="${1:-$PROJECT_DIR/.build/whisper-engine}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$PROJECT_DIR/.build/whisper.cpp-build"
SRC="$WORK/whisper.cpp-$WHISPER_CPP_TAG"
STAMP="$OUT/BUILD-STAMP"
WANT_STAMP="whisper.cpp $WHISPER_CPP_TAG $WHISPER_CPP_COMMIT script $(shasum -a 256 "$SCRIPT" | cut -c1-16)"

if [ -x "$OUT/whisper-server" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ]; then
    echo "==> Speech engine already built ($WHISPER_CPP_TAG): $OUT/whisper-server"
    check_binary "$OUT/whisper-server"
    exit 0
fi

[ "$(uname)" = "Darwin" ] || fail "this builds the macOS engine; run it on a Mac"
command -v git >/dev/null 2>&1 || fail "git was not found (xcode-select --install)"
command -v cmake >/dev/null 2>&1 || fail "cmake was not found. Install it from https://cmake.org/download/ (or: brew install cmake, or: pip3 install cmake). Only building needs it."
command -v clang >/dev/null 2>&1 || fail "clang was not found (xcode-select --install)"

echo "==> whisper.cpp $WHISPER_CPP_TAG"
mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$WHISPER_CPP_TAG" \
        https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi
HEAD="$(git -C "$SRC" rev-parse HEAD)"
[ "$HEAD" = "$WHISPER_CPP_COMMIT" ] || fail "whisper.cpp $WHISPER_CPP_TAG is at $HEAD, expected $WHISPER_CPP_COMMIT. Delete $SRC to fetch it again; if the tag really moved, review the change before updating the pin."

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DGGML_CCACHE=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_EXAMPLES=ON
    -DWHISPER_BUILD_SERVER=ON
    -DWHISPER_SDL2=OFF
    -DWHISPER_CURL=OFF
    -DWHISPER_COREML=OFF
)

for arch in arm64 x86_64; do
    echo "==> Building whisper-server ($arch)"
    if [ "$arch" = arm64 ]; then
        FLAGS=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
    else
        FLAGS=(-DGGML_METAL=OFF -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON)
    fi
    BUILD="$WORK/build-$arch"
    rm -rf "$BUILD"
    cmake -S "$SRC" -B "$BUILD" -DCMAKE_OSX_ARCHITECTURES="$arch" "${COMMON[@]}" "${FLAGS[@]}" >"$WORK/configure-$arch.log" 2>&1 \
        || { tail -40 "$WORK/configure-$arch.log" >&2; fail "cmake configure failed ($arch); full log: $WORK/configure-$arch.log"; }
    cmake --build "$BUILD" --config Release --target whisper-server -j "$JOBS" >"$WORK/build-$arch.log" 2>&1 \
        || { tail -40 "$WORK/build-$arch.log" >&2; fail "build failed ($arch); full log: $WORK/build-$arch.log"; }
    [ -x "$BUILD/bin/whisper-server" ] || fail "no whisper-server in $BUILD/bin"
    lipo "$BUILD/bin/whisper-server" -verify_arch "$arch" || fail "the $arch build is not $arch"
done

echo "==> Making the universal binary"
rm -f "$OUT/whisper-server" "$STAMP"
lipo -create -output "$OUT/whisper-server" "$WORK/build-arm64/bin/whisper-server" "$WORK/build-x86_64/bin/whisper-server"
# Debug symbols are not needed in the app. Stripping voids the linker's
# signature, and Apple Silicon refuses to run unsigned code, so sign it ad hoc
# here; the app signature (release.sh, deploy.sh, install.sh) signs it again.
strip -S "$OUT/whisper-server"
codesign --force --sign - "$OUT/whisper-server" 2>/dev/null
chmod 755 "$OUT/whisper-server"
cp "$SRC/LICENSE" "$OUT/whisper.cpp-LICENSE.txt"
check_binary "$OUT/whisper-server"
echo "$WANT_STAMP" > "$STAMP"
echo "    $(du -h "$OUT/whisper-server" | cut -f1)  $OUT/whisper-server"
