# Open Ocean level plan

User request 2026-10-19: make the open ocean its own "level" with collectibles, life, weather and set pieces.
One phase per build/test cycle. Update STATUS as phases land.

## STATUS

- 2026-10-19: Phases 0a + 0b BUILT (compiles, links, app builds; UNTESTED on device).
- 2026-10-19: Phase 2 (barrels + floating orb rings) BUILT, UNTESTED on device.
- 2026-10-19: Phase 1 (seagulls) BUILT, UNTESTED on device.
- 2026-10-19: Phase 3 part 1 (waves + wind, user: "start phase 3 with the wave and wind sounds first") BUILT,
  UNTESTED. Remaining phase 3 extras on request.
- 2026-10-19: Phase 4 (scout fly boxes) BUILT, UNTESTED. Orbs decision confirmed by user: ocean orbs stay in the
  normal (spendable/HUD) count + ocean 500, never the stock 2000 total / completion.
- 2026-10-19: Phase 5 (weather) BUILT, UNTESTED.
- 2026-10-19: Phase 6 (sea serpent) BUILT, UNTESTED.
- 2026-10-19: Phase 7 plan agreed (user "proceed" = all recommendations): Precursor ruin that rises rarely
  (~every 10-15 min in the ocean, up 8-10 min), LPC pieces, 3x3 light-the-tiles puzzle -> ocean cell 6 (index 5),
  blue vent + launcher to an upper deck, warp gate -> Sandover; cell 7 (index 6) still open. Steps 7a-7d, device
  test each. 7a BUILT (device: visible after the wave fix). 7b BUILT, UNTESTED. 7c BUILT, UNTESTED. Next: 7d (warp gate on the upper deck).
