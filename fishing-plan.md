# Fishing (Experimental) — phased plan

First "life sim" feature. Replaces the **Fish in Ocean** experimental option (row 0x1606) and reuses its
fish art, renderer pinning and swim logic (`pc/ios/ios-ocean-fish.gc`, `Jak1Level-ios-fish.fr3z`).

Rule: each phase is built, handed over for a device test, and the next phase starts only when asked.

## STATUS

| Phase | Name | State |
|---|---|---|
| 0 | Foundations (option swap, code space, save data) | done 2026-10-17 (builds; untested on device) |
| 1 | Fish roster + solo fish | done 2026-10-17 (builds; untested on device) |
| 2 | Action menu (L1 / ACTION button) | done 2026-10-17 (builds; untested on device) |
| 3 | Fishing mode: camera, hints, rod, cast, bobber | done 2026-10-17 (builds; untested on device) |
| 4 | Bites, reeling, line breaks | done 2026-10-17 (builds; untested on device) |
| 5 | Catch reveal + fish log | done 2026-10-17 (builds; untested on device) |
| 6 | Pause FISH button + Fish menu | done 2026-10-17 (builds; untested on device) |

---

## Decisions (user, 2026-10-17)

- Fish log is per save file and kept even while Fishing is off.
- Pause FISH button is opened with R1 on a controller; an R1 hint is shown next to it while a controller is
  connected.
- L1 opens the Action menu only while Fishing is on for now. The Action menu is a dynamic list: each feature
  registers an entry with an "enabled" predicate, and entries appear or disappear with their options.
- Fish live only in the ocean (as Fish in Ocean did): open sea or near the shore, but not too close to it.
- Names: always a real fish type + a Jak 1 creature, enemy or object. No character names, no location/level
  names, no item names (orb, cell, fly, eco...).
  Eels are catchable.

## Phase 0 — Foundations (DONE 2026-10-17)

- **Option swap**: row 0x1606 now reads FISHING in all 25 `game_custom_text` JSONs; PC text marker
  `.jakios-pc-text-fishing-v12`. NSUserDefaults key `experimental.oceanFishEnabled` and GOAL `*ios-ocean-fish*`
  are kept, so a player who had Fish in Ocean on gets Fishing on.
- **Code space**: the region was never really full. `aot_level_code_link.py` grows the blob as needed; `0x04398000`
  was only the page-rounded end. The real ceiling is the host's `kLevelCodeRegionLimit` `0x04800000` (the native
  helper heap starts there), and the captured arena is zero up to it, so about **4.4 MB is free** (4,620,288 B).
  The linker now checks the whole range is empty and fails the link if the blob would pass the limit (before,
  that only showed on device as "level code disabled"), and it prints the free bytes. Relink verified
  byte-identical to the shipped blob. Host-side (C++/Swift) is still preferred for menus/UI/log.
- **Fish log storage**: `Jak1MemoryCardManager` owns the log of the game being played: `FishCaughtCount`,
  `AddFishCatch`, `ResetFishLog`, `kFishLogCapacity` 64. It is stored in each bank's McHeader data at +8 (after the
  "iOSM" mirror tag): tag "iOSF", u16 count, u16 reserved, u16 counts[64]. This area isn't checksummed and desktop
  OpenGOAL ignores it. Load replaces the log (zeros for saves without the tag), every save writes it, and the New
  Game slot screen clears it (SyncMirrorMode).
- **Roster**: `jakIOS/Runtime/IOSFishRoster.h`, `kFishSpecies[35]` (index = save id, append only): name, base model
  (7 stock models), colour variant, rarity, scale; `kFishRaritySpawnWeight` 200/80/30/10/3. A static_assert ties it
  to the log capacity. GOAL gets the table from the host in Phase 1.

## Phase 1 — Fish roster + solo fish (DONE 2026-10-17)

- **Solo fish**: `ios-fish-school` is now the swimming brain of exactly one fish (count 1, fish at its centre);
  at most 10 fish/schools. Spawns need fish water at the spot AND 7 m N/E/S/W of it (`ios-fish-shore-clear?`), so
  no fish starts right at a shore; look-ahead 3 → 5 m so they turn away from shores earlier. Ocean only, as before.
