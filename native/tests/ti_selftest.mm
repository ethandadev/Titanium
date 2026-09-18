/* Titanium native self-test.
 *
 * These are real correctness checks: every rendering test reads the rendered
 * pixels back off the GPU and asserts exact or tolerance-bounded values.
 * Nothing here reports success without having verified an outcome.
 *
 * Exit code 0 = all tests passed.
 */
#include "titanium/ti_api.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <string>
#include <chrono>
#include <algorithm>

static int g_pass = 0, g_fail = 0;

static void check(bool ok, const char *what) {
    if (ok) { ++g_pass; printf("  ok    %s\n", what); }
    else    { ++g_fail; printf("  FAIL  %s  (last error: %s)\n", what, ti_last_error()); }
}

static void check_rc(TiResult r, const char *what) {
    check(r == TI_OK, what);
    if (r != TI_OK) printf("        rc=%d\n", (int)r);
}

/* ---------------- geometry shared by the render tests ---------------- */

struct Vtx { float x, y, u, v; };

static const Vtx kQuad[4] = {
    { -1.0f,  1.0f, 0.0f, 0.0f },   /* top-left     */
    {  1.0f,  1.0f, 1.0f, 0.0f },   /* top-right    */
    { -1.0f, -1.0f, 0.0f, 1.0f },   /* bottom-left  */
    {  1.0f, -1.0f, 1.0f, 1.0f },   /* bottom-right */
};
static const uint16_t kQuadIdx[6] = { 0, 1, 2, 2, 1, 3 };

struct Push { float z; float _pad[3]; float color[4]; };
static_assert(sizeof(Push) == 32, "Push must match the MSL struct layout");
static_assert(offsetof(Push, color) == 16, "Push.color must sit at offset 16");

static const char *kMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VOut { float4 pos [[position]]; float2 uv; };
/* NOTE: float3 in MSL carries 16-byte alignment, which would push `color`
   to offset 32 while the C++ side puts it at 16. Three scalar floats keep
   both layouts identical. This is exactly the class of mismatch the
   GLSL->MSL layer has to handle systematically for std140 blocks. */
struct Push { float z; float p0; float p1; float p2; float4 color; };

vertex VOut vs_main(VIn in [[stage_in]], constant Push& p [[buffer(1)]]) {
    VOut o;
    o.pos = float4(in.pos, p.z, 1.0);
    o.uv  = in.uv;
    return o;
}

fragment float4 fs_tex(VOut in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}

fragment float4 fs_solid(VOut in [[stage_in]], constant Push& p [[buffer(1)]]) {
    return p.color;
}
)MSL";

/* Build the vertex layout used by every test pipeline. */
static void fill_vertex_layout(TiVertexAttr attrs[2], TiVertexBufferLayout layouts[1]) {
    attrs[0] = { 0, offsetof(Vtx, x), 0, TI_VF_FLOAT2 };
    attrs[1] = { 1, offsetof(Vtx, u), 0, TI_VF_FLOAT2 };
    layouts[0] = { (uint32_t)sizeof(Vtx), TI_STEP_PER_VERTEX, 1 };
}

struct Fixture {
    TiDevice   *dev = nullptr;
    TiLibrary  *lib = nullptr;
    TiBuffer   *vb = nullptr, *ib = nullptr;
};

static bool fixture_init(Fixture &f, const char *cache_dir) {
    TiDeviceDesc dd = {};
    dd.cache_dir = cache_dir;
    dd.max_frames_in_flight = 3;
    dd.debug_labels = true;
    if (ti_device_create(&dd, &f.dev) != TI_OK) return false;
    if (ti_library_from_source(f.dev, kMSL, "selftest", &f.lib) != TI_OK) return false;
    if (ti_buffer_create(f.dev, sizeof kQuad, TI_STORAGE_SHARED, "vb", &f.vb) != TI_OK) return false;
    memcpy(ti_buffer_contents(f.vb), kQuad, sizeof kQuad);
    if (ti_buffer_create(f.dev, sizeof kQuadIdx, TI_STORAGE_SHARED, "ib", &f.ib) != TI_OK) return false;
    memcpy(ti_buffer_contents(f.ib), kQuadIdx, sizeof kQuadIdx);
    return true;
}

