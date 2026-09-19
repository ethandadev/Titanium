/*
 * Golden semantic tests for GLSL -> MSL translation.
 *
 * "It compiles" proves almost nothing: every fixup below produces valid MSL
 * whether it is right or wrong. Each test therefore renders with a translated
 * shader and asserts the pixels OpenGL would have produced, read back off the
 * GPU. Render targets are checked in *memory row* order, where OpenGL's
 * convention is row 0 = bottom of the image.
 */
#include "titanium/ti_api.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <set>
#include <sstream>

static int g_pass = 0, g_fail = 0;
static void check(bool ok, const char *what) {
    if (ok) { ++g_pass; printf("  ok    %s\n", what); }
    else    { ++g_fail; printf("  FAIL  %s\n        (last error: %.600s)\n", what, ti_last_error()); }
}

static TiDevice *g_dev = nullptr;

/* ---------------- translated-pipeline helper -------------------------- */

struct Refl { std::vector<std::vector<std::string>> rows; };

static Refl parse_refl(const char *r) {
    Refl out;
    std::istringstream in(r ? r : "");
    std::string line;
    while (std::getline(in, line)) {
        std::istringstream ls(line);
        std::vector<std::string> f; std::string w;
        while (ls >> w) f.push_back(w);
        if (!f.empty()) out.rows.push_back(f);
    }
    return out;
}

static int refl_find(const Refl &r, const char *kind, const char *name, int field) {
    for (auto &row : r.rows)
        if (row.size() > (size_t)field && row[0] == kind && row[1] == name)
            return atoi(row[field].c_str());
    return -1;
}

struct Attr { const char *name; uint32_t offset; TiVertexFormat fmt; };

struct TP {
    TiTranslation *t = nullptr;
    TiLibrary *vl = nullptr, *fl = nullptr;
    TiPipeline *p = nullptr;
    Refl refl;
    ~TP() {
        if (p) ti_pipeline_release(p);
        if (fl) ti_library_release(fl);
        if (vl) ti_library_release(vl);
        if (t) ti_translation_release(t);
    }
};

static bool build(TP &tp, const char *vs, const char *fs, const char *name,
                  const std::vector<Attr> &attrs, uint32_t stride,
                  TiPixelFormat depth = TI_PF_INVALID, bool blend = false) {
    if (ti_translate_glsl(vs, fs, name, &tp.t) != TI_OK) return false;
    tp.refl = parse_refl(ti_translation_reflection(tp.t));
    if (ti_library_from_source(g_dev, ti_translation_msl(tp.t, TI_STAGE_VERTEX), nullptr, &tp.vl) != TI_OK) return false;
    if (ti_library_from_source(g_dev, ti_translation_msl(tp.t, TI_STAGE_FRAGMENT), nullptr, &tp.fl) != TI_OK) return false;

    std::vector<TiVertexAttr> va;
    for (auto &a : attrs) {
        int loc = refl_find(tp.refl, "vertex_input", a.name, 2);
        if (loc < 0) { fprintf(stderr, "no vertex input %s\n", a.name); return false; }
        va.push_back({ (uint32_t)loc, a.offset, TI_VERTEX_BUFFER_INDEX, a.fmt });
    }
    /* Layout array is indexed by buffer index, so slot 30 needs 31 entries. */
    std::vector<TiVertexBufferLayout> layouts(TI_VERTEX_BUFFER_INDEX + 1,
                                              TiVertexBufferLayout{0, TI_STEP_PER_VERTEX, 1});
    layouts[TI_VERTEX_BUFFER_INDEX] = { stride, TI_STEP_PER_VERTEX, 1 };

    TiPipelineDesc pd = {};
    pd.library = tp.vl; pd.fragment_library = tp.fl;
    pd.vertex_fn = ti_translation_entry_point(tp.t, TI_STAGE_VERTEX);
    pd.fragment_fn = ti_translation_entry_point(tp.t, TI_STAGE_FRAGMENT);
    pd.attrs = va.data(); pd.attr_count = (uint32_t)va.size();
    pd.layouts = layouts.data(); pd.layout_count = (uint32_t)layouts.size();
    pd.color_count = 1; pd.color[0].format = TI_PF_RGBA8_UNORM; pd.color[0].write_mask = 0xF;
    if (blend) {
        pd.color[0].blend_enabled = true;
        pd.color[0].src_rgb = pd.color[0].src_alpha = TI_BF_ONE;
        pd.color[0].dst_rgb = pd.color[0].dst_alpha = TI_BF_ZERO;
    }
    pd.depth_format = depth; pd.sample_count = 1; pd.label = name;
    return ti_pipeline_create(g_dev, &pd, &tp.p) == TI_OK;
}

