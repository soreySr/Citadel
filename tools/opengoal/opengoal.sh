#!/bin/bash
# OpenGOAL/ is not stored in this repository. It is upstream OpenGOAL (the revision in OpenGOALUpstream.lock.json),
# fetched with git, plus our changes in tools/opengoal/opengoal.patch: the iOS AOT tools (tools/ios), kernel capture
# hooks, and our goal_src changes and new objects (pc/ios, engine/mods). Upstream includes OpenGOAL's decompilation of
# the game (goal_src, mips2c, ...), which this repository therefore never hosts.
#
# Usage: tools/opengoal/opengoal.sh <command> [--cache DIR] [--force]
#   apply    create or update OpenGOAL/ = upstream + patch (refuses to overwrite unsaved edits)
#   save     write your current OpenGOAL/ changes into tools/opengoal/opengoal.patch
#   status   report whether OpenGOAL/ matches upstream + patch
#   --cache DIR   upstream checkout (default: build-release/upstream)
#   --force       apply: overwrite edits that are not in the patch
#
# Files ignored by OpenGOAL's own .gitignore files (out/, iso_data/, decompiler_out/, build-make/, ...) are never
# touched or compared. Workflow: edit files in OpenGOAL/ as usual, then run `save` and commit the patch.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OG="$ROOT/OpenGOAL"
PATCH="$ROOT/tools/opengoal/opengoal.patch"
CACHE="$ROOT/build-release/upstream"
FORCE=0
COMMAND=${1:-}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --cache) CACHE=$2; shift 2 ;;
        --force) FORCE=1; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done
mkdir -p "$(dirname "$CACHE")"
CACHE=$(cd "$(dirname "$CACHE")" && pwd)/$(basename "$CACHE")

fail() { echo "error: $*" >&2; exit 1; }

# A private index keeps every operation away from the cache checkout's own index.
INDEX=$(mktemp -t opengoal-index)
trap 'rm -f "$INDEX"' EXIT
upstream_git() { GIT_INDEX_FILE="$INDEX" git --git-dir="$CACHE/.git" --work-tree="$OG" "$@"; }

# Check out upstream OpenGOAL at the locked revision into $CACHE.
fetch_upstream() {
    local repository
    REVISION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$ROOT/OpenGOALUpstream.lock.json")
    repository=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repository"])' "$ROOT/OpenGOALUpstream.lock.json")
    if [ ! -d "$CACHE/.git" ]; then
        echo "Fetching upstream OpenGOAL (about 750 MB, once)..."
        git clone -q --filter=blob:none --no-checkout "$repository" "$CACHE"
    fi
    git -C "$CACHE" sparse-checkout disable 2> /dev/null || true
    if [ "$(git -C "$CACHE" rev-parse HEAD 2> /dev/null)" != "$REVISION" ]; then
        git -C "$CACHE" fetch -q origin "$REVISION" 2> /dev/null || true
        git -C "$CACHE" checkout -q "$REVISION"
    fi
    [ -f "$CACHE/goal_src/jak1/game.gp" ] || fail "upstream checkout at $CACHE is incomplete"
}

# Print OpenGOAL/'s changes against upstream (respecting OpenGOAL's .gitignore files), in the patch's format.
current_diff() {
    upstream_git read-tree HEAD
    upstream_git add -A
    upstream_git diff --cached --binary --no-color HEAD
}

in_sync() {
    [ -d "$OG" ] && cmp -s <(current_diff) "$PATCH"
}

case "$COMMAND" in
    apply)
        fetch_upstream
        if in_sync; then
            echo "OpenGOAL/ is up to date (upstream ${REVISION:0:8} + tools/opengoal/opengoal.patch)."
            exit 0
        fi
        if [ -d "$OG/goal_src" ] && [ "$FORCE" != 1 ]; then
            fail "OpenGOAL/ has changes that are not in tools/opengoal/opengoal.patch." \
                "Run 'tools/opengoal/opengoal.sh save' to keep them, or 'apply --force' to overwrite them."
        fi
        mkdir -p "$OG"
        # Write every upstream file (build outputs and disc data in ignored folders stay as they are), then the patch.
        upstream_git read-tree HEAD
        upstream_git checkout-index -a -f
        (cd "$OG" && GIT_INDEX_FILE="$INDEX" git --git-dir="$CACHE/.git" --work-tree=. apply --whitespace=nowarn "$PATCH") ||
            fail "tools/opengoal/opengoal.patch does not apply"
        if ! in_sync; then
            echo "warning: OpenGOAL/ still differs from upstream + patch (files that exist only locally):" >&2
            current_diff | grep '^diff --git' | sed 's#^diff --git a/[^ ]* b/#  #' >&2
        fi
        echo "Wrote OpenGOAL/ (upstream ${REVISION:0:8} + tools/opengoal/opengoal.patch)."
        ;;
    save)
        fetch_upstream
        [ -d "$OG/goal_src" ] || fail "OpenGOAL/ does not exist (run apply first)"
        current_diff > "$PATCH.new"
        mv "$PATCH.new" "$PATCH"
        echo "Wrote tools/opengoal/opengoal.patch ($(grep -c '^diff --git' "$PATCH") files changed from upstream)."
        ;;
    status)
        fetch_upstream
        if in_sync; then
            echo "in sync"
        else
            echo "OpenGOAL/ differs from upstream + patch (run save to keep your edits):"
            diff <(grep '^diff --git' "$PATCH") <(current_diff | grep '^diff --git') | grep '^[<>]' || true
            exit 1
        fi
        ;;
    *)
        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