static void fixture_free(Fixture &f) {
    if (f.ib)  ti_buffer_release(f.ib);
    if (f.vb)  ti_buffer_release(f.vb);
    if (f.lib) ti_library_release(f.lib);
    if (f.dev) ti_device_release(f.dev);
}

/* ---------------- test 1: capability probe --------------------------- */

static void test_probe(void) {
    printf("\n[1] capability probe\n");
    TiCaps c;
    TiResult r = ti_probe(&c);
    check_rc(r, "ti_probe succeeds");
    if (r != TI_OK) return;

    printf("        device            : %s\n", c.device_name);
    printf("        apple family      : %d  (metal3=%d metal4=%d)\n",
           c.apple_family, c.supports_metal3, c.supports_metal4);
    printf("        unified memory    : %d   apple silicon: %d\n",
           c.has_unified_memory, c.is_apple_silicon);
    printf("        max buffer        : %.2f GiB\n", c.max_buffer_length / 1073741824.0);
    printf("        working set       : %.2f GiB\n", c.recommended_max_working_set / 1073741824.0);
    printf("        max texture 2D    : %u\n", c.max_texture_size_2d);
    printf("        argument buf tier : %u\n", c.argument_buffers_tier);
    printf("        mesh shaders      : %d\n", c.supports_mesh_shaders);
    printf("        raytracing        : %d\n", c.supports_raytracing);
    printf("        prog. blending    : %d\n", c.supports_programmable_blending);
    printf("        memoryless targets: %d\n", c.supports_memoryless_targets);
    printf("        depth24stencil8   : %d  (expected 0 on Apple silicon)\n",
           c.supports_depth24_stencil8);
    printf("        MetalFX spatial   : %d\n", c.supports_metalfx_spatial);
    printf("        MetalFX temporal  : %d\n", c.supports_metalfx_temporal);
    printf("        display           : %u Hz, variable=%d\n",
           c.max_display_refresh_hz, c.display_is_variable_refresh);
    printf("        macOS             : %d.%d.%d\n", c.os_major, c.os_minor, c.os_patch);

    check(c.max_buffer_length > 0, "max_buffer_length is populated");
    check(c.max_texture_size_2d >= 8192, "max_texture_size_2d >= 8192");
    check(c.os_major >= 12, "macOS version detected");
    if (c.is_apple_silicon) {
        check(!c.supports_depth24_stencil8,
              "Apple silicon correctly reports no Depth24Unorm_Stencil8");
        check(c.supports_memoryless_targets, "Apple silicon exposes memoryless attachments");
        check(c.supports_programmable_blending, "Apple silicon exposes programmable blending");
    }
}

/* ---------------- test 2: textured draw, verified per-pixel ---------- */

