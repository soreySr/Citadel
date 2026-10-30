#!/bin/sh
# Builds the Mac-only mod level tools (modlevel_pack, extract_levels, glb_undraco) against the macOS extractor library.
# Usage (from the repo root): sh tools/modlevel/build.sh   -> build-ios-extractor/macos/modlevel_pack
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OG="$ROOT/OpenGOAL"
OUT="$ROOT/build-ios-extractor/macos"
[ -f "$OUT/libjak1_extractor.a" ] || sh "$ROOT/tools/ios_extractor/build.sh" macos
clang -c -O2 -w -I"$OG" "$ROOT/jakIOS/Runtime/Jak1XDelta3.c" -o "$OUT/xdelta3.o"
clang++ -std=c++20 -O2 -w -I"$OG" -I"$OG/third-party" -I"$OG/third-party/fmt/include" -I"$ROOT/jakIOS/Import" \
  "$ROOT/tools/modlevel/modlevel_pack.cpp" "$ROOT/jakIOS/Import/Jak1ModLevelRecipe.cpp" "$OUT/xdelta3.o" \
  "$OUT/libjak1_extractor.a" -lcompression -o "$OUT/modlevel_pack"
echo "Built $OUT/modlevel_pack"
# The disc's levels as the import builds them (modlevel_pack --levels).
clang++ -std=c++20 -O2 -w -I"$OG" -I"$OG/third-party" -I"$OG/third-party/fmt/include" -I"$ROOT/jakIOS/Import" \
  "$ROOT/tools/modlevel/extract_levels.cpp" "$ROOT/jakIOS/Import/Jak1LevelExtractor.cpp" "$OUT/xdelta3.o" \
  "$OUT/libjak1_extractor.a" -lcompression -o "$OUT/extract_levels"
echo "Built $OUT/extract_levels"
# Draco decoder for mod glbs saved with KHR_draco_mesh_compression (the import's tinygltf has no Draco).
DRACO="$ROOT/build-ios-extractor/draco-macos"
if [ ! -f "$DRACO/libdraco.a" ]; then
  cmake -S "$OG/third-party/draco" -B "$DRACO" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 > /dev/null
  ninja -C "$DRACO" > /dev/null
fi
clang++ -std=c++20 -O2 -w -I"$OG" -I"$OG/third-party" -I"$OG/third-party/draco/src" -I"$DRACO" \
  "$ROOT/tools/modlevel/glb_undraco.cpp" "$DRACO/libdraco.a" -o "$OUT/glb_undraco"
echo "Built $OUT/glb_undraco"
