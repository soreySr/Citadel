#include "Jak1OverlordSound.h"

#include <array>
#include <cstring>
#include <memory>
#include <mutex>
#include <span>
#include <string>

#include "Sound989Log.h"
#include "player.h"

namespace jak1sound {
namespace {

// ---- Overlord data structures (game/overlord/common/ssound.h, sbank.h, srpc.h) ----

struct Vec3w {
    s32 x, y, z;
};

// GOAL sound-play-parms (gsound-h.gc), as the RPC sends it.
struct SoundParams {
    u16 mask;
    s16 pitch_mod;
    s16 bend;
    s16 fo_min;
    s16 fo_max;
    s8 fo_curve;
    s8 priority;
    s32 volume;
    Vec3w trans;
    u8 group;
    u8 reg[3];
};
static_assert(sizeof(SoundParams) == 32, "sound-play-parms is 32 bytes");

struct SoundRecord {
    std::array<char, 16> name;
    u32 fallof_params;
};

struct SoundBank {
    std::array<char, 16> name;
    snd::BankHandle bank_handle;
    u32 sound_count;
    std::vector<SoundRecord> sound;
};

struct Sound {
    s32 id;
    s32 sound_handle;
    s32 is_music;
    s32 new_volume;
    s32 auto_time;
    SoundParams params;
    SoundRecord* bank_entry;
    s64 add_index;
};

struct Curve {
    s32 unk1, unk2, unk3, unk4;
};

constexpr int kMusicTweakCount = 32;
struct MusicTweaks {
    u32 TweakCount;
    struct {
        char MusicName[12];
        s32 VolumeAdjust;
    } MusicTweak[kMusicTweakCount];
};

enum Command : u16 {
    LOAD_BANK = 0,
    LOAD_MUSIC = 1,
    UNLOAD_BANK = 2,
    PLAY = 3,
    PAUSE_SOUND = 4,
    STOP_SOUND = 5,
    CONTINUE_SOUND = 6,
    SET_PARAM = 7,
    SET_MASTER_VOLUME = 8,
    PAUSE_GROUP = 9,
    STOP_GROUP = 10,
    CONTINUE_GROUP = 11,
    SET_FALLOFF_CURVE = 13,
    SET_SOUND_FALLOFF = 14,
    RELOAD_INFO = 15,
    SET_FLAVA = 17,
    SET_EAR_TRANS = 19,
    UNLOAD_MUSIC = 22,
    MIRROR_MODE = 201,
};

constexpr int kNumSounds = 64;
// The PS2 overlord had 6 slots (common + level banks swapped per level). The mod-base level.gc that ships
// with the Eroded Coast pack replaces that swapping with update-sound-banks, which loads all 20 level banks
// once at boot and never unloads them. With 6 slots everything after "firecany" was silently dropped
// (village1 = the boat engine, jungle, misty, ...), so there is room for common + every level bank (~6 MB).
constexpr int kNumBanks = 24;
constexpr s32 kMusicSoundId = 666;

// ---- Overlord globals ----

std::unique_ptr<snd::Player> gPlayer;
// The overlord's RPC threads were serialised by the IOP scheduler; the host can call in from
// the GOAL kernel thread and from UIKit, so the overlord state takes one lock.
std::recursive_mutex gLock;
FileReader gReader;

Sound gSounds[kNumSounds];
SoundBank gBanks[kNumBanks];
Vec3w gEarTrans;
Vec3w gCamTrans;
s32 gCamAngle = 0;
u8 gMirrorMode = 0;
u32 sLastTick = 0;
s64 gAddIndex = 0;
Curve gCurves[16];
snd::VolPair gPanTable[361];

snd::BankHandle gMusic = nullptr;
s32 gMusicVol = 0x400;
s32 gMusicFade = 0;
s32 gMusicFadeDir = 0;
u32 gMusicFadeHack = 0;
s32 gMusicTweak = 0x80;
s32 gMusicPause = 0;
MusicTweaks gMusicTweakInfo {};
s16 gFlava = 0;

// LOAD_MUSIC/UNLOAD_MUSIC block the IOP loader thread (holding gSema) until VBlank has faded
// the old music out. The host has no loader thread, so the request waits here until VBlank
// finishes the fade.
enum class MusicRequest { None, Load, Unload };
MusicRequest gMusicRequest = MusicRequest::None;
char gMusicRequestName[16] {};

// ---- 989snd shims (game/sound/sndshim.cpp) ----

s32 snd_SoundIsStillPlaying(s32 handle) {
    return gPlayer->SoundStillActive(handle) ? handle : 0;
}

// ---- game/overlord/common/ssound.cpp ----

const s32 sqrt_table[256] = {
    0,     4096,  5793,  7094,  8192,  9159,  10033, 10837, 11585, 12288, 12953, 13585, 14189,
    14768, 15326, 15864, 16384, 16888, 17378, 17854, 18318, 18770, 19212, 19644, 20066, 20480,
    20886, 21283, 21674, 22058, 22435, 22806, 23170, 23530, 23884, 24232, 24576, 24915, 25249,
    25580, 25905, 26227, 26545, 26859, 27170, 27477, 27780, 28081, 28378, 28672, 28963, 29251,
    29537, 29819, 30099, 30377, 30652, 30924, 31194, 31462, 31727, 31991, 32252, 32511, 32768,
    33023, 33276, 33527, 33776, 34024, 34270, 34514, 34756, 34996, 35235, 35472, 35708, 35942,
    36175, 36406, 36636, 36864, 37091, 37316, 37540, 37763, 37985, 38205, 38424, 38642, 38858,
    39073, 39287, 39500, 39712, 39923, 40132, 40341, 40548, 40755, 40960, 41164, 41368, 41570,
    41771, 41972, 42171, 42369, 42567, 42763, 42959, 43154, 43348, 43541, 43733, 43925, 44115,
    44305, 44494, 44682, 44869, 45056, 45242, 45427, 45611, 45795, 45977, 46160, 46341, 46522,
    46702, 46881, 47059, 47237, 47415, 47591, 47767, 47942, 48117, 48291, 48465, 48637, 48809,
    48981, 49152, 49322, 49492, 49661, 49830, 49998, 50166, 50332, 50499, 50665, 50830, 50995,
    51159, 51323, 51486, 51649, 51811, 51972, 52134, 52294, 52454, 52614, 52773, 52932, 53090,
    53248, 53405, 53562, 53719, 53874, 54030, 54185, 54340, 54494, 54647, 54801, 54954, 55106,
    55258, 55410, 55561, 55712, 55862, 56012, 56162, 56311, 56459, 56608, 56756, 56903, 57051,
    57198, 57344, 57490, 57636, 57781, 57926, 58071, 58215, 58359, 58503, 58646, 58789, 58931,
    59073, 59215, 59357, 59498, 59639, 59779, 59919, 60059, 60199, 60338, 60477, 60615, 60753,
    60891, 61029, 61166, 61303, 61440, 61576, 61712, 61848, 61984, 62119, 62254, 62388, 62523,
    62657, 62790, 62924, 63057, 63190, 63323, 63455, 63587, 63719, 63850, 63982, 64113, 64243,
    64374, 64504, 64634, 64763, 64893, 65022, 65151, 65279, 65408,
};

const s32 atan_table[257] = {
    0,  0,  0,  0,  0,  1,  1,  1,  1,  2,  2,  2,  2,  2,  3,  3,  3,  3,  4,  4,  4,  4,  4,  5,
    5,  5,  5,  6,  6,  6,  6,  6,  7,  7,  7,  7,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  10, 10,
    10, 10, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 14, 15, 15, 15,
    15, 15, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 19, 19, 19, 19, 19, 20, 20,
    20, 20, 20, 21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 24, 24, 24, 24, 24,
    25, 25, 25, 25, 25, 26, 26, 26, 26, 26, 26, 27, 27, 27, 27, 27, 27, 28, 28, 28, 28, 28, 29, 29,
    29, 29, 29, 29, 30, 30, 30, 30, 30, 30, 31, 31, 31, 31, 31, 31, 32, 32, 32, 32, 32, 32, 32, 33,
    33, 33, 33, 33, 33, 34, 34, 34, 34, 34, 34, 34, 35, 35, 35, 35, 35, 35, 35, 36, 36, 36, 36, 36,
    36, 37, 37, 37, 37, 37, 37, 37, 37, 38, 38, 38, 38, 38, 38, 38, 39, 39, 39, 39, 39, 39, 39, 40,
    40, 40, 40, 40, 40, 40, 40, 41, 41, 41, 41, 41, 41, 41, 41, 42, 42, 42, 42, 42, 42, 42, 42, 43,
    43, 43, 43, 43, 43, 43, 43, 43, 44, 44, 44, 44, 44, 44, 44, 44, 45,
};

Sound* LookupSound(s32 id) {
    if (id == 0) return nullptr;
    for (auto& s : gSounds) {
        if (s.id == id) {
            s32 sndid = snd_SoundIsStillPlaying(s.sound_handle);
            s.sound_handle = sndid;
            if (sndid == 0) {
                s.id = 0;
                return nullptr;
            }
            return &s;
        }
    }
    return nullptr;
}

void CleanSounds() {
    for (auto& s : gSounds) {
        if (s.id != 0) {
            s32 sndid = snd_SoundIsStillPlaying(s.sound_handle);
            s.sound_handle = sndid;
            if (sndid == 0) s.id = 0;
        }
    }
}

s32 CalculateAngle(const Vec3w* trans) {
    s32 diffX = gCamTrans.x - trans->x;
    s32 diffZ = gCamTrans.z - trans->z;
    s32 angle;

    s32 lookupX = diffX;
    s32 lookupZ = diffZ;
    if (diffX < 0) lookupX = trans->x - gCamTrans.x;
    if (diffZ < 0) lookupZ = trans->z - gCamTrans.z;
    if (lookupX == 0 && lookupZ == 0) return 0;

    if (lookupZ >= lookupX) {
        angle = atan_table[(lookupX << 8) / lookupZ];
        if (diffZ >= 0) {
            if (diffX < 0) angle = 360 - angle;
        } else if (diffX >= 0) {
            angle = 180 - angle;
        } else {
            angle += 180;
        }
    } else {
        angle = atan_table[(lookupZ << 8) / lookupX];
        if (diffX >= 0) {
            angle = diffZ >= 0 ? 90 - angle : angle + 90;
        } else {
            angle = diffZ >= 0 ? angle + 270 : 270 - angle;
        }
    }

    angle = (angle - gCamAngle + 720) % 360;
    if (gMirrorMode) angle = ((180 - angle) + 180) % 360;
    return angle;
}

s32 GetPan(Sound* sound) {
    return CalculateAngle(&sound->params.trans);
}

// Jak 1 branch of CalculateFalloffVolume.
s32 CalculateFalloffVolume(const Vec3w* pos, s32 volume, s32 fo_curve, s32 fo_min, s32 fo_max) {
    if (fo_curve == 0) return volume;

    s32 xdiff = gEarTrans.x - pos->x;
    s32 ydiff = gEarTrans.y - pos->y;
    s32 zdiff = gEarTrans.z - pos->z;
    if (xdiff < 0) xdiff = -xdiff;
    if (ydiff < 0) ydiff = -ydiff;
    if (zdiff < 0) zdiff = -zdiff;

    s32 min = fo_min << 8;
    s32 max = fo_max << 8;

    s32 new_vol = 0;
    if (xdiff <= max && ydiff <= max && zdiff <= max) {
        while (max > 0x7fff) {
            max >>= 1;
            min >>= 1;
            xdiff >>= 1;
            ydiff >>= 1;
            zdiff >>= 1;
        }
        u32 dist_squared = xdiff * xdiff + ydiff * ydiff + zdiff * zdiff;
        s32 dist_steps = 0;
        if (dist_squared != 0) {
            while ((dist_squared & 0xc0000000) == 0) {
                ++dist_steps;
                dist_squared <<= 2;
            }
            dist_steps = sqrt_table[dist_squared >> 24] >> (dist_steps & 0x1f);
        }
        new_vol = volume;
        if (min < dist_steps) {
            u32 voldiff = dist_steps - min;
            if (dist_steps < max) {
                dist_steps = max - min;
                while (voldiff > 0xffff) {
                    dist_steps >>= 1;
                    voldiff >>= 1;
                }
                voldiff = (voldiff << 0x10) / dist_steps;
                if (voldiff != 0x10000) {
                    new_vol = (voldiff * voldiff) >> 0x10;
                    const Curve& curve = gCurves[fo_curve & 15];
                    new_vol = (curve.unk4 * 0x10000 + curve.unk3 * voldiff + curve.unk2 * new_vol +
                               curve.unk1 * ((new_vol * voldiff) >> 0x10)) >>
                              0xc;
                    if (new_vol < 0) {
                        new_vol = 0;
                    } else if (0x10000 < new_vol) {
                        new_vol = 0x10000;
                    }
                    new_vol = (new_vol * volume) >> 0x10;
                }
            } else {
                new_vol = 0;
            }
        }
    }
    return new_vol;
}

s32 GetVolume(Sound* sound) {
    return CalculateFalloffVolume(&sound->params.trans, sound->params.volume, sound->params.fo_curve,
                                  sound->params.fo_min, sound->params.fo_max);
}

void UpdateVolume(Sound* sound) {
    s32 id = snd_SoundIsStillPlaying(sound->sound_handle);
    sound->sound_handle = id;
    if (sound->sound_handle == 0) {
        sound->id = 0;
    } else {
        gPlayer->SetSoundVolPan(id, GetVolume(sound), snd::PAN_DONT_CHANGE);
    }
}

Sound* AllocateSound() {
    for (int pass = 0; pass < 2; pass++) {
        for (auto& s : gSounds) {
            if (s.id == 0) {
                s.add_index = gAddIndex++;
                return &s;
            }
        }
        CleanSounds();
    }
    return nullptr;
}

void KillSoundsInGroup(u8 group) {
    for (auto& s : gSounds) {
        if (s.id != 0) {
            s32 sndid = snd_SoundIsStillPlaying(s.sound_handle);
            s.sound_handle = sndid;
            if (sndid == 0) {
                s.id = 0;
            } else if (s.params.group & group) {
                gPlayer->StopSound(s.sound_handle);
                s.id = 0;
            }
        }
    }
}

void UpdateAutoVol(Sound* sound, s32 ticks) {
    if (ticks < sound->auto_time) {
        s32 nvol = sound->new_volume;
        if (nvol == -4) nvol = 0;

        s32 step = (nvol - sound->params.volume) * ticks;
        step /= sound->auto_time;

        if (step >= 0) {
            if (step == 0) step = 1;
            sound->params.volume += step;
            if (sound->new_volume < sound->params.volume) sound->params.volume = sound->new_volume;
        } else {
            sound->params.volume += step;
            if (sound->new_volume > sound->params.volume) sound->params.volume = sound->new_volume;
        }

        sound->auto_time -= ticks;
        return;
    }

    if (sound->new_volume == -4) {
        gPlayer->StopSound(sound->sound_handle);
        sound->id = 0;
    } else {
        sound->params.volume = sound->new_volume;
    }
    sound->auto_time = 0;
}

void SetCurve(s32 curve, s32 falloff, s32 ease) {
    if (curve < 0 || curve >= 16) return;
    gCurves[curve].unk1 = ease * 2;
    gCurves[curve].unk2 = falloff - 3 * ease;
    gCurves[curve].unk3 = ease - falloff - 0x1000;
    gCurves[curve].unk4 = 0x1000;
}

// ---- game/overlord/jak1/ssound.cpp ----

void UpdateLocation(Sound* sound) {
    if (sound->id == 0) return;

    // The overlord reads the bank entry first; checking the handle first keeps a sound from an
    // unloaded bank from reading its stale record. A finished sound is dropped either way.
    s32 id = snd_SoundIsStillPlaying(sound->sound_handle);
    if (id == 0) {
        sound->id = 0;
        return;
    }
    if ((sound->bank_entry->fallof_params >> 28) == 0) return;

    // A positional sound that falls silent is stopped, which frees its voices. Holding on to
    // out-of-range ambient loops exhausted the voice pool and silenced later effects.
    s32 volume = GetVolume(sound);
    if (volume == 0) {
        gPlayer->StopSound(sound->sound_handle);
    } else {
        gPlayer->SetSoundVolPan(id, volume, GetPan(sound));
    }
}

void SetEarTrans(const Vec3w& ear, const Vec3w& cam, s32 cam_angle) {
    s32 tick = gPlayer->GetTick();
    u32 delta = tick - sLastTick;
    sLastTick = tick;

    gEarTrans = ear;
    gCamTrans = cam;
    gCamAngle = cam_angle;

    for (auto& s : gSounds) {
        if (s.id != 0 && s.is_music == 0) {
            if (s.auto_time != 0) UpdateAutoVol(&s, delta);
            UpdateLocation(&s);
        }
    }
}

void SetMusicVol() {
    s32 volume = (gMusicVol * gMusicFade >> 0x10) * gMusicTweak >> 7;
    gPlayer->SetMasterVolume(1, volume);
    gPlayer->SetMasterVolume(2, volume);
}

void InitSound_Overlord() {
    for (auto& s : gSounds) s = {};
    for (auto& b : gBanks) {
        b = {};
        strcpy(b.name.data(), "<unused>");
    }

    SetCurve(1, 0, 0);
    SetCurve(2, 4096, 0);
    SetCurve(3, 0, 4096);
    SetCurve(4, 2048, 0);
    SetCurve(5, 2048, 2048);
    SetCurve(6, -4096, 0);
    SetCurve(7, -2048, 0);

    gPlayer = std::make_unique<snd::Player>();

    for (int i = 0; i < 91; i++) {
        s16 opposing_front = static_cast<s16>(((i * 0x33ff) / 0x5a) + 0xc00);
        s16 rear_right = static_cast<s16>(((i * -0x2800) / 0x5a) + 0x3400);
        s16 rear_left = static_cast<s16>(((i * -0xbff) / 0x5a) + 0x3fff);

        gPanTable[90 - i].left = 0x3FFF;
        gPanTable[180 - i].left = opposing_front;
        gPanTable[270 - i].left = rear_right;
        gPanTable[360 - i].left = rear_left;

        gPanTable[i].right = opposing_front;
        gPanTable[90 + i].right = 0x3FFF;
        gPanTable[180 + i].right = rear_left;
        gPanTable[270 + i].right = rear_right;
    }
    gPlayer->SetPanTable(gPanTable);
    gPlayer->SetPlaybackMode(2);
}

// ---- game/overlord/common/sbank.cpp + jak1/fake_iso.cpp ----

SoundBank* AllocateBank() {
    for (int index = 0; index < kNumBanks; index++) {
        if (gBanks[index].bank_handle == nullptr) {
            // The loader reads this back to size the sound name list it reads.
            gBanks[index].sound_count = index == 0 ? 0x3fe : 0x65;
            return &gBanks[index];
        }
    }
    return nullptr;
}

s32 LookupSoundIndex(const char* name, SoundBank** bank_out) {
    for (auto& bank : gBanks) {
        if (!bank.bank_handle) continue;
        for (int i = 0; i < (int)bank.sound_count; i++) {
            if (memcmp(bank.sound[i].name.data(), name, 16) == 0) {
                *bank_out = &bank;
                return i;
            }
        }
    }
    return -1;
}

// The overlord matches unloaded banks too, which would make a level bank that was unloaded and
// is later needed again (revisiting a level) skip its reload. Only loaded banks match here.
SoundBank* LookupBank(const char* name) {
    for (int index = kNumBanks - 1; index >= 0; index--) {
        SoundBank& bank = gBanks[index];
        if (bank.bank_handle != nullptr && memcmp(bank.name.data(), name, 16) == 0) return &bank;
    }
    return nullptr;
}

// FS_LoadSoundBank: the SBK starts with the overlord's name list, and the 989snd bank follows
// it 10 sectors (common bank slot) or 1 sector in.
void LoadSoundBank(const char* bank_name, SoundBank* bank) {
    char namebuf[16] {};
    strncpy(namebuf, bank_name, 8);
    strcat(namebuf, ".sbk");

    std::vector<uint8_t> data = gReader(namebuf);
    if (data.empty()) {
        lg::warn("sound bank {} not found, using empty1.sbk", namebuf);
        data = gReader("empty1.sbk");
        if (data.empty()) return;
    }
    if (data.size() < 24) return;

    u32 offset = bank->sound_count == 101 ? 1 * 2048 : 10 * 2048;
    // Accept the other name-list size too, in case a bank lands in an unexpected slot.
    auto bankStartsAt = [&](u32 candidate) {
        if (candidate + 4 > data.size()) return false;
        u32 type = 0;
        memcpy(&type, data.data() + candidate, 4);
        return type == 1 || type == 3;
    };
    if (!bankStartsAt(offset)) offset = offset == 2048 ? 10 * 2048 : 2048;
    if (!bankStartsAt(offset)) return;

    memcpy(bank->name.data(), data.data(), 16);
    u32 count = 0;
    memcpy(&count, data.data() + 20, sizeof(count));
    count = std::min<u32>(count, (u32)((std::min<size_t>(offset, data.size()) - 24) / 20));
    bank->sound_count = count;
    bank->sound.resize(count);
    for (u32 i = 0; i < count; i++) {
        const uint8_t* record = data.data() + 24 + i * 20;
        memcpy(bank->sound[i].name.data(), record, 16);
        memcpy(&bank->sound[i].fallof_params, record + 16, 4);
    }

    bank->bank_handle =
        gPlayer->LoadBank(std::span<u8>(data.data() + offset, data.size() - offset));
    lg::info("loaded sound bank {} ({} sounds) handle={}", namebuf, count, (void*)bank->bank_handle);
}

// FS_LoadMusic + iso_api.cpp LoadMusic's tweak lookup.
void LoadMusic(const char* music_name) {
    char namebuf[16] {};
    strncpy(namebuf, music_name, 8);
    strcat(namebuf, ".mus");
    std::vector<uint8_t> data = gReader(namebuf);
    if (!data.empty()) {
        gMusic = gPlayer->LoadBank(std::span<u8>(data.data(), data.size()));
    }
    lg::info("loaded music {} handle={}", namebuf, (void*)gMusic);

    for (u32 i = 0; i < gMusicTweakInfo.TweakCount && i < kMusicTweakCount; i++) {
        if (!strncmp(gMusicTweakInfo.MusicTweak[i].MusicName, music_name, 12)) {
            gMusicTweak = gMusicTweakInfo.MusicTweak[i].VolumeAdjust;
            return;
        }
    }
    gMusicTweak = 0x80;
}

void LoadMusicTweaks() {
    std::vector<uint8_t> data = gReader("TWEAKVAL.MUS");
    gMusicTweakInfo = {};
    memcpy(&gMusicTweakInfo, data.data(), std::min(data.size(), sizeof(gMusicTweakInfo)));
}

// The parts of LOAD_MUSIC/UNLOAD_MUSIC after the fade-out wait.
void FinishMusicRequest() {
    if (gMusic) {
        gPlayer->UnloadBank(gMusic);
        gMusic = nullptr;
    }
    if (gMusicRequest == MusicRequest::Load) LoadMusic(gMusicRequestName);
    gMusicRequest = MusicRequest::None;
}

void RequestMusic(MusicRequest request, const char* name) {
    gMusicRequest = request;
    memset(gMusicRequestName, 0, sizeof(gMusicRequestName));
    if (name != nullptr) memcpy(gMusicRequestName, name, 15);
    if (gMusic) {
        gMusicFadeDir = -1;
        // Nothing to wait for when the music is already silent.
        if (gMusicFade == 0) FinishMusicRequest();
    } else {
        FinishMusicRequest();
    }
}

template <typename T>
T Read(const uint8_t* bytes, size_t offset) {
    T value;
    memcpy(&value, bytes + offset, sizeof(T));
    return value;
}

}  // namespace

void Init(FileReader reader) {
    std::scoped_lock lock(gLock);
    gReader = std::move(reader);
    if (gPlayer) return;
    InitSound_Overlord();
    LoadMusicTweaks();
    // gsound.gc loads the common bank while the engine boots, which the captured kernel image
    // has already run past. Load it into its slot here; GOAL's own request then finds it.
    char common[16] {"common"};
    if (SoundBank* bank = AllocateBank()) LoadSoundBank(common, bank);
}

void Render(int16_t* stereo, int frames) {
    // Not under gLock: Player::Tick takes the 989snd lock, as the cubeb callback does.
    snd::Player* player = gPlayer.get();
    if (player == nullptr) {
        memset(stereo, 0, sizeof(int16_t) * 2 * frames);
        return;
    }
    static_assert(sizeof(snd::s16Output) == 4, "s16Output is interleaved stereo");
    player->Tick(reinterpret_cast<snd::s16Output*>(stereo), frames);
}

void BeginPlayerRpc() {
    std::scoped_lock lock(gLock);
    if (!gPlayer) return;
    // PollSema(gSema) fails while the loader is waiting on a music fade.
    if (gMusicRequest == MusicRequest::None && gMusic && !gMusicPause && !LookupSound(kMusicSoundId)) {
        Sound* music = AllocateSound();
        if (music != nullptr) {
            gMusicFade = 0;
            gMusicFadeDir = 1;
            SetMusicVol();
            music->sound_handle = gPlayer->PlaySound(gMusic, 0, 0x400, -1, 0, 0);
            music->id = kMusicSoundId;
            music->is_music = 1;
        }
    }

    SetMusicVol();
    Sound* music = LookupSound(kMusicSoundId);
    if (music != nullptr) {
        gPlayer->SetSoundVolPan(music->sound_handle, snd::VOLUME_DONT_CHANGE, 0);
        gPlayer->SetSoundReg(music->sound_handle, 0, (u8)gFlava);
    }
}

bool HandlePlayerCommand(const uint8_t* cmd) {
    std::scoped_lock lock(gLock);
    if (!gPlayer) return false;
    const u16 command = Read<u16>(cmd, 2);
    switch (command) {
        case PLAY: {
            const u32 sound_id = Read<u32>(cmd, 4);
            if (sound_id == 0) break;
            const char* name = reinterpret_cast<const char*>(cmd + 16);
            if (!memcmp(name, "spool-", 6)) break;  // VAG stream, handled by the host

            SoundBank* bank = nullptr;
            s32 index = LookupSoundIndex(name, &bank);
            if (index < 0) break;

            const SoundParams parms = Read<SoundParams>(cmd, 32);
            Sound* sound = LookupSound(sound_id);
            const bool existing = sound != nullptr;
            if (!existing) {
                sound = AllocateSound();
                if (!sound) break;
                sound->auto_time = 0;
            }
            sound->params = parms;
            sound->bank_entry = &bank->sound[index];
            sound->is_music = 0;
            if ((sound->params.mask & 0x40) == 0) {
                sound->params.fo_min = sound->bank_entry->fallof_params & 0x3fff;
            }
            if ((sound->params.mask & 0x80) == 0) {
                sound->params.fo_max = (sound->bank_entry->fallof_params >> 14) & 0x3fff;
            }
            if ((sound->params.mask & 0x100) == 0) {
                sound->params.fo_curve = sound->bank_entry->fallof_params >> 28;
            }

            if (existing) {
                // PLAY with a live id only updates that sound.
                UpdateVolume(sound);
                gPlayer->SetSoundPmod(sound->sound_handle, parms.pitch_mod);
                gPlayer->SetSoundPBend(sound->sound_handle, parms.bend);
                break;
            }

            s32 vol = GetVolume(sound);
            s32 pan = GetPan(sound);
            s32 handle = gPlayer->PlaySound(bank->bank_handle, index, vol, pan,
                                            sound->params.pitch_mod, sound->params.bend);
            sound->sound_handle = handle;
            if (sound->sound_handle) sound->id = sound_id;
        } break;
        case PAUSE_SOUND: {
            Sound* sound = LookupSound(Read<u32>(cmd, 4));
            if (sound == nullptr) return false;
            gPlayer->PauseSound(sound->sound_handle);
            return true;
        }
        case STOP_SOUND: {
            Sound* sound = LookupSound(Read<u32>(cmd, 4));
            if (sound == nullptr) return false;
            gPlayer->StopSound(sound->sound_handle);
            return true;
        }
        case CONTINUE_SOUND: {
            Sound* sound = LookupSound(Read<u32>(cmd, 4));
            if (sound == nullptr) return false;
            gPlayer->ContinueSound(sound->sound_handle);
            return true;
        }
        case SET_PARAM: {
            Sound* sound = LookupSound(Read<u32>(cmd, 4));
            if (sound == nullptr) return false;
            const SoundParams parms = Read<SoundParams>(cmd, 8);
            const s32 auto_time = Read<s32>(cmd, 40);
            const u32 mask = parms.mask;
            if (mask & 1) {
                if (mask & 0x10) {
                    sound->auto_time = auto_time;
                    sound->new_volume = parms.volume;
                } else {
                    sound->params.volume = parms.volume;
                }
            }
            if (mask & 0x20) sound->params.trans = parms.trans;
            if (mask & 0x21) UpdateVolume(sound);
            // snd_AutoPitch/snd_AutoPitchBend ramps are applied immediately (OpenGOAL leaves
            // them unimplemented, which kept the old pitch).
            if (mask & 2) {
                sound->params.pitch_mod = parms.pitch_mod;
                gPlayer->SetSoundPmod(sound->sound_handle, parms.pitch_mod);
            }
            if (mask & 4) {
                sound->params.bend = parms.bend;
                gPlayer->SetSoundPBend(sound->sound_handle, parms.bend);
            }
            return true;
        }
        case SET_MASTER_VOLUME: {
            const u32 group = cmd[4];
            const s32 volume = Read<s32>(cmd, 8);
            for (int i = 0; i < 32; i++) {
                if (((group >> i) & 1) != 0) {
                    if (i == 1) {
                        gMusicVol = volume;
                    } else if (i != 2) {  // group 2 is the dialog (VAG) volume
                        gPlayer->SetMasterVolume(i, volume);
                    }
                }
            }
        } break;
        case PAUSE_GROUP: {
            gPlayer->PauseAllSoundsInGroup(cmd[4]);
            if (cmd[4] & 2) gMusicPause = 1;
        } break;
        case STOP_GROUP:
            KillSoundsInGroup(cmd[4]);
            break;
        case CONTINUE_GROUP: {
            gPlayer->ContinueAllSoundsInGroup(cmd[4]);
            if (cmd[4] & 2) gMusicPause = 0;
        } break;
        case SET_FALLOFF_CURVE:
            SetCurve(Read<s32>(cmd, 4), Read<s32>(cmd, 8), Read<s32>(cmd, 12));
            break;
        case SET_SOUND_FALLOFF: {
            SoundBank* bank = nullptr;
            s32 idx = LookupSoundIndex(reinterpret_cast<const char*>(cmd + 16), &bank);
            if (idx >= 0) {
                bank->sound[idx].fallof_params =
                    (Read<s32>(cmd, 32) << 28) | (Read<s32>(cmd, 40) << 14) | Read<s32>(cmd, 36);
            }
        } break;
        case SET_FLAVA:
            gFlava = cmd[4];
            break;
        case SET_EAR_TRANS:
            SetEarTrans(Read<Vec3w>(cmd, 4), Read<Vec3w>(cmd, 16), Read<s32>(cmd, 28));
            break;
        default:
            break;
    }
    return false;
}

void HandleLoaderCommand(const uint8_t* cmd) {
    std::scoped_lock lock(gLock);
    if (!gPlayer) return;
    const u16 command = Read<u16>(cmd, 2);
    const char* name = reinterpret_cast<const char*>(cmd + 16);
    char safeName[17] {};
    memcpy(safeName, name, 16);
    switch (command) {
        case LOAD_BANK:
            if (!LookupBank(safeName)) {
                if (SoundBank* bank = AllocateBank()) LoadSoundBank(safeName, bank);
            }
            break;
        case UNLOAD_BANK:
            if (SoundBank* bank = LookupBank(safeName)) {
                snd::BankHandle id = bank->bank_handle;
                bank->bank_handle = nullptr;
                gPlayer->UnloadBank(id);
            }
            break;
        case RELOAD_INFO:
            break;
        case LOAD_MUSIC:
            RequestMusic(MusicRequest::Load, safeName);
            break;
        case UNLOAD_MUSIC:
            RequestMusic(MusicRequest::Unload, nullptr);
            break;
        case MIRROR_MODE:
            gMirrorMode = cmd[4];
            break;
        default:
            break;
    }
}

void VBlank() {
    std::scoped_lock lock(gLock);
    if (!gPlayer) return;
    if (gMusicFadeDir > 0) {
        gMusicFade += (0x10000 / 64);
        if (gMusicFade > 0x10000 || (gMusicFadeHack & 1)) {
            gMusicFade = 0x10000;
            gMusicFadeDir = 0;
        }
    } else if (gMusicFadeDir < 0) {
        gMusicFade -= (0x10000 / 128);
        if (gMusicFade < 0 || (gMusicFadeHack & 2)) {
            gMusicFade = 0;
            gMusicFadeDir = 0;
        }
    }
    // The music master volume follows the fade between player RPCs as well; on the IOP the next
    // RPC_Player (sent every frame) applied it.
    SetMusicVol();
    if (gMusicRequest != MusicRequest::None && gMusicFade == 0) FinishMusicRequest();
}

void SetFlavaHack(uint64_t value) {
    snd::SoundFlavaHack = value;
}

void SetFadeHack(uint32_t value) {
    std::scoped_lock lock(gLock);
    gMusicFadeHack = value;
}

void CalculateVAGVolumes(int32_t volume, int32_t dialogVolume, bool positioned,
                         const int32_t trans[3], int32_t* left, int32_t* right) {
    std::scoped_lock lock(gLock);
    if (positioned) {
        const Vec3w position {trans[0], trans[1], trans[2]};
        volume = CalculateFalloffVolume(&position, (volume * dialogVolume) >> 10, 1, 10, 50);
        const snd::VolPair& pan = gPanTable[(630 - CalculateAngle(&position)) % 360];
        *left = std::min((pan.left * volume) >> 10, 0x3FFF);
        *right = std::min((pan.right * volume) >> 10, 0x3FFF);
    } else {
        volume = std::min((volume * dialogVolume) >> 6, 0x3FFF);
        *left = volume;
        *right = volume;
    }
}

}  // namespace jak1sound
