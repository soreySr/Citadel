#!/bin/bash
# Builds Citadel.ipa from this source code and your own Jak and Daxter disc. Citadel is not distributed as an
# IPA: everyone builds their own. Nothing built here is committed: the repository holds source only.
#
# Usage (from anywhere): tools/release/build.sh --iso "<your NTSC v1 disc image>.iso" [options]
#   --iso FILE          extract + decompile this disc image first (only needed once; later runs reuse
#                       OpenGOAL/iso_data/jak1 and OpenGOAL/decompiler_out/jak1)
#   --work DIR          scratch folder (default: build-release/ at the repository root, gitignored)
#   --no-ipa            stop after jakIOS/Generated/ (enough to build and run from Xcode)
#   --audit             scan the finished IPA for disc data (tools/release_audit, takes 5-20 minutes)
#   --update-expected   developers: accept changed outputs, rewrite tools/release/expected-generated.sha256
#   --jobs N            parallel compile jobs (default: CPU count)
#
# Needs: a Mac with Apple silicon, Xcode (with the iOS platform), CMake, Ninja, Python 3, git, about 15 GB of free
# disk space and an internet connection (upstream OpenGOAL, about 750 MB, is fetched once). The first run takes 20-30
# minutes. The result is build-release/Citadel.ipa (unsigned): install it with a sideloading tool, which signs it.
#
# How it works (details in OPEN_GOAL_IOS_PORT.md, "Building the app from source"):
#   0. OpenGOAL  OpenGOAL/ = upstream OpenGOAL + tools/opengoal/opengoal.patch (tools/opengoal/opengoal.sh).
#   1. tools     goalc + gk from OpenGOAL/ (CMake), noaslr helper, xd3_tool.
#   2. capture   the signed code is the engine as upstream OpenGOAL compiles it: upstream goal_src at the revision
#                in OpenGOALUpstream.lock.json (fetched by tools/opengoal/opengoal.sh) is compiled (KERNEL/GAME/TIT)
#                and booted in desktop gk, which dumps its 128 MiB GOAL arena at the first kernel dispatch.
#                The capture environment below is fixed so the memory layout matches what the iOS host's hard-coded GOAL addresses expect; the capture record is
#                checked against tools/aot_inputs/Jak1AOTRuntimeCapture.json and the build stops if it differs.
#   3. game      OpenGOAL/goal_src (upstream + tools/opengoal/opengoal.patch: our engine changes, ios-* objects),
#                compiled with (mi).
#   4. derive    signed code payload + tables from the arena, level code linked from step 3 at fixed addresses,
#                arena -> xdelta3 patch against your disc (no disc bytes ship), extractor config pack.
#   5. verify    deterministic outputs are compared with tools/release/expected-generated.sha256.
#   6. ipa       extractor library, unsigned Release build, stripped, zipped.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OG="$ROOT/OpenGOAL"
GENERATED="$ROOT/jakIOS/Generated"
EXPECTED="$ROOT/tools/release/expected-generated.sha256"
CAPTURE_REFERENCE="$ROOT/tools/aot_inputs/Jak1AOTRuntimeCapture.json"

WORK="$ROOT/build-release"
ISO=""
BUILD_IPA=1
AUDIT=0
UPDATE_EXPECTED=0
JOBS=$(sysctl -n hw.ncpu)

while [ $# -gt 0 ]; do
    case "$1" in
        --iso) ISO=$2; shift 2 ;;
        --work) WORK=$2; shift 2 ;;
        --no-ipa) BUILD_IPA=0; shift ;;
        --audit) AUDIT=1; shift ;;
        --update-expected) UPDATE_EXPECTED=1; shift ;;
        --jobs) JOBS=$2; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
done
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