- **Roster in GOAL**: `*ios-fish-roster*` (ios-fish-roster: count +0, 64 x 32-byte ios-fish-species-info from +16:
  model, rarity, scale, weight, tint rgb + glow w) is made with count 0 by the startup object. Host
  `SyncFishRoster` (every 60 frames, after SyncOceanFishOption) copies `IOSFishRoster.h` into it. A species'
  weight = its rarity's weight / species of that rarity (odds about 62 / 25 / 9 / 3 / 1 %).
- **Species roll**: `ios-fish-random-species`; Epic+ (rarity >= 3) only where the water column is >= 12 m (open
  sea, or deep water). The fish and its school keep the species id (`species` field) for Phase 4.
- **Eel**: catch-fishc is now resident art (kOceanFishArt) and in `Jak1Level-ios-fish.fr3z` (custom levels
  marker `.jakios-custom-levels-v3`, so the fish models rebuild once on next launch); GOAL kind 2 = FishModel::Eel,
  type `ios-fish-eel`, anim index 2, scale 0.3 (assumed catch-fish sized), slower.
- **Colours**: no renderer change. `draw-control color-mult` = tint (multiplies the lighting, so the texture keeps
  its pattern recoloured), `color-emissive` = tint * glow (0.12 Epic, 0.25 Legendary). These are applied by stock
  dma-add-process-drawable into the Merc lights.
- GOAL kinds renumbered to match FishModel (eel = 2, junglefish 3, sunken 4-6).
- Relink: same command as before (`ios-ocean-fish` startup object). Blob now ends 0x0439c000 (4,603,904 B free).
  Backup of the previous object + level code: `AOTBackup-2026-10-17-fishing1/`.
- **Device checks**: eel scale/orientation, whether the tints read clearly (dark tints at night), spawn rate with
  the extra shore probes, and the "jakIOS: Fishing: roster of 35 species written" log.
- **Roster**: 35 species, the source of truth is `IOSFishRoster.h`:
  - Common: Lurker Sardine, Hopper Minnow, Yakow Carp, Babak Bluegill, Kermit Frogfish, Lurker Batfish, Seagull
    Herring, Swamp Rat Wrasse, Lurker Mud Eel, Snow Bunny Snapper
  - Uncommon: Flut Flut Flying Fish, Bone Armor Perch, Lightning Mole Pike, Balloon Lurker Pufferfish, Lurker Crab
    Triggerfish, Lurker Puppy Dogfish, Spider Eel, Bonelurker Stonefish
  - Rare: Ram Hammerhead, Mother Spider Scorpionfish, Lurker Snake Eel, Flying Lurker Bluefin, Precursor Koi, Ice
    Cube Icefish, Yeti Lionfish
  - Epic: Driller Lurker Anglerfish, Lurker Viperfish, Bully Grouper, Lurker Shark Pup, Precursor Moray Eel
  - Legendary: Lurker Ship Sturgeon, Zoomer Swordfish, Muse Marlin, Warp Gate Barracuda, Silo Shadow Eel
- Fish names + rarity labels become PC text ids (0x161c+) with the menus (Phases 5/6).

## Phase 2 — Action menu (DONE 2026-10-17)

- **Registry** (`jakIOS/Runtime/ActionMenu.swift` `ActionMenuRegistry.providers`): one closure per feature
  returns its `ActionMenuEntry` (id, title, isAvailable, unavailableHint) while that feature is on, else nil. To add
  an action: append a provider and handle its id in `-[OGJak1RuntimeHost performAction:]`. Entries are rebuilt
  every frame. The menu, the ACTION button and the L1 takeover only exist while there is at least one entry, so
  for now only with Fishing on.
- **Input** (`Jak1MetalView.swift` `updateActionMenu`): an L1 press edge (controller) or ACTION (touch command)
  toggles the menu. While it is open the game gets a neutral pad: D-pad L/R = step, Cross = choose, Circle or
  Start = close. In gameplay with entries, L1 never reaches the game (no crouch on L1; R1 still crouches). Controls
  held when it closes are kept from the game until released, so the choosing Cross isn't a jump. It closes
  itself if gameplay ends (death, cutscene, menu).
- **UI** (`ActionMenuView`, shown by RuntimeShellView above the touch layer, also with a controller): dimmed
  screen, a large bronze-ring disc in the touch-control style (`PadStyle`, now internal), an "ACTIONS" header in
  Ottselesque, and a wrap-around carousel (neighbours faded, chevrons and dots when there are 2+ entries). It
  steps one entry per swipe (swipe left = next) and taps the disc to choose. Tapping outside or BACK (top-left,
  touch only) closes it. Footer: "TAP TO SELECT" (touch) or ✕ SELECT / ○ CLOSE (controller). Unavailable entries
  are dimmed with their hint.
