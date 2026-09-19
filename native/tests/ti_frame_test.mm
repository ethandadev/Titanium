/* Tests for the operations the Minecraft backend depends on: submission
 * ordering, serials/fences, rect clears, the flipped present, views, cube
 * maps, texel buffers, sampler LOD clamps, and integer/normalised vertex
 * formats. Every check reads GPU results back. */
#include "titanium/ti_api.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <ctime>

static int g_pass = 0, g_fail = 0;
static void check(bool ok, const char *what) {
    if (ok) { ++g_pass; printf("  ok    %s\n", what); }
    else    { ++g_fail; printf("  FAIL  %s  (%s)\n", what, ti_last_error()); }
}
static TiDevice *D;
static TiDevice *D_dev() { return D; }

static TiTexture *rt(uint32_t w, uint32_t h, TiPixelFormat f = TI_PF_RGBA8_UNORM) {
    TiTextureDesc d = {}; d.width = w; d.height = h; d.format = f;
    d.storage = TI_STORAGE_PRIVATE; d.render_target = true; d.shader_read = true;
    TiTexture *t = nullptr; ti_texture_create(D, &d, &t); return t;
}
static std::vector<uint8_t> px(TiTexture *t, uint32_t w, uint32_t h) {
    std::vector<uint8_t> v(w * h * 4); ti_texture_readback(t, 0, 0, 0, w, h, v.data(), w * 4); return v;
}
static const uint8_t *at(const std::vector<uint8_t> &v, uint32_t w, uint32_t x, uint32_t row) {
    return &v[(row * w + x) * 4];
}
static TiResult clear_pass(TiFrame *f, TiTexture *t, float r, float g, float b, bool load) {
    TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = t;
    rp.color[0].load = load ? TI_LOAD_LOAD : TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
    rp.color[0].clear_r = r; rp.color[0].clear_g = g; rp.color[0].clear_b = b; rp.color[0].clear_a = 1;
    TiPass *p = nullptr; TiResult res = ti_pass_begin(f, &rp, &p);
    if (res == TI_OK) ti_pass_end(p);
    return res;
}

static void test_ordering() {
    printf("\n[1] frame-ordered upload lands between the passes around it (GL command order)\n");
    const uint32_t N = 8;
    TiTexture *t = rt(N, N);
    std::vector<uint8_t> green(4 * 4 * 4);
    for (size_t i = 0; i < green.size(); i += 4) { green[i+1] = 255; green[i+3] = 255; }
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
    clear_pass(f, t, 1, 0, 0, false);                                   /* pass A: red   */
    check(ti_frame_upload_texture(f, t, 0, 0, 0, 0, 4, 4, green.data(), 16) == TI_OK,
          "upload encoded into the open frame");
    green.assign(green.size(), 0);                                      /* caller reuses its memory */
    TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = t;
    rp.color[0].load = TI_LOAD_LOAD; rp.color[0].store = TI_STORE_STORE;
    TiPass *p = nullptr; ti_pass_begin(f, &rp, &p);
    check(ti_frame_upload_texture(f, t, 0, 0, 0, 0, 1, 1, green.data(), 4) == TI_ERR_INVALID_ARGUMENT,
          "transfer refused while a render pass is open");
    ti_pass_end(p);
    ti_frame_end_and_wait(f, false);
    auto v = px(t, N, N);
    check(at(v, N, 1, 1)[1] == 255 && at(v, N, 1, 1)[0] == 0,
          "uploaded region is green: the upload ran after pass A cleared to red");
    check(at(v, N, 6, 6)[0] == 255, "untouched region keeps pass A's red");
    check(true, "caller memory was reusable immediately (it was zeroed before the GPU ran)");
    ti_texture_release(t);
}

static void test_serials() {
    printf("\n[2] submission serials: the basis of GpuFence\n");
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
    uint64_t s = ti_frame_serial(f);
    check(s > 0, "frame has a serial");
    check(ti_device_wait_serial(D, s, 1000000) == TI_ERR_INVALID_ARGUMENT,
          "waiting on an uncommitted frame is refused instead of deadlocking");
    ti_frame_end(f, false);
    check(ti_device_wait_serial(D, s, UINT64_MAX) == TI_OK, "wait returns once the GPU finishes");
    check(ti_device_completed_serial(D) >= s, "completed serial advanced");
    TiFrame *g = nullptr; ti_frame_begin(D, nullptr, &g);
    check(ti_frame_serial(g) > s, "serials are monotonic");
    ti_frame_end_and_wait(g, false);
}

