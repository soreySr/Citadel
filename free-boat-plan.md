# Free boat plan: a driveable boat that does not need Sandover loaded

Goal: with the Driveable Boat option on, the boat you drive is not a village1 actor, so the ocean manager can
load any two levels (e.g. Rock Village + Boggy Swamp) instead of always keeping Sandover in one slot.
With the option off nothing changes: the stock fisherman ride/cutscene boat stays as it is.

Do one phase per session. Each phase ends in a buildable, testable state; stop and report after each one.

## Background (read first in a new session)

- Memory notes: driveable-boat, expanded-flut-flut, level-memory-residency, eroded-coast-water (relink command).
- The boat today: `fishermans-boat` actor `fishermans-boat-2` (aid 10419) in village1,
  `OpenGOAL/goal_src/jak1/levels/village1/fishermans-boat.gc`. Its init-from-entity! spawns `ios-ocean-manager`
  (`:to this`), which spawns `ios-ocean-shark`. Parking spot lives in the entity perm (`pc/ios/ios-boat-park.gc`).
- Boat code `fishermans-boat.o` is already prelinked in the signed image. Its art (`fishermans-boat-ag`, ~83 KB
  in VI1.DGO) and textures (village1 tpages) live in the village1 level heap -> gone when village1 unloads.
- Precedent for level-independent art: Expanded Flut Flut. Host `LoadExpandedFlut` in
  `jakIOS/Runtime/OpenGOALRuntimeHost.mm` links art from a DGO into the global heap while `loading-level` is
  `level-default`; `KernelEnvironment::skipDgoObject` (`Jak1Kernel.cpp`) drops the duplicate when the DGO loads;
  the renderer pins `Jak1Level-ios-flut.fr3z` (built by `tools/flut/flut_merc_fr3.cpp`) via
  `SetExpandedFlutModelEnabled` (`Jak1Background.mm`).
- Rebuild per GOAL change: goalc in /tmp/og-title, copy .o to OpenGOAL/out/jak1/obj, full relink command
  (eroded-coast-water memory + `--startup-object ios-blue-eco-swim --startup-object ios-boat-park`), touch
  `jakIOS/Runtime/Jak1AOTSignedImage.s`, BuildProject. Back up blob/manifest/.o to `AOTBackup-<date>-<tag>/` first.

## Phase 1: resident boat art + model (host side only)

DONE 2026-10-09 (builds; untested on device). What was actually done (differs from the notes below):
- VI1.DGO has two objects named `fishermans-boat`: v3 code and v4 art (link header 0xffffffff, version 4,
  82976 bytes). `LoadResidentBoatArt` (OpenGOALRuntimeHost.mm) links the v4 one in place in the global heap
  while loading-level = level-default, once per session when the option is on; log
  "jakIOS: Driveable Boat: resident boat art (82976 bytes) at 0x...".
- Kept the stock name (no rename, nothing skipped from VI1). CORRECTION (phase 2): initialize-skeleton loads
  from `(-> entity extra level) art-group`, so the village1 actor keeps using village1's copy; only a process
  whose entity links point at level-default (the free boat) gets the resident one.
- Shared helpers `LinkResidentArtObject` / `IsLoadingLevelDefault` (flut loader now uses them as well).
- Fixed host `loado` (native case 4) to return #f like upstream instead of 0: merc login of art whose tpage is
  not loaded calls texture-page-login -> loado, and 0 is truthy -> relocate on object 0 (also affected flut).
- `tools/boat/boat_merc_fr3.cpp` -> `jakIOS/Runtime/Jak1Level-ios-boat.fr3z` (fishermans-boat-lod0/lod1,
  35 textures, 235 KB); pinned via `SetResidentBoatModelEnabled` (Jak1Background).