- **Drawn by GOAL since 2026-10-17** (user: same font as the options menus; dim over the whole screen): SwiftUI
  `ActionMenuView` is now only a full-screen, safe-area-ignoring touch layer (swipe = step, tap on the disc =
  choose, tap outside = close) plus BACK. Swift passes the entries each frame while open
  (`setActionMenuTitles:hints:available:selection:controllerHints:`, host dedups); `SyncActionMenu` writes them
  game-encoded into `*ios-action-menu-view*` (count/selection/controller/available bits + 8 title and 8 hint GOAL
  strings filled in place). `ios-action-menu-draw` (menu-hook, while open and paused) draws in the debug bucket in
  512x224 screen units: full-view dim quad (alpha #x34), socket + orange glass fans, bronze ring strip (angular
  light/mid/dark), glow line, arrows/dots for 2+ entries; then `print-game-text`: ACTIONS (progress-yellow 0.8),
  centred title (default 1.0, dimmed when unavailable), neighbours (0.5), hint (progress-blue 0.5), footer
  (<PAD_X> SELECT <PAD_CIRCLE> CLOSE or TAP TO SELECT). Disc radius 96 of 224 high, rx scaled by
  512/(224*aspect-ratio) so it stays round.
- **Touch button**: ACTION capsule under HUD (top right), only while the menu can open.
- **Pause**: new startup object `pc/ios/ios-action-menu.gc` (relink: `--startup-object ios-action-menu` LAST,
  after ios-green-eco; game.gp + build.sh STARTUP_OBJECTS updated). Host writes `*ios-action-menu-open*`; GOAL
  sets the pause process-mask bit + sound-group-pause (like master mode 'pause, minus its "PAUSED" text, staying
  in 'game). It publishes `*ios-action-menu-allowed*` (master mode game, no progress, progress-allowed? and
  pause-allowed?, not title).
- **Fish availability**: `*ios-can-fish*` (ios-ocean-fish.gc, 5x/s): Jak in a plain standing/walking state, not
  driving, 0.5 m below to 6 m above the sea, and one of 8 points 4 m around him has fish water (2.5 m+ column).
  That covers shores, docks and the boat deck. The host ANDs it with Fishing on.
- Choosing Fish now only logs "jakIOS: Action menu: Fish chosen" (host `fishingRequested`, consumed in
  SyncActionMenu): Phase 3 starts fishing mode there.
- **Device checks**: pause really freezes Jak/enemies/sound and resumes cleanly; L1 no longer crouches; the
  ACTION button position; menu look/size on phone and iPad; Fish dims away from water.

## Phase 3 — Fishing mode (DONE 2026-10-17)

New startup object `pc/ios/ios-fishing.gc` (relink: `--startup-object ios-fishing` LAST, after ios-action-menu;
game.gp + build.sh updated). Host `SyncActionMenu` writes `*ios-fishing-request*` when Fish is chosen;
`ios-fishing-update` (menu-hook) spawns `ios-fisher` if `*ios-can-fish*`.
- **Mode**: process-grab? Jak (refused if he can't be grabbed), `'draw #f` hides Jak + Daxter, camera
  `cam-fixed` steered every frame (the newest slave's saved-pt/trans = eye 1.6 m above Jak; tracking inv-mat from
  forward, 9 degrees down). Yaw only: left stick, right stick (= touch swipes), d-pad at 90 degrees/s, clamped
  +-80 degrees around the starting facing. Exit: O (presses eaten incl. *cpad-history-list*), death/cutscene (Jak
  no longer target-grab), or Fishing turned off. `*ios-fishing-active*` blocks the Action menu.
- **Hints**: top right at the boat's spot (464, 26, right-aligned, scale 0.7): PRESS <SQUARE> TO CAST / <X> TO
  REEL IN / <CIRCLE> TO EXIT; shown 5 s after fishing starts, then faded out over 1 s (user 2026-10-17).
- **Rod**: import builds `Jak1Level-ios-rod.fr3z` (custom levels marker v4): `AppendTieRodAsTfrag` takes ONE of
  village1's 4 `vil1-fishingpole.mb` instances (pieces = strips joined by shared vertices; first piece taller than
  2 m seeds the axis; pieces whose centre is within 0.8 m of the axis, refitted once; 15 pieces / 116 triangles,
  nearest other piece 0.90 m) and stands it upright with PCA (base = origin, +y to the tip, 7.09 m). Verified offline
  with a Mac harness (/tmp/rodprobe, libjak1_extractor macos). `EmitTieTrisAsTfrag` was split out of
  AppendTieProtoAsTfrag; flut pad and vent ring are geometrically identical to before.
  GOAL `*ios-fishing-rod*` (base w=1 + world x/y/z axes, scale 0.36 = 2.55 m) -> host `SyncFishingRod` (after each
  kernel frame) -> `jak1::SetFishingRod` -> Jak1Background draws ios-rod (pinned with the fish) in the first
  opaque tfrag pass with rot'[j] = sum_i A[j][i] rot[i], trans' = camera position in rod coordinates. Pose: base
  0.45 m right, 0.55 m down, 0.6 m ahead of the eye; 45 degrees up, tip leaning 14 degrees inward. Rolled 90 degrees
  counter-clockwise about its length (user 2026-10-17) so the purple reel points down, not left.
