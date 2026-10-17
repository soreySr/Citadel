# OpenGOAL iOS Runtime Integration

## Upstream baseline

The port is pinned in `OpenGOALUpstream.lock.json`. The upstream source is used as the
semantic reference for the GOAL compiler, linker, symbol table, type system, and kernel
bootstrap. Game assets remain user-supplied and are not copied into the app.

## Stock-iOS execution model

Stock iOS does not permit the desktop runtime's writable/executable-memory design. The
iOS target therefore must not use the upstream `mach_vm_remap` executable view, runtime
`mprotect(PROT_EXEC)`, or generated native trampolines.

The supported pipeline is:

1. Run the pinned OpenGOAL ARM64 compiler and Jak 1 linker as a macOS build tool.
2. Link every executable GOAL segment at build time.
3. Emit code into Mach-O assembly sections so Xcode signs it with the application.
4. Emit a separate writable-memory bootstrap image containing the initialized symbol
   table, type graph, heaps, static objects, and relocation results.
5. Emit a manifest that identifies every executable range and every writable relocation.
6. Validate both images and their hashes before allowing kernel dispatch on iOS.

## Runtime initialization boundary

Upstream `game/kernel/jak1/kscheme.cpp::InitHeapAndSymbol()` is authoritative. The iOS
bootstrap must reproduce all of its observable state before calling GOAL code, including:

- fixed pairs, booleans, heaps, and allocation symbols;
- the complete fundamental and derived type hierarchy;
- fixed functions and their method tables;
- C/native helper symbols;
- linked `kernel` top-level execution;
- listener/kernel symbols and kernel package state;
- engine top-level execution and machine symbols.

Jumping directly to `kernel-dispatcher` before this state exists is invalid. A zero GOAL
function offset becomes the synthetic executable base and causes the page-aligned
`EXC_BAD_ACCESS` failures observed on device.

## Required build artifacts

The existing payload remains non-executable because its manifest declares
`prelinked-signed-code-pending-goal-executor`. A replacement build must generate:

- a signed ARM64 code image;
- a writable GOAL bootstrap image;
- initial symbol values, not only symbol hashes and names;
- serialized type and method tables;
- ordered top-level initialization records;
- executable-range and relocation manifests;
- a manifest execution state of `signed-native-kernel-dispatch-ready` only after all
  validation passes.

The runtime safety gate must remain enabled until these artifacts are generated together.

## Building the app from source

The app bundle ships no disc data. Level files and the captured GOAL arena are built from the player's
own NTSC v1 disc at import (see `asset-free-bundle-plan.md`).

The repository holds source only. `tools/release/build.sh [--iso <disc image>]` builds everything else
(about 6 minutes once the toolchain is built; `--help` lists the options):

0. **OpenGOAL**: `OpenGOAL/` is not in the repository. `tools/opengoal/opengoal.sh apply` checks out upstream
   OpenGOAL at the locked revision (`build-release/upstream`, about 750 MB) and applies `tools/opengoal/opengoal.patch`
   (our changes: `tools/ios`, the kernel capture hooks, `goal_src` engine changes, `pc/ios/*`, `engine/mods/*`).
   Upstream includes OpenGOAL's decompilation of the game (`goal_src`, `game/mips2c`, decompiler references), which
   this repository therefore never hosts. Files ignored by OpenGOAL's `.gitignore` (disc data, `out/`, builds) are
   left alone. It refuses to overwrite edits that are not in the patch: after editing anything in `OpenGOAL/` run
   `opengoal.sh save` and commit the patch (`opengoal.sh status` checks).
1. **tools**: `goalc` and `gk` from `OpenGOAL/` into `build-release/opengoal-build`.
2. **capture**: upstream `goal_src` at the revision in `OpenGOALUpstream.lock.json` (fetched with git) is compiled
   (KERNEL/GAME/TIT) and booted in desktop `gk`, which dumps its 128 MiB GOAL arena at the first kernel dispatch
   (`OPENGOAL_IOS_AOT_STATE_PATH`, game/kernel/jak1/kboot.cpp). The captured engine is upstream's on purpose: our
   engine changes reach the device as relinked objects (step 3), and the host hard-codes GOAL addresses of this
   layout. The capture environment is therefore fixed: home folder of 20 characters, config path
   `/private/tmp/opengoal-ios-aot-config` (both strings sit in the GOAL heap before the engine loads, so their lengths
   move every later address), clock `OPENGOAL_IOS_AOT_CLOCK` (knuth-rand keeps the reading in its statics), and ASLR
   off (`tools/release/noaslr.c`; gk stores native pointers in GOAL memory). The capture record must equal
   `tools/aot_inputs/Jak1AOTRuntimeCapture.json`, or the build stops.