static TiTexture *make_rt(uint32_t w, uint32_t h, TiPixelFormat f = TI_PF_RGBA8_UNORM) {
    TiTextureDesc d = {};
    d.width = w; d.height = h; d.format = f; d.storage = TI_STORAGE_PRIVATE;
    d.render_target = true; d.shader_read = true;
    TiTexture *t = nullptr;
    ti_texture_create(g_dev, &d, &t);
    return t;
}

static TiBuffer *make_buf(const void *data, size_t size) {
    TiBuffer *b = nullptr;
    ti_buffer_create(g_dev, size, TI_STORAGE_SHARED, "tb", &b);
    if (b) memcpy(ti_buffer_contents(b), data, size);
    return b;
}

static std::vector<uint8_t> read_rgba(TiTexture *t, uint32_t w, uint32_t h) {
    std::vector<uint8_t> px(w * h * 4);
    ti_texture_readback(t, 0, 0, 0, w, h, px.data(), w * 4);
    return px;
}
static const uint8_t *row_px(const std::vector<uint8_t> &px, uint32_t w, uint32_t x, uint32_t row) {
    return &px[(row * w + x) * 4];
}

/* Full-screen and half-screen quads in GL NDC. */
static const float kFull[8]    = { -1,-1,  1,-1,  -1, 1,  1, 1 };
static const float kTopHalf[8] = { -1, 0,  1, 0,  -1, 1,  1, 1 };
static const uint16_t kQuadIdx[6] = { 0, 1, 2, 2, 1, 3 };

/* Draw a 4-vertex quad with the given pipeline into `rt`. */
static bool draw_quad(TP &tp, TiTexture *rt, uint32_t W, uint32_t H, const float *verts,
                      const void *ubo = nullptr, size_t ubo_size = 0, const char *ubo_name = nullptr,
                      TiTexture *sample = nullptr, TiSampler *smp = nullptr, const char *smp_name = nullptr,
                      TiTexture *depth = nullptr, TiDepthStencil *ds = nullptr) {
    TiBuffer *vb = make_buf(verts, sizeof(float) * 8);
    TiBuffer *ib = make_buf(kQuadIdx, sizeof kQuadIdx);
    TiFrame *f = nullptr;
    if (ti_frame_begin(g_dev, nullptr, &f) != TI_OK) return false;
    TiRenderPassDesc rp = {};
    rp.color_count = 1; rp.color[0].texture = rt;
    rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE; rp.color[0].clear_a = 1;
    if (depth) {
        rp.has_depth = true; rp.depth.texture = depth; rp.depth.load = TI_LOAD_CLEAR;
        rp.depth.store = TI_STORE_STORE; rp.depth.clear_depth = 1.0;
    }
    TiPass *p = nullptr;
    if (ti_pass_begin(f, &rp, &p) != TI_OK) { ti_frame_end(f, false); return false; }
    ti_pass_set_pipeline(p, tp.p);
    if (ds) ti_pass_set_depth_stencil(p, ds);
    ti_pass_set_viewport(p, 0, 0, W, H, 0, 1);
    ti_pass_set_front_face_ccw(p, false);   /* GL's CCW front, after the Y flip */
    ti_pass_set_vertex_buffer(p, TI_VERTEX_BUFFER_INDEX, vb, 0);
    if (ubo) {
        int idx = refl_find(tp.refl, "uniform_block", ubo_name, 2);
        for (auto &row : tp.refl.rows)
            if (row[0] == "uniform_block" && row[1] == ubo_name) {
                if (row[4].find('v') != std::string::npos) ti_pass_set_vertex_bytes(p, idx, ubo, (uint32_t)ubo_size);
                if (row[4].find('f') != std::string::npos) ti_pass_set_fragment_bytes(p, idx, ubo, (uint32_t)ubo_size);
            }
    }
    if (sample) {
        int ti = refl_find(tp.refl, "sampler", smp_name, 2);
        ti_pass_set_fragment_texture(p, ti, sample);
        ti_pass_set_fragment_sampler(p, ti, smp);
    }
    ti_pass_draw_indexed(p, TI_PRIM_TRIANGLES, 6, TI_INDEX_U16, ib, 0, 1, 0);
    ti_pass_end(p);
    TiResult r = ti_frame_end_and_wait(f, false);
    ti_buffer_release(vb); ti_buffer_release(ib);
    return r == TI_OK;
}

static const char *kFsWhite =
    "#version 330\nout vec4 fragColor;\nvoid main(){ fragColor = vec4(1.0); }\n";
