/* Titanium — surface/swapchain, frame lifecycle, render passes, draws. */
#include "ti_internal.h"
#import <AppKit/AppKit.h>

/* ===================== surface ======================================= */

static void ti_surface_apply_screen(TiSurface *s) {
    /* Caller must be on the main thread. */
    NSScreen *screen = s->window.screen ?: NSScreen.mainScreen;
    if (!screen) return;
    CGFloat scale = screen.backingScaleFactor;
    if (s->layer.contentsScale != scale) {
        s->layer.contentsScale = scale;
        ti_log(TI_LOG_INFO, "surface contentsScale -> %.2f", (double)scale);
    }
}

TiResult ti_surface_create_for_nswindow(TiDevice *dev, const TiSurfaceDesc *d,
                                        TiSurface **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out || !d || !d->ns_window) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;

    MTLPixelFormat pf = ti_mtl_format(d->format);
    if (pf != MTLPixelFormatBGRA8Unorm && pf != MTLPixelFormatBGRA8Unorm_sRGB &&
        pf != MTLPixelFormatRGBA16Float)
        return ti_fail(TI_ERR_INVALID_ARGUMENT,
                       "surface format must be BGRA8 (optionally sRGB) or RGBA16Float");

    __block TiSurface *surf = nullptr;
    __block TiResult   rc   = TI_OK;

    ti_main_sync(^{
        @autoreleasepool {
            NSWindow *win = (__bridge NSWindow *)d->ns_window;
            if (![win isKindOfClass:NSWindow.class]) {
                rc = ti_fail(TI_ERR_INVALID_ARGUMENT, "ns_window is not an NSWindow");
                return;
            }
            NSView *view = win.contentView;
            if (!view) {
                rc = ti_fail(TI_ERR_INVALID_ARGUMENT, "window has no content view");
                return;
            }

            CAMetalLayer *layer = [CAMetalLayer layer];
            layer.device = dev->mtl;
            layer.pixelFormat = pf;
            layer.opaque = d->opaque;
            /* framebufferOnly keeps the drawable in a compressed, display-only
             * layout. Minecraft composites into its own render target and only
             * blits here, so nothing ever reads the drawable back. */
            layer.framebufferOnly = YES;
            layer.maximumDrawableCount = (dev->max_frames_in_flight >= 3) ? 3 : 2;
            layer.displaySyncEnabled = d->vsync;
            layer.allowsNextDrawableTimeout = YES;

            if (d->wants_extended_dynamic_range && pf == MTLPixelFormatRGBA16Float) {
                layer.wantsExtendedDynamicRangeContent = YES;
                layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
            }

            view.wantsLayer = YES;
            view.layer = layer;
            /* Redraw on resize rather than stretching the previous frame. */
            view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

            surf = new TiSurface();
            surf->hdr = TiObjHeader TI_HDR_INIT(TI_T_SURFACE);
            surf->dev = dev;
            surf->layer = layer;
            surf->window = win;
            surf->vsync = d->vsync;
            surf->max_fps = 0;
            surf->format = d->format;
            surf->max_drawables = (int)layer.maximumDrawableCount;

            if (d->drawable_scale > 0.0) layer.contentsScale = d->drawable_scale;
            else                          ti_surface_apply_screen(surf);

            CGSize px = view.bounds.size;
            px.width  *= layer.contentsScale;
            px.height *= layer.contentsScale;
            if (px.width < 1) px.width = 1;
            if (px.height < 1) px.height = 1;
            layer.drawableSize = px;

            ti_log(TI_LOG_INFO, "surface attached: %.0fx%.0f px, scale %.2f, vsync=%d",
                   px.width, px.height, (double)layer.contentsScale, d->vsync);
        }
    });

    if (rc != TI_OK) return rc;
    if (!surf)      return TI_ERR_INTERNAL;
    *out = surf;
    return TI_OK;
}

void ti_surface_release(TiSurface *s) {
    if (!ti_validate(s, TI_T_SURFACE)) return;
    ti_main_sync(^{
        s->layer = nil;
        s->window = nil;
    });
    s->hdr.magic = 0;
    delete s;
}

TiResult ti_surface_set_drawable_size(TiSurface *s, uint32_t w, uint32_t h) {
    TI_CHECK(s, TI_T_SURFACE);
    if (w == 0 || h == 0) return TI_ERR_INVALID_ARGUMENT;
    ti_main_sync(^{
        CGSize cur = s->layer.drawableSize;
        if ((uint32_t)cur.width != w || (uint32_t)cur.height != h) {
            s->layer.drawableSize = CGSizeMake(w, h);
            ti_log(TI_LOG_DEBUG, "drawable resized to %ux%u", w, h);
        }
    });
    return TI_OK;
}

void ti_surface_drawable_size(TiSurface *s, uint32_t *w, uint32_t *h) {
    if (!ti_validate(s, TI_T_SURFACE)) return;
    __block CGSize sz = CGSizeZero;
    ti_main_sync(^{ sz = s->layer.drawableSize; });
    if (w) *w = (uint32_t)sz.width;
    if (h) *h = (uint32_t)sz.height;
}

