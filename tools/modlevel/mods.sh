#!/bin/bash
# Downloads the community mod levels from their authors' GitHub repositories and prepares jakIOS/ModLevels/ for the
# app. Nothing of the mods is stored in this repository: every build fetches them from the source, at the commits
# below. tools/release/build.sh runs this before it links the level code.
#
#   Glacier             by Cuttlefishthesage  https://github.com/Cuttlefishthesage/OG-Mod-Base-Glacier
#   Brume Village       by Cuttlefishthesage  https://github.com/Cuttlefishthesage/BrumeVillage
#   The Forgotten Lands by Kuitar5            https://github.com/Kuitar5/the-forgotten-lands
#
# Usage (from anywhere): tools/modlevel/mods.sh --work DIR [--disc OpenGOAL/iso_data/jak1]
#   --work DIR   scratch folder: mod checkouts, the disc's levels, packed files (build.sh: build-release/mods)
#   --disc DIR   the extracted NTSC v1 disc (default OpenGOAL/iso_data/jak1)
# Needs OpenGOAL/ (tools/opengoal/opengoal.sh apply), the extracted disc, CMake, Ninja, zstd, git, afconvert.
#
# Per mod: sparse checkout of the files the app uses -> level glbs Draco-decoded (glb_undraco) -> the game's own
# textures and ripped meshes taken out of every glb (modlevel_pack, against the disc's levels built exactly as the
# app's import builds them) -> zstd -19 -> level descriptions staged (mod_stage.py, forgotten_stage.py) -> music
# and hint voices converted to AAC. At ISO import the app puts the game's data back from the player's own disc
# (tools/modlevel/README.md). A mod whose inputs did not change since the last run is not rebuilt.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OG="$ROOT/OpenGOAL"
OUT="$ROOT/jakIOS/ModLevels"
TOOLS="$ROOT/build-ios-extractor/macos"
WORK=""
DISC="$OG/iso_data/jak1"

while [ $# -gt 0 ]; do
    case "$1" in
        --work) WORK=$2; shift 2 ;;
        --disc) DISC=$2; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
done
[ -n "$WORK" ] || { echo "error: --work DIR is required" >&2; exit 2; }
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
DISC=$(cd "$DISC" && pwd)

fail() { echo "error: $*" >&2; exit 1; }
for tool in zstd git afconvert python3; do
    command -v "$tool" > /dev/null || fail "$tool not found (zstd: brew install zstd)"
done
[ -f "$DISC/CGO/GAME.CGO" ] || fail "no extracted disc at $DISC"
[ -d "$OG/decompiler/config/jak1" ] || fail "no OpenGOAL/ yet (tools/opengoal/opengoal.sh apply)"

# ---- the mods: name, repository, commit, sparse paths ----------------------------------------------------------
GLACIER_REPO=https://github.com/Cuttlefishthesage/OG-Mod-Base-Glacier.git
GLACIER_COMMIT=b530d0ec49df7ee44916f475b4630a85f203ad6b
BRUME_REPO=https://github.com/Cuttlefishthesage/BrumeVillage.git
BRUME_COMMIT=51b106d9ba01b3ce710eb7e8fa0be3ce1776eb1b
FORGOTTEN_REPO=https://github.com/Kuitar5/the-forgotten-lands.git
FORGOTTEN_COMMIT=e8618a3022879ce45eee7ffd227e7d41949638df

# Brume's custom models (the levels' "custom_models" the app builds) and its music loops: <source> <app name>.
BRUME_MODELS="test-actor2 gravityswitch ambushdoor"
BRUME_AUDIO="jungsunrep.wav:brume-music junsynthrep.wav:abandon-music junraverep.wav:mount-music
musesteps.mp3:brume-musesteps"
FORGOTTEN_LEVELS="crystal-cave crescent-top energy-bay open-mines valley"
# All the mod's models but the developer commentary nodes, the title screen's and the unused test actor.
FORGOTTEN_MODELS="bucket-wheel crc-dev-cam crc-gondola cst-dev-cam enb-dev-cam lab-door observatory-lens
observatory-ring opm-dev-cam pds-cam pds-gem-blue pds-gem-green pds-gem-yellow pds-plat-circle pds-plat-rectangle
pds-plat-square pds-sentinel pds-swingpole pds-trap-central pds-trap-inner pds-trap-mid-left pds-trap-mid-right
pds-trap-out-left pds-trap-out-right rolling-rock tfl-crystal-blue tfl-crystal-green tfl-crystal-red
tfl-crystal-yellow tfl-lowreskui turbineblade val-dev-cam valley-rock"

