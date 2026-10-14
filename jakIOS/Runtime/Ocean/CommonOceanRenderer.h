#pragma once
// iOS version of OpenGOAL game/graphics/opengl_renderer/ocean/CommonOceanRenderer: the GIF
// packets kicked by the mid/near ocean VU programs are bucketed exactly as in OpenGOAL; the
// GL flush is replaced by a snapshot (OceanDrawList) that the Metal renderer draws.

#include "common/common_types.h"
#include "common/math/Vector.h"

#include <vector>

struct OceanDrawList {
  struct Vertex {
    math::Vector<float, 3> xyz;
    math::Vector<u8, 4> rgba;
    math::Vector<float, 3> stq;
    u8 fog;
    u8 pad[3];
  };
  static_assert(sizeof(Vertex) == 32);

  bool mid = false;  // flush_mid (2 buckets) vs flush_near (3 buckets)
  std::vector<Vertex> vertices;
  std::vector<u32> indices[3];  // RGB_TEXTURE, ALPHA, ENV_MAP (mid: ocean, envmap)
  u32 envmap_tbp = 0;
};

class CommonOceanRenderer {
 public:
  CommonOceanRenderer();

  void init_for_near();
  void kick_from_near(const u8* data);
  void flush_near(OceanDrawList* out);

  void init_for_mid();
  void kick_from_mid(const u8* data);
  void flush_mid(OceanDrawList* out);

 private:
  void handle_near_vertex_gif_data_fan(const u8* data, u32 offset, u32 loop);
  void handle_near_vertex_gif_data_strip(const u8* data, u32 offset, u32 loop);
  void handle_near_adgif(const u8* data, u32 offset, u32 count);
  void handle_mid_adgif(const u8* data, u32 offset);
  bool room_for(u32 vertices) const;

  enum VertexBucket {
    RGB_TEXTURE = 0,
    ALPHA = 1,
    ENV_MAP = 2,
  };
  u32 m_current_bucket = VertexBucket::RGB_TEXTURE;

  using Vertex = OceanDrawList::Vertex;
  static constexpr int NUM_BUCKETS = 3;

  std::vector<Vertex> m_vertices;
  u32 m_next_free_vertex = 0;

  std::vector<u32> m_indices[NUM_BUCKETS];
  u32 m_next_free_index[NUM_BUCKETS] = {0};

  u32 m_envmap_tex = 0;
};