TiResult ti_surface_set_vsync(TiSurface *s, bool vsync) {
    TI_CHECK(s, TI_T_SURFACE);
    ti_main_sync(^{ s->layer.displaySyncEnabled = vsync; });
    s->vsync = vsync;
    return TI_OK;
}

TiResult ti_surface_set_max_fps(TiSurface *s, uint32_t fps) {
    TI_CHECK(s, TI_T_SURFACE);
    s->max_fps = fps;
    return TI_OK;
}

uint32_t ti_surface_display_refresh_hz(TiSurface *s) {
    if (!ti_validate(s, TI_T_SURFACE)) return 0;
    __block uint32_t hz = 60;
    ti_main_sync(^{
        if (@available(macOS 12.0, *)) {
            NSScreen *sc = s->window.screen ?: NSScreen.mainScreen;
            if (sc) hz = (uint32_t)sc.maximumFramesPerSecond;
        }
    });
    return hz;
}

TiResult ti_surface_handle_display_change(TiSurface *s) {
    TI_CHECK(s, TI_T_SURFACE);
    ti_main_sync(^{
        ti_surface_apply_screen(s);
        NSView *v = s->window.contentView;
        if (v) {
            CGSize px = v.bounds.size;
            px.width  *= s->layer.contentsScale;
            px.height *= s->layer.contentsScale;
            if (px.width >= 1 && px.height >= 1) s->layer.drawableSize = px;
        }
    });
    ti_log(TI_LOG_INFO, "display change handled; refresh now %u Hz",
           ti_surface_display_refresh_hz(s));
    return TI_OK;
}

/* ===================== frames ======================================== */

TiResult ti_frame_begin(TiDevice *dev, TiSurface *surface, TiFrame **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    if (surface && !ti_validate(surface, TI_T_SURFACE)) return TI_ERR_INVALID_HANDLE;

    /* Throttle the CPU to max_frames_in_flight frames ahead of the GPU. The
     * non-blocking probe keeps the uncontended path free of clock reads. */
    if (dispatch_semaphore_wait(dev->frame_sem, DISPATCH_TIME_NOW) != 0) {
        uint64_t t0 = ti_mono_ns();
        dispatch_semaphore_wait(dev->frame_sem, DISPATCH_TIME_FOREVER);
        dev->frame_waits.fetch_add(1, std::memory_order_relaxed);
        dev->frame_wait_ns.fetch_add(ti_mono_ns() - t0, std::memory_order_relaxed);
    }

    @autoreleasepool {
        id<MTLCommandBuffer> cb = [dev->queue commandBuffer];
        if (!cb) {
            dispatch_semaphore_signal(dev->frame_sem);
            return ti_fail(TI_ERR_INTERNAL, "commandBuffer allocation failed");
        }
        cb.label = @"Titanium.frame";

        id<CAMetalDrawable> drawable = nil;
        if (surface) {
            uint64_t t0 = ti_mono_ns();
            drawable = [surface->layer nextDrawable];
            dev->drawable_waits.fetch_add(1, std::memory_order_relaxed);
            dev->drawable_wait_ns.fetch_add(ti_mono_ns() - t0, std::memory_order_relaxed);
            if (!drawable) {
                /* Timed out — the window is occluded, minimised, or the
                 * display reconfigured. Give the token back so we cannot
                 * deadlock, and let the caller skip the frame. */
                dispatch_semaphore_signal(dev->frame_sem);
                return ti_fail(TI_ERR_SURFACE_LOST, "nextDrawable timed out");
            }
        }

        TiFrame *f = new TiFrame();
        f->hdr = TiObjHeader TI_HDR_INIT(TI_T_FRAME);
        f->dev = dev; f->surface = surface; f->cmd = cb;
        f->drawable = drawable; f->semaphore_held = true;
        f->serial = dev->next_serial.fetch_add(1);
        f->pass_open = false;
        *out = f;
        return TI_OK;
    }
}