static const char *kFsRed =
    "#version 330\nout vec4 fragColor;\nvoid main(){ fragColor = vec4(1.0, 0.0, 0.0, 1.0); }\n";
static const char *kVsPos =
    "#version 330\nin vec2 Position;\nvoid main(){ gl_Position = vec4(Position, 0.0, 1.0); }\n";

/* ---------------- tests ---------------------------------------------- */

static void test_reflection_and_layout() {
    printf("\n[1] translation, reflection, and a Minecraft-shaped uniform block\n");
    /* Same member types as vanilla's DynamicTransforms: mat4, vec4, vec3, mat4. */
    const char *vs =
        "#version 330\n"
        "layout(std140) uniform Transforms { mat4 MV; vec4 Tint; vec3 Offset; mat4 TexMat; };\n"
        "layout(std140) uniform Proj { mat4 P; };\n"
        "in vec3 Position; in vec2 UV0; in vec4 Color;\n"
        "out vec2 texCoord0; out vec4 vertexColor;\n"
        "void main(){ gl_Position = P * MV * vec4(Position + Offset, 1.0);\n"
        "  texCoord0 = (TexMat * vec4(UV0, 0.0, 1.0)).xy; vertexColor = Color * Tint; }\n";
    const char *fs =
        "#version 330\n"
        "layout(std140) uniform Transforms { mat4 MV; vec4 Tint; vec3 Offset; mat4 TexMat; };\n"
        "uniform sampler2D Sampler0;\n"
        "in vec2 texCoord0; in vec4 vertexColor; out vec4 fragColor;\n"
        "void main(){ vec4 c = texture(Sampler0, texCoord0) * vertexColor;\n"
        "  if (c.a < 0.1) discard; fragColor = c * Tint; }\n";

    TiTranslation *t = nullptr;
    TiResult r = ti_translate_glsl(vs, fs, "reflect", &t);
    check(r == TI_OK, "translate a linked vertex+fragment pair");
    if (!t) return;
    const char *refl = ti_translation_reflection(t);
    printf("        reflection:\n");
    std::istringstream in(refl); std::string l;
    while (std::getline(in, l)) printf("          %s\n", l.c_str());
    Refl R = parse_refl(refl);

    check(refl_find(R, "uniform_block", "Transforms", 3) == 160,
          "std140 mat4,vec4,vec3,mat4 block is 160 bytes (vanilla DynamicTransforms layout)");
    int tvs = -1; std::string tstages;
    for (auto &row : R.rows) if (row[0] == "uniform_block" && row[1] == "Transforms") { tvs = atoi(row[2].c_str()); tstages = row[4]; }
    check(tstages == "vf", "a block used by both stages is reported for both");
    check(tvs >= 0 && tvs < TI_VERTEX_BUFFER_INDEX, "uniform block slot is below the vertex-buffer slot");
    check(refl_find(R, "sampler", "Sampler0", 2) == 0, "Sampler0 resolved by name to texture slot 0");
    check(refl_find(R, "vertex_input", "Position", 2) >= 0 &&
          refl_find(R, "vertex_input", "UV0", 2) >= 0 &&
          refl_find(R, "vertex_input", "Color", 2) >= 0,
          "every vertex attribute is reported with its location");

    const char *vmsl = ti_translation_msl(t, TI_STAGE_VERTEX);
    const char *fmsl = ti_translation_msl(t, TI_STAGE_FRAGMENT);
    check(vmsl && strstr(vmsl, "ti_vs_main"), "vertex entry point renamed");
    check(fmsl && strstr(fmsl, "discard_fragment"), "GLSL discard became discard_fragment()");
    TiLibrary *a = nullptr, *b = nullptr;
    check(ti_library_from_source(g_dev, vmsl, nullptr, &a) == TI_OK, "vertex MSL compiles with Metal");
    check(ti_library_from_source(g_dev, fmsl, nullptr, &b) == TI_OK, "fragment MSL compiles with Metal");
    if (a) ti_library_release(a);
    if (b) ti_library_release(b);
    ti_translation_release(t);
}

