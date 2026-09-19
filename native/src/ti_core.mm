/* Titanium — device, capabilities, logging, power management. */
#include "ti_internal.h"
#import <MetalFX/MetalFX.h>
#import <AppKit/AppKit.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <pthread.h>
#include <sys/qos.h>
#include <chrono>
#include <string>

/* ===================== logging & errors ============================== */

static TiLogFn    g_log_fn    = nullptr;
static void      *g_log_user  = nullptr;
static TiLogLevel g_log_level = TI_LOG_INFO;

/* Large enough for a full glslang/SPIRV-Cross diagnostic. */
static thread_local char g_err[8192] = {0};

void ti_set_log_callback(TiLogFn fn, void *user) { g_log_fn = fn; g_log_user = user; }
void ti_set_log_level(TiLogLevel lvl)            { g_log_level = lvl; }
const char *ti_last_error(void)                  { return g_err; }

const char *ti_version_string(void) {
    static char buf[64];
    snprintf(buf, sizeof buf, "Titanium %d.%d", TI_API_VERSION_MAJOR, TI_API_VERSION_MINOR);
    return buf;
}

extern "C" void ti_log(TiLogLevel lvl, const char *fmt, ...) {
    if (lvl > g_log_level) return;
    char buf[8192];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (g_log_fn) g_log_fn(lvl, buf, g_log_user);
    else {
        static const char *names[] = {"ERROR","WARN","INFO","DEBUG"};
        fprintf(stderr, "[titanium/%s] %s\n", names[lvl], buf);
    }
}

extern "C" void ti_set_error(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
}

extern "C" TiResult ti_fail(TiResult r, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
    ti_log(TI_LOG_ERROR, "%s", g_err);
    return r;
}

bool ti_validate(const void *h, TiObjType t) {
    if (!h) { ti_set_error("null handle (expected type %d)", (int)t); return false; }
    const TiObjHeader *hdr = (const TiObjHeader *)h;
    if (hdr->magic != (TI_MAGIC_BASE | (uint32_t)t)) {
        ti_set_error("invalid handle: magic 0x%08x, expected 0x%08x",
                     hdr->magic, TI_MAGIC_BASE | (uint32_t)t);
        return false;
    }
    return true;
}

/* ===================== main-thread marshalling ======================= */

