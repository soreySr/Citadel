#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <string_view>
#include <ctime>
#include <dlfcn.h>
#include <execinfo.h>
#include <mach/mach_time.h>
#include <os/log.h>

#define FMT_HEADER_ONLY 1
#include "game/mips2c/jak1_functions/merc_blend_shape.cpp"
#include "game/mips2c/jak1_functions/ripple.cpp"
#include "game/mips2c/jak1_functions/ocean_vu0.cpp"
#include "game/mips2c/jak1_functions/sparticle_launcher.cpp"
#include "game/mips2c/jak1_functions/sparticle.cpp"
#include "game/mips2c/jak1_functions/texture.cpp"
#include "game/mips2c/jak1_functions/bones.cpp"
#include "game/mips2c/jak1_functions/joint.cpp"
#include "game/mips2c/jak1_functions/generic_merc.cpp"
#include "game/mips2c/jak1_functions/generic_effect.cpp"
#include "game/mips2c/jak1_functions/generic_effect2.cpp"
#include "game/mips2c/jak1_functions/generic_tie.cpp"
#include "game/mips2c/jak1_functions/sky_tng.cpp"
#include "game/mips2c/jak1_functions/time_of_day.cpp"
#include "game/mips2c/jak1_functions/tfrag.cpp"
#include "game/mips2c/jak1_functions/tie_methods.cpp"
#include "game/mips2c/jak1_functions/shadow.cpp"
#include "game/mips2c/jak1_functions/ocean.cpp"
#include "game/mips2c/jak1_functions/draw_string.cpp"
#include "game/mips2c/jak1_functions/collide_func.cpp"
#include "game/mips2c/jak1_functions/collide_mesh.cpp"
#include "game/mips2c/jak1_functions/collide_probe.cpp"
#include "game/mips2c/jak1_functions/collide_cache.cpp"
#include "game/mips2c/jak1_functions/collide_edge_grab.cpp"

// The selected Mips2C implementation uses these process-wide bases through
// ExecutionContext's inline load/store helpers.
u8* g_ee_main_mem = nullptr;
u8* g_ee_main_mem_exec = nullptr;

namespace {
// Reports a failed Mips2C assertion with its native call stack (which names the Mips2C function
// that hit it) to stderr, os_log, and Documents/Mips2CAssert.log. The crash is intermittent and
// often happens without a debugger attached, so the log file is what survives it.
[[noreturn]] void ReportAssertAndAbort(const char* expression,
                                       const char* file,
                                       int line,
                                       const char* function,
                                       std::string_view message) {
    char header[1024];
    std::snprintf(header, sizeof(header),
                  "jakIOS Mips2C assertion failed: %s\n  at %s:%d (%s)\n  %.*s\n",
                  expression != nullptr ? expression : "(unknown expression)",
                  file != nullptr ? file : "(unknown file)", line,
                  function != nullptr ? function : "(unknown function)",
                  static_cast<int>(message.size()), message.data());

    void* frames[48];
    const int count = backtrace(frames, 48);
    char** symbols = backtrace_symbols(frames, count);

    FILE* logFile = nullptr;
    if (const char* home = std::getenv("HOME")) {
        char path[1024];
        std::snprintf(path, sizeof(path), "%s/Documents/Mips2CAssert.log", home);
        logFile = std::fopen(path, "a");
    }

    std::fputs(header, stderr);
    os_log_error(OS_LOG_DEFAULT, "%{public}s", header);
    if (logFile != nullptr) {
        std::fprintf(logFile, "==== %ld\n%s", static_cast<long>(std::time(nullptr)), header);
    }
    for (int i = 0; i < count; i++) {
        // dladdr gives the image base so raw frames can be symbolicated with atos.
        Dl_info info{};
        const uintptr_t imageOffset = dladdr(frames[i], &info) != 0 && info.dli_fbase != nullptr
            ? reinterpret_cast<uintptr_t>(frames[i]) - reinterpret_cast<uintptr_t>(info.dli_fbase)
            : 0;
        char frameLine[1024];
        std::snprintf(frameLine, sizeof(frameLine), "%s [image+0x%lx]\n",
                      symbols != nullptr ? symbols[i] : "?", static_cast<unsigned long>(imageOffset));
        std::fputs(frameLine, stderr);
        os_log_error(OS_LOG_DEFAULT, "jakIOS Mips2C frame %{public}s", frameLine);
        if (logFile != nullptr) {
            std::fputs(frameLine, logFile);
        }
    }
    if (logFile != nullptr) {
        std::fclose(logFile);
    }
    std::fflush(stderr);
    std::abort();
}
}  // namespace

