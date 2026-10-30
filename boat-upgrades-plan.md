# Boat upgrades plan

Driveable Boat upgrades with power cells, opened from a BOAT button (replaces HUD while driving) or R2.

## User decisions (2026-10-23)
- Power cells are a threshold, not spent: level N -> N+1 needs 20 x N cells collected. Max level 6.
- Level is per save (bank header); New Game starts at 1; older saves read as 1.
- Lvl 1 is slower / turns worse than the pre-upgrade boat; Lvl 6 is much faster and turns much better.
- Menu: left "BOAT LVL" + number ("MAX LVL" at 6); right required cells + UPGRADE button (grayed if short);
  at max the right side is hidden. Modeled on the Action menu, wider.

## Phases
1. Storage + plumbing. DONE 2026-10-23 (builds, untested on device).
   - Jak1MemoryCardManager: "iOSB" tag + level after the Open Ocean block (kBoatHeaderOffset); Get/Set/ResetBoatLevel.
   - Host SyncBoatUpgrade (after SyncOpenOceanProgress): memcard level -> GOAL `*ios-boat-level*` (int, define-perm in
     fishermans-boat.gc), *game-info* fuel -> powerCells, applies requestBoatUpgrade if cells >= cost.
     New Game reset in SyncMirrorMode. boatDriving atomic set in SyncDriveableBoatOption.
   - Bridge: isBoatDriving, boatLevel, boatMaxLevel, boatUpgradeCost, powerCellCount, canUpgradeBoat, requestBoatUpgrade.
   - Level code relinked; old LevelCode backed up in build-release/backup-2026-10-23-boatlvl/.
2. Speed/turning table per level. DONE 2026-10-23 (builds, untested on device).
   fishermans-boat.gc: *fishermans-boat-ios-level-throttle* .36 .40 .45 .51 .57 .66, -steering .40 .45 .51 .58 .67 .80,
   -turn .18 .20 .22 .24 .27 .30 (turn push also scales with cruise thrust, so Lvl 6 spins ~2x the old boat).
   FISHERMANS_BOAT_IOS_MAX_THROTTLE / _TURN_IN_PLACE constants removed; fishermans-boat-ios-max-throttle reads the
   table (steady wobble ramp + turn-in-place fade use it). Throttle climb rate = 1.15 x cruise/s (same ~0.9 s to cruise
   at every level). To retune: edit the three arrays. Device checks: Lvl 6 streaming near Rock Village/swamp, shore probe.
3. BOAT button + R2. DONE 2026-10-23 (builds, untested on device). Swift only.
   - TouchInputState isBoatDriving / isBoatMenuOpen + BoatMenuCommand (toggle, close) queue.
   - Jak1MetalView updateBoatMenu (after updateActionMenu): driving = plain gameplay && runtime.isBoatDriving();
     R2 rising edge or BOAT toggles; Circle/Start close; closes itself when driving ends. While driving R2 never
     reaches the game (releasing(_:rightTrigger: false)); open = neutral pad + no camera swipes. Boat keeps
     engine/course while open (neutral pad only zeroes steering input). Held-back buttons after close as Action menu.
   - TouchControlsOverlay: BOAT pill in HUD's slot while driving; R2 trigger released on the swap.
   - Until phases 4-5 the menu is invisible: open = controls do nothing, BOAT / R2 / Circle closes it.
4. GOAL-drawn Boat menu. DONE 2026-10-23 (builds, untested on device; layout never seen).
   - ios-action-menu.gc: *ios-boat-menu-view* (open, level, max-level, cost, cells, controller, flash; #x1c),
     ios-am-rect / ios-am-frame helpers, ios-boat-menu-draw (debug bucket), ios-boat-menu-update chained in the
     same *menu-hook* (draws only while open && *ios-boat-driving* && master-mode game && no progress menu).
   - Layout (512x224 units, centre 256,112, half-height 62, half-width 62 x aspect x 2.6, capped 236): left column
     "BOAT LVL" + level (scale 2.0); right column "POWER CELLS", cost, "YOU HAVE n" (blue / red if short), UPGRADE
     button at cy+30 (half-size 0.34hw x 11; orange or gray). At max: narrow panel (x1.3), "BOAT" / "MAX LVL" only.
     Controller: pad-X glyph on UPGRADE, "O CLOSE" under the panel. flash field = glow behind level (phase 5 drives).
   - Host SyncBoatMenu (pre-frame, after SyncActionMenu) fills the view; app calls setBoatMenuOpen:controllerHints:.
   - goalc quirk: make fishermans-boat.o first in the same session, else pad.gc fails (*pc-settings*).
5. Touch layer, controller, upgrading. DONE 2026-10-23 (builds, untested on device).
   - BoatMenu.swift: BoatMenuView (hosted in RuntimeShellView like ActionMenuView; overlay controls hidden while open):
     tap UPGRADE rect -> .upgrade, tap outside the panel -> .close, BACK (touch only). BoatMenuLayout mirrors the GOAL
     geometry (aspect from view size) + 5-unit finger margin; keep in step with ios-boat-menu-draw.
   - Controller: Cross = .upgrade, Circle/Start/R2 close. .upgrade -> runtime.requestBoatUpgrade() (not at max).
   - Host SyncBoatUpgrade decides: enough cells -> level+1, event 1, flash start; short -> event 2. SyncBoatMenu writes
     event for one frame (+28, view now #x20) and flash = 1 - t/0.9 s. GOAL plays "cell-prize" (1) / "yellow-fizzle" (2)
     and clears event; draws the glow behind the level from flash.
   - TouchInputState.isBoatAtMaxLevel (no button hit area at max).
6. Device test + tuning.

## Incremental rebuild (zsh)
goalc in build-release/game: `(make "$OUT/obj/fishermans-boat.o")`, then aot_level_code_link.py with the
RELINK_CAPTURED / STARTUP_OBJECTS lists from tools/release/build.sh (as arrays), copy LevelCode/ to
jakIOS/Generated/LevelCode, touch jakIOS/Runtime/Jak1AOTSignedImage.s, `tools/opengoal/opengoal.sh save`.
