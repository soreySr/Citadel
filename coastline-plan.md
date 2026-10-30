# East coastline plan (Forbidden Jungle -> Rock Village)

User request 2026-10-21: the east coast between the Forbidden Jungle and Rock Village was never meant to be seen.
With the free / driveable boat and the Open Ocean it needs real-looking cliffs, no empty gaps, collision, earlier
streaming of Rock Village + Boggy Swamp, and a fog bank that hides the north -> south level hand-over.
One phase per build/test cycle. Update STATUS as phases land.

## STATUS

- 2026-10-21: plan written. User decisions: rock type follows the nearest level (jungle rock near the jungle,
  Rock Village rock near Rock Village, switching where they get close); no standing on the cliffs (boat blocked,
  Jak slides off into the water); no pine trees / foliage, bare rock only.
- 2026-10-21: Phase 0 offline survey DONE (findings below). Device part BUILT, waiting for a device run: host logs
  `[sea-survey screenshot]` on every screenshot and prefixes level streaming lines with `[sea-survey level]`
  (time, Jak + camera position, camera forward). The yellow-circle screenshots are enough for placement (their
  views reproduce offline with coast_survey), so no survey run is needed before phases 1-3; the load timings
  only feed phase 4 and come from any device run once that code exists.
- 2026-10-21: Phase 1 BUILT (app builds; verified offline, nothing drawn in game yet). Import now also writes
  `Jak1Level-ios-coastrock.fr3z` (custom levels marker v10): `BuildCoastRockLevel` in Jak1CustomLevelBuilder.cpp,
  5 chunks = 5 tfrag trees in this order: jungle-a, jungle-b, village2-a, village2-b, village2-c (9.9k / 10.0k /
  16.3k / 27.5k / 10.7k tris; 74x87, 69x84, 107x60, 117x113, 90x55 m footprints). Chunk-local: origin at sea level
  under the footprint centre, +z = the sea side. Rock-kit TIE (proto whitelist `IsRockKitProto`, base draws) +
  rock/beach tfrag by texture, each triangle keeps its own source palette colours. JC dropped (floats ~20 m up).
  Mac check: /tmp/coastrock/harness (main.cpp calling BuildCoastRockLevel on bundled jungle + village2, 0.2 s),
  then `coast_survey view ... +tree=N` from local (0, 6, 170) yaw 180. Look: jungle-b has gaps at the waterline
  and village2-c an arch -> back-row / variety pieces; jungle-a, village2-a, village2-b are solid front pieces.
  Cut sides are open (hollow), so phase 2 must overlap neighbours.
- 2026-10-21: Phase 2 BUILT (app builds; layout verified offline with coast_survey, UNTESTED on device). Custom
  levels marker v11. `BuildCoastLevel` now writes `Jak1Level-ios-coast.fr3z` itself (the coastrock library file
  is gone): 4 solid chunks (jungle-g 420/-230..530/-150, jungle-e 440/-290..530/-205, village2-a, village2-b capped
  at 45 m), `CullHiddenTris` per chunk (depth/id raster from 66 sea-side views; only 4-20 % hidden: the kit is
  mostly shell), `LayOutCoast` two rows - east face x 478 z -385..-1405 (to the open sea), west face
  (392,-392)-(300,-480)-(300,-1200)-(205,-1395) (Fire Canyon channel) - spacing 0.7 / 0.72 of a chunk's width,
  scale 0.95-1.25, yaw jitter 12 deg, random mirror, fixed seed; jungle rock north of z -820, Rock Village rock
  south of -940, mixed between. Result: 30 copies, 419k triangles, 399k vertices (shared per copy), 3 trees
  sorted by z, 2.9k colours, 4 textures, 14.9 MB file, ~1.2 s on the Mac.
  Dropped: holey chunks (jungle-b, jungle-f, village2-c showed open sea through caves) and a ridge row (+60k tris,
  barely visible). Removed: old template `jakIOS/Import/Jak1CoastTerrain.fr3z`, FillCoastFromJungle,
  tools/coast/coast_template.cpp + coast_terrain_fr3.cpp (green top and flat slabs gone); BuildCustomLevels lost
  its template argument.
  NOT done: Rock Village ocean-map land tiles (black line) - the east face now hides them from the open sea; the
  zeroing needs an ocean-tables relink, left until the device test shows it is still visible.
  Known until phase 3: collision is still the old terrain's `*ios-coast-heights*` grid (rock front can stand
  ~10 m past it). Device checks: frame time with +419k triangles drawn every frame (no culling yet), memory,
  load time of the 15 MB file when the coast first appears (async, pops in once), colours at night / storms.
