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
void      ti_set_error(const char *fmt, ...) __attribute__((format(printf,1,2)));
void      ti_log(TiLogLevel lvl, const char *fmt, ...) __attribute__((format(printf,2,3)));
TiResult  ti_fail(TiResult r, const char *fmt, ...) __attribute__((format(printf,2,3)));

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

    /* pipeline binary archive (optional, best-effort) */
    id<MTLBinaryArchive>     archive;
    std::mutex               archive_mtx;
    bool                     archive_dirty;

    TiCaps                   caps;

    /* last completed frame GPU time, milliseconds */
    std::atomic<double>      last_gpu_ms{-1.0};
};

struct TiSurface {
    TiObjHeader     hdr;
    TiDevice       *dev;
    CAMetalLayer   *layer;
    NSWindow       *window;
    uint32_t        max_fps;
    bool            vsync;
    TiPixelFormat   format;
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
};

struct TiPass {
    TiObjHeader                        hdr;
    TiFrame                           *frame;
    id<MTLRenderCommandEncoder>        enc;
};

#endif /* TITANIUM_TI_INTERNAL_H */