# ---- Capture environment: part of the layout contract, do not change --------------------------------------------
# gk stores these strings in the GOAL heap before the engine loads, so their lengths set every later address.
# The original capture ran with a 20-character home folder; any 20-character path gives the same layout, and this
# one keeps the builder's user name out of the app. The folder does not need to exist.
CAPTURE_HOME=/Users/citadel-build
CAPTURE_CONFIG=/private/tmp/opengoal-ios-aot-config
# knuth-rand is seeded from the clock and keeps the reading in its statics, which are part of the signed payload.
CAPTURE_CLOCK="2026-10-01 18:20:05"

# ---- Level code link: captured objects relinked from current source, then startup objects in order --------------
RELINK_CAPTURED="ocean-tables mood-tables mood level-info level entity task-control progress-static title-obs"
STARTUP_OBJECTS="ios-blue-eco-swim ios-boat-park ios-dynamic-save ios-ocean-fish ios-boat-summon ios-green-eco"

# Outputs that must come out byte-identical for identical sources (the .xd3 also holds gk's native pointers).
DETERMINISTIC="Jak1AOTBootstrap.bin Jak1AOTBootstrapManifest.json Jak1AOTCodeRanges.bin Jak1AOTImagePayload.bin
Jak1AOTKernelEntry.json Jak1AOTRuntimeSymbols.json Jak1NativeStubInventory.json Jak1ExtractorConfig.pack
LevelCode/Jak1LevelCode.bin LevelCode/Jak1LevelCodeManifest.json"

TOOLS="$WORK/opengoal-build"
GOALC="$TOOLS/goalc/goalc"
GK="$TOOLS/game/gk"
NOASLR="$WORK/noaslr"
DISC="$OG/iso_data/jak1"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

