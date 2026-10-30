// Mod levels built at import: goalc's custom level builder (goalc/build_level/jak1/build_level.cpp,
// run_build_level) with two changes for the phone:
//   * The disc is read one DGO at a time (GAME.CGO + that DGO), like Jak1LevelExtractor.cpp, instead of
//     every DGO in one ObjectFileDB. Each step below mirrors run_build_level's order, so the output is the
//     same as goalc's.
//   * The glb ships without the game's data (tools/modlevel/modlevel_pack.cpp). Its recipe
//     (Jak1ModLevelRecipe.h) names the disc textures to put back into its images and the game geometry to put
//     back into its meshes; both are restored on the loaded glb before the mesh is read.
//   * An optional "ios_offset": [x, y, z] (meters) in the jsonc moves the whole level in the world (the glb's scene
//     roots, every actor / ambient position, path, movie-pos and vol plane), so a mod level can be placed somewhere
//     else than its author put it. The level's GOAL side (level-info continues, custom nav meshes) is moved by hand.
#include "Jak1ModLevelBuilder.h"
#include "Jak1ModLevelRecipe.h"

// Xcode's Debug configuration defines DEBUG=1, which breaks the decompiler's Cop0 register enum
// (decompiler/Disasm/Register.h has a register named DEBUG).
#ifdef DEBUG
#undef DEBUG
#endif

#include <algorithm>
#include <array>
#include <cstring>
#include <exception>
#include <fstream>
#include <map>
#include <set>
#include <stdexcept>
#include <vector>

#include "common/log/log.h"
#include "common/util/FileUtil.h"
#include "common/util/compress.h"
#include "common/util/gltf_util.h"
#include "common/util/json_util.h"

#include "decompiler/Disasm/OpcodeInfo.h"
#include "decompiler/ObjectFile/ObjectFileDB.h"
#include "decompiler/config.h"
#include "decompiler/data/TextureDB.h"
#include "decompiler/level_extractor/BspHeader.h"
#include "decompiler/level_extractor/extract_collide_frags.h"
#include "decompiler/level_extractor/extract_level.h"
#include "decompiler/level_extractor/extract_merc.h"
#include "goalc/build_actor/common/MercExtract.h"
#include "goalc/build_actor/jak1/build_actor.h"
#include "goalc/build_level/collide/jak1/collide_bvh.h"
#include "goalc/build_level/collide/jak1/collide_pack.h"
#include "goalc/build_level/common/Tfrag.h"
#include "goalc/build_level/common/Tie.h"
#include "goalc/build_level/common/build_level.h"
#include "goalc/build_level/common/gltf_mesh_extract.h"
#include "goalc/build_level/jak1/Entity.h"
#include "goalc/build_level/jak1/FileInfo.h"
#include "goalc/build_level/jak1/LevelFile.h"