static void test_textured_quad(Fixture &f) {
    printf("\n[2] textured quad -> readback (nearest sampling, 2x2 texture)\n");
    const uint32_t N = 256;

    TiTextureDesc td = {};
    td.width = N; td.height = N; td.format = TI_PF_RGBA8_UNORM;
    td.storage = TI_STORAGE_PRIVATE; td.render_target = true; td.shader_read = true;
    td.label = "color";
    TiTexture *color = nullptr;
    check_rc(ti_texture_create(f.dev, &td, &color), "create colour target");
    if (!color) return;

    /* 2x2 source texture: red, green / blue, yellow */
    TiTextureDesc st = {};
    st.width = 2; st.height = 2; st.format = TI_PF_RGBA8_UNORM;
    st.storage = TI_STORAGE_SHARED; st.shader_read = true; st.label = "src";
    TiTexture *src = nullptr;
    check_rc(ti_texture_create(f.dev, &st, &src), "create source texture");
    const uint8_t texels[16] = {
        255,0,0,255,    0,255,0,255,      /* row 0: red,  green  */
        0,0,255,255,    255,255,0,255,    /* row 1: blue, yellow */
    };
    check_rc(ti_texture_upload(src, 0, 0, 0, 0, 2, 2, texels, 8), "upload source texels");

    TiSamplerDesc sd = {};
    sd.min_filter = TI_FILTER_NEAREST; sd.mag_filter = TI_FILTER_NEAREST;
    sd.mip_filter = TI_MIP_NONE;
    sd.address_u = sd.address_v = sd.address_w = TI_ADDR_CLAMP_TO_EDGE;
    sd.max_anisotropy = 1; sd.label = "nearest";
    TiSampler *smp = nullptr;
    check_rc(ti_sampler_create(f.dev, &sd, &smp), "create nearest sampler");

    TiVertexAttr attrs[2]; TiVertexBufferLayout layouts[1];
    fill_vertex_layout(attrs, layouts);

    TiPipelineDesc pd = {};
    pd.library = f.lib; pd.vertex_fn = "vs_main"; pd.fragment_fn = "fs_tex";
    pd.attrs = attrs; pd.attr_count = 2;
    pd.layouts = layouts; pd.layout_count = 1;
    pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    pd.color_count = 1; pd.sample_count = 1; pd.label = "tex";
    TiPipeline *pipe = nullptr;
    check_rc(ti_pipeline_create(f.dev, &pd, &pipe), "create textured pipeline");
    if (!pipe) return;

    TiFrame *frame = nullptr;
    check_rc(ti_frame_begin(f.dev, nullptr, &frame), "begin offscreen frame");
    if (!frame) return;

    TiRenderPassDesc rp = {};
    rp.color_count = 1;
    rp.color[0].texture = color;
    rp.color[0].load = TI_LOAD_CLEAR;
    rp.color[0].store = TI_STORE_STORE;
    rp.color[0].clear_r = 0; rp.color[0].clear_g = 0; rp.color[0].clear_b = 0; rp.color[0].clear_a = 1;
    rp.label = "tex-pass";

    TiPass *pass = nullptr;
    check_rc(ti_pass_begin(frame, &rp, &pass), "begin render pass");
    if (!pass) { ti_frame_end(frame, false); return; }

    Push push = {}; push.z = 0.5f;
    check_rc(ti_pass_set_pipeline(pass, pipe), "bind pipeline");
    check_rc(ti_pass_set_viewport(pass, 0, 0, N, N, 0, 1), "set viewport");
    check_rc(ti_pass_set_vertex_buffer(pass, 0, f.vb, 0), "bind vertex buffer");
    check_rc(ti_pass_set_vertex_bytes(pass, 1, &push, sizeof push), "set push constants");
    check_rc(ti_pass_set_fragment_texture(pass, 0, src), "bind texture");
    check_rc(ti_pass_set_fragment_sampler(pass, 0, smp), "bind sampler");
    check_rc(ti_pass_draw_indexed(pass, TI_PRIM_TRIANGLES, 6, TI_INDEX_U16, f.ib, 0, 1, 0),
             "draw indexed");
    check_rc(ti_pass_end(pass), "end pass");
    check_rc(ti_frame_end_and_wait(frame, false), "submit and wait");

    std::vector<uint8_t> px(N * N * 4);
    check_rc(ti_texture_readback(color, 0, 0, 0, N, N, px.data(), N * 4), "read pixels back");

    auto at = [&](uint32_t x, uint32_t y) { return &px[(y * N + x) * 4]; };
    auto is_rgb = [&](const uint8_t *p, int r, int g, int b) {
        return p[0] == r && p[1] == g && p[2] == b;
    };

    /* Quadrant centres must match the corresponding texel exactly. */
    check(is_rgb(at(64,  64),  255, 0,   0),   "top-left quadrant is red");
    check(is_rgb(at(192, 64),  0,   255, 0),   "top-right quadrant is green");
    check(is_rgb(at(64,  192), 0,   0,   255), "bottom-left quadrant is blue");
    check(is_rgb(at(192, 192), 255, 255, 0),   "bottom-right quadrant is yellow");

    ti_pipeline_release(pipe);
    ti_sampler_release(smp);
    ti_texture_release(src);
    ti_texture_release(color);
}