void ti_main_sync(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

/* ===================== formats ======================================= */

MTLPixelFormat ti_mtl_format(TiPixelFormat f) {
    switch (f) {
        case TI_PF_R8_UNORM:              return MTLPixelFormatR8Unorm;
        case TI_PF_RG8_UNORM:             return MTLPixelFormatRG8Unorm;
        case TI_PF_RGBA8_UNORM:           return MTLPixelFormatRGBA8Unorm;
        case TI_PF_RGBA8_UNORM_SRGB:      return MTLPixelFormatRGBA8Unorm_sRGB;
        case TI_PF_BGRA8_UNORM:           return MTLPixelFormatBGRA8Unorm;
        case TI_PF_BGRA8_UNORM_SRGB:      return MTLPixelFormatBGRA8Unorm_sRGB;
        case TI_PF_RGB10A2_UNORM:         return MTLPixelFormatRGB10A2Unorm;
        case TI_PF_R16_FLOAT:             return MTLPixelFormatR16Float;
        case TI_PF_RG16_FLOAT:            return MTLPixelFormatRG16Float;
        case TI_PF_RGBA16_FLOAT:          return MTLPixelFormatRGBA16Float;
        case TI_PF_R32_FLOAT:             return MTLPixelFormatR32Float;
        case TI_PF_DEPTH32_FLOAT:         return MTLPixelFormatDepth32Float;
        case TI_PF_DEPTH32_FLOAT_STENCIL8:return MTLPixelFormatDepth32Float_Stencil8;
        case TI_PF_STENCIL8:              return MTLPixelFormatStencil8;
        case TI_PF_R8_SINT:               return MTLPixelFormatR8Sint;
        default:                          return MTLPixelFormatInvalid;
    }
}

uint32_t ti_pixel_format_bytes_per_pixel(TiPixelFormat f) {
    switch (f) {
        case TI_PF_R8_UNORM: case TI_PF_STENCIL8:
        case TI_PF_R8_SINT:                                   return 1;
        case TI_PF_RG8_UNORM: case TI_PF_R16_FLOAT:           return 2;
        case TI_PF_RGBA8_UNORM: case TI_PF_RGBA8_UNORM_SRGB:
        case TI_PF_BGRA8_UNORM: case TI_PF_BGRA8_UNORM_SRGB:
        case TI_PF_RGB10A2_UNORM: case TI_PF_RG16_FLOAT:
        case TI_PF_R32_FLOAT: case TI_PF_DEPTH32_FLOAT:       return 4;
        case TI_PF_RGBA16_FLOAT:                              return 8;
        case TI_PF_DEPTH32_FLOAT_STENCIL8:                    return 8; /* padded */
        default:                                              return 0;
    }
}

bool ti_pixel_format_is_depth(TiPixelFormat f) {
    return f == TI_PF_DEPTH32_FLOAT || f == TI_PF_DEPTH32_FLOAT_STENCIL8;
}

/* ===================== capability probing ============================ */

/* Metal feature-set families are referenced by their numeric values so the
 * library can keep a macOS 12 deployment target: supportsFamily: simply
 * returns NO for a family the running OS does not know about. */
static const NSInteger kTiGPUFamilyMetal3 = 5001;
static const NSInteger kTiGPUFamilyMetal4 = 5002;

static void ti_fill_caps(id<MTLDevice> d, TiCaps *c) {
    memset(c, 0, sizeof *c);

    snprintf(c->device_name, sizeof c->device_name, "%s", d.name.UTF8String ?: "unknown");
    c->registry_id = d.registryID;

    /* Highest supported Apple family. MTLGPUFamilyApple1 == 1001. */
    c->apple_family = 0;
    for (NSInteger i = 9; i >= 1; --i) {
        if ([d supportsFamily:(MTLGPUFamily)(1000 + i)]) { c->apple_family = (int32_t)i; break; }
    }
    c->supports_metal3 = [d supportsFamily:(MTLGPUFamily)kTiGPUFamilyMetal3];
    c->supports_metal4 = [d supportsFamily:(MTLGPUFamily)kTiGPUFamilyMetal4];
    c->has_unified_memory = d.hasUnifiedMemory;
    c->is_apple_silicon   = (c->apple_family > 0) && c->has_unified_memory;
    c->is_low_power       = d.isLowPower;
    c->is_removable       = d.isRemovable;
    c->is_headless        = d.isHeadless;

    c->recommended_max_working_set  = d.recommendedMaxWorkingSetSize;
    c->max_buffer_length            = d.maxBufferLength;
    c->max_threads_per_threadgroup  = (uint32_t)d.maxThreadsPerThreadgroup.width;
    c->max_threadgroup_memory       = (uint32_t)d.maxThreadgroupMemoryLength;
    c->argument_buffers_tier        = (d.argumentBuffersSupport == MTLArgumentBuffersTier2) ? 2 : 1;
    c->max_color_attachments        = 8;
    /* Metal exposes no query for this; it is a documented family limit. */
    c->max_texture_size_2d = (c->apple_family >= 3 || [d supportsFamily:MTLGPUFamilyMac2]) ? 16384 : 8192;

    /* Object/mesh shaders: Apple7+, or Mac2 with Metal 3. */
    c->supports_mesh_shaders = [d supportsFamily:MTLGPUFamilyApple7] ||
                               (c->supports_metal3 && [d supportsFamily:MTLGPUFamilyMac2]);
    c->supports_raytracing        = d.supportsRaytracing;
    c->supports_function_pointers = d.supportsFunctionPointers;
    /* Programmable blending and memoryless attachments are TBDR features,
     * i.e. every Apple-family GPU. */
    c->supports_programmable_blending = [d supportsFamily:MTLGPUFamilyApple1];
    c->supports_memoryless_targets    = [d supportsFamily:MTLGPUFamilyApple1];
    c->supports_msaa_32bit_float      = d.supports32BitMSAA;
    c->supports_depth24_stencil8      = d.isDepth24Stencil8PixelFormatSupported;
    c->supports_binary_archives       = true;   /* macOS 11+ */

    if (@available(macOS 13.0, *)) {
        MTLFXSpatialScalerDescriptor *sd = [MTLFXSpatialScalerDescriptor new];
        c->supports_metalfx_spatial = [MTLFXSpatialScalerDescriptor supportsDevice:d];
        (void)sd;
        c->supports_metalfx_temporal = [MTLFXTemporalScalerDescriptor supportsDevice:d];
    } else {
        c->supports_metalfx_spatial = false;
        c->supports_metalfx_temporal = false;
    }

    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    c->os_major = (int32_t)v.majorVersion;
    c->os_minor = (int32_t)v.minorVersion;
    c->os_patch = (int32_t)v.patchVersion;

    /* Display characteristics of the main screen. */
    c->max_display_refresh_hz = 60;
    c->display_is_variable_refresh = false;
    if (@available(macOS 12.0, *)) {
        NSScreen *s = NSScreen.mainScreen;
        if (s) {
            c->max_display_refresh_hz = (uint32_t)s.maximumFramesPerSecond;
            NSTimeInterval mn = s.minimumRefreshInterval;
            NSTimeInterval mx = s.maximumRefreshInterval;
            c->display_is_variable_refresh = (mx - mn) > 1e-6;
        }
    }
}

TiResult ti_probe(TiCaps *out) {
    if (!out) return TI_ERR_INVALID_ARGUMENT;
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) return ti_fail(TI_ERR_NO_DEVICE, "no Metal device available");
        ti_fill_caps(d, out);
        return TI_OK;
    }
}