static TiResult ti_frame_finish(TiFrame *f, bool present, bool wait) {
    TI_CHECK(f, TI_T_FRAME);
    TiDevice *dev = f->dev;
    if (f->pass_open)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "frame ended with a render pass still open");
    @autoreleasepool {
        id<MTLCommandBuffer> cb = f->cmd;

        if (present && f->drawable) {
            uint32_t fps = f->surface ? f->surface->max_fps : 0;
            if (fps > 0) {
                /* Frame pacing for variable-refresh (ProMotion) displays:
                 * ask the compositor to hold the frame for at least one
                 * interval instead of spinning the GPU faster than needed. */
                [cb presentDrawable:f->drawable afterMinimumDuration:1.0 / (double)fps];
            } else {
                [cb presentDrawable:f->drawable];
            }
        }

        /* Release the in-flight token and record GPU time from the driver's
         * own timestamps — not a CPU-side estimate. */
        dispatch_semaphore_t sem = dev->frame_sem;
        std::atomic<double> *slot = &dev->last_gpu_ms;
        const uint64_t serial = f->serial;
        TiProfPending *prof = ti_profile_take(f);
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            CFTimeInterval gpu = done.GPUEndTime - done.GPUStartTime;
            slot->store(gpu * 1000.0, std::memory_order_relaxed);
            if (prof) ti_profile_complete(dev, prof);
            {
                /* Notify under the lock: once a waiter (e.g. device release)
                 * sees this serial, this handler no longer touches `dev`. */
                std::lock_guard<std::mutex> lk(dev->serial_mtx);
                if (serial > dev->completed_serial) dev->completed_serial = serial;
                dev->serial_cv.notify_all();
            }
            dispatch_semaphore_signal(sem);
        }];
        f->semaphore_held = false;

        {
            std::lock_guard<std::mutex> lk(dev->serial_mtx);
            if (serial > dev->committed_serial) dev->committed_serial = serial;
        }
        [cb commit];
        if (wait) {
            [cb waitUntilCompleted];
            if (cb.error) {
                TiResult r = ti_fail(TI_ERR_INTERNAL, "frame failed on GPU: %s",
                                     cb.error.localizedDescription.UTF8String ?: "?");
                f->hdr.magic = 0; f->cmd = nil; f->drawable = nil; delete f;
                return r;
            }
        }

        f->hdr.magic = 0;
        f->cmd = nil;
        f->drawable = nil;
        delete f;
        return TI_OK;
    }
}

TiResult ti_frame_end(TiFrame *f, bool present)          { return ti_frame_finish(f, present, false); }
TiResult ti_frame_end_and_wait(TiFrame *f, bool present) { return ti_frame_finish(f, present, true);  }

/* ===================== render passes ================================= */

static MTLLoadAction ti_load(TiLoadAction a) {
    switch (a) {
        case TI_LOAD_LOAD:  return MTLLoadActionLoad;
        case TI_LOAD_CLEAR: return MTLLoadActionClear;
        default:            return MTLLoadActionDontCare;
    }
}
static MTLStoreAction ti_store(TiStoreAction a) {
    switch (a) {
        case TI_STORE_STORE:   return MTLStoreActionStore;
        case TI_STORE_RESOLVE: return MTLStoreActionMultisampleResolve;
        default:               return MTLStoreActionDontCare;
    }
}

TiResult ti_pass_begin(TiFrame *f, const TiRenderPassDesc *d, TiPass **out) {
    TI_CHECK(f, TI_T_FRAME);
    if (!out || !d) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    if (f->pass_open)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "a render pass is already open on this frame");

    @autoreleasepool {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];

        for (uint32_t i = 0; i < d->color_count && i < 8; ++i) {
            const TiColorAttachment *a = &d->color[i];
            id<MTLTexture> tex = nil;
            bool memoryless = false;

            if (a->use_drawable) {
                if (!f->drawable)
                    return ti_fail(TI_ERR_INVALID_ARGUMENT,
                                   "attachment %u wants the drawable but this frame has none", i);
                tex = f->drawable.texture;
            } else {
                if (!ti_validate(a->texture, TI_T_TEXTURE)) return TI_ERR_INVALID_HANDLE;
                tex = a->texture->mtl;
                memoryless = (a->texture->mode == TI_STORAGE_MEMORYLESS);
            }

            MTLRenderPassColorAttachmentDescriptor *ca = rp.colorAttachments[i];
            ca.texture = tex;
            ca.level = a->level;
            ca.slice = a->slice;
            ca.loadAction = ti_load(a->load);
            /* A memoryless attachment has no backing store to write to;
             * storing it is invalid, so force DontCare rather than letting
             * Metal's validation layer abort the process. */
            ca.storeAction = memoryless ? MTLStoreActionDontCare : ti_store(a->store);
            ca.clearColor = MTLClearColorMake(a->clear_r, a->clear_g, a->clear_b, a->clear_a);

            if (a->store == TI_STORE_RESOLVE) {
                if (!ti_validate(a->resolve_texture, TI_T_TEXTURE)) return TI_ERR_INVALID_HANDLE;
                ca.resolveTexture = a->resolve_texture->mtl;
            }
        }

        if (d->has_depth) {
            if (!ti_validate(d->depth.texture, TI_T_TEXTURE)) return TI_ERR_INVALID_HANDLE;
            bool memoryless = (d->depth.texture->mode == TI_STORAGE_MEMORYLESS);
            MTLRenderPassDepthAttachmentDescriptor *da = rp.depthAttachment;
            da.texture = d->depth.texture->mtl;
            da.loadAction = ti_load(d->depth.load);
            da.storeAction = memoryless ? MTLStoreActionDontCare : ti_store(d->depth.store);
            da.clearDepth = d->depth.clear_depth;
        }

        ti_profile_attach(f, rp, d->label);
        id<MTLRenderCommandEncoder> enc = [f->cmd renderCommandEncoderWithDescriptor:rp];
        if (!enc) return ti_fail(TI_ERR_INTERNAL, "renderCommandEncoderWithDescriptor failed");
        if (d->label) enc.label = [NSString stringWithUTF8String:d->label];

        TiPass *p = new TiPass();
        p->hdr = TiObjHeader TI_HDR_INIT(TI_T_PASS);
        p->frame = f; p->enc = enc;
        f->pass_open = true;
        *out = p;
        return TI_OK;
    }
}