/* ---------------- test 3: depth testing with a memoryless depth buffer */

static void test_depth_memoryless(Fixture &f) {
    printf("\n[3] depth test using a MEMORYLESS depth attachment (TBDR path)\n");
    const uint32_t N = 64;

    TiCaps caps; ti_device_caps(f.dev, &caps);

    TiTextureDesc td = {};
    td.width = N; td.height = N; td.format = TI_PF_RGBA8_UNORM;
    td.storage = TI_STORAGE_PRIVATE; td.render_target = true; td.shader_read = true;
    TiTexture *color = nullptr;
    check_rc(ti_texture_create(f.dev, &td, &color), "create colour target");

    TiTextureDesc dd = {};
    dd.width = N; dd.height = N; dd.format = TI_PF_DEPTH32_FLOAT;
    dd.storage = caps.supports_memoryless_targets ? TI_STORAGE_MEMORYLESS : TI_STORAGE_PRIVATE;
    dd.render_target = true;
    dd.label = "depth";
    TiTexture *depth = nullptr;
    check_rc(ti_texture_create(f.dev, &dd, &depth),
             caps.supports_memoryless_targets ? "create memoryless depth target"
                                              : "create private depth target");
    if (!color || !depth) return;

    TiVertexAttr attrs[2]; TiVertexBufferLayout layouts[1];
    fill_vertex_layout(attrs, layouts);

    TiPipelineDesc pd = {};
    pd.library = f.lib; pd.vertex_fn = "vs_main"; pd.fragment_fn = "fs_solid";
    pd.attrs = attrs; pd.attr_count = 2;
    pd.layouts = layouts; pd.layout_count = 1;
    pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    pd.color_count = 1; pd.depth_format = TI_PF_DEPTH32_FLOAT;
    pd.sample_count = 1; pd.label = "solid-depth";
    TiPipeline *pipe = nullptr;
    check_rc(ti_pipeline_create(f.dev, &pd, &pipe), "create depth-aware pipeline");

    TiDepthStencilDesc dsd = {};
    dsd.depth_compare = TI_CMP_LESS; dsd.depth_write = true; dsd.label = "less";
    TiDepthStencil *ds = nullptr;
    check_rc(ti_depth_stencil_create(f.dev, &dsd, &ds), "create depth state (LESS, write)");
    if (!pipe || !ds) return;

    TiFrame *frame = nullptr;
    check_rc(ti_frame_begin(f.dev, nullptr, &frame), "begin frame");
    if (!frame) return;

    TiRenderPassDesc rp = {};
    rp.color_count = 1;
    rp.color[0].texture = color; rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
    rp.color[0].clear_a = 1;
    rp.has_depth = true;
    rp.depth.texture = depth; rp.depth.load = TI_LOAD_CLEAR;
    rp.depth.store = TI_STORE_DONT_CARE;     /* nothing needs depth afterwards */
    rp.depth.clear_depth = 1.0;
    rp.label = "depth-pass";

    TiPass *pass = nullptr;
    check_rc(ti_pass_begin(frame, &rp, &pass), "begin pass with depth");
    if (!pass) { ti_frame_end(frame, false); return; }

    ti_pass_set_pipeline(pass, pipe);
    ti_pass_set_depth_stencil(pass, ds);
    ti_pass_set_viewport(pass, 0, 0, N, N, 0, 1);
    ti_pass_set_vertex_buffer(pass, 0, f.vb, 0);

    struct { float z; float r, g, b; } draws[3] = {
        { 0.5f, 1, 0, 0 },   /* red   at z=0.5 -> passes (depth starts at 1) */
        { 0.8f, 0, 1, 0 },   /* green at z=0.8 -> rejected, 0.8 !< 0.5       */
        { 0.2f, 0, 0, 1 },   /* blue  at z=0.2 -> passes                     */
    };
    for (auto &d : draws) {
        Push p = {}; p.z = d.z;
        p.color[0] = d.r; p.color[1] = d.g; p.color[2] = d.b; p.color[3] = 1.0f;
        ti_pass_set_vertex_bytes(pass, 1, &p, sizeof p);
        ti_pass_set_fragment_bytes(pass, 1, &p, sizeof p);
        ti_pass_draw_indexed(pass, TI_PRIM_TRIANGLES, 6, TI_INDEX_U16, f.ib, 0, 1, 0);
    }

    check_rc(ti_pass_end(pass), "end pass");
    check_rc(ti_frame_end_and_wait(frame, false), "submit and wait");

    std::vector<uint8_t> px(N * N * 4);
    check_rc(ti_texture_readback(color, 0, 0, 0, N, N, px.data(), N * 4), "read pixels back");
    const uint8_t *c = &px[(32 * N + 32) * 4];
    printf("        centre pixel = (%u,%u,%u,%u)\n", c[0], c[1], c[2], c[3]);
    check(c[0] == 0 && c[1] == 0 && c[2] == 255,
          "nearest draw wins; occluded draw correctly rejected");

    ti_depth_stencil_release(ds);
    ti_pipeline_release(pipe);
    ti_texture_release(depth);
    ti_texture_release(color);
}