/* ===================== device ======================================== */

static NSString *ti_archive_path(const std::string &dir) {
    if (dir.empty()) return nil;
    return [NSString stringWithFormat:@"%s/pipelines.metalar", dir.c_str()];
}

static void ti_open_archive(TiDevice *dev) {
    if (dev->cache_dir.empty()) return;
    @autoreleasepool {
        NSString *path = ti_archive_path(dev->cache_dir);
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:[NSString stringWithUTF8String:dev->cache_dir.c_str()]
      withIntermediateDirectories:YES attributes:nil error:nil];

        MTLBinaryArchiveDescriptor *desc = [MTLBinaryArchiveDescriptor new];
        if ([fm fileExistsAtPath:path]) desc.url = [NSURL fileURLWithPath:path];

        NSError *err = nil;
        id<MTLBinaryArchive> a = [dev->mtl newBinaryArchiveWithDescriptor:desc error:&err];
        if (!a && desc.url) {
            /* Stale or incompatible archive (driver/OS change): start fresh. */
            ti_log(TI_LOG_WARN, "discarding unreadable pipeline cache: %s",
                   err.localizedDescription.UTF8String ?: "?");
            [fm removeItemAtPath:path error:nil];
            desc.url = nil;
            a = [dev->mtl newBinaryArchiveWithDescriptor:desc error:&err];
        }
        if (!a) {
            ti_log(TI_LOG_WARN, "pipeline cache unavailable: %s",
                   err.localizedDescription.UTF8String ?: "?");
            return;
        }
        dev->archive = a;
        ti_log(TI_LOG_INFO, "pipeline cache open at %s", path.UTF8String);
    }
}

