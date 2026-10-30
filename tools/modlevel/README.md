# Mod levels (OpenGOAL custom levels built at import)

The app can ship OpenGOAL community levels without shipping any of the game's data. A mod level's files live in
`jakIOS/ModLevels/<Name>/`:

| File | What |
|---|---|
| `<name>.jsonc` | the mod's level description (actors, art groups, sky...), as in its `custom_assets/jak1/levels/<name>/` |
| `<name>.gd` | the mod's DGO list; the import assembles the DGO from it (code objects are stubs, art comes from the disc) |
| `<name>.glb.zst` | the mod's mesh with the game's data taken out (`modlevel_pack`), zstd -19 |
| `<name>.recipe.json` | what was taken out and where it is on the disc (`jakIOS/Import/Jak1ModLevelRecipe.h`) |

`jakIOS/ModLevels/` is not in the repository. `tools/modlevel/mods.sh` (run by `tools/release/build.sh`) downloads
each mod from its author's GitHub repository at the commit pinned at the top of the script and writes these files:
it builds the tools below (`build.sh`), builds the disc's levels the way the import does (`extract_levels`), packs
every glb, stages the level descriptions (`mod_stage.py` for Glacier / Brume, `forgotten_stage.py`) and converts the
music and hint voices to AAC (`afconvert`). Run it by hand with `tools/modlevel/mods.sh --work build-release/mods`.

At import, `jakIOS/Import/Jak1ModLevelBuilder.cpp` (goalc's build_level, in the import library) refills the glb from
the player's disc and extracted levels and builds `<name>.go` + `Jak1Level-<name>.fr3z`.

## Packing a mod's glb (what mods.sh does per glb)

```
sh tools/ios_extractor/build.sh macos   # once
sh tools/modlevel/build.sh
# only if the glb uses KHR_draco_mesh_compression (Blender's "Compression" export option):
build-ios-extractor/macos/glb_undraco <mod>/.../<name>.glb /tmp/<name>-plain.glb   # then pack that one
build-ios-extractor/macos/modlevel_pack --glb <mod>/custom_assets/jak1/levels/<name>/<name>.glb \
  --project OpenGOAL --disc OpenGOAL/iso_data/jak1 --levels build-release/mods/levels \
  --out-glb /tmp/<name>.glb --out-recipe jakIOS/ModLevels/<Name>/<name>.recipe.json
zstd -19 -T0 /tmp/<name>.glb -o jakIOS/ModLevels/<Name>/<name>.glb.zst
```

`--levels` must hold the 25 extracted levels as the import builds them (`Jak1Level-*.fr3z`):
`build-ios-extractor/macos/extract_levels <Jak1ExtractorConfig.pack> OpenGOAL/iso_data/jak1 <dir>` writes them. The tool:
- replaces images that are disc textures (same pixels, renamed copies, or with whole channels painted a constant)
  with 1x1 placeholders, and refuses images that look like edits of game art;
- finds meshes cut from the game (edge-pair signatures vs. a jittered control, then piecewise rigid fits against
  every level's tfrag / TIE / merc geometry), zeroes their positions / uvs / (merc) normals / matching colors and
  records the source vertices; meshes that are never drawn nor collided with are zeroed outright;
- also matches Blender's metallic-roughness copies of a disc texture (its alpha in blue: recipe "from")
  and "name.png" / "name.001" copies;
- custom actor models (custom_assets/jak1/models/custom_levels/<model>.glb) are packed the same way and ship as
  <model>.glb.zst + <model>.recipe.json next to the levels; the import builds their art groups (goalc build-actor)
  and adds their merc data to the levels that list them in "custom_models";
- reloads its output, applies the recipe with the import's code and compares with the original (fails above
  1 mm / 1e-5 uv).

Check the result with `/tmp`-style survey tools if anything is unclear; the release audit's byte matching does not
see glb content (floats and PNGs never byte-match the disc's packed formats), so this tool is the check.

## Glacier

`jakIOS/ModLevels/Glacier`: "Glacier" by Cuttlefishthesage, https://github.com/Cuttlefishthesage/OG-Mod-Base-Glacier
(commit b530d0ec, an OpenGOAL mod base fork; ISC licence, Copyright (c) 2020-2025 OpenGOAL Team). Packed 2026-10-27:
71 images from the disc (2 with a channel override), 4 unused placeholders, 1 kept (the mod's own snow-leaf
texture); 19685 vertices of 20 ripped meshes rebuilt from beach / jungle / jungleb / rolling / snow / training /
citadel (worst 0.3 mm), 84 author-edited vertices kept, jak4reference (invisible Jak) zeroed. Build from the packed
files equals goalc's build of the original glb (textures identical, tfrag <= 1.2 mm, collision same triangles and
orientation).

## Brume Village

`jakIOS/ModLevels/Brume`: "Brume Village" by Cuttlefishthesage, https://github.com/Cuttlefishthesage/BrumeVillage
(commit 51b106d9, an OpenGOAL mod base fork; ISC licence, Copyright (c) 2020-2025 OpenGOAL Team): four levels (brume,
abandon, mount, preundg) and three custom models (test-actor2, gravityswitch, ambushdoor). The glbs are Draco
compressed, so they were decoded with glb_undraco first. Packed 2026-10-27: every disc texture filled from the disc
(Blender metallic-roughness copies through "from"); kept as the mod's own: its photo/painted textures, cit-wires-grayscale
(preundg; a heavily edited grey version of cit-wires, no per-pixel formula) and vil-beachrock-test (512x256, no
disc match); ripped geometry rebuilt from beach / misty / jungle and others (worst 1 mm); jak4reference zeroed.
Build from the packed files equals the build of the decoded originals (textures identical, under 0.2% of
collision triangles moved by sub-mm rounding). brume.jsonc's numeric alt-task 121 is 128 here (tasks moved up by 7).