static void test_rect_clear() {
    printf("\n[3] rectangle clear in OpenGL window coordinates (y from the bottom)\n");
    const uint32_t N = 16;
    TiTexture *c = rt(N, N), *d = rt(N, N, TI_PF_DEPTH32_FLOAT);
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
    ti_frame_clear(f, c, true, 0, 0, 1, 1, d, true, 1.0, false, 0, 0, 0, 0);
    check(ti_frame_clear(f, c, true, 1, 0, 0, 1, d, true, 0.25, true, 0, 0, N / 2, N / 2) == TI_OK,
          "scissored clear of the bottom-left quarter");
    ti_frame_end_and_wait(f, false);
    auto v = px(c, N, N);
    check(at(v, N, 2, 2)[0] == 255,        "GL bottom-left (memory rows 0..7) is red");
    check(at(v, N, 12, 12)[2] == 255,      "GL top-right stays blue");
    check(at(v, N, 2, 12)[2] == 255,       "GL top-left stays blue");
    std::vector<float> dv(N * N);
    ti_texture_readback(d, 0, 0, 0, N, N, dv.data(), N * 4);
    check(dv[2 * N + 2] == 0.25f && dv[12 * N + 12] == 1.0f, "depth cleared inside the rect only");
    ti_texture_release(c); ti_texture_release(d);
}

static void test_flip_blit() {
    printf("\n[4] present blit turns OpenGL memory layout upright\n");
    const uint32_t N = 16;
    TiTexture *src = rt(N, N), *dst = rt(N, N, TI_PF_BGRA8_UNORM);
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
    ti_frame_clear(f, src, true, 0, 0, 0, 1, nullptr, false, 0, false, 0, 0, 0, 0);
    /* GL's top half = memory rows N/2..N-1 */
    ti_frame_clear(f, src, true, 1, 0, 0, 1, nullptr, false, 0, true, 0, N / 2, N, N / 2);
    check(ti_frame_blit_flipped(f, src, dst, nullptr) == TI_OK, "blit into a BGRA target");
    ti_frame_end_and_wait(f, false);
    auto v = px(dst, N, N);   /* BGRA: red is byte 2 */
    check(at(v, N, 8, 2)[2] == 255,  "GL top appears at the top of the displayed image (row 2)");
    check(at(v, N, 8, 13)[2] == 0,   "GL bottom appears at the bottom");
    ti_texture_release(src); ti_texture_release(dst);
}

static void test_views_cube_texelbuffer() {
    printf("\n[5] texture views, cube maps, texel buffers\n");
    TiTextureDesc d = {}; d.width = 16; d.height = 16; d.mip_levels = 5; d.format = TI_PF_RGBA8_UNORM;
    d.storage = TI_STORAGE_PRIVATE; d.shader_read = true; d.render_target = true;
    TiTexture *t = nullptr; ti_texture_create(D, &d, &t);
    TiTexture *v = nullptr;
    check(ti_texture_create_view(t, 2, 3, &v) == TI_OK, "view of mips [2,5)");
    uint32_t w = 0, h = 0; ti_texture_dimensions(v, &w, &h);
    check(w == 4 && h == 4, "view reports its base mip's size (4x4)");
    TiTexture *clamped = nullptr;
    check(ti_texture_create_view(t, 3, 3, &clamped) == TI_OK, "view running past the chain is clamped (GL leniency)");
    if (clamped) ti_texture_release(clamped);
    TiTexture *bad = nullptr;
    check(ti_texture_create_view(t, 5, 1, &bad) == TI_ERR_INVALID_ARGUMENT, "view whose base level doesn't exist is refused");
    ti_texture_release(v); ti_texture_release(t);

    TiTextureDesc cd = {}; cd.width = 8; cd.height = 8; cd.array_length = 6; cd.cube = true;
    cd.format = TI_PF_RGBA8_UNORM; cd.storage = TI_STORAGE_PRIVATE; cd.shader_read = true;
    TiTexture *cube = nullptr;
    check(ti_texture_create(D, &cd, &cube) == TI_OK, "cube map (panorama) created");
    std::vector<uint8_t> face(8 * 8 * 4, 200);
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
    check(ti_frame_upload_texture(f, cube, 0, 5, 0, 0, 8, 8, face.data(), 32) == TI_OK,
          "upload into cube face 5");
    ti_frame_end_and_wait(f, false);
    if (cube) ti_texture_release(cube);
    cd.width = 8; cd.height = 4;
    TiTexture *badcube = nullptr;
    check(ti_texture_create(D, &cd, &badcube) == TI_ERR_INVALID_ARGUMENT, "non-square cube refused");

    TiBuffer *b = nullptr; ti_buffer_create(D, 4096, TI_STORAGE_SHARED, "tb", &b);
    TiTexture *tb = nullptr;
    check(ti_texture_create_buffer_view(b, TI_PF_R8_SINT, 0, 4096, &tb) == TI_OK,
          "R8_SINT texel buffer over a buffer (clouds use isamplerBuffer)");
    uint32_t tw = 0; ti_texture_dimensions(tb, &tw, nullptr);
    check(tw == 4096, "texel buffer has one element per byte");
    if (tb) ti_texture_release(tb);
    ti_buffer_release(b);
}