static void test_depth_range() {
    printf("\n[2] clip-space depth: GL [-w,w] must land in Metal [0,1]\n");
    const char *vs =
        "#version 330\nin vec2 Position;\n"
        "layout(std140) uniform Params { vec4 Z; };\n"
        "void main(){ gl_Position = vec4(Position, Z.x, 1.0); }\n";
    TP tp;
    check(build(tp, vs, kFsWhite, "depth", {{"Position", 0, TI_VF_FLOAT2}}, 8, TI_PF_DEPTH32_FLOAT),
          "build depth pipeline");
    if (!tp.p) return;
    TiDepthStencilDesc dd = { TI_CMP_LESS, true, "less" };
    TiDepthStencil *ds = nullptr; ti_depth_stencil_create(g_dev, &dd, &ds);
    const uint32_t N = 16;
    TiTexture *rt = make_rt(N, N), *depth = make_rt(N, N, TI_PF_DEPTH32_FLOAT);

    struct { float gl_z; float want; const char *what; } cases[] = {
        {  0.0f, 0.50f, "GL z=0 (mid-range) -> depth 0.50" },
        { -0.5f, 0.25f, "GL z=-0.5 -> depth 0.25" },
        {  0.5f, 0.75f, "GL z=+0.5 -> depth 0.75" },
    };
    for (auto &c : cases) {
        float ubo[4] = { c.gl_z, 0, 0, 0 };
        draw_quad(tp, rt, N, N, kFull, ubo, sizeof ubo, "Params", nullptr, nullptr, nullptr, depth, ds);
        std::vector<float> d(N * N);
        ti_texture_readback(depth, 0, 0, 0, N, N, d.data(), N * 4);
        float got = d[(N / 2) * N + N / 2];
        char msg[160];
        snprintf(msg, sizeof msg, "%s (got %.4f)", c.what, got);
        check(fabsf(got - c.want) < 1e-4f, msg);
    }
    ti_texture_release(depth); ti_texture_release(rt); ti_depth_stencil_release(ds);
}

static void test_y_origin() {
    printf("\n[3] framebuffer origin: render targets keep OpenGL's memory layout\n");
    TP tp;
    check(build(tp, kVsPos, kFsRed, "yorigin", {{"Position", 0, TI_VF_FLOAT2}}, 8), "build pipeline");
    if (!tp.p) return;
    const uint32_t N = 32;
    TiTexture *rt = make_rt(N, N);
    draw_quad(tp, rt, N, N, kTopHalf);
    auto px = read_rgba(rt, N, N);
    /* GL: NDC y in [0,1] is the top half, which is memory rows N/2..N-1. */
    check(row_px(px, N, N/2, 3*N/4)[0] == 255, "GL top half lands in the upper memory rows");
    check(row_px(px, N, N/2, N/4)[0] == 0,     "lower memory rows stay clear");
    ti_texture_release(rt);
}

static void test_render_then_sample() {
    printf("\n[4] render-to-texture then sample: a post-processing chain stays upright\n");
    TP a, b;
    check(build(a, kVsPos, kFsRed, "rt-a", {{"Position", 0, TI_VF_FLOAT2}}, 8), "build producer");
    /* Consumer written the way Minecraft's post shaders are: UV derived from
     * the GL-convention position, (0,0) at the bottom-left. */
    const char *vs = "#version 330\nin vec2 Position; out vec2 texCoord;\n"
                     "void main(){ gl_Position = vec4(Position, 0.0, 1.0); texCoord = Position * 0.5 + 0.5; }\n";
    const char *fs = "#version 330\nuniform sampler2D InSampler; in vec2 texCoord; out vec4 fragColor;\n"
                     "void main(){ fragColor = texture(InSampler, texCoord); }\n";
    check(build(b, vs, fs, "rt-b", {{"Position", 0, TI_VF_FLOAT2}}, 8), "build consumer");
    if (!a.p || !b.p) return;
    const uint32_t N = 32;
    TiTexture *ra = make_rt(N, N), *rb = make_rt(N, N);
    TiSamplerDesc sd = {}; sd.min_filter = sd.mag_filter = TI_FILTER_NEAREST;
    TiSampler *smp = nullptr; ti_sampler_create(g_dev, &sd, &smp);
    draw_quad(a, ra, N, N, kTopHalf);
    draw_quad(b, rb, N, N, kFull, nullptr, 0, nullptr, ra, smp, "InSampler");
    auto px = read_rgba(rb, N, N);
    check(row_px(px, N, N/2, 3*N/4)[0] == 255, "sampled image is not vertically flipped (top stays top)");
    check(row_px(px, N, N/2, N/4)[0] == 0,     "bottom stays clear after the round trip");
    ti_sampler_release(smp); ti_texture_release(ra); ti_texture_release(rb);
}