TiResult ti_device_create(const TiDeviceDesc *desc, TiDevice **out) {
    if (!out) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) return ti_fail(TI_ERR_NO_DEVICE, "MTLCreateSystemDefaultDevice returned nil");

        id<MTLCommandQueue> q = [d newCommandQueue];
        if (!q) return ti_fail(TI_ERR_INTERNAL, "newCommandQueue failed");

        TiDevice *dev = new TiDevice();
        dev->hdr = TiObjHeader TI_HDR_INIT(TI_T_DEVICE);
        dev->mtl = d;
        dev->queue = q;
        dev->debug_labels = desc ? desc->debug_labels : false;
        uint32_t f = desc ? desc->max_frames_in_flight : 3;
        if (f < 1) f = 1; if (f > 3) f = 3;
        dev->max_frames_in_flight = f;
        dev->frame_sem = dispatch_semaphore_create(f);
        if (desc && desc->cache_dir) dev->cache_dir = desc->cache_dir;
        dev->archive_dirty = false;

        q.label = @"Titanium.queue";

        ti_fill_caps(d, &dev->caps);
        ti_open_archive(dev);

        ti_log(TI_LOG_INFO,
               "device '%s' apple-family=%d metal3=%d metal4=%d unified=%d "
               "frames-in-flight=%u mesh=%d fx-spatial=%d fx-temporal=%d",
               dev->caps.device_name, dev->caps.apple_family,
               dev->caps.supports_metal3, dev->caps.supports_metal4,
               dev->caps.has_unified_memory, f,
               dev->caps.supports_mesh_shaders,
               dev->caps.supports_metalfx_spatial,
               dev->caps.supports_metalfx_temporal);

        *out = dev;
        return TI_OK;
    }
}

TiResult ti_device_flush_pipeline_cache(TiDevice *dev) {
    TI_CHECK(dev, TI_T_DEVICE);
    std::lock_guard<std::mutex> lk(dev->archive_mtx);
    if (!dev->archive || dev->cache_dir.empty() || !dev->archive_dirty) return TI_OK;
    @autoreleasepool {
        NSString *path = ti_archive_path(dev->cache_dir);
        NSString *tmp  = [path stringByAppendingString:@".tmp"];
        NSError *err = nil;
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
        if (![dev->archive serializeToURL:[NSURL fileURLWithPath:tmp] error:&err]) {
            /* Metal names the failing entry only by index; list them so the
             * message is actionable (0-based insertion order). */
            for (size_t i = 0; i < dev->archive_labels.size(); ++i)
                ti_log(TI_LOG_WARN, "pipeline cache entry %zu: %s", i, dev->archive_labels[i].c_str());
            return ti_fail(TI_ERR_IO, "pipeline cache serialize failed: %s",
                           err.localizedDescription.UTF8String ?: "?");
        }
        /* Atomic replace so a crash mid-write cannot corrupt the cache. */
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        if (![NSFileManager.defaultManager moveItemAtPath:tmp toPath:path error:&err]) {
            return ti_fail(TI_ERR_IO, "pipeline cache rename failed: %s",
                           err.localizedDescription.UTF8String ?: "?");
        }
        dev->archive_dirty = false;
        ti_log(TI_LOG_INFO, "pipeline cache written");
        return TI_OK;
    }
}

void ti_device_release(TiDevice *dev) {
    if (!ti_validate(dev, TI_T_DEVICE)) return;
    ti_device_flush_pipeline_cache(dev);
    ti_device_wait_idle(dev);
    dev->hdr.magic = 0;          /* poison: use-after-free becomes a clean error */
    dev->internal_pipes.clear();
    dev->internal_lib = nil;
    dev->fx_scaler = nil;
    dev->fx_intermediate = nil;
    dev->archive = nil;
    dev->queue = nil;
    dev->mtl = nil;
    dev->frame_sem = nil;
    delete dev;
}

TiResult ti_device_caps(TiDevice *dev, TiCaps *out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out) return TI_ERR_INVALID_ARGUMENT;
    *out = dev->caps;
    return TI_OK;
}

uint64_t ti_device_allocated_bytes(TiDevice *dev) {
    if (!ti_validate(dev, TI_T_DEVICE)) return 0;
    return dev->mtl.currentAllocatedSize;
}

TiResult ti_device_wait_idle(TiDevice *dev) {
    TI_CHECK(dev, TI_T_DEVICE);
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [dev->queue commandBuffer];
        cb.label = @"Titanium.waitIdle";
        [cb commit];
        [cb waitUntilCompleted];
    }
    return TI_OK;
}