[[noreturn]] void private_assert_failed(const char* expression,
                                        const char* file,
                                        int line,
                                        const char* function,
                                        const char* message) {
    ReportAssertAndAbort(expression, file, line, function, message != nullptr ? message : "");
}

[[noreturn]] void private_assert_failed(const char* expression,
                                        const char* file,
                                        int line,
                                        const char* function,
                                        const std::string_view& message) {
    ReportAssertAndAbort(expression, file, line, function, message);
}

namespace {
// Functions registered by each Mips2C link() callback, in registration order. The host binds
// each one to a signed indexed thunk (see og_jak1_mips2c_indexed_thunks_begin).
struct RegisteredMips2C {
    std::string name;
    u64 (*execute)(void*);
    u32 stackSize;
};
std::vector<RegisteredMips2C> gRegisteredMips2C;
uint32_t (*gMips2CSymbolResolver)(const char*) = nullptr;

struct ParticleProfileCounter {
    const char* name;
    uint64_t calls = 0;
    uint64_t ticks = 0;
};

ParticleProfileCounter gParticleProfiles[] = {
    {"launch"}, {"adgif"}, {"block3d"}, {"block2d"},
};
uint64_t gParticleProfileReportStart = 0;

template <typename Function>
uint64_t ProfileParticleCall(size_t index, Function&& function) {
    const uint64_t begin = mach_continuous_time();
    const uint64_t result = function();
    const uint64_t end = mach_continuous_time();
    auto& counter = gParticleProfiles[index];
    counter.calls++;
    counter.ticks += end - begin;

    if (gParticleProfileReportStart == 0) {
        gParticleProfileReportStart = begin;
    }
    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    const double elapsedMs = static_cast<double>(end - gParticleProfileReportStart) *
        static_cast<double>(timebase.numer) / static_cast<double>(timebase.denom) / 1.0e6;
    if (elapsedMs >= 1000.0) {
        std::fprintf(stderr, "jakIOS perf particles:");
        for (auto& profile : gParticleProfiles) {
            const double milliseconds = static_cast<double>(profile.ticks) *
                static_cast<double>(timebase.numer) / static_cast<double>(timebase.denom) / 1.0e6;
            std::fprintf(stderr, " %s=%llu/%.2fms", profile.name, profile.calls, milliseconds);
            profile.calls = 0;
            profile.ticks = 0;
        }
        std::fprintf(stderr, "\n");
        gParticleProfileReportStart = end;
    }
    return result;
}
}  // namespace

namespace jak1 {
// link() callbacks cache symbol addresses through this; resolve them against the GOAL image.
Ptr<Symbol> intern_from_c(const char* name) {
    return Ptr<Symbol>(gMips2CSymbolResolver != nullptr ? gMips2CSymbolResolver(name) : 0);
}
}  // namespace jak1

namespace Mips2C {
LinkedFunctionTable gLinkedFunctionTable;

void LinkedFunctionTable::reg(const std::string& name, u64 (*exec)(void*), u32 goal_stack_size) {
    gRegisteredMips2C.push_back({name, exec, goal_stack_size});
}
}  // namespace Mips2C

extern "C" void og_jak1_configure_mips2c(void* goalMemory,
                                          void* signedCodeBase,
                                          uint32_t blercGlobalsSymbol,
                                          uint32_t fakeScratchpadSymbol,
                                          uint32_t cosPolyVecSymbol,
                                          uint32_t oceanWaveFramesSymbol,
                                          uint32_t oceanWorkSymbol) {
    g_ee_main_mem = static_cast<u8*>(goalMemory);
    g_ee_main_mem_exec = static_cast<u8*>(signedCodeBase);
    Mips2C::jak1::setup_blerc_chains_for_one_fragment::cache.blerc_globals =
        g_ee_main_mem + blercGlobalsSymbol;
    Mips2C::jak1::setup_blerc_chains_for_one_fragment::cache.fake_scratchpad_data =
        g_ee_main_mem + fakeScratchpadSymbol;
    Mips2C::jak1::ripple_execute_init::cache.cos_poly_vec =
        g_ee_main_mem + cosPolyVecSymbol;
    Mips2C::jak1::ocean_interp_wave::cache.ocean_wave_frames =
        g_ee_main_mem + oceanWaveFramesSymbol;
    Mips2C::jak1::ocean_interp_wave::cache.ocean_work =
        g_ee_main_mem + oceanWorkSymbol;
}

extern "C" uint64_t og_jak1_setup_blerc_execute(void* context) {
    return Mips2C::jak1::setup_blerc_chains_for_one_fragment::execute(context);
}

extern "C" uint64_t og_jak1_ripple_execute_init(void* context) {
    return Mips2C::jak1::ripple_execute_init::execute(context);
}

