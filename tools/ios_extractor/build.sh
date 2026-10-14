#!/bin/sh
# Builds OpenGOAL's level extractor as static libraries:
#   build-ios-extractor/iphoneos/libjak1_extractor.a          linked by the jakIOS app target (device)
#   build-ios-extractor/iphonesimulator/libjak1_extractor.a   same, for simulator builds
#   build-ios-extractor/macos/libjak1_extractor.a      for desktop testing of jakIOS/Import/Jak1LevelExtractor.cpp
# Usage (from the repo root): sh tools/ios_extractor/build.sh [iphoneos|iphonesimulator|macos|all]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TARGET=${1:-all}
DEPLOYMENT_TARGET=18.6  # jakIOS IPHONEOS_DEPLOYMENT_TARGET

build() {
  platform=$1
  shift
  out="$ROOT/build-ios-extractor/$platform"
  cmake -S "$ROOT/tools/ios_extractor" -B "$out/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release "$@"
  cmake --build "$out/cmake" --target jak1_extractor
  cp "$out/cmake/libjak1_extractor.a" "$out/libjak1_extractor.a"
  echo "Built $out/libjak1_extractor.a"
}

# The iOS SDKs ship with Xcode, not the command line tools xcode-select may point at.
if ! xcrun --sdk iphoneos --show-sdk-path > /dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
for sdk in iphoneos iphonesimulator; do
  if [ "$TARGET" = "$sdk" ] || [ "$TARGET" = all ]; then
    build "$sdk" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  fi
done
if [ "$TARGET" = macos ] || [ "$TARGET" = all ]; then
  build macos -DCMAKE_OSX_ARCHITECTURES=arm64
fi