TiResult ti_pass_end(TiPass *p) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc endEncoding];
    if (ti_validate(p->frame, TI_T_FRAME)) p->frame->pass_open = false;
    p->hdr.magic = 0;
    p->enc = nil;
    delete p;
    return TI_OK;
}

/* ===================== pass state ==================================== */

TiResult ti_pass_set_pipeline(TiPass *p, TiPipeline *pipe) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(pipe, TI_T_PIPELINE);
    [p->enc setRenderPipelineState:pipe->mtl];
    return TI_OK;
}

TiResult ti_pass_set_depth_stencil(TiPass *p, TiDepthStencil *ds) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(ds, TI_T_DEPTHSTENCIL);
    [p->enc setDepthStencilState:ds->mtl];
    return TI_OK;
}

TiResult ti_pass_set_viewport(TiPass *p, double x, double y, double w, double h,
                              double znear, double zfar) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc setViewport:(MTLViewport){x, y, w, h, znear, zfar}];
    return TI_OK;
}

TiResult ti_pass_set_scissor(TiPass *p, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc setScissorRect:(MTLScissorRect){x, y, w, h}];
    return TI_OK;
}

TiResult ti_pass_set_cull_mode(TiPass *p, int32_t mode) {
    TI_CHECK(p, TI_T_PASS);
    MTLCullMode m = MTLCullModeNone;
    if (mode == 1) m = MTLCullModeFront;
    else if (mode == 2) m = MTLCullModeBack;
    [p->enc setCullMode:m];
    return TI_OK;
}

TiResult ti_pass_set_front_face_ccw(TiPass *p, bool ccw) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc setFrontFacingWinding:ccw ? MTLWindingCounterClockwise : MTLWindingClockwise];
    return TI_OK;
}

TiResult ti_pass_set_blend_color(TiPass *p, double r, double g, double b, double a) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc setBlendColorRed:r green:g blue:b alpha:a];
    return TI_OK;
}

TiResult ti_pass_set_depth_bias(TiPass *p, float constant, float slope, float clamp) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc setDepthBias:constant slopeScale:slope clamp:clamp];
    return TI_OK;
}

TiResult ti_pass_set_wireframe(TiPass *p, bool wireframe) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc setTriangleFillMode:wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    return TI_OK;
}

TiResult ti_pass_push_debug_group(TiPass *p, const char *label) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc pushDebugGroup:[NSString stringWithUTF8String:(label ?: "?")]];
    return TI_OK;
}

TiResult ti_pass_pop_debug_group(TiPass *p) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc popDebugGroup];
    return TI_OK;
}

TiResult ti_pass_set_vertex_buffer(TiPass *p, uint32_t index, TiBuffer *b, uint64_t offset) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(b, TI_T_BUFFER);
    [p->enc setVertexBuffer:b->mtl offset:offset atIndex:index];
    return TI_OK;
}

TiResult ti_pass_set_fragment_buffer(TiPass *p, uint32_t index, TiBuffer *b, uint64_t offset) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(b, TI_T_BUFFER);
    [p->enc setFragmentBuffer:b->mtl offset:offset atIndex:index];
    return TI_OK;
}

TiResult ti_pass_set_vertex_bytes(TiPass *p, uint32_t index, const void *data, uint32_t size) {
    TI_CHECK(p, TI_T_PASS);
    if (!data || size == 0 || size > 4096) return TI_ERR_INVALID_ARGUMENT;
    [p->enc setVertexBytes:data length:size atIndex:index];
    return TI_OK;
}

TiResult ti_pass_set_fragment_bytes(TiPass *p, uint32_t index, const void *data, uint32_t size) {
    TI_CHECK(p, TI_T_PASS);
    if (!data || size == 0 || size > 4096) return TI_ERR_INVALID_ARGUMENT;
    [p->enc setFragmentBytes:data length:size atIndex:index];
    return TI_OK;
}

TiResult ti_pass_set_fragment_texture(TiPass *p, uint32_t index, TiTexture *t) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(t, TI_T_TEXTURE);
    [p->enc setFragmentTexture:t->mtl atIndex:index];
    return TI_OK;
}

TiResult ti_pass_set_vertex_texture(TiPass *p, uint32_t index, TiTexture *t) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(t, TI_T_TEXTURE);
    [p->enc setVertexTexture:t->mtl atIndex:index];
    return TI_OK;
}

