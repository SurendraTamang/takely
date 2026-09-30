#!/bin/bash
# Builds Packages/TakelyKit/Vendor/WebRTCAEC.xcframework: WebRTC AEC3 from the freedesktop
# webrtc-audio-processing release, plus the C wrapper in Vendor/webrtc-aec, as one static arm64 library.
# Needs Xcode, git and `brew install meson ninja`. The result is committed, so normal builds don't run this.
set -euo pipefail

VERSION=v2.1
COMMIT=846fe90a289f58b7c9303a635142aa2c7caa93e5  # the v2.1 tag; a moved tag fails the build
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/build/webrtc-apm
VENDOR=$ROOT/Packages/TakelyKit/Vendor
export MACOSX_DEPLOYMENT_TARGET=26.0
export ZERO_AR_DATE=1  # no timestamps in the archive, so rebuilds are byte-identical
[[ $(uname -m) == arm64 ]] || { echo "run on Apple silicon (native arm64 shell)" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$VERSION" \
    https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$WORK/src"
[[ $(git -C "$WORK/src" rev-parse HEAD) == "$COMMIT" ]] || { echo "tag $VERSION doesn't point at $COMMIT" >&2; exit 1; }

cd "$WORK/src"
meson setup build --default-library=static --buildtype=release --force-fallback-for=abseil-cpp \
    --prefix="$WORK/install" >/dev/null
ninja -C build install >/dev/null

ABSEIL=$(echo "$WORK"/src/subprojects/abseil-cpp-*)
clang++ -std=c++17 -O2 -arch arm64 -DWEBRTC_POSIX -DWEBRTC_MAC \
    -I "$WORK/install/include/webrtc-audio-processing-2" -I "$ABSEIL" \
    -c "$VENDOR/webrtc-aec/WebRTCAEC.cpp" -o "$WORK/WebRTCAEC.o"
libtool -static -o "$WORK/libWebRTCAEC.a" "$WORK/WebRTCAEC.o" "$WORK/install/lib/libwebrtc-audio-processing-2.a"

mkdir -p "$WORK/headers"
cp "$VENDOR/webrtc-aec/WebRTCAEC.h" "$WORK/headers/"
printf 'module WebRTCAEC {\n    header "WebRTCAEC.h"\n    export *\n}\n' >"$WORK/headers/module.modulemap"

rm -rf "$VENDOR/WebRTCAEC.xcframework"
xcodebuild -create-xcframework -library "$WORK/libWebRTCAEC.a" -headers "$WORK/headers" \
    -output "$VENDOR/WebRTCAEC.xcframework" >/dev/null

LICENSES=$VENDOR/webrtc-aec/licenses
rm -rf "$LICENSES"
mkdir -p "$LICENSES"
cp "$WORK/src/COPYING" "$LICENSES/webrtc-audio-processing-COPYING"
cp "$WORK/src/webrtc/LICENSE" "$LICENSES/webrtc-LICENSE"
cp "$WORK/src/webrtc/PATENTS" "$LICENSES/webrtc-PATENTS"
cp "$ABSEIL/LICENSE" "$LICENSES/abseil-LICENSE"
# Code bundled inside WebRTC's audio processing, under its own licenses.
cp "$WORK/src/webrtc/third_party/rnnoise/COPYING" "$LICENSES/rnnoise-COPYING"
cp "$WORK/src/webrtc/third_party/pffft/LICENSE" "$LICENSES/pffft-LICENSE"
cp "$WORK/src/webrtc/modules/third_party/fft/LICENSE" "$LICENSES/fft-LICENSE"
cp "$WORK/src/webrtc/common_audio/third_party/spl_sqrt_floor/LICENSE" "$LICENSES/spl_sqrt_floor-LICENSE"
cp "$WORK/src/webrtc/common_audio/third_party/ooura/LICENSE" "$LICENSES/ooura-LICENSE"
echo "built $VENDOR/WebRTCAEC.xcframework ($VERSION)"