3. **game**: `OpenGOAL/goal_src` with `(mi)`, plus the `ios-*` startup objects (in no DGO).
4. **derive** into `jakIOS/Generated/` (gitignored): signed payload + tables (`aot_captured_runtime_image.py`,
   `aot_signed_text_embed.py`), stub inventory, level code (`aot_level_code_link.py` with the relink/startup lists at
   the top of build.sh), arena → `Jak1AOTRuntimeState.xd3` against the disc, `Jak1ExtractorConfig.pack`.
5. **verify**: the deterministic outputs must match `tools/release/expected-generated.sha256` (the `.xd3` is not
   compared: the arena holds gk's malloc pointers and dead stack). After an intended GOAL change, test on a device and
   rerun with `--update-expected`.
6. **ipa**: extractor library (`tools/ios_extractor/build.sh iphoneos`), unsigned Release build, `strip -S`,
   `build-release/Citadel.ipa`. `--audit` also runs the release audit on it.

`jakIOS/Runtime/Jak1AOTSignedImage.s` is hand-written source that `.incbin`s the generated payload and level code;
Xcode does not track those inputs, so touch it after they change (build.sh does). If `jakIOS/Generated/` is
incomplete, `jakIOS/Runtime/Jak1GeneratedFilesCheck.c` stops the build with an error naming the missing file (after a
clean build). To build from Xcode, run `tools/release/build.sh --no-ipa` once.

At import the app runs `Jak1LevelBuilder` (jakIOS/Import/) to write `fr3/Jak1Level-*.fr3z` into the imported
game folder, and the runtime rebuilds its arena from `Jak1AOTRuntimeState.xd3` + the disc's CGO/DGO files
(`tools/runtime_state_patch/`). Never publish `LocalGameData/`, `Parked/`, `AOTBackup-*`, `build-ios-extractor/`
or `OpenGOAL/{iso_data,out,decompiler_out,build-make}`.

## Release audit (before publishing)

`tools/release_audit/audit.py` checks that no game data from the disc is in a build or in the source. It indexes
your own extracted disc (and, with `--levels`, converted level files), scans every file at every byte offset and
fails on chains of matching data (spans of 1 KB or more, over 16 KB per file). Matches with compiled GOAL code
objects are reported but allowed: they are the static tables OpenGOAL publishes in `goal_src`, which make up the
AOT code blobs. Files kept on purpose are listed in `tools/release_audit/allowlist.json`.

    python3 -m venv /tmp/venv && /tmp/venv/bin/pip install numpy      # needs the zstd CLI too
    /tmp/venv/bin/python tools/release_audit/audit.py --disc OpenGOAL/iso_data/jak1 \
        --levels OpenGOAL/out/jak1/fr3 --app <path to jakIOS.app or .ipa>
    /tmp/venv/bin/python tools/release_audit/audit.py --disc OpenGOAL/iso_data/jak1 \
        --levels OpenGOAL/out/jak1/fr3 --source .      # the files git would publish

`--source` follows `.gitignore`; for the nested `OpenGOAL/` repository it scans only its changes against its own
HEAD (upstream files are already public; `--nested-full` scans everything). A run takes a few minutes.
Relinking level code (`OpenGOAL/tools/ios/aot_level_code_link.py`) needs `tools/aot_inputs/Jak1AOTRuntimeCapture.json`
(published) and the captured arena, which is built from your disc and never published:

    clang -O2 -IOpenGOAL tools/runtime_state_patch/xd3_tool.c -x c OpenGOAL/third-party/xdelta3/xdelta3.c \
        -w -o tools/runtime_state_patch/xd3_tool
    python3 tools/runtime_state_patch/runtime_state_patch.py decode jakIOS/Generated/Jak1AOTRuntimeState.xd3 \
        OpenGOAL/iso_data/jak1 LocalGameData/Jak1AOTRuntimeState.bin
