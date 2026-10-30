#pragma once

#include <functional>
#include <string>
#include <vector>

namespace jak1 {

// A custom actor model (custom_assets/jak1/models/custom_levels/<name>.glb), stripped and refilled like a level's glb.
struct ModLevelModel {
    std::string name;    // the model's name (the jsonc's "custom_models" entry, the art group's name without -ag)
    std::string glb;     // its glb with the game's data taken out
    std::string recipe;  // optional: its recipe (Jak1ModLevelRecipe.h)
    bool genMesh = true;     // game.gp build-actor :gen-mesh (a collide mesh in the art group)
    int textureBucket = 0;   // build-actor :texture-bucket (-1: #f, no texture-bucket lump)
};

// Paths for building one OpenGOAL custom ("mod") level at import, from the files the app ships (the level's
// .jsonc, a .glb with the game's data taken out, and its recipe) and the player's disc.
struct ModLevelPaths {
    std::string project;   // read-only: decompiler/config/jak1/... and goal_src/jak1/build/all_objs.json
    std::string disc;      // the imported disc (CGO/, DGO/)
    std::string jsonc;     // the level description (custom_assets/jak1/levels/<name>/<name>.jsonc)
    std::string glb;       // its mesh; replaces the jsonc's "gltf_file"
    std::string recipe;    // optional: what the pack tool took out of the glb (Jak1ModLevelRecipe.h)
    std::string levels;    // the extracted levels (Jak1Level-<name>.fr3z) the recipe's geometry comes from
    std::string bsp;       // receives <name>.go, the level's bsp object for its DGO
    std::string fr3;       // receives <name>.fr3 (zstd), the PC renderer's level file
    std::vector<ModLevelModel> models;  // the jsonc's "custom_models" (their merc data goes into the fr3)
};

// Called before each step: (index, total, label). index == total means finished.
using ModLevelProgress = std::function<void(int, int, const std::string &)>;

// goalc's build_level (goalc/build_level/jak1/build_level.cpp) with the disc read one DGO at a time, the
// way the level extractor does, instead of all at once (~1.9 GB). Output matches goalc's for the same glb
// except build_level's timestamp. Returns false and sets *error on failure.
bool BuildModLevel(const ModLevelPaths &paths, const ModLevelProgress &progress, std::string *error);

// Writes the level's DGO from its .gd list (custom_assets/jak1/levels/<name>/<name>.gd): code objects (.o) become
// stubs, since their signed copies are prelinked into the app (Jak1Kernel links level code by object name); art and
// texture pages (.go) are copied from the first disc archive (in the config's order) that has them; <name>.go is the
// bsp BuildModLevel wrote; the file goes to outputDirectory under the .gd's DGO name. Layout as OpenGOAL's DgoWriter: u32 count + 60-byte name, then per object u32 size +
// 60-byte name + data padded to 16 bytes. Object names drop ".o" / ".go" / "-ag" like the game's own DGOs.
// customArt: built art groups (header name without -ag -> file, BuildModLevelActor's output) used for objects of
// the .gd that are not on the disc.
bool AssembleModLevelDgo(const std::string &project, const std::string &disc, const std::string &gd,
                         const std::string &bsp, const std::string &outputDirectory, std::string *error,
                         const std::vector<std::pair<std::string, std::string>> &customArt = {});

// goalc's build-actor (goalc/build_actor/jak1/build_actor.cpp, run_build_actor, :gen-mesh #t) for a custom actor
// model: writes its art group object (<name>-ag.go) to output. Geometry the recipe names is refilled from the
// extracted levels in `levels`; images are not needed for the art group (only the fr3 draws them).
bool BuildModLevelActor(const std::string &project, const ModLevelModel &model, const std::string &levels,
                        const std::string &output, std::string *error);

}  // namespace jak1
