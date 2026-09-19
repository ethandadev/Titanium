/* Titanium internal definitions. Not part of the public ABI. */
#ifndef TITANIUM_TI_INTERNAL_H
#define TITANIUM_TI_INTERNAL_H

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

@class NSWindow;   /* avoids dragging AppKit into every translation unit */
#include "titanium/ti_api.h"
#include <string>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <condition_variable>
#include <memory>
#include <vector>

/* ---- handle tagging -------------------------------------------------- */
#define TI_MAGIC_BASE 0x54490000u   /* 'TI' */
enum TiObjType {
    TI_T_DEVICE = 1, TI_T_SURFACE, TI_T_BUFFER, TI_T_TEXTURE, TI_T_SAMPLER,
    TI_T_LIBRARY, TI_T_PIPELINE, TI_T_DEPTHSTENCIL, TI_T_FRAME, TI_T_PASS
};
struct TiObjHeader { uint32_t magic; uint32_t type; };
#define TI_HDR_INIT(t) { TI_MAGIC_BASE | (uint32_t)(t), (uint32_t)(t) }

bool ti_validate(const void *h, TiObjType t);
#define TI_CHECK(h, t) do { if (!ti_validate((h), (t))) return TI_ERR_INVALID_HANDLE; } while (0)
#define TI_CHECK_NULL(h, t) do { if (!ti_validate((h), (t))) return NULL; } while (0)

/* ---- error / logging ------------------------------------------------- */
#include "ti_error.h"

/* ---- format helpers -------------------------------------------------- */
MTLPixelFormat ti_mtl_format(TiPixelFormat f);

/* ---- main-thread marshalling ---------------------------------------- */
void ti_main_sync(void (^block)(void));

/* ---- objects --------------------------------------------------------- */
struct TiDevice {
    TiObjHeader              hdr;
    id<MTLDevice>            mtl;
    id<MTLCommandQueue>      queue;
    dispatch_semaphore_t     frame_sem;
    uint32_t                 max_frames_in_flight;
    bool                     debug_labels;
    std::string              cache_dir;

    /* Pipeline binary archives. `lookup_archive` is last session's file, used
     * read-only to find precompiled pipelines. `archive` is a fresh archive
     * receiving exactly this session's pipelines; it replaces the file at
     * shutdown. (Adding to the loaded archive instead grew the file without
     * bound across sessions — 746 KB to 2.7 MB — and repacked stale entries.) */
    id<MTLBinaryArchive>     lookup_archive;
    id<MTLBinaryArchive>     archive;
    /* Time spent creating pipeline states, to measure what the cache buys. */
    std::atomic<uint64_t>    pso_count{0};
    std::atomic<uint64_t>    pso_ns{0};
    std::mutex               archive_mtx;
    bool                     archive_dirty;
    std::vector<std::string> archive_labels;   /* insertion order, for diagnostics */

    TiCaps                   caps;

    /* last completed frame GPU time, milliseconds */
    std::atomic<double>      last_gpu_ms{-1.0};

    /* Submission serials. One queue => command buffers complete in order, so
     * "completed" is a simple high-water mark. */
    std::atomic<uint64_t>    next_serial{1};
    std::mutex               serial_mtx;
    std::condition_variable  serial_cv;
    uint64_t                 committed_serial = 0;   /* guarded by serial_mtx */
    uint64_t                 completed_serial = 0;   /* guarded by serial_mtx */

    /* Titanium's own pipelines (flip-blit, rect clear), keyed by formats. */
    std::mutex                                                 internal_mtx;
    id<MTLLibrary>                                             internal_lib;
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>>   internal_pipes;
    id<MTLDepthStencilState>                                   ds_always_write;
    id<MTLSamplerState>                                        smp_nearest, smp_linear;

    /* MetalFX spatial scaler for world upscaling, recreated when the
     * configuration changes, plus an intermediate output when the caller's
     * destination lacks the usage MetalFX requires. */
    id                        fx_scaler;           /* id<MTLFXSpatialScaler> */
    uint64_t                  fx_key = 0;
    id<MTLTexture>            fx_intermediate;
    bool                      fx_logged = false;
};

struct TiSurface {
    TiObjHeader     hdr;
    TiDevice       *dev;
    CAMetalLayer   *layer;
    NSWindow       *window;
    uint32_t        max_fps;
    std::atomic<bool> vsync{true};
    TiPixelFormat   format;
    /* Drawables acquired and not yet presented on screen. Shared, because
     * presented-handlers run on a system thread and may outlive the surface. */
    std::shared_ptr<std::atomic<int>> drawables_in_use = std::make_shared<std::atomic<int>>(0);
    int             max_drawables = 3;
    std::atomic<uint64_t> presents{0}, skips{0};
};

struct TiBuffer {
    TiObjHeader   hdr;
    TiDevice     *dev;
    id<MTLBuffer> mtl;
    uint64_t      size;
    TiStorageMode mode;
};

struct TiTexture {
    TiObjHeader    hdr;
    TiDevice      *dev;
    id<MTLTexture> mtl;
    TiPixelFormat  format;
    TiStorageMode  mode;
    uint32_t       width, height;
};

struct TiSampler {
    TiObjHeader          hdr;
    id<MTLSamplerState>  mtl;
};

struct TiLibrary {
    TiObjHeader     hdr;
    TiDevice       *dev;
    id<MTLLibrary>  mtl;
};

struct TiPipeline {
    TiObjHeader                 hdr;
    id<MTLRenderPipelineState>  mtl;
};

struct TiDepthStencil {
    TiObjHeader               hdr;
    id<MTLDepthStencilState>  mtl;
};

struct TiFrame {
    TiObjHeader              hdr;
    TiDevice                *dev;
    TiSurface               *surface;       /* may be NULL (offscreen) */
    id<MTLCommandBuffer>     cmd;
    id<CAMetalDrawable>      drawable;      /* may be nil */
    bool                     semaphore_held;
    uint64_t                 serial;
    bool                     pass_open;     /* no blits while a pass is encoding */
};

/* Internal helpers shared between translation units. */
#define TI_NO_OP ((TiResult)1)   /* internal only: valid request that touches nothing */
TiResult ti_check_region(TiTexture *t, uint32_t mip, uint32_t slice,
                         uint32_t x, uint32_t y, uint32_t w, uint32_t h);
MTLVertexFormat ti_mtl_vertex_format(TiVertexFormat f);
id<MTLRenderPipelineState> ti_internal_pipeline(TiDevice *dev, const char *vs, const char *fs,
                                                MTLPixelFormat color, MTLPixelFormat depth);

struct TiPass {
    TiObjHeader                        hdr;
    TiFrame                           *frame;
    id<MTLRenderCommandEncoder>        enc;
};

#endif /* TITANIUM_TI_INTERNAL_H */