- 2026-10-21: Phase 3 BUILT (app builds, level code relinked; UNTESTED on device). Custom levels marker v12.
  - Import: `WriteCoastHeights` -> `Jak1Level-ios-coast.heights` (160 KB): 2 m grid x 140..640, z -1560..-280,
    max rock height per cell from every placed triangle sampled at 1 m (rock below -2.5 m ignored); inside of the
    coast filled at 40 m (flood of the sea from the border over cells 2 cells clear of rock, rows' open ends
    capped at (392,-392)-(478,-385) and (205,-1395)-(478,-1405), then the sea grown back 2 cells to the rock).
    Result 29k rock + 14k inside cells. Preview of the grid: /tmp/cs/grid.png (python in the session notes).
  - GOAL (fishermans-boat.gc): the static 64x160 `*ios-coast-heights*` and IOS_COAST_* constants are gone;
    `(define-perm *ios-coast-grid* pointer #f)` + `ios-coast-height` reading the header. `ios-ocean-update-coast`:
    Jak in the rock (y + 0.5 m below its height, not on the boat) is moved out down the grid's slope at
    IOS_COAST_SLIDE_SPEED 8 m/s and his velocity into it is replaced by 8 m/s outward, so he drops into the water
    (user: no standing on it); deep inside where the grid is flat he goes back to the last spot outside. The
    boat's shore probe is unchanged (now reads the new grid).
  - Host: `LoadCoastGrid` (OpenGOALRuntimeHost.mm), called once from SyncDriveableBoatOption with the option on:
    reads <content>/fr3/Jak1Level-ios-coast.heights into the global bump heap and sets the symbol (logs
    "east coastline: collision grid 250 x 640").
  - Relink: incremental goalc in build-release/game (fishermans-boat.o + startup objects), aot_level_code_link.py
    with build.sh's RELINK_CAPTURED / STARTUP_OBJECTS (reproduced the shipped blob byte-for-byte first), 2889
    symbols. Backup: AOTBackup-2026-10-21-coast/. opengoal.patch saved (`bash tools/opengoal/opengoal.sh save`).
    tools/release/expected-generated.sha256 NOT updated yet (after the device test: build.sh --update-expected).
  - Removed tools/coast terrain.py, fill.py, preview.py (old terrain + grid generator).
  Device checks: boat stops at the rock along both faces and at the gap (no clipping ~10 m in any more); swim into
  the face -> pushed back out and down into the water; jump at it from the boat -> slides off; nothing blocks the
  open sea; Fire Canyon channel still navigable. Next: Phase 4.
