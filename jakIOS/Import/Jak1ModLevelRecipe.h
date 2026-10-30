#pragma once

// The recipe that goes with a mod level's stripped glb (tools/modlevel/modlevel_pack.cpp writes it, the import's
// Jak1ModLevelBuilder.cpp applies it). The pack tool takes the game's data out of the mod's glb and records where it
// came from on the disc, so the shipped files hold only the mod author's own work:
//   * images: glb image index -> disc texture id (+ optional per-channel constants the author painted over it).
//   * geometry: meshes (or parts of meshes) cut from the game's levels. Per glb vertex: which piece it belongs to and
//     which source vertex (level fr3, tfrag / TIE tree or merc, vertex index); a piece is a rigid transform from the
//     source level's space to the mesh's local space. Positions, uvs, colors and (merc) normals of those vertices
//     are zero in the shipped glb and refilled from the player's extracted levels (fr3/Jak1Level-<level>.fr3z).
// JSON:
// {"format": 1,
//  "images": [{"index": 3, "id": 85786647, "name": "cmn-precursor-metal-plain-01", "set": [-1, -1, -1, 102]}],
//  ("from": [0, 1, 3, 3] reads kept channels from other disc channels: Blender's metallic-roughness images carry the
//   texture's alpha in blue)
//  "pieces": [{"level": "beach", "kind": "merc|tie|tfrag", "tree": 0, "tod": 0, "r": [9 floats], "t": [3]}],
//  "primitives": [{"mesh": 12, "primitive": 0, "piece": [...], "source": [...], "flags": [...]}]}
// piece -1 = vertex untouched. flags: kPosition | kUv | kColor | kNormal (source normal) | kNormalRecompute
// (smooth normal from the rebuilt triangles; only its side matters to the builder, which flips collision faces whose
// three normals all face against the winding) | kNormalFlip.

#include <array>
#include <string>
#include <vector>

#include "common/common_types.h"

namespace tinygltf {
class Model;
}
namespace tfrag3 {
struct Level;
}

namespace jak1 {

constexpr u32 kRecipePosition = 1;
constexpr u32 kRecipeUv = 2;
constexpr u32 kRecipeColor = 4;
constexpr u32 kRecipeNormal = 8;
constexpr u32 kRecipeNormalRecompute = 16;
constexpr u32 kRecipeNormalFlip = 32;  // with kRecipeNormalRecompute: the mod's normal faced the other way

struct RecipeImage {
    int index = 0;
    u32 id = 0;
    std::string name;
    std::array<int, 4> set {-1, -1, -1, -1};  // channel constant, -1 = keep the disc value
    std::array<int, 4> from {0, 1, 2, 3};     // disc channel each kept channel is read from (r, g, b, a)
};

struct RecipePiece {
    std::string level;
    std::string kind;  // "tfrag", "tie" or "merc"
    int tree = 0;      // index over the level's tfrag (or TIE) trees of all geometry kinds, in file order
    int tod = 0;       // time-of-day slot of tfrag / TIE vertex colors
    std::array<double, 9> r {1, 0, 0, 0, 1, 0, 0, 0, 1};  // row major, local = r * source + t (meters)
    std::array<double, 3> t {0, 0, 0};
};

struct RecipePrimitive {
    int mesh = 0;
    int primitive = 0;
    std::vector<int> piece;
    std::vector<u32> source;
    std::vector<u32> flags;
};

struct ModLevelRecipe {
    std::vector<RecipeImage> images;
    std::vector<RecipePiece> pieces;
    std::vector<RecipePrimitive> primitives;
};

ModLevelRecipe ParseModLevelRecipe(const std::string &json);
std::string SerializeModLevelRecipe(const ModLevelRecipe &recipe);

// Reads Jak1Level-<name>.fr3z (FR3Z header + LZFSE) into level. Throws on failure.
void LoadFr3z(const std::string &path, tfrag3::Level &level);

// One vertex of the game's geometry as the OpenGOAL glTF exporter writes it (meters, st, 0-1 color).
struct SourceVertex {
    float pos[3];
    float st[2];
    float color[3];
    float normal[3];  // merc only (normalized), else zero
};

// Source vertices of one piece kind/tree of an unpacked level, in the indexing the recipe uses.
// tfrag / TIE trees must have been unpack()ed.
std::vector<SourceVertex> SourceVertices(const tfrag3::Level &level, const std::string &kind, int tree, int tod);

// Writes the recipe's geometry into the model's vertex buffers. fr3Directory holds Jak1Level-<level>.fr3z.
void ApplyModLevelGeometry(tinygltf::Model &model, const ModLevelRecipe &recipe, const std::string &fr3Directory);

}  // namespace jak1