static const char *kLodMSL = R"(
#include <metal_stdlib>
using namespace metal;
struct O { float4 p [[position]]; };
vertex O vs(uint v [[vertex_id]]) { float2 q = float2((v<<1)&2, v&2); O o; o.p = float4(q*2-1,0,1); return o; }
fragment float4 fs(O i [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, float2(0.5), level(1.0));
}
)";

static void test_sampler_lod_clamp() {
    printf("\n[6] sampler maxLod 0 pins mip 0 (regression: 0 used to mean unbounded)\n");
    TiTextureDesc d = {}; d.width = 2; d.height = 2; d.mip_levels = 2; d.format = TI_PF_RGBA8_UNORM;
    d.storage = TI_STORAGE_PRIVATE; d.shader_read = true;
    TiTexture *t = nullptr; ti_texture_create(D, &d, &t);
    uint8_t red[16], green[4] = { 0, 255, 0, 255 };
    for (int i = 0; i < 16; i += 4) { red[i] = 255; red[i+1] = 0; red[i+2] = 0; red[i+3] = 255; }
    TiLibrary *lib = nullptr; ti_library_from_source(D, kLodMSL, nullptr, &lib);
    TiPipelineDesc pd = {}; pd.library = lib; pd.vertex_fn = "vs"; pd.fragment_fn = "fs";
    pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    TiPipeline *pipe = nullptr; ti_pipeline_create(D, &pd, &pipe);

    auto run = [&](float lod_max) {
        TiSamplerDesc sd = {}; sd.min_filter = sd.mag_filter = TI_FILTER_NEAREST;
        sd.mip_filter = TI_MIP_LINEAR; sd.lod_max = lod_max;
        TiSampler *s = nullptr; ti_sampler_create(D, &sd, &s);
        TiTexture *out = rt(4, 4);
        TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
        ti_frame_upload_texture(f, t, 0, 0, 0, 0, 2, 2, red, 8);
        ti_frame_upload_texture(f, t, 1, 0, 0, 0, 1, 1, green, 4);
        TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = out;
        rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
        TiPass *p = nullptr; ti_pass_begin(f, &rp, &p);
        ti_pass_set_pipeline(p, pipe);
        ti_pass_set_fragment_texture(p, 0, t); ti_pass_set_fragment_sampler(p, 0, s);
        ti_pass_draw(p, TI_PRIM_TRIANGLES, 0, 3, 1);
        ti_pass_end(p); ti_frame_end_and_wait(f, false);
        auto v = px(out, 4, 4);
        std::vector<uint8_t> c(at(v, 4, 1, 1), at(v, 4, 1, 1) + 4);
        ti_texture_release(out); ti_sampler_release(s);
        return c;
    };
    auto pinned = run(0.0f);
    check(pinned[0] == 255 && pinned[1] == 0, "maxLod 0: level(1) request is clamped to mip 0 (red)");
    auto open = run(-1.0f);
    check(open[1] == 255 && open[0] == 0, "unbounded: level(1) reaches mip 1 (green)");
    ti_pipeline_release(pipe); ti_library_release(lib); ti_texture_release(t);
}

static const char *kVfMSL = R"(
#include <metal_stdlib>
using namespace metal;
struct VI { float3 pos [[attribute(0)]]; int2 uv2 [[attribute(1)]]; float3 nrm [[attribute(2)]]; float4 col [[attribute(3)]]; };
struct VO { float4 p [[position]]; float4 c; };
vertex VO vs(VI i [[stage_in]]) {
    VO o; o.p = float4(i.pos, 1);
    // uv2 arrives as raw integers (240, -16), normal as [-1,1], colour as [0,1]
    o.c = float4(float(i.uv2.x) / 255.0, float(-i.uv2.y) / 255.0, i.nrm.z * 0.5 + 0.5, i.col.a);
    return o;
}
fragment float4 fs(VO i [[stage_in]]) { return i.c; }
)";