static void test_fragcoord() {
    printf("\n[5] gl_FragCoord.y counts from the bottom, as in OpenGL\n");
    const char *fs = "#version 330\nout vec4 fragColor;\n"
                     "void main(){ fragColor = gl_FragCoord.y < 16.0 ? vec4(1,0,0,1) : vec4(0,1,0,1); }\n";
    TP tp;
    check(build(tp, kVsPos, fs, "fragcoord", {{"Position", 0, TI_VF_FLOAT2}}, 8), "build pipeline");
    if (!tp.p) return;
    const uint32_t N = 32;
    TiTexture *rt = make_rt(N, N);
    draw_quad(tp, rt, N, N, kFull);
    auto px = read_rgba(rt, N, N);
    check(row_px(px, N, 8, 4)[0] == 255,  "low gl_FragCoord.y is the bottom (memory row 4 red)");
    check(row_px(px, N, 8, 28)[1] == 255, "high gl_FragCoord.y is the top (memory row 28 green)");
    ti_texture_release(rt);
}

static void test_winding() {
    printf("\n[6] winding: GL counter-clockwise front faces survive the Y flip\n");
    const char *fs = "#version 330\nout vec4 fragColor;\n"
                     "void main(){ fragColor = gl_FrontFacing ? vec4(0,1,0,1) : vec4(1,0,0,1); }\n";
    TP tp;
    check(build(tp, kVsPos, fs, "winding", {{"Position", 0, TI_VF_FLOAT2}}, 8), "build pipeline");
    if (!tp.p) return;
    const uint32_t N = 32;
    /* Counter-clockwise in GL NDC (y up): bottom-left, bottom-right, top. */
    const float ccw[6] = { -0.8f,-0.8f,  0.8f,-0.8f,  0.0f, 0.8f };
    const float cw[6]  = { -0.8f,-0.8f,  0.0f, 0.8f,  0.8f,-0.8f };

    auto run = [&](const float *tri, bool cull_back) {
        TiTexture *rt = make_rt(N, N);
        TiBuffer *vb = make_buf(tri, sizeof(float) * 6);
        TiFrame *f = nullptr; ti_frame_begin(g_dev, nullptr, &f);
        TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = rt;
        rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE; rp.color[0].clear_a = 1;
        TiPass *p = nullptr; ti_pass_begin(f, &rp, &p);
        ti_pass_set_pipeline(p, tp.p);
        ti_pass_set_viewport(p, 0, 0, N, N, 0, 1);
        ti_pass_set_front_face_ccw(p, false);          /* the rule under test */
        ti_pass_set_cull_mode(p, cull_back ? 2 : 0);
        ti_pass_set_vertex_buffer(p, TI_VERTEX_BUFFER_INDEX, vb, 0);
        ti_pass_draw(p, TI_PRIM_TRIANGLES, 0, 3, 1);
        ti_pass_end(p); ti_frame_end_and_wait(f, false);
        auto px = read_rgba(rt, N, N);
        std::vector<uint8_t> c(row_px(px, N, N/2, N/2), row_px(px, N, N/2, N/2) + 4);
        ti_buffer_release(vb); ti_texture_release(rt);
        return c;
    };
    auto a = run(ccw, true);
    check(a[1] == 255 && a[0] == 0, "GL-CCW triangle survives back-face culling and reports gl_FrontFacing");
    auto b = run(cw, true);
    check(b[0] == 0 && b[1] == 0, "GL-CW triangle is culled as a back face");
    auto c = run(cw, false);
    check(c[0] == 255 && c[1] == 0, "unculled GL-CW triangle reports gl_FrontFacing == false");
}