- **Cast (Square, when ready)**: swing 0-0.25 s back to 80 degrees, snap to 15 degrees by 0.4 s, settle by
  0.8 s; at 0.33 s the bobber is thrown to water 11-17 m ahead (stepping 1.5 m nearer until
  ios-fish-water-column passes; no water ahead = no cast), 1.1 s arc 3.5 m high.
- **Bobber**: `ios-fishing-bobber` = *money-sg* (precursor orb) at scale 0.35, tinted red (color-mult 1.4 .32 .28,
  emissive .25 .05 .04). Hangs 0.8 m under the tip when ready; floating: ocean-get-height + bob, slow random drift
  (max 0.15 m/s) that stops before shallows.
- **Line**: `ios-fishing-draw-line`: 12 segments tip -> bobber (sag 5% of length when floating), each point through
  transform-point-qword!, a screen-space triangle strip 1 game px wide, colour 150 150 140, in the debug bucket with
  test-1 ztst gequal + zbuf zmsk (no z write), test restored to always after.
- **Reel (X)**: +0.7 m per press, pulled in at 4 m/s towards Jak; within 2.2 m (xz) = back to ready.
- For phases 4/5: `*ios-fishing-bobber-pos*`, `*ios-fishing-phase*` (-1 off, 0 ready, 1 flying, 2 floating).
- **Device checks**: rod placement and look (it can clip into nearby walls; the tfrag pass must run that frame),
  line visible/thickness, the bobber model and tint, camera blend in/out, the touch overlay still usable (left stick
  turns, face buttons work), exit restores Jak + camera, the eye height on the boat.

## Phase 4 — Bites, reeling, line breaks (DONE 2026-10-17)

- **Fish side** (`ios-ocean-fish.gc`): `ios-fish-school` got `lure-mode` / `lure-time`; `ios-fish-school-lure` swims it
  instead of the normal steering (and it is never despawned): APPROACH = turn to the bobber at 90 deg/s, up to
  1.8 m/s slowing near it, rise to 0.6 m under the surface; HOOKED = pinned 0.6 m under the bobber, facing away from
  Jak with a wiggle; FLEE = 5 m/s away from the bobber, down to the floor, removed after 2.5 s.
- **Fisher side** (`ios-fishing.gc`), every 0.5 s while floating: with no fish coming, each swimming fish within
  12 m of the bobber gets 25% x eager to come over (eager = 1 - 0.15 x rarity: Common 1.0 .. Legendary 0.4); one
  at a time. Once it is within 1 m it bites with 40% x eager per check; after 10 s without a bite it loses
  interest.
- **Bite**: phase HOOKED (3), bobber shake (sinks 0.2 m and jitters, fading over 1.25 s, then a faster, deeper
  bob), sound "smack-surface", "CAUGHT!" (progress-yellow, 1.6 s, fading).
- **Hooked**: the fish pulls the bobber away from Jak at 0.5 + 0.15 x rarity m/s (up to 20 m of line); each X
  reels 0.7 m and adds 0.35 tension (decays 0.7/s). The line is nearly taut (1% sag).
- **Break**: per X press while hooked, chance 2% + 1.5% x rarity + 12% x (tension - 1 if above 1). That plays
  "yellow-fizzle", shows "GOT AWAY" (red), the fish flees, and the rod is ready again. Leaving fishing mode with a
  fish on also makes it flee.