/* ---------------- test 4: alpha blending ----------------------------- */

static void test_blending(Fixture &f) {
    printf("\n[4] alpha blending (SRC_ALPHA / ONE_MINUS_SRC_ALPHA)\n");
    const uint32_t N = 32;

    TiTextureDesc td = {};
    td.width = N; td.height = N; td.format = TI_PF_RGBA8_UNORM;
    td.storage = TI_STORAGE_PRIVATE; td.render_target = true; td.shader_read = true;
    TiTexture *color = nullptr;
    check_rc(ti_texture_create(f.dev, &td, &color), "create colour target");
    if (!color) return;

    TiVertexAttr attrs[2]; TiVertexBufferLayout layouts[1];
    fill_vertex_layout(attrs, layouts);

    TiPipelineDesc pd = {};
    pd.library = f.lib; pd.vertex_fn = "vs_main"; pd.fragment_fn = "fs_solid";
    pd.attrs = attrs; pd.attr_count = 2;
    pd.layouts = layouts; pd.layout_count = 1;
    pd.color_count = 1;
    pd.color[0].format = TI_PF_RGBA8_UNORM;
    pd.color[0].write_mask = 0xF;
    pd.color[0].blend_enabled = true;
    pd.color[0].src_rgb = TI_BF_SRC_ALPHA;
    pd.color[0].dst_rgb = TI_BF_ONE_MINUS_SRC_ALPHA;
    pd.color[0].src_alpha = TI_BF_ONE;
    pd.color[0].dst_alpha = TI_BF_ONE_MINUS_SRC_ALPHA;
    pd.color[0].op_rgb = pd.color[0].op_alpha = TI_BO_ADD;
    pd.sample_count = 1; pd.label = "blend";
    TiPipeline *pipe = nullptr;
    check_rc(ti_pipeline_create(f.dev, &pd, &pipe), "create blending pipeline");
    if (!pipe) return;

    TiFrame *frame = nullptr;
    check_rc(ti_frame_begin(f.dev, nullptr, &frame), "begin frame");
    if (!frame) return;

    TiRenderPassDesc rp = {};
    rp.color_count = 1;
    rp.color[0].texture = color;
    rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
    rp.color[0].clear_r = 0; rp.color[0].clear_g = 0; rp.color[0].clear_b = 0; rp.color[0].clear_a = 1;

    TiPass *pass = nullptr;
    check_rc(ti_pass_begin(frame, &rp, &pass), "begin pass");
    if (!pass) { ti_frame_end(frame, false); return; }

    Push p = {}; p.z = 0.5f;
    p.color[0] = 1.0f; p.color[1] = 0.0f; p.color[2] = 0.0f; p.color[3] = 0.5f;
    ti_pass_set_pipeline(pass, pipe);
    ti_pass_set_viewport(pass, 0, 0, N, N, 0, 1);
    ti_pass_set_vertex_buffer(pass, 0, f.vb, 0);
    ti_pass_set_vertex_bytes(pass, 1, &p, sizeof p);
    ti_pass_set_fragment_bytes(pass, 1, &p, sizeof p);
    ti_pass_draw_indexed(pass, TI_PRIM_TRIANGLES, 6, TI_INDEX_U16, f.ib, 0, 1, 0);
    check_rc(ti_pass_end(pass), "end pass");
    check_rc(ti_frame_end_and_wait(frame, false), "submit and wait");

    std::vector<uint8_t> px(N * N * 4);
    check_rc(ti_texture_readback(color, 0, 0, 0, N, N, px.data(), N * 4), "read pixels back");
    const uint8_t *c = &px[(16 * N + 16) * 4];
    printf("        centre pixel = (%u,%u,%u,%u), expected R ~128\n", c[0], c[1], c[2], c[3]);
    check(std::abs((int)c[0] - 128) <= 1 && c[1] == 0 && c[2] == 0,
          "50%% red over black blends to ~128");

    ti_pipeline_release(pipe);
    ti_texture_release(color);
}

