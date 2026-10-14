#include "CommonOceanRenderer.h"

#define FMT_HEADER_ONLY 1
#include "common/dma/gs.h"

#include <algorithm>
#include <cstring>

// Port of game/graphics/opengl_renderer/ocean/CommonOceanRenderer.cpp. Packet handling is as in
// OpenGOAL; its ASSERTs become early returns (the app has no assert-and-continue).

namespace {
constexpr int OCEAN_TEX_TBP_JAK2 = 672;
}

CommonOceanRenderer::CommonOceanRenderer() {
  m_vertices.resize(4096 * 10);
  for (auto& buf : m_indices) {
    buf.resize(4096 * 10);
  }
}

bool CommonOceanRenderer::room_for(u32 vertices) const {
  if (m_next_free_vertex + vertices + 4 > m_vertices.size()) return false;
  for (int i = 0; i < NUM_BUCKETS; i++) {
    if (m_next_free_index[i] + 4 * vertices + 4 > m_indices[i].size()) return false;
  }
  return true;
}

void CommonOceanRenderer::init_for_near() {
  m_next_free_vertex = 0;
  for (auto& x : m_next_free_index) {
    x = 0;
  }
}

void CommonOceanRenderer::kick_from_near(const u8* data) {
  bool eop = false;
  u32 offset = 0;
  while (!eop) {
    GifTag tag(data + offset);
    offset += 16;
    if (tag.nreg() == 3) {
      if (!tag.pre() || !room_for(tag.nloop())) return;
      if (GsPrim(tag.prim()).kind() == GsPrim::Kind::TRI_STRIP) {
        handle_near_vertex_gif_data_strip(data, offset, tag.nloop());
      } else {
        handle_near_vertex_gif_data_fan(data, offset, tag.nloop());
      }
      offset += 16 * 3 * tag.nloop();
    } else if (tag.nreg() == 1) {
      handle_near_adgif(data, offset, tag.nloop());
      offset += 16 * 1 * tag.nloop();
    } else {
      return;
    }
    eop = tag.eop();
  }
}

void CommonOceanRenderer::handle_near_vertex_gif_data_strip(const u8* data, u32 offset, u32 loop) {
  m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = UINT32_MAX;
  bool reset_last = false;
  for (u32 i = 0; i < loop; i++) {
    auto& dest_vert = m_vertices[m_next_free_vertex++];

    // stq
    memcpy(dest_vert.stq.data(), data + offset, 12);
    offset += 16;

    // rgba
    dest_vert.rgba[0] = data[offset];
    dest_vert.rgba[1] = data[offset + 4];
    dest_vert.rgba[2] = data[offset + 8];
    dest_vert.rgba[3] = data[offset + 12];
    offset += 16;

    // xyz
    u32 x = 0, y = 0;
    memcpy(&x, data + offset, 4);
    memcpy(&y, data + offset + 4, 4);

    u64 upper;
    memcpy(&upper, data + offset + 8, 8);
    u32 z = (upper >> 4) & 0xffffff;
    offset += 16;

    dest_vert.xyz[0] = (float)(x << 16) / (float)UINT32_MAX;
    dest_vert.xyz[1] = (float)(y << 16) / (float)UINT32_MAX;
    dest_vert.xyz[2] = (float)(z << 8) / (float)UINT32_MAX;

    u8 f = (upper >> 36);
    dest_vert.fog = f;

    auto vidx = m_next_free_vertex - 1;
    bool adc = upper & (1ull << 47);
    if (!adc) {
      m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = vidx;
      reset_last = false;
    } else {
      if (reset_last) {
        m_next_free_index[m_current_bucket] -= 3;
      }
      m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = UINT32_MAX;
      m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = vidx - 1;
      m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = vidx;
      reset_last = true;
    }
  }
}

void CommonOceanRenderer::handle_near_vertex_gif_data_fan(const u8* data, u32 offset, u32 loop) {
  u32 ind_of_fan_start = UINT32_MAX;
  bool fan_running = false;
  // :regs0 (gif-reg-id st) :regs1 (gif-reg-id rgbaq) :regs2 (gif-reg-id xyzf2)
  for (u32 i = 0; i < loop; i++) {
    auto& dest_vert = m_vertices[m_next_free_vertex++];

    // stq
    memcpy(dest_vert.stq.data(), data + offset, 12);
    offset += 16;

    // rgba
    dest_vert.rgba[0] = data[offset];
    dest_vert.rgba[1] = data[offset + 4];
    dest_vert.rgba[2] = data[offset + 8];
    dest_vert.rgba[3] = data[offset + 12];
    offset += 16;

    // xyz
    u32 x = 0, y = 0;
    memcpy(&x, data + offset, 4);
    memcpy(&y, data + offset + 4, 4);

    u64 upper;
    memcpy(&upper, data + offset + 8, 8);
    u32 z = (upper >> 4) & 0xffffff;
    offset += 16;

    dest_vert.xyz[0] = (float)(x << 16) / (float)UINT32_MAX;
    dest_vert.xyz[1] = (float)(y << 16) / (float)UINT32_MAX;
    dest_vert.xyz[2] = (float)(z << 8) / (float)UINT32_MAX;

    u8 f = (upper >> 36);
    dest_vert.fog = f;

    auto vidx = m_next_free_vertex - 1;

    if (ind_of_fan_start == UINT32_MAX) {
      ind_of_fan_start = vidx;
    } else {
      if (fan_running) {
        // hack to draw fans with strips (fans are rare).
        m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = UINT32_MAX;
        m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = vidx;
        m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = vidx - 1;
        m_indices[m_current_bucket][m_next_free_index[m_current_bucket]++] = ind_of_fan_start;
      } else {
        fan_running = true;
      }
    }
  }
}

