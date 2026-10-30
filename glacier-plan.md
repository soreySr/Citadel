# Glacier mod level plan (publishable, built at import)

User request 2026-10-27: add the community level "Glacier" (https://github.com/Cuttlefishthesage/OG-Mod-Base-Glacier,
OpenGOAL mod base fork, ISC) the way Eroded Coast was added, but publishable: the app ships no game data, the level
is built on the device at ISO import with goalc's custom level builder ported into the import library. This also
makes later mod levels a data drop (jsonc + stripped glb + recipe).

## STATUS

- 2026-10-27: phases 0-5 BUILT (app builds; Mac-verified builder + pack; UNTESTED on device). Next: device import
  (watch the "mod level glacier" footprint log lines), Experimental Options > GLACIER LEVEL on, warp from any gate
  (slot 5), play through; then `tools/release/build.sh --update-expected`.
- Decisions taken without the user (revisit if wanted): reached only by warp gate slot 5, from any gate, while the
  GLACIER LEVEL option is on (no story gate); the mod's new-game start at glacier-warp not taken; glacier page,
  orbs and cells are a bonus outside the stock 100% (like the Open Ocean); level bsphere made finite
  (y 20 z 1740 r 450 m) instead of the mod's infinite one; its first cell keeps the vanilla, otherwise unused
  red-eggtop task (the red vents' block is hard-coded to it).

- 2026-10-27 device run: import built the level and warping in worked. Fixes: the bundled glb is a plain zstd frame
  (crash: OpenGOAL's decompress_zstd wants its size prefix); swimming in the glacier counted as open sea for the
  boat's ocean manager, which streamed village1 in beside it -> crash in adgif_shader_texture_with_update (both
  levels carry the same village1 tpages; a mod level must never share the level slots with the level it copies
  tpages from). First fix (ocean code off while 'glacier is loaded) replaced by the boat support below.

- 2026-10-27: reachable by boat (user). fishermans-boat.gc: IOS_SEA_GLACIER_* (centre 0/1750, shore 300 m), a
  north pair Misty + Glacier within 500/600 m of its centre (ios-ocean-update-north-levels), arrival / back-on-land
  'glacier (glacier + misty, respawn glacier-start), shark death respawn there, sea edge north margin 200 m (was
  500: the boat stopped at z 1804) while it is available. ios-open-ocean: zone 8 GLACIER (r 320 + margin), no
  storms inside its territory. ios-glacier-guard-levels holds back a not-yet-loaded village1 while the glacier is
  loaded and restores the request once it is gone. All only while *ios-glacier-warp* (built + option on).
  Pop-in fix (user 2026-10-27): the pair now starts when Misty shows in full at sea (within 660 m of Misty's centre,
  leave 760 m) or within 600 m of the glacier, so the glacier streams in while Misty is approached; Sandover
  unloads then (no stand-in of it from there). Docking at Misty (arrival zone) is still stock Sandover + Misty.

- 2026-10-27 MOVED (user): east of the coast, halfway Sandover -> Rock Village. glacier.jsonc "ios_offset"
  [1050, 0, -2550] is applied at import by Jak1ModLevelBuilder (glb scene roots; actor / ambient trans, bsphere, paths,
  movie-pos, vol planes w += n.offset); verified on the Mac: collision now x 899..1290, z -1176..-530. Moved by hand:
  level-info glacier continues + bsphere (1095 / -850, r 460), and the mod's custom nav meshes (entity.gc aids
  50000-52000, ported now, replacing Eroded's 51000/51100/52000: they were missing before, so glacier enemies had
  none). Import marker .jakios-mod-levels-v2 rebuilds it. Sea: the Misty pair is gone; inside a white fog ring
  (IOS_GLACIER_FOG_RING 640 m from 1095 / -850) the pair is Glacier + the nearer of jungle / Rock Village, entering
  at 690 m and leaving at 725 m, i.e. only in thick fog; the fog is held full until the glacier is active. White
  clouds stand on the ring (ios-glacier-fog-bank-update); the Rock Village fog bank (whose band the glacier sits in)
  is kept out of the ring. Open Ocean zone 8 + ios-ocean-in-glacier? moved. North sea-edge relaxation removed.

## The mod (what is in it)

- `custom_assets/jak1/levels/glacier/`: glacier.glb (70 MB, 300 meshes, 827k tris, 78 embedded images),
  glacier.jsonc (259 actors, base_id 45000, sky + tex_remap village1, textures village1-vis-alpha, 23 art groups),
  glacier.gd (GLA.DGO: ~25 code objects from other levels + 30 art/tpage objects + glacier.go).
- `goal_src/jak1/levels/glacier/glacier.gc` (eggtop-red, glacier-iris-door, yeti-glacier + slave,
  glacier-battlecontroller), plus engine edits: game-task 116-122, text ids #x2100-2106, level-info `glacier`
  (index 24, snow mood/sound, 5 checkpoints at z 1500-2000 m, x +-150 m: open sea far from everything),
  progress page 16, 5 checkpoint load boundaries, warp gate slot 5 ("glacier-warp", unlocked by glacier-button or
  finalboss-movies), snow weather (powerups.gc), game-counts 101 orbs / 7 scout flies, and every new game starting
  at glacier-warp (not taken).
- Mod bug: its all-types.gc has glacier-button 123 (game-task-h 122). jsonc never uses glacier-button.
- Its first cell uses the vanilla (unused in vanilla) task red-eggtop; the red vents' vent-blocked check is
  hard-coded to red-eggtop (collectables.gc), which is why.
- Copies: LocalGameData/glacier/mod-original (never publish), reference outputs LocalGameData/glacier/glacier.{go,fr3}.