/* ---------------- test 5: handle validation & error paths ------------ */

static void test_error_handling(Fixture &f) {
    printf("\n[5] handle validation and error reporting\n");

    TiBuffer *bogus = (TiBuffer *)"not a real handle at all";
    check(ti_buffer_size(bogus) == 0, "stale handle rejected by ti_buffer_size");
    check(ti_buffer_contents(bogus) == nullptr, "stale handle rejected by ti_buffer_contents");

    TiBuffer *b = nullptr;
    check(ti_buffer_create(f.dev, 0, TI_STORAGE_SHARED, "zero", &b) == TI_ERR_INVALID_ARGUMENT,
          "zero-length buffer refused");

    check(ti_buffer_create(f.dev, 64, TI_STORAGE_MEMORYLESS, "ml", &b) == TI_ERR_INVALID_ARGUMENT,
          "memoryless buffer refused (textures only)");

    TiTextureDesc td = {};
    td.width = 16; td.height = 16; td.format = TI_PF_RGBA8_UNORM;
    td.storage = TI_STORAGE_MEMORYLESS; td.render_target = true; td.shader_read = true;
    TiTexture *t = nullptr;
    check(ti_texture_create(f.dev, &td, &t) == TI_ERR_INVALID_ARGUMENT,
          "memoryless texture with shader_read refused");

    TiLibrary *bad = nullptr;
    check(ti_library_from_source(f.dev, "this is not valid MSL", "bad", &bad)
              == TI_ERR_SHADER_COMPILE,
          "invalid MSL reports a compile error rather than crashing");
    check(strlen(ti_last_error()) > 0, "compile failure populates ti_last_error()");

    TiPipelineDesc pd = {};
    pd.library = f.lib; pd.vertex_fn = "no_such_function";
    pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    TiPipeline *p = nullptr;
    check(ti_pipeline_create(f.dev, &pd, &p) == TI_ERR_PIPELINE_CREATE,
          "missing shader entry point reports PIPELINE_CREATE");

    check(ti_library_has_function(f.lib, "vs_main"), "ti_library_has_function finds vs_main");
    check(!ti_library_has_function(f.lib, "nope"), "ti_library_has_function rejects unknown name");
}