extern "C" uint64_t og_jak1_ocean_interp_wave(void* context) {
    return Mips2C::jak1::ocean_interp_wave::execute(context);
}

extern "C" void og_jak1_configure_ocean_generate_verts(
    uint32_t oceanVu0WorkSymbol,
    uint32_t timeOfDayContextSymbol,
    uint32_t oceanVu0BlockSymbol,
    uint32_t uploadVu0ProgramSymbol,
    uint32_t vectorSymbol,
    uint32_t vuLightsLightGroupSymbol,
    uint32_t oceanGenerateVertsVectorSymbol) {
    auto& cache = Mips2C::jak1::ocean_generate_verts::cache;
    cache.ocean_vu0_work = g_ee_main_mem + oceanVu0WorkSymbol;
    cache.time_of_day_context = g_ee_main_mem + timeOfDayContextSymbol;
    cache.ocean_vu0_block = g_ee_main_mem + oceanVu0BlockSymbol;
    cache.upload_vu0_program = g_ee_main_mem + uploadVu0ProgramSymbol;
    cache.vector = g_ee_main_mem + vectorSymbol;
    cache.vu_lights_light_group = g_ee_main_mem + vuLightsLightGroupSymbol;
    cache.ocean_generate_verts_vector = g_ee_main_mem + oceanGenerateVertsVectorSymbol;
}

extern "C" uint64_t og_jak1_ocean_generate_verts(void* context) {
    return Mips2C::jak1::ocean_generate_verts::execute(context);
}

extern "C" void og_jak1_configure_sp_launch_particles_var(const uint32_t* symbols) {
    auto& cache = Mips2C::jak1::sp_launch_particles_var::cache;
    cache.level = g_ee_main_mem + symbols[0];
    cache.sp_launcher_enable = g_ee_main_mem + symbols[1];
    cache.sp_launcher_lock = g_ee_main_mem + symbols[2];
    cache.time_of_day_context = g_ee_main_mem + symbols[3];
    cache.add_to_sprite_aux_list = g_ee_main_mem + symbols[4];
    cache.cos = g_ee_main_mem + symbols[5];
    cache.new_sound_id = g_ee_main_mem + symbols[6];
    cache.particle_adgif = g_ee_main_mem + symbols[7];
    cache.quaternion_axis_angle = g_ee_main_mem + symbols[8];
    cache.sin = g_ee_main_mem + symbols[9];
    cache.sound_play_by_spec = g_ee_main_mem + symbols[10];
    cache.sp_adjust_launch = g_ee_main_mem + symbols[11];
    cache.sp_euler_convert = g_ee_main_mem + symbols[12];
    cache.sp_get_particle = g_ee_main_mem + symbols[13];
    cache.sp_init_fields = g_ee_main_mem + symbols[14];
    cache.sp_queue_launch = g_ee_main_mem + symbols[15];
    cache.sp_rotate_system = g_ee_main_mem + symbols[16];
    auto& adgifCache = Mips2C::jak1::particle_adgif::cache;
    adgifCache.particle_adgif_cache = g_ee_main_mem + symbols[17];
    adgifCache.particle_setup_adgif = g_ee_main_mem + symbols[18];
    auto& block3D = Mips2C::jak1::sp_process_block_3d::cache;
    block3D.sp_frame_time = g_ee_main_mem + symbols[19];
    block3D.quaternion = g_ee_main_mem + symbols[20];
    block3D.sp_free_particle = g_ee_main_mem + symbols[21];
    block3D.sp_relaunch_particle_3d = g_ee_main_mem + symbols[22];
    auto& block2D = Mips2C::jak1::sp_process_block_2d::cache;
    block2D.sp_frame_time = g_ee_main_mem + symbols[19];
    block2D.sp_free_particle = g_ee_main_mem + symbols[21];
    block2D.sp_orbiter = g_ee_main_mem + symbols[23];
    block2D.sp_relaunch_particle_2d = g_ee_main_mem + symbols[24];
}

extern "C" uint64_t og_jak1_sp_launch_particles_var(void* context) {
    return ProfileParticleCall(0, [&] {
        return Mips2C::jak1::sp_launch_particles_var::execute(context);
    });
}

extern "C" uint64_t og_jak1_particle_adgif(void* context) {
    return ProfileParticleCall(1, [&] {
        return Mips2C::jak1::particle_adgif::execute(context);
    });
}

extern "C" uint64_t og_jak1_sp_process_block_3d(void* context) {
    return ProfileParticleCall(2, [&] {
        return Mips2C::jak1::sp_process_block_3d::execute(context);
    });
}

extern "C" uint64_t og_jak1_sp_process_block_2d(void* context) {
    return ProfileParticleCall(3, [&] {
        return Mips2C::jak1::sp_process_block_2d::execute(context);
    });
}