- **Landed** (bobber back within 2.2 m with a fish on): `*ios-fishing-landed-species*` = its species,
  `*ios-fishing-landed-count*` +1, the fish is removed, and "LANDED!" (placeholder until phase 5's reveal) shows.
  The host logs "jakIOS: Fishing: landed a <name>" (SyncActionMenu). Not yet added to the save's fishing log
  (phase 5).
- Sounds are from the common bank (the fishing minigame's "get-small-fish" etc. are in the jungle bank, not loaded
  at sea).
- **Device checks / tuning**: bite frequency (notice 25%/bite 40%), pull vs reel speed, break odds, the sounds.

## Phase 5 — Catch reveal + fish log (DONE 2026-10-17)

- **Landing** (`ios-fisher-land`, ios-fishing.gc): the school is removed, sound "cell-prize" plays,
  `*ios-fishing-landed-species*` / `-count` are set, a `ios-fishing-trophy` child is spawned, and the phase goes to
  REVEAL (4). The "LANDED!" placeholder is gone.
- **Trophy**: that species' model (ios-fish-skel / anim / scale from ios-ocean-fish.gc) with its tint, at the
  model's ocean scale x (0.75 + 0.25 x species scale), 2.4 m in front of the eye and 0.15 m below the middle,
  side-on and turning at 50 degrees/s, swimming animation.
- **Text** (`ios-fishing-draw-reveal`, game font): the name at the top centre (1.0); the rarity on the right (0.8):
  COMMON white, UNCOMMON green, RARE cyan, EPIC pink, LEGENDARY orange; "NEW DISCOVERY!" under it (0.6,
  progress-yellow, pulsing) on the save's first catch of that species; "PRESS <X> TO CONTINUE" at the bottom. X
  removes the trophy and goes back to ready.
- **Log** (host `SyncActionMenu`): when the landed count goes up, it checks
  `jak1::memcard::FishCaughtCount(species) == 0` (= new), calls `AddFishCatch`, writes the game-encoded name into
  `*ios-fishing-reveal*`, then new, then serial = the count (GOAL shows the text once serial matches). Logs
  "jakIOS: Fishing: landed a <name>[, new discovery] (N caught)". The log goes into the save on the next save
  (bank header "iOSF", phase 0), whether Fishing is on or not.
- **Device checks**: trophy size/position per model (the eel and the sunken fish may need their own scale), text
  positions, "cell-prize" fits.

## Phase 6 — Pause FISH button + Fish menu (DONE 2026-10-17)

- **Button**: `PauseFishButton` (RuntimeShellView, above the touch layer so it also shows with a controller) on the
  pause menu's collectible pages while Fishing is on: a FISH capsule right of RESUME (same scale/paddings as the
  touch menu controls), plus an R1 badge while a controller is connected. Tap -> `menuOpenFish`; R1 (controller):
  host `SyncFishMenuShortcut` (post-frame, button0-rel R1 on a collectible page) queues the same event.
- **Transition**: the FishMenu menu event injects Circle (the collectible pages' Options press: push! + slide to
  Settings); post-frame `SyncIOSFishMenu` rewrites next-display-state 3 -> 41 within 90 frames (the slide-out takes
  several frames before enter!). Same transition as Options; the stock BACK (Triangle) pops back to the page.
- **Screen**: progress-screen 41 (mouse-options; unused on iOS, drawn by progress-pc.gc with draw-options 115 25
  0.65). `InstallIOSFishMenu` (after the Dev Menu install): 35 rows (copies of the Back button, type button) sorted
  rarest last (stable by roster order), plus the stock Back row; remap[41] is re-asserted every frame. Touch taps
  and scrolling use the default option-list layout.
- **Text**: 64 new ids 0x1630-0x166f ("??????" in all 25 game_custom_text JSONs, PC text marker
  `.jakios-pc-text-fish-menu-v13`). While the Fish screen is (about to be) up, the host points each id's
  *common-text* entry at its own GOAL string (re-pointed every frame, for language changes) and writes
  "NAME  X3" (caught, capitals) or "??????". Uncaught rows get the always-disabled predicate (grayed, skipped).
- **Preview**: Cross on a caught row -> host writes `*ios-fish-menu-preview*` = species; `ios-fish-menu-preview`
  (ios-fishing.gc, mask without pause/menu so it runs in the pause menu) shows that fish 2.4 m out and 1.25 m to
  the right of the camera, turning, with its tint; leaving the screen sets -1.