uint64_t ti_device_completed_serial(TiDevice *dev) {
    if (!ti_validate(dev, TI_T_DEVICE)) return 0;
    std::lock_guard<std::mutex> lk(dev->serial_mtx);
    return dev->completed_serial;
}

TiResult ti_device_wait_serial(TiDevice *dev, uint64_t serial, uint64_t timeout_ns) {
    TI_CHECK(dev, TI_T_DEVICE);
    std::unique_lock<std::mutex> lk(dev->serial_mtx);
    if (serial <= dev->completed_serial) return TI_OK;
    if (serial > dev->committed_serial)
        return ti_fail(TI_ERR_INVALID_ARGUMENT,
                       "wait on serial %llu, but only %llu has been committed; "
                       "waiting would never complete",
                       (unsigned long long)serial, (unsigned long long)dev->committed_serial);
    auto done = [&] { return dev->completed_serial >= serial; };
    if (timeout_ns == UINT64_MAX) { dev->serial_cv.wait(lk, done); return TI_OK; }
    return dev->serial_cv.wait_for(lk, std::chrono::nanoseconds(timeout_ns), done)
           ? TI_OK : TI_ERR_TIMEOUT;
}

/* ===================== internal pipelines ============================ */

static const char *kInternalMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct BlitOut { float4 pos [[position]]; float2 uv; };

// Full-screen triangle. The source is in OpenGL memory layout (row 0 =
// bottom), so the top of the destination samples uv.y = 1.
// Same triangle, no flip: copies between two textures that share a layout.
vertex BlitOut ti_blit_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    BlitOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv  = float2(p.x, 1.0 - p.y);
    return o;
}

vertex BlitOut ti_blit_flip_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    BlitOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv  = p;
    return o;
}

fragment float4 ti_blit_fs(BlitOut in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           sampler smp [[sampler(0)]]) {
    return src.sample(smp, in.uv);
}

struct ClearOut { float4 pos [[position]]; };
struct ClearParams { float4 color; float depth; float3 pad; };

vertex ClearOut ti_clear_vs(uint vid [[vertex_id]], constant ClearParams& p [[buffer(0)]]) {
    float2 q = float2((vid << 1) & 2, vid & 2);
    ClearOut o;
    o.pos = float4(q * 2.0 - 1.0, p.depth, 1.0);
    return o;
}

fragment float4 ti_clear_fs(constant ClearParams& p [[buffer(0)]]) {
    return p.color;
}
)MSL";

id<MTLRenderPipelineState> ti_internal_pipeline(TiDevice *dev, const char *vs, const char *fs,
                                                MTLPixelFormat color, MTLPixelFormat depth) {
    std::lock_guard<std::mutex> lk(dev->internal_mtx);
    if (!dev->internal_lib) {
        NSError *err = nil;
        MTLCompileOptions *o = [MTLCompileOptions new];
        dev->internal_lib = [dev->mtl newLibraryWithSource:@(kInternalMSL) options:o error:&err];
        if (!dev->internal_lib) {
            ti_fail(TI_ERR_SHADER_COMPILE, "internal shaders failed: %s",
                    err.localizedDescription.UTF8String ?: "?");
            return nil;
        }
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = YES;
        dev->ds_always_write = [dev->mtl newDepthStencilStateWithDescriptor:dd];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        dev->smp_nearest = [dev->mtl newSamplerStateWithDescriptor:sd];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        dev->smp_linear = [dev->mtl newSamplerStateWithDescriptor:sd];
    }
    uint64_t key = ((uint64_t)color << 32) ^ ((uint64_t)depth << 16) ^
                   (uint64_t)(std::hash<std::string>{}(std::string(vs) + fs) & 0xffff);
    auto it = dev->internal_pipes.find(key);
    if (it != dev->internal_pipes.end()) return it->second;

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = [dev->internal_lib newFunctionWithName:@(vs)];
    pd.fragmentFunction = [dev->internal_lib newFunctionWithName:@(fs)];
    if (color != MTLPixelFormatInvalid) pd.colorAttachments[0].pixelFormat = color;
    else if (pd.fragmentFunction) pd.fragmentFunction = nil;   /* depth-only */
    pd.depthAttachmentPixelFormat = depth;
    if (depth == MTLPixelFormatDepth32Float_Stencil8) pd.stencilAttachmentPixelFormat = depth;
    NSError *err = nil;
    id<MTLRenderPipelineState> ps = [dev->mtl newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) {
        ti_fail(TI_ERR_PIPELINE_CREATE, "internal pipeline %s/%s failed: %s", vs, fs,
                err.localizedDescription.UTF8String ?: "?");
        return nil;
    }
    dev->internal_pipes[key] = ps;
    return ps;
}