extern "C" uint64_t og_jak1_adgif_shader_texture_with_update(void* context) {
    return Mips2C::jak1::adgif_shader_texture_with_update::execute(context);
}

// Runs every Jak 1 link() callback from mips2c_table.cpp. Must be called after
// og_jak1_configure_mips2c (symbol caches are stored as host pointers into GOAL memory).
// Returns the number of registered functions.
extern "C" uint32_t og_jak1_mips2c_link_all(uint32_t (*resolveSymbol)(const char*)) {
    using namespace Mips2C::jak1;
    gMips2CSymbolResolver = resolveSymbol;
    gRegisteredMips2C.clear();
    void (*const callbacks[])() = {
        draw_string::link, particle_adgif::link, sp_launch_particles_var::link,
        sp_process_block_3d::link, sp_process_block_2d::link,
        adgif_shader_texture_with_update::link, draw_large_polygon::link, init_sky_regs::link,
        clip_polygon_against_positive_hyperplane::link, render_sky_quad::link,
        render_sky_tri::link, set_tex_offset::link, set_sky_vf27::link,
        set_sky_vf23_value::link, init_boundary_regs::link, render_boundary_quad::link,
        render_boundary_tri::link, draw_boundary_polygon::link, draw_inline_array_tfrag::link,
        stats_tfrag_asm::link, time_of_day_interp_colors_scratch::link,
        collide_do_primitives::link, moving_sphere_triangle_intersect::link,
        collide_probe_node::link, collide_probe_instance_tie::link,
        method_12_collide_mesh::link, method_11_collide_mesh::link,
        method_15_collide_mesh::link, method_14_collide_mesh::link,
        method_26_collide_cache::link, method_32_collide_cache::link,
        pc_upload_collide_frag::link, method_28_collide_cache::link,
        method_27_collide_cache::link, method_29_collide_cache::link,
        method_12_collide_shape_prim_mesh::link, method_14_collide_shape_prim_mesh::link,
        method_13_collide_shape_prim_mesh::link, method_30_collide_cache::link,
        method_9_collide_cache_prim::link, method_10_collide_cache_prim::link,
        method_10_collide_puss_work::link, method_9_collide_puss_work::link,
        method_16_collide_edge_work::link, method_15_collide_edge_work::link,
        method_10_collide_edge_hold_list::link, method_18_collide_edge_work::link,
        calc_animation_from_spr::link, cspace_parented_transformq_joint::link,
        bones_mtx_calc::link, draw_bones_merc::link, draw_bones_check_longest_edge_asm::link,
        blerc_execute::link, setup_blerc_chains_for_one_fragment::link,
        generic_merc_init_asm::link, generic_merc_execute_asm::link, mercneric_convert::link,
        high_speed_reject::link, generic_prepare_dma_double::link, generic_light_proc::link,
        generic_envmap_proc::link, generic_prepare_dma_single::link,
        generic_envmap_dproc::link, generic_interp_dproc::link, generic_no_light_dproc::link,
        ripple_execute_init::link, ripple_create_wave_table::link,
        ripple_apply_wave_table::link, ripple_matrix_scale::link, init_ocean_far_regs::link,
        render_ocean_quad::link, draw_large_polygon_ocean::link, ocean_interp_wave::link,
        ocean_generate_verts::link, shadow_execute::link, shadow_add_double_edges::link,
        shadow_add_double_tris::link, shadow_add_single_edges::link,
        shadow_add_facing_single_tris::link, shadow_add_verts::link,
        shadow_find_double_edges::link, shadow_find_facing_double_tris::link,
        shadow_find_single_edges::link, shadow_find_facing_single_tris::link,
        shadow_init_vars::link, shadow_scissor_top::link, shadow_scissor_edges::link,
        shadow_calc_dual_verts::link, shadow_xform_verts::link,
        draw_inline_array_instance_tie::link, draw_inline_array_prototype_tie_generic_asm::link,
        generic_tie_dma_to_spad_sync::link, generic_tie_convert::link,
    };
    for (const auto callback : callbacks) {
        callback();
    }
    return static_cast<uint32_t>(gRegisteredMips2C.size());
}

// Describes registered function `index`: its GOAL name ("foo" or "(method N type)"),
// C entry point and GOAL stack size. Returns false when out of range.
extern "C" bool og_jak1_mips2c_registered(uint32_t index, const char** name,
                                          uint64_t (**execute)(void*), uint32_t* stackSize) {
    if (index >= gRegisteredMips2C.size()) {
        return false;
    }
    const RegisteredMips2C& entry = gRegisteredMips2C[index];
    *name = entry.name.c_str();
    *execute = entry.execute;
    *stackSize = entry.stackSize;
    return true;
}
