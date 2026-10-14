#pragma once

#include <string>

namespace jak1 {

// Builds the iOS-only model files the experimental options draw, from the level files the import just
// extracted from the disc (Jak1LevelBuilder.mm), so the app bundle ships none of their game art:
//   Jak1Level-ios-boat.fr3z   fisherman's boat + lurker shark Merc models (village1)      Driveable Boat
//   Jak1Level-ios-fish.fr3z   ocean fish Merc models (jungle, sunken)                     Fish in Ocean
//   Jak1Level-ios-flut.fr3z   flut flut saddle (swamp) + Sandover's zoomer pad (village1) Expanded Flut Flut
//   Jak1Level-ios-coast.fr3z  stand-in coastline: our terrain (coastTemplatePath, no game data) with the
//                             jungle's textures and time-of-day colors                    Driveable Boat
//   Jak1Level-ios-vents.fr3z  the citadel's eco vent ring (citadel), vent-local           Expanded Green Eco
// Replaces tools/boat, tools/fish and tools/flut; tools/coast makes the template.
// fr3Directory holds the extracted Jak1Level-<name>.fr3z files and receives the new ones.
bool BuildCustomLevels(const std::string &fr3Directory, const std::string &coastTemplatePath,
                       std::string *error);

}  // namespace jak1