# A goalc project folder that reads everything from OpenGOAL/ but writes its out/ and log/ under $1.
make_project() {
    local project=$1 entry
    mkdir -p "$project"
    for entry in "$OG"/* "$OG"/.[!.]*; do
        case "$(basename "$entry")" in
            out|log|build|build-make|.git|.DS_Store) ;;
            *) [ -e "$project/$(basename "$entry")" ] || ln -s "$entry" "$project/$(basename "$entry")" ;;
        esac
    done
}

run_goalc() {
    local project=$1 command=$2 log=$3
    if ! (cd "$project" && "$GOALC" -g jak1 --proj-path "$project" -c "$command" > "$log" 2>&1); then
        sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -30 >&2
        fail "goalc failed (full log: $log)"
    fi
}

# ---- checks ------------------------------------------------------------------------------------------------------
step "Checking requirements"
[ "$(uname -s)" = Darwin ] || fail "this script runs on macOS"
# The capture runs the game's ARM64 code natively in the desktop runtime.
[ "$(uname -m)" = arm64 ] || fail "a Mac with Apple silicon (M1 or later) is needed"
for tool in cmake ninja; do
    command -v "$tool" > /dev/null || fail "$tool not found. Install it with Homebrew: brew install cmake ninja"
done
for tool in python3 git clang; do
    command -v "$tool" > /dev/null || fail "$tool not found. Install Xcode's command line tools: xcode-select --install"
done
# xcodebuild and the iOS SDK come with Xcode itself, not the command line tools xcode-select may point at.
if ! xcodebuild -version > /dev/null 2>&1; then
    [ -d /Applications/Xcode.app ] || fail "Xcode not found. Install it from the App Store, open it once, then rerun"
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    xcodebuild -version > /dev/null 2>&1 ||
        fail "xcodebuild does not run. Open Xcode once to finish its setup (or run: sudo xcodebuild -license accept)"
fi
xcrun --sdk iphoneos --show-sdk-path > /dev/null 2>&1 ||
    fail "the iOS platform is not installed in Xcode. Run: xcodebuild -downloadPlatform iOS"
FREE_GB=$(df -g "$WORK" | awk 'NR == 2 {print $4}')
[ "$FREE_GB" -ge 15 ] || echo "warning: only ${FREE_GB} GB free; the build needs about 15 GB" >&2

# ---- OpenGOAL -----------------------------------------------------------------------------------------------------
# Not stored in the repository (upstream includes OpenGOAL's decompilation of the game): upstream at the locked
# revision plus tools/opengoal/opengoal.patch. Stops if OpenGOAL/ has edits that are not saved in the patch.
UPSTREAM="$WORK/upstream"
step "Preparing OpenGOAL/ (upstream + tools/opengoal/opengoal.patch)"
"$ROOT/tools/opengoal/opengoal.sh" apply --cache "$UPSTREAM"

# ---- 1. tools ----------------------------------------------------------------------------------------------------
step "Building goalc and gk (the first time takes about 15 minutes)"
cmake -S "$OG" -B "$TOOLS" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_TESTING=OFF > "$WORK/cmake-configure.log" 2>&1 || { tail -20 "$WORK/cmake-configure.log"; fail "cmake failed"; }
TARGETS="goalc gk"
[ -n "$ISO" ] && TARGETS="$TARGETS extractor"
ninja -C "$TOOLS" -j "$JOBS" $TARGETS > "$WORK/ninja.log" 2>&1 || { tail -30 "$WORK/ninja.log"; fail "ninja failed"; }
clang -O2 -o "$NOASLR" "$ROOT/tools/release/noaslr.c"
clang -O2 -I"$OG" "$ROOT/tools/runtime_state_patch/xd3_tool.c" -x c "$OG/third-party/xdelta3/xdelta3.c" -w \
    -o "$ROOT/tools/runtime_state_patch/xd3_tool"

# ---- disc --------------------------------------------------------------------------------------------------------
if [ -n "$ISO" ] && { [ ! -f "$DISC/CGO/GAME.CGO" ] || [ ! -d "$OG/decompiler_out/jak1/raw_obj" ]; }; then
    [ -f "$ISO" ] || fail "disc image not found: $ISO"
    step "Extracting and decompiling the disc (a few minutes)"
    "$TOOLS/decompiler/extractor" "$ISO" --proj-path "$OG" --extract --decompile > "$WORK/extractor.log" 2>&1 ||
        { sed 's/\x1b\[[0-9;]*m//g' "$WORK/extractor.log" | tail -20; fail "disc extraction failed (log: $WORK/extractor.log)"; }
fi
[ -f "$DISC/CGO/GAME.CGO" ] || fail "no extracted disc yet: run with --iso \"<your Jak and Daxter disc image>.iso\""
[ -d "$OG/decompiler_out/jak1/raw_obj" ] || fail "no decompiled disc data yet: run with --iso \"<your disc image>.iso\""
# The runtime state patch and the captured layout are made for the original NTSC (USA) release.
(cd "$DISC" && shasum -a 256 -c "$ROOT/tools/release/ntsc-v1.sha256" > /dev/null 2>&1) ||
    fail "this disc is not the NTSC v1 (USA) release of Jak and Daxter: The Precursor Legacy, the only one supported." \
        "Delete OpenGOAL/iso_data/jak1 and OpenGOAL/decompiler_out/jak1, then rerun with --iso and the right disc"

# ---- 2. capture --------------------------------------------------------------------------------------------------
step "Compiling upstream KERNEL.CGO, GAME.CGO, TIT.DGO"
CAPTURE="$WORK/capture"
rm -rf "$CAPTURE"
mkdir -p "$CAPTURE"
cp -R "$UPSTREAM/goal_src" "$CAPTURE/goal_src"
ln -s "$OG/iso_data" "$CAPTURE/iso_data"
ln -s "$OG/decompiler_out" "$CAPTURE/decompiler_out"
run_goalc "$CAPTURE" '(begin (make "$OUT/iso/KERNEL.CGO") (make "$OUT/iso/GAME.CGO") (make "$OUT/iso/TIT.DGO"))' \
    "$WORK/goalc-capture.log"

step "Capturing the desktop runtime"
if ! (cd "$CAPTURE" && HOME="$CAPTURE_HOME" OPENGOAL_IOS_AOT_CLOCK="$CAPTURE_CLOCK" \
        OPENGOAL_IOS_AOT_STATE_PATH="$CAPTURE/arena.bin" OPENGOAL_RECORD_SYMBOLS=1 \
        "$NOASLR" "$GK" -g jak1 --no-display --proj-path "$CAPTURE" --config-path "$CAPTURE_CONFIG" \
        -- -boot -fakeiso > "$CAPTURE/gk-stdout.log" 2> "$CAPTURE/gk-capture.log"); then
    tail -20 "$CAPTURE/gk-stdout.log"
    fail "gk capture failed"
fi
python3 "$OG/tools/ios/capture_startup_addresses.py" "$CAPTURE/gk-capture.log" "$CAPTURE/capture.json" > /dev/null
cmp -s "$CAPTURE/capture.json" "$CAPTURE_REFERENCE" ||
    fail "the capture layout differs from tools/aot_inputs/Jak1AOTRuntimeCapture.json ($CAPTURE/capture.json);" \
        "the iOS host's fixed GOAL addresses would no longer match"

# ---- 3. game -----------------------------------------------------------------------------------------------------
step "Compiling the current goal_src (mi)"
GAME="$WORK/game"
make_project "$GAME"
mkdir -p "$GAME/out/jak1/fr3"
run_goalc "$GAME" '(mi)' "$WORK/goalc-game.log"
# The ios-* startup objects are in no DGO. fishermans-boat first: some targets fail when made in a fresh session.
IOS_MAKE='(begin (make "$OUT/obj/fishermans-boat.o")'
for name in $STARTUP_OBJECTS; do IOS_MAKE="$IOS_MAKE (make \"\$OUT/obj/$name.o\")"; done
run_goalc "$GAME" "$IOS_MAKE)" "$WORK/goalc-ios.log"

# ---- 4. derive ---------------------------------------------------------------------------------------------------
step "Deriving jakIOS/Generated/"
STAGE="$WORK/generated"
rm -rf "$STAGE"
mkdir -p "$STAGE/LevelCode"
IOS_TOOLS="$OG/tools/ios"
python3 "$IOS_TOOLS/aot_captured_runtime_image.py" "$CAPTURE_REFERENCE" "$CAPTURE/arena.bin" \
    "$STAGE/Jak1AOTBootstrap.bin" "$STAGE/Jak1AOTCodeRanges.bin" "$STAGE/Jak1AOTKernelEntry.json" \
    "$STAGE/Jak1AOTRuntimeSymbols.json" --bootstrap-manifest "$STAGE/Jak1AOTBootstrapManifest.json"
python3 "$IOS_TOOLS/aot_signed_text_embed.py" "$STAGE/Jak1AOTBootstrap.bin" "$STAGE/Jak1AOTImagePayload.bin"
python3 "$OG/tools/ios/capture_c_function_stubs.py" "$CAPTURE_REFERENCE" "$STAGE/Jak1NativeStubInventory.json"
LINK_ARGS=""
for name in $RELINK_CAPTURED; do LINK_ARGS="$LINK_ARGS --relink-captured $name"; done
for name in $STARTUP_OBJECTS; do LINK_ARGS="$LINK_ARGS --startup-object $name"; done
python3 "$IOS_TOOLS/aot_level_code_link.py" "$CAPTURE/arena.bin" "$CAPTURE_REFERENCE" "$OG/goal_src/jak1/dgos" \
    "$GAME/out/jak1/obj" "$STAGE/LevelCode/Jak1LevelCode.bin" "$STAGE/LevelCode/Jak1LevelCodeManifest.json" \
    --extra-dgo-dir "$OG/custom_assets/jak1/levels" $LINK_ARGS
python3 "$ROOT/tools/runtime_state_patch/runtime_state_patch.py" encode "$CAPTURE/arena.bin" "$DISC" \
    "$STAGE/Jak1AOTRuntimeState.xd3"
python3 "$ROOT/tools/ios_extractor/pack_config.py" "$STAGE/Jak1ExtractorConfig.pack"

# ---- 5. verify ---------------------------------------------------------------------------------------------------
step "Verifying deterministic outputs"
(cd "$STAGE" && shasum -a 256 $DETERMINISTIC) > "$WORK/generated.sha256"
if [ "$UPDATE_EXPECTED" = 1 ]; then
    cp "$WORK/generated.sha256" "$EXPECTED"
    echo "Updated $EXPECTED"
elif ! diff -u "$EXPECTED" "$WORK/generated.sha256"; then
    fail "the built game code differs from the tested build (tools/release/expected-generated.sha256)." \
        "If you did not change the source, please report this. Developers: after an intended GOAL change, test on a" \
        "device, then rerun with --update-expected."
else
    echo "All deterministic outputs match tools/release/expected-generated.sha256."
fi

rm -rf "$GENERATED"
mkdir -p "$(dirname "$GENERATED")"
cp -R "$STAGE" "$GENERATED"
# Xcode does not track .incbin inputs.
touch "$ROOT/jakIOS/Runtime/Jak1AOTSignedImage.s"
echo "Wrote $GENERATED"

[ "$BUILD_IPA" = 1 ] || exit 0

# ---- 6. ipa ------------------------------------------------------------------------------------------------------
step "Building the level extractor library (iphoneos)"
sh "$ROOT/tools/ios_extractor/build.sh" iphoneos > "$WORK/ios-extractor.log" 2>&1 ||
    { tail -30 "$WORK/ios-extractor.log"; fail "extractor library build failed"; }

step "Building the unsigned Release app"
DERIVED="$WORK/DerivedData"
if ! xcodebuild -project "$ROOT/jakIOS.xcodeproj" -scheme jakIOS -configuration Release -sdk iphoneos \
        -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        DEVELOPMENT_TEAM="" OTHER_CFLAGS='$(inherited) -ffile-prefix-map=$(SRCROOT)/=' \
        OTHER_SWIFT_FLAGS='$(inherited) -file-prefix-map $(SRCROOT)/=' clean build > "$WORK/xcodebuild.log" 2>&1; then
    grep -E "error:" "$WORK/xcodebuild.log" | head -20
    fail "xcodebuild failed (full log: $WORK/xcodebuild.log)"
fi
if grep -q "only available" "$WORK/xcodebuild.log"; then
    grep "only available" "$WORK/xcodebuild.log" | sort -u
    fail "the build uses APIs newer than the deployment target"
fi

step "Packaging Citadel.ipa"
APP="$DERIVED/Build/Products/Release-iphoneos/jakIOS.app"
[ -d "$APP" ] || fail "no app at $APP"
PACKAGE="$WORK/package"
rm -rf "$PACKAGE"
mkdir -p "$PACKAGE/Payload"
cp -R "$APP" "$PACKAGE/Payload/"
# The debug map holds absolute build paths.
xcrun strip -S "$PACKAGE/Payload/jakIOS.app/jakIOS"
xattr -cr "$PACKAGE/Payload"
IPA="$WORK/Citadel.ipa"
rm -f "$IPA"
(cd "$PACKAGE" && zip -qryX "$IPA" Payload)
if LC_ALL=C grep -q -F "$(id -un)" "$PACKAGE/Payload/jakIOS.app/jakIOS"; then
    echo "warning: the app binary still contains your user name ($(id -un))" >&2
fi
echo "Wrote $IPA ($(du -h "$IPA" | cut -f1))"
(cd "$WORK" && shasum -a 256 Citadel.ipa)
echo "Install it on your iPhone or iPad with a sideloading tool (AltStore, SideStore, Sideloadly, ...), which signs it."
echo "In the app, import the same disc image."

# ---- audit (optional) --------------------------------------------------------------------------------------------
if [ "$AUDIT" = 1 ]; then
    step "Scanning the IPA for disc data"
    VENV="$WORK/venv"
    [ -x "$VENV/bin/python3" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" -q install numpy; }
    "$VENV/bin/python3" "$ROOT/tools/release_audit/audit.py" --disc "$DISC" --app "$IPA"
fi