TiResult ti_pass_set_vertex_sampler(TiPass *p, uint32_t index, TiSampler *s) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(s, TI_T_SAMPLER);
    [p->enc setVertexSamplerState:s->mtl atIndex:index];
    return TI_OK;
}

TiResult ti_pass_set_fragment_sampler(TiPass *p, uint32_t index, TiSampler *s) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(s, TI_T_SAMPLER);
    [p->enc setFragmentSamplerState:s->mtl atIndex:index];
    return TI_OK;
}

/* ===================== draws ========================================= */

static MTLPrimitiveType ti_prim(TiPrimitive p) {
    switch (p) {
        case TI_PRIM_TRIANGLE_STRIP: return MTLPrimitiveTypeTriangleStrip;
        case TI_PRIM_LINES:          return MTLPrimitiveTypeLine;
        case TI_PRIM_POINTS:         return MTLPrimitiveTypePoint;
        case TI_PRIM_LINE_STRIP:     return MTLPrimitiveTypeLineStrip;
        default:                     return MTLPrimitiveTypeTriangle;
    }
}

TiResult ti_pass_draw(TiPass *p, TiPrimitive prim, uint32_t first, uint32_t count,
                      uint32_t instances) {
    TI_CHECK(p, TI_T_PASS);
    if (count == 0) return TI_OK;
    [p->enc drawPrimitives:ti_prim(prim)
               vertexStart:first
               vertexCount:count
             instanceCount:instances ? instances : 1];
    return TI_OK;
}

TiResult ti_pass_draw_indexed(TiPass *p, TiPrimitive prim, uint32_t index_count,
                              TiIndexType type, TiBuffer *ib, uint64_t ib_offset,
                              uint32_t instances, int32_t base_vertex) {
    TI_CHECK(p, TI_T_PASS);
    TI_CHECK(ib, TI_T_BUFFER);
    if (index_count == 0) return TI_OK;
    [p->enc drawIndexedPrimitives:ti_prim(prim)
                       indexCount:index_count
                        indexType:(type == TI_INDEX_U32) ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
                      indexBuffer:ib->mtl
                indexBufferOffset:ib_offset
                    instanceCount:instances ? instances : 1
                       baseVertex:base_vertex
                     baseInstance:0];
    return TI_OK;
}

TiResult ti_pass_draw_indexed_stream(TiPass *p, TiPrimitive prim, uint32_t vertex_slot,
                                     const int64_t *s, size_t len, uint32_t draw_count) {
    TI_CHECK(p, TI_T_PASS);
    if (draw_count && !s) return TI_ERR_INVALID_ARGUMENT;
    if (vertex_slot > 30) return ti_fail(TI_ERR_INVALID_ARGUMENT, "vertex slot %u out of range", vertex_slot);
    id<MTLRenderCommandEncoder> enc = p->enc;
    const MTLPrimitiveType mp = ti_prim(prim);
    /* What this call has bound. Unretained: every buffer is kept alive by its
     * TiBuffer for the duration of the call, and this avoids ARC traffic in
     * the hottest loop in the backend. */
    __unsafe_unretained id<MTLBuffer> vb_bound = nil;
    __unsafe_unretained id<MTLBuffer> bound[2][31] = {};
    uint64_t bound_off[2][31];
    size_t i = 0;
    for (uint32_t d = 0; d < draw_count; ++d) {
        if (len - i < 5 || i > len)
            return ti_fail(TI_ERR_INVALID_ARGUMENT, "draw stream truncated in record %u", d);
        TiBuffer *vb = (TiBuffer *)(uintptr_t)s[i];
        TiBuffer *ib = (TiBuffer *)(uintptr_t)s[i + 1];
        const uint64_t ib_off = (uint64_t)s[i + 2];
        const uint64_t ci = (uint64_t)s[i + 3];
        const uint64_t nb = (uint64_t)s[i + 4];
        i += 5;
        if (nb > 62 || len - i < nb * 3)
            return ti_fail(TI_ERR_INVALID_ARGUMENT, "draw stream record %u: bad bind count %llu", d,
                           (unsigned long long)nb);
        for (uint64_t k = 0; k < nb; ++k, i += 3) {
            const uint32_t stages = (uint32_t)((uint64_t)s[i] >> 32), slot = (uint32_t)s[i];
            TiBuffer *b = (TiBuffer *)(uintptr_t)s[i + 1];
            const uint64_t off = (uint64_t)s[i + 2];
            if (slot > 30 || ((stages & 1) && slot == vertex_slot))
                return ti_fail(TI_ERR_INVALID_ARGUMENT, "draw stream record %u: bind slot %u invalid", d, slot);
            if (!ti_validate(b, TI_T_BUFFER)) return TI_ERR_INVALID_HANDLE;
            __unsafe_unretained id<MTLBuffer> mb = b->mtl;
            if (stages & 1) {
                if (bound[0][slot] != mb) { [enc setVertexBuffer:mb offset:off atIndex:slot]; bound[0][slot] = mb; bound_off[0][slot] = off; }
                else if (bound_off[0][slot] != off) { [enc setVertexBufferOffset:off atIndex:slot]; bound_off[0][slot] = off; }
            }
            if (stages & 2) {
                if (bound[1][slot] != mb) { [enc setFragmentBuffer:mb offset:off atIndex:slot]; bound[1][slot] = mb; bound_off[1][slot] = off; }
                else if (bound_off[1][slot] != off) { [enc setFragmentBufferOffset:off atIndex:slot]; bound_off[1][slot] = off; }
            }
        }
        if (vb) {
            if (!ti_validate(vb, TI_T_BUFFER)) return TI_ERR_INVALID_HANDLE;
            __unsafe_unretained id<MTLBuffer> mv = vb->mtl;
            if (mv != vb_bound) { [enc setVertexBuffer:mv offset:0 atIndex:vertex_slot]; vb_bound = mv; }
        }
        if (!ti_validate(ib, TI_T_BUFFER)) return TI_ERR_INVALID_HANDLE;
        const uint32_t count = (uint32_t)ci;
        if (count == 0) continue;
        [enc drawIndexedPrimitives:mp
                        indexCount:count
                         indexType:(ci >> 32) == TI_INDEX_U32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
                       indexBuffer:ib->mtl
                 indexBufferOffset:ib_off
                     instanceCount:1
                        baseVertex:0
                      baseInstance:0];
    }
    if (i != len) return ti_fail(TI_ERR_INVALID_ARGUMENT, "draw stream has %zu trailing words", len - i);
    return TI_OK;
}

