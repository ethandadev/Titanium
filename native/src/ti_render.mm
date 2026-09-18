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

    /* Throttle the CPU to max_frames_in_flight frames ahead of the GPU. */
    dispatch_semaphore_wait(dev->frame_sem, DISPATCH_TIME_FOREVER);

    @autoreleasepool {
        id<MTLCommandBuffer> cb = [dev->queue commandBuffer];
        if (!cb) {
            dispatch_semaphore_signal(dev->frame_sem);
            return ti_fail(TI_ERR_INTERNAL, "commandBuffer allocation failed");
        }
        cb.label = @"Titanium.frame";

        id<CAMetalDrawable> drawable = nil;
        if (surface) {
            drawable = [surface->layer nextDrawable];
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
        *out = f;
        return TI_OK;
    }
}

static TiResult ti_frame_finish(TiFrame *f, bool present, bool wait) {
    TI_CHECK(f, TI_T_FRAME);
    TiDevice *dev = f->dev;
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
        __block std::atomic<double> *slot = &dev->last_gpu_ms;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            CFTimeInterval gpu = done.GPUEndTime - done.GPUStartTime;
            slot->store(gpu * 1000.0, std::memory_order_relaxed);
            dispatch_semaphore_signal(sem);
        }];
        f->semaphore_held = false;

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

        id<MTLRenderCommandEncoder> enc = [f->cmd renderCommandEncoderWithDescriptor:rp];
        if (!enc) return ti_fail(TI_ERR_INTERNAL, "renderCommandEncoderWithDescriptor failed");
        if (d->label) enc.label = [NSString stringWithUTF8String:d->label];

        TiPass *p = new TiPass();
        p->hdr = TiObjHeader TI_HDR_INIT(TI_T_PASS);
        p->frame = f; p->enc = enc;
        *out = p;
        return TI_OK;
    }
}

TiResult ti_pass_end(TiPass *p) {
    TI_CHECK(p, TI_T_PASS);
    [p->enc endEncoding];
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
