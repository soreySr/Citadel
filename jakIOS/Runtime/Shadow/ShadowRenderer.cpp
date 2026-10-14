// Port of OpenGOAL game/graphics/opengl_renderer/ShadowRenderer.cpp (render's DMA walk and
// xgkick). Upstream asserts on unexpected DMA; here a mismatch drops the frame's shadows instead.

#include "ShadowRenderer.h"

#include "common/dma/gs.h"

namespace {
constexpr u32 kTagCall = 5;  // DmaTag::Kind::CALL

// Room left at the end of the arrays for the full-screen quad Jak1Shadow draws (upstream adds
// it in draw()), so xgkick never fills them completely.
constexpr u32 kReservedVertices = 4;
constexpr u32 kReservedIndices = 6;
}  // namespace

void ShadowRenderer::xgkick(u16 imm) {
  u32 ind_of_fan_start = UINT32_MAX;
  bool fan_running = false;
  const u8* data = (const u8*)(m_vu_data + imm);

  u8 rgba[4] = {1, 2, 3, 4};

  bool eop = false;

  u32 offset = 0;
  while (!eop) {
    if (imm * 16 + offset + 16 > sizeof(m_vu_data)) return;
    GifTag tag(data + offset);
    offset += 16;

    // unpack registers.
    // faster to do it once outside of the nloop loop.
    GifTag::RegisterDescriptor reg_desc[16];
    u32 nreg = tag.nreg();
    for (u32 i = 0; i < nreg; i++) {
      reg_desc[i] = tag.reg(i);
    }

    auto format = tag.flg();
    if (format != GifTag::Format::PACKED) return;  // upstream: ASSERT(false)
    for (u32 loop = 0; loop < tag.nloop(); loop++) {
      for (u32 reg = 0; reg < nreg; reg++) {
        if (imm * 16 + offset + 16 > sizeof(m_vu_data)) return;
        switch (reg_desc[reg]) {
          case GifTag::RegisterDescriptor::AD: {
            GsRegisterAddress addr;
            memcpy(&addr, data + offset + 8, sizeof(GsRegisterAddress));
            if (addr == GsRegisterAddress::RGBAQ) {
              rgba[0] = data[0 + offset];
              rgba[1] = data[1 + offset];
              rgba[2] = data[2 + offset];
              rgba[3] = data[3 + offset];
            }
          } break;
          case GifTag::RegisterDescriptor::ST:
            break;
          case GifTag::RegisterDescriptor::RGBAQ:
            for (int i = 0; i < 4; i++) {
              rgba[i] = data[offset + i * 4];
            }
            break;
          case GifTag::RegisterDescriptor::XYZF2: {
            u32 x, y;
            memcpy(&x, data + offset, 4);
            memcpy(&y, data + offset + 4, 4);

            u64 upper;
            memcpy(&upper, data + offset + 8, 8);
            u32 z = (upper >> 4) & 0xffffff;

            x <<= 16;
            y <<= 16;
            z <<= 8;
            if (m_next_vertex + kReservedVertices >= (u32)MAX_VERTICES ||
                m_next_front_index + kReservedIndices + 3 > (u32)MAX_INDICES ||
                m_next_back_index + 3 > (u32)MAX_INDICES) {
              break;
            }
            u32 vidx = m_next_vertex++;
            auto& v = m_vertices[vidx];
            v.xyz[0] = (float)x / (float)UINT32_MAX;
            v.xyz[1] = (float)y / (float)UINT32_MAX;
            v.xyz[2] = (float)z / (float)UINT32_MAX;
            v.flag = 0;

            if (ind_of_fan_start == UINT32_MAX) {
              ind_of_fan_start = vidx;
            } else {
              if (fan_running) {
                if (rgba[0] > 0) {
                  // back
                  m_back_indices[m_next_back_index++] = vidx;
                  m_back_indices[m_next_back_index++] = vidx - 1;
                  m_back_indices[m_next_back_index++] = ind_of_fan_start;
                } else {
                  m_front_indices[m_next_front_index++] = vidx;
                  m_front_indices[m_next_front_index++] = vidx - 1;
                  m_front_indices[m_next_front_index++] = ind_of_fan_start;
                }
              } else {
                fan_running = true;
              }
            }
          } break;
          default:
            break;  // upstream: unsupported register assert
        }
        offset += 16;  // PACKED = quadwords
      }
    }

    eop = tag.eop();
  }
}