static void test_vertex_id() {
    printf("\n[7] gl_VertexID includes the base vertex (OpenGL DrawElementsBaseVertex semantics)\n");
    const char *vs =
        "#version 330\nin vec2 Position; out vec4 vcolor;\n"
        "void main(){ gl_Position = vec4(Position, 0.0, 1.0); gl_PointSize = 1.0;\n"
        "  vcolor = vec4(float(gl_VertexID) / 255.0, 0.0, 0.0, 1.0); }\n";
    const char *fs = "#version 330\nin vec4 vcolor; out vec4 fragColor;\nvoid main(){ fragColor = vcolor; }\n";
    TP tp;
    check(build(tp, vs, fs, "vertexid", {{"Position", 0, TI_VF_FLOAT2}}, 8), "build pipeline");
    if (!tp.p) return;
    const uint32_t N = 8;
    /* 7 vertices; only 4..6 are drawn, at pixel centres of columns 1, 3, 5. */
    float verts[14] = {0};
    for (int i = 0; i < 3; ++i) {
        verts[(4 + i) * 2 + 0] = ((1 + 2 * i) + 0.5f) / N * 2.0f - 1.0f;
        verts[(4 + i) * 2 + 1] = (4 + 0.5f) / N * 2.0f - 1.0f;
    }
    const uint16_t idx[3] = { 0, 1, 2 };
    TiBuffer *vb = make_buf(verts, sizeof verts), *ib = make_buf(idx, sizeof idx);
    TiTexture *rt = make_rt(N, N);
    TiFrame *f = nullptr; ti_frame_begin(g_dev, nullptr, &f);
    TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = rt;
    rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
    TiPass *p = nullptr; ti_pass_begin(f, &rp, &p);
    ti_pass_set_pipeline(p, tp.p);
    ti_pass_set_viewport(p, 0, 0, N, N, 0, 1);
    ti_pass_set_vertex_buffer(p, TI_VERTEX_BUFFER_INDEX, vb, 0);
    ti_pass_draw_indexed(p, TI_PRIM_POINTS, 3, TI_INDEX_U16, ib, 0, 1, /*base_vertex*/ 4);
    ti_pass_end(p); ti_frame_end_and_wait(f, false);
    auto px = read_rgba(rt, N, N);
    std::set<int> seen;
    for (uint32_t i = 0; i < N * N; ++i) if (px[i * 4 + 3]) seen.insert(px[i * 4]);
    printf("        gl_VertexID values observed:");
    for (int v : seen) printf(" %d", v);
    printf("\n");
    check(seen == std::set<int>({4, 5, 6}), "indices 0,1,2 with base vertex 4 give gl_VertexID 4,5,6");
    ti_buffer_release(vb); ti_buffer_release(ib); ti_texture_release(rt);
}

static void test_std140_packing() {
    printf("\n[8] std140 packing: a float after a vec3 shares its 16-byte slot\n");
    const char *fs =
        "#version 330\n"
        "layout(std140) uniform Pack { vec3 A; float B; vec3 C; float D; vec2 E; float F; };\n"
        "out vec4 fragColor;\n"
        "void main(){ fragColor = vec4(B, D, F, C.y); }\n";
    TP tp;
    check(build(tp, kVsPos, fs, "std140", {{"Position", 0, TI_VF_FLOAT2}}, 8), "build pipeline");
    if (!tp.p) return;
    int sz = refl_find(tp.refl, "uniform_block", "Pack", 3);
    printf("        reported block size: %d\n", sz);
    check(sz == 48, "block size is the std140 48 bytes (44 declared, rounded to 16)");
    /* Hand-computed std140 offsets: A@0 B@12 C@16 D@28 E@32 F@40. A naive
     * MSL struct would put B at 16 and read 0 here. */
    float ubo[12] = {0};
    ubo[0] = 9.0f; ubo[1] = 9.0f; ubo[2] = 9.0f;   /* A */
    ubo[3] = 0.2f;                                 /* B @12 */
    ubo[4] = 9.0f; ubo[5] = 0.8f; ubo[6] = 9.0f;   /* C @16, C.y @20 */
    ubo[7] = 0.4f;                                 /* D @28 */
    ubo[8] = 9.0f; ubo[9] = 9.0f;                  /* E @32 */
    ubo[10] = 0.6f;                                /* F @40 */
    const uint32_t N = 8;
    TiTexture *rt = make_rt(N, N);
    draw_quad(tp, rt, N, N, kFull, ubo, sizeof ubo, "Pack");
    auto px = read_rgba(rt, N, N);
    const uint8_t *c = row_px(px, N, 4, 4);
    printf("        pixel = (%u,%u,%u,%u), expected (51,102,153,204)\n", c[0], c[1], c[2], c[3]);
    check(c[0] == 51 && c[1] == 102 && c[2] == 153 && c[3] == 204,
          "every member read from its std140 offset");
    ti_texture_release(rt);
}

static void test_varying_order() {
    printf("\n[9] varyings match by name even when declared in a different order\n");
    const char *vs =
        "#version 330\nin vec2 Position; out vec4 va; out vec4 vb;\n"
        "void main(){ gl_Position = vec4(Position,0,1); va = vec4(1,0,0,1); vb = vec4(0,1,0,1); }\n";
    const char *fs =
        "#version 330\nin vec4 vb; in vec4 va; out vec4 fragColor;\n"
        "void main(){ fragColor = vec4(va.r, vb.g, 0.0, 1.0); }\n";
    TP tp;
    check(build(tp, vs, fs, "varyings", {{"Position", 0, TI_VF_FLOAT2}}, 8), "build pipeline");
    if (!tp.p) return;
    const uint32_t N = 8;
    TiTexture *rt = make_rt(N, N);
    draw_quad(tp, rt, N, N, kFull);
    auto px = read_rgba(rt, N, N);
    const uint8_t *c = row_px(px, N, 4, 4);
    check(c[0] == 255 && c[1] == 255, "va and vb arrive in the right inputs");
    ti_texture_release(rt);
}