- 2026-10-21 device feedback (IMG_2597-2600): rock too far back, "layer of green over it", darker section looks
  strange; vision = one straight natural line of rock from the jungle to Rock Village. Found + fixed (BUILT,
  custom levels marker v13, UNTESTED on device):
  - The green layer is STOCK: Sandover's LOWRES background tree (and training's copy) holds a low-detail
    stand-in of the jungle + east coast land (`vil1-medres-grass` plateau, x 100..560, z -120..-1450, 19-86 m
    high, + `vil3-lores-treetop`), drawn even with the jungle loaded. `SplitCoastBackdrop` (builder) moves its
    triangles with centres at x 60..700, z -340..-1460 out of village1's / training's lowres trees (987 / 843 tris;
    Rock Village's `v1-lores-vil2-wall` stand-in south of -1460 stays) into Jak1Level-ios-backdrop-village1/
    -training.fr3z; Jak1Background draws those only while the coast is hidden (option off / Fire Canyon / title),
    so the stock view is unchanged without the boat. Idempotent (a split level has nothing left to move).
    NOTE: this rewrites Jak1Level-village1.fr3z and Jak1Level-training.fr3z in the fr3 directory at import.
  - East face moved out to x 508 (flush with the jungle's own sea cliffs ~520) and made one straight line
    z -360..-1415; yaw jitter 6 deg, inset jitter +-3 m. Caps of the collision flood moved with it.
  - The dark section was the Rock Village rock half of the coast (from z -820). Now jungle rock all the way to
    z -1220, mixed to -1320, Rock Village rock only for the last stretch next to Rock Village itself.
  - Result: 33 copies, 378k triangles. Offline views: /tmp/cs/um.png.
- 2026-10-21 device feedback 2 (IMG_2601-2605): fragments sticking out, holes showing the bare sea / ocean
  edge, floating green left. Fixed (BUILT, custom levels marker v14, UNTESTED on device):
  - Floating green = village1's TIE `v1-lores-trees.mb` (far tree tops). SplitCoastBackdrop now also moves those
    instances over the coast (per matrix group = instance; 3360 tris) into the backdrop (as tfrag) and hides them in
    the level (instance matrix -> zero at y -1e8 m). Training has none.
  - Shards: chunks take whole kit pieces only (piece in when its centre is in the box; pieces = BVH vis index),
    and no beach tfrag (flat sand blades at the waterline).
  - Holes: a second east row ((478,-400)-(478,-1395), scale 1.0-1.15, spacing 0.85) behind the sea face, and a
    plain rockwall "curtain" (18-26 m high, 4 m texture repeat) 45 m behind the west face.
  - Collision: the flood fill leaked through the shell's gaps once pieces were whole; replaced by a land polygon
    (392,-392)(500,-362)(500,-1413)(213,-1393)(308,-1200)(308,-480) filled at 40 m (+ rock heights outside it).
  - Result: 40 copies, 481k triangles (up from 378k: watch frame time), 435k vertices.
- 2026-10-21 device feedback 3 (IMG_2606-2608). BUILT, custom levels marker v15, UNTESTED on device:
  - Gap by Rock Village (2606) = the hollow between the rows + a narrow channel between the coast's south end and
    Rock Village's north rocks, seen from the Fire Canyon channel. New row across the south end facing Rock
    Village ((215,-1428)-(500,-1436), set into RV's north ring; RV's bay + dock at (317,-1571) open to the east
    stay clear), and the west back wall continues behind it to (470,-1392).
  - Green piece floating (2608) = the JUNGLE's own grass hill at its north-east (x 390..500, z -90..-170); it has
    walkable floor collision under it (jungle terrain), so it was NOT removed (Jak would walk on invisible
    ground). It looked floating because of caves beneath it: fixed with the next item.
  - Holes under the green by the secret cell platform (2607): a low row of jungle rock along the jungle's own
    east shore ((530,-40)-(530,-375), scale 0.55-0.7) fills the caves you could see / sail under; the hills stay
    visible above. The green slab above there is village1's lowres stand-in (x 440..540, z -260..-350), kept as
    asked (move the split box's z limit to -240 to drop it). Collision grid now z -1560..+40 (nz 800).
  - Second east row thinned (spacing 1.05) to pay for it: 49 copies, 605k triangles, 551k vertices.
- 2026-10-21 user: "why a second row?" -> tried one solid front row instead. BUILT, marker v16, UNTESTED:
  - coast_survey `holes` (+top=<m>): rays from 354 boat-route views that cross the coast's land below <m>
    without hitting chunk rock. Builder macros JAKIOS_COAST_SEED / _EAST_SPACING / _NO_CURTAIN for the offline
    search (/tmp/coastrock/search.sh).
  - Chunk bases within 1.5 m of the sea pulled 5 m under it (slits under the rock showed the water behind).
  - Findings (+top=30, no back wall): old two rows 605k tris / 48.9k hole px; one row at 0.65 497k / 56.4k
    (the jungle chunks are pillars: gaps between them at 10-30 m, the back wall showed flat there); one row at
    0.45 610-627k / 35.9-39.4k. So a single row is not cheaper for the same fill - only denser.
  - Chosen: one east row, spacing 0.45, seed 0x2468ace (fewest gaps), second row removed; back wall now on the
    east too (45 m in), bumpy 4 m grid with vertical grain, 26-34 m top, as a safety net. 49 copies, 633k tris.
  - The real saving is phase 6: split the coast into stretches and skip the ones off screen / far away.
- 2026-10-21 user decision: back to normal spacing (0.7, seed 0x51c0a57) + the second east row; holes in the
  first face are invisible walls. BUILT, marker v17, UNTESTED: east back wall dropped again (west + south only);
  collision = land polygon behind the first face (x 500 inward, solid) + new thin wall x 521..528 along the
  jungle's own east shore z -375..-40 (in front of its caves; the jungle ground behind keeps its own collision).
  Kept from the previous try: chunk bases pulled 5 m under the sea. 49 copies, 608k tris.
- 2026-10-22 (screenshot by Rock Village's bay): gap between the east face's end and Rock Village's north-east
  rocks, seen from the bay. New short row (512,-1415)-(512,-1495) facing east; bay mouth (z -1500..-1600) and
  dock stay open. BUILT, marker v18, UNTESTED. 51 copies, 646k tris.
  - BUG FOUND + FIXED: the collision grid had rock over walkable ground of the real levels (1567 jungle floor
    triangles on its east cliffs x 419..506 under the low shore row, 10 Rock Village path triangles under the
    south row) -> Jak would have been pushed off ground he can stand on. WriteCoastHeights now clears cells with
    floor collision above 0.5 m in jungle / village2 (their own collision rules there). Check tool:
    /tmp/cs/overlap.cpp (level fr3z + heights -> walkable floor triangles under coast rock; now 1 + 1).
- 2026-10-22: Phase 4 BUILT (level code relinked, app builds; UNTESTED on device). Backup
  AOTBackup-2026-10-22-coast-mid/.
  - Device timings (sea-survey log): DGO loads are ~1 s (village1 0.96 s, swamp 0.65 s), so loading speed was
    never the problem: Rock Village only started loading at the halfway north/south hand-over.
  - New middle stage in ios-ocean-update-levels (fishermans-boat.gc): at sea with the jungle the nearest north
    island and Rock Village within IOS_SEA_MID_ENTER_R 1150 m (leave 1250 m), the pair is jungle + Rock Village
    (`ios-ocean-update-mid-levels`, manager field `mid`): the loaded one stays while the other streams in
    (ios-ocean-want-pair), both force-vis + display, vis/respawn follow the nearer. Sailing south this drops
    Sandover just past the jungle's south end (z ~-400) and Rock Village is in from there on, mood blending
    jungle -> Rock Village by distance (stock update-time-of-day). The south pair (village2 + swamp) still takes
    over at the old halfway rule; phase 5 moves that swap into the fog bank.
- 2026-10-22: Phase 5 BUILT (level code relinked, app builds; UNTESTED on device):
  - Fog now lives in the levels' mood functions (`ios-sea-fog-mood-func`, installed per slot by
    `ios-sea-fog-hook-moods`, under the Open Ocean storm's wrapper when a storm has them), so it changes the fog
    distances AND colours inside update-time-of-day: world and horizon both go into one sea-fog colour (cool grey
    by day, dark blue-grey at night, from the mood's hour), identical on both sides of the swap. Full fog: 4 m /
    45 m. The old math-camera override is gone.
  - Band: |t| < 0.08 full, clears by 0.2 (~55 m / ~140 m either side of the hand-over line down the coast);
    eases in ~1.5 s.
  - The north <-> south pair switch (Boggy Swamp in / out) only happens while the fog is above 0.9, unless Jak is
    well away from the line (|t| > 0.2: saves loaded at sea, warps).
  - NOT done: the visible "wall of mist" sprites on the water ahead of the band (needs an alpha-blended pass for
    native geometry); the band is noticed as the view closing in. Phase 6 next.
- 2026-10-22: Phase 6 BUILT (app builds, custom levels marker v19; UNTESTED on device):
  - Culling: each chunk copy is its own visibility group with a bounding sphere in its tree's BVH, so the
    renderer's existing frustum test (drawStripTree / SphereInView) skips copies off screen. Offline estimate
    (/tmp/cs/cullcheck.cpp): 0-54 % of the 646k triangles drawn looking across / away from the coast, ~90 % looking
    along it. No distance culling (fog end varies; fully fogged copies would pop).
  - Memory: the renderer uploaded all 3 tfrag levels of detail of every level but draws only kTfragLod (0); now
    the others are dropped at load (all levels, not just the coast), and the coast is written with one copy:
    file 7.4 MB (was ~22 MB with 3), GPU ~27 MB instead of ~80 MB for the coast.
  - Reviewed in code (not run): 120 fps / mirror mode / title (coast hidden) / Fire Canyon (hidden) / option off
    (hidden, backdrop drawn) all go through the same camera + *ios-coast-visible* paths as before.
  - 2026-10-22 fog with height (user: the hand-over fog only covered the water): ios-open-ocean.gc mist now also
    launches soft camera-facing bigpuff clouds (parts 2974-2976, default sprite system) around the camera, 4-60 m
    out and 0-30 m up (more low down), ~22 per second at full fog, ~8 s each (fade in 1.5 s, hold, fade out),
    drifting / growing / turning slowly, tinted with *fog-color*. Like the flat sheets, only with OPEN OCEAN LEVEL
    on (ios-open-ocean-update). BUILT + relinked, UNTESTED.
  - 2026-10-22 fog bank MOVED (user: it came before the abrupt sky / water colour change). Device log showed the
    switches: village1 -> village2 at (748, -556) (mid pair starts: sky + water colour change, the active ocean
    map is the last active level's), jungle -> swamp at (800, -994). The fog now sits on the Sandover <-> Rock
    Village switch: band on Jak's distance to Rock Village around IOS_SEA_FOG_CENTER 1200 m (full within 70 m,
    clear beyond 170 m; the mid pair enters at 1150 / leaves at 1250), only with the jungle the nearest north
    island. The mid switch only happens with the fog above 0.9 (or Jak > 170 m from the line: saves, warps), and
    *ios-sea-fog-hold-until* keeps it full for 2.5 s after a switch and while the arriving level (village2 going
    south, village1 going north) is not active yet. The Boggy Swamp swap (halfway) is no longer fogged or gated.
    BUILT + relinked, UNTESTED.
  - 2026-10-22 fog bank visible from afar (user: it appeared only once Jak was in it): fishermans-boat.gc
    `ios-sea-fog-bank-update` (called from ios-ocean-transition-fog every frame) launches big bigpuff clouds
    (parts 2977-2979, 40-70 m, ~15 s each, ~10/s -> ~150 alive) ON the band - the arc 1200 m (+-70) from Rock
    Village, -5..55 deg from north (the sea east of the coast + the channel), 0-45 m up - whenever the camera is
    within 1.1 km of the band down the east coast, 80 m-1.1 km from the camera, in the sea-fog colour
    (`ios-sea-fog-color`). Works without the Open Ocean option (the near mist still needs it). BUILT, UNTESTED.
    Tuned 2026-10-22 (user: too thick): 5/s (~75 alive), fade-a 0.2 (hold alpha ~24, was ~42). Near mist made to
    match: sheets 2971 + puffs 2974 now use ios-sea-fog-color (was *fog-color*, a blend with the level's own fog
    while the fog eases in) and the puffs the same transparency (fade-a 0.2, out -0.1).
  - 2026-10-22 (user: Rock Village's sky, light and extra rock settled in after the fog; pontoons late). BUILT,
    UNTESTED:
    - Fog reaches further toward Rock Village: full from the line to 260 m inside (clear 360 m), Sandover side
      unchanged (70 / 170 m); the far bank's clouds fill the wider band too.
    - `*ios-sea-look*` ('mid / 'south, set by ios-ocean-update-levels at sea) + `ios-sea-look-weights` (from slot
      0's mood function, which runs between update-time-of-day reading slot 0's and slot 1's level-distance):
      slot 1's level-distance is set so the mood blend uses Rock Village's sky and light in full in the mid pair,
      and in the south pair until the swamp is within ~650 m, easing to the stock blend by 300 m. The stock
      interpolation ramp smooths the change. The fog's mood wrapper stays installed while *ios-sea-look* is set.
    - Pontoons (ios-open-ocean.gc ios-ocean-pontoons-birth, every 32 ticks with OPEN OCEAN LEVEL): born once
      village2 is active and the camera is within 900 m (stock birth-dist 220 m), entity perm bit-3 set so
      actors-update doesn't kill them beyond 220 m.
    - Not changed: "extra rock wall chunks" late - the coast model is not streamed (drawn whole, frustum culled
      only); needs a screenshot of which rock appears late.
  - 2026-10-22 one kind of fog (user: the far clouds vanished on entry and a second kind took over). BUILT,
    UNTESTED: the Open Ocean near mist (sheets 2971 + puffs 2974) is off; the fog bank's clouds (2977) are also
    launched close around the camera (8 m-220 m, on the band only) at IOS_FOG_BANK_CLOSE_RATE 8/s x *ios-sea-fog*,
    and no longer kept 80 m away. Distance fog loosened 4/45 m -> 10/110 m (at 45 m it flattened the clouds into
    fog colour); beyond 110 m the level swap is still hidden.
  - Still open: tools/release/expected-generated.sha256 (update after the device test), the visible mist wall
    (phase 5 note), Rock Village ocean-map land tiles (black horizon strips) if still seen.

## Phase 0 findings (2026-10-21)

Tool: `tools/coast/coast_survey.cpp` (offline software renderer + stats for bundled .fr3z levels; build line in its
header). Renders were checked against the device screenshots (same views reproduce IMG_2582 / 2583 / 2587).

- The red-circle rock is NOT one mesh. Both levels build their cliffs from the same modular TIE rock kit
  (`wallmed-01/02/03`, `wallmed-01-squaredoff`, `walllarge-01`, `walltall-01/02`, `wallsmall-01/02/04`,
  `cliffsmall/med/large`, `cliffmed-4m`, `groundlarge/small`, `lil-rock-06`, `lil-bigrock-02`) over a tfrag core
  (`jng-rockwall-01` / `vil2-rockwall`, `jng-beach-01` / `vil2-beach-01`). Each level skins the kit with its own
  textures and time-of-day colours: green-gold in the jungle, dark blue-grey in Rock Village.
- Rendering only those protos + rockwall/beach tfrag gives bare rock with no trees, vines (`walltree.mb`),
  canopies, bonsai or huts. That is the chunk recipe.
- So the rod cutter (TIE, by proto) and a tfrag box cut are both needed: phase 1 cuts a BOX of
  {rock-kit TIE pieces + rockwall/beach tfrag}, not single protos.
- Candidate chunks (x0 z0 x1 z1, metres; tri counts with everything in the box):
  | Chunk | Source | Box | Tris | Notes |
  |---|---|---|---|---|
  | JA | jungle east face | 440 -170 530 -250 | 10.9k | solid to the waterline, good |
  | JB | jungle east face | 440 -250 530 -330 | 10.1k | gaps at the base, needs a low row in front |
  | JC | jungle east face | 420 -330 530 -410 | 6.0k | floats ~20 m up (no base), top-up only |
  | VA | Rock Village north | 150 -1420 270 -1530 | 15.7k | solid wall, good |
  | VB | Rock Village north | 270 -1400 380 -1530 | 27.4k | tallest; includes the sea stack, trim the top bridge |
  | VC | Rock Village north | 380 -1420 480 -1530 | 11.3k | arch / gaps, use as a back row |
  Budget: ~12-18 placed chunks for ~1.4 km of coast = ~150-250k tris before culling. Phase 1 drops triangles
  facing away from the sea (cliff backs and insides are never seen) to roughly halve that.
- Gap geometry: the stand-in coast covers x 288..500, z -480..-1170. Rock Village's rock starts at z ~-1420
  (x 150..480). Between them (z -1170..-1420) there is nothing: the open sky in IMG_2586/2587/2588.
- Black line on the horizon: Sandover's ocean map is already all water (opengoal.patch zeroed it for Eroded),
  but Rock Village's map (`*ocean-mid-indices-village2*`, active in the south pair) still marks tiles as land with
  no geometry: x 89..281 at z -1496..-1208 and x 89..185 at z -1592..-1496 (96 m tiles). No water is drawn there, so
  the clear colour shows through as a black strip. Fix in phase 2: zero those tiles like the village1 patch
  (ocean-tables is a `--relink-captured` object), and the new rock covers the spot anyway.
- Fire Canyon's lava path runs x ~100..230 behind the coast; it is only drawn in Fire Canyon, where the coast is
  hidden (as today).
- Still needed from the device run: DGO load times for village2 / swamp at sea (Adding -> Displaying), the boat's
  top speed (from two log lines), and the exact spots of the remaining yellow gaps.

## What exists today

- Stand-in coast (tools/coast/README.md): height-field terrain x 288..480 m, z -1152..-480 m, jungle grass / rock /
  sand textures, packed as one tfrag tree `ios-coast` (template `jakIOS/Import/Jak1CoastTerrain.fr3z`, rebuilt at
  import by Jak1CustomLevelBuilder.cpp). Drawn by Jak1Background.mm in the first opaque tfrag pass of ANY level
  (`drewCoast`) while GOAL `*ios-coast-visible*` (fishermans-boat.gc `ios-ocean-update-coast`).
- Collision: GOAL grid `*ios-coast-heights*` / `ios-coast-height`; boat shore probe + swimming Jak snapped back to
  the last safe spot. No real collision mesh.
- Level streaming: two slots. North pair = village1 + nearest; south pair = village2 + swamp, switched by
  IOS_SEA_REGION_HYSTERESIS 0.9 on nearest-south vs nearest-north distance (about halfway, ~z -935 m). One DGO at a
  time (ios-load-one-at-a-time) and `ios-ocean-want-pair` keeps the old level until the new one is ready.
- Transition fog: `ios-ocean-transition-fog` (distance balance, 20 m / 220 m) - too thin and in the wrong place to
  hide the swap; Boggy Swamp's mood (sky, fog colour, water) still snaps over.
- Model ripping precedent: `AppendTieRodAsTfrag` / `EmitTieTrisAsTfrag` (fishing rod, flut pad, vent ring), verified
  offline with a Mac harness against libjak1_extractor.

## Reading the screenshots (2026-10-21)

- Red (source rock): IMG_2582 = the Forbidden Jungle's own east-shore cliffs; IMG_2587 = the Rock Village sea stack
  with the pine trees on top. Both are TFRAG (background), not TIE, so the rod cutter can't be reused as-is.
- Yellow (to fill): IMG_2583 / 2585 / 2584 = the whole stand-in coast (flat dark slabs + the green top);
  IMG_2584 also its south end where it just stops; IMG_2586 / 2587 / 2588 = open sky between the coast's south end
  (z -1152) and Rock Village's north edge (z ~-1474), a ~320 m gap with nothing in it.
- The thin black line on the horizon in IMG_2586/2587/2588 = ocean-map tiles marked "land" with no geometry
  (the same black void the stand-in coast was made for). It goes once rock covers those tiles.

## Phases

### 0. Survey (no visible change)
- Debug readout (`*ios-open-ocean-debug*`): add camera heading and a log line on tap, so each yellow spot gets an
  exact x/z/heading. User revisits the 7 screenshot spots once.
- Mac harness (like /tmp/rodprobe): dump jungle + village2 tfrag triangles near the red regions, find the box
  around each chunk, count tris / textures / draw modes, render a preview PNG of each cut.
- Device logs: time village2 and swamp DGO loads (link-begin -> "Displaying level"), and the boat's top speed.
  Load distance = speed x load time + margin, used in phase 4.
- Map the black-line land tiles (tools/coast/oceanmask.py) that are outside every level's geometry.

### 1. Cut the rock chunks (import builder, offline-verified)
- New `AppendRockRegionAsTfrag(out, source, box, pivot)`: rock-kit TIE pieces (proto whitelist, phase 0) and
  rockwall/beach tfrag triangles with their centre inside the box, minus triangles facing away from the sea;
  re-based to the chunk's bottom centre. Copies the textures and time-of-day colours it uses (like the coast
  template / `EmitTieTrisAsTfrag`).
- Chunks: JA / JB / JC from the jungle, VA / VB / VC from Rock Village (boxes in the findings table), no
  trees or foliage (user 2026-10-21).
- Output: `Jak1Level-ios-coastrock.fr3z` built from the player's own jungle + village2 at import; bump
  `kCustomLevelsVersionMarker` (Jak1LevelBuilder.mm). Nothing from the game data ships in the app.
- Check: preview renders of each chunk on the Mac; vertex/tri counts for the memory budget.

### 2. Lay the coast + remove the old one
- Placement tool (tools/coast/place.py): instances along a coast polyline from the jungle's south-east shore to
  Rock Village's north edge, covering the old extent AND the 320 m gap + the black-line tiles. Per instance: chunk
  id, yaw, scale 0.8-1.4, mirror (negate x, flip winding) for variety. 2-3 staggered rows (front low, back tall) so
  no sky shows through from any angle at sea; trimmed so nothing pokes through the jungle's or Rock Village's
  real geometry (their collision extents from fr3_collision_dump).
- Bake the instances into one tfrag tree at import (recommended: no new renderer path, same draw as `ios-coast`).
  Runtime instancing with per-instance matrices (like the rod) only if the baked size is too big.
- Remove the green top and the old height-field terrain: `ios-coast` / Jak1CoastTerrain.fr3z go, the new tree
  takes its draw slot (`drewCoast`, `*ios-coast-visible*`, hidden in Fire Canyon / title as now).
- Drawn whenever at sea or near the jungle, whichever level pair is in: it carries its own textures.
- Device test: sail the whole coast both ways at day / night / storm; look for gaps, seams, z-fighting.

### 3. Collision for the boat and Jak
- Regenerate `*ios-coast-heights*` from the placed chunk triangles (top height per 2 m cell, finer than now) in
  the same tool, so the boat's shore probe and the swimming push-out match the new rock exactly.
- Swimming / boat contact: slide along the rock instead of snapping back to the last safe spot.
- No standing on top (user 2026-10-21): Jak jumping onto the rock is pushed back out over the water and slides
  off into it, never lands on it.
- Device test: ram the boat into every stretch, swim into it, jump off the boat at it.

### 4. Stream Rock Village + Boggy Swamp earlier
- Three stages instead of the 50/50 pair swap (ios-ocean-update-levels):
  A. village1 + jungle (as now, near the jungle).
  B. jungle + village2: village2 replaces village1 as soon as Jak is south of the jungle heading out (Sandover is
     far behind), so Rock Village is already displayed (long-view) well before you reach it.
  C. village2 + swamp: swamp replaces the jungle INSIDE the fog bank (phase 5) - the swamp is what changes the sky.
- Distances from the phase-0 timings; keep hysteresis and the one-DGO guard; `ios-ocean-want-pair` keeps the old
  level displayed until the new one is ready. Reverse order heading north.
- Check which level's mood drives the sky in stage B (jungle vs village2) and that respawn / low-res models still
  behave without village1.
- Device test: no pop-in sailing south; no black world / reload loops (grep link-begin heaps).

### 5. Fog bank on the water at the swamp hand-over
- Replace the distance-balance fog with a fixed band across the channel at the stage-C line (position from
  phase 4): ramp in over ~150 m, a thick core (~150 m deep, fog end ~40-60 m, fog-min 0), ramp out.
- The stage-C swap only fires while the fog is at full strength (both directions); the fog holds until the new
  level is displayed and its mood has settled.
- Mood blend: while in the band, fog / sky / erase colours are lerped from the north mood to the swamp mood, so on
  leaving the fog the swamp look is already there (no snap).
- Visible fog bank "in the water": low, soft billboards on the water surface along the band so you see a wall of
  mist ahead before you enter it. Native quads in the renderer with a procedural soft texture (no game textures
  needed), fogged and lit by time of day; stock particle mist if a common-texture one exists.
- Compose with the weather phase (storm mood already sets fog 15 m / 260 m): take the thicker of the two.
- Device test: sail through both ways at speed and slowly; the level swap must never be visible.

### 6. Polish
- Frame time with the rock tree drawn every frame (tfrag has no LOD of its own; split into 2-3 trees by distance
  if needed), memory with the extra textures, 120 fps mode, mirror mode, title flyover, Fire Canyon, option off.
- Update tools/coast/README.md and the memory notes.

## User decisions (2026-10-21)

- Rock type by area: jungle chunks near the jungle, Rock Village chunks near Rock Village, switching where the
  stretches meet.
- No standing on cliffs: collision keeps the boat out; Jak jumping at it slides off into the water.
- Bare rock only (no pine trees).