namespace jak1 {

namespace {

using decompiler::ObjectFileDB;
using decompiler::TextureDB;

bool EndsWith(const std::string &text, const std::string &suffix) {
    return text.size() >= suffix.size() &&
           text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Object names in a DGO/CGO header (art groups without their "-ag", which the decompiler adds). Used only to
// skip files that can't hold anything the level needs.
std::set<std::string> ArchiveObjectNames(const fs::path &path, std::string *last) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("missing " + path.filename().string() + " on the imported disc");
    std::set<std::string> names;
    uint32_t count = 0;
    stream.read(reinterpret_cast<char *>(&count), 4);
    stream.seekg(64);
    for (uint32_t i = 0; i < count && stream; i++) {
        uint32_t size = 0;
        char name[61] {};
        stream.read(reinterpret_cast<char *>(&size), 4);
        stream.read(name, 60);
        names.insert(name);
        if (last) *last = name;
        stream.seekg((size + 15) & ~15u, std::ios::cur);
    }
    return names;
}

// The ObjectFileDB steps run_build_level uses (no code analysis, no texture merges).
struct DiscArchive {
    explicit DiscArchive(const std::vector<fs::path> &archives, const decompiler::Config &config,
                         const fs::path &textureDump)
        : db(archives, fs::path(config.obj_file_name_map_file), {}, {}, {}, {}, config) {
        db.process_link_data(config);
        db.process_tpages(tex, textureDump, config, "");
    }
    ObjectFileDB db;
    TextureDB tex;
};

// Moves every world position in the level description by offset (meters): trans / bsphere centres, and the lumps
// that hold positions (vector3m / vector4m paths, movie-pos), and vector-vol planes (n . p <= w: w += n . offset).
void OffsetLevelJson(nlohmann::json &level, const std::array<double, 3> &offset) {
    const auto shift = [&](nlohmann::json &v) {
        if (!v.is_array() || v.size() < 3) return;
        for (int c = 0; c < 3; c++) v[c] = v[c].get<double>() + offset[c];
    };
    for (const char *list : {"actors", "ambients", "cameras"}) {
        if (!level.contains(list)) continue;
        for (auto &actor : level.at(list)) {
            if (actor.contains("trans")) shift(actor.at("trans"));
            if (actor.contains("bsphere")) shift(actor.at("bsphere"));
            if (!actor.contains("lump")) continue;
            for (auto &[key, value] : actor.at("lump").items()) {
                if (!value.is_array() || value.empty() || !value[0].is_string()) continue;
                std::string type = value[0].get<std::string>();
                type = type.substr(0, type.find('@'));
                for (size_t i = 1; i < value.size(); i++) {
                    if (type == "vector3m" || type == "vector4m" || type == "movie-pos") {
                        shift(value[i]);
                    } else if (type == "vector-vol" && value[i].is_array() && value[i].size() == 4) {
                        double w = value[i][3].get<double>();
                        for (int c = 0; c < 3; c++) w += value[i][c].get<double>() * offset[c];
                        value[i][3] = w;
                    }
                }
            }
        }
    }
}

// The same offset on the glb: every scene's root nodes (children follow).
void OffsetGlbRoots(tinygltf::Model &model, const std::array<double, 3> &offset) {
    std::set<int> roots;
    for (const auto &scene : model.scenes) roots.insert(scene.nodes.begin(), scene.nodes.end());
    for (int index : roots) {
        auto &node = model.nodes.at(index);
        if (node.matrix.size() == 16) {
            for (int c = 0; c < 3; c++) node.matrix[12 + c] += offset[c];
        } else {
            node.translation.resize(3, 0.0);
            for (int c = 0; c < 3; c++) node.translation[c] += offset[c];
        }
    }
}

struct GlbImageFill {
    struct Entry {
        const TextureDB::TextureData *texture = nullptr;
        std::array<int, 4> set {-1, -1, -1, -1};
        std::array<int, 4> from {0, 1, 2, 3};
    };
    std::map<int, Entry> byImage;
};

// tinygltf image callback: listed images come from the disc, the rest are decoded from the glb.
bool LoadGlbImage(tinygltf::Image *image, const int index, std::string *err, std::string *warn,
                  int requestWidth, int requestHeight, const unsigned char *bytes, int size, void *user) {
    const auto *fill = static_cast<const GlbImageFill *>(user);
    const auto found = fill->byImage.find(index);
    if (found == fill->byImage.end()) {
        return tinygltf::LoadImageData(image, index, err, warn, requestWidth, requestHeight, bytes, size,
                                       nullptr);
    }
    const TextureDB::TextureData &texture = *found->second.texture;
    image->width = texture.w;
    image->height = texture.h;
    image->component = 4;
    image->bits = 8;
    image->pixel_type = TINYGLTF_COMPONENT_TYPE_UNSIGNED_BYTE;
    image->image.resize(texture.rgba_bytes.size() * 4);
    // Channels the mod author painted a constant over, or that come from another channel of the texture.
    const auto &entry = found->second;
    for (size_t p = 0; p < texture.rgba_bytes.size(); p++) {
        for (int c = 0; c < 4; c++) {
            image->image[p * 4 + c] =
                entry.set[c] >= 0 ? (u8)entry.set[c] : (u8)(texture.rgba_bytes[p] >> (8 * entry.from[c]));
        }
    }
    return true;
}

GlbImageFill ImageFillFor(const ModLevelRecipe &recipe, const std::map<u32, TextureDB::TextureData> &discTextures) {
    GlbImageFill fill;
    for (const auto &image : recipe.images) {
        fill.byImage[image.index] = {&discTextures.at(image.id), image.set, image.from};
    }
    return fill;
}

// A custom actor model's glb, with the recipe's images (if fill is given) and geometry put back.
tinygltf::Model LoadModelGlb(const ModLevelModel &model, const ModLevelRecipe &recipe, const GlbImageFill *fill,
                             const std::string &levels) {
    tinygltf::TinyGLTF loader;
    if (fill) loader.SetImageLoader(&LoadGlbImage, const_cast<GlbImageFill *>(fill));
    tinygltf::Model result;
    std::string err, warn;
    if (!loader.LoadBinaryFromFile(&result, &err, &warn, model.glb)) {
        throw std::runtime_error("could not read the " + model.name + " model: " + err);
    }
    ApplyModLevelGeometry(result, recipe, levels);
    return result;
}

}  // namespace

bool BuildModLevel(const ModLevelPaths &paths, const ModLevelProgress &progress, std::string *error) {
    using namespace decompiler;
    try {
        file_util::setup_project_path(fs::path(paths.project), true);
        init_opcode_info();
        // Same config override as run_build_level.
        Config config = read_config_file(
            fs::path(paths.project) / "decompiler/config/jak1/jak1_config.jsonc", "ntsc_v1",
            R"({"decompile_code": false, "find_functions": false, "levels_extract": true, "allowed_objects": [], "save_texture_pngs": false})");
        const fs::path disc(paths.disc);
        const fs::path textureDump = fs::path(paths.fr3).parent_path() / "mod-level-textures";
        file_util::create_dir_if_needed(textureDump);

        std::string gameCgo;
        for (const auto &name : config.dgo_names) {
            if (EndsWith(name, "GAME.CGO")) gameCgo = name;
        }
        if (gameCgo.empty()) throw std::runtime_error("the config lists no GAME.CGO");
        // GAME.CGO is loaded with every other archive, as the level extractor does.
        const auto archivesFor = [&](const std::string &name) {
            std::vector<fs::path> archives {disc / gameCgo};
            if (name != gameCgo) archives.push_back(disc / name);
            return archives;
        };
        const int total = static_cast<int>(config.dgo_names.size()) * 2 + 4;
        int step = 0;
        const auto report = [&](const std::string &label) {
            if (progress) progress(step, total, label);
            step++;
        };

        auto level_json = parse_commented_json(file_util::read_text_file(paths.jsonc), paths.jsonc);
        std::array<double, 3> offset {0, 0, 0};
        const bool offsetLevel = level_json.contains("ios_offset");
        if (offsetLevel) {
            offset = level_json.at("ios_offset").get<std::array<double, 3>>();
            OffsetLevelJson(level_json, offset);
        }

        // Custom actor models the level draws (their merc data goes into the fr3, after the art groups').
        const auto customModels = level_json.value("custom_models", std::vector<std::string>{});
        std::vector<const ModLevelModel *> models;
        std::vector<ModLevelRecipe> modelRecipes;
        for (const auto &name : customModels) {
            const auto found = std::ranges::find_if(paths.models, [&](const auto &m) { return m.name == name; });
            if (found == paths.models.end()) throw std::runtime_error("custom model " + name + " is missing");
            models.push_back(&*found);
            modelRecipes.push_back(found->recipe.empty() ? ModLevelRecipe {}
                                                         : ParseModLevelRecipe(file_util::read_text_file(found->recipe)));
        }

        // 1. The disc textures the glb's (and the custom models') images were made from, by texture id.
        std::map<u32, TextureDB::TextureData> discTextures;
        GlbImageFill fill;
        ModLevelRecipe recipe;
        if (!paths.recipe.empty()) recipe = ParseModLevelRecipe(file_util::read_text_file(paths.recipe));
        std::vector<RecipeImage> allImages = recipe.images;
        for (const auto &modelRecipe : modelRecipes) {
            allImages.insert(allImages.end(), modelRecipe.images.begin(), modelRecipe.images.end());
        }
        if (!allImages.empty()) {
            std::set<u32> pages;
            for (const auto &image : allImages) pages.insert(image.id >> 16);
            for (const auto &name : config.dgo_names) {
                std::set<u32> here;
                const auto objects = ArchiveObjectNames(disc / name, nullptr);
                for (u32 page : pages) {
                    if (objects.count(fmt::format("tpage-{}", page))) here.insert(page);
                }
                if (here.empty()) continue;
                report("textures " + fs::path(name).filename().string());
                DiscArchive archive(archivesFor(name), config, textureDump);
                for (const auto &image : allImages) {
                    const auto found = archive.tex.textures.find(image.id);
                    if (here.count(image.id >> 16) && found != archive.tex.textures.end()) {
                        discTextures.emplace(image.id, found->second);
                    }
                }
                for (u32 page : here) pages.erase(page);
                if (pages.empty()) break;
            }
            for (const auto &image : allImages) {
                const auto found = discTextures.find(image.id);
                if (found == discTextures.end() || found->second.name != image.name) {
                    throw std::runtime_error("texture " + image.name + " is not on the imported disc");
                }
            }
            fill = ImageFillFor(recipe, discTextures);
        }

        // 2. run_build_level from here on.
        report("mesh");
        LevelFile file {};                // GOAL level file
        tfrag3::Level pc_level;           // PC level file
        gltf_util::TexturePool tex_pool;  // pc level texture pool

        gltf_mesh_extract::Input mesh_extract_in;
        mesh_extract_in.filename = paths.glb;
        mesh_extract_in.auto_wall_enable = level_json.value("automatic_wall_detection", true);
        mesh_extract_in.double_sided_collide = level_json.at("double_sided_collide").get<bool>();
        mesh_extract_in.auto_wall_angle = level_json.value("automatic_wall_angle", 30.0);
        mesh_extract_in.tex_pool = &tex_pool;
        mesh_extract_in.image_loader = &LoadGlbImage;
        mesh_extract_in.image_loader_data = &fill;
        mesh_extract_in.model_patch = [&](tinygltf::Model &model) {
            ApplyModLevelGeometry(model, recipe, paths.levels);
            if (offsetLevel) OffsetGlbRoots(model, offset);
        };
        gltf_mesh_extract::Output mesh_extract_out;
        gltf_mesh_extract::extract(mesh_extract_in, mesh_extract_out);
        fill.byImage.clear();
        report("tfrag");

        file.info = make_file_info_for_level(fs::path(paths.jsonc).filename().string());
        file.name = level_json.at("long_name").get<std::string>();
        if (file.name.size() > 10) throw std::runtime_error("long_name over 10 characters: " + file.name);
        file.nickname = level_json.at("nickname").get<std::string>();

        std::vector<u32> aid_list;
        std::vector<EntityActor> actors;
        auto dts = decompiler::DecompilerTypeSystem(GameVersion::Jak1);
        dts.parse_type_defs({"decompiler", "config", "jak1", "all-types.gc"});
        add_actors_from_json(level_json.at("actors"), actors, level_json.value("base_id", 1234), dts);
        std::ranges::sort(actors, [](auto &a, auto &b) { return a.aid < b.aid; });
        for (auto &actor : actors) aid_list.push_back(actor.aid);
        if (std::ranges::adjacent_find(actors, [](auto &a, auto &b) { return a.aid == b.aid; }) !=
            actors.end()) {
            throw std::runtime_error("actor IDs must be unique");
        }
        file.actors = std::move(actors);
        std::vector<EntityAmbient> ambients;
        add_ambients_from_json(level_json.at("ambients"), ambients, level_json.value("base_id", 12345), dts);
        file.ambients = std::move(ambients);
        file.drawable_trees.ambients.emplace_back();
        if (level_json.contains("cameras")) {
            std::vector<EntityCamera> cameras;
            add_cameras_from_json(
                level_json.at("cameras"), cameras,
                std::max(level_json.value("base_id", 2345), (int)*std::ranges::max_element(aid_list)), dts);
            std::ranges::sort(cameras, [](auto &a, auto &b) { return a.aid < b.aid; });
            for (auto &cam : cameras) aid_list.push_back(cam.aid);
            std::ranges::sort(aid_list, [](auto &a, auto &b) { return a < b; });
            if (std::ranges::adjacent_find(aid_list, [](auto &a, auto &b) { return a == b; }) !=
                aid_list.end()) {
                throw std::runtime_error("actor and camera IDs must be unique");
            }
            file.cameras = std::move(cameras);
        }
        for (size_t i = 0; i < file.actors.size(); i++) file.actor_birth_order.push_back(i);

        pc_level.level_name = file.name;
        // Unused by custom levels and left uninitialized by goalc; zeroed so builds are repeatable.
        pc_level.hfrag.wang_tree_tex_id = {};
        pc_level.hfrag.draw_mode = {};
        pc_level.hfrag.occlusion_offset = 0;
        file.drawable_trees.tfrags.emplace_back("drawable-tree-tfrag", "drawable-inline-array-tfrag");
        file.drawable_trees.tfrags.emplace_back("drawable-tree-trans-tfrag",
                                                "drawable-inline-array-trans-tfrag");
        tfrag_from_gltf(mesh_extract_out.tfrag, pc_level.tfrag_trees[0]);
        if (!mesh_extract_out.tie.base_draws.empty()) {
            file.drawable_trees.ties.emplace_back();
            tie_from_gltf(mesh_extract_out.tie, pc_level.tie_trees[0]);
        }
        pc_level.textures = std::move(tex_pool.textures_by_idx);
        report("collision");

        if (mesh_extract_out.collide.faces.empty()) {
            lg::error("No collision geometry was found");
        } else {
            auto &collide_drawable_tree = file.drawable_trees.collides.emplace_back();
            collide_drawable_tree.bvh = collide::construct_collide_bvh(mesh_extract_out.collide.faces);
            collide_drawable_tree.packed_frags = pack_collide_frags(collide_drawable_tree.bvh.frags.frags);
            for (auto &face : mesh_extract_out.collide.faces) {
                math::Vector4f verts[3];
                for (int i = 0; i < 3; i++) {
                    verts[i].x() = face.v[i].x();
                    verts[i].y() = face.v[i].y();
                    verts[i].z() = face.v[i].z();
                    verts[i].w() = 1.f;
                }
                // Zeroed: set_vertices_for_tri leaves pad2 alone (goalc writes stack bytes there).
                tfrag3::CollisionMesh::Vertex out_verts[3] {};
                decompiler::set_vertices_for_tri(out_verts, verts);
                for (auto &out : out_verts) {
                    out.pat = face.pat.val;
                    pc_level.collision.vertices.push_back(out);
                }
            }
        }
        mesh_extract_out = {};

        const auto sky_name = level_json.value("sky", "none");
        const auto texture_remap = level_json.value("tex_remap", "none");
        const auto tpages = level_json.value("tpages", std::vector<u32>({}));
        const auto wanted_art = level_json.value("art_groups", std::vector<std::string>{});
        const bool has_textures = level_json.contains("textures") && !level_json.at("textures").empty();

        // 3. Art groups, sky and texture remap, one archive at a time in the config's order (the order
        // run_build_level visits them in its single database).
        if (!wanted_art.empty() || has_textures) {
            const bool should_process_art_groups =
                !wanted_art.empty() || (sky_name != "none" || texture_remap != "none");
            std::vector<std::string> processed_art_groups;
            // Textures the jsonc's "textures" list may ask for, collected from every archive loaded.
            TextureDB requested;
            std::set<std::string> requested_pages;
            if (has_textures) {
                for (auto &arr : level_json.at("textures")) requested_pages.insert(arr.at(0).get<std::string>());
            }
            std::set<std::string> loaded;
            const auto collect_requested = [&](const TextureDB &tex) {
                for (auto &[id, texture] : tex.textures) {
                    const auto &page = tex.tpage_names.at(texture.page);
                    if (requested_pages.count(page) && !requested.textures.count(id)) {
                        requested.textures[id] = texture;
                        requested.tpage_names[texture.page] = page;
                    }
                }
            };
            const auto seen_page = [&](const std::string &page) {
                return std::ranges::any_of(requested.tpage_names,
                                           [&](const auto &entry) { return entry.second == page; });
            };

            for (const auto &dgo : config.dgo_names) {
                const auto &dgo_name = dgo.substr(4);
                std::string last;
                const auto objects = ArchiveObjectNames(disc / dgo, &last);
                bool needed = false;
                if (should_process_art_groups) {
                    for (const auto &ag : wanted_art) {
                        if (EndsWith(ag, "-ag") &&
                            std::ranges::find(processed_art_groups, ag) == processed_art_groups.end() &&
                            objects.count(ag.substr(0, ag.size() - 3))) {
                            needed = true;
                        }
                    }
                    if (EndsWith(dgo_name, ".DGO") && last.size() > 4) {
                        const auto bsp_name = last.substr(0, last.size() - 4);
                        needed |= bsp_name == sky_name || bsp_name == texture_remap;
                    }
                }
                if (!needed) continue;
                report("art " + dgo_name);
                DiscArchive archive(archivesFor(dgo), config, textureDump);
                loaded.insert(dgo);
                collect_requested(archive.tex);
                auto &db = archive.db;
                const auto &files = db.obj_files_by_dgo.at(dgo_name);
                auto art_groups = find_art_groups(processed_art_groups, wanted_art, files);
                std::vector<level_tools::TextureRemap> tex_remap {};
                if (auto bsp = get_bsp_file(files, dgo_name)) {
                    const auto &link_data = db.lookup_record(bsp.value()).linked_data;
                    if (is_valid_bsp(link_data)) {
                        level_tools::BspHeader level_file;
                        level_file.read_from_file(link_data, dts, GameVersion::Jak1, true);
                        auto bsp_name = bsp.value().name.substr(0, bsp.value().name.size() - 4);
                        tex_remap = level_file.texture_remap_table;
                        auto is_sky_bsp = bsp_name == sky_name;
                        auto is_tex_remap_bsp = bsp_name == texture_remap;
                        auto sky_and_tex_remap_same = sky_name == texture_remap;
                        if (is_tex_remap_bsp) {
                            file.texture_remap_table.resize(tex_remap.size());
                            memcpy(file.texture_remap_table.data(), level_file.texture_remap_table.data(),
                                   tex_remap.size() * sizeof(level_tools::TextureRemap));
                            if (!tpages.empty()) {
                                file.texture_ids.resize(tpages.size());
                                for (size_t i = 0; i < tpages.size(); ++i) file.texture_ids[i] = tpages[i] << 20;
                            }
                        }
                        if (is_sky_bsp) {
                            auto &adgifs = file.adgifs.adgifs;
                            adgifs.resize(level_file.adgifs.adgifs.size());
                            memcpy(adgifs.data(), level_file.adgifs.adgifs.data(),
                                   level_file.adgifs.adgifs.size() * sizeof(AdGifData));
                        }
                        if (sky_and_tex_remap_same && is_sky_bsp && is_tex_remap_bsp && tpages.empty()) {
                            file.texture_ids.resize(level_file.texture_page_count);
                            memcpy(file.texture_ids.data(), level_file.texture_ids.data(),
                                   sizeof(u32) * level_file.texture_page_count);
                        }
                    }
                }
                for (const auto &ag : art_groups) {
                    if (ag.name.length() > 3 && !ag.name.compare(ag.name.length() - 3, 3, "-ag")) {
                        const auto &ag_file = db.lookup_record(ag);
                        lg::info("custom level: extracting art group {}", ag_file.name_in_dgo);
                        decompiler::MercSwapInfo info;
                        decompiler::extract_merc(ag_file, archive.tex, db.dts, tex_remap, pc_level, false,
                                                 db.version(), info);
                    }
                }
            }

            // A "textures" tpage not in any archive loaded above: look through the rest for it.
            for (const auto &dgo : config.dgo_names) {
                if (std::ranges::all_of(requested_pages, seen_page)) break;
                if (loaded.count(dgo)) continue;
                const auto objects = ArchiveObjectNames(disc / dgo, nullptr);
                if (std::ranges::none_of(objects, [](const std::string &n) { return n.starts_with("tpage-"); })) {
                    continue;
                }
                report("textures " + dgo.substr(4));
                DiscArchive archive(archivesFor(dgo), config, textureDump);
                loaded.insert(dgo);
                collect_requested(archive.tex);
            }

            // run_build_level's "add textures", against the requested tpages' textures.
            if (has_textures) {
                const TextureDB &tex_db = requested;
                std::map<std::string, std::vector<std::string>> processed_textures;
                auto tex_json = level_json.value("textures", std::vector<std::vector<std::string>>{});
                std::map<std::string, std::vector<std::string>> wanted_texs;
                for (auto &arr : tex_json) {
                    auto tpage_name = arr[0];
                    if (arr.size() > 1) {
                        for (size_t i = 1; i < arr.size(); i++) {
                            wanted_texs.insert({tpage_name, {arr.begin() + 1, arr.end()}});
                        }
                    } else {
                        auto it = std::find_if(tex_db.tpage_names.begin(), tex_db.tpage_names.end(),
                                               [tpage_name](const std::pair<u32, std::string> &t) {
                                                   return t.second == tpage_name;
                                               });
                        if (it != tex_db.tpage_names.end()) {
                            std::vector<std::string> tex_names;
                            for (auto &[id, tex] : tex_db.textures) {
                                if (tex_db.tpage_names.at(tex.page) == tpage_name) {
                                    tex_names.push_back(tex.name);
                                    pc_level.textures.push_back(make_texture(id, tex_db, true));
                                    processed_textures[tpage_name].push_back(tex.name);
                                }
                            }
                            wanted_texs.insert({tpage_name, tex_names});
                        }
                    }
                }
                for (auto &level_tex : pc_level.textures) {
                    auto tpage = level_tex.debug_tpage_name;
                    auto name = level_tex.debug_name;
                    auto it = std::find_if(
                        wanted_texs.begin(), wanted_texs.end(),
                        [tpage, name](const std::pair<std::string, std::vector<std::string>> &elt) {
                            return elt.first == tpage &&
                                   std::find(elt.second.begin(), elt.second.end(), name) != elt.second.end();
                        });
                    if (it != wanted_texs.end()) {
                        processed_textures[level_tex.debug_tpage_name].push_back(level_tex.debug_name);
                    }
                }
                for (auto &[id, tex] : tex_db.textures) {
                    auto db_tpage_name = tex_db.tpage_names.at(tex.page);
                    for (auto &[wanted_tpage_name, wanted_tex_list] : wanted_texs) {
                        auto processed = processed_textures[db_tpage_name];
                        if (std::find(processed.begin(), processed.end(), tex.name) != processed.end()) {
                            continue;
                        }
                        for (auto &wanted_tex : wanted_tex_list) {
                            if (db_tpage_name == wanted_tpage_name && tex.name == wanted_tex) {
                                pc_level.textures.push_back(make_texture(id, tex_db, true));
                                processed_textures[db_tpage_name].push_back(tex.name);
                            }
                        }
                    }
                }
            }
        }

        // 4. Custom models, as build_level's add_model_to_level (goalc/build_level/common/build_level.cpp).
        for (size_t m = 0; m < models.size(); m++) {
            report("model " + models[m]->name);
            const GlbImageFill modelFill = ImageFillFor(modelRecipes[m], discTextures);
            const auto model = LoadModelGlb(*models[m], modelRecipes[m], &modelFill, paths.levels);
            gltf_util::MercExtractData extractData;
            extract(models[m]->name + "-lod0", extractData, model, gltf_util::flatten_nodes_from_all_scenes(model),
                    pc_level.merc_data.indices.size(), pc_level.merc_data.vertices.size(), pc_level.textures.size());
            gltf_util::MercSwapData merc;
            merc_convert(merc, extractData);
            pc_level.merc_data.indices.insert(pc_level.merc_data.indices.end(), merc.new_indices.begin(),
                                              merc.new_indices.end());
            pc_level.merc_data.vertices.insert(pc_level.merc_data.vertices.end(), merc.new_vertices.begin(),
                                               merc.new_vertices.end());
            pc_level.merc_data.models.push_back(merc.new_model);
            pc_level.textures.insert(pc_level.textures.end(), merc.new_textures.begin(), merc.new_textures.end());
        }
        discTextures.clear();

        report("saving");
        const auto bsp = file.save_object_file();
        file_util::write_binary_file(fs::path(paths.bsp), bsp.data(), bsp.size());
        Serializer ser;
        pc_level.serialize(ser);
        const auto compressed =
            compression::compress_zstd(ser.get_save_result().first, ser.get_save_result().second);
        file_util::write_binary_file(fs::path(paths.fr3), compressed.data(), compressed.size());
        fs::remove_all(textureDump);
        if (progress) progress(total, total, "");
        return true;
    } catch (const std::exception &exception) {
        if (error) *error = exception.what();
    } catch (...) {
        if (error) *error = "mod level build failed";
    }
    return false;
}

bool BuildModLevelActor(const std::string &project, const ModLevelModel &model, const std::string &levels,
                        const std::string &output, std::string *error) {
    try {
        file_util::setup_project_path(fs::path(project), true);
        const ModLevelRecipe recipe =
            model.recipe.empty() ? ModLevelRecipe {} : ParseModLevelRecipe(file_util::read_text_file(model.recipe));
        const tinygltf::Model gltf = LoadModelGlb(model, recipe, nullptr, levels);
        // run_build_actor from here on, with the model's game.gp build-actor options.
        BuildActorParams1 params;  // as goalc's BuildActorTool gets them from game.gp's build-actor
        params.gen_collide_mesh = model.genMesh;
        params.texture_bucket = model.textureBucket;
        params.framerate = 60.0f;
        auto all_nodes = gltf_util::flatten_nodes_from_all_scenes(gltf);
        auto skin_idx = gltf_util::find_single_skin(gltf, all_nodes);
        std::vector<anim::CompressedAnim> user_anims;
        ArtGroup ag(model.name);
        std::vector<Joint> joints;
        gltf_util::MercExtractData extract_data;
        extract("test", extract_data, gltf, all_nodes, 0, 0, 0);
        ag.mdl = &extract_data.new_model;
        if (skin_idx) {
            auto skeleton_joints = extract_skeleton(gltf, *skin_idx);
            joints = convert_joints(skeleton_joints);
            user_anims = process_anim(gltf, skeleton_joints, params.master_art_group, params.master_ag_map,
                                      params.framerate);
        } else {
            auto identity = math::Matrix4f::identity();
            joints.emplace_back("align", 0, -1, identity);
            joints.emplace_back("prejoint", 1, -1, identity);
            auto main_pose = math::Matrix4f::identity();
            main_pose(3, 1) = -2194.1628418f;
            joints.emplace_back("main", 2, 1, main_pose);
        }
        std::vector<CollideMesh> mesh;
        if (params.gen_collide_mesh) mesh = gen_collide_mesh_from_model_jak1(gltf, all_nodes, 3);
        ag.elts.emplace_back(std::make_shared<ArtJointGeo>(ag.name, mesh, joints, params));
        ag.elts.emplace_back(nullptr);  // dummy merc-ctrl
        if (!user_anims.empty()) {
            for (auto &anim : user_anims) ag.elts.emplace_back(std::make_shared<ArtJointAnim>(anim, joints));
        } else {
            ag.elts.emplace_back(std::make_shared<ArtJointAnim>(ag.name, joints));
        }
        ag.length = ag.elts.size();
        const auto ag_file = ag.save_object_file();
        file_util::write_binary_file(fs::path(output), ag_file.data(), ag_file.size());
        return true;
    } catch (const std::exception &exception) {
        if (error) *error = exception.what();
    } catch (...) {
        if (error) *error = "building the " + model.name + " model failed";
    }
    return false;
}

bool AssembleModLevelDgo(const std::string &project, const std::string &disc, const std::string &gd,
                         const std::string &bsp, const std::string &outputDirectory, std::string *error,
                         const std::vector<std::pair<std::string, std::string>> &customArt) {
    using namespace decompiler;
    try {
        file_util::setup_project_path(fs::path(project), true);
        Config config = read_config_file(fs::path(project) / "decompiler/config/jak1/jak1_config.jsonc", "ntsc_v1", "{}");
        // ("NAME.DGO" ("a.o" "b-ag.go" ...)): the quoted strings in order, comments stripped.
        std::string text = file_util::read_text_file(gd);
        std::vector<std::string> strings;
        for (size_t i = 0; i < text.size(); i++) {
            if (text[i] == ';') {
                while (i < text.size() && text[i] != '\n') i++;
            } else if (text[i] == '"') {
                const size_t end = text.find('"', i + 1);
                if (end == std::string::npos) throw std::runtime_error("unterminated string in " + gd);
                strings.push_back(text.substr(i + 1, end - i - 1));
                i = end;
            }
        }
        if (strings.size() < 2) throw std::runtime_error("no objects in " + gd);
        const std::string dgoName = strings[0];
        const std::string levelName = fs::path(bsp).stem().string();

        // Object name in a DGO header: no extension, art groups without "-ag".
        const auto headerName = [](std::string name) {
            for (const char *suffix : {".go", ".o"}) {
                if (EndsWith(name, suffix)) name.resize(name.size() - strlen(suffix));
            }
            if (EndsWith(name, "-ag")) name.resize(name.size() - 3);
            return name;
        };
        // Art / texture objects wanted from the disc, by header name.
        std::map<std::string, std::vector<u8>> art;
        for (size_t i = 1; i < strings.size(); i++) {
            if (EndsWith(strings[i], ".go") && headerName(strings[i]) != levelName) art[headerName(strings[i])];
        }
        // built custom actors first (the disc never has them)
        for (const auto &[name, path] : customArt) {
            const auto found = art.find(name);
            if (found != art.end()) found->second = file_util::read_binary_file(path);
        }
        for (const auto &archive : config.dgo_names) {
            if (std::ranges::all_of(art, [](const auto &entry) { return !entry.second.empty(); })) break;
            std::ifstream stream(fs::path(disc) / archive, std::ios::binary);
            if (!stream) continue;
            uint32_t count = 0;
            stream.read(reinterpret_cast<char *>(&count), 4);
            stream.seekg(64);
            for (uint32_t i = 0; i < count && stream; i++) {
                uint32_t size = 0;
                char name[61] {};
                stream.read(reinterpret_cast<char *>(&size), 4);
                stream.read(name, 60);
                const auto found = art.find(name);
                std::vector<u8> data(size);
                stream.read(reinterpret_cast<char *>(data.data()), size);
                stream.seekg(((size + 15) & ~15u) - size, std::ios::cur);
                // art and texture pages are v4 objects (0xffffffff); code objects share their names
                uint32_t magic = 0;
                if (size >= 4) memcpy(&magic, data.data(), 4);
                if (found != art.end() && found->second.empty() && magic == 0xffffffff) found->second = std::move(data);
            }
        }
        for (const auto &[name, data] : art) {
            if (data.empty()) throw std::runtime_error("art object " + name + " is not on the imported disc");
        }

        std::vector<u8> out(64, 0);
        const uint32_t count = static_cast<uint32_t>(strings.size() - 1);
        memcpy(out.data(), &count, 4);
        memcpy(out.data() + 4, dgoName.data(), std::min<size_t>(dgoName.size(), 59));
        const auto append = [&](const std::string &name, const std::vector<u8> &data) {
            u8 header[64] {};
            const uint32_t size = static_cast<uint32_t>(data.size());
            memcpy(header, &size, 4);
            memcpy(header + 4, name.data(), std::min<size_t>(name.size(), 59));
            out.insert(out.end(), header, header + 64);
            out.insert(out.end(), data.begin(), data.end());
            out.resize(out.size() + (((size + 15) & ~15u) - size), 0);
        };
        // A code object the kernel never runs: "GOAL" + zeros (anything but 0xffffffff means code).
        const std::vector<u8> codeStub {'G', 'O', 'A', 'L', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
        for (size_t i = 1; i < strings.size(); i++) {
            const auto name = headerName(strings[i]);
            if (EndsWith(strings[i], ".o")) {
                append(name, codeStub);
            } else if (name == levelName) {
                append(name, file_util::read_binary_file(bsp));
            } else {
                append(name, art.at(name));
            }
        }
        file_util::write_binary_file(fs::path(outputDirectory) / dgoName, out.data(), out.size());
        return true;
    } catch (const std::exception &exception) {
        if (error) *error = exception.what();
    } catch (...) {
        if (error) *error = "DGO assembly failed";
    }
    return false;
}

}  // namespace jak1