static void test_errors() {
    printf("\n[10] failures are reported, never thrown\n");
    TiTranslation *t = nullptr;
    check(ti_translate_glsl("#version 330\nvoid main(){ gl_Position = undefined_thing; }\n",
                            nullptr, "broken", &t) == TI_ERR_SHADER_COMPILE && !t,
          "GLSL error returns SHADER_COMPILE");
    check(strstr(ti_last_error(), "undefined_thing") != nullptr,
          "diagnostic names the offending identifier");
    check(ti_translate_glsl(kVsPos,
              "#version 330\nin vec4 nowhere; out vec4 c;\nvoid main(){ c = nowhere; }\n",
              "unlinked", &t) == TI_ERR_SHADER_COMPILE && !t,
          "a fragment input with no vertex output is a link error, as in OpenGL");
    check(ti_translate_glsl(nullptr, nullptr, "none", &t) == TI_ERR_INVALID_ARGUMENT,
          "no stages is an argument error");
    check(ti_translate_glsl(kVsPos, nullptr, "vs-only", &t) == TI_OK && t &&
          ti_translation_msl(t, TI_STAGE_FRAGMENT) == nullptr,
          "a single stage translates; the absent stage reports NULL");
    if (t) ti_translation_release(t);
}

static void test_gl_link_leniency_and_reserved_names() {
    printf("\n[11] OpenGL link leniency and MSL-reserved identifiers\n");
    /* Declared-but-unused fragment input: legal in GL (vanilla
     * rendertype_text_background does this), must not break the pipeline. */
    const char *fs_unused =
        "#version 330\nin vec2 neverWritten; out vec4 fragColor;\n"
        "void main(){ fragColor = vec4(0.0, 0.0, 1.0, 1.0); }\n";
    TP a;
    check(build(a, kVsPos, fs_unused, "unused-input", {{"Position", 0, TI_VF_FLOAT2}}, 8),
          "unused, unmatched fragment input links and builds a Metal pipeline");
    if (a.p) {
        TiTexture *rt = make_rt(8, 8);
        draw_quad(a, rt, 8, 8, kFull);
        auto px = read_rgba(rt, 8, 8);
        check(row_px(px, 8, 4, 4)[2] == 255, "and renders correctly");
        ti_texture_release(rt);
    }

    /* A parameter named `sampler` (vanilla terrain.fsh) is a type in MSL. */
    const char *fs_reserved =
        "#version 330\nuniform sampler2D Sampler0; out vec4 fragColor;\n"
        "vec4 pick(sampler2D sampler, vec2 uv) { return texture(sampler, uv); }\n"
        "void main(){ fragColor = pick(Sampler0, vec2(0.5)); }\n";
    TP b;
    check(build(b, kVsPos, fs_reserved, "reserved", {{"Position", 0, TI_VF_FLOAT2}}, 8),
          "GLSL identifier 'sampler' is renamed so Metal accepts it");
    check(refl_find(b.refl, "sampler", "Sampler0", 2) == 0,
          "renaming happens after reflection: the bind name is still 'Sampler0'");
    if (b.p) {
        uint8_t green[4] = { 0, 255, 0, 255 };
        TiTextureDesc sd = {}; sd.width = 1; sd.height = 1; sd.format = TI_PF_RGBA8_UNORM;
        sd.storage = TI_STORAGE_SHARED; sd.shader_read = true;
        TiTexture *src = nullptr; ti_texture_create(g_dev, &sd, &src);
        ti_texture_upload(src, 0, 0, 0, 0, 1, 1, green, 4);
        TiSamplerDesc smd = {}; TiSampler *smp = nullptr; ti_sampler_create(g_dev, &smd, &smp);
        TiTexture *rt = make_rt(8, 8);
        draw_quad(b, rt, 8, 8, kFull, nullptr, 0, nullptr, src, smp, "Sampler0");
        auto px = read_rgba(rt, 8, 8);
        check(row_px(px, 8, 4, 4)[1] == 255, "and samples through the renamed parameter");
        ti_texture_release(rt); ti_sampler_release(smp); ti_texture_release(src);
    }
}