/* ===================== frame-ordered transfer operations ============ */

static TiResult ti_frame_blit_ready(TiFrame *f) {
    if (!ti_validate(f, TI_T_FRAME)) return TI_ERR_INVALID_HANDLE;
    if (f->pass_open)
        return ti_fail(TI_ERR_INVALID_ARGUMENT,
                       "transfer requested while a render pass is open (Minecraft forbids "
                       "this too; the caller has a bug)");
    return TI_OK;
}

uint64_t ti_frame_serial(TiFrame *f) {
    return ti_validate(f, TI_T_FRAME) ? f->serial : 0;
}

TiResult ti_frame_upload_buffer(TiFrame *f, TiBuffer *dst, uint64_t offset,
                                const void *src, uint64_t size) {
    TiResult r = ti_frame_blit_ready(f); if (r != TI_OK) return r;
    TI_CHECK(dst, TI_T_BUFFER);
    if (!src) return TI_ERR_INVALID_ARGUMENT;
    if (size == 0) return TI_OK;
    if (offset + size > dst->size)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "upload exceeds buffer size");
    @autoreleasepool {
        /* The staging buffer is referenced by the command buffer, which retains
         * it until the GPU is done: no lifetime bookkeeping needed here. */
        id<MTLBuffer> staging = [f->dev->mtl newBufferWithBytes:src length:(NSUInteger)size
                                                        options:MTLResourceStorageModeShared];
        if (!staging) return ti_fail(TI_ERR_OUT_OF_MEMORY, "staging allocation failed");
        id<MTLBlitCommandEncoder> b = [f->cmd blitCommandEncoder];
        [b copyFromBuffer:staging sourceOffset:0 toBuffer:dst->mtl
        destinationOffset:(NSUInteger)offset size:(NSUInteger)size];
        [b endEncoding];
        return TI_OK;
    }
}

TiResult ti_frame_upload_texture(TiFrame *f, TiTexture *dst, uint32_t mip, uint32_t slice,
                                 uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                                 const void *src, uint32_t src_row_bytes) {
    TiResult r = ti_frame_blit_ready(f); if (r != TI_OK) return r;
    TI_CHECK(dst, TI_T_TEXTURE);
    if (!src) return TI_ERR_INVALID_ARGUMENT;
    { TiResult rr = ti_check_region(dst, mip, slice, x, y, w, h); if (rr == TI_NO_OP) return TI_OK; if (rr != TI_OK) return rr; }
    @autoreleasepool {
        NSUInteger total = (NSUInteger)src_row_bytes * h;
        id<MTLBuffer> staging = [f->dev->mtl newBufferWithBytes:src length:total
                                                        options:MTLResourceStorageModeShared];
        if (!staging) return ti_fail(TI_ERR_OUT_OF_MEMORY, "staging allocation failed");
        id<MTLBlitCommandEncoder> b = [f->cmd blitCommandEncoder];
        [b copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:src_row_bytes
        sourceBytesPerImage:total sourceSize:MTLSizeMake(w, h, 1)
                 toTexture:dst->mtl destinationSlice:slice destinationLevel:mip
         destinationOrigin:MTLOriginMake(x, y, 0)];
        [b endEncoding];
        return TI_OK;
    }
}

