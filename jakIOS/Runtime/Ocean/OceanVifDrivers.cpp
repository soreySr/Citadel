// DMA-driving parts of OpenGOAL's OceanMid.cpp, OceanNear.cpp and OceanTexture.cpp, reshaped to
// take one transfer at a time (their DmaFollower loops live in Jak1Ocean.mm). The VU programs
// they call are the unchanged OpenGOAL ports in *_PS2.cpp.
#define FMT_HEADER_ONLY 1
#include "OceanMid.h"
#include "OceanNear.h"
#include "OceanTexture.h"

#include <cstring>

namespace {
// VIF codes (common/dma/dma.h).
constexpr u32 kNop = 0x00, kStcycl = 0x01, kOffset = 0x02, kBase = 0x03, kStmod = 0x05,
              kMscalf = 0x15, kFlushA = 0x13, kDirect = 0x50;

u32 kind(u32 vif) {
  return (vif >> 24) & 0x7f;
}
u32 imm(u32 vif) {
  return vif & 0xffff;
}
u32 num(u32 vif) {
  return (vif >> 16) & 0xff;
}
bool is_unpack(u32 vif) {
  return (kind(vif) & 0x60) == 0x60;
}
// unpack format: vn (bits 2-3) and vl (bits 0-1) of the command
u32 unpack_format(u32 vif) {
  return kind(vif) & 0xf;
}
constexpr u32 kV4_32 = 0b1100, kV4_8 = 0b1110;
u16 unpack_addr(u32 vif) {
  return imm(vif) & 0x3ff;
}
bool unpack_tops(u32 vif) {
  return imm(vif) & 0x8000;
}
}  // namespace

// ---- OceanMid (OceanMid::run) ----

OceanMid::OceanMid() {
  for (auto& x : m_vu_data) {
    x.fill(999.);
  }
  vu.vf25 = Vf(1, 1, 1, 1);
}

bool OceanMid::begin(const u8* constants) {
  m_common_ocean_renderer.init_for_mid();
  memcpy(&m_constants, constants, sizeof(Constants));
  memcpy(m_vu_data + Vu1Data::CONSTANTS, &m_constants, sizeof(Constants));
  run_call0();
  return true;
}

bool OceanMid::transfer(u32 vif0, u32 vif1, const u8* data, u32 size) {
  if (kind(vif0) == kStcycl && imm(vif0) == 0x404 && is_unpack(vif1) && unpack_format(vif1) == kV4_32) {
    u16 addr = unpack_addr(vif1) + (unpack_tops(vif1) ? get_upload_buffer() : 0);
    if (addr + num(vif1) > 1024 || 16 * num(vif1) > size) return false;
    memcpy(m_vu_data + addr, data, 16 * num(vif1));
  } else if (kind(vif0) == kStcycl && imm(vif0) == 0x404 && is_unpack(vif1) &&
             unpack_format(vif1) == kV4_8) {
    u16 addr = unpack_addr(vif1) + get_upload_buffer();
    if (addr + num(vif1) > 1024 || 4 * num(vif1) > size) return false;
    u32 temp[4];
    for (u32 i = 0; i < num(vif1); i++) {
      for (u32 j = 0; j < 4; j++) {
        temp[j] = data[4 * i + j];
      }
      memcpy(m_vu_data + addr + i, temp, 16);
    }
  } else if (kind(vif0) == kStcycl && imm(vif0) == 0x204 && is_unpack(vif1) &&
             unpack_format(vif1) == kV4_8) {
    u16 addr = unpack_addr(vif1) + get_upload_buffer();
    if (addr + 4 * ((num(vif1) + 1) / 2) > 1024 || 4 * num(vif1) > size) return false;
    u32 temp[4];
    for (u32 i = 0; i < num(vif1); i++) {
      for (u32 j = 0; j < 4; j++) {
        temp[j] = data[4 * i + j];
      }
      // cl = 4, wl = 2
      u32 addr_off = 4 * (i / 2) + i % 2;
      memcpy(m_vu_data + addr + addr_off, temp, 16);
    }
  } else if (kind(vif0) == kStcycl && imm(vif0) == 0x404 && kind(vif1) == kMscalf) {
    switch (imm(vif1)) {
      case 46: run_call46_vu2c(); break;
      case 73: run_call73_vu2c(); break;
      case 107: run_call107_vu2c(); break;
      case 275: run_call275_vu2c(); break;
      default: break;
    }
  } else if (kind(vif0) == kMscalf && kind(vif1) == kFlushA) {
    switch (imm(vif0)) {
      case 41: run_call41_vu2c(); break;
      case 43: run_call43_vu2c(); break;
      default: return false;
    }
  } else {
    return false;
  }
  return true;
}

void OceanMid::run_call0() {
  run_call0_vu2c();
}

void OceanMid::xgkick(u16 addr) {
  m_common_ocean_renderer.kick_from_mid((const u8*)&m_vu_data[addr]);
}

// ---- OceanNear (OceanNear::render_jak1) ----

