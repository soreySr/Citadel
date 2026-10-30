# Brume Village mod levels (publishable, built at import)

User request 2026-10-27: add the community mod "Brume Village" (https://github.com/Cuttlefishthesage/BrumeVillage,
OpenGOAL mod base fork, ISC) the way Glacier was added (glacier-plan.md): no game data ships, the levels are built on
the device at ISO import. Copies: LocalGameData/brume/mod-original (full git history; never publish).

## STATUS

- 2026-10-27: all phases BUILT (app builds; Mac-verified builder + pack + DGOs; UNTESTED on device). Next: device
  import (watch "mod level <name>" footprint lines and "GOAL heap block ... left"), Experimental Options > BRUME
  VILLAGE on, warp gate slot 6 ("YELLOW SAGE'S HUT") from any gate, play the four levels.
- Biggest risks: import memory (Abandon peaks 2.6 GB on the Mac, inside gltf_mesh_extract; Glacier was 0.9 GB);
  level heaps now 14 MB each (BRU 11.1 MB, ABA 11.2 MB DGOs) from the 55 MB host bump heap; renderer memory with two
  ~220 MB (raw) fr3s loaded at once.
- tools/release/expected-generated.sha256 was updated by the build (--update-expected) before the device test.

## The mod

- Four levels, one connected area at x -2030..-1040 m, z -1060..1230 m, y 20..385 m (high above the sea west of
  Geyser Rock, kept where the author put it): brume (village hub, 253 actors), abandon (caverns, 445), mount
  (mountain range, 466), preundg (precursor underground, 343). Load boundaries link them (load-boundary-data.gc).
- 28 tasks (mod 116-143) -> ours 123-150, max 151 (glacier keeps 116-122). Text ids are the mod's (#x4620-#x4648,
  #x102); option row BRUME VILLAGE 0x1677. Level-info indices 29-32, progress pages 18-21 (115/200/215/215 orbs,
  7 flies each, outside the stock 100%).
- Custom models test-actor2 (brume), gravityswitch (abandon, preundg), ambushdoor (preundg): goalc build-actor.
- glbs are KHR_draco compressed: tools/modlevel/glb_undraco decodes them before packing (shipped glbs are plain).

## What was done

1. Builder (Jak1ModLevelBuilder.cpp): custom_models (add_model_to_level with recipe images/geometry),
   BuildModLevelActor (run_build_actor, :gen-mesh #t), AssembleModLevelDgo takes built art groups. Recipe images gain
   "from" (channel source: Blender metallic-roughness = texture alpha in blue). gltf_mesh_extract maps the glb.
   pack_helpers assert relaxed like the mod base (diff < 32587). Import (Jak1LevelBuilder.mm): models first, then
   glacier + 4 levels; marker .jakios-mod-levels-v3.
2. Pack: jakIOS/ModLevels/Brume (71 MB). See tools/modlevel/README.md.
3. GOAL: tasks/text/all-types, level-info (music bank 'jungle instead of the mod's mp3s), task-control (28 entries +
   *oracle-brume-tasks*), progress-static pages + remap, entity.gc nav meshes (70500-, 80500-, 90500-),
   load-boundary-data (mod's file; now relinked: RELINK_CAPTURED), level code levels/{brume,abandoned,mount,preundg}
   (mp3 calls dropped, forward decls), level-code edits made conditional on the Brume levels (minecart, pontoon,
   flutflut, battlecontroller; ecoventrock hit-by-others; oracle cases), warp gate slot 6 (villagep-obs, basebutton,
   target-death), level heaps 14 MB (level.gc). pc/ios/ios-brume.gc (startup object, after ios-glacier): game counts,
   page opening, vol lumps without time stamps ('base fallback; also fixes Glacier's water vols), yellow vent block
   task, water-anim bounds x10, big collide cache while in, village1/snow held back while in. Ocean manager and Open
   Ocean code skip while a Brume level is loaded (ios-brume-here?).
4. Host: option row (experimental.brumeVillageEnabled), SyncBrumeLevelOption -> *ios-brume-warp*, BrumeLevelsBuilt,
   GOAL heap block log, PC text marker v18.

Not taken: the mod's new game at brume-warp, its mp3 music/voices (mod-base play-sound-file / play-main-music),
slower plat-buttons in brume/preundg, jungle water ripple / jungle particle tweaks (they change stock jungle).

## Audio (2026-10-27)

Checked every mod audio file against the disc (OpenGOAL's rip of VAGWAD voice lines / SFX, and its 989snd render of
every music bank and flava; band-energy fingerprints, /tmp/brume-dev/cmp):
- fishies.mp3 = FIACCEPT 2.9886 s + 3.797 s at 0.241; muskratstew.mp3 = YERESOLU 18.2394 s + 1.920 s at 0.247
  (0.99 correlation): played from the player's disc at runtime (Jak1AudioManager playModClipFromVAGNamed).
- juntemp(rep) = a recording of JUNGLEB (0.85; an exact re-encode scores 0.98): preundg's music bank is 'jungleb.
- jungsun, junsynth, junrav (and their loops) and musesteps.mp3 match nothing on the disc (<= 0.37, junrav ~0.7
  against many unrelated tracks): the author's own or from elsewhere. Not shipped; ask Cuttlefishthesage.
Player: ios-brume.gc publishes *ios-brume-music* / -gain / -clip / -clip-seq; OpenGOALRuntimeHost.mm SyncBrumeAudio
plays brume-music.m4a / abandon-music.m4a / mount-music.m4a and brume-musesteps.m4a from the app bundle if present
(drop them into jakIOS/ModLevels/Brume once permitted) and mutes the bank music meanwhile (jak1sound::SetMusicMuted).
- 2026-10-27 (user): the mod's tracks and muse steps ARE bundled now for personal use (jakIOS/ModLevels/Brume/
  brume-music.m4a, abandon-music.m4a, mount-music.m4a from the *rep.wav loops, brume-musesteps.m4a; AAC). NOT
  cleared for distribution: ask Cuttlefishthesage before publishing, or delete these four files (the code falls back
  to the music banks).
