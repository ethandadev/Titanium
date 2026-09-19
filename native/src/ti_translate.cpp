/*
 * Titanium — GLSL 330 (Minecraft) -> SPIR-V (glslang) -> MSL (SPIRV-Cross).
 *
 * This is source translation at pipeline-creation time. Nothing here runs per
 * frame and no Vulkan runtime is involved: SPIR-V is only an intermediate
 * representation between two compilers.
 *
 * Every C++ exception is caught before it can reach the C ABI (and from there
 * JNI, where an escaping exception would abort the JVM).
 */
#include "ti_error.h"

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>
#include "spirv_msl.hpp"

#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

struct TiTranslation {
    uint32_t    magic;
    std::string msl[2];
    std::string entry[2];
    bool        present[2] = { false, false };
    std::string reflection;
};

static const uint32_t kTranslationMagic = 0x54495452u; /* 'TITR' */

namespace {

std::once_flag g_glslang_once;

void ensure_glslang() {
    std::call_once(g_glslang_once, [] { glslang::InitializeProcess(); });
}

/*
 * Semantic fixup at the source level, for the vertex stage only.
 *
 * The user's main() is renamed through the preprocessor and wrapped, so the
 * fix runs after *every* return path of the original main — patching the end
 * of main() textually would miss early returns.
 *
 *  y: negated so a render target's memory layout matches OpenGL's
 *     (row 0 = bottom). Sampling a render target then behaves exactly as it
 *     did under GL, with no per-pass bookkeeping. Negating y reverses winding,
 *     which the caller compensates for when setting the front face.
 *  z: OpenGL clip space is [-w, w]; Metal's is [0, w].
 */
std::string wrap_vertex_main(const std::string &src) {
    size_t v = src.find("#version");
    size_t insert_at = 0;
    std::string head;
    if (v == std::string::npos) {
        head = "#version 330\n";
    } else {
        size_t eol = src.find('\n', v);
        insert_at = (eol == std::string::npos) ? src.size() : eol + 1;
    }
    std::string out;
    out.reserve(src.size() + 320);
    out += head;
    out.append(src, 0, insert_at);
    out += "#define main ti_user_main\n";
    out.append(src, insert_at, std::string::npos);
    out += "\n#undef main\n"
           "void main() {\n"
           "    ti_user_main();\n"
           "    gl_Position.y = -gl_Position.y;\n"
           "    gl_Position.z = (gl_Position.z + gl_Position.w) * 0.5;\n"
           "}\n";
    return out;
}

const char *dim_name(const spirv_cross::SPIRType &t) {
    switch (t.image.dim) {
        case spv::Dim2D:     return t.image.arrayed ? "2darray" : "2d";
        case spv::Dim3D:     return "3d";
        case spv::DimCube:   return "cube";
        case spv::DimBuffer: return "buffer";
        default:             return "other";
    }
}

/* Valid GLSL identifiers that are types or keywords in MSL. Vanilla's
 * terrain.fsh has `vec4 sampleNearest(sampler2D sampler, ...)`, which SPIRV-Cross
 * emits verbatim and the Metal compiler rejects ("must use 'struct' tag to
 * refer to type 'sampler'"). */
const char *const kMslReserved[] = {
    "sampler", "texture", "buffer", "device", "constant", "thread", "threadgroup",
    "half", "uchar", "ushort", "kernel", "vertex", "fragment", "array", "metal",
    "sample", "access", "read", "write", "depth2d", "texture2d", "texture3d",
    "texturecube", "packed_float3", "simd", "ray", "visible", "stage_in",
};

void rename_msl_reserved(spirv_cross::CompilerMSL &msl) {
    const uint32_t bound = msl.get_current_id_bound();
    for (uint32_t id = 1; id < bound; ++id) {
        const std::string &n = msl.get_name(id);
        if (n.empty()) continue;
        for (const char *r : kMslReserved) {
            if (n == r) { msl.set_name(id, n + "_ti"); break; }
        }
    }
}

struct Slot { uint32_t index; uint32_t stages; uint32_t size; std::string dim; };

/* Program-wide name -> Metal slot tables. The same uniform block or sampler
 * used by both stages must land in the same slot, because Minecraft binds it
 * once by name for the whole pipeline. */
struct Bindings {
    std::map<std::string, Slot> blocks;
    std::map<std::string, Slot> samplers;
    std::vector<std::string>    block_order, sampler_order;
    std::vector<std::pair<std::string, uint32_t>> vertex_inputs;
    /* name -> location of every user-defined vertex output. The fragment
     * stage's inputs are re-pointed at these, by name. */
    std::map<std::string, uint32_t> vertex_outputs;
    bool                            have_vertex_outputs = false;
};

bool translate_stage(const std::vector<uint32_t> &spirv, spv::ExecutionModel model,
                     const char *entry, Bindings &b, std::string &msl_out,
                     std::string &err) {
    spirv_cross::CompilerMSL msl(spirv);

    spirv_cross::CompilerMSL::Options o = msl.get_msl_options();
    o.platform = spirv_cross::CompilerMSL::Options::macOS;
    o.set_msl_version(2, 3);
    o.texture_buffer_native = true;     /* isamplerBuffer -> texture_buffer<int> */
    o.enable_decoration_binding = false;
    msl.set_msl_options(o);

    msl.rename_entry_point("main", entry, model);

    const uint32_t stage_bit = (model == spv::ExecutionModelVertex) ? 1u : 2u;

    /* Only statically-used interface variables participate, as in a GL link.
     * A fragment input that is declared but never read (vanilla's
     * rendertype_text_background declares texCoord0 and never uses it) is not
     * a link error in OpenGL — and if it were emitted into the MSL stage_in
     * struct, Metal would reject the pipeline because no vertex function
     * writes it. Unused uniforms drop out too; binding one by name is then a
     * no-op, which is also what OpenGL does. */
    auto active = msl.get_active_interface_variables();
    spirv_cross::ShaderResources res = msl.get_shader_resources(active);
    msl.set_enabled_interface_variables(std::move(active));

    /* OpenGL keeps UBO and texture bindings in separate namespaces, so glslang
     * happily gives the first UBO and the first sampler both binding 0.
     * Rewrite every resource to a unique (set 0, binding N) first, so each
     * Metal binding below is unambiguous. */
    uint32_t unique = 0;
    auto rebind = [&](const spirv_cross::Resource &r) {
        msl.set_decoration(r.id, spv::DecorationDescriptorSet, 0);
        msl.set_decoration(r.id, spv::DecorationBinding, unique);
        return unique++;
    };

    for (const auto &ub : res.uniform_buffers) {
        std::string name = msl.get_name(ub.base_type_id);
        if (name.empty()) name = ub.name;
        auto it = b.blocks.find(name);
        if (it == b.blocks.end()) {
            const auto &type = msl.get_type(ub.base_type_id);
            uint32_t idx = (uint32_t)b.blocks.size();
            if (idx >= TI_VERTEX_BUFFER_INDEX) {
                err = "too many uniform blocks for Metal's buffer table";
                return false;
            }
            /* get_declared_struct_size() stops at the last member; std140
             * rounds a block's size up to its 16-byte base alignment, and
             * Minecraft sizes its buffers the same way. */
            uint32_t declared = (uint32_t)msl.get_declared_struct_size(type);
            uint32_t std140 = (declared + 15u) & ~15u;
            it = b.blocks.emplace(name, Slot{ idx, 0, std140, "" }).first;
            b.block_order.push_back(name);
        }
        it->second.stages |= stage_bit;

        spirv_cross::MSLResourceBinding mb;
        mb.stage = model;
        mb.desc_set = 0;
        mb.binding = rebind(ub);
        mb.msl_buffer = it->second.index;
        msl.add_msl_resource_binding(mb);
    }

    for (const auto &si : res.sampled_images) {
        auto it = b.samplers.find(si.name);
        if (it == b.samplers.end()) {
            uint32_t idx = (uint32_t)b.samplers.size();
            if (idx >= TI_MAX_SAMPLERS) {
                err = "more than 16 samplers; Metal allows 16 per stage";
                return false;
            }
            it = b.samplers.emplace(si.name, Slot{ idx, 0, 0,
                    dim_name(msl.get_type(si.type_id)) }).first;
            b.sampler_order.push_back(si.name);
        }
        it->second.stages |= stage_bit;

        spirv_cross::MSLResourceBinding mb;
        mb.stage = model;
        mb.desc_set = 0;
        mb.binding = rebind(si);
        mb.msl_texture = it->second.index;
        mb.msl_sampler = it->second.index;
        msl.add_msl_resource_binding(mb);
    }

    if (!res.separate_images.empty() || !res.separate_samplers.empty() ||
        !res.storage_buffers.empty() || !res.storage_images.empty()) {
        err = "shader uses resource kinds Minecraft's GLSL 330 does not "
              "(separate images/samplers or storage resources)";
        return false;
    }

    if (model == spv::ExecutionModelVertex) {
        for (const auto &in : res.stage_inputs) {
            uint32_t loc = msl.get_decoration(in.id, spv::DecorationLocation);
            b.vertex_inputs.emplace_back(in.name, loc);
        }
        for (const auto &o : res.stage_outputs)
            b.vertex_outputs[o.name] = msl.get_decoration(o.id, spv::DecorationLocation);
        b.have_vertex_outputs = true;
    }

    /* OpenGL links varyings BY NAME. glslang's mapIO() with the OpenGL client
     * assigns locations per stage in declaration order, so a vertex shader
     * declaring (a, b) and a fragment shader declaring (b, a) would silently
     * swap them. Re-point each fragment input at the vertex output of the
     * same name. (Covered by the varying-order golden test.) */
    if (model == spv::ExecutionModelFragment && b.have_vertex_outputs) {
        for (const auto &in : res.stage_inputs) {
            auto it = b.vertex_outputs.find(in.name);
            if (it == b.vertex_outputs.end()) {
                err = "fragment input '" + in.name + "' has no matching vertex output";
                return false;
            }
            msl.set_decoration(in.id, spv::DecorationLocation, it->second);
        }
    }

    rename_msl_reserved(msl);
    msl_out = msl.compile();
    return true;
}

} // namespace