- The reveal name (phase 5) is now uppercase too.
- **Device checks**: the FISH button position next to RESUME, R1 on collectible pages (no stock R1 use there),
  the redirect landing on the Fish menu (not Options), the list's look at scale 0.65, the preview placement in the
  pause menu (camera space) and that it is drawn while paused.

## Tweaks after phase 6 (user 2026-10-17)

- **Catch reveal lock**: X does nothing for `IOS_FISHING_REVEAL_LOCK` (3 s) after the reveal appears;
  "PRESS <X> TO CONTINUE" only appears (fading in over 0.3 s) once it works.
- **Reveal in front of everything**: the rod (`*ios-fishing-rod*` w = 0), line and bobber
  (`*ios-fishing-bobber-hidden*` -> draw-status hidden) are hidden during the reveal, and the fish is drawn
  `IOS_FISHING_SHOW_DIST` 1.0 m from the eye at `IOS_FISHING_SHOW_SCALE` (1/2.4) of its earlier size: same size on
  screen, but nothing in the world can come between it and the camera. The reveal text is in the debug bucket, above
  the 3D scene.
- **Line breaks a little rarer**: per press 1.4% (was 2%) + 1% (was 1.5%) per rarity + 8% (was 12%) per unit of
  tension over 1.
- **Fish menu layout**: while screen 41 is the one shown, `SyncIOSFishMenu` raises the progress menu's left-x-offset
  by 62 (draw-options and the touch hit test both use it), so the list sits on the left; restored when another screen
  shows. Cross on a caught fish: the preview (same close-to-camera trick) is placed by projecting test points so it
  lands at screen (400, 92) in 512 x 224 units, with its rarity (coloured, 0.7) and "CAUGHT: N"
  (`*ios-fish-menu-preview-count*`, written by the host) under it.
- **No boat prompt while fishing** (user 2026-10-17): `fishermans-boat-ios-board?` (fishermans-boat.gc) treats the
  boat as not boardable while `*ios-fishing-active*`, so the stock "press O to use" prompt (and its hide-hud /
  hint suppression) doesn't show while fishing from the deck, and the O that leaves fishing can't take the wheel in
  the same frame. Previous boat object: `AOTBackup-2026-10-17-fishing1/fishermans-boat-before-fishing-prompt.o`.
- **Fish menu fix 2 (user 2026-10-17: backdrop gap on the left, tapping a fish showed nothing)**. Replaces the
  left-x-offset shift and the near-camera fish above:
  - left-x-offset is no longer touched (it also positions the menu backdrop, which left a gap). The stock rows are
    blank; `ios-fish-menu-draw-list` (ios-fishing.gc, menu-hook, while display-state is 41) draws the 6 visible rows
    left-aligned at x 36, y 40 + 25k (same rows as draw-options 115 25, so taps/cursor/scroll go through the stock
    rows) from `*ios-fish-menu-list*` (host: count, first row = *progress-scroll* start-index, row strings, caught
    flags). Selected = progress-selected, uncaught = menu-invalid. The Back row is gone (BACK / Triangle go back).
  - The preview follows the highlighted row (a tap highlights it) instead of a Cross press the host never saw.
  - Shown fish (menu preview and catch reveal) are drawn like the pause menu's 3D orb/cell icons:
    `dma-add-process-drawable-hud`, screen-space trans (x - 256, y - screen-sy, z 1024) and scale
    `IOS_FISHING_HUD_SCALE` 0.034 x the model's ocean scale (x relative-x/y-scale, y negated x 1.16). So they are on
    top of the world, the rod and the menu backdrop. Preview at (384, 92) of 512 x 224 with rarity + CAUGHT under it,
    at 0.75 size; reveal fish at the screen centre, a little low.