- 2026-10-21 fixes from device testing (BUILT, UNTESTED):
  - Boundary readout OFF (*ios-open-ocean-debug* default #f, user 2026-10-21); flip it to #t to show it again.
  - Precursor ruin spawning OFF (IOS_RUIN_ENABLED #f) until refined; code kept.
  - Fast-test timings now on their own switch *ios-open-ocean-fast* (default #f); the readout (*ios-open-ocean-debug*)
    no longer speeds up storms / serpent / ruin (that was why they were "far too common").
  - Rarer: storms check 120 s at 8 %, 10 min cooldown; serpent check 180 s at 6 %, 15 min cooldown.
  - HUD fly counter: ocean fly pickup sets fact-info-target buzzer to the ocean's count (+ buzzer-pickup-time) and
    the stock fly-to-HUD manipy is back (stock level-enter recount left 0 / 7 there).
  - Ocean power cells: ios-ocean-cell (fuel-cell subtype, fuel-cell-init-by-other) with its own pickup state:
    pu-powercell + group-fuel-cell-starburst + 'get-pickup + auto-save, no victory sequence. ios-ocean-spawn-cell
    used by barrels, the 7th fly and the tile puzzle.
  - Barrels: collision is the art's prim-mesh (transform 3, as the stock keg / crates) instead of a 1.6 m sphere
    (Jak hovered 0.6 m over the 1 m-radius keg).
  - Serpent far rule tightened (user 2026-10-21: still drew wrong when Jak moved away): every up state's :trans
    runs ios-ocean-serpent-far-check -- Jak > 45 m: dive (sink), > 70 m: straight under with splashes, even
    mid-sink; spawns 20-35 m; under never resurfaces > 45 m (gone).
  - Serpent: chases Jak at 2 m/s while up (open water only) to 14 m; dives and goes when Jak is > 120 m away
    (beyond the fog end its body is a fog-coloured silhouette with only the envmap eyes bright -- that was the
    "only the eyes render" report; body = effect 0 plain merc, eyes/pendant = effect 1 envmap). At the boat's wheel:
    head within 9 m during a chomp -> process-release? (boat leaves drive mode itself) and a default attack next frame.
  - Ambience beds (ocean-bg, wind-loop, swamp-amb, village2-amb) are sound-play-by-name with no position (same id
    each frame) instead of ambient-sounds kept on the ear: rain cut in and out while fishing moved the camera.
  - Death in the Open Ocean: save-game!/load-game! wrappers remember the save's checkpoint (*ios-ocean-saved-continue*,
    the stock one behind *ios-dsp-continue*); while Jak dies at sea current-continue is held on it every frame and the
    boat goes to the dock nearest it (ios-boat-park-return-home). Fallback (no save/load yet this session): stock.
- 2026-10-21 (2) BUILT, UNTESTED:
  - Hand-over mist: parts 2971-2973 (copy of Misty's group-misty-fog part 982: flat 3D bigpuff2 sheets 30-46 m,
    fade in 1.2 s / hold 4.5 s / out ~2 s), launched on *sp-particle-system-3d* around the camera within 90 m at mean
    sea + 1.6-3.4 m, 14/s x *ios-sea-fog* (boat code's eased hand-over strength), tinted with *fog-color*. Hand-over
    distance fog thicker: fishermans-boat.gc IOS_SEA_FOG_START 20 -> 10 m, END 220 -> 150 m.
  - South zones (Rock Village 5, Boggy Swamp 6, Precursor City 7) without the 120 m margin
    (IOS_OPEN_OCEAN_SOUTH_MARGIN 0): the sea around Rock Village counts as Open Ocean, so barrels / fly boxes /
    gulls / serpent spawn there (interpretation of "the whole open ocean is one area"; confirm with the user).
  - Pontoons: every 32 frames, *entity-pool* children whose type is pontoon / pontoonfive / pontoonten get
    pause-adjust-distance +200 m (stock -30 m -> they only ran, and so first drew, within 20 m of the camera).
- 2026-10-23 BUILT, UNTESTED: 6 power cells (user: remove 2): cells 0-4 from drifting barrels, cell 5 (the last)
  = FREE 7 SCOUT FLIES (IOS_OCEAN_FLY_CELL 5, page buzzer-task-index 5). The ruin tile puzzle awards no cell
  (IOS_OCEAN_RUIN_CELL -1). Old saves' fly cell (bit 7) is read as bit 5; bits masked to 0-5.
- 2026-10-23 BUILT, UNTESTED: experimental option STORMS (text 0x1675, NSUserDefaults experimental.stormsEnabled,
  host SyncStormsOption -> *ios-storms*, second host copy of the green eco row; PC text marker storms-v16). The ocean
  weather process (now also spawned with only STORMS on) may start storms over village1 / beach / jungle / misty /
  training: same odds as the sea (IOS_LAND_STORM_* = IOS_STORM_*: 45 s / 50 % / 10 min, ~11-12 min clear between storms; user 2026-10-23). User follow-up: a storm that is on
  follows Jak everywhere until it clears (ios-storm-carry?), except indoor *ios-storm-dry-levels* (jungleb, sunken(b),
  caves, lavatube, citadel, finalboss). Rain/gloom beds moved from the ocean ambience into the weather process;
  Backup: AOTBackup-2026-10-23-storms/.
- 2026-10-23 rain collision (user: no rain through Sandover's roofs), BUILT, UNTESTED: drop :funcs can't probe
  (sp-process-block keeps particles in the scratchpad, which the collide cache also uses), so the weather process
  keeps *ios-rain-map*: 1 m cells within 23 m of Jak, y-probe (background|ground-object|wall-object) from Jak + 20 m,
  24 probes/frame, re-probed when Jak moves > 3.5 m up / 6 m down; miss = sea level 0. While our rain is on, part
  37's :func = ios-rain-drop-37 (stock splash at the cell height) and part 38 uses a copy of its specs with :func
  ios-rain-drop-38 (kill only); unprobed cells kill drops. Restored when the rain stops.
- 2026-10-23 storm fixes from device (BUILT, UNTESTED): (1) door frames vanishing as it darkened: update-mood-itimes
  makes palette rgb = times.xyz * w but alpha = w, so darkening w faded alpha-tested background; now xyz is darkened
  (from per-level-slot saved values, restored when the storm ends; mood funcs never write xyz). (2) rain inside
  enterable buildings: roofs have no collision. Wall-probe indoor test failed (offline sim on village1 collision:
  interiors speckled); REPLACED by *ios-rain-dry-circles* where no rain falls at all. 24 probes/frame. Circles first fitted to
  wall collision (r 7-10) still leaked under the eaves; now measured from roof render geometry (TIE vil1-rooftile-1
  + vil-under-roof clusters, Samos vil1-sages-strawroof-01; r 18.5-24) for all 7 Sandover buildings, checked by
  overlaying on a coast_survey top-down render. (3) music: weather
  process holds 'rel music-volume = 1 - rain (silent at full storm, back as it clears).
- 2026-10-23 scout fly counter fix (BUILT, UNTESTED): HUD + main pause screen read *target* fact buzzer, which
  stock level-enter sets to the current level's count (showed 7 at sea). ios-ocean-hud-flies-update holds it on the
  ocean count every frame in the Open Ocean ('sync on non-pickup changes) and restores the level's count on leaving.
  Save fix: "iOSO" flags bit 1 (kOceanFlagFliesReset) written on every save; saves without it get flies + the fly
  cell (bit 5 / old bit 7) cleared once on load. Fly boxes already stop at 7/7.
- 2026-10-23 save file name (BUILT, UNTESTED): saving in the Open Ocean stores level-index 27 (test-zone's, never
  played) in the save; *level-task-data-remap* entry 26 is set every frame to the ocean page (option on) or Sandover
  (off), so the file reads OPEN OCEAN / SANDOVER VILLAGE. Loading such a save with the option off drops the exact
  spot and starts at "village1-hut".
- 2026-10-24 fog bank edges (BUILT, UNTESTED): fishermans-boat.gc ios-sea-fog-bank-launch picks each cloud's size and
  keeps its visible circle (scale / 2, fully grown) 1.8 m over mean sea, so no cloud is cut along the waterline; 55 %
  are new flat unrotated streaks (part 2980) lying on the water, the rest tall round clouds (2977) above them.
- Everything is behind the experimental option OPEN OCEAN LEVEL (user 2026-10-19): title Options > Experimental,
  text 0x1673, host-allocated copy of the Expanded Green Eco row, NSUserDefaults experimental.openOceanLevelEnabled,
  -> GOAL *ios-open-ocean-level* (SyncOpenOceanLevelOption). Off = no boundary, no page; progress still saved.

### What 0a/0b built
- Startup object `pc/ios/ios-open-ocean.gc` (relink: `--startup-object ios-open-ocean` LAST, after ios-fishing;
  in game.gp + build.sh STARTUP_OBJECTS). Backup of the previous level code: AOTBackup-2026-10-19-openocean0/.
- Progress: save bank header block "iOSO" at McHeader data +144 (after the fish log): orbs u16, flies bits u8,
  cells bits u8, visited flag. Jak1MemoryCardManager Get/Set/ResetOceanProgress; reset on the New Game screen with
  the fish log. GOAL mirror `*ios-ocean-progress*` (orbs/flies/cells/visited written by host; GOAL only adds to
  add-orbs/add-flies/add-cells/add-visited, host SyncOpenOceanProgress folds them in after each frame).
  GOAL helpers: ios-ocean-orbs / -flies / -cells / ios-ocean-cell-collected? / ios-in-open-ocean?.
- Page: *level-task-data* entry 16 (was parked Eroded) replaced at boot by *ios-ocean-level-tasks* (8 entries,
  buzzer index 7, task-id none). Wrapped: draw-fuel-cell-screen / draw-money-screen / draw-buzzer-screen (page 16
  drawn from ocean data: x/500 orbs, x/7 flies, cells "???" until collected, then name + TASK COMPLETED),
  get-next-task-up/down (all 8 selectable on page 16), make-levels-with-tasks-available-to-progress (level-opened 16
  = option on + visited), calculate-completion (stock pages only), activate-progress (paused in the ocean -> opens
  on page 16). Host SyncErodedCoastProgressTotals (shrank the array to hide Eroded) REMOVED.
- Text: 0x1670 OPEN OCEAN, 0x1671 FIND IN DRIFTING BARREL, 0x1672 ???, 0x1673 OPEN OCEAN LEVEL (English in all
  languages); marker .jakios-pc-text-open-ocean-v14. Cell 7 uses stock (text-id beach-buzzer) FREE 7 SCOUT FLIES.
- Boundary: *ios-open-ocean-zones* (x, z, land radius m) for Sandover, Sentinel Beach, Forbidden Jungle, Misty,
  Geyser Rock, Rock Village, Boggy Swamp, Precursor City + one shared IOS_OPEN_OCEAN_MARGIN (120 m) -> the line is
  the same distance out from every level; 15 m hysteresis to leave. Land radii = ocean manager home radii - 120 m.
  Debug readout (*ios-open-ocean-debug*, default #t: "OPEN OCEAN  N M FROM X" / "X  N M TO OPEN OCEAN", left side
  y 180) for tuning; turn it off once the line is right. format 0 logs enter/leave.
- Music (user 2026-10-19): no music in the Open Ocean. Process ios-open-ocean-music (spawned on *entity-pool*,
  re-spawned if gone) holds a 'rel music-volume setting: fades to 0 over 3 s while in the ocean, back over 2 s
  outside, then removes the setting. Volume 0 also stops settings update from loading new music, so the next
  level's music only starts once Jak is back in a level's territory. Phase 3 ambience replaces it.
- Not done: no way to grant ocean items for testing (Dev Menu row is disabled); nothing awards ocean items yet.

## User decisions (2026-10-19)

- Power cells: 8 total, same layout as stock levels = 5 drifting-barrel cells + 2 TBD + 1 for all 7 scout flies.
  Fits the existing 8-slot `level-tasks-info` page (buzzer slot + 7 cells), no structure change.
- Undiscovered cells show `???`; barrel cells read "Find in drifting barrel" once found.
- Ocean collectibles are a SEPARATE BONUS: they show on their own pause page but do not change the stock
  101 cells / 2000 orbs / completion % math. Finished saves stay 100%.
- 500 orbs come from barrel orb bundles only (floating rings removed 2026-10-19); stop at 500.
- Once all ocean orbs + cells are collected, barrels only hold big green eco clusters.
- Once all 7 ocean scout flies are collected, scout-fly boxes stop spawning.

## Technical constraints found

- Precedent: the parked Eroded Coast (opengoal.patch) added game-tasks 116-122 (`max 123`) and
  `level-task-data-index eroded 16` with a progress page. Leave Eroded's ids alone (restorable from
  jakIOS/Parked/ErodedCoast); Open Ocean gets new ids after it.
- `level-tasks-info` holds `task-info-data 8` -> buzzer + 7 cells max per page.
- `game-info money-per-level` is `uint8 32` -> max 255 per level. The 500-orb count is kept host-side in our own
  save data (like the fish log in the McHeader) and shown on the page; not in money-per-level.
- Save load copies `min(elt-count, task-perm-list allocated-length)` task perms -> length-tolerant, but
  task-perm-list is allocated in the captured runtime image. MUST verify the allocated length / whether
  extending `game-task max` needs a recapture before anything else in 0a.
- Ocean cells must not touch `game-info fuel` / completion math (bonus decision), so cell pickup needs an
  ocean-specific path (task closed + page shown, fuel total untouched) -- verify how the stock pickup adds fuel.

## Phases

### 0a. Data model (no gameplay)
- Verify task-perm-list capacity in the captured image; pick ids for 1 ocean buzzer task + 7 cell tasks.
- New progress page (level-task-data-index 17) "OPEN OCEAN": `???` until found, text ids for cell names.
- Host-side ocean save block: orb count (0-500), scout fly bits (7), barrel cell discovery; reset on New Game.
- Page shows orbs x/500, flies x/7, cells x/8. Dev-only way to grant items for testing.

### 0b. Boundary
- Each surrounding level's territory extends halfway toward its neighbours; outside all of them = Open Ocean.
- Drives: spawn eligibility, collectible attribution, pause menu opening on the Open Ocean page.
- Debug readout of current region to tune the line on device.

### What phase 2 built (all in pc/ios/ios-open-ocean.gc unless noted)
- Art: host LoadResidentOceanArt links MIS.DGO "keg" (v4 art) into the global heap as level-default art once per
  session when the option is on -> GOAL *ios-ocean-art*. Model: Jak1CustomLevelBuilder builds
  Jak1Level-ios-ocean.fr3z (misty keg-lod0/1/2), custom levels marker .jakios-custom-levels-v5 (rebuilds all custom
  models once); Jak1Background pins "ios-ocean" via SetResidentOceanModelEnabled.
- Stand-in entity *ios-ocean-entity* (level-default links, like the fish's); pickups are recognised by it.
- ios-ocean-barrel (process-drawable, *ios-ocean-keg-sg*): sphere prim 1.6 m, collide-as crate, solid +
  rider-plat-sticky, offense normal-attack (iron crate). 'attack 'flop -> break; other attacks smush +
  icrate-nobreak. Floats at ocean-get-height + 0.15 m, drifts 0.5 m/s (turns away when ios-fish-water-column fails
  6 m ahead), slow yaw spin + small roll. No animation played (keg idle = Misty conveyor roll); orientation
  assumed already "on its side" in the bind pose -- CHECK ON DEVICE. Cell barrels carry the stock power cell hum
  (ambient-sound "powercell-idle", fo-max 40).
- Break: icrate-break + smack-surface, group-crate-explode + group-part-water-splash. Contents via
  birth-pickup-at-point: cell -> fuel-cell hovering 1.2 m above the water (amount 200 + cell index, 'movie-pos -1 so
  the stock victory sequence plays where it is); orbs (5-15) and big green eco with instant-collect.
- Orb rings REMOVED (user 2026-10-19: no orbs floating in the water); barrels are the only ocean orb source.
- ios-ocean-spawner (*entity-pool*, ensured while in the ocean): max 4 barrels / 2 rings, spawn 60-140 m away in
  open ocean water, despawn > 230 m; barrel check every 3 s (50 %), ring every 6 s (30 %). Contents: 15 % cell (lowest
  uncollected barrel cell not already in a live barrel), 55 % orbs (if any left after what live barrels/rings
  hold), else green eco. Spawns nothing outside the ocean; deactivates when the option goes off.
- pickup-collectable! wrapper (wraps ios-green-eco's): ocean money -> add-orbs (clamped to 500) + spendable
  *game-info* money + money-pickup sound, NOT money-total/money-per-level; ocean fuel-cell -> add-cells bit only
  (no fuel, no task). DECISION TO CONFIRM WITH USER: ocean orbs are spendable.
- Rarity + second look (user 2026-10-19, "barrels flooding the game area"): max 2 barrels / 1 ring; barrel check
  every 20 s at 30 % (~1/min), ring every 30 s at 25 %. Half the barrels are the common green eco barrel
  (crates.gc *crate-barrel-sg*, crate-barrel-lod0-2 in GAME art: always resident, no host/import step), tipped 90 deg
  about local x with its base origin moved so its middle floats (IOS_OCEAN_CRATE_BARREL_HALF 0.75 m, sphere prim
  offset the same); wcrate-break sound. Keg only when *ios-ocean-art*. Barrel field `center` = floating point.
- Device unknowns: keg orientation/size (IOS_OCEAN_BARREL_SCALE / _RADIUS / _FLOAT_Y), whether Jak's flop lands on
  the barrel, cell victory animation height over water, ring height for swimming/boat pickup.

### 2. Drifting barrels (before seagulls: first real source of cells/orbs)
- Misty `keg` art, lying sideways, bobbing on the ocean height; break by dive attack.
- Contents: power cell (5 total), orb bundles, big green eco clusters. Cell barrels play the power-cell-nearby
  ambient sound. Floating orb clusters/rings also spawn until 500.

### What phase 1 built
- Art: LoadResidentOceanArt now loads a table: MIS.DGO keg + BEA.DGO seagull (-> *ios-ocean-gull-art*).
  Jak1Level-ios-ocean.fr3z also takes beach seagull-lod0 (custom levels marker v6).
- ios-ocean-gull-flock (process, child of the spawner): centre 14-26 m above the water wanders to a new spot
  20-60 m from Jak every 10 s at 5 m/s; cries "seagulls-2" every 4-12 s. Children ios-ocean-gull
  (process-drawable, *ios-ocean-gull-sg*): orbit the centre at 6-16 m, 25-45 deg/s (one direction per flock),
  +-3 m height + 1.5 m bob, yaw along the orbit, banked 25 deg; seagull-fly-ja loop with 35 % glides
  (seagull-slowfly-ja x2-4); wing sound effects off.
- Spawner: max 2 flocks, check every 12 s at 50 %, 40-90 m from Jak inside the Open Ocean; 40 % a lone gull, else
  2-4. Despawn > 230 m. Gulls need no water under them.
- Sound banks: NOT a limit after all. The relinked level.gc (mod-base update-sound-banks) loads all 20 level banks
  once at boot and never unloads them (overlord port has 24 bank slots for that), so village1/beach sounds play
  anywhere at sea. User asked to keep Sandover's sounds loaded at sea: already true, no change needed.
- Device unknowns: bank angle sign, gull size against the sea, whether "seagulls-2" is a one-shot or a loop.

### 1. Seagulls
- Beach `seagull` art; spawn alone or small groups within a radius of the player, calls/SFX.

### Crash 2026-10-19 (device, after phase 3 part 1): fixed, untested
- Symptom: far too many seagulls, then EXC_BAD_ACCESS on jak1-kernel (pc in garbage); console flooded with
  ocean-bg / wind-loop sound commands and "WARNING: flushing RPC port #0".
- Cause: the music/ambience/spawner "ensure" functions kept their process handle in a define-perm symbol. Handles
  are 64-bit (pointer + pid); Jak 1 symbols hold 32 bits, so the pid was lost, handle->process never matched, and a
  new process was spawned EVERY frame (hundreds of spawners -> gull flocks/barrels each; hundreds of ambience
  processes -> sound RPC overflow), until pools/heaps ran out.
- Fix: handles live in *ios-ocean-handles* (structure with 64-bit handle fields). Never put a handle in a global
  symbol.

### What phase 3 part 1 built
- ios-open-ocean-ambience (*entity-pool*, ensured with the music process): beds "ocean-bg" 75 % + "wind-loop" 45 %
  (village1 bank) as ambient-sounds kept on the ear (update-trans! (ear-trans)), volumes via update-vol!, fade
  3 s in/out with the Open Ocean, stopped at 0. One-shots: "water-lap" 55 % every 3-9 s 3-8 m away; gusts
  "tower-winds"/"tower-wind2"/"tower-wind3" (beach) 60 % every 8-20 s 10-25 m away. Nothing new while paused.
- Other candidates seen in the banks: beach-amb2, bird (beach), village-amb, boat-splash (village1),
  training-amb, village2-amb + thunder (village2, phase 5), swamp-amb.
- Device unknowns: whether ocean-bg / wind-loop loop by themselves (ambient-sound replays with the same id each
  frame, so a one-shot restarts when it ends), mix levels.

### 3. Ambience
- Periodic wind / waves / gull layers from beach sound banks (must be loaded banks; see fishing note on
  common-bank sounds).

### What phase 4 built
- Fly box = ios-ocean-barrel with contents IOS_OCEAN_BARREL_FLY (amount = fly index) and look
  IOS_OCEAN_LOOK_FLY_BOX (*crate-iron-sg*, common art, upright, base origin offset like the crate barrel). Stock
  crate-buzzer buzz ("buzzer" pitch -762, fo-max 40) + group-buzzer-crate puff/jiggle (1 %/frame). Breaks on 'flop
  only; icrate-break + group-crate-steel-explode.
- Spawner: one box at a time (*ios-ocean-fly-box-held* from the tally), check every 45 s at 25 % (~1 per 3 min),
  lowest fly not found yet; none once all 7 are found. Not counted in the barrel max.
- ios-ocean-buzzer (subtype of stock buzzer): wait = transform-post + animate (no task reminder check); pickup =
  buzzer-pickup sound, no task close / HUD fly / hint; when this makes 7 ocean flies and cell 7 is missing, births
  fuel-cell 200+7 (movie-pos -1) and waits for it. Spawned with buzzer-init-by-other, hops up (vel y 57001) and
  settles 1.2 m above the water.
- Wrapper: ocean buzzer pickup -> add-flies bit (amount = index); no stock buzzer task / buzzer-total.
- Not done: HUD scout fly counter (stock HUD shows the current level's count, so it isn't shown for ocean flies).

### 4. Floating scout-fly boxes
- Like barrels, rarer; stop spawning when all 7 ocean flies are collected; 7th fly awards the 8th cell.

### What phase 5 built
- ios-ocean-weather (*entity-pool*, handle in *ios-ocean-handles*): clear -> building (30 s) -> raining (2.5-5 min,
  then 30 %/20 s to stop) -> clearing (30 s); a storm may start every 60 s at 15 % once 4 min clear (debug readout on:
  every 20 s at 50 %, 1 min cooldown, for testing). *ios-ocean-storm* = strength x presence (presence seeks 1 in the
  Open Ocean, 0 outside, over 8 s); *ios-ocean-rain* = storm 0.4..1 -> 0..1.
- Darkening: update-time-of-day wrapper -> ios-storm-hook-moods puts ios-storm-mood-func in each level slot's
  mood-func while storm > 0 (originals in *ios-storm-orig-mood-0/1*, restored at 0). After the level's mood:
  times w *= lerp(1, 0.42, s) + flash*1.6 -> update-mood-itimes; light-group levels x the same; prt/sun/env dimmed;
  fog/erase colours -> dark grey (85 %), fog dists -> 15 m / 260 m; sky-times -> the level's 1 am snapshots (80 %);
  stars x (1 - s). Not Rock Village's actual cloud textures: sky textures belong to each level's bsp, so village2's
  aren't there at sea; this darkens the loaded levels' own skies toward their night sky.
- Rain: weather-part.gc update-rain (parts 37/38 drops + splash, camera drips) every frame, :num scaled by rain
  and restored after. Sounds (ambience process): "swamp-amb" 80 % x rain, "village2-amb" 50 % x storm, wind x (1 +
  storm). Lightning (storm > 0.75): every 6-20 s, flicker 1 / 0.2 / 0.8 then fade over 0.7 s (*ios-ocean-flash*
  brightens palette, lights, fog), "thunder" 0.3-2 s later at 150-300 % x storm, 40 m above the ear.
- Readout shows STORM % / RAIN % while a storm is on.
- Device unknowns: rain splash height (part 37 user-float 0 = y 0), darkness level, whether swamp-amb sounds like
  rain without the swamp around, night-sky look.

### 5. Weather events
- Rock Village dark clouds + Boggy Swamp rain; slow fade in, long duration, random end; lightning/thunder +
  rain lighting and sounds.

### What phase 6 built
- Art: BEA.DGO "lurkerworm" resident (-> *ios-ocean-worm-art*); lurkerworm-lod0/1 added to Jak1Level-ios-ocean.fr3z
  (custom levels marker v7).
- ios-ocean-serpent (process-drawable, child of the spawner): scale 4, animations at 0.55 (chomp 0.72). States: rise
  (water-explosion + worm-rise1 + large-splash, 8 splashes then 2 every 0.12 s, boulder-splash at the top) -> rest
  (idle loops, splash every 0.6 s; strikes 2-4 times when Jak is within 24 m xz at 2 %/frame; dives after 2+ loops at
  30 %, always at 6 or when out of bites) -> strike (worm-taunt, stock chomp) -> sink (worm-sink + water-explosion,
  splashes, large-splash) -> under (hidden 2-5 s, resurfaces 25-45 m from Jak, at most 3 risings, gone if Jak left
  the ocean). Body turns to Jak at 35 deg/s, head tilt via the stock prebind (joint at +432). Base stays on the waves.
- Collision: the stock worm's prims, radii x4 (body spheres on joints 3/5/6/7/8 solid, head prim 1 on joint 11 bites
  on touch with a default attack-info = stock damage). Jak's attacks only make it dive.
- Spawner: one at a time; check every 90 s at 15 %, 5 min from the last one (debug readout on: 30 s / 40 % / 1 min).
- Not used: the worm's sand particles (group-beach-sandworm) and twister: beach level code.
- Device unknowns: size/height vs the water (base at the surface), bite reach at 4x, collision radii, anim speeds.

### 6. Sea serpent
- Beach `lurkerworm` scaled up, slower rise/sink, bite hurts Jak, random dive back; heavy splash particles + SFX.

### What 7a built
- Art: SUN.DGO "square-platform" resident (-> *ios-ocean-ruin-art*); square-platform-lod0/1 in ios-ocean.fr3z
  (custom levels marker v8). Resident ocean art total ~101 KB (keg 18, seagull 25, lurkerworm 50, square-platform
  8); the rest of phase 7 adds ~42 KB (qbert-plat 11 + qbert-plat-on 11, floating-launcher 13 (SUB.DGO),
  warp-gate-switch 5, warpgate 1.3 -- so the warp gate's ring is probably level geometry, not this art: check in 7d).
- ios-ocean-ruin (child of the spawner) + 7 ios-ocean-pillar children (*ios-ocean-pillar-sg*, stock square-platform
  prim-mesh collision: ground-object, solid + rider-plat-sticky, transform 3; rider-trans/rider-post). Layout
  *ios-ruin-layout*: middle pillar (top +2.5 m) + hex ring at 7 m (tops alternating +0 / +1 m) above sea + 1.5 m.
  Rises 22 m in 20 s (eco-tower-rise + water-explosion, splashes every 0.2 s, eco-tower-stop + large-splash),
  stays 8-10 min or until Jak is 350 m away, sinks the same way, then gone. Beacon: group-part-vent-blue-active
  on the middle pillar while up.
- Spawner: check every 180 s at 30 %, 5 min after the last rose (debug readout on: 45 s / 50 % / 1 min); 150-250 m
  from Jak, open-water spot at least 40 m inside the Open Ocean.
- Fix 2026-10-19 (user: "nothing happens when the ruins are supposed to be rising"): memory dump showed it HAD
  risen (7 pillars, tops 1.7-4.2 m above the water, 70 m from Jak; storm at 100 %) -- it rose 150-250 m off,
  low, silent (positional sounds out of range) and in storm fog. Pillar model measured (offline probe
  /tmp/pillarprobe on sunken.fr3z): top at the origin, 8 x 8 m, 13 m tall. Now: spawns 70-110 m away; layout
  middle +6 m, ring alternating +0 / +2.5 m (over sea + 1.5 m); spacing 8.2 m; its sounds play up to 35 m from the
  ear toward it (always heard); camera shake (*camera-smush-control* 409.6) within 150 m while it moves; beacon
  stream cycled over 4 heights (0-15 m).
- Fix 2 2026-10-19 (user screenshot: most pillar tops under the water, one slab above): the base height was
  ocean-get-height at spawn = the wave at that instant (waves are +-1.3 m, mean sea level = *ocean-map*
  start-corner y = 0). Spawned on a trough, the low tops (+1.5) sat ~0.2 m and crests covered them. Now based on
  start-corner y, lowest tops 2.2 m above mean (middle 8.2, others 4.7).
- Device unknowns: pillar top size vs the 7 m spacing (gaps / overlap), whether the boat collides with the pillars
  (they collide with target only), beacon visibility from 150+ m (particle fade distance), the idle frame pose.

### What 7c built
- Layout now 8 pillars: index 0 = upper deck (top +16 m over the lowest tops = 18.2 m over mean sea), index 7 =
  the pillar stacked under it (top +3.0), ring 1-6 alternating +0 / +2.5. ios-ocean-ruin-top gives a risen top.
- On reaching the top (end of rise): ios-ocean-blue-vent (stock vent, blue: eco-blue fact, group-part-vent-blue-
  active, group-blue-collect / group-eco-blue-collect, 'eco-bg-blue) on ring pillar 1 (+0), stock launcher
  (launcher-init-by-other: spring 20 m, mode 0 = cam-launcher-shortfall, active 100 m; ocean entity -> jungle
  particles) on ring pillar 2 (+2.5) with dest = deck top, seek-time 1.2 s. Both deactivated when it starts sinking.
  Beacon moved with the deck (pillar 0).
- Device unknowns: launch reaching/landing on the deck (spring/seek), vent stream look without a vent ring model.

### What 7b built
- Art: SUN.DGO qbert-plat + qbert-plat-on resident; *ios-ocean-ruin-art* only when all three ruin arts loaded;
  models qbert-plat-lod0 / qbert-plat-on-lod0 in ios-ocean.fr3z (custom levels marker v9). Tiles are 6.8 x 6.8 m,
  6.3 m deep, top at the origin (probe).
- 9 ios-ocean-tile children of the ruin: 3x3 at 7.2 m, grid centre 24 m +x of the ruin's middle; each floats at
  ocean-get-height(its spot) + 0.6 m + ruin offset, small rock; stock qbert-plat prim-mesh (transform 0) solid +
  rider-plat-sticky. Landing (riders 0 -> >0, only once risen) sends 'tile index to the ruin, which toggles the bit
  (plat-light-on / plat-light-off). Lit look = ios-ocean-tile-glow child (qbert-plat-on, emissive blue as stock
  qbert-plat-on-mimic) with the dark tile hidden. All 9 -> solved, cell-prize, fuel-cell 200+5 (movie-pos -1)
  1.5 m over the middle tile. Already collected -> tiles start lit, inert.
- Page: cell index 5 = text 0x1674 SOLVE THE PRECURSOR RUIN (marker .jakios-pc-text-open-ocean-v15).
- Device unknowns: jump from the low ring pillar (top 2.2 m over mean) to the grid (gap ~1 m; tiles ~0.6 m over the
  waves), whether riders counts Jak reliably on a bobbing tile, glow overlay alignment.

### 7. Precursor ruin island (rare)
- Small custom island from existing tie/prototype pieces, boat-only warp gate, eco vent, power cell puzzle
  (likely one of the 2 TBD cells).
