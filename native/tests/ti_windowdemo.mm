/*
 * Titanium on-screen validation.
 *
 * Creates a real NSWindow — the same object GLFW hands back from
 * glfwGetCocoaWindow() — attaches a CAMetalLayer through the public API, and
 * drives actual presented frames. This is the only way to exercise the
 * swapchain, drawable acquisition, resize, and ProMotion pacing paths, none of
 * which the offscreen self-test can reach.
 *
 *   ./ti_windowdemo [--frames N] [--width W] [--height H] [--no-window]
 *
 * Exits non-zero if any checked behaviour fails.
 */
#include "titanium/ti_api.h"
#import <AppKit/AppKit.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include <chrono>

static int g_pass = 0, g_fail = 0;
static void check(bool ok, const char *what) {
    if (ok) { ++g_pass; printf("  ok    %s\n", what); }
    else    { ++g_fail; printf("  FAIL  %s  (%s)\n", what, ti_last_error()); }
}

struct Vtx { float x, y, u, v; };
static const Vtx kQuad[4] = {
    { -0.8f,  0.8f, 0.f, 0.f }, {  0.8f,  0.8f, 1.f, 0.f },
    { -0.8f, -0.8f, 0.f, 1.f }, {  0.8f, -0.8f, 1.f, 1.f },
};
static const uint16_t kIdx[6] = { 0, 1, 2, 2, 1, 3 };
struct Push { float z; float p0, p1, p2; float color[4]; };
static_assert(sizeof(Push) == 32, "Push layout must match MSL");

static const char *kMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VOut { float4 pos [[position]]; float2 uv; };
struct Push { float z; float p0; float p1; float p2; float4 color; };
vertex VOut vs_main(VIn in [[stage_in]], constant Push& p [[buffer(1)]]) {
    VOut o; o.pos = float4(in.pos, p.z, 1.0); o.uv = in.uv; return o;
}
fragment float4 fs_main(VOut in [[stage_in]], constant Push& p [[buffer(1)]]) {
    // A simple checker so tearing or a stale drawable would be visible.
    float2 g = floor(in.uv * 8.0);
    float  c = fmod(g.x + g.y, 2.0);
    return float4(p.color.rgb * mix(0.55, 1.0, c), 1.0);
}
)MSL";