bool ShadowRenderer::run(const Transfer* transfers, size_t count) {
  m_next_vertex = 0;
  m_next_back_index = 0;
  m_next_front_index = 0;

  // jump to bucket, then: is the bucket empty (renderer didn't run)?
  if (count < 2 || transfers[1].tag_kind == kTagCall) return false;
  size_t at = 1;

  // constants, gif constants, matrix: STCYCL 0x404 + UNPACK V4-32 at a fixed address.
  struct Upload {
    u16 addr;
    u32 num;
  };
  for (const Upload& upload : {Upload{Vu1Data::CONSTANTS, 13}, Upload{Vu1Data::GIF_CONSTANTS, 4},
                               Upload{Vu1Data::MATRIX, 4}}) {
    if (at >= count) return false;
    const Transfer& t = transfers[at++];
    VifCode v0(t.vif0), v1(t.vif1);
    if (v0.kind != VifCode::Kind::STCYCL || v0.immediate != 0x404 ||
        v1.kind != VifCode::Kind::UNPACK_V4_32 || v1.immediate != upload.addr || v1.num != upload.num ||
        t.size_bytes < upload.num * 16) {
      return false;
    }
    memcpy(m_vu_data + upload.addr, t.data, upload.num * 16);
  }

  // exec 10
  if (at >= count) return false;
  {
    VifCode v0(transfers[at].vif0), v1(transfers[at].vif1);
    if (v0.kind != VifCode::Kind::MSCALF || v0.immediate != Vu1Code::INIT ||
        v1.kind != VifCode::Kind::FLUSHE) {
      return false;
    }
    at++;
    run_mscal10_vu2c();
  }

  // init gs direct
  at++;

  while (at < count && transfers[at].tag_kind != kTagCall) {
    const Transfer& next = transfers[at++];
    VifCode v0(next.vif0), v1(next.vif1);
    if ((v0.kind == VifCode::Kind::FLUSHA || v0.kind == VifCode::Kind::NOP) &&
        v1.kind == VifCode::Kind::UNPACK_V4_32) {
      VifCodeUnpack unpack(v1);
      if (unpack.use_tops_flag || (u32)unpack.addr_qw + v1.num >= 1024 || v1.num * 16 > next.size_bytes) {
        return false;
      }
      memcpy(m_vu_data + unpack.addr_qw, next.data, v1.num * 16);
    } else if (v0.kind == VifCode::Kind::NOP && v1.kind == VifCode::Kind::UNPACK_V4_8) {
      VifCodeUnpack up(v1);
      u16 addr = up.addr_qw;
      if (up.use_tops_flag || !up.is_unsigned || addr + v1.num > 1024) return false;
      const u32 offset = 4 * v1.num;
      if (offset + 16 > next.size_bytes) return false;

      u32 temp[4];
      for (u32 i = 0; i < v1.num; i++) {
        for (u32 j = 0; j < 4; j++) {
          temp[j] = next.data[4 * i + j];
        }
        memcpy(m_vu_data + addr + i, temp, 16);
      }

      // The MSCALF that runs the program sits in the transfer's last qw.
      u32 after[4];
      memcpy(&after, next.data + offset, 16);
      VifCode mscal(after[3]);
      if (mscal.kind != VifCode::Kind::MSCALF) return false;
      run_mscal_vu2c(mscal.immediate);
    } else if (v0.kind == VifCode::Kind::FLUSHA && v1.kind == VifCode::Kind::DIRECT) {
      // there's 4 direct transfers to set up various registers.
      // we only care about the one that has the color value.
      if (at + 3 > count || transfers[at].size_bytes < 28) return false;
      const u8* xfer1 = transfers[at].data;
      at += 3;
      m_color.x() = xfer1[24] / 255.0f;
      m_color.y() = xfer1[25] / 255.0f;
      m_color.z() = xfer1[26] / 255.0f;
      m_color.w() = xfer1[27] / 128.0f;
    } else {
      return false;
    }
  }
  return true;
}
