#pragma once

#include <string>

namespace jak1 {

// Builds the iOS-only model files the experimental options draw, from the level files the import just
// extracted from the disc (Jak1LevelBuilder.mm), so the app bundle ships none of their game art:
//   Jak1Level-ios-boat.fr3z   fisherman's boat + lurker shark Merc models (village1)      Driveable Boat
//   Jak1Level-ios-fish.fr3z   ocean fish Merc models (jungle, sunken)                     Fish in Ocean
//   Jak1Level-ios-flut.fr3z   flut flut saddle (swamp) + Sandover's zoomer pad (village1) Expanded Flut Flut
//   Jak1Level-ios-coast.fr3z  east coastline: bare cliff chunks (jungle, village2), see below  Driveable Boat
//   Jak1Level-ios-backdrop-village1/-training.fr3z  their lowres far stand-in of the east coast, split out of
//                             Jak1Level-village1/-training.fr3z (drawn only while the coast is off)  Driveable Boat
//   Jak1Level-ios-vents.fr3z  the citadel's eco vent ring (citadel), vent-local           Expanded Green Eco
//   Jak1Level-ios-ocean.fr3z  Misty's keg, beach seagull + lurkerworm, LPC square-platform Open Ocean Level
// Replaces tools/boat, tools/fish and tools/flut.
// fr3Directory holds the extracted Jak1Level-<name>.fr3z files and receives the new ones.
bool BuildCustomLevels(const std::string &fr3Directory, std::string *error);

// Jak1Level-ios-coast.fr3z: the east coastline between the Forbidden Jungle and Rock Village
// (coastline-plan.md). Bare cliff chunks cut from the jungle's east face and Rock Village's north face (rock-kit
// TIE + rock tfrag), stripped of faces never seen from the sea, then laid along the coast in rows (rotated,
// scaled, mirrored) and baked into world-space tfrag trees. Called by BuildCustomLevels; separate so the Mac
// survey harness (tools/coast) can run it.
bool BuildCoastLevel(const std::string &fr3Directory, std::string *error);

}  // namespace jak1