int main(int argc, char **argv) {
    int frames = 180, W = 900, H = 560;
    bool wantWindow = true;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--width")  && i + 1 < argc) W = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--height") && i + 1 < argc) H = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-window")) wantWindow = false;
    }

    printf("=== Titanium on-screen validation (%s) ===\n", ti_version_string());
    ti_set_log_level(TI_LOG_INFO);

    @autoreleasepool {
        if (!wantWindow) { printf("--no-window given; nothing to validate.\n"); return 0; }

        // AppKit must be initialised on the main thread before any NSWindow.
        [NSApplication sharedApplication];
        // Accessory policy: appears on screen without stealing focus or adding
        // a Dock icon, which matters when this runs unattended.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(120, 120, W, H)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        win.title = @"Titanium — Metal surface validation";
        win.releasedWhenClosed = NO;
        [win orderFrontRegardless];
        check(win.contentView != nil, "NSWindow created with a content view");

        TiDeviceDesc dd = {};
        std::string cache = std::string(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp")
                          + "/titanium-windowdemo-cache";
        dd.cache_dir = cache.c_str();
        dd.max_frames_in_flight = 3;
        dd.debug_labels = true;
        TiDevice *dev = nullptr;
        check(ti_device_create(&dd, &dev) == TI_OK, "create device");
        if (!dev) return 1;

        TiCaps caps; ti_device_caps(dev, &caps);

        // ---- surface ------------------------------------------------------
        printf("\n[1] attach CAMetalLayer to the NSWindow\n");
        TiSurfaceDesc sd = {};
        sd.ns_window = (__bridge void *)win;
        sd.format = TI_PF_BGRA8_UNORM;
        sd.vsync = true;
        sd.drawable_scale = 0.0;   // follow the screen
        sd.opaque = true;
        TiSurface *surf = nullptr;
        TiResult rc = ti_surface_create_for_nswindow(dev, &sd, &surf);
        check(rc == TI_OK, "ti_surface_create_for_nswindow");
        if (!surf) { ti_device_release(dev); return 1; }

        uint32_t dw = 0, dh = 0;
        ti_surface_drawable_size(surf, &dw, &dh);
        printf("        drawable %ux%u for a %dx%d point window\n", dw, dh, W, H);
        check(dw >= (uint32_t)W && dh >= (uint32_t)H,
              "drawable is at least the window size (Retina scale applied)");

        uint32_t hz = ti_surface_display_refresh_hz(surf);
        printf("        display refresh: %u Hz (variable=%d)\n", hz, caps.display_is_variable_refresh);
        check(hz >= 30, "display refresh rate queried");

        // ---- pipeline -----------------------------------------------------
        TiLibrary *lib = nullptr;
        check(ti_library_from_source(dev, kMSL, "windowdemo", &lib) == TI_OK, "compile MSL");
        TiBuffer *vb = nullptr, *ib = nullptr;
        ti_buffer_create(dev, sizeof kQuad, TI_STORAGE_SHARED, "vb", &vb);
        memcpy(ti_buffer_contents(vb), kQuad, sizeof kQuad);
        ti_buffer_create(dev, sizeof kIdx, TI_STORAGE_SHARED, "ib", &ib);
        memcpy(ti_buffer_contents(ib), kIdx, sizeof kIdx);

        TiVertexAttr attrs[2] = {
            { 0, offsetof(Vtx, x), 0, TI_VF_FLOAT2 },
            { 1, offsetof(Vtx, u), 0, TI_VF_FLOAT2 },
        };
        TiVertexBufferLayout layouts[1] = { { (uint32_t)sizeof(Vtx), TI_STEP_PER_VERTEX, 1 } };

        TiPipelineDesc pd = {};
        pd.library = lib; pd.vertex_fn = "vs_main"; pd.fragment_fn = "fs_main";
        pd.attrs = attrs; pd.attr_count = 2;
        pd.layouts = layouts; pd.layout_count = 1;
        pd.color_count = 1;
        pd.color[0].format = TI_PF_BGRA8_UNORM;   // must match the layer
        pd.color[0].write_mask = 0xF;
        pd.sample_count = 1; pd.label = "windowdemo";
        TiPipeline *pipe = nullptr;
        check(ti_pipeline_create(dev, &pd, &pipe) == TI_OK,
              "pipeline whose colour format matches the drawable");
        if (!pipe) return 1;

        // ---- presented frames ---------------------------------------------
        printf("\n[2] present %d frames to the drawable\n", frames);
        std::vector<double> cpu; cpu.reserve(frames);
        int lost = 0, errs = 0;
        bool resizeChecked = false, resizeOk = false;

        for (int i = 0; i < frames; ++i) {
            // Pump AppKit so the window stays live and resizable.
            NSEvent *ev;
            while ((ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:nil
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES]))
                [NSApp sendEvent:ev];

            // Mid-run resize: the real failure mode is a stale drawable size.
            if (i == frames / 2) {
                [win setContentSize:NSMakeSize(W - 160, H - 120)];
                NSView *v = win.contentView;
                CGFloat s = v.window.screen.backingScaleFactor;
                ti_surface_set_drawable_size(surf,
                    (uint32_t)(v.bounds.size.width * s),
                    (uint32_t)(v.bounds.size.height * s));
                uint32_t nw = 0, nh = 0;
                ti_surface_drawable_size(surf, &nw, &nh);
                resizeOk = (nw != dw || nh != dh);
                resizeChecked = true;
                printf("        resized: %ux%u -> %ux%u\n", dw, dh, nw, nh);
            }

            auto t0 = std::chrono::steady_clock::now();
            TiFrame *f = nullptr;
            TiResult r = ti_frame_begin(dev, surf, &f);
            if (r == TI_ERR_SURFACE_LOST) { ++lost; continue; }
            if (r != TI_OK) { ++errs; continue; }

            float t = (float)i / (float)frames;
            TiRenderPassDesc rp = {};
            rp.color_count = 1;
            rp.color[0].use_drawable = true;
            rp.color[0].load = TI_LOAD_CLEAR;
            rp.color[0].store = TI_STORE_STORE;
            rp.color[0].clear_r = 0.04; rp.color[0].clear_g = 0.04;
            rp.color[0].clear_b = 0.05; rp.color[0].clear_a = 1.0;
            rp.label = "present";

            TiPass *p = nullptr;
            if (ti_pass_begin(f, &rp, &p) != TI_OK) { ++errs; ti_frame_end(f, false); continue; }

            Push push = {}; push.z = 0.5f;
            push.color[0] = 0.35f + 0.45f * t;
            push.color[1] = 0.55f;
            push.color[2] = 0.95f - 0.35f * t;
            push.color[3] = 1.0f;

            ti_pass_set_pipeline(p, pipe);
            ti_pass_set_vertex_buffer(p, 0, vb, 0);
            ti_pass_set_vertex_bytes(p, 1, &push, sizeof push);
            ti_pass_set_fragment_bytes(p, 1, &push, sizeof push);
            ti_pass_draw_indexed(p, TI_PRIM_TRIANGLES, 6, TI_INDEX_U16, ib, 0, 1, 0);
            ti_pass_end(p);

            if (ti_frame_end(f, true) != TI_OK) ++errs;
            cpu.push_back(std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count());
        }
        ti_device_wait_idle(dev);

        printf("        presented %zu frames, %d drawable timeouts, %d errors\n",
               cpu.size(), lost, errs);
        check(errs == 0, "no frame errors while presenting");
        check(cpu.size() >= (size_t)(frames * 0.9), "at least 90% of frames presented");
        if (resizeChecked) check(resizeOk, "drawable size follows a live window resize");
        if (!cpu.empty()) {
            std::vector<double> s = cpu; std::sort(s.begin(), s.end());
            double sum = 0; for (double v : cpu) sum += v;
            printf("        wall time per presented frame: mean %.2f ms  p50 %.2f  p99 %.2f\n",
                   sum / cpu.size(), s[s.size()/2], s[(size_t)(s.size()*0.99)]);
            printf("        last GPU time: %.3f ms\n", ti_device_last_gpu_ms(dev));
            // With vsync on a 120 Hz panel, ~8.3 ms/frame is the floor.
            check(sum / cpu.size() > 1.0,
                  "vsync actually paces the loop (frames are not free-running)");
        }

        // ---- presentation controls ----------------------------------------
        printf("\n[3] presentation controls\n");
        check(ti_surface_set_vsync(surf, false) == TI_OK, "vsync can be disabled");
        check(ti_surface_set_vsync(surf, true) == TI_OK, "vsync can be re-enabled");
        check(ti_surface_set_max_fps(surf, 60) == TI_OK, "ProMotion frame cap accepted");
        check(ti_surface_set_max_fps(surf, 0) == TI_OK, "frame cap can be removed");
        check(ti_surface_handle_display_change(surf) == TI_OK, "display change handled");

        // ---- teardown ------------------------------------------------------
        printf("\n[4] teardown\n");
        ti_device_flush_pipeline_cache(dev);
        ti_pipeline_release(pipe);
        ti_library_release(lib);
        ti_buffer_release(ib);
        ti_buffer_release(vb);
        ti_surface_release(surf);
        ti_device_release(dev);
        [win close];
        check(true, "released surface and device without crashing");
    }

    printf("\n=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