static void test_vertex_formats() {
    printf("\n[7] Minecraft vertex element types: integer UV2, normalised byte normal, UBYTE colour\n");
    struct V { float x, y, z; int16_t u, v; int8_t nx, ny, nz, pad; uint8_t r, g, b, a; };
    V q[3];
    const float xy[3][2] = { {-1,-1}, {3,-1}, {-1,3} };
    for (int i = 0; i < 3; ++i) q[i] = V{ xy[i][0], xy[i][1], 0.5f, 240, 16, 0, 0, 127, 0, 0, 0, 0, 204 };
    q[0].v = q[1].v = q[2].v = -16;
    TiBuffer *vb = nullptr; ti_buffer_create(D, sizeof q, TI_STORAGE_SHARED, "vf", &vb);
    memcpy(ti_buffer_contents(vb), q, sizeof q);
    TiLibrary *lib = nullptr;
    check(ti_library_from_source(D, kVfMSL, nullptr, &lib) == TI_OK, "compile");
    TiVertexAttr a[4] = {
        { 0, offsetof(V, x),  0, TI_VF_MAKE(TI_VC_FLOAT, 3, false) },
        { 1, offsetof(V, u),  0, TI_VF_MAKE(TI_VC_SHORT, 2, false) },   /* glVertexAttribIPointer */
        { 2, offsetof(V, nx), 0, TI_VF_MAKE(TI_VC_BYTE,  3, true)  },   /* NORMAL: normalised */
        { 3, offsetof(V, r),  0, TI_VF_MAKE(TI_VC_UBYTE, 4, true)  },   /* COLOR: normalised */
    };
    TiVertexBufferLayout l = { sizeof(V), TI_STEP_PER_VERTEX, 1 };
    TiPipelineDesc pd = {}; pd.library = lib; pd.vertex_fn = "vs"; pd.fragment_fn = "fs";
    pd.attrs = a; pd.attr_count = 4; pd.layouts = &l; pd.layout_count = 1;
    pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    TiPipeline *pipe = nullptr;
    check(ti_pipeline_create(D, &pd, &pipe) == TI_OK, "pipeline with encoded vertex formats");
    if (!pipe) return;
    TiTexture *out = rt(4, 4);
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
    TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = out;
    rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
    TiPass *p = nullptr; ti_pass_begin(f, &rp, &p);
    ti_pass_set_pipeline(p, pipe); ti_pass_set_vertex_buffer(p, 0, vb, 0);
    ti_pass_draw(p, TI_PRIM_TRIANGLES, 0, 3, 1);
    ti_pass_end(p); ti_frame_end_and_wait(f, false);
    auto v = px(out, 4, 4); const uint8_t *c = at(v, 4, 1, 1);
    printf("        pixel = (%u,%u,%u,%u), expected (240,16,255,204)\n", c[0], c[1], c[2], c[3]);
    check(c[0] == 240 && c[1] == 16, "SHORT x2 arrives as integers, including a negative one");
    check(c[2] >= 254, "BYTE x3 normal is normalised (127 -> 1.0)");
    check(c[3] == 204, "UBYTE x4 colour is normalised");
    ti_texture_release(out); ti_pipeline_release(pipe); ti_library_release(lib); ti_buffer_release(vb);
}

static void test_gl_leniency() {
    printf("\n[8] OpenGL leniency where Metal would abort the process\n");
    /* Found by launching the real game: Minecraft creates a 16x16 texture with
     * 6 mip levels. GL makes level 5 0x0; Metal's descriptor validation calls
     * abort(). Must be clamped, not passed through. */
    TiTextureDesc d = {}; d.width = 16; d.height = 16; d.mip_levels = 6; d.format = TI_PF_RGBA8_UNORM;
    d.storage = TI_STORAGE_PRIVATE; d.shader_read = true;
    TiTexture *t = nullptr;
    check(ti_texture_create(D, &d, &t) == TI_OK, "16x16 with 6 requested mips is created (clamped to 5)");
    TiTexture *v = nullptr;
    check(ti_texture_create_view(t, 0, 6, &v) == TI_OK, "a view over all 6 requested mips is clamped too");
    if (v) ti_texture_release(v);
    uint8_t px[4] = {0};
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
    check(ti_frame_upload_texture(f, t, 5, 0, 0, 0, 1, 1, px, 4) == TI_OK,
          "upload to the 0x0 level is a no-op, as in GL");
    check(ti_frame_upload_texture(f, t, 0, 0, 0, 0, 0, 0, px, 4) == TI_OK, "0x0 region is a no-op");
    check(ti_frame_upload_texture(f, t, 0, 0, 12, 12, 8, 8, px, 32) == TI_ERR_INVALID_ARGUMENT,
          "out-of-bounds upload is an error, not a process abort");
    TiBuffer *b = nullptr; ti_buffer_create(D, 4096, TI_STORAGE_SHARED, "b", &b);
    check(ti_frame_copy_texture_to_buffer(f, t, 0, 10, 10, 16, 16, b, 0, 64) == TI_ERR_INVALID_ARGUMENT,
          "out-of-bounds readback region is an error, not a process abort");
    ti_frame_end_and_wait(f, false);
    ti_buffer_release(b); ti_texture_release(t);
}