/* ---------------- test 6: unified-memory no-copy buffers -------------- */

static void test_nocopy(Fixture &f) {
    printf("\n[6] unified-memory no-copy buffer aliasing\n");
    TiCaps caps; ti_device_caps(f.dev, &caps);

    const size_t page = 16384;
    void *mem = nullptr;
    if (posix_memalign(&mem, page, page) != 0 || !mem) {
        check(false, "posix_memalign for page-aligned block");
        return;
    }
    memset(mem, 0xAB, page);

    TiBuffer *b = nullptr;
    TiResult r = ti_buffer_create_no_copy(f.dev, mem, page, "nocopy", &b);
    if (caps.has_unified_memory) {
        check_rc(r, "no-copy buffer created on unified memory");
        if (r == TI_OK) {
            check(ti_buffer_contents(b) == mem,
                  "GPU buffer aliases the original allocation (zero copies)");
            check(ti_buffer_size(b) == page, "no-copy buffer reports the right size");
            ti_buffer_release(b);
        }
    } else {
        check(r == TI_ERR_UNSUPPORTED, "no-copy correctly refused without unified memory");
    }

    /* Misaligned pointers must be refused rather than silently corrected. */
    TiBuffer *b2 = nullptr;
    check(ti_buffer_create_no_copy(f.dev, (uint8_t *)mem + 1, page, "bad", &b2)
              == TI_ERR_UNSUPPORTED,
          "misaligned no-copy pointer refused");
    free(mem);
}

/* ---------------- test 7: frames-in-flight throughput ---------------- */

static void test_frames_in_flight(Fixture &f) {
    printf("\n[7] frames-in-flight pacing and GPU timing\n");
    const uint32_t N = 512;
    const int FRAMES = 240;

    TiTextureDesc td = {};
    td.width = N; td.height = N; td.format = TI_PF_RGBA8_UNORM;
    td.storage = TI_STORAGE_PRIVATE; td.render_target = true; td.shader_read = true;
    TiTexture *color = nullptr;
    if (ti_texture_create(f.dev, &td, &color) != TI_OK) { check(false, "create target"); return; }

    TiVertexAttr attrs[2]; TiVertexBufferLayout layouts[1];
    fill_vertex_layout(attrs, layouts);
    TiPipelineDesc pd = {};
    pd.library = f.lib; pd.vertex_fn = "vs_main"; pd.fragment_fn = "fs_solid";
    pd.attrs = attrs; pd.attr_count = 2;
    pd.layouts = layouts; pd.layout_count = 1;
    pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    pd.sample_count = 1; pd.label = "bench";
    TiPipeline *pipe = nullptr;
    if (ti_pipeline_create(f.dev, &pd, &pipe) != TI_OK) { check(false, "create pipeline"); return; }

    std::vector<double> cpu_ms; cpu_ms.reserve(FRAMES);
    int failures = 0;

    for (int i = 0; i < FRAMES; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        TiFrame *frame = nullptr;
        if (ti_frame_begin(f.dev, nullptr, &frame) != TI_OK) { ++failures; continue; }

        TiRenderPassDesc rp = {};
        rp.color_count = 1;
        rp.color[0].texture = color;
        rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
        rp.color[0].clear_a = 1;
        TiPass *pass = nullptr;
        if (ti_pass_begin(frame, &rp, &pass) != TI_OK) { ++failures; ti_frame_end(frame, false); continue; }

        Push p = {}; p.z = 0.5f; p.color[0] = 0.25f; p.color[3] = 1.0f;
        ti_pass_set_pipeline(pass, pipe);
        ti_pass_set_viewport(pass, 0, 0, N, N, 0, 1);
        ti_pass_set_vertex_buffer(pass, 0, f.vb, 0);
        ti_pass_set_vertex_bytes(pass, 1, &p, sizeof p);
        ti_pass_set_fragment_bytes(pass, 1, &p, sizeof p);
        /* 200 draws per frame to give the encoder something to chew on. */
        for (int d = 0; d < 200; ++d)
            ti_pass_draw_indexed(pass, TI_PRIM_TRIANGLES, 6, TI_INDEX_U16, f.ib, 0, 1, 0);
        ti_pass_end(pass);
        ti_frame_end(frame, false);

        auto t1 = std::chrono::steady_clock::now();
        cpu_ms.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
    }
    ti_device_wait_idle(f.dev);

    check(failures == 0, "all frames submitted without error");
    if (!cpu_ms.empty()) {
        std::vector<double> s = cpu_ms;
        std::sort(s.begin(), s.end());
        double sum = 0; for (double v : cpu_ms) sum += v;
        printf("        %d frames x 200 draws, CPU submit time:\n", FRAMES);
        printf("          mean %.3f ms   p50 %.3f ms   p99 %.3f ms   max %.3f ms\n",
               sum / cpu_ms.size(), s[s.size()/2], s[(size_t)(s.size()*0.99)], s.back());
        printf("        last frame GPU time: %.3f ms\n", ti_device_last_gpu_ms(f.dev));
        check(ti_device_last_gpu_ms(f.dev) > 0.0, "GPU timestamps reported by the driver");
    }

    ti_pipeline_release(pipe);
    ti_texture_release(color);
}

