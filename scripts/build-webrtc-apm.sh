#!/bin/bash
# Builds Packages/TakelyKit/Vendor/WebRTCAEC.xcframework: WebRTC AEC3 from the freedesktop
# webrtc-audio-processing release, plus the C wrapper in Vendor/webrtc-aec, as one static arm64 library.
# Needs Xcode, git and `brew install meson ninja`. The result is committed, so normal builds don't run this.
set -euo pipefail

VERSION=v2.1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/build/webrtc-apm
VENDOR=$ROOT/Packages/TakelyKit/Vendor
export MACOSX_DEPLOYMENT_TARGET=26.0

rm -rf "$WORK"
mkdir -p "$WORK"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$VERSION" \
    https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$WORK/src"

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

mkdir -p "$VENDOR/webrtc-aec/licenses"
cp "$WORK/src/COPYING" "$VENDOR/webrtc-aec/licenses/webrtc-audio-processing-COPYING"
cp "$WORK/src/webrtc/LICENSE" "$VENDOR/webrtc-aec/licenses/webrtc-LICENSE"
cp "$WORK/src/webrtc/PATENTS" "$VENDOR/webrtc-aec/licenses/webrtc-PATENTS"
cp "$ABSEIL/LICENSE" "$VENDOR/webrtc-aec/licenses/abseil-LICENSE"
echo "built $VENDOR/WebRTCAEC.xcframework ($VERSION)"
