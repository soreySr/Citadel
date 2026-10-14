# Stand-in coastline (driveable boat)

No level has geometry for the ~700 m of east coast between the Forbidden Jungle and Rock Village
(x 288..480 m, z -1152..-480 m): the village1 ocean map marks those tiles as land, so with nothing
loaded there you saw a black void from the sea. These tools generate simple terrain for it.

Pipeline (paths are the ones used on 2026-10-08):

1. `fr3_collision_dump.cpp` - dumps each level's collision mesh from `OpenGOAL/out/jak1/fr3/<level>.fr3`
   (used to find which ocean-map land tiles have no level geometry). Build against
   `OpenGOAL/build-make/common/libcommon.dylib` (see the header of `coast_terrain_fr3.cpp`), run on
   copies of the .fr3 files in `/tmp/colldump/`.
2. `oceanmask.py` - decodes the ocean-mid masks from `ocean-tables.gc` (48x48 tiles of 96 m).
3. `fill.py` - picks the empty coastal land tiles to fill -> `/tmp/coast/tiles.npz`.
4. `terrain.py` - builds the height field (sand shelf, cliffs to a 35-45 m ridge, rock skirts on open
   edges), per-triangle material/shading -> `/tmp/coast/tris.bin`, and the GOAL collision grid
   `/tmp/coast/coast-heights.gc` (pasted into `fishermans-boat.gc` as `*ios-coast-heights*`).
   `preview.py` renders a top-down check image.
5. `coast_terrain_fr3.cpp` - packs `tris.bin` into one tfrag tree with the jungle's grass / rock / sand
   textures, draw modes and time-of-day palettes -> `jakIOS/Runtime/Jak1Level-ios-coast.fr3z`.

Runtime: `Jak1Background.mm` draws the ios-coast tree inside village1's opaque tfrag bucket while
`SetCoastTerrainEnabled` is on; the host sets that from GOAL `*ios-coast-visible*` (driveable boat
option on, Fire Canyon not loaded). The boat's shore probe and the ocean manager use
`ios-coast-height` so the boat and swimming Jak can't pass through it.

If the terrain changes, regenerate both the .fr3z and the GOAL grid, then relink level code.

## Shipping (no game data in the app)

The app does not bundle `Jak1Level-ios-coast.fr3z` (it contains the jungle's textures and colors). It ships
`jakIOS/Import/Jak1CoastTerrain.fr3z`, the same level with texture pixels and time-of-day colors removed, and
rebuilds the full file at import from the player's extracted jungle level (`jakIOS/Import/Jak1CustomLevelBuilder.cpp`,
same texture and color rules as `coast_terrain_fr3.cpp`). After regenerating the terrain:

6. `coast_template.cpp` - `Jak1Level-ios-coast.fr3z` -> `jakIOS/Import/Jak1CoastTerrain.fr3z` (build line in its header).
   Bump `kCustomLevelsVersionMarker` in `jakIOS/Import/Jak1LevelBuilder.mm` so installed copies rebuild.

The boat, fish and flut models (formerly tools/boat, tools/fish, tools/flut) are cut from the extracted levels by
the same builder.