/* ---------------- test 8: pipeline cache persistence ----------------- */

static void test_pipeline_cache(const char *cache_dir) {
    printf("\n[8] on-disk pipeline cache\n");
    std::string archive = std::string(cache_dir) + "/pipelines.metalar";
    remove(archive.c_str());

    Fixture f;
    if (!fixture_init(f, cache_dir)) { check(false, "fixture for cache test"); return; }

    TiVertexAttr attrs[2]; TiVertexBufferLayout layouts[1];
    fill_vertex_layout(attrs, layouts);
    TiPipelineDesc pd = {};
    pd.library = f.lib; pd.vertex_fn = "vs_main"; pd.fragment_fn = "fs_solid";
    pd.attrs = attrs; pd.attr_count = 2;
    pd.layouts = layouts; pd.layout_count = 1;
    pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    pd.sample_count = 1; pd.label = "cached";
    TiPipeline *p = nullptr;
    check_rc(ti_pipeline_create(f.dev, &pd, &p), "create pipeline (cold)");
    if (p) ti_pipeline_release(p);

    check_rc(ti_device_flush_pipeline_cache(f.dev), "flush pipeline cache");
    fixture_free(f);

    FILE *fp = fopen(archive.c_str(), "rb");
    long sz = 0;
    if (fp) { fseek(fp, 0, SEEK_END); sz = ftell(fp); fclose(fp); }
    printf("        archive size: %ld bytes\n", sz);
    check(sz > 0, "pipeline archive written to disk");

    /* Reopening must accept the archive we just wrote. */
    Fixture f2;
    check(fixture_init(f2, cache_dir), "device reopens the existing pipeline cache");
    fixture_free(f2);
}

/* ---------------- main ----------------------------------------------- */

int main(int argc, char **argv) {
    printf("=== Titanium native self-test (%s) ===\n", ti_version_string());
    ti_set_log_level(TI_LOG_INFO);

    char cache_dir[512];
    snprintf(cache_dir, sizeof cache_dir, "%s/titanium-selftest-cache",
             getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");

    test_probe();

    Fixture f;
    if (!fixture_init(f, cache_dir)) {
        printf("\nFATAL: could not initialise device fixture: %s\n", ti_last_error());
        return 1;
    }
    test_textured_quad(f);
    test_depth_memoryless(f);
    test_blending(f);
    test_error_handling(f);
    test_nocopy(f);
    test_frames_in_flight(f);
    fixture_free(f);

    test_pipeline_cache(cache_dir);

    printf("\n=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
