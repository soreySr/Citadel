#pragma once

// Port of the Jak 1 overlord's bank-sound half (game/overlord/jak1/srpc.cpp, ssound.cpp and
// game/overlord/common/ssound.cpp, sbank.cpp) on top of OpenGOAL's 989snd synth. VAG streams
// stay with the host, which handles the "spool-" PLAY form and the stream fallbacks.

#include <cstdint>
#include <functional>
#include <vector>

namespace jak1sound {

// Returns the whole content file with this name (case-insensitive), or an empty vector.
using FileReader = std::function<std::vector<uint8_t>(const char* fileName)>;

constexpr uint32_t kCommandSize = 0x50;

void Init(FileReader reader);

// Fills `frames` interleaved stereo 48 kHz samples. Runs on the audio render thread.
void Render(int16_t* stereo, int frames);

// The work RPC_Player does before its commands: start/restart the music sound and push the
// music volume and flava register to it.
void BeginPlayerRpc();

// Executes one player command (overlord RPC_Player). Returns true when the command's id named
// a live bank sound; PAUSE/STOP/CONTINUE/SET_PARAM only fall back to the VAG stream otherwise.
bool HandlePlayerCommand(const uint8_t* command);

// Executes one loader command (overlord RPC_Loader).
void HandleLoaderCommand(const uint8_t* command);

// Overlord VBlank_Handler's music fade, once per game frame.
void VBlank();

// pc-sound-set-flava-hack / pc-sound-set-fade-hack.
void SetFlavaHack(uint64_t value);
void SetFadeHack(uint32_t value);

// Overlord CalculateVAGVolumes: the stream voice's SPU VOLL/VOLR (0x3fff = full) for a stream
// volume and dialog volume (0x400 = 1.0). Positioned streams take falloff and pan from `trans`
// against the current ear and camera.
void CalculateVAGVolumes(int32_t volume, int32_t dialogVolume, bool positioned,
                         const int32_t trans[3], int32_t* left, int32_t* right);

}  // namespace jak1sound