extern "C" {

TiResult ti_translate_glsl(const char *vs_glsl, const char *fs_glsl,
                           const char *debug_name, TiTranslation **out) {
    if (!out) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    if (!vs_glsl && !fs_glsl)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "translate: no stages supplied");
    const char *name = debug_name ? debug_name : "<shader>";

    try {
        ensure_glslang();
        const EShMessages msgs = (EShMessages)(EShMsgSpvRules);

        std::string vs_src = vs_glsl ? wrap_vertex_main(vs_glsl) : std::string();
        std::string fs_src = fs_glsl ? std::string(fs_glsl) : std::string();

        std::unique_ptr<glslang::TShader> vs, fs;
        auto make = [&](EShLanguage lang, const std::string &src,
                        std::unique_ptr<glslang::TShader> &sh) -> bool {
            sh.reset(new glslang::TShader(lang));
            const char *strs[]  = { src.c_str() };
            const char *names[] = { name };
            sh->setStringsWithLengthsAndNames(strs, nullptr, names, 1);
            /* OpenGL client semantics, not Vulkan: Minecraft uses gl_VertexID,
             * which Vulkan GLSL rejects outright. */
            sh->setEnvInput(glslang::EShSourceGlsl, lang, glslang::EShClientOpenGL, 100);
            sh->setEnvClient(glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
            sh->setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
            sh->setAutoMapLocations(true);
            sh->setAutoMapBindings(true);
            if (!sh->parse(GetDefaultResources(), 330, false, msgs)) {
                ti_fail(TI_ERR_SHADER_COMPILE, "%s (%s): GLSL parse failed:\n%s",
                        name, lang == EShLangVertex ? "vertex" : "fragment",
                        sh->getInfoLog());
                return false;
            }
            return true;
        };

        if (vs_glsl && !make(EShLangVertex, vs_src, vs))   return TI_ERR_SHADER_COMPILE;
        if (fs_glsl && !make(EShLangFragment, fs_src, fs)) return TI_ERR_SHADER_COMPILE;

        glslang::TProgram prog;
        if (vs) prog.addShader(vs.get());
        if (fs) prog.addShader(fs.get());
        if (!prog.link(msgs))
            return ti_fail(TI_ERR_SHADER_COMPILE, "%s: link failed:\n%s", name, prog.getInfoLog());
        /* Cross-stage I/O mapping: gives a vertex output and the fragment input
         * of the same name the same location. */
        if (!prog.mapIO())
            return ti_fail(TI_ERR_SHADER_COMPILE, "%s: I/O mapping failed:\n%s", name, prog.getInfoLog());

        std::unique_ptr<TiTranslation> t(new TiTranslation());
        t->magic = kTranslationMagic;
        Bindings b;

        glslang::SpvOptions spv_opts;
        spv_opts.generateDebugInfo = false;
        spv_opts.disableOptimizer = true;   /* built without SPIRV-Tools */
        spv_opts.validate = false;

        struct { EShLanguage lang; spv::ExecutionModel model; const char *entry; int slot; } stages[] = {
            { EShLangVertex,   spv::ExecutionModelVertex,   "ti_vs_main", TI_STAGE_VERTEX },
            { EShLangFragment, spv::ExecutionModelFragment, "ti_fs_main", TI_STAGE_FRAGMENT },
        };
        for (auto &st : stages) {
            glslang::TIntermediate *im = prog.getIntermediate(st.lang);
            if (!im) continue;
            std::vector<uint32_t> spirv;
            glslang::GlslangToSpv(*im, spirv, &spv_opts);
            std::string err;
            if (!translate_stage(spirv, st.model, st.entry, b, t->msl[st.slot], err))
                return ti_fail(TI_ERR_SHADER_COMPILE, "%s: %s", name, err.c_str());
            t->entry[st.slot] = st.entry;
            t->present[st.slot] = true;
        }

        std::ostringstream r;
        auto stages_str = [](uint32_t m) {
            return std::string((m & 1u) ? "v" : "") + ((m & 2u) ? "f" : "");
        };
        for (auto &vi : b.vertex_inputs)
            r << "vertex_input " << vi.first << ' ' << vi.second << '\n';
        for (auto &n : b.block_order) {
            const Slot &s = b.blocks[n];
            r << "uniform_block " << n << ' ' << s.index << ' ' << s.size << ' '
              << stages_str(s.stages) << '\n';
        }
        for (auto &n : b.sampler_order) {
            const Slot &s = b.samplers[n];
            r << "sampler " << n << ' ' << s.index << ' ' << s.index << ' ' << s.dim << ' '
              << stages_str(s.stages) << '\n';
        }
        t->reflection = r.str();

        *out = t.release();
        return TI_OK;
    } catch (const std::exception &e) {
        return ti_fail(TI_ERR_SHADER_COMPILE, "%s: translation threw: %s", name, e.what());
    } catch (...) {
        return ti_fail(TI_ERR_SHADER_COMPILE, "%s: translation threw an unknown exception", name);
    }
}

static bool ti_translation_ok(TiTranslation *t) {
    if (!t || t->magic != kTranslationMagic) {
        ti_set_error("invalid TiTranslation handle");
        return false;
    }
    return true;
}

const char *ti_translation_msl(TiTranslation *t, TiShaderStage s) {
    if (!ti_translation_ok(t) || (s != TI_STAGE_VERTEX && s != TI_STAGE_FRAGMENT)) return nullptr;
    return t->present[s] ? t->msl[s].c_str() : nullptr;
}

const char *ti_translation_entry_point(TiTranslation *t, TiShaderStage s) {
    if (!ti_translation_ok(t) || (s != TI_STAGE_VERTEX && s != TI_STAGE_FRAGMENT)) return nullptr;
    return t->present[s] ? t->entry[s].c_str() : nullptr;
}

const char *ti_translation_reflection(TiTranslation *t) {
    if (!ti_translation_ok(t)) return nullptr;
    return t->reflection.c_str();
}

void ti_translation_release(TiTranslation *t) {
    if (!ti_translation_ok(t)) return;
    t->magic = 0;
    delete t;
}

} /* extern "C" */