# fetch <dir> <repo> <commit> <path>...: only the listed paths, only that commit (a few hundred MB at most).
fetch() {
    local dir=$1 repo=$2 commit=$3
    shift 3
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2> /dev/null)" = "$commit" ]; then
        git -C "$dir" sparse-checkout set --no-cone "$@"
        return
    fi
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" remote add origin "$repo"
    git -C "$dir" sparse-checkout set --no-cone "$@"
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$commit" ||
        fail "could not download $repo (commit $commit). Check the internet connection and rerun"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

# pack <glb> <output dir> <name> [modlevel_pack options]: -> <name>.glb.zst + <name>.recipe.json
pack() {
    local glb=$1 out=$2 name=$3
    shift 3
    local plain="$WORK/tmp/$name.glb"
    mkdir -p "$WORK/tmp"
    [ -f "$glb" ] || fail "the mod has no $glb"
    if LC_ALL=C grep -q -a KHR_draco_mesh_compression "$glb"; then
        "$TOOLS/glb_undraco" "$glb" "$WORK/tmp/$name-plain.glb" > /dev/null
        glb="$WORK/tmp/$name-plain.glb"
    fi
    if ! "$TOOLS/modlevel_pack" --glb "$glb" --project "$OG" --disc "$DISC" --levels "$LEVELS" \
            --out-glb "$plain" --out-recipe "$out/$name.recipe.json" "$@" > "$WORK/logs/pack-$name.log" 2>&1; then
        tail -20 "$WORK/logs/pack-$name.log" >&2
        fail "packing $name failed (log: $WORK/logs/pack-$name.log)"
    fi
    zstd -q -19 -T0 -f "$plain" -o "$out/$name.glb.zst"
    rm -f "$plain" "$WORK/tmp/$name-plain.glb"
}

# aac <source> <output.m4a> [afconvert options]
aac() {
    [ -f "$1" ] || fail "the mod has no $1"
    afconvert -f m4af -d aac "${@:3}" "$1" "$2"
}

# The inputs of a mod's build: its commit and our tools / scripts. Unchanged -> the last build is reused.
stamp() {
    { echo "$1"; cat "$ROOT/tools/modlevel/mods.sh" "$ROOT/tools/modlevel/modlevel_pack.cpp" \
        "$ROOT/tools/modlevel/glb_undraco.cpp" "$ROOT/tools/modlevel/mod_stage.py" \
        "$ROOT/tools/modlevel/forgotten_stage.py" "$ROOT/jakIOS/Import/Jak1ModLevelRecipe.cpp"; } | shasum -a 256
}

# build_mod <Name> <commit> <function>: builds into a staging folder, then replaces jakIOS/ModLevels/<Name>.
build_mod() {
    local name=$1 commit=$2 function=$3 stamp_value
    stamp_value=$(stamp "$commit")
    if [ -d "$OUT/$name" ] && [ -f "$WORK/stamps/$name" ] && [ "$(cat "$WORK/stamps/$name")" = "$stamp_value" ]; then
        echo "  $name: up to date"
        return
    fi
    prepare_tools
    local stage="$WORK/stage/$name"
    rm -rf "$stage"
    mkdir -p "$stage"
    "$function" "$stage"
    rm -rf "${OUT:?}/$name"
    mkdir -p "$OUT" "$WORK/stamps"
    mv "$stage" "$OUT/$name"
    echo "$stamp_value" > "$WORK/stamps/$name"
    echo "  $name: done ($(du -sh "$OUT/$name" | cut -f1))"
}

# Built on first use only: the packer, and the disc's levels it matches against (as the app's import builds them).
TOOLS_READY=0
LEVELS="$WORK/levels"
prepare_tools() {
    [ "$TOOLS_READY" = 0 ] || return 0
    echo "  building the mod level tools (the first time takes a few minutes)"
    sh "$ROOT/tools/modlevel/build.sh" > "$WORK/logs/tools.log" 2>&1 ||
        { tail -20 "$WORK/logs/tools.log" >&2; fail "building the mod level tools failed (log: $WORK/logs/tools.log)"; }
    if [ "$(ls "$LEVELS"/Jak1Level-*.fr3z 2> /dev/null | wc -l)" -lt 25 ]; then
        echo "  building the disc's levels for matching"
        rm -rf "$LEVELS"
        python3 "$ROOT/tools/ios_extractor/pack_config.py" "$WORK/Jak1ExtractorConfig.pack" > /dev/null
        "$TOOLS/extract_levels" "$WORK/Jak1ExtractorConfig.pack" "$DISC" "$LEVELS" > "$WORK/logs/levels.log" 2>&1 ||
            { tail -20 "$WORK/logs/levels.log" >&2; fail "building the disc's levels failed (log: $WORK/logs/levels.log)"; }
    fi
    TOOLS_READY=1
}