OceanNear::OceanNear() {
  for (auto& a : m_vu_data) {
    a.fill(0);
  }
}

bool OceanNear::transfer(u32 vif0, u32 vif1, const u8* data, u32 size) {
  if (kind(vif0) == kStcycl && is_unpack(vif1) && unpack_format(vif1) == kV4_32) {
    u16 addr = unpack_addr(vif1) + (unpack_tops(vif1) ? get_upload_buffer() : 0);
    if (addr + num(vif1) > 1024 || 16 * num(vif1) > size) return false;
    memcpy(m_vu_data + addr, data, 16 * num(vif1));
  } else if (kind(vif0) == kMscalf && kind(vif1) == kStmod) {
    switch (imm(vif0)) {
      case 0: run_call0_vu2c(); break;
      case 39: run_call39_vu2c(); break;
      default: return false;
    }
  }
  return true;
}

void OceanNear::xgkick(u16 addr) {
  m_common_ocean_renderer.kick_from_near((const u8*)&m_vu_data[addr]);
}

// ---- OceanTexture (OceanTexture::handle_ocean_texture_jak1) ----

OceanTexture::OceanTexture() {
  m_dbuf_x = m_dbuf_a;
  m_dbuf_y = m_dbuf_b;
  m_tbuf_x = m_tbuf_a;
  m_tbuf_y = m_tbuf_b;
  init_pc();
}

void OceanTexture::init_pc() {
  int i = 0;
  m_pc.vertex_positions.resize(NUM_VERTS);
  m_pc.vertex_dynamic.resize(NUM_VERTS);
  m_pc.index_buffer.clear();
  for (u32 strip = 0; strip < NUM_STRIPS; strip++) {
    u32 lo = 64 * strip;
    u32 hi = 64 * (strip + 1);
    for (u32 vert_pair = 0; vert_pair < NUM_VERTS_PER_STRIP / 2; vert_pair++) {
      m_pc.index_buffer.push_back(i);
      m_pc.vertex_positions[i++] = math::Vector2f(vert_pair * 64, lo);
      m_pc.index_buffer.push_back(i);
      m_pc.vertex_positions[i++] = math::Vector2f(vert_pair * 64, hi);
    }
    m_pc.index_buffer.push_back(UINT32_MAX);
  }
}

void OceanTexture::destroy_pc() {}

void OceanTexture::setup_renderer() {
  m_pc.vtx_idx = 0;
}

int OceanTexture::run(const Transfer* t, int count) {
  // display setup, base/offset, constants, envmap adgif, first verts, START,
  // 9 x (verts, REST), last verts (2 parts), REST, DONE
  constexpr int kTransfers = 6 + 2 * NUM_FRAG_LOOPS + 2 + 1 + 1;
  if (count < kTransfers) return 0;
  int at = 1;  // (set-display-gs-state ...) isn't needed
  if (!(t[at].size == 0 && kind(t[at].vif0) == kBase && kind(t[at].vif1) == kOffset)) return 0;
  at++;
  if (t[at].size != sizeof(OceanTextureConstants) || kind(t[at].vif0) != kStcycl) return 0;
  memcpy(&m_texture_constants, t[at].data, sizeof(OceanTextureConstants));
  at++;
  if (t[at].size != sizeof(AdGifData) + 16 || kind(t[at].vif1) != kDirect) return 0;
  memcpy(&m_envmap_adgif, t[at].data + 16, sizeof(AdGifData));
  setup_renderer();
  at++;

  m_texture_vertices_loading = m_texture_vertices_a;
  m_texture_vertices_drawing = m_texture_vertices_b;
  if (t[at].size != sizeof(m_texture_vertices_a)) return 0;
  memcpy(m_texture_vertices_loading, t[at].data, sizeof(m_texture_vertices_a));
  at++;
  if (kind(t[at].vif0) != kMscalf || imm(t[at].vif0) != TexVu1Prog::START) return 0;
  run_L1_PC();
  at++;

  for (int i = 0; i < NUM_FRAG_LOOPS; i++) {
    if (t[at].size != sizeof(m_texture_vertices_a)) return 0;
    memcpy(m_texture_vertices_loading, t[at].data, sizeof(m_texture_vertices_a));
    at++;
    if (kind(t[at].vif0) != kMscalf || imm(t[at].vif0) != TexVu1Prog::REST) return 0;
    run_L2_PC();
    at++;
  }

  if (t[at].size != 128 * 16 || t[at + 1].size != 64 * 16) return 0;
  memcpy(m_texture_vertices_loading, t[at].data, 128 * 16);
  memcpy(m_texture_vertices_loading + 128, t[at + 1].data, 64 * 16);
  at += 2;
  if (kind(t[at].vif0) != kMscalf || imm(t[at].vif0) != TexVu1Prog::REST) return 0;
  run_L2_PC();
  at++;
  if (kind(t[at].vif0) != kMscalf || imm(t[at].vif0) != TexVu1Prog::DONE) return 0;
  at++;
  if (m_pc.vtx_idx != NUM_VERTS) return 0;
  return at;
}