static void test_upscale() {
    printf("\n[9] world upscaling: bilinear and MetalFX spatial (no flip, correct quadrants)\n");
    const uint32_t S = 8, D = 16;
    /* memory rows 0-3: red | blue ; rows 4-7: green | white */
    std::vector<uint8_t> src(S * S * 4);
    for (uint32_t y = 0; y < S; ++y) for (uint32_t x = 0; x < S; ++x) {
        uint8_t *p = &src[(y * S + x) * 4];
        bool top = y < S / 2, left = x < S / 2;
        p[0] = (top && left) || (!top && !left) ? 255 : 0;
        p[1] = (!top) ? 255 : 0;
        p[2] = (top && !left) || (!top && !left) ? 255 : 0;
        p[3] = 255;
    }
    TiTexture *in = rt(S, S);
    for (int mode = 0; mode < 2; ++mode) {
        const char *name = mode ? "MetalFX spatial" : "bilinear";
        TiTexture *out = rt(D, D);
        TiFrame *f = nullptr; ti_frame_begin(D_dev(), nullptr, &f);
        ti_frame_upload_texture(f, in, 0, 0, 0, 0, S, S, src.data(), S * 4);
        TiResult r = ti_frame_upscale(f, in, out, mode ? TI_UPSCALE_METALFX_SPATIAL : TI_UPSCALE_BILINEAR);
        ti_frame_end_and_wait(f, false);
        char msg[160];
        snprintf(msg, sizeof msg, "%s upscale 8x8 -> 16x16 encodes", name);
        check(r == TI_OK, msg);
        auto v = px(out, D, D);
        auto near = [](const uint8_t *p, int r, int g, int b) {
            return abs(p[0] - r) < 40 && abs(p[1] - g) < 40 && abs(p[2] - b) < 40;
        };
        const uint8_t *tl = at(v, D, 3, 3), *tr = at(v, D, 12, 3), *bl = at(v, D, 3, 12), *br = at(v, D, 12, 12);
        printf("        %-16s tl=(%u,%u,%u) tr=(%u,%u,%u) bl=(%u,%u,%u) br=(%u,%u,%u)\n", name,
               tl[0],tl[1],tl[2], tr[0],tr[1],tr[2], bl[0],bl[1],bl[2], br[0],br[1],br[2]);
        snprintf(msg, sizeof msg, "%s keeps every quadrant in place (no flip, no swap)", name);
        check(near(tl, 255, 0, 0) && near(tr, 0, 0, 255) && near(bl, 0, 255, 0) && near(br, 255, 255, 255), msg);
        ti_texture_release(out);
    }
    ti_texture_release(in);
}


static const char *kProfMSL = R"(
#include <metal_stdlib>
using namespace metal;
struct O { float4 p [[position]]; };
vertex O vs_light(uint v [[vertex_id]]) { float2 q = float2((v<<1)&2, v&2); O o; o.p = float4(q*2-1,0,1); return o; }
fragment float4 fs_light(O i [[stage_in]]) { return float4(1, 0, 0, 1); }
/* Vertex-bound: a long dependent loop per vertex, zero-area triangles so no
 * fragment work follows. */
vertex O vs_heavy(uint v [[vertex_id]]) {
    float a = float(v) * 1e-6;
    for (int k = 0; k < 400; ++k) a = fract(sin(a * 12.9898 + float(k)) * 43758.5453);
    O o; o.p = float4(a * 1e-3, a * 1e-3, 0, 1); return o;
}
/* Fragment-bound: a long dependent loop per pixel over a full-screen triangle. */
fragment float4 fs_heavy(O i [[stage_in]]) {
    float a = i.p.x * 1e-3 + i.p.y;
    for (int k = 0; k < 400; ++k) a = fract(sin(a * 12.9898 + float(k)) * 43758.5453);
    return float4(a, a, a, 1);
}
)";

