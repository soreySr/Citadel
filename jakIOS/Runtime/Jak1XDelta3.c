// Compiles OpenGOAL's xdelta3 build (third-party/xdelta3) into the app. The game-text builder uses
// xd3_decode_memory to apply OpenGOAL's NTSC-v1 -> v2 text patches, as the decompiler does.
#pragma clang diagnostic ignored "-Weverything"
#include "third-party/xdelta3/xdelta3.c"
