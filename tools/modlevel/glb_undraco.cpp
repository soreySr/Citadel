// Decodes a glb's KHR_draco_mesh_compression meshes into plain accessors (one buffer, tightly packed), so
// modlevel_pack and the import's builder (whose tinygltf has no Draco) can read it. goalc decodes Draco the same way
// (OpenGOAL builds tinygltf with TINYGLTF_ENABLE_DRACO), so the level built from the output is the same.
//
// Usage: glb_undraco <in.glb> <out.glb>
// Build: sh tools/modlevel/build.sh (builds Draco from OpenGOAL/third-party/draco once).
#define TINYGLTF_IMPLEMENTATION
#define TINYGLTF_ENABLE_DRACO
#define TINYGLTF_NO_STB_IMAGE
#define TINYGLTF_NO_STB_IMAGE_WRITE
#define TINYGLTF_NO_EXTERNAL_IMAGE
#include "third-party/tiny_gltf/tiny_gltf.h"

#include <cstdio>
#include <cstring>

namespace {

// Images stay encoded: they keep their bufferView and are copied byte for byte.
bool KeepImage(tinygltf::Image *, const int, std::string *, std::string *, int, int, const unsigned char *, int,
               void *) {
    return true;
}
bool NoWrite(const std::string *, const std::string *, tinygltf::Image *, bool, void *) {
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: glb_undraco <in.glb> <out.glb>\n");
        return 2;
    }
    tinygltf::TinyGLTF loader;
    loader.SetImageLoader(&KeepImage, nullptr);
    tinygltf::Model in;
    std::string err, warn;
    if (!loader.LoadBinaryFromFile(&in, &err, &warn, argv[1])) {
        fprintf(stderr, "%s: %s\n", argv[1], err.c_str());
        return 1;
    }

    // One new buffer: image bufferViews, then every accessor's elements packed.
    tinygltf::Model out = in;
    out.buffers.assign(1, {});
    out.bufferViews.clear();
    auto &data = out.buffers[0].data;
    const auto align = [&] { data.resize((data.size() + 3) & ~size_t(3), 0); };
    const auto addView = [&](const unsigned char *bytes, size_t size, int target) {
        align();
        tinygltf::BufferView view;
        view.buffer = 0;
        view.byteOffset = data.size();
        view.byteLength = size;
        view.target = target;
        data.insert(data.end(), bytes, bytes + size);
        out.bufferViews.push_back(view);
        return int(out.bufferViews.size() - 1);
    };
    for (auto &image : out.images) {
        if (image.bufferView < 0) continue;
        const auto &view = in.bufferViews.at(image.bufferView);
        const auto &buffer = in.buffers.at(view.buffer);
        image.bufferView = addView(buffer.data.data() + view.byteOffset, view.byteLength, 0);
        image.image.clear();
    }
    // Index accessors get ELEMENT_ARRAY_BUFFER, the rest ARRAY_BUFFER.
    std::vector<bool> isIndex(in.accessors.size(), false);
    for (const auto &mesh : in.meshes) {
        for (const auto &prim : mesh.primitives) {
            if (prim.indices >= 0) isIndex[prim.indices] = true;
        }
    }
    for (size_t a = 0; a < out.accessors.size(); a++) {
        auto &accessor = out.accessors[a];
        if (accessor.sparse.isSparse) {
            fprintf(stderr, "accessor %zu: sparse accessors are not supported\n", a);
            return 1;
        }
        if (accessor.bufferView < 0) continue;  // never filled (unused)
        const auto &view = in.bufferViews.at(accessor.bufferView);
        const auto &buffer = in.buffers.at(view.buffer);
        const size_t element = tinygltf::GetComponentSizeInBytes(accessor.componentType) *
                               tinygltf::GetNumComponentsInType(accessor.type);
        const size_t stride = view.byteStride ? view.byteStride : element;
        std::vector<unsigned char> packed(element * accessor.count);
        for (size_t i = 0; i < accessor.count; i++) {
            memcpy(packed.data() + i * element, buffer.data.data() + view.byteOffset + accessor.byteOffset + i * stride,
                   element);
        }
        accessor.bufferView = addView(packed.data(), packed.size(), isIndex[a] ? TINYGLTF_TARGET_ELEMENT_ARRAY_BUFFER
                                                                               : TINYGLTF_TARGET_ARRAY_BUFFER);
        accessor.byteOffset = 0;
    }
    for (auto &mesh : out.meshes) {
        for (auto &prim : mesh.primitives) prim.extensions.erase("KHR_draco_mesh_compression");
    }
    std::erase(out.extensionsUsed, "KHR_draco_mesh_compression");
    std::erase(out.extensionsRequired, "KHR_draco_mesh_compression");

    tinygltf::TinyGLTF writer;
    writer.SetImageWriter(&NoWrite, nullptr);
    if (!writer.WriteGltfSceneToFile(&out, argv[2], false, false, false, true)) {
        fprintf(stderr, "could not write %s\n", argv[2]);
        return 1;
    }
    printf("%s: %zu accessors, %zu images, %zu bytes of buffer\n", argv[2], out.accessors.size(), out.images.size(),
           data.size());
    return 0;
}