static void test_pass_profile() {
    printf("\n[10] per-pass stage profiling separates vertex-bound from fragment-bound work\n");
    TiResult en = ti_device_set_pass_profiling(D, true);
    check(en == TI_OK, "stage-boundary profiling available on this GPU");
    if (en != TI_OK) return;
    TiLibrary *lib = nullptr; ti_library_from_source(D, kProfMSL, nullptr, &lib);
    auto mk = [&](const char *vs, const char *fs) {
        TiPipelineDesc pd = {}; pd.library = lib; pd.vertex_fn = vs; pd.fragment_fn = fs;
        pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
        TiPipeline *pp = nullptr; ti_pipeline_create(D, &pd, &pp); return pp;
    };
    TiPipeline *light = mk("vs_light", "fs_light"), *vheavy = mk("vs_heavy", "fs_light"),
               *fheavy = mk("vs_light", "fs_heavy");
    TiTexture *small = rt(64, 64), *big = rt(1024, 1024);
    auto pass = [&](TiFrame *f, const char *label, TiTexture *t, TiPipeline *pp, uint32_t verts) {
        TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = t; rp.label = label;
        rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
        TiPass *p = nullptr; ti_pass_begin(f, &rp, &p);
        ti_pass_set_pipeline(p, pp); ti_pass_draw(p, TI_PRIM_TRIANGLES, 0, verts, 1);
        ti_pass_end(p);
    };

    /* A frame encoded before a reset must not leak into the next interval. */
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);
    pass(f, "stale", small, light, 3);
    ti_frame_end(f, false);
    ti_device_reset_pass_profile(D);

    ti_frame_begin(D, nullptr, &f);
    pass(f, "light", small, light, 3);
    pass(f, "vertex-heavy", small, vheavy, 300000);
    pass(f, "fragment-heavy", big, fheavy, 3);
    ti_frame_end_and_wait(f, false);
    double cb_ms = ti_device_last_gpu_ms(D);

    /* Disabled: passes are not sampled. */
    ti_device_set_pass_profiling(D, false);
    ti_frame_begin(D, nullptr, &f);
    pass(f, "after-disable", small, light, 3);
    ti_frame_end_and_wait(f, false);
    ti_device_wait_idle(D);

    struct timespec ts = { 0, 60 * 1000 * 1000 }; nanosleep(&ts, nullptr);   /* calibration baseline */
    TiPassProfileEntry e[8] = {}; TiPassProfileSummary sum = {};
    check(ti_device_pass_profile(D, e, 8, &sum) == TI_OK, "profile readable");
    auto find = [&](const char *l) -> TiPassProfileEntry * {
        for (uint32_t i = 0; i < sum.entries && i < 8; ++i) if (!strcmp(e[i].label, l)) return &e[i];
        return nullptr;
    };
    TiPassProfileEntry *L = find("light"), *V = find("vertex-heavy"), *F = find("fragment-heavy");
    check(!find("stale"), "frame encoded before the reset is discarded");
    check(!find("after-disable"), "no samples once profiling is disabled");
    check(L && V && F && sum.entries == 3, "exactly the three passes of the interval, by label");
    check(sum.command_buffers == 1 && sum.unsampled_passes == 0, "one command buffer, nothing unsampled");
    check(sum.ns_per_tick > 0.01 && sum.ns_per_tick < 1000.0, "GPU timestamp calibration is sane");
    if (!(L && V && F)) { ti_device_set_pass_profiling(D, false); return; }
    printf("        light v=%.4f f=%.4f | vertex-heavy v=%.4f f=%.4f | fragment-heavy v=%.4f f=%.4f | cb=%.4f ms\n",
           L->vertex_ms, L->fragment_ms, V->vertex_ms, V->fragment_ms, F->vertex_ms, F->fragment_ms, cb_ms);
    check(L->passes == 1 && V->passes == 1 && F->passes == 1 && L->invalid + V->invalid + F->invalid == 0,
          "each pass sampled once with valid vertex and fragment timestamps");
    check(V->vertex_ms > 5 * V->fragment_ms && V->vertex_ms > 5 * F->vertex_ms,
          "vertex-bound pass: time lands in the vertex stage");
    check(F->fragment_ms > 5 * F->vertex_ms && F->fragment_ms > 5 * L->fragment_ms,
          "fragment-bound pass: time lands in the fragment stage");
    check(F->fragment_ms <= cb_ms * 1.05 + 0.05 && V->vertex_ms <= cb_ms * 1.05 + 0.05,
          "stage times fit inside the command buffer's GPU time");
    ti_pipeline_release(light); ti_pipeline_release(vheavy); ti_pipeline_release(fheavy);
    ti_library_release(lib); ti_texture_release(small); ti_texture_release(big);
}


static void test_wait_stats() {
    printf("\n[11] blocked-on-GPU accounting counts real waits only\n");
    TiLibrary *lib = nullptr; ti_library_from_source(D, kProfMSL, nullptr, &lib);
    TiPipelineDesc pd = {}; pd.library = lib; pd.vertex_fn = "vs_light"; pd.fragment_fn = "fs_heavy";
    pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    TiPipeline *pp = nullptr; ti_pipeline_create(D, &pd, &pp);
    TiTexture *big = rt(1024, 1024);
    ti_device_wait_idle(D);
    TiWaitStats a = {}, b = {};
    ti_device_wait_stats(D, &a);
    TiFrame *f = nullptr; ti_frame_begin(D, nullptr, &f);   /* a free slot: must not count */
    TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = big;
    rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
    TiPass *p = nullptr; ti_pass_begin(f, &rp, &p);
    ti_pass_set_pipeline(p, pp); ti_pass_draw(p, TI_PRIM_TRIANGLES, 0, 3, 1); ti_pass_end(p);
    uint64_t serial = ti_frame_serial(f);
    ti_frame_end(f, false);
    ti_device_wait_serial(D, serial, UINT64_MAX);            /* ~3 ms of GPU work: must count */
    ti_device_wait_stats(D, &b);
    printf("        frame waits +%llu, serial waits +%llu (%.3f ms)\n",
           (unsigned long long)(b.frame_waits - a.frame_waits),
           (unsigned long long)(b.serial_waits - a.serial_waits), b.serial_wait_ms - a.serial_wait_ms);
    check(b.frame_waits == a.frame_waits, "acquiring a free frame slot is not counted as a wait");
    check(b.serial_waits == a.serial_waits + 1 && b.serial_wait_ms - a.serial_wait_ms > 0.5,
          "waiting on an in-flight serial is counted with its duration");
    ti_device_wait_stats(D, &a);
    ti_device_wait_serial(D, serial, UINT64_MAX);            /* already complete: returns early */
    ti_device_wait_stats(D, &b);
    check(b.serial_waits == a.serial_waits, "waiting on a completed serial is not counted");
    ti_pipeline_release(pp); ti_library_release(lib); ti_texture_release(big);
}