TiResult ti_frame_copy_buffer(TiFrame *f, TiBuffer *src, uint64_t src_off,
                              TiBuffer *dst, uint64_t dst_off, uint64_t size) {
    TiResult r = ti_frame_blit_ready(f); if (r != TI_OK) return r;
    TI_CHECK(src, TI_T_BUFFER); TI_CHECK(dst, TI_T_BUFFER);
    if (src_off + size > src->size || dst_off + size > dst->size)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "buffer copy out of range");
    if (size == 0) return TI_OK;
    id<MTLBlitCommandEncoder> b = [f->cmd blitCommandEncoder];
    [b copyFromBuffer:src->mtl sourceOffset:(NSUInteger)src_off toBuffer:dst->mtl
    destinationOffset:(NSUInteger)dst_off size:(NSUInteger)size];
    [b endEncoding];
    return TI_OK;
}

TiResult ti_frame_copy_texture_to_buffer(TiFrame *f, TiTexture *src, uint32_t mip,
                                         uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                                         TiBuffer *dst, uint64_t dst_off, uint32_t row_bytes) {
    TiResult r = ti_frame_blit_ready(f); if (r != TI_OK) return r;
    TI_CHECK(src, TI_T_TEXTURE); TI_CHECK(dst, TI_T_BUFFER);
    { TiResult rr = ti_check_region(src, mip, 0, x, y, w, h); if (rr == TI_NO_OP) return TI_OK; if (rr != TI_OK) return rr; }
    if (dst_off + (uint64_t)row_bytes * h > dst->size)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "texture-to-buffer copy exceeds buffer");
    id<MTLBlitCommandEncoder> b = [f->cmd blitCommandEncoder];
    [b copyFromTexture:src->mtl sourceSlice:0 sourceLevel:mip sourceOrigin:MTLOriginMake(x, y, 0)
            sourceSize:MTLSizeMake(w, h, 1) toBuffer:dst->mtl
     destinationOffset:(NSUInteger)dst_off destinationBytesPerRow:row_bytes
destinationBytesPerImage:(NSUInteger)row_bytes * h];
    [b endEncoding];
    return TI_OK;
}

TiResult ti_frame_copy_texture(TiFrame *f, TiTexture *src, uint32_t src_mip,
                               uint32_t sx, uint32_t sy, TiTexture *dst, uint32_t dst_mip,
                               uint32_t dx, uint32_t dy, uint32_t w, uint32_t h) {
    TiResult r = ti_frame_blit_ready(f); if (r != TI_OK) return r;
    TI_CHECK(src, TI_T_TEXTURE); TI_CHECK(dst, TI_T_TEXTURE);
    if (src->mtl.pixelFormat != dst->mtl.pixelFormat)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "texture copy between different formats");
    { TiResult rr = ti_check_region(src, src_mip, 0, sx, sy, w, h); if (rr == TI_NO_OP) return TI_OK; if (rr != TI_OK) return rr; }
    { TiResult rr = ti_check_region(dst, dst_mip, 0, dx, dy, w, h); if (rr == TI_NO_OP) return TI_OK; if (rr != TI_OK) return rr; }
    id<MTLBlitCommandEncoder> b = [f->cmd blitCommandEncoder];
    [b copyFromTexture:src->mtl sourceSlice:0 sourceLevel:src_mip
          sourceOrigin:MTLOriginMake(sx, sy, 0) sourceSize:MTLSizeMake(w, h, 1)
             toTexture:dst->mtl destinationSlice:0 destinationLevel:dst_mip
     destinationOrigin:MTLOriginMake(dx, dy, 0)];
    [b endEncoding];
    return TI_OK;
}

TiResult ti_frame_generate_mipmaps(TiFrame *f, TiTexture *t) {
    TiResult r = ti_frame_blit_ready(f); if (r != TI_OK) return r;
    TI_CHECK(t, TI_T_TEXTURE);
    if (t->mtl.mipmapLevelCount <= 1) return TI_OK;
    id<MTLBlitCommandEncoder> b = [f->cmd blitCommandEncoder];
    [b generateMipmapsForTexture:t->mtl];
    [b endEncoding];
    return TI_OK;
}