build_glacier() {
    local stage=$1 mod="$WORK/src/glacier"
    pack "$mod/custom_assets/jak1/levels/glacier/glacier.glb" "$stage" glacier
    python3 "$ROOT/tools/modlevel/mod_stage.py" glacier "$mod" "$stage"
}

build_brume() {
    local stage=$1 mod="$WORK/src/brume" level glb model entry
    for level in brume abandon mount preundg; do
        glb="$mod/custom_assets/jak1/levels/$level/$level.glb"
        [ "$level" = mount ] && glb="$mod/custom_assets/jak1/levels/mount/mountain.glb"
        pack "$glb" "$stage" "$level"
    done
    for model in $BRUME_MODELS; do
        pack "$mod/custom_assets/jak1/models/custom_levels/$model.glb" "$stage" "$model"
    done
    python3 "$ROOT/tools/modlevel/mod_stage.py" brume "$mod" "$stage"
    for entry in $BRUME_AUDIO; do
        local source="$mod/custom_assets/jak1/audio/sound_replacements/${entry%%:*}" target="$stage/${entry#*:}.m4a"
        case "$source" in
            *.wav) aac "$source" "$target" -b 160000 ;;
            *) aac "$source" "$target" ;;
        esac
    done
}

build_forgotten() {
    local stage=$1 mod="$WORK/src/forgotten" level model file
    # --substitute-near-copies: the mod's near-identical re-saves of disc textures (precursor-metal-plain-SD, a
    # re-save of jng-precursor-metal-plain-fade-01, and an edging copy) use the disc's.
    for level in $FORGOTTEN_LEVELS; do
        pack "$mod/custom_assets/jak1/levels/$level/$level.glb" "$stage" "$level" --substitute-near-copies 1
    done
    for model in $FORGOTTEN_MODELS; do
        pack "$mod/custom_assets/jak1/models/custom_levels/$model.glb" "$stage" "$model" --substitute-near-copies 1
    done
    python3 "$ROOT/tools/modlevel/forgotten_stage.py" "$mod" "$stage" > /dev/null
    for file in "$mod"/custom_assets/jak1/audio/tfl/music/*.mp3; do
        aac "$file" "$stage/tfl-music-$(basename "$file" .mp3).m4a" -b 160000
    done
    for file in "$mod"/custom_assets/jak1/audio/tfl/hints/*.wav; do
        aac "$file" "$stage/$(basename "$file" .wav).m4a" -b 96000
    done
}

mkdir -p "$WORK/logs" "$WORK/src"
echo "  downloading the mods from GitHub (the first time: about 1 GB)"
fetch "$WORK/src/glacier" "$GLACIER_REPO" "$GLACIER_COMMIT" /LICENSE /custom_assets/jak1/levels/glacier/
fetch "$WORK/src/brume" "$BRUME_REPO" "$BRUME_COMMIT" /LICENSE /custom_assets/jak1/levels/brume/ \
    /custom_assets/jak1/levels/abandon/ /custom_assets/jak1/levels/mount/ /custom_assets/jak1/levels/preundg/ \
    $(for model in $BRUME_MODELS; do echo "/custom_assets/jak1/models/custom_levels/$model.glb"; done) \
    $(for entry in $BRUME_AUDIO; do echo "/custom_assets/jak1/audio/sound_replacements/${entry%%:*}"; done)
fetch "$WORK/src/forgotten" "$FORGOTTEN_REPO" "$FORGOTTEN_COMMIT" /LICENSE \
    $(for level in $FORGOTTEN_LEVELS; do echo "/custom_assets/jak1/levels/$level/"; done) \
    $(for model in $FORGOTTEN_MODELS; do echo "/custom_assets/jak1/models/custom_levels/$model.glb"; done) \
    /custom_assets/jak1/audio/tfl/music/ /custom_assets/jak1/audio/tfl/hints/

build_mod Glacier "$GLACIER_COMMIT" build_glacier
build_mod Brume "$BRUME_COMMIT" build_brume
build_mod Forgotten "$FORGOTTEN_COMMIT" build_forgotten
rm -rf "$WORK/tmp"
echo "  wrote $OUT"
