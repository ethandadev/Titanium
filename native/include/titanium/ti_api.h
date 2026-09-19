/*
 * Titanium — native Metal backend for Minecraft: Java Edition
 * Public C ABI. Deliberately C-only (no C++/ObjC types) so that the same
 * surface can be bound from JNI today and from java.lang.foreign (FFM)
 * on a JDK 22+ runtime later without changing the native side.
 *
 * Threading contract
 * ------------------
 *  - A TiDevice may be created from any thread, once per process.
 *  - A TiSurface must be created and resized on the main (AppKit) thread.
 *    ti_surface_create_for_nswindow() and ti_surface_set_drawable_size()
 *    marshal to the main thread internally, so callers on Minecraft's render
 *    thread are safe.
 *  - Encoding (ti_pass_*, ti_frame_*) is single-threaded per TiFrame.
 *  - Resource creation is thread-safe.
 *
 * Ownership
 * ---------
 *  Every ti_*_create() returns a handle owned by the caller and released with
 *  the matching ti_*_release(). Handles are pointers to tagged control blocks;
 *  passing a stale or foreign pointer is detected in debug builds (TI_DEBUG)
 *  and reported as TI_ERR_INVALID_HANDLE rather than crashing.
 */
#ifndef TITANIUM_TI_API_H
#define TITANIUM_TI_API_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#if defined(__cplusplus)
extern "C" {
#endif

#if defined(__GNUC__)
#  define TI_EXPORT __attribute__((visibility("default")))
#else
#  define TI_EXPORT
#endif

#define TI_API_VERSION_MAJOR 0
/* 0.2: TiPipelineDesc.fragment_library, TiTextureDesc.cube, frame-ordered
 * transfers, serials, translation, texel buffers, vertex samplers. */
#define TI_API_VERSION_MINOR 3

/* ------------------------------------------------------------------ */
/* Result codes                                                        */
/* ------------------------------------------------------------------ */
typedef enum TiResult {
    TI_OK                      = 0,
    TI_ERR_UNSUPPORTED         = -1,  /* hardware/OS lacks the feature      */
    TI_ERR_INVALID_ARGUMENT    = -2,
    TI_ERR_INVALID_HANDLE      = -3,
    TI_ERR_OUT_OF_MEMORY       = -4,
    TI_ERR_SHADER_COMPILE      = -5,
    TI_ERR_PIPELINE_CREATE     = -6,
    TI_ERR_NO_DEVICE           = -7,
    TI_ERR_SURFACE_LOST        = -8,
    TI_ERR_INTERNAL            = -9,
    TI_ERR_TIMEOUT             = -10,
    TI_ERR_IO                  = -11,
    /* Not an error: vsync is off and no drawable is free right now, so this
     * frame was rendered but not presented (as GL drops frames the display
     * can't show at swap interval 0). The frame's work is still committed. */
    TI_SKIPPED_PRESENT         = 2
} TiResult;

/* ------------------------------------------------------------------ */
/* Opaque handles                                                      */
/* ------------------------------------------------------------------ */
typedef struct TiDevice        TiDevice;
typedef struct TiSurface       TiSurface;
typedef struct TiBuffer        TiBuffer;
typedef struct TiTexture       TiTexture;
typedef struct TiSampler       TiSampler;
typedef struct TiLibrary       TiLibrary;
typedef struct TiPipeline      TiPipeline;
typedef struct TiDepthStencil  TiDepthStencil;
typedef struct TiFrame         TiFrame;   /* one in-flight command buffer   */
typedef struct TiPass          TiPass;    /* one render command encoder     */

/* ------------------------------------------------------------------ */
/* Logging                                                             */
/* ------------------------------------------------------------------ */
typedef enum TiLogLevel {
    TI_LOG_ERROR = 0, TI_LOG_WARN = 1, TI_LOG_INFO = 2, TI_LOG_DEBUG = 3
} TiLogLevel;

/* Callback is invoked on the calling thread; must not re-enter Titanium. */
typedef void (*TiLogFn)(TiLogLevel level, const char *msg, void *user);

TI_EXPORT void        ti_set_log_callback(TiLogFn fn, void *user);
TI_EXPORT void        ti_set_log_level(TiLogLevel level);
/* Last error message for the calling thread. Never NULL; "" when none. */
TI_EXPORT const char *ti_last_error(void);
TI_EXPORT const char *ti_version_string(void);

/* ------------------------------------------------------------------ */
/* Capabilities                                                        */
/* ------------------------------------------------------------------ */
typedef struct TiCaps {
    char     device_name[128];
    uint64_t registry_id;

    /* GPU family: highest supported Apple family (1..9), 0 if non-Apple. */
    int32_t  apple_family;
    bool     supports_metal3;
    bool     supports_metal4;
    bool     is_apple_silicon;      /* unified memory + TBDR              */
    bool     has_unified_memory;
    bool     is_low_power;
    bool     is_removable;
    bool     is_headless;

    uint64_t recommended_max_working_set;  /* bytes                       */
    uint64_t max_buffer_length;            /* bytes                       */
    uint32_t max_threads_per_threadgroup;
    uint32_t max_threadgroup_memory;
    uint32_t argument_buffers_tier;        /* 1 or 2                      */
    uint32_t max_color_attachments;
    uint32_t max_texture_size_2d;

    /* Feature gates — each is checked at runtime, never assumed. */
    bool     supports_mesh_shaders;
    bool     supports_raytracing;
    bool     supports_function_pointers;
    bool     supports_programmable_blending;  /* Apple GPUs (TBDR)        */
    bool     supports_memoryless_targets;     /* Apple GPUs (TBDR)        */
    bool     supports_msaa_32bit_float;
    bool     supports_depth24_stencil8;       /* false on Apple silicon   */
    bool     supports_binary_archives;
    bool     supports_metalfx_spatial;
    bool     supports_metalfx_temporal;

    /* Display */
    uint32_t max_display_refresh_hz;        /* of the current screen      */
    bool     display_is_variable_refresh;   /* ProMotion / adaptive-sync  */

    /* OS */
    int32_t  os_major, os_minor, os_patch;
} TiCaps;

/* Probe the machine without creating a device. Safe to call before init and
 * on unsupported systems — returns TI_ERR_NO_DEVICE if no Metal device. */
TI_EXPORT TiResult ti_probe(TiCaps *out_caps);

/* ------------------------------------------------------------------ */
/* Device                                                              */
/* ------------------------------------------------------------------ */
typedef struct TiDeviceDesc {
    /* Absolute path to a writable directory for shader/pipeline caches.
     * May be NULL to disable on-disk caching. */
    const char *cache_dir;
    /* Frames the CPU may run ahead of the GPU. Clamped to [1,3]. */
    uint32_t    max_frames_in_flight;
    /* Emit Metal debug labels + validate handles. Small CPU cost. */
    bool        debug_labels;
} TiDeviceDesc;

TI_EXPORT TiResult  ti_device_create(const TiDeviceDesc *desc, TiDevice **out);
TI_EXPORT void      ti_device_release(TiDevice *dev);
TI_EXPORT TiResult  ti_device_caps(TiDevice *dev, TiCaps *out);
/* Bytes currently allocated by this process's Metal heap, as reported by
 * MTLDevice.currentAllocatedSize. Real number, not an estimate. */
TI_EXPORT uint64_t  ti_device_allocated_bytes(TiDevice *dev);
/* Block until all previously committed work on this device has retired. */
TI_EXPORT TiResult  ti_device_wait_idle(TiDevice *dev);

/* ------------------------------------------------------------------ */
/* Formats                                                             */
/* ------------------------------------------------------------------ */
typedef enum TiPixelFormat {
    TI_PF_INVALID = 0,
    TI_PF_R8_UNORM,
    TI_PF_RG8_UNORM,
    TI_PF_RGBA8_UNORM,
    TI_PF_RGBA8_UNORM_SRGB,
    TI_PF_BGRA8_UNORM,
    TI_PF_BGRA8_UNORM_SRGB,
    TI_PF_RGB10A2_UNORM,
    TI_PF_R16_FLOAT,
    TI_PF_RG16_FLOAT,
    TI_PF_RGBA16_FLOAT,
    TI_PF_R32_FLOAT,
    TI_PF_DEPTH32_FLOAT,
    TI_PF_DEPTH32_FLOAT_STENCIL8,
    TI_PF_STENCIL8,
    TI_PF_R8_SINT                /* Minecraft TextureFormat.RED8I          */
} TiPixelFormat;

TI_EXPORT uint32_t ti_pixel_format_bytes_per_pixel(TiPixelFormat fmt);
TI_EXPORT bool     ti_pixel_format_is_depth(TiPixelFormat fmt);

/* ------------------------------------------------------------------ */
/* Buffers                                                             */
/* ------------------------------------------------------------------ */
typedef enum TiStorageMode {
    /* Unified memory, CPU+GPU coherent. Default on Apple silicon. */
    TI_STORAGE_SHARED = 0,
    /* GPU-only. Use for immutable geometry uploaded once via blit. */
    TI_STORAGE_PRIVATE = 1,
    /* Tile memory only; render targets that are never read back. */
    TI_STORAGE_MEMORYLESS = 2
} TiStorageMode;

TI_EXPORT TiResult ti_buffer_create(TiDevice *dev, uint64_t size,
                                    TiStorageMode mode, const char *label,
                                    TiBuffer **out);
/* Create a buffer that aliases caller memory with no copy. Only valid for
 * page-aligned pointers and sizes on unified-memory devices; returns
 * TI_ERR_UNSUPPORTED otherwise so the caller can fall back to a copy. */
TI_EXPORT TiResult ti_buffer_create_no_copy(TiDevice *dev, void *ptr,
                                            uint64_t size, const char *label,
                                            TiBuffer **out);
TI_EXPORT void     ti_buffer_release(TiBuffer *buf);
/* CPU-visible pointer, or NULL for PRIVATE/MEMORYLESS buffers. On unified
 * memory this is the same memory the GPU reads — no staging copy. */
TI_EXPORT void    *ti_buffer_contents(TiBuffer *buf);
TI_EXPORT uint64_t ti_buffer_size(TiBuffer *buf);
/* Upload into a PRIVATE buffer via a staging blit; blocks until complete. */
TI_EXPORT TiResult ti_buffer_upload(TiBuffer *buf, uint64_t offset,
                                    const void *src, uint64_t size);

/* ------------------------------------------------------------------ */
/* Textures & samplers                                                 */
/* ------------------------------------------------------------------ */
typedef struct TiTextureDesc {
    uint32_t      width, height;
    uint32_t      mip_levels;       /* 0 => full chain                     */
    uint32_t      array_length;     /* 0 or 1 => single layer              */
    uint32_t      sample_count;     /* 1, 2, 4, 8                          */
    TiPixelFormat format;
    TiStorageMode storage;
    bool          render_target;    /* usable as colour/depth attachment   */
    bool          shader_read;
    bool          shader_write;
    const char   *label;
    bool          cube;             /* 6 faces; array_length must be 6      */
} TiTextureDesc;

TI_EXPORT TiResult ti_texture_create(TiDevice *dev, const TiTextureDesc *desc,
                                     TiTexture **out);
TI_EXPORT void     ti_texture_release(TiTexture *tex);
TI_EXPORT TiResult ti_texture_upload(TiTexture *tex, uint32_t mip,
                                     uint32_t slice,
                                     uint32_t x, uint32_t y,
                                     uint32_t w, uint32_t h,
                                     const void *src, uint32_t src_row_bytes);
/* Synchronous readback. Used by the test-suite and by screenshots. */
TI_EXPORT TiResult ti_texture_readback(TiTexture *tex, uint32_t mip,
                                       uint32_t x, uint32_t y,
                                       uint32_t w, uint32_t h,
                                       void *dst, uint32_t dst_row_bytes);
TI_EXPORT TiResult ti_texture_generate_mipmaps(TiTexture *tex);
/* A view onto [base_mip, base_mip + mip_count) of `tex`. Owns its own handle;
 * Metal keeps the parent alive for as long as the view exists. */
TI_EXPORT TiResult ti_texture_create_view(TiTexture *tex, uint32_t base_mip,
                                          uint32_t mip_count, TiTexture **out);
/* A texture_buffer aliasing `buf` (GLSL samplerBuffer / isamplerBuffer). */
TI_EXPORT TiResult ti_texture_create_buffer_view(TiBuffer *buf, TiPixelFormat fmt,
                                                 uint64_t offset, uint64_t size_bytes,
                                                 TiTexture **out);
TI_EXPORT void     ti_texture_dimensions(TiTexture *tex, uint32_t *w, uint32_t *h);

typedef enum TiFilter     { TI_FILTER_NEAREST = 0, TI_FILTER_LINEAR = 1 } TiFilter;
typedef enum TiMipFilter  { TI_MIP_NONE = 0, TI_MIP_NEAREST = 1, TI_MIP_LINEAR = 2 } TiMipFilter;
typedef enum TiAddressMode {
    TI_ADDR_CLAMP_TO_EDGE = 0, TI_ADDR_REPEAT = 1,
    TI_ADDR_MIRROR_REPEAT = 2, TI_ADDR_CLAMP_TO_ZERO = 3
} TiAddressMode;

typedef struct TiSamplerDesc {
    TiFilter      min_filter, mag_filter;
    TiMipFilter   mip_filter;
    TiAddressMode address_u, address_v, address_w;
    uint32_t      max_anisotropy;   /* 1..16                              */
    float         lod_min;
    float         lod_max;          /* < 0 => unbounded. 0 is a real clamp:
                                       Minecraft uses maxLod 0 to pin mip 0. */
    const char   *label;
} TiSamplerDesc;

TI_EXPORT TiResult ti_sampler_create(TiDevice *dev, const TiSamplerDesc *desc,
                                     TiSampler **out);
TI_EXPORT void     ti_sampler_release(TiSampler *s);

/* ------------------------------------------------------------------ */
/* Shaders & pipelines                                                 */
/* ------------------------------------------------------------------ */
/* Compile MSL source. `key` is a stable identity used for the on-disk
 * binary cache; pass NULL to skip caching for this library. */
TI_EXPORT TiResult ti_library_from_source(TiDevice *dev, const char *msl,
                                          const char *key, TiLibrary **out);
TI_EXPORT TiResult ti_library_from_metallib(TiDevice *dev, const char *path,
                                            TiLibrary **out);
TI_EXPORT void     ti_library_release(TiLibrary *lib);
TI_EXPORT bool     ti_library_has_function(TiLibrary *lib, const char *name);

typedef enum TiVertexFormat {
    TI_VF_INVALID = 0,
    TI_VF_FLOAT1, TI_VF_FLOAT2, TI_VF_FLOAT3, TI_VF_FLOAT4,
    TI_VF_UCHAR4_NORM,      /* colour bytes -> float4 in [0,1]            */
    TI_VF_UCHAR4,
    TI_VF_CHAR4_NORM,       /* packed normals                             */
    TI_VF_SHORT2,
    TI_VF_SHORT2_NORM,
    TI_VF_USHORT2,          /* lightmap UVs                               */
    TI_VF_UINT1
} TiVertexFormat;

/* Full matrix of what Minecraft's VertexFormatElement can express:
 * component type x count (1-4) x normalised. Encoded values are accepted
 * anywhere a TiVertexFormat is. Integer, non-normalised formats feed GLSL
 * `ivec`/`uvec` inputs (e.g. the UV1/UV2 lightmap coordinates). */
typedef enum TiVertexComponent {
    TI_VC_FLOAT = 0, TI_VC_UBYTE, TI_VC_BYTE, TI_VC_USHORT, TI_VC_SHORT, TI_VC_UINT, TI_VC_INT
} TiVertexComponent;
#define TI_VF_MAKE(component, count, normalized) \
    ((TiVertexFormat)(0x1000 | ((component) << 4) | ((normalized) ? 8 : 0) | (count)))

typedef struct TiVertexAttr {
    uint32_t       location;    /* [[attribute(n)]] in MSL                */
    uint32_t       offset;      /* bytes into the vertex                  */
    uint32_t       buffer;      /* vertex buffer index                    */
    TiVertexFormat format;
} TiVertexAttr;

typedef enum TiStepFunction { TI_STEP_PER_VERTEX = 0, TI_STEP_PER_INSTANCE = 1 } TiStepFunction;

typedef struct TiVertexBufferLayout {
    uint32_t       stride;
    TiStepFunction step;
    uint32_t       step_rate;
} TiVertexBufferLayout;

typedef enum TiBlendFactor {
    TI_BF_ZERO = 0, TI_BF_ONE,
    TI_BF_SRC_COLOR, TI_BF_ONE_MINUS_SRC_COLOR,
    TI_BF_SRC_ALPHA, TI_BF_ONE_MINUS_SRC_ALPHA,
    TI_BF_DST_COLOR, TI_BF_ONE_MINUS_DST_COLOR,
    TI_BF_DST_ALPHA, TI_BF_ONE_MINUS_DST_ALPHA,
    TI_BF_SRC_ALPHA_SATURATED,
    TI_BF_CONSTANT_COLOR, TI_BF_ONE_MINUS_CONSTANT_COLOR,
    TI_BF_CONSTANT_ALPHA, TI_BF_ONE_MINUS_CONSTANT_ALPHA
} TiBlendFactor;

typedef enum TiBlendOp {
    TI_BO_ADD = 0, TI_BO_SUBTRACT, TI_BO_REVERSE_SUBTRACT, TI_BO_MIN, TI_BO_MAX
} TiBlendOp;

typedef struct TiColorTargetDesc {
    TiPixelFormat format;
    bool          blend_enabled;
    TiBlendFactor src_rgb, dst_rgb, src_alpha, dst_alpha;
    TiBlendOp     op_rgb, op_alpha;
    /* Bit mask: 1=R 2=G 4=B 8=A. 0xF writes everything. */
    uint32_t      write_mask;
} TiColorTargetDesc;

typedef struct TiPipelineDesc {
    TiLibrary                 *library;
    const char                *vertex_fn;
    const char                *fragment_fn;   /* NULL => depth-only pass   */
    const TiVertexAttr        *attrs;
    uint32_t                   attr_count;
    const TiVertexBufferLayout*layouts;
    uint32_t                   layout_count;
    TiColorTargetDesc          color[8];
    uint32_t                   color_count;
    TiPixelFormat              depth_format;    /* TI_PF_INVALID => none   */
    TiPixelFormat              stencil_format;  /* TI_PF_INVALID => none   */
    uint32_t                   sample_count;
    bool                       alpha_to_coverage;
    const char                *label;
    /* Library holding fragment_fn. NULL => `library`. Translated shaders need
     * this: vertex and fragment MSL are separate translation units that both
     * declare the same uniform-block structs, so they cannot be one library. */
    TiLibrary                 *fragment_library;
} TiPipelineDesc;

TI_EXPORT TiResult ti_pipeline_create(TiDevice *dev, const TiPipelineDesc *desc,
                                      TiPipeline **out);
TI_EXPORT void     ti_pipeline_release(TiPipeline *p);
/* Pipeline states created this session and the total time spent creating
 * them (driver compile, or archive lookup on a warm cache). */
TI_EXPORT void     ti_device_pipeline_stats(TiDevice *dev, uint64_t *count, double *total_ms);
/* Persist this session's pipelines to cache_dir (replacing the previous
 * file atomically). Call at shutdown. */
TI_EXPORT TiResult ti_device_flush_pipeline_cache(TiDevice *dev);

/* ---- per-pass GPU stage profiling (diagnostic) ------------------------
 * Samples Metal's timestamp counters at stage boundaries, so each render
 * pass reports its vertex-stage (on Apple GPUs: geometry + tiling) and
 * fragment-stage durations separately. Aggregated by pass label. Stages of
 * neighbouring passes can overlap on the GPU, so the sums are per-stage
 * busy time, not a partition of the frame. Off by default: it adds a sample
 * buffer attachment to every pass. */
typedef struct TiPassProfileEntry {
    char     label[64];      /* truncated pass label */
    uint64_t passes;         /* passes sampled under this label */
    uint64_t invalid;        /* passes where the driver returned no sample for a stage */
    double   vertex_ms;      /* summed vertex-stage time */
    double   fragment_ms;    /* summed fragment-stage time */
} TiPassProfileEntry;

typedef struct TiPassProfileSummary {
    uint64_t command_buffers;   /* completed command buffers that carried samples */
    uint64_t unsampled_passes;  /* passes beyond a command buffer's sample capacity */
    double   ns_per_tick;       /* GPU timestamp calibration; 0 until measurable */
    uint32_t entries;           /* distinct labels recorded (may exceed `cap`) */
} TiPassProfileSummary;

/* Time the calling threads spent blocked on the GPU, cumulative since device
 * creation: waiting for a frame-in-flight slot (the GPU is >= N frames
 * behind), waiting on a submission serial (fences), and waiting for a
 * drawable. Near-zero totals mean the CPU side sets the frame rate. */
typedef struct TiWaitStats {
    uint64_t frame_waits;    double frame_wait_ms;
    uint64_t serial_waits;   double serial_wait_ms;
    uint64_t drawable_waits; double drawable_wait_ms;
} TiWaitStats;
TI_EXPORT void ti_device_wait_stats(TiDevice *dev, TiWaitStats *out);

/* TI_ERR_UNSUPPORTED if the GPU cannot sample timestamps at stage boundaries. */
TI_EXPORT TiResult ti_device_set_pass_profiling(TiDevice *dev, bool enable);
/* Clears the aggregates (e.g. at the start of a measured interval). */
TI_EXPORT void     ti_device_reset_pass_profile(TiDevice *dev);
/* Copies up to `cap` entries in first-seen order. ms values are NaN until the
 * calibration interval is long enough (>= 50 ms since profiling began). */
TI_EXPORT TiResult ti_device_pass_profile(TiDevice *dev, TiPassProfileEntry *out, uint32_t cap,
                                          TiPassProfileSummary *summary);

typedef enum TiCompareFunc {
    TI_CMP_NEVER = 0, TI_CMP_LESS, TI_CMP_EQUAL, TI_CMP_LEQUAL,
    TI_CMP_GREATER, TI_CMP_NOTEQUAL, TI_CMP_GEQUAL, TI_CMP_ALWAYS
} TiCompareFunc;

typedef struct TiDepthStencilDesc {
    TiCompareFunc depth_compare;
    bool          depth_write;
    const char   *label;
} TiDepthStencilDesc;

TI_EXPORT TiResult ti_depth_stencil_create(TiDevice *dev,
                                           const TiDepthStencilDesc *desc,
                                           TiDepthStencil **out);
TI_EXPORT void     ti_depth_stencil_release(TiDepthStencil *ds);

/* ------------------------------------------------------------------ */
/* Surface (CAMetalLayer bound to Minecraft's GLFW NSWindow)           */
/* ------------------------------------------------------------------ */
typedef struct TiSurfaceDesc {
    /* NSWindow* from glfwGetCocoaWindow(). Required. */
    void         *ns_window;
    TiPixelFormat format;          /* BGRA8_UNORM or BGRA8_UNORM_SRGB     */
    bool          vsync;
    /* Backing scale for the *world* target. 0 => follow the screen. This is
     * what makes decoupled Retina scaling possible. */
    double        drawable_scale;
    bool          opaque;
    bool          wants_extended_dynamic_range;
} TiSurfaceDesc;

TI_EXPORT TiResult ti_surface_create_for_nswindow(TiDevice *dev,
                                                  const TiSurfaceDesc *desc,
                                                  TiSurface **out);
TI_EXPORT void     ti_surface_release(TiSurface *s);
TI_EXPORT TiResult ti_surface_set_drawable_size(TiSurface *s, uint32_t w, uint32_t h);
TI_EXPORT void     ti_surface_drawable_size(TiSurface *s, uint32_t *w, uint32_t *h);
TI_EXPORT TiResult ti_surface_set_vsync(TiSurface *s, bool vsync);
/* Cap presentation rate. 0 => uncapped / display native. Used for ProMotion
 * pacing via presentDrawable:afterMinimumDuration:. */
TI_EXPORT TiResult ti_surface_set_max_fps(TiSurface *s, uint32_t fps);
TI_EXPORT uint32_t ti_surface_display_refresh_hz(TiSurface *s);
/* Re-read the window's screen after a display change or fullscreen toggle. */
TI_EXPORT TiResult ti_surface_handle_display_change(TiSurface *s);

/* ------------------------------------------------------------------ */
/* Frames, passes, drawing                                             */
/* ------------------------------------------------------------------ */
/* Begin a frame. Waits on the frames-in-flight semaphore. `surface` may be
 * NULL for a purely offscreen frame. */
TI_EXPORT TiResult ti_frame_begin(TiDevice *dev, TiSurface *surface, TiFrame **out);
/* Present (if the frame has a surface) and commit. Releases the handle. */
TI_EXPORT TiResult ti_frame_end(TiFrame *frame, bool present);
/* Commit and block until the GPU has retired this frame. Tests/readback. */
TI_EXPORT TiResult ti_frame_end_and_wait(TiFrame *frame, bool present);
/* ---- Submission ordering -------------------------------------------------
 * OpenGL executes uploads and copies in command order. The frame-ordered
 * operations below encode into the frame's command buffer, so they run after
 * the passes encoded before them and before the ones encoded after — exactly
 * GL's model. (ti_buffer_upload / ti_texture_upload, by contrast, submit on
 * their own and would overtake an uncommitted frame; use them only at load
 * time with no frame open.) All fail if a render pass is currently open.
 * Source memory is copied into a staging buffer immediately, so the caller may
 * reuse it as soon as the call returns. */
TI_EXPORT TiResult ti_frame_upload_buffer(TiFrame *f, TiBuffer *dst, uint64_t offset,
                                          const void *src, uint64_t size);
TI_EXPORT TiResult ti_frame_upload_texture(TiFrame *f, TiTexture *dst, uint32_t mip,
                                           uint32_t slice, uint32_t x, uint32_t y,
                                           uint32_t w, uint32_t h,
                                           const void *src, uint32_t src_row_bytes);
TI_EXPORT TiResult ti_frame_copy_buffer(TiFrame *f, TiBuffer *src, uint64_t src_off,
                                        TiBuffer *dst, uint64_t dst_off, uint64_t size);
TI_EXPORT TiResult ti_frame_copy_texture_to_buffer(TiFrame *f, TiTexture *src, uint32_t mip,
                                                   uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                                                   TiBuffer *dst, uint64_t dst_off,
                                                   uint32_t dst_row_bytes);
TI_EXPORT TiResult ti_frame_copy_texture(TiFrame *f, TiTexture *src, uint32_t src_mip,
                                         uint32_t sx, uint32_t sy,
                                         TiTexture *dst, uint32_t dst_mip,
                                         uint32_t dx, uint32_t dy, uint32_t w, uint32_t h);
TI_EXPORT TiResult ti_frame_generate_mipmaps(TiFrame *f, TiTexture *tex);
/* Clear colour and/or depth. With has_rect the clear is limited to a
 * rectangle in OpenGL window coordinates (y from the bottom), done as a
 * scissored draw because Metal load actions cannot clear a sub-rectangle. */
TI_EXPORT TiResult ti_frame_clear(TiFrame *f, TiTexture *color, bool clear_color,
                                  double r, double g, double b, double a,
                                  TiTexture *depth, bool clear_depth, double depth_value,
                                  bool has_rect, uint32_t x, uint32_t y, uint32_t w, uint32_t h);
/* Copy `src` (OpenGL memory layout, row 0 = bottom) into `dst` flipped so it
 * displays upright, scaling if sizes differ. dst NULL => the surface drawable,
 * acquired now (late acquisition keeps the drawable pool free longer).
 * With vsync off, returns TI_SKIPPED_PRESENT instead of blocking when every
 * drawable is still with the compositor: a windowed CAMetalLayer does not
 * release drawables faster than the display refresh even with
 * displaySyncEnabled = NO (measured: 122 fps cap with 0.07 ms of GPU work). */
TI_EXPORT TiResult ti_frame_blit_flipped(TiFrame *f, TiTexture *src, TiTexture *dst,
                                         TiSurface *surface);

/* Scale `src` into `dst` for decoupled world resolution. Both are in OpenGL
 * memory layout; nothing is flipped. TI_UPSCALE_METALFX_SPATIAL returns
 * TI_ERR_UNSUPPORTED where MetalFX spatial scaling is unavailable, so the
 * caller can fall back to bilinear explicitly. */
typedef enum TiUpscaler { TI_UPSCALE_BILINEAR = 0, TI_UPSCALE_METALFX_SPATIAL = 1 } TiUpscaler;
TI_EXPORT TiResult ti_frame_upscale(TiFrame *f, TiTexture *src, TiTexture *dst, TiUpscaler mode);

/* Monotonic submission serials, for fences and CPU/GPU buffer sync. */
TI_EXPORT uint64_t ti_frame_serial(TiFrame *f);
TI_EXPORT uint64_t ti_device_completed_serial(TiDevice *dev);
/* TI_OK once `serial` has completed; TI_ERR_TIMEOUT on timeout;
 * TI_ERR_INVALID_ARGUMENT if that frame was never committed (waiting on it
 * would otherwise deadlock). timeout_ns = UINT64_MAX waits forever. */
TI_EXPORT TiResult ti_device_wait_serial(TiDevice *dev, uint64_t serial, uint64_t timeout_ns);

/* GPU time of the last completed frame, in milliseconds. -1 if unavailable. */
TI_EXPORT double   ti_device_last_gpu_ms(TiDevice *dev);

typedef enum TiLoadAction  { TI_LOAD_DONT_CARE = 0, TI_LOAD_LOAD = 1, TI_LOAD_CLEAR = 2 } TiLoadAction;
typedef enum TiStoreAction { TI_STORE_DONT_CARE = 0, TI_STORE_STORE = 1, TI_STORE_RESOLVE = 2 } TiStoreAction;

typedef struct TiColorAttachment {
    TiTexture    *texture;       /* NULL + use_drawable => the swapchain   */
    bool          use_drawable;
    TiTexture    *resolve_texture;
    uint32_t      level, slice;
    TiLoadAction  load;
    TiStoreAction store;
    double        clear_r, clear_g, clear_b, clear_a;
} TiColorAttachment;

typedef struct TiDepthAttachment {
    TiTexture    *texture;
    TiLoadAction  load;
    TiStoreAction store;
    double        clear_depth;
} TiDepthAttachment;

typedef struct TiRenderPassDesc {
    TiColorAttachment color[8];
    uint32_t          color_count;
    TiDepthAttachment depth;
    bool              has_depth;
    const char       *label;
} TiRenderPassDesc;

TI_EXPORT TiResult ti_pass_begin(TiFrame *frame, const TiRenderPassDesc *desc, TiPass **out);
TI_EXPORT TiResult ti_pass_end(TiPass *pass);

TI_EXPORT TiResult ti_pass_set_pipeline(TiPass *p, TiPipeline *pipe);
TI_EXPORT TiResult ti_pass_set_depth_stencil(TiPass *p, TiDepthStencil *ds);
TI_EXPORT TiResult ti_pass_set_viewport(TiPass *p, double x, double y,
                                        double w, double h,
                                        double znear, double zfar);
TI_EXPORT TiResult ti_pass_set_scissor(TiPass *p, uint32_t x, uint32_t y,
                                       uint32_t w, uint32_t h);
TI_EXPORT TiResult ti_pass_set_cull_mode(TiPass *p, int32_t mode /*0 none,1 front,2 back*/);
TI_EXPORT TiResult ti_pass_set_front_face_ccw(TiPass *p, bool ccw);
TI_EXPORT TiResult ti_pass_set_blend_color(TiPass *p, double r, double g, double b, double a);
TI_EXPORT TiResult ti_pass_set_depth_bias(TiPass *p, float constant, float slope, float clamp);
TI_EXPORT TiResult ti_pass_set_wireframe(TiPass *p, bool wireframe);
TI_EXPORT TiResult ti_pass_push_debug_group(TiPass *p, const char *label);
TI_EXPORT TiResult ti_pass_pop_debug_group(TiPass *p);

TI_EXPORT TiResult ti_pass_set_vertex_buffer(TiPass *p, uint32_t index,
                                             TiBuffer *buf, uint64_t offset);
TI_EXPORT TiResult ti_pass_set_fragment_buffer(TiPass *p, uint32_t index,
                                               TiBuffer *buf, uint64_t offset);
/* Small (<4 KiB) constants inlined into the command buffer — avoids an
 * allocation per draw for Minecraft's per-draw uniforms. */
TI_EXPORT TiResult ti_pass_set_vertex_bytes(TiPass *p, uint32_t index,
                                            const void *data, uint32_t size);
TI_EXPORT TiResult ti_pass_set_fragment_bytes(TiPass *p, uint32_t index,
                                              const void *data, uint32_t size);
TI_EXPORT TiResult ti_pass_set_fragment_texture(TiPass *p, uint32_t index, TiTexture *tex);
TI_EXPORT TiResult ti_pass_set_fragment_sampler(TiPass *p, uint32_t index, TiSampler *s);
TI_EXPORT TiResult ti_pass_set_vertex_texture(TiPass *p, uint32_t index, TiTexture *tex);
/* Vertex-stage samplers: vanilla terrain samples the lightmap in the vertex shader. */
TI_EXPORT TiResult ti_pass_set_vertex_sampler(TiPass *p, uint32_t index, TiSampler *s);

typedef enum TiPrimitive {
    TI_PRIM_TRIANGLES = 0, TI_PRIM_TRIANGLE_STRIP, TI_PRIM_LINES, TI_PRIM_POINTS,
    TI_PRIM_LINE_STRIP
} TiPrimitive;
typedef enum TiIndexType { TI_INDEX_U16 = 0, TI_INDEX_U32 = 1 } TiIndexType;

TI_EXPORT TiResult ti_pass_draw(TiPass *p, TiPrimitive prim,
                                uint32_t first_vertex, uint32_t vertex_count,
                                uint32_t instance_count);
TI_EXPORT TiResult ti_pass_draw_indexed(TiPass *p, TiPrimitive prim,
                                        uint32_t index_count, TiIndexType type,
                                        TiBuffer *index_buffer,
                                        uint64_t index_offset,
                                        uint32_t instance_count,
                                        int32_t base_vertex);

/* A run of indexed draws encoded in one call, for Minecraft's chunk-section
 * path (thousands of draws per frame, each with its own vertex buffer and
 * uniform slice). Measured motivation: interleaving the caller's per-draw
 * work with per-draw Metal calls leaves each buffer object cache-cold when
 * bound; encoding the run back to back, and replacing a same-buffer rebind
 * with setVertexBufferOffset, removes most of that cost (see
 * tests/ti_encode_bench.mm and docs/architecture.md, "Draw submission").
 *
 * `stream` is `len` int64 words holding `draw_count` records, each:
 *   [0] vertex buffer (TiBuffer*), bound at `vertex_slot`; 0 keeps the current one
 *   [1] index buffer  (TiBuffer*)
 *   [2] index buffer offset in bytes
 *   [3] index_count | (TiIndexType << 32)
 *   [4] k = number of buffer binds that precede this draw, then k triples:
 *         (stage_mask << 32 | slot)  stage_mask: 1 = vertex, 2 = fragment
 *         buffer (TiBuffer*)
 *         offset in bytes
 * Binds are applied in order before the draw; ones that match what this call
 * last bound are skipped. Every handle is validated before use; a malformed
 * stream stops at the offending record with an error (records before it have
 * been encoded). Instance count 1, base vertex 0 (what the chunk path uses). */
TI_EXPORT TiResult ti_pass_draw_indexed_stream(TiPass *p, TiPrimitive prim, uint32_t vertex_slot,
                                               const int64_t *stream, size_t len,
                                               uint32_t draw_count);

/* ------------------------------------------------------------------ */
/* Shader translation: Minecraft GLSL 330 -> MSL                       */
/* ------------------------------------------------------------------ */
/* Vertex data for translated pipelines is bound at this buffer index.
 * Uniform blocks are assigned densely from 0 upwards, so the two never
 * collide inside Metal's 31-slot buffer table. */
#define TI_VERTEX_BUFFER_INDEX 30
#define TI_MAX_SAMPLERS        16   /* Metal's per-stage sampler limit */

typedef enum TiShaderStage { TI_STAGE_VERTEX = 0, TI_STAGE_FRAGMENT = 1 } TiShaderStage;

typedef struct TiTranslation TiTranslation;

/* Translate Minecraft GLSL into MSL.
 *
 * Input is exactly what GlDevice compiles: source whose #moj_import lines
 * were already resolved by ShaderManager, with ShaderDefines already injected
 * by GlslPreprocessor.injectDefines. Either stage may be NULL. When both are
 * given they are LINKED, so vertex outputs and fragment inputs receive
 * matching locations even if declared in a different order.
 *
 * Semantic fixups applied (docs/architecture.md section 3):
 *  - clip-space depth [-w,w] (GL) remapped to [0,w] (Metal);
 *  - clip-space Y negated so render targets keep OpenGL's memory layout
 *    (row 0 = bottom). Callers MUST then treat GL's counter-clockwise front
 *    face as clockwise, and flip once when presenting to the drawable;
 *  - every resource gets an explicit, collision-free Metal binding, reported
 *    by ti_translation_reflection() so name-based binds can be resolved.
 *
 * Thread-safe. On failure returns TI_ERR_SHADER_COMPILE with the compiler
 * diagnostics in ti_last_error(); *out is NULL. */
TI_EXPORT TiResult    ti_translate_glsl(const char *vertex_glsl,
                                        const char *fragment_glsl,
                                        const char *debug_name,
                                        TiTranslation **out);
/* MSL source for a stage, or NULL if that stage was not supplied. */
TI_EXPORT const char *ti_translation_msl(TiTranslation *t, TiShaderStage stage);
TI_EXPORT const char *ti_translation_entry_point(TiTranslation *t, TiShaderStage stage);
/* Newline-separated records, one resource per line:
 *   vertex_input  <name> <location>
 *   uniform_block <name> <buffer_index> <size_bytes> <stages>
 *   sampler       <name> <texture_index> <sampler_index> <dim> <stages>
 *   flat_input    <name>   (fragment input declared `flat`: see provoking vertex)
 * <stages> is v, f or vf.  <dim> is 2d, 3d, cube, 2darray or buffer. */
TI_EXPORT const char *ti_translation_reflection(TiTranslation *t);
TI_EXPORT void        ti_translation_release(TiTranslation *t);

/* ------------------------------------------------------------------ */
/* Power management & scheduling                                       */
/* ------------------------------------------------------------------ */
/* Prevents App Nap for the duration. `allow_idle_sleep = true` (the default
 * Titanium uses) keeps normal display/idle sleep working — it does not
 * globally disable power management. Returns a token to end the activity. */
TI_EXPORT TiResult ti_activity_begin(const char *reason, bool allow_idle_sleep,
                                     bool latency_critical, uint64_t *out_token);
TI_EXPORT TiResult ti_activity_end(uint64_t token);
/* Raise the *calling* thread's QoS class. 0=default 1=utility 2=user-initiated
 * 3=user-interactive. Applies only to this thread. */
TI_EXPORT TiResult ti_thread_set_qos(int32_t qos);

#if defined(__cplusplus)
} /* extern "C" */
#endif
#endif /* TITANIUM_TI_API_H */