## Phase 0: desktop reference — DONE

goalc's standalone build_level tool (`make build_level` in OpenGOAL/build-make), run from a scratch project
(/tmp/glacier-ref: decompiler config copy with Eroded's task slots renamed to the glacier tasks, iso_data, game,
goal_src/jak1/build symlinks; exe copied next to a `data` symlink). 3.2 s, 1.9 GB peak (all DGOs in one DB).
glacier.go 7.2 MB, glacier.fr3 33.8 MB (120 MB raw: collision mesh 52 MB, textures 31 MB, tfrag 27 MB).
Two goalc runs differ only in the bsp's timestamp and uninitialized bytes (hfrag fields, collision pad2, ~39 merc bytes).

## Phase 1: builder port — DONE (Mac)

- tools/ios_extractor/CMakeLists.txt also builds goalc/build_level (common, jak1, collide/jak1) + MercExtract +
  DataObjectGenerator.
- jakIOS/Import/Jak1ModLevelBuilder.cpp: run_build_level's steps with the disc read one archive at a time (GAME.CGO +
  one DGO; archives picked by header names), per-DGO art groups / sky / remap in config order, the "textures" list
  resolved over the archives loaded. Zeroes the fields goalc leaves uninitialized.
- OpenGOAL patch: gltf_mesh_extract::Input gains image_loader (tinygltf image callback).
- Verified: same output as goalc for the original glb (bsp: timestamp only; fr3: only the known uninitialized
  bytes). 4.6 s on the Mac, 15 archives loaded. Harness: /tmp/glacier-dev/modbuild + fr3cmp (canonical compare).

## Phase 2: strip the glb — DONE (tools/modlevel, see its README)

Survey of glacier.glb (2026-10-27):
- Images: 71 of 78 are byte-identical to disc textures (by id) -> filled from the disc. Two are disc textures with
  a channel overwritten (snow-ice-transparency = snow-ice with alpha 102; image 4 = jngb-precursor-metal-plain-01
  with R=G=A=255) -> filled from the disc + channel override. LeafyGround_Realistic_Snow_Brighter is the mod's own
  (no disc match) -> stays in the glb. bam-*/programmer_eye are only used by jak4reference (invisible).
- Ripped geometry (edge-pair signatures at 5 mm vs 2 cm-jitter control, then rigid fits): jak4reference
  (finalboss Jak, invisible), sharkey-lod0, orb-cache-top-lod1, pusher-lod0 x4, precurbridge-geo x4 (jungle merc),
  redecovent x4 (snow TIE), thirdarealauncher.001/.002 (beach launcher TIE), eggtopbase/eggtopplat (jungleb TIE,
  partly edited), snow-bumper-lod0.001 (3 bumpers merged). Several have collision (bridges, launcher, vents, eggtop),
  so they can't be dropped. Everything else matches at chance level.
- Plan: a Mac tool (tools/modlevel) finds, per rip vertex, the game vertex it came from (piecewise rigid fit),
  zeroes that data in the shipped glb and writes a recipe; at import the builder refills positions / uvs / colors
  from the player's extracted level fr3s (Jak1Level-*.fr3z), normals recomputed. Vertices the author edited keep
  their glb data. Index buffers stay (topology only).

## Phase 3: GLA.DGO at import — BUILT
Jak1ModLevelBuilder.cpp AssembleModLevelDgo, called from Jak1LevelBuilder.mm (marker .jakios-mod-levels-v1) after the
level extraction; also writes fr3/Jak1Level-glacier.fr3z. Mac check: all 30 art objects found, 10.6 MB DGO.
Code objects are never executed from a DGO (Jak1Kernel links the prelinked copy by name), so the import writes
stub code objects, copies art/tpage objects from the player's DGOs by name, and appends the built glacier.go.

## Phase 4: GOAL integration + relink — BUILT
Done: Eroded's task slots / text ids (#x4000-4006) / level-info index 28 / task-control entries now Glacier's
(all-types.gc too, so the import's builder knows the task names); progress-static: 16 = Open Ocean placeholder,
17 = Glacier; levels/glacier/glacier.gc (mod, unchanged); villagep-obs slot 5 (skips closed slots);
basebutton *warp-info* + 'glacier; target-death glacier-warp case; pc/ios/ios-glacier.gc startup object (LAST):
grows task-perm-list + fuel-cell-time to 123 (captured with 116: tasks 116+ would have written past them), repairs
the length after loading older saves, *game-counts* copy with entry 17 (101/7), snow, *ios-glacier-warp*.
ios-open-ocean keeps the page count and opens page 17. Relink adds --relink-captured basebutton target-death,
--startup-object ios-glacier, --extra-dgo-dir jakIOS/ModLevels (tools/release/build.sh updated). Backup of the
previous level code: AOTBackup-2026-10-27-preglacier/.
glacier.gc; reuse Eroded's dormant task slots 116-122 (renamed; max stays 123, so the captured image is fine;
saves that played Eroded would show those flags as glacier progress); level-info index 29; progress page 17
(Open Ocean owns 16); text ids; warp gate slot 5; snow weather; game-counts. Relink (startup objects as usual).

## Phase 5: host — BUILT
Experimental Options row GLACIER LEVEL (text 0x1676, copy of the green-eco row, experimental.glacierLevelEnabled),
SyncGlacierLevelOption writes *ios-glacier-warp* = option && level built. PC text marker v17.
Experimental option (or warp gate only), canLoadDgo, PC text, renderer picks up Jak1Level-glacier.fr3z, import
marker bump, device memory check (Mac peak 0.9 GB incl. macOS allocator inflation).