TiResult ti_frame_clear(TiFrame *f, TiTexture *color, bool clear_color,
                        double r_, double g, double b, double a,
                        TiTexture *depth, bool clear_depth, double depth_value,
                        bool has_rect, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    TiResult r = ti_frame_blit_ready(f); if (r != TI_OK) return r;
    if (color && !ti_validate(color, TI_T_TEXTURE)) return TI_ERR_INVALID_HANDLE;
    if (depth && !ti_validate(depth, TI_T_TEXTURE)) return TI_ERR_INVALID_HANDLE;
    if (!color && !depth) return TI_ERR_INVALID_ARGUMENT;
    TiTexture *ref = color ? color : depth;

    /* A rect covering the whole target is just a full clear. */
    if (has_rect && x == 0 && y == 0 && w >= ref->width && h >= ref->height) has_rect = false;

    @autoreleasepool {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        if (color) {
            rp.colorAttachments[0].texture = color->mtl;
            rp.colorAttachments[0].loadAction =
                (clear_color && !has_rect) ? MTLLoadActionClear : MTLLoadActionLoad;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(r_, g, b, a);
        }
        if (depth) {
            rp.depthAttachment.texture = depth->mtl;
            rp.depthAttachment.loadAction =
                (clear_depth && !has_rect) ? MTLLoadActionClear : MTLLoadActionLoad;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.depthAttachment.clearDepth = depth_value;
        }
        ti_profile_attach(f, rp, "Titanium.clear");
        id<MTLRenderCommandEncoder> enc = [f->cmd renderCommandEncoderWithDescriptor:rp];
        if (!enc) return ti_fail(TI_ERR_INTERNAL, "clear encoder creation failed");
        enc.label = @"Titanium.clear";

        if (has_rect) {
            /* Scissored draw. Rect is in GL window coords; render targets keep
             * GL's memory layout, so GL's y maps straight onto Metal rows. */
            MTLPixelFormat cf = color ? color->mtl.pixelFormat : MTLPixelFormatInvalid;
            MTLPixelFormat df = depth ? depth->mtl.pixelFormat : MTLPixelFormatInvalid;
            id<MTLRenderPipelineState> ps =
                ti_internal_pipeline(f->dev, "ti_clear_vs", "ti_clear_fs", cf, df);
            if (!ps) { [enc endEncoding]; return TI_ERR_PIPELINE_CREATE; }
            uint32_t cx = x < ref->width ? x : ref->width;
            uint32_t cy = y < ref->height ? y : ref->height;
            uint32_t cw = (cx + w > ref->width) ? ref->width - cx : w;
            uint32_t ch = (cy + h > ref->height) ? ref->height - cy : h;
            if (cw && ch) {
                struct { float c[4]; float d; float pad[3]; } p =
                    { { (float)r_, (float)g, (float)b, (float)a }, (float)depth_value, {0,0,0} };
                [enc setRenderPipelineState:ps];
                if (depth && clear_depth) [enc setDepthStencilState:f->dev->ds_always_write];
                [enc setScissorRect:(MTLScissorRect){ cx, cy, cw, ch }];
                [enc setVertexBytes:&p length:sizeof p atIndex:0];
                [enc setFragmentBytes:&p length:sizeof p atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
        }
        [enc endEncoding];
        return TI_OK;
    }
}

TiResult ti_frame_blit_flipped(TiFrame *f, TiTexture *src, TiTexture *dst, TiSurface *surface) {
    TiResult r = ti_frame_blit_ready(f); if (r != TI_OK) return r;
    TI_CHECK(src, TI_T_TEXTURE);
    id<MTLTexture> target = nil;
    if (dst) {
        TI_CHECK(dst, TI_T_TEXTURE);
        target = dst->mtl;
    } else {
        TI_CHECK(surface, TI_T_SURFACE);
        if (!f->drawable) {
            /* vsync off: never block on the compositor. If every drawable is
             * still out, skip presenting this frame (it was fully rendered).
             * One drawable is held back as headroom because a drawable returns
             * to the pool a little after its presented-handler fires. */
            if (!surface->vsync.load() &&
                surface->drawables_in_use->load() >= surface->max_drawables - 1) {
                surface->skips.fetch_add(1);
                return TI_SKIPPED_PRESENT;
            }
            /* Late acquisition: the drawable is taken only now, at present
             * time, so the swapchain pool is not held across the whole frame. */
            uint64_t t0 = ti_mono_ns();
            f->drawable = [surface->layer nextDrawable];
            f->dev->drawable_waits.fetch_add(1, std::memory_order_relaxed);
            f->dev->drawable_wait_ns.fetch_add(ti_mono_ns() - t0, std::memory_order_relaxed);
            if (!f->drawable) return ti_fail(TI_ERR_SURFACE_LOST, "nextDrawable timed out");
            f->surface = surface;
            surface->drawables_in_use->fetch_add(1);
            std::shared_ptr<std::atomic<int>> counter = surface->drawables_in_use;   /* copied into the block */
            [f->drawable addPresentedHandler:^(id<MTLDrawable> d) { counter->fetch_sub(1); }];
            surface->presents.fetch_add(1);
        }
        target = f->drawable.texture;
    }
    @autoreleasepool {
        id<MTLRenderPipelineState> ps = ti_internal_pipeline(
            f->dev, "ti_blit_flip_vs", "ti_blit_fs", target.pixelFormat, MTLPixelFormatInvalid);
        if (!ps) return TI_ERR_PIPELINE_CREATE;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;   /* fully overwritten */
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        ti_profile_attach(f, rp, "Titanium.present");
        id<MTLRenderCommandEncoder> enc = [f->cmd renderCommandEncoderWithDescriptor:rp];
        enc.label = @"Titanium.present";
        [enc setRenderPipelineState:ps];
        [enc setFragmentTexture:src->mtl atIndex:0];
        bool same = (src->mtl.width == target.width && src->mtl.height == target.height);
        [enc setFragmentSamplerState:same ? f->dev->smp_nearest : f->dev->smp_linear atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        return TI_OK;
    }
}
