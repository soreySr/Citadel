# East coastline (driveable boat / Open Ocean)

No level has geometry for the ~1 km of east coast between the Forbidden Jungle and Rock Village
(x 288..480 m, z -360..-1420 m). The app builds one at import: `jak1::BuildCoastLevel`
(`jakIOS/Import/Jak1CustomLevelBuilder.cpp`, plan and status in `coastline-plan.md`).

- Rock chunks: boxes of the jungle's east face and Rock Village's north face, cut from the player's own extracted
  levels. Both levels build their cliffs from the same TIE rock kit (`IsRockKitProto`) over rockwall / beach
  tfrag; only those are kept (bare rock, no trees or huts), with each level's own textures and time-of-day colours.
- Faces never seen from the sea in front of a chunk are dropped (`CullHiddenTris`, a small depth/id rasterizer).
- `LayOutCoast` sets copies along two rows (east face to the open sea, west face to Fire Canyon's channel),
  rotated, scaled and mirrored, jungle rock in the north, Rock Village rock in the south (mixed z -820..-940).
- Output `Jak1Level-ios-coast.fr3z`: world-space tfrag trees, one BVH sphere per chunk copy (frustum culled), drawn by `Jak1Background.mm` with the first
  opaque tfrag pass of the frame while `SetCoastTerrainEnabled` is on (GOAL `*ios-coast-visible*`). Nothing from
  the game data ships in the app. Bump `kCustomLevelsVersionMarker` (Jak1LevelBuilder.mm) after changing it.

Tools:

- `coast_survey.cpp`: offline renderer + box statistics for bundled `.fr3z` levels (build line in its header).
  Renders a built `Jak1Level-ios-coast.fr3z` together with the real levels to check the layout from the sea.
  Mac harness for the builder: a `main` calling `jak1::BuildCoastLevel(dir)` on a directory holding
  `Jak1Level-jungle.fr3z` and `Jak1Level-village2.fr3z`, linked with `build-ios-extractor/macos/libjak1_extractor.a`.
- `fr3_collision_dump.cpp`: dumps a level's collision triangles near a point (finding real shores / walls).
- Offline checks used while tuning (kept in /tmp during the 2026-10 work, easy to recreate): `coast_survey holes`
  (see-through from the boat route), an overlap check (real levels' walkable floor under coast rock) and a culling
  estimate (share of triangles in view per camera).
- `oceanmask.py`: decodes the ocean maps' land / water tiles from `ocean-tables.gc` (the black horizon strips).

Collision: `WriteCoastHeights` (same builder) writes `Jak1Level-ios-coast.heights` next to the model, a 2 m height
grid of the placed rock with the inside between the rows filled solid. The host copies it into the GOAL heap for
`*ios-coast-grid*`; `ios-coast-height` (fishermans-boat.gc) reads it for the boat's shore probe and to slide Jak
off the rock into the water.