static void test_flat_provoking_vertex() {
    printf("\n[12] flat varyings: GL takes the LAST vertex, Metal the FIRST\n");
    /* Vanilla rendertype_leash: flat colour on a TRIANGLE_STRIP. Strip of 4
     * vertices, each with a distinct colour; triangle 0 is left, 1 is right. */
    const char *vs =
        "#version 330\nin vec2 Position; in vec4 Color; flat out vec4 vertexColor;\n"
        "void main(){ gl_Position = vec4(Position,0,1); vertexColor = Color; }\n";
    const char *fs =
        "#version 330\nflat in vec4 vertexColor; out vec4 fragColor;\n"
        "void main(){ fragColor = vertexColor; }\n";
    TP tp;
    check(build(tp, vs, fs, "flat", {{"Position", 0, TI_VF_FLOAT2}, {"Color", 8, TI_VF_UCHAR4_NORM}}, 12),
          "build flat pipeline");
    if (!tp.p) return;
    check(refl_find(tp.refl, "flat_input", "vertexColor", 1) >= 0 || [&]{
              for (auto &row : tp.refl.rows) if (row[0] == "flat_input" && row[1] == "vertexColor") return true;
              return false; }(),
          "translator reports vertexColor as a flat input");

    struct V { float x, y; uint8_t r, g, b, a; };
    /* strip: v0 bottom-left, v1 top-left, v2 bottom-right-ish, v3 top-right */
    V v[4] = { {-1,-1, 255,0,0,255}, {-1,1, 0,255,0,255}, {1,-1, 0,0,255,255}, {1,1, 255,255,0,255} };
    const uint32_t N = 16;
    auto render = [&](const std::vector<uint32_t> &idx) {
        TiBuffer *vb = make_buf(v, sizeof v), *ib = make_buf(idx.data(), idx.size() * 4);
        TiTexture *rt = make_rt(N, N);
        TiFrame *f = nullptr; ti_frame_begin(g_dev, nullptr, &f);
        TiRenderPassDesc rp = {}; rp.color_count = 1; rp.color[0].texture = rt;
        rp.color[0].load = TI_LOAD_CLEAR; rp.color[0].store = TI_STORE_STORE;
        TiPass *p = nullptr; ti_pass_begin(f, &rp, &p);
        ti_pass_set_pipeline(p, tp.p); ti_pass_set_viewport(p, 0, 0, N, N, 0, 1);
        ti_pass_set_vertex_buffer(p, TI_VERTEX_BUFFER_INDEX, vb, 0);
        ti_pass_draw_indexed(p, TI_PRIM_TRIANGLES, (uint32_t)idx.size(), TI_INDEX_U32, ib, 0, 1, 0);
        ti_pass_end(p); ti_frame_end_and_wait(f, false);
        auto px = read_rgba(rt, N, N);
        ti_buffer_release(vb); ti_buffer_release(ib); ti_texture_release(rt);
        return px;
    };
    /* GL expectation: triangle 0 (v0,v1,v2) is v2's blue; triangle 1 is v3's yellow. */
    auto naive = render({0,1,2, 1,2,3});                      /* GL order, Metal provoking = first */
    auto fixed = render({2,0,1, 3,2,1});                      /* even (i+2,i,i+1), odd (i+2,i+1,i) */
    const uint8_t *nl = row_px(naive, N, 2, 8), *fl = row_px(fixed, N, 2, 8);
    const uint8_t *nr = row_px(naive, N, 13, 8), *fr = row_px(fixed, N, 13, 8);
    printf("        naive: left=(%u,%u,%u) right=(%u,%u,%u)   rotated: left=(%u,%u,%u) right=(%u,%u,%u)\n",
           nl[0],nl[1],nl[2], nr[0],nr[1],nr[2], fl[0],fl[1],fl[2], fr[0],fr[1],fr[2]);
    check(!(nl[2] == 255 && nl[0] == 0), "without reordering, Metal gives the wrong (first-vertex) colour");
    check(fl[2] == 255 && fl[0] == 0 && fl[1] == 0, "rotated: triangle 0 takes v2's colour, as in GL");
    check(fr[0] == 255 && fr[1] == 255 && fr[2] == 0, "rotated: triangle 1 takes v3's colour, as in GL");
}

int main() {
    printf("=== Titanium GLSL -> MSL golden tests ===\n");
    ti_set_log_level(TI_LOG_WARN);
    TiDeviceDesc dd = {}; dd.max_frames_in_flight = 1; dd.debug_labels = true;
    if (ti_device_create(&dd, &g_dev) != TI_OK) { printf("no device\n"); return 1; }

    test_reflection_and_layout();
    test_depth_range();
    test_y_origin();
    test_render_then_sample();
    test_fragcoord();
    test_winding();
    test_vertex_id();
    test_std140_packing();
    test_varying_order();
    test_errors();
    test_gl_link_leniency_and_reserved_names();
    test_flat_provoking_vertex();

    ti_device_release(g_dev);
    printf("\n=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
