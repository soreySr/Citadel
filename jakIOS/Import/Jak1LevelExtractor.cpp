// Level extraction at ISO import: the minimal path of OpenGOAL's run_decompilation_process
// (decompiler/decompilation_process.cpp, minimal_for_extractor = true, stock jak1 config), followed by
// extract_all_levels' work (decompiler/level_extractor/extract_level.cpp) done level by level with
// explicit output folders instead of the project's out/ and decompiler_out/.
#include "Jak1LevelExtractor.h"

// Xcode's Debug configuration defines DEBUG=1, which breaks the decompiler's Cop0 register enum
// (decompiler/Disasm/Register.h has a register named DEBUG).
#ifdef DEBUG
#undef DEBUG
#endif

#include <exception>
#include <map>
#include <stdexcept>
#include <vector>

#include "common/log/log.h"
#include "common/util/FileUtil.h"

#include "decompiler/Disasm/OpcodeInfo.h"
#include "decompiler/ObjectFile/ObjectFileDB.h"
#include "decompiler/config.h"
#include "decompiler/data/TextureDB.h"
#include "decompiler/level_extractor/extract_level.h"

namespace decompiler {
// Defined in extract_level.cpp; extract_all_levels runs them on one thread per level.
void extract_common(const ObjectFileDB &db,
                    const TextureDB &tex_db,
                    const std::string &dgo_name,
                    const fs::path &output_folder,
                    const Config &config);
void extract_from_level(const ObjectFileDB &db,
                        const TextureDB &tex_db,
                        const std::string &dgo_name,
                        const Config &config,
                        const fs::path &output_folder,
                        const fs::path &entities_folder);
}  // namespace decompiler

namespace jak1 {

namespace {

bool EndsWith(const std::string &text, const std::string &suffix) {
    return text.size() >= suffix.size() &&
           text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

}  // namespace

bool ExtractLevels(const LevelExtractorPaths &paths, const LevelExtractorProgress &progress,
                   std::string *error) {
    using namespace decompiler;
    try {
        file_util::setup_project_path(fs::path(paths.project), true);
        init_opcode_info();
        Config config = read_config_file(
            fs::path(paths.project) / "decompiler/config/jak1/jak1_config.jsonc", "ntsc_v1", "{}");

        // Inputs as in minimal_for_extractor (GAME.CGO + level DGOs, texture STRs), but loaded per
        // level: the full set needs ~1.8 GB, GAME.CGO + one level DGO a small fraction of that.
        const fs::path disc(paths.disc);
        std::string gameCgo;
        std::map<std::string, std::string> levelDgos;  // "VI1.DGO" -> "DGO/VI1.DGO"
        for (const auto &name : config.dgo_names) {
            if (EndsWith(name, "GAME.CGO")) gameCgo = name;
            if (EndsWith(name, "DGO")) levelDgos[fs::path(name).filename().string()] = name;
        }
        std::vector<fs::path> texStrs, artStrs;
        for (const auto &name : config.str_texture_file_names) texStrs.push_back(disc / name);
        for (const auto &name : config.str_art_file_names) artStrs.push_back(disc / name);

        const fs::path scratch(paths.scratch);
        const fs::path output(paths.output);
        file_util::create_dir_if_needed(output);
        file_util::create_dir_if_needed(scratch / "textures");
        file_util::create_dir_if_needed(scratch / "entities");
        const auto mergePath = fs::path(paths.project) / "game/assets/jak1/texture_merges";

        // Steps of run_decompilation_process that level extraction depends on.
        const auto extractWith = [&](const std::vector<fs::path> &dgos, const auto &extract) {
            ObjectFileDB db(dgos, fs::path(config.obj_file_name_map_file), {}, {}, texStrs, artStrs,
                            config);
            db.process_link_data(config);
            db.find_code(config);
            db.process_labels();
            if (config.find_functions) db.ir2_top_level_pass(config);
            if (!config.art_group_info_dump.empty()) db.dts.art_group_info = config.art_group_info_dump;
            if (!config.jg_info_dump.empty()) db.dts.jg_info = config.jg_info_dump;
            if (config.process_part_group_table && !config.part_group_table.empty()) {
                db.dts.part_group_table = config.part_group_table;
            }
            if (config.process_tpages && !config.texture_info_dump.empty()) {
                db.dts.textures = config.texture_info_dump;
            }
            TextureDB texDB;
            db.process_tpages(texDB, scratch / "textures", config, "");
            if (fs::exists(mergePath)) texDB.merge_textures(mergePath);
            extract(db, texDB);
        };

        if (gameCgo.empty()) throw std::runtime_error("the config lists no GAME.CGO");
        const int total = static_cast<int>(config.levels_to_extract.size()) + 1;
        if (progress) progress(0, total, "GAME");
        extractWith({disc / gameCgo}, [&](const ObjectFileDB &db, const TextureDB &texDB) {
            extract_common(db, texDB, "GAME.CGO", output, config);
        });
        for (int index = 0; index < total - 1; index++) {
            const auto &dgo = config.levels_to_extract[index];
            if (progress) progress(index + 1, total, dgo);
            const auto found = levelDgos.find(dgo);
            if (found == levelDgos.end()) throw std::runtime_error("the config lists no " + dgo);
            extractWith({disc / gameCgo, disc / found->second},
                        [&](const ObjectFileDB &db, const TextureDB &texDB) {
                            extract_from_level(db, texDB, dgo, config, output, scratch / "entities");
                        });
        }
        if (progress) progress(total, total, "");
        return true;
    } catch (const std::exception &exception) {
        if (error) *error = exception.what();
    } catch (...) {
        if (error) *error = "level extraction failed";
    }
    return false;
}

}  // namespace jak1