double ti_device_last_gpu_ms(TiDevice *dev) {
    if (!ti_validate(dev, TI_T_DEVICE)) return -1.0;
    return dev->last_gpu_ms.load(std::memory_order_relaxed);
}

/* ===================== power management & scheduling ================= */

static std::mutex                                  g_act_mtx;
static std::unordered_map<uint64_t, id<NSObject>>  g_activities;
static std::atomic<uint64_t>                       g_act_next{1};

TiResult ti_activity_begin(const char *reason, bool allow_idle_sleep,
                           bool latency_critical, uint64_t *out_token) {
    if (!out_token) return TI_ERR_INVALID_ARGUMENT;
    @autoreleasepool {
        /* NSActivityUserInitiatedAllowingIdleSystemSleep prevents App Nap but
         * leaves normal idle/display sleep working. We deliberately do NOT
         * pass NSActivityIdleSystemSleepDisabled unless asked, and
         * LatencyCritical (which disables timer coalescing machine-wide) is
         * opt-in only. */
        NSActivityOptions opts = allow_idle_sleep
            ? NSActivityUserInitiatedAllowingIdleSystemSleep
            : NSActivityUserInitiated;
        if (latency_critical) opts |= NSActivityLatencyCritical;

        NSString *r = [NSString stringWithUTF8String:(reason ?: "Titanium rendering")];
        id<NSObject> tok = [NSProcessInfo.processInfo beginActivityWithOptions:opts reason:r];
        if (!tok) return ti_fail(TI_ERR_INTERNAL, "beginActivityWithOptions returned nil");

        uint64_t id_ = g_act_next.fetch_add(1);
        { std::lock_guard<std::mutex> lk(g_act_mtx); g_activities[id_] = tok; }
        *out_token = id_;
        ti_log(TI_LOG_DEBUG, "activity %llu begun (idle-sleep=%d latency-critical=%d)",
               (unsigned long long)id_, allow_idle_sleep, latency_critical);
        return TI_OK;
    }
}

TiResult ti_activity_end(uint64_t token) {
    @autoreleasepool {
        id<NSObject> tok = nil;
        {
            std::lock_guard<std::mutex> lk(g_act_mtx);
            auto it = g_activities.find(token);
            if (it == g_activities.end()) return TI_ERR_INVALID_ARGUMENT;
            tok = it->second;
            g_activities.erase(it);
        }
        [NSProcessInfo.processInfo endActivity:tok];
        return TI_OK;
    }
}

TiResult ti_thread_set_qos(int32_t qos) {
    qos_class_t q;
    switch (qos) {
        case 0: q = QOS_CLASS_DEFAULT;          break;
        case 1: q = QOS_CLASS_UTILITY;          break;
        case 2: q = QOS_CLASS_USER_INITIATED;   break;
        case 3: q = QOS_CLASS_USER_INTERACTIVE; break;
        default: return TI_ERR_INVALID_ARGUMENT;
    }
    /* Affects only the calling thread. We never touch process-wide or
     * system power policy. */
    if (pthread_set_qos_class_self_np(q, 0) != 0)
        return ti_fail(TI_ERR_INTERNAL, "pthread_set_qos_class_self_np failed");
    return TI_OK;
}