static const char *kStreamMSL = R"(
#include <metal_stdlib>
using namespace metal;
struct VI { float2 pos [[attribute(0)]]; };
struct U { float4 color; };
struct VO { float4 p [[position]]; float4 c; };
vertex VO vs(VI i [[stage_in]], constant U &u [[buffer(0)]]) { VO o; o.p = float4(i.pos, 0, 1); o.c = u.color; return o; }
fragment float4 fs(VO i [[stage_in]], constant float4 &tint [[buffer(1)]]) { return i.c * tint; }
)";

static void test_draw_stream() {
    printf("\n[12] batched draw stream renders exactly what individual calls render\n");
    TiLibrary *lib = nullptr; ti_library_from_source(D, kStreamMSL, nullptr, &lib);
    const uint32_t VSLOT = 2;
    TiVertexAttr a = { 0, 0, VSLOT, TI_VF_MAKE(TI_VC_FLOAT, 2, false) };
    TiVertexBufferLayout l[3] = { {}, {}, { 8, TI_STEP_PER_VERTEX, 1 } };
    TiPipelineDesc pd = {}; pd.library = lib; pd.vertex_fn = "vs"; pd.fragment_fn = "fs";
    pd.attrs = &a; pd.attr_count = 1; pd.layouts = l; pd.layout_count = 3;
    pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    TiPipeline *pipe = nullptr;
    check(ti_pipeline_create(D, &pd, &pipe) == TI_OK, "pipeline");
    if (!pipe) return;

    /* One vertex buffer per quadrant (like one per chunk section). */
    TiBuffer *vb[4];
    const float q[4][2] = { {-1, 0}, {0, 0}, {-1, -1}, {0, -1} };   /* lower-left corners */
    for (int k = 0; k < 4; ++k) {
        float x = q[k][0], y = q[k][1];
        float v[8] = { x, y, x + 1, y, x + 1, y + 1, x, y + 1 };
        ti_buffer_create(D, sizeof v, TI_STORAGE_SHARED, "quad", &vb[k]);
        memcpy(ti_buffer_contents(vb[k]), v, sizeof v);
    }
    uint16_t idx[6] = { 0, 1, 2, 2, 3, 0 };
    TiBuffer *ib = nullptr; ti_buffer_create(D, sizeof idx, TI_STORAGE_SHARED, "idx", &ib);
    memcpy(ti_buffer_contents(ib), idx, sizeof idx);
    /* Per-draw uniforms: slices of ONE buffer, so rebinds are offset-only. */
    TiBuffer *ubo = nullptr; ti_buffer_create(D, 256 * 4, TI_STORAGE_SHARED, "ubo", &ubo);
    const float col[4][4] = { {1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 0, 1} };
    for (int k = 0; k < 4; ++k) memcpy((char *)ti_buffer_contents(ubo) + 256 * k, col[k], 16);
    TiBuffer *tint = nullptr; ti_buffer_create(D, 16, TI_STORAGE_SHARED, "tint", &tint);
    const float one[4] = { 1, 1, 1, 1 }; memcpy(ti_buffer_contents(tint), one, 16);

    /* draws: quadrants 0..3 with colours 0..3, a zero-count draw, then quadrant 3
     * again with vb=0 (keep) and colour 0 (rebind to an earlier offset). */
    struct Dr { int vb; uint32_t count; int color; } dr[6] = {
        { 0, 6, 0 }, { 1, 6, 1 }, { 2, 6, 2 }, { 3, 6, 3 }, { 3, 0, 1 }, { -1, 6, 0 } };
    auto begin = [&](TiTexture *t, TiFrame **f, TiPass **p) {
        ti_frame_begin(D, nullptr, f);
        TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = t;
        rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
        ti_pass_begin(*f, &rp, p); ti_pass_set_pipeline(*p, pipe);
    };

    TiTexture *ref = rt(8, 8), *got = rt(8, 8);
    TiFrame *f = nullptr; TiPass *p = nullptr;
    begin(ref, &f, &p);
    TiBuffer *cur = nullptr;
    for (auto &d : dr) {
        ti_pass_set_vertex_buffer(p, 0, ubo, 256 * d.color);
        ti_pass_set_fragment_buffer(p, 1, tint, 0);
        if (d.vb >= 0) cur = vb[d.vb];
        ti_pass_set_vertex_buffer(p, VSLOT, cur, 0);
        ti_pass_draw_indexed(p, TI_PRIM_TRIANGLES, d.count, TI_INDEX_U16, ib, 0, 1, 0);
    }
    ti_pass_end(p); ti_frame_end_and_wait(f, false);

    std::vector<int64_t> st;
    for (auto &d : dr) {
        st.push_back(d.vb >= 0 ? (int64_t)(uintptr_t)vb[d.vb] : 0);
        st.push_back((int64_t)(uintptr_t)ib); st.push_back(0);
        st.push_back((int64_t)d.count | ((int64_t)TI_INDEX_U16 << 32));
        st.push_back(2);
        st.push_back((1ll << 32) | 0); st.push_back((int64_t)(uintptr_t)ubo);  st.push_back(256 * d.color);
        st.push_back((2ll << 32) | 1); st.push_back((int64_t)(uintptr_t)tint); st.push_back(0);
    }
    begin(got, &f, &p);
    TiResult r = ti_pass_draw_indexed_stream(p, TI_PRIM_TRIANGLES, VSLOT, st.data(), st.size(), 6);
    ti_pass_end(p); ti_frame_end_and_wait(f, false);
    check(r == TI_OK, "stream of 6 records accepted");
    auto a8 = px(ref, 8, 8), b8 = px(got, 8, 8);
    check(a8 == b8, "stream output is byte-identical to individual calls");
    /* Metal row 0 is the top: NDC y > 0. */
    auto is = [&](uint32_t x, uint32_t y, const float *c) {
        const uint8_t *pp = at(b8, 8, x, y);
        return pp[0] == (uint8_t)(c[0] * 255) && pp[1] == (uint8_t)(c[1] * 255) && pp[2] == (uint8_t)(c[2] * 255);
    };
    check(is(2, 2, col[0]) && is(6, 2, col[1]) && is(2, 6, col[2]),
          "each record bound its own vertex buffer and uniform slice (offset-only rebinds)");
    check(is(6, 6, col[0]), "vb=0 keeps the bound buffer; rebinding an earlier offset takes effect");

    /* Malformed streams fail cleanly instead of crashing. */
    begin(got, &f, &p);
    check(ti_pass_draw_indexed_stream(p, TI_PRIM_TRIANGLES, VSLOT, st.data(), 7, 1) == TI_ERR_INVALID_ARGUMENT,
          "truncated record is rejected");
    check(ti_pass_draw_indexed_stream(p, TI_PRIM_TRIANGLES, VSLOT, st.data(), st.size() + 0, 5) == TI_ERR_INVALID_ARGUMENT,
          "trailing words are rejected");
    std::vector<int64_t> bad(st.begin(), st.begin() + 11);
    bad[1] = (int64_t)(uintptr_t)ref;                                 /* a texture where a buffer belongs */
    check(ti_pass_draw_indexed_stream(p, TI_PRIM_TRIANGLES, VSLOT, bad.data(), bad.size(), 1) == TI_ERR_INVALID_HANDLE,
          "wrong-type handle is rejected");
    std::vector<int64_t> bad2(st.begin(), st.begin() + 11);
    bad2[5] = (1ll << 32) | VSLOT;                                     /* uniform over the vertex-data slot */
    check(ti_pass_draw_indexed_stream(p, TI_PRIM_TRIANGLES, VSLOT, bad2.data(), bad2.size(), 1) == TI_ERR_INVALID_ARGUMENT,
          "bind aimed at the vertex-data slot is rejected");
    ti_pass_end(p); ti_frame_end_and_wait(f, false);

    for (auto b : vb) ti_buffer_release(b);
    ti_buffer_release(ib); ti_buffer_release(ubo); ti_buffer_release(tint);
    ti_texture_release(ref); ti_texture_release(got); ti_pipeline_release(pipe); ti_library_release(lib);
}

int main() {
    printf("=== Titanium frame/backend-support tests ===\n");
    ti_set_log_level(TI_LOG_WARN);
    TiDeviceDesc dd = {}; dd.max_frames_in_flight = 3;
    if (ti_device_create(&dd, &D) != TI_OK) return 1;
    test_ordering();
    test_serials();
    test_rect_clear();
    test_flip_blit();
    test_views_cube_texelbuffer();
    test_sampler_lod_clamp();
    test_vertex_formats();
    test_gl_leniency();
    test_upscale();
    test_pass_profile();
    test_wait_stats();
    test_draw_stream();
    ti_device_release(D);
    printf("\n=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