- Phase 2 note: the boat's code (`*fishermans-boat-sg*` etc.) is defined by VI1's top-level; the free boat
  will need its code available without VI1 (e.g. `linkPrelinkedCodeObject("fishermans-boat")` once, like the
  flut does for target-flut — check that VI1 relinking it later doesn't reset state the free boat relies on).

Original notes:

Get the boat's art and model to stay loaded no matter which levels are loaded. No gameplay change yet.
- Inspect `fishermans-boat-ag` in VI1.DGO: which art objects the boat needs (skeleton, joint anims, collide
  mesh, merc model), and whether evilbro/evilsis share it (the ride cutscene uses them; we only need the boat).
- Host: `LoadResidentBoatArt` modelled on `LoadExpandedFlut`: when the option is on, link the boat art from the
  player's VI1.DGO into the global heap at level-default load time. Leave it registered under a separate name
  (e.g. `ios-boat-ag`) so it does NOT clash with village1's own copy and no `skipDgoObject` is needed: the stock
  boat keeps using village1's art.
- Renderer: `tools/boat/boat_merc_fr3.cpp` (copy of the flut tool) -> `Jak1Level-ios-boat.fr3z` with the boat
  merc model + its textures out of village1.fr3; pin it with `SetResidentBoatModelEnabled`.
- Check global heap free space before/after (flut uses ~640 KB; boat should be ~100-200 KB).
- Test: option on, boot, debugger/log shows the art group in the global heap and the fr3z pinned; no crash on
  title or Sandover load; Sandover boat unaffected.

## Phase 2: `ios-free-boat` process, drawn and driveable near Sandover

DONE 2026-10-09 (builds; untested on device). As built, all in fishermans-boat.gc (og:ios free boat):
- The free boat is the SAME type `fishermans-boat` (so every iOS drive/idle behaviour is reused), spawned
  `:to *entity-pool*` with `fishermans-boat-ios-free-init-by-other` (args: the actor). It copies the actor's
  trans/quat and the whole inline `rbody` (momentum), dock-point-index -1, then goes `fishermans-boat-ios-drive`.
- Stand-in entity `ios-free-boat-entity` (define-perm `*ios-free-boat-entity*`, made once in 'global): empty
  `entity-actor` res-lump + `entity-links` with level = level-default, process #f. Needed because
  method-29 (water-actor), path-control, nav-mesh-connect and initialize-skeleton all read the entity.
- Tracking: define-perm `*ios-free-boat-ppointer*` + `*ios-free-boat-pid*` -> `(ios-free-boat)`;
  `(fishermans-boat-ios-free? boat)` = entity is the stand-in. Host writes `*ios-boat-art-resident*` each frame.
- Handoff `fishermans-boat-ios-take-wheel` replaces the 3 `(go fishermans-boat-ios-drive)` after
  `fishermans-boat-ios-board?` (ios-idle + both docked states). No resident art -> old behaviour (actor drives).
- Actor state `fishermans-boat-ios-hidden`: draw hidden, collide cleared, engine off, no post; deactivates once
  the free boat is gone -> entity reborn by actors-update at the parked spot. init-from-entity! goes hidden
  first if a free boat exists.
- `fishermans-boat-ios-free-check` (drive + idle trans): free boat deactivates when the option is off or the
  title level is loaded. `deactivate` only clears the shared *ios-boat-...* flags if it is the free boat or none exists.
- Ocean manager: `(ios-ocean-boat)` = free boat if alive else parent actor (look-ahead, long-view, shark).
- Known gaps for later phases: the manager + shark are still children of the actor (die with village1);
  parking still writes the actor's perm (works without village1 via game-info copy); free boat persists across
  death/save-load at its last position; VI1 relink re-runs `define`s (*ios-boat-driving*, -borders-off,
  -boardable) mid-drive — matters once village1 can load while driving (phase 4); "boat-engine" sound is in
  village1's sound bank (phase 4).
- Backup: AOTBackup-2026-10-09-freeboat2/ (pre-phase-2 .gc/.o/blob/manifest).

Original notes:

A new process type that is not an actor, using the resident art; still keep village1 loaded (manager unchanged).
- GOAL: new `ios-free-boat` in a new file (e.g. `pc/ios/ios-free-boat.gc`, startup object, or inside
  fishermans-boat.gc if it must share its types). Same rigid-body-platform base and parameters as
  `fishermans-boat`; skeleton from the resident `ios-boat-ag` skel group; spawned into the global process tree
  (`*entity-pool*` or `*active-pool*`), not from an entity.
- Reuse the existing iOS drive code (controls, hold-player, camera-follow, steady, shore probe, turn-in-place,
  borders-off, hints, sounds). Factor those helpers to take the boat object rather than assume the actor, where
  needed (they mostly use `self` fields that both types will share).
- Handoff: when the option is on and Jak boards the Sandover boat (`fishermans-boat-ios-board?`), hide the actor
  (draw off, collision off) and spawn/place `ios-free-boat` at its transform; Jak drives the free boat. The actor
  stays hidden while the free boat exists. Option off -> free boat killed, actor shown again.
- Test: drive around Sandover exactly like today (speed, steering, camera, O exit, sound). Expect the free boat
  to still die if village1 unloads only if something parents it to village1 — check it does not.

## Phase 3: move the ocean manager, shark and parking onto the free boat

DONE 2026-10-10 (builds; untested on device). As built:
- Host `LoadResidentBoatArt` now also `linkPrelinkedCodeObject("fishermans-boat")` at boot (code only requires
  engine files) and loads the `sharkey` v4 art from VI1.DGO next to the boat art; `*ios-boat-art-resident*`
  only goes #t when code + both art groups are in. Jak1Level-ios-boat.fr3z now also has sharkey-lod0
  (3 models, 46 textures, 287 KB).
- Sound: nothing to do. The mod-base level.gc loads ALL level sound banks at boot and never unloads them
  (Jak1OverlordSound.cpp kNumBanks comment), so "boat-engine" (VILLAGE1.SBK) plays anywhere; shark sounds
  are in COMMON.SBK.
- Ocean manager: standalone singleton in *entity-pool* (`ios-ocean-manager-ensure`, registry
  `*ios-ocean-manager-ppointer*`/`-pid*`), given the stand-in entity in its init, so its shark inherits it
  (process `activate` copies the parent's entity) and loads the resident sharkey art. The actor only spawns
  its own child manager when the art is NOT resident (legacy); a leftover child manager kills itself.
  `ios-ocean-boat` = free boat, else the actor via `entity-by-aid 10419`.
- Free boat at the parked spot: `ios-free-boat-update` (called each frame from ios-boat-park.gc's *menu-hook*
  when resident) ensures the manager and spawns the free boat at `ios-boat-park-get` (anchored, ios-idle) when
  none exists (not while driving / on the actor's deck). `fishermans-boat-ios-free-init-by-other` takes
  (src park): src = handoff, else parked spawn. The actor hides whenever a free boat exists
  (`fishermans-boat-ios-free-check`, also in the docked states).
- Parking storage was already level-independent (game-info perm copy, saved). The village1-'special
  hold/release in ios-boat-park.gc is skipped when resident (legacy kept for no-art fallback); the Rock
  Village no-spot rule moved to `ios-boat-park-village2-spot` and runs in both paths.
- Save load / new game: the free boat remembers what it stored (`*ios-free-boat-last-park*`); record-park
  deactivates it when the perm no longer holds that spot (>1 m or none); the update respawns it at the new one.
- *ios-boat-driving* / -boardable / -borders-off / *ios-coast-visible* are define-perm now (VI1 relink safe).
- Backup of the phase-2 state: AOTBackup-2026-10-10-freeboat3/.

Original notes:

Everything boat-related lives on the free boat; still keep village1 loaded.
- Spawn `ios-ocean-manager` from the free boat instead of the actor (`(-> self parent)` lookups in
  `ios-ocean-look-ahead`, long-view, shark boat handle etc. must point at the free boat).
- Parking: the spot must survive without village1's entity perm. Store it in a global perm record instead
  (new place in `ios-boat-park.gc`, keep the same magic/format; migrate an existing spot from aid 10419 once).
  The free boat spawns at the parked spot directly; the `*menu-hook*` logic that loads village1 'special next to
  a parked boat is no longer needed and gets removed.
- Respawn after death/continue: free boat respawns at its parked spot (or Sandover dock if none).
- Test: park at Rock Village, die, reload a save, reboot app -> boat is where you left it; shark, sea walls,
  fallback water, coast terrain still behave.

## Phase 4: let the manager drop Sandover (level pairs)

DONE 2026-10-10 (builds; untested on device). As built:
- `ios-ocean-update-levels`: with the art resident, a "south" region (manager field `south`, hysteresis
  IOS_SEA_REGION_HYSTERESIS 0.9 on nearest-south vs nearest-north distance) runs
  `ios-ocean-update-south-levels`: want village2 + swamp, each 'display once loaded, force-vis both, vis +
  respawn from the nearer. North = old village1 + nearest logic, minus village2/swamp candidates (those stay
  only for the no-art fallback). Leaving south resets primary to #f so the respawn is set again.
- `ios-ocean-arrive` 'village2/'swamp: village2 + swamp in full with the art resident; old village1-keeping
  setup otherwise. 'eroded split out unchanged.
- Removed IOS_SEA_LOOK_AHEAD / `ios-ocean-look-ahead` (the 2026-10-09 workaround).
- Stand-in coastline (Jak1Background.mm renderTfragBucket) now draws with the first opaque tfrag pass of the
  frame of ANY level (`drewCoast`, reset in beginFrame), not only village1's — it has its own textures.
- Not changed: med-res low-res island models are village1 actors, so they only exist in the north pair (fine).
- Backup of the pre-phase-4 state: AOTBackup-2026-10-10-freeboat4/.
- Transition fog (user 2026-10-10, untested): `ios-ocean-transition-fog` (fishermans-boat.gc), called every
  frame from ios-boat-park.gc's *menu-hook* (after the draw hook's update-time-of-day, before the next
  update-camera, so it lands in every renderer's fog). At sea (boat or swimming, not Fire Canyon/title):
  bal = |d-north - d-south| / (d-north + d-south); full below IOS_SEA_FOG_FULL 0.1, none above
  IOS_SEA_FOG_EDGE 0.4; lerps *math-camera* fog-start/end/min toward 20 m / 220 m / 0; strength eased
  (`*ios-sea-fog*`, ~2 s). Backup: AOTBackup-2026-10-10-seafog/.

Original notes:

The payoff: the manager picks the best two levels for Jak's position.
- Replace the "village1 + nearest" rule with pair selection, e.g.: Sandover area -> village1 + nearest
  (misty/training/beach/jungle/eroded, as now, because village1 holds their low-res stand-ins);
  Rock Village / Boggy Swamp area -> village2 + swamp (stock pairing, both displayed); between the two areas ->
  village1 + village2 or village2 alone with long-view. Keep the look-ahead + hysteresis idea for switching.
- Arrival (`ios-ocean-arrive`) uses the stock continue pairs (e.g. village2 + swamp) instead of forcing village1.
- Things tied to village1 that must be handled: med-res stand-ins (only exist with village1), the east-coast
  stand-in terrain (`SetCoastTerrainEnabled`, uses village1 textures; only show with village1 or give it its own
  textures), music bank per level, `ios-ocean-set-respawn` fallbacks.
- Remove the Rock Village/Swamp workaround from 2026-10-09 (IOS_SEA_LOOK_AHEAD) once pairs cover it.
- Test: sail Sandover -> Rock Village -> along to Boggy Swamp: both visible together, no pop-in, boat survives;
  sail back to Sandover.

## Phase 5: cleanup, edge cases, polish

DONE 2026-10-10 as a code audit (no code changes; nothing run on device):
- Option off mid-game: free boat deactivates via fishermans-boat-ios-free-check (drive :exit releases Jak and
  the camera); hidden actor reborn at its stock dock; parked spot kept, so turning the option back on respawns
  the free boat there. A child manager the actor spawns while the option is off kills itself once the art is
  resident again.
- Title: free boat removed, manager idles, transition fog fades out. New game / other save: parked-spot check.
- VI1 relink while the free boat lives: all runtime flags are define-perm; other statics restore identically.
- Legacy actor path (ios-boat-park hold/release, village1-keeping arrivals) kept as the no-art fallback.
- Boggy Swamp shore wall: not identifiable from collision. Swamp has no below-water #xa; its #xa tris are 12
  posts (1 x 5 m). Only deep floor: east edge x 648..720 z -2076..-1858, ordinary 0x1348 walls (mat13, -10..4 m).
  Needs the exact spot where the boat/Jak gets stopped before anything is removed.
- Relink command now ends with `--startup-object ios-blue-eco-swim --startup-object ios-boat-park
  --startup-object ios-dynamic-save` (dynamic save points, another session).
- Boat home on death (user 2026-10-10, untested): when Jak dies (target-death / target-flut-death) in open sea
  with the boat adrift in open sea too, `ios-ocean-return-boat-on-death` (manager, once per death) calls
  `ios-boat-park-return-home` (ios-boat-park.gc): nearer of Sandover's stock dock (parked spot cleared) and the
  Rock Village dock (spot stored). The free boat notices the changed spot and respawns there.

- Option toggled mid-game (at sea / parked far away), title screen, new game, cutscenes, fisherman minigame and
  the stock ride with the option on and off.
- Memory: watch "unloaded FR3 level" logs and global heap; confirm no leak of resident art across save loads.
- Boggy Swamp shore invisible wall (from the `plans` notes) if it blocks the boat: same noentity trick as
  `ios-ocean-sync-sea-walls`.
- Update memory notes (driveable-boat) and remove dead code from the actor-based path.
