# STATUS — paused 2026-10-11, resume here

The user is playing the game to 100% on device to verify everything before publishing. Nothing is committed or
pushed yet; no git repository exists at the root.

Done: runtime state shipped as .xd3 patch (phase 2) · all levels built on device at import (phase 4) · ios-boat/fish/
flut/coast built on device (phase 5) · Eroded Coast parked (Parked/ErodedCoast) · intermittent "kernel dispatcher"
error fixed (AllocateGoalArena) · symbol-shadowing extraction bug fixed · release audit (tools/release_audit) ·
.gitignore files · final sweep: 272 publishable files, 0 with game data.

Kept by decision: MenuBackground.jpg, AppIcon.png, Ottselesque font (tools/release_audit/allowlist.json).

When resuming:
1. Fix anything found during the playthrough; rebuild; re-run the audit on the new .app/.ipa and on `--source .`.
2. User decides the repository layout: one repo (OpenGOAL vendored) or OpenGOAL fork + app repo (recommended).
3. Decide whether `plans` (the user's to-do file) is published.
4. Create the repo(s), commit, then publish source + IPA.
Restore point: Checkpoints/2026-10-11-pre-release/ (app source tarball, OpenGOAL patch against
opengoal-base-revision.txt + untracked files, level-code blob).

---

# Asset-free app bundle

Goal: the shipped .app contains only code compiled from OpenGOAL/goal_src + our own work. Everything derived from
the disc is generated during ISO import into the content directory.

Findings below are from 2026-10-11, checked against `OpenGOAL/iso_data/jak1` (NTSC v1).

## Inventory

| Bundled file | What it is | From the disc? | Action |
|---|---|---|---|
| `Jak1AOTImagePayload.bin`, `Jak1AOTBootstrap.bin`, `Jak1AOTSignedImage.s` | v3 (code) main segments only, built from goal_src | Code only. 254 KB of static tables (ocean-frames, mood-tables, *-part, font…) match the PS2 objects; these are the decompiled tables OpenGOAL publishes in goal_src | Keep |
| `Jak1LevelCode.bin` + manifest | Prelinked v3 level code | Code only (goal_src + our ios-* objects) | Keep |
| CodeRanges / KernelEntry / RuntimeSymbols / StartupPatches / SymbolHashes / SymbolStrings / TypeRecords / NativeStubInventory | Link metadata | No | Keep |
| `Jak1AOTRuntimeState.bin` (**done 2026-10-11**: now `.xd3`) | 128 MB captured GOAL arena | **Yes**: 4.3 MB of verbatim disc bytes (eichar, sidekick, logo, ndi, tpages, title-vis, plus stale copies in buffers) | Ship as xdelta3 patch against the user's CGO/DGO (phase 2) |
| `Jak1Level-<level>.fr3z` x 25 (~250 MB) | Decompiler level extraction | **Yes** (converted) | Generate on device (phase 4) |
| `Jak1GameMerc.bin`, `Jak1TitleMerc.bin` | Merc assets cut from GAME/title fr3 (lost /tmp tool) | **Yes** | Load from generated GAME/title fr3; delete |
| `Jak1Level-ios-boat/fish/flut.fr3z` | Model subsets of jungle/sunken/… fr3 (tools/boat, fish, flut) | **Yes** | Run the same extraction code on device after phase 4 |
| `Jak1Level-ios-coast.fr3z` | Our terrain (tools/coast) + village1 textures | Textures only | Ship `tris.bin`, build on device with coast_terrain_fr3 logic |
| `ERO.DGO` (removed 2026-10-11) | Eroded Coast | 21 art objects byte-identical to VI1/BEA/TRA/VI2/JUN/MAI/SWA/MIS/SUN/ROB; 5 goalc code objects; `eroded` bsp (4 MB) from eroded.glb | Assemble on device from a manifest (phase 3) |
| `Jak1Level-eroded.fr3z` (59 MB) + `eroded` bsp (removed 2026-10-11) | Custom level builder output from `eroded.glb` | glb embeds 145 game textures (vil1-*, cmn-*, …); geometry provenance unknown | **Decision needed**, see phase 6 |
| `PCText/*SUBTIT.TXT`, `*.xd3`, `*.json` | OpenGOAL build of community subtitles, OpenGOAL patches/text | No | Keep (ISC attribution) |
| `MenuBackground.jpg` | Sandover screenshot | **Yes** | Kept by decision (2026-10-11) |
| `AppIcon.png` | Precursor orb artwork | **Yes** | Kept by decision (2026-10-11) |
| `Ottselesque-Regular.otf` | Fan font (© Christopher Kirk-Nielsen, no licence) | No | Kept by decision (2026-10-11) |

Audio (VAGWAD/VAGDIR/SBK/MUS) already loads from the imported disc.

## Phase 1: guardrails
- `tools/audit_bundle.py`: index every disc file (32-byte windows), scan the built .app byte by byte, fail on any
  match outside an allowlist (goal_src static tables in the code payload). A prototype of this check
  (/tmp/audit_state.py) found the 4.3 MB above.
- Import: identify the disc version by the GAME.CGO hash. Every patch below is against NTSC v1 bytes, so other
  regions get a clear "unsupported disc" error until we have patches for them.

## Phase 2: runtime state -> xdelta3 patch — DONE 2026-10-11
- Bundled: jakIOS/Runtime/Jak1AOTRuntimeState.xd3 (1.1 MB). Host LoadValidRuntimeState(contentPath) rebuilds the arena at
  boot (host init now takes contentURL); CRC-checks each source; wrong disc -> NTSC v1 message. Tool:
  tools/runtime_state_patch/ (xd3_tool.c + runtime_state_patch.py encode/decode). The .bin moved to LocalGameData/
  (never publish). Verified: Mac harness of the real loader rebuilds the arena byte-exact in 0.4 s. Untested on device.
- Proof of concept done (/tmp/xdpoc): source = KERNEL.CGO + ENGINE.CGO + GAME.CGO + TIT.DGO from the disc,
  target = decoded 128 MB arena, `xd3_encode_memory(COMPLEVEL_9 | NOCOMPRESS)`.
  Patch is 4.7 MB raw / 1.1 MB deflated; decodes byte-exact in 0.3 s; 0 disc 32-byte windows in the patch
  at byte stride.
- Packer: new `aot_runtime_state_patch.py` (or a C helper like the PoC) writes `Jak1AOTRuntimeState.xd3`
  (header: magic, target size, target CRC32, source file list + CRCs).
- Host: `LoadValidRuntimeState` builds the source from the content directory's CGO/DGO files, calls
  `xd3_decode_memory` (already compiled in via Jak1XDelta3.c), keeps the CRC check.
- Everything that currently produces Jak1AOTRuntimeState.bin (level-code relinks read it) keeps the .bin as a
  desktop-only input; only the .xd3 goes in the target.

## Phase 3: ERO.DGO assembled on import
- Ship the 5 code objects + a manifest (order, name, source DGO, size, sha1 of each art object).
- GameContentStore replaces `installBundledExperimentalLevels` with an assemble step (DgoWriter format:
  u32 count + 60-byte name; per object u32 size + 60-byte name + data, 16-aligned).
- The `eroded` bsp object depends on phase 6.

## Phase 4: FR3 extraction on device — DONE 2026-10-11 (untested on device)
- jakIOS/Import/Jak1LevelExtractor.cpp (minimal-mode extraction, one ObjectFileDB per level: GAME.CGO + that DGO)
  + Jak1LevelBuilder.mm (unpacks Jak1ExtractorConfig.pack, extracts, converts zstd .fr3 -> LZFSE .fr3z into
  <content>/fr3/, marker .jakios-levels-v1). ContentView/GameContentStore run it at import and once on launch for
  older imports ("BUILDING LEVELS n/25"); the runtime only starts after.
- Library: tools/ios_extractor (CMake, sources read from OpenGOAL's common/decompiler CMakeLists; repl/sockets/
  sqlite/dialogs/term_util/decompilation_process/streamed_audio excluded, ios_stubs.cpp; no Draco).
- Verified on the Mac: output equals stock decompiler output except uninitialized struct bytes (proved with
  MallocScribble runs: 0 unexplained bytes); 15 s for all levels; real working set ~313 MB (macOS's large-allocation
  cache inflates footprint to ~1.2 GB there; the device log prints footprint/peak per level).
- Removed from the bundle: 25 level fr3z, test-zone fr3z (custom level, not on the disc), Jak1GameMerc/TitleMerc.bin
  (renderer now takes title/GAME Merc from their FR3; title inserted first). Copies in LocalGameData/bundled-levels.
- Determinism note: run-to-run differences are uninitialized padding only (sizes identical).

### Original notes
- Desktop timing: the OpenGOAL decompiler extracts all 25 levels in ~3 s with a 1.8 GB peak RSS (all DGOs loaded
  into one ObjectFileDB). On iPhone, expect tens of seconds; run one level at a time to keep memory down.
- Build `common` + the `decomp` subset (ObjectFileDB, linker, TypeSystem/all-types.gc, TextureDB/process_tpages,
  level_extractor) as an iOS static library via CMake (iOS toolchain). Stub out desktop-only deps (replxx,
  tinyfiledialogs; check whether tree-sitter/sqlite are reachable from this path). Ship all-types.gc +
  jak1_config.jsonc + game/assets texture_merges (OpenGOAL repo files).
- Import step "Building levels…" with progress; write `<content>/fr3/<level>.fr3z` (or read .fr3 directly).
  Jak1Background.mm / Jak1MetalRenderer.mm look in the content directory instead of NSBundle.
- **Determinism check first:** a fresh desktop run on 2026-10-11 produced different bytes than the existing
  out/jak1/fr3 (sizes off by up to ~0.5 MB; the originals were restored from /tmp/fr3backup). Find out whether that
  is config/version drift or nondeterminism, and confirm the renderer (merc mod layout checks, TIE/tfrag) works with
  freshly extracted files before porting.

## Phase 5: our derived fr3s on device — DONE 2026-10-11 (untested on device)
- jakIOS/Import/Jak1CustomLevelBuilder.cpp builds ios-boat/fish/flut/coast into <content>/fr3 right after the level
  extraction (marker .jakios-custom-levels-v1; older imports only run this step). tools/boat, fish, flut deleted.
- Coast ships as jakIOS/Import/Jak1CoastTerrain.fr3z (tools/coast/coast_template.cpp: our terrain + draw modes +
  texture names; pixels and time-of-day colors removed), refilled from the extracted jungle level.
- Verified on the Mac: ios-coast byte-identical to the old bundled file; boat/fish/flut differ only in uninitialized
  padding (13-43 bytes). Template audit: its only converted-level matches are index counters + 32 bytes of names.
- The app bundle now holds no level data (162 MB).

### Original notes
- Move tools/boat, fish, flut extraction into a small C++ step run after phase 4 (they only need Tfrag3Data +
  Serializer).
- Coast: ship `tris.bin` (our data), run the coast_terrain_fr3 packing on device against the generated village1 fr3.

## Phase 6: Eroded Coast built at import
**2026-10-11: the user removed Eroded Coast from the build for now** (parked in Parked/ErodedCoast, README has restore
steps). Revisit this phase only if it comes back.

Tested 2026-10-11: an xdelta of eroded.fr3 (180 MB raw) against the raw game fr3s is 162 MB, so patching is useless.
The level must be built from shipped original inputs + the user's disc.
- eroded.glb = 98 MB geometry + 5.2 MB of 145 embedded PNGs named after game textures (vil-*, vil1-*, cmn-*…).
  Most meshes are hand-made (Plane/Cube/Circle/coastline/rockwall…), but `medres-misty-lod0`, `medres-training-lod0`,
  `medres-firecanyon` (and possibly `Mesh_*`) look like ripped game meshes.
- Option A (recommended, no builder port): ship eroded.fr3 with texture pixels removed (keep names/sizes) + the
  `eroded` bsp object; at import fill textures by name from the user's texture DB (phase 4), copy the 21 art
  objects from the user's DGOs, assemble ERO.DGO.
- Option B: port goalc/build_level (~3k lines; uses the same ObjectFileDB/TextureDB/extract_merc as phase 4) and
  build eroded.go + eroded.fr3 on device from a stripped glb + jsonc + rockfall.glb.
- Either way the ripped meshes must come out of the shipped data: remove them from the glb, rebuild, and either
  re-add them at import from the user's generated fr3 or drop them.
- Geometry check (2026-10-11, provenance unknown to the user): every glb mesh compared with the decompiler's
  rip_levels export of all 24 levels, using edge-pair signatures (5 side lengths, 5 cm bins, Draco-decoded), against a
  control of the same mesh jittered 8 cm (= chance level). Scripts: /tmp/meshmatch_lib.py, /tmp/pairmatch.py.
  - Clear rips (match far above chance): medres-misty-lod0 (68% vs 0%), medres-training-lod0 (82% vs 0%),
    periscopebase x6 / Mesh_3.* (82% vs ~22%), OOB.001 / Mesh_2.002 (61% vs 0%), waterfallOOBfix / Mesh_0.001
    (23% vs 1%), medres-firecanyon-lod0 (16%, named after game art).
  - Partial, look at these in Blender: beach (24% vs 7%), OOBHEXAGON.002 (34% vs 11%), rocktufts / Mesh_237 (29% vs 11%).
  - Everything else (rockwalls, mountain range, cave, coastline, hexagons, grass, lighthouse…) matches at chance
    level; OOBvil1 / Mesh_48 5% vs 4%. Under 3% of the level's geometry is flagged.
  - Limits: can't detect ripped geometry that was remeshed, sculpted or scaled, and can't prove anything is original.
- Custom music (custom_assets/jak1/audio/sound_replacements/eroded_coast_*.mp3): check provenance too.

## Phase 7: clean-up
- Remove the files listed above from the target, replace MenuBackground + AppIcon, run audit_bundle.py on the
  archived .app.