- **Fish menu fix 3 (user 2026-10-17)**:
  - Preview behind the pause panels: screen-space Merc buckets come before `sprite` (66), where the menu panels are.
    Shown fish now use `ios-fishing-dma-add-hud` (draw-bones-hud-merc with *hud-lights* tinted by color-mult /
    color-emissive, since the stock HUD path drops the tint) and stamp light direction 0 w = #x46495348; the renderer
    (Jak1MetalRenderer.mm `MercSubmission::onTop`) draws such submissions at the debug bucket's trace offset, i.e.
    after every sprite and before the menu text. The preview's rarity / CAUGHT text is drawn from the menu hook
    (after the pause menu drew), like the list.
  - Cursor skips "??????": `SyncIOSFishMenu` (post-frame) moves option-index off an uncaught row to the next caught
    one in the pad step's direction (Up/Down in button0-rel; swipes inject those too), or back to the last caught one
    (a tap on "??????", or nothing further that way); starts on the first caught fish; keeps the 6-row window
    (*progress-scroll* start-index and the GOAL list's start) around it.
  - B / Circle backs out: `gFishMenuCircleIsBack` (set while screen 41 is up) turns Circle into Triangle in
    cpad-get-data.

## Round of fixes (user 2026-10-17, after device test)

- **Shown fish invisible** (reveal + menu): `draw-bones-hud-merc` only copies the lights for envmap effects and
  sends every other effect "mercneric" (to the generic renderer), so the Metal Merc path drew nothing. Back to the
  stock generic `draw-bones-hud` (as the pause menu's icons) via `ios-fishing-dma-add-hud`, which writes the HUD
  lights tinted by color-mult / color-emissive. Over the menu panels: GOAL `*ios-fishing-hud-on-top*` (trophy or
  preview up) -> host `SyncFishingRod` -> `Jak1RendererSetHudModelsOnTop` -> Generic2 batches with `usesHud` are
  drawn at the debug bucket's trace offset (after the sprites, before the text). The Merc "HSIF" marker is gone.
- **Line breaks 25% rarer again**: 1.05% + 0.75% x rarity + 6% x (tension - 1).
- **Rod jitter when turning**: the rod pose is now in camera space (`*ios-fishing-rod*` origin w = 2; axes along
  *math-camera* inv-camera-rot rows, up sign checked against world up) and Jak1Background places it with the
  camera of the frame it draws (world = trans + rot columns x camera coords). The rod tip for the line is taken
  through the same *math-camera* the line is projected with.
- **Action menu no longer pauses**: the game runs, the app still gives it a neutral pad. `*ios-action-menu-allowed*`
  goes false as soon as Jak is hurt (target-hit / target-death or health dropped since the last frame), so the app
  closes the menu and returns control at once. Drawn while open and allowed.
- **Line to the top of the bobber**: ends `IOS_FISHING_BOBBER_TOP` 0.4 m above the bobber's origin.
- **Reveal text up**: rarity y 100 -> 72, NEW DISCOVERY! 120 -> 90 (clear of the touch Triangle button).
- **Landing splash**: "water-drop" + `splash-spawn` 0.4 (small water splash particles) where the bobber lands.
- **Fish colours in the water**: swimming fish use the tint exaggerated 1.6x away from white (min 0.15) and always
  self-lit by (glow + 0.18), so the species colours show through the ocean (the reveal/menu keep the plain tint).
- **Shark 25% rarer**: swim delay 3-35 s -> 4-47 s, boat 15-75 s -> 20-100 s (fishermans-boat.gc).

## Round of fixes 2 (user 2026-10-17)

- **Fish menu / reveal model, re-evaluated**: the only shown-fish setup ever seen working was a normal world model
  close to the camera; neither HUD route showed these models (`draw-bones-hud-merc` hands non-envmap effects to
  generic; the generic HUD route was never seen to draw them either). So both are world models again,
  `IOS_FISHING_SHOW_DIST` 1 m out at `IOS_FISHING_SHOW_SCALE` (`ios-fishing-view-place` projects test points to put
  them at a screen position: reveal (256, 118), preview (384, 92) in 512 x 224 units). To get over the pause panels
  they are marked: `ios-fishing-show-tint` sets color-mult w = 0 and color-emissive w = #x3f800001 (1.0000001), so
  the Merc packet has light colour w 0 and ambient w exactly that (dma-add-process-drawable: ambient x mult +
  emissive); the renderer (`MercSubmission::onTop`) draws those at the debug bucket offset, after every sprite.
  The HUD-generic reorder and `*ios-fishing-hud-on-top*` were removed.
- **PAUSE hidden on the catch screen**: host `gFishingRevealActive` (from `*ios-fishing-phase*` == 4) -> app hides
  the touch PAUSE button (slot kept) and cpad-get-data drops Start, until X clears the reveal.
- **Shark half as often again**: swim 8-94 s, boat 40-200 s.
- **Line breaks half as often again**: 0.525% + 0.375% x rarity + 3% x (tension - 1).
- **Landing splash sound**: "smack-surface" (the bite's water slap) at full volume; "water-drop" wasn't audible.
- **Fish menu preview, real cause (user 2026-10-17: it flashed for a frame on unpausing)**: the preview process kept
  the `progress` process-mask bit, so it never ran while the pause menu was up (no pose -> not drawn). Its mask now
  clears pause / menu / progress, like the pause menu's own 3D icons (hud-classes.gc).
- **Splash sound**: "swim-stroke" (Jak landing in water, target.gc) for the bobber landing and for the bite.
- **Menu preview, next theory (user 2026-10-17: it now draws fully on unpause, never while paused)**: the pause
  menu's dimming is drawn in the debug bucket, and marked fish were drawn at its start, under it. They are now drawn
  where the next reached bucket after debug (67) starts, i.e. after the menu text and dimming. The renderer logs
  "jakIOS: Fishing: shown fish reaching / no longer reaching the renderer" whenever that changes, to tell
  "not submitted while paused" from "submitted but covered" if it still doesn't show.
- **Camera on the catch screen**: no turning while phase is REVEAL.
- **Fishing view**: eye 1.9 m above Jak (was 1.6), camera fov `IOS_FISHING_FOV` 74 degrees (set on the cam-fixed slave
  every frame).
- **Menu preview, from the device log (2026-10-17)**: with the pause menu up, the console showed "shown fish reaching
  the renderer (drawn after bucket offset 256208)" for catch-fishb, so the fish IS submitted and drawn last, yet
  unseen. Remaining cause: depth. The pause menu's 2D panels are GS sprites at z #x3fffff (the nearest depth) and
  write it, so a 3D model drawn after them fails GEQUAL. Jak1MetalRenderer now draws a full-screen depth reset
  (`_depthResetPipelineState`: the pcrtc triangle at depth 0 with colour writes off, depth always + write) once per
  frame right before the first marked fish.

### Cast swing (user 2026-10-17)
- Swing is larger: back to 95 degrees (was 80), forward snap to 0 degrees (was 15), same timing (`ios-fisher-rod-angle`).
- The forward snap (t = 0.25 s) plays Jak's punch woosh: common-bank sound `punch` (`whooshed` flag per swing).

### Round of fixes (user 2026-10-18)
- Catch reveal: fish centre moved down to screen y 132 (`IOS_FISHING_TROPHY_Y`, was 118) so it no longer covers the name.
- Fish menu touch scrolling: a swipe moved the window, then the "cursor only stops on caught fish" step in
  SyncIOSFishMenu sent the cursor back to the last fish, which scrolled the window straight back. Now, when the
  window moved without a pad step, the cursor stays in the new window (nearest caught fish there, else where it is).
- Names: NEW RULE = short, real fish type + a word for the fish's look/tint; no other animal names (plus the old
  bans: characters, locations, items). All 35 renamed in IOSFishRoster.h (display only; ids unchanged).
- In-water colours: tint exaggerated 2.6x (was 1.6x), clamped 0.1-2.2, glow = tint glow + min(0.45, 1.1 * distance
  from white) (stock-coloured species stay unlit).
- Boat camera: while driving, cam-stick farther than 45 m from Jak snaps back behind the boat
  (`fishermans-boat-ios-camera-snap`, then `'teleport` to *camera*).

### Round of changes (user 2026-10-18, part 2)
- Cast: 13-20 m (was 11-17 m), `IOS_FISHING_CAST_MIN/MAX`.
- 15 regional species (ids 35-49), 3 per region (Common / Uncommon / Rare): FishRegion in IOSFishRoster.h,
  `region` in ios-fish-species-info (struct now #x30, roster #xc10; host GoalSpeciesInfo 48 bytes). Region =
  Jak's current level (village1 / beach / misty / village2 / swamp). Spawn weights come from the region-Any species
  only; a regional one weighs the same as one of those.
- Fish water = ocean OR a harmless water-vol (Boggy Swamp's water is water-vols, not the ocean): the manager lists
  live non-deadly water-vols every second (`*ios-fish-vol-list*`, iterate-process-tree); `ios-fish-surface` /
  `ios-fish-vol-surface` / `ios-fish-jak-surface` replace ocean-get-height; volume water needs a 1.5 m column
  (sea 2.5 m). Untested: swamp volume shapes/depths unknown.
- Can-fish: rings at 4/8/12 m (was exactly 4 m) in 8 directions nearest Jak's facing first, Jak up to 10 m above
  the water (was 6), wading states count; the direction found (`*ios-fish-water-yaw*`) is where fishing starts facing.
