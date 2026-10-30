#pragma once

// Fishing (experimental): every catchable fish species. The array index is the species id, used by
// the per-save fishing log (Jak1MemoryCardManager.h, kFishLogCapacity) and by GOAL
// (pc/ios/ios-ocean-fish.gc). Ids are stored in save files: only append, never reorder or remove.
//
// Naming rule (user 2026-10-18): short, a real fish type + a word for how the fish looks (its tint).
// No other animal names, no character names, no location/level names and no collectible item names.
// Names are display only (the log stores ids), so renaming keeps saves intact.
//
// There is no new fish art, so a species is one of the stock fish models plus a tint and a scale. The
// tint is the stock per-object colour path: GOAL draw-control color-mult multiplies the model's lighting
// (so the texture keeps its pattern, recoloured) and color-emissive (= tint * glow) adds a self-lit
// glow, used for the rarest fish. The host copies this table into GOAL's *ios-fish-roster*.

#include <cstdint>

namespace jak1::fishing {

// Stock fish models kept resident while Fishing is on (OpenGOALRuntimeHost.mm kOceanFishArt).
enum class FishModel : uint8_t {
    CatchFishA,         // catch-fisha (fishing minigame fish)
    CatchFishB,         // catch-fishb
    Eel,                // catch-fishc (the fishing minigame's poisonous eel)
    JungleFish,         // junglefish
    SunkenRedYellow,    // sunkenfisha, stock texture set 1
    SunkenYellowBlue,   // sunkenfisha, stock texture set 2
    SunkenYellowEye,    // sunkenfisha, stock texture set 3
};

// Menu order: the fish menu lists Common first and Legendary last.
enum class FishRarity : uint8_t { Common, Uncommon, Rare, Epic, Legendary };

// Where a species lives (user 2026-10-18). Same numbers as IOS_FISH_REGION_* in ios-ocean-fish.gc, which works it
// out from the level Jak is in. Any = everywhere there is fish water.
enum class FishRegion : uint8_t { Any, SandoverVillage, SentinelBeach, MistyIsland, RockVillage, BoggySwamp };

// Relative chance of a spawned fish being a species of this rarity (summed over all species).
constexpr uint16_t kFishRaritySpawnWeight[] = {200, 80, 30, 10, 3};

struct FishSpecies {
    const char *name;    // English; PC text ids are added with the fish menu (phase 6)
    FishModel model;
    FishRarity rarity;
    float scale;         // relative to the model's ocean-fish scale
    float tint[3];       // color-mult rgb; 1 1 1 = stock colours
    float glow;          // color-emissive = tint * glow
    FishRegion region = FishRegion::Any;  // only spawns there
};

constexpr FishSpecies kFishSpecies[] = {
    // Common
    {"Plain Sardine",             FishModel::CatchFishA,       FishRarity::Common,    1.0f, {1.00f, 1.00f, 1.00f}, 0.00f},
    {"Moss Minnow",               FishModel::CatchFishA,       FishRarity::Common,    0.8f, {0.75f, 1.15f, 0.70f}, 0.00f},
    {"Common Carp",               FishModel::CatchFishB,       FishRarity::Common,    1.0f, {1.00f, 1.00f, 1.00f}, 0.00f},
    {"Pale Bluegill",             FishModel::CatchFishB,       FishRarity::Common,    0.9f, {0.60f, 0.90f, 1.30f}, 0.00f},
    {"Little Goby",               FishModel::JungleFish,       FishRarity::Common,    1.0f, {1.00f, 1.00f, 1.00f}, 0.00f},
    {"Dusk Gar",                  FishModel::JungleFish,       FishRarity::Common,    0.9f, {0.60f, 0.55f, 0.75f}, 0.00f},
    {"Pearl Herring",             FishModel::CatchFishB,       FishRarity::Common,    0.9f, {1.25f, 1.25f, 1.30f}, 0.00f},
    {"Sunset Wrasse",             FishModel::SunkenRedYellow,  FishRarity::Common,    1.0f, {1.00f, 1.00f, 1.00f}, 0.00f},
    {"Mud Eel",                   FishModel::Eel,              FishRarity::Common,    1.0f, {0.75f, 0.60f, 0.45f}, 0.00f},
    {"Snow Snapper",              FishModel::JungleFish,       FishRarity::Common,    1.0f, {1.30f, 1.30f, 1.35f}, 0.00f},
    // Uncommon
    {"Rose Darter",               FishModel::CatchFishA,       FishRarity::Uncommon,  1.0f, {1.30f, 0.80f, 1.20f}, 0.00f},
    {"Sand Perch",                FishModel::CatchFishB,       FishRarity::Uncommon,  1.0f, {1.20f, 1.10f, 0.85f}, 0.00f},
    {"Volt Pike",                 FishModel::JungleFish,       FishRarity::Uncommon,  1.2f, {1.20f, 1.20f, 0.60f}, 0.00f},
    {"Amber Pufferfish",          FishModel::CatchFishB,       FishRarity::Uncommon,  1.1f, {1.30f, 0.90f, 0.50f}, 0.00f},
    {"Lemon Triggerfish",         FishModel::SunkenYellowBlue, FishRarity::Uncommon,  1.0f, {1.00f, 1.00f, 1.00f}, 0.00f},
    {"Ash Cod",                   FishModel::CatchFishB,       FishRarity::Uncommon,  1.1f, {0.70f, 0.65f, 0.60f}, 0.00f},
    {"Slate Eel",                 FishModel::Eel,              FishRarity::Uncommon,  1.0f, {0.50f, 0.50f, 0.55f}, 0.00f},
    {"Gravel Stonefish",          FishModel::JungleFish,       FishRarity::Uncommon,  1.0f, {0.80f, 0.80f, 0.75f}, 0.00f},
    // Rare
    {"Iron Hammerhead",           FishModel::CatchFishB,       FishRarity::Rare,      1.5f, {0.60f, 0.60f, 0.70f}, 0.00f},
    {"Scarlet Rockfish",          FishModel::JungleFish,       FishRarity::Rare,      1.1f, {1.40f, 0.55f, 0.45f}, 0.00f},
    {"Emerald Eel",               FishModel::Eel,              FishRarity::Rare,      1.1f, {0.70f, 1.30f, 0.50f}, 0.00f},
    {"Cobalt Tuna",               FishModel::CatchFishA,       FishRarity::Rare,      1.4f, {0.55f, 0.80f, 1.40f}, 0.00f},
    {"Golden Koi",                FishModel::SunkenRedYellow,  FishRarity::Rare,      1.1f, {1.35f, 1.00f, 0.55f}, 0.00f},
    {"Glacier Icefish",           FishModel::SunkenYellowBlue, FishRarity::Rare,      1.0f, {0.80f, 1.10f, 1.40f}, 0.00f},
    {"Goldeye Tang",              FishModel::SunkenYellowEye,  FishRarity::Rare,      1.1f, {1.00f, 1.00f, 1.00f}, 0.00f},
    // Epic
    {"Copper Anglerfish",         FishModel::JungleFish,       FishRarity::Epic,      1.3f, {0.85f, 0.60f, 0.40f}, 0.12f},
    {"Midnight Lanternfish",      FishModel::SunkenYellowEye,  FishRarity::Epic,      1.2f, {0.55f, 0.50f, 0.80f}, 0.12f},
    {"Orchid Grouper",            FishModel::JungleFish,       FishRarity::Epic,      1.4f, {1.20f, 0.70f, 1.10f}, 0.12f},
    {"Storm Tarpon",              FishModel::CatchFishB,       FishRarity::Epic,      1.8f, {0.45f, 0.55f, 0.60f}, 0.12f},
    {"Gilded Moray",              FishModel::Eel,              FishRarity::Epic,      1.3f, {1.30f, 1.05f, 0.50f}, 0.12f},
    // Legendary
    {"Violet Sturgeon",           FishModel::CatchFishB,       FishRarity::Legendary, 1.8f, {0.90f, 0.50f, 1.30f}, 0.25f},
    {"Sapphire Swordfish",        FishModel::SunkenRedYellow,  FishRarity::Legendary, 1.7f, {0.55f, 0.85f, 1.40f}, 0.25f},
    {"Sunfire Marlin",            FishModel::CatchFishA,       FishRarity::Legendary, 2.0f, {1.40f, 1.15f, 0.45f}, 0.25f},
    {"Radiant Barracuda",         FishModel::JungleFish,       FishRarity::Legendary, 1.6f, {0.50f, 1.20f, 1.40f}, 0.25f},
    {"Shadow Eel",                FishModel::Eel,              FishRarity::Legendary, 1.5f, {0.60f, 0.35f, 0.90f}, 0.25f},
    // Regional (user 2026-10-18): only around one place
    {"Peach Mullet",              FishModel::CatchFishA,       FishRarity::Common,    0.9f, {1.35f, 0.95f, 0.75f}, 0.00f, FishRegion::SandoverVillage},
    {"Jade Bream",                FishModel::SunkenYellowBlue, FishRarity::Uncommon,  1.0f, {0.60f, 1.25f, 1.00f}, 0.00f, FishRegion::SandoverVillage},
    {"Sunbeam Tetra",             FishModel::SunkenRedYellow,  FishRarity::Rare,      1.0f, {1.40f, 1.25f, 0.50f}, 0.08f, FishRegion::SandoverVillage},
    {"Sandy Flounder",            FishModel::CatchFishB,       FishRarity::Common,    1.0f, {1.20f, 1.05f, 0.80f}, 0.00f, FishRegion::SentinelBeach},
    {"Seafoam Mackerel",          FishModel::CatchFishA,       FishRarity::Uncommon,  1.1f, {0.75f, 1.25f, 1.15f}, 0.00f, FishRegion::SentinelBeach},
    {"Shell Pompano",             FishModel::JungleFish,       FishRarity::Rare,      1.2f, {1.35f, 1.15f, 1.05f}, 0.06f, FishRegion::SentinelBeach},
    {"Fog Smelt",                 FishModel::CatchFishA,       FishRarity::Common,    0.8f, {0.85f, 0.90f, 0.95f}, 0.00f, FishRegion::MistyIsland},
    {"Mossback Bass",             FishModel::JungleFish,       FishRarity::Uncommon,  1.1f, {0.60f, 0.85f, 0.55f}, 0.00f, FishRegion::MistyIsland},
    {"Ghost Char",                FishModel::SunkenYellowEye,  FishRarity::Rare,      1.1f, {1.30f, 1.35f, 1.40f}, 0.15f, FishRegion::MistyIsland},
    {"Pebble Sculpin",            FishModel::CatchFishB,       FishRarity::Common,    0.9f, {0.75f, 0.72f, 0.70f}, 0.00f, FishRegion::RockVillage},
    {"Ember Tilefish",            FishModel::JungleFish,       FishRarity::Uncommon,  1.1f, {1.40f, 0.60f, 0.35f}, 0.05f, FishRegion::RockVillage},
    {"Magma Eel",                 FishModel::Eel,              FishRarity::Rare,      1.2f, {1.40f, 0.50f, 0.30f}, 0.12f, FishRegion::RockVillage},
    {"Murk Loach",                FishModel::Eel,              FishRarity::Common,    0.8f, {0.55f, 0.60f, 0.40f}, 0.00f, FishRegion::BoggySwamp},
    {"Peat Bowfin",               FishModel::JungleFish,       FishRarity::Uncommon,  1.0f, {0.65f, 0.50f, 0.35f}, 0.00f, FishRegion::BoggySwamp},
    {"Venom Arowana",             FishModel::SunkenRedYellow,  FishRarity::Rare,      1.1f, {0.70f, 1.35f, 0.35f}, 0.12f, FishRegion::BoggySwamp},
};

constexpr int kFishSpeciesCount = static_cast<int>(sizeof(kFishSpecies) / sizeof(kFishSpecies[0]));

}  // namespace jak1::fishing
