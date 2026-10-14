#pragma once
// iOS shim of OpenGOAL game/graphics/opengl_renderer/ShadowRenderer.h: identical VU state and
// program declarations (used verbatim by Shadow_PS2.cpp), without OpenGL or BucketRenderer.
// ShadowRenderer.cpp's DMA walk and xgkick are ported in ShadowRenderer.cpp; drawing is in Jak1Shadow.mm.

#define FMT_HEADER_ONLY 1
#include "fmt/format.h"

#include "game/common/vu.h"
#include "common/math/Vector.h"

#include <cstddef>

class ShadowRenderer {
 public:
  // One DMA transfer of the shadow bucket, in chain order.
  struct Transfer {
    u32 tag_kind;  // DmaTag::Kind
    u32 vif0, vif1;
    const u8* data;
    u32 size_bytes;
  };

  struct Vertex {
    math::Vector3f xyz;
    u32 flag;  // 1 if front face, 0 otherwise
  };
  static_assert(sizeof(Vertex) == 16);

  static constexpr int MAX_VERTICES = 8192 * 3;
  static constexpr int MAX_INDICES = 8192 * 3;

  // ShadowRenderer::render up to draw(): runs the VU programs for the bucket's transfers.
  // Returns false when the bucket is empty or isn't laid out as expected.
  bool run(const Transfer* transfers, size_t count);

  const Vertex* vertices() const { return m_vertices; }
  u32 vertex_count() const { return m_next_vertex; }
  const u32* front_indices() const { return m_front_indices; }
  u32 front_index_count() const { return m_next_front_index; }
  const u32* back_indices() const { return m_back_indices; }
  u32 back_index_count() const { return m_next_back_index; }
  const math::Vector4f& color() const { return m_color; }

 private:
  void run_mscal_vu2c(u16 imm);
  void xgkick(u16 imm);
  void run_mscal10_vu2c();  // identical in jak 2
  void handle_jalr_to_end_block(u16 val, u32& first_flag, u32& second_flag);
  void handle_bal52();

  Vf m_vu_data[1024];

  enum Vu1Data {
    MATRIX = 0,
    CONSTANTS = 0x370,
    GIF_CONSTANTS = 0x3ac,
  };

  enum Vu1Code {
    INIT = 10,
  };

  void lq_buffer(Mask mask, Vf& dest, u16 addr) {
    ASSERT(addr < 1024);
    for (int i = 0; i < 4; i++) {
      if ((u64)mask & (1 << i)) {
        dest[i] = m_vu_data[addr].data[i];
      }
    }
  }

  void sq_buffer(Mask mask, const Vf& val, u16 addr) {
    ASSERT(addr < 1024);
    for (int i = 0; i < 4; i++) {
      if ((u64)mask & (1 << i)) {
        m_vu_data[addr].data[i] = val[i];
      }
    }
  }

  void ilw_buffer(Mask mask, u16& dest, u16 addr) {
    ASSERT(addr < 1024);
    switch (mask) {
      case Mask::x:
        dest = m_vu_data[addr].x_as_u16();
        break;
      case Mask::y:
        dest = m_vu_data[addr].y_as_u16();
        break;
      case Mask::z:
        dest = m_vu_data[addr].z_as_u16();
        break;
      case Mask::w:
        dest = m_vu_data[addr].w_as_u16();
        break;
      default:
        ASSERT(false);
    }
  }

  void isw_buffer(Mask mask, u16 src, u16 addr) {
    ASSERT(addr < 1024);
    u32 val32 = src;
    switch (mask) {
      case Mask::x:
        memcpy(&m_vu_data[addr].data[0], &val32, 4);
        break;
      case Mask::y:
        memcpy(&m_vu_data[addr].data[1], &val32, 4);
        break;
      case Mask::z:
        memcpy(&m_vu_data[addr].data[2], &val32, 4);
        break;
      case Mask::w:
        memcpy(&m_vu_data[addr].data[3], &val32, 4);
        break;
      default:
        ASSERT(false);
    }
  }

  struct Vu {
    const Vf vf00;
    Vu() : vf00(0, 0, 0, 1) {}

    u16 vi01, vi02, vi03, vi04, vi05, vi06, vi07, vi08, vi09, vi10, vi12, vi15;
    Vf vf01, vf02, vf03, vf04, vf05, vf06, vf07, vf08, vf09, vf10, vf11, vf12, vf13, vf14, vf15,
        vf16, vf17, vf18, vf19, vf20, vf21, vf22, vf23, vf24, vf25, vf26, vf27, vf28, vf29, vf30,
        vf31;
    Accumulator acc;
    float Q;
    const u16 vi00 = 0;
  } vu;

  Vertex m_vertices[MAX_VERTICES];
  u32 m_front_indices[MAX_INDICES];
  u32 m_back_indices[MAX_INDICES];

  u32 m_next_vertex = 0;
  u32 m_next_front_index = 0;
  u32 m_next_back_index = 0;

  math::Vector4f m_color;
};