void CommonOceanRenderer::handle_near_adgif(const u8* data, u32 offset, u32 count) {
  u32 most_recent_tbp = 0;

  for (u32 i = 0; i < count; i++) {
    u64 value;
    GsRegisterAddress addr;
    memcpy(&value, data + offset + 16 * i, sizeof(u64));
    memcpy(&addr, data + offset + 16 * i + 8, sizeof(GsRegisterAddress));
    switch (addr) {
      case GsRegisterAddress::CLAMP_1: {
        bool s = value & 0b001;
        if (s) {
          m_current_bucket = VertexBucket::ENV_MAP;
        }
      } break;
      case GsRegisterAddress::TEX0_1: {
        GsTex0 reg(value);
        if (!reg.tcc()) {
          m_current_bucket = VertexBucket::RGB_TEXTURE;
        }
        most_recent_tbp = reg.tbp0();
      } break;
      case GsRegisterAddress::ALPHA_1: {
        GsAlpha reg(value);
        if (reg.a_mode() == GsAlpha::BlendMode::SOURCE &&
            reg.b_mode() == GsAlpha::BlendMode::ZERO_OR_FIXED &&
            reg.c_mode() == GsAlpha::BlendMode::DEST && reg.d_mode() == GsAlpha::BlendMode::DEST) {
          m_current_bucket = VertexBucket::ENV_MAP;
        }
      } break;
      case GsRegisterAddress::FRAME_1: {
        u32 mask = value >> 32;
        if (mask) {
          m_current_bucket = VertexBucket::ALPHA;
        }
      } break;
      default:
        break;
    }
  }

  if (m_current_bucket == VertexBucket::ENV_MAP) {
    m_envmap_tex = most_recent_tbp;
  }
}

void CommonOceanRenderer::flush_near(OceanDrawList* out) {
  out->mid = false;
  out->vertices.assign(m_vertices.begin(), m_vertices.begin() + m_next_free_vertex);
  for (int bucket = 0; bucket < 3; bucket++) {
    out->indices[bucket].assign(m_indices[bucket].begin(),
                                m_indices[bucket].begin() + m_next_free_index[bucket]);
  }
  out->envmap_tbp = m_envmap_tex;
}

void CommonOceanRenderer::kick_from_mid(const u8* data) {
  bool eop = false;
  u32 offset = 0;
  while (!eop) {
    GifTag tag(data + offset);
    offset += 16;
    if (tag.flg() != GifTag::Format::PACKED) return;
    if (tag.nreg() == 1) {
      if (tag.pre() || tag.nloop() != 5) return;
      handle_mid_adgif(data, offset);
      offset += 5 * 16;
    } else {
      if (tag.nreg() != 3 || !tag.pre() || !room_for(tag.nloop())) return;
      m_current_bucket = GsPrim(tag.prim()).abe() ? 1 : 0;
      int count = tag.nloop();
      if (GsPrim(tag.prim()).kind() == GsPrim::Kind::TRI_STRIP) {
        handle_near_vertex_gif_data_strip(data, offset, tag.nloop());
      } else {
        handle_near_vertex_gif_data_fan(data, offset, tag.nloop());
      }
      offset += 3 * 16 * count;
    }
    eop = tag.eop();
  }
}

void CommonOceanRenderer::handle_mid_adgif(const u8* data, u32 offset) {
  u32 most_recent_tbp = 0;
  for (u32 i = 0; i < 5; i++) {
    u64 value;
    GsRegisterAddress addr;
    memcpy(&value, data + offset + 16 * i, sizeof(u64));
    memcpy(&addr, data + offset + 16 * i + 8, sizeof(GsRegisterAddress));
    if (addr == GsRegisterAddress::TEX0_1) {
      most_recent_tbp = GsTex0(value).tbp0();
    }
  }
  if (most_recent_tbp != OCEAN_TEX_TBP_JAK2) {
    m_envmap_tex = most_recent_tbp;
  }
}

void CommonOceanRenderer::init_for_mid() {
  m_next_free_vertex = 0;
  for (auto& x : m_next_free_index) {
    x = 0;
  }
}

void CommonOceanRenderer::flush_mid(OceanDrawList* out) {
  out->mid = true;
  out->vertices.assign(m_vertices.begin(), m_vertices.begin() + m_next_free_vertex);
  // The envmap pass is drawn in reverse so the high-poly mesh wins (see flush_mid in OpenGOAL).
  out->indices[0].assign(m_indices[0].begin(), m_indices[0].begin() + m_next_free_index[0]);
  out->indices[1].assign(m_indices[1].begin(), m_indices[1].begin() + m_next_free_index[1]);
  std::reverse(out->indices[1].begin(), out->indices[1].end());
  out->indices[2].clear();
  out->envmap_tbp = m_envmap_tex;
}
