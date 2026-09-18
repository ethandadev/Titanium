/*
 * Titanium JNI bridge.
 *
 * Why JNI and not FFM: Minecraft 1.21.11 declares `javaVersion.majorVersion
 * = 21` (java-runtime-delta). java.lang.foreign is a *preview* API in 21 and
 * only final in 22, so an FFM-based mod would require --enable-preview on the
 * vanilla launcher's JRE. JNI needs no launch flags and works on every runtime
 * players actually have. The C ABI in ti_api.h is deliberately FFM-shaped, so
 * a second binding can be added for Java 22+ runtimes without touching the
 * native side.
 *
 * Call-shape notes:
 *  - Handles cross as jlong. 0 means null.
 *  - Buffer contents are handed to Java as a *direct* ByteBuffer aliasing GPU
 *    memory, so on unified memory the JVM writes vertices straight into the
 *    buffer the GPU reads. No staging copy, no JNI call per vertex.
 *  - Render passes take a single colour attachment plus optional depth,
 *    because that is exactly what CommandEncoder.createRenderPass offers.
 */
#include "titanium/ti_api.h"
#include <jni.h>
#include <string>
#include <vector>
#include <cstdio>

#define TI_FN(name) JNIEXPORT JNICALL Java_com_ethandadev_titanium_natives_TitaniumNative_##name

namespace {

struct JStr {
    JNIEnv *env; jstring js; const char *c;
    JStr(JNIEnv *e, jstring s) : env(e), js(s), c(nullptr) {
        if (js) c = env->GetStringUTFChars(js, nullptr);
    }
    ~JStr() { if (js && c) env->ReleaseStringUTFChars(js, c); }
    const char *get() const { return c; }
};

/* Capabilities are read once at startup, so a flat key=value string is a
 * better trade than 40 JNI accessors or a fragile struct layout. */
std::string caps_to_string(const TiCaps &c) {
    char buf[3072];
    snprintf(buf, sizeof buf,
        "deviceName=%s\nregistryId=%llu\nappleFamily=%d\nmetal3=%d\nmetal4=%d\n"
        "appleSilicon=%d\nunifiedMemory=%d\nlowPower=%d\nremovable=%d\nheadless=%d\n"
        "recommendedMaxWorkingSet=%llu\nmaxBufferLength=%llu\n"
        "maxThreadsPerThreadgroup=%u\nmaxThreadgroupMemory=%u\nargumentBuffersTier=%u\n"
        "maxColorAttachments=%u\nmaxTextureSize2D=%u\n"
        "meshShaders=%d\nraytracing=%d\nfunctionPointers=%d\n"
        "programmableBlending=%d\nmemorylessTargets=%d\nmsaa32BitFloat=%d\n"
        "depth24Stencil8=%d\nbinaryArchives=%d\n"
        "metalfxSpatial=%d\nmetalfxTemporal=%d\n"
        "maxDisplayRefreshHz=%u\nvariableRefresh=%d\n"
        "osMajor=%d\nosMinor=%d\nosPatch=%d\n",
        c.device_name, (unsigned long long)c.registry_id, c.apple_family,
        c.supports_metal3, c.supports_metal4, c.is_apple_silicon,
        c.has_unified_memory, c.is_low_power, c.is_removable, c.is_headless,
        (unsigned long long)c.recommended_max_working_set,
        (unsigned long long)c.max_buffer_length,
        c.max_threads_per_threadgroup, c.max_threadgroup_memory,
        c.argument_buffers_tier, c.max_color_attachments, c.max_texture_size_2d,
        c.supports_mesh_shaders, c.supports_raytracing, c.supports_function_pointers,
        c.supports_programmable_blending, c.supports_memoryless_targets,
        c.supports_msaa_32bit_float, c.supports_depth24_stencil8,
        c.supports_binary_archives, c.supports_metalfx_spatial,
        c.supports_metalfx_temporal, c.max_display_refresh_hz,
        c.display_is_variable_refresh, c.os_major, c.os_minor, c.os_patch);
    return std::string(buf);
}

} // namespace

extern "C" {

/* ---------------- library-level ---------------------------------- */

JNIEXPORT jstring TI_FN(nVersion)(JNIEnv *env, jclass) {
    return env->NewStringUTF(ti_version_string());
}
JNIEXPORT void TI_FN(nSetLogLevel)(JNIEnv *, jclass, jint level) {
    ti_set_log_level((TiLogLevel)level);
}
JNIEXPORT jstring TI_FN(nLastError)(JNIEnv *env, jclass) {
    return env->NewStringUTF(ti_last_error());
}
JNIEXPORT jstring TI_FN(nProbe)(JNIEnv *env, jclass) {
    TiCaps c;
    if (ti_probe(&c) != TI_OK) return nullptr;
    return env->NewStringUTF(caps_to_string(c).c_str());
}

/* ---------------- device ------------------------------------------ */

JNIEXPORT jlong TI_FN(nDeviceCreate)(JNIEnv *env, jclass, jstring cacheDir,
                                     jint framesInFlight, jboolean debugLabels) {
    JStr dir(env, cacheDir);
    TiDeviceDesc d = {};
    d.cache_dir = dir.get();
    d.max_frames_in_flight = (uint32_t)framesInFlight;
    d.debug_labels = debugLabels;
    TiDevice *dev = nullptr;
    if (ti_device_create(&d, &dev) != TI_OK) return 0;
    return (jlong)(uintptr_t)dev;
}
JNIEXPORT void TI_FN(nDeviceRelease)(JNIEnv *, jclass, jlong h) {
    ti_device_release((TiDevice *)(uintptr_t)h);
}
JNIEXPORT jstring TI_FN(nDeviceCaps)(JNIEnv *env, jclass, jlong h) {
    TiCaps c;
    if (ti_device_caps((TiDevice *)(uintptr_t)h, &c) != TI_OK) return nullptr;
    return env->NewStringUTF(caps_to_string(c).c_str());
}
JNIEXPORT jlong TI_FN(nDeviceAllocatedBytes)(JNIEnv *, jclass, jlong h) {
    return (jlong)ti_device_allocated_bytes((TiDevice *)(uintptr_t)h);
}
JNIEXPORT jint TI_FN(nDeviceWaitIdle)(JNIEnv *, jclass, jlong h) {
    return ti_device_wait_idle((TiDevice *)(uintptr_t)h);
}
JNIEXPORT jdouble TI_FN(nDeviceLastGpuMs)(JNIEnv *, jclass, jlong h) {
    return ti_device_last_gpu_ms((TiDevice *)(uintptr_t)h);
}
JNIEXPORT jint TI_FN(nDeviceFlushPipelineCache)(JNIEnv *, jclass, jlong h) {
    return ti_device_flush_pipeline_cache((TiDevice *)(uintptr_t)h);
}

/* ---------------- buffers ----------------------------------------- */

JNIEXPORT jlong TI_FN(nBufferCreate)(JNIEnv *env, jclass, jlong dev, jlong size,
                                     jint mode, jstring label) {
    JStr l(env, label);
    TiBuffer *b = nullptr;
    if (ti_buffer_create((TiDevice *)(uintptr_t)dev, (uint64_t)size,
                         (TiStorageMode)mode, l.get(), &b) != TI_OK) return 0;
    return (jlong)(uintptr_t)b;
}
JNIEXPORT void TI_FN(nBufferRelease)(JNIEnv *, jclass, jlong h) {
    ti_buffer_release((TiBuffer *)(uintptr_t)h);
}
JNIEXPORT jlong TI_FN(nBufferSize)(JNIEnv *, jclass, jlong h) {
    return (jlong)ti_buffer_size((TiBuffer *)(uintptr_t)h);
}
/* Direct ByteBuffer over GPU-visible memory: the zero-copy upload path. */
JNIEXPORT jobject TI_FN(nBufferContents)(JNIEnv *env, jclass, jlong h) {
    TiBuffer *b = (TiBuffer *)(uintptr_t)h;
    void *p = ti_buffer_contents(b);
    if (!p) return nullptr;
    return env->NewDirectByteBuffer(p, (jlong)ti_buffer_size(b));
}
JNIEXPORT jint TI_FN(nBufferUpload)(JNIEnv *env, jclass, jlong h, jlong offset,
                                    jobject src, jint srcOffset, jint size) {
    uint8_t *base = (uint8_t *)env->GetDirectBufferAddress(src);
    if (!base) return TI_ERR_INVALID_ARGUMENT;
    return ti_buffer_upload((TiBuffer *)(uintptr_t)h, (uint64_t)offset,
                            base + srcOffset, (uint64_t)size);
}

/* ---------------- textures ---------------------------------------- */

JNIEXPORT jlong TI_FN(nTextureCreate)(JNIEnv *env, jclass, jlong dev,
                                      jint w, jint h, jint mips, jint arrayLen,
                                      jint samples, jint format, jint storage,
                                      jboolean renderTarget, jboolean shaderRead,
                                      jboolean shaderWrite, jstring label) {
    JStr l(env, label);
    TiTextureDesc d = {};
    d.width = (uint32_t)w; d.height = (uint32_t)h;
    d.mip_levels = (uint32_t)mips; d.array_length = (uint32_t)arrayLen;
    d.sample_count = (uint32_t)samples;
    d.format = (TiPixelFormat)format; d.storage = (TiStorageMode)storage;
    d.render_target = renderTarget; d.shader_read = shaderRead; d.shader_write = shaderWrite;
    d.label = l.get();
    TiTexture *t = nullptr;
    if (ti_texture_create((TiDevice *)(uintptr_t)dev, &d, &t) != TI_OK) return 0;
    return (jlong)(uintptr_t)t;
}
JNIEXPORT void TI_FN(nTextureRelease)(JNIEnv *, jclass, jlong h) {
    ti_texture_release((TiTexture *)(uintptr_t)h);
}
JNIEXPORT jint TI_FN(nTextureUpload)(JNIEnv *env, jclass, jlong h, jint mip, jint slice,
                                     jint x, jint y, jint w, jint th,
                                     jobject src, jint srcOffset, jint rowBytes) {
    uint8_t *base = (uint8_t *)env->GetDirectBufferAddress(src);
    if (!base) return TI_ERR_INVALID_ARGUMENT;
    return ti_texture_upload((TiTexture *)(uintptr_t)h, mip, slice, x, y, w, th,
                             base + srcOffset, (uint32_t)rowBytes);
}
JNIEXPORT jint TI_FN(nTextureReadback)(JNIEnv *env, jclass, jlong h, jint mip,
                                       jint x, jint y, jint w, jint th,
                                       jobject dst, jint dstOffset, jint rowBytes) {
    uint8_t *base = (uint8_t *)env->GetDirectBufferAddress(dst);
    if (!base) return TI_ERR_INVALID_ARGUMENT;
    return ti_texture_readback((TiTexture *)(uintptr_t)h, mip, x, y, w, th,
                               base + dstOffset, (uint32_t)rowBytes);
}
JNIEXPORT jint TI_FN(nTextureGenerateMipmaps)(JNIEnv *, jclass, jlong h) {
    return ti_texture_generate_mipmaps((TiTexture *)(uintptr_t)h);
}

/* ---------------- samplers ---------------------------------------- */

JNIEXPORT jlong TI_FN(nSamplerCreate)(JNIEnv *env, jclass, jlong dev,
                                      jint minF, jint magF, jint mipF,
                                      jint addrU, jint addrV, jint addrW,
                                      jint aniso, jfloat lodMin, jfloat lodMax,
                                      jstring label) {
    JStr l(env, label);
    TiSamplerDesc d = {};
    d.min_filter = (TiFilter)minF; d.mag_filter = (TiFilter)magF;
    d.mip_filter = (TiMipFilter)mipF;
    d.address_u = (TiAddressMode)addrU; d.address_v = (TiAddressMode)addrV;
    d.address_w = (TiAddressMode)addrW;
    d.max_anisotropy = (uint32_t)aniso; d.lod_min = lodMin; d.lod_max = lodMax;
    d.label = l.get();
    TiSampler *s = nullptr;
    if (ti_sampler_create((TiDevice *)(uintptr_t)dev, &d, &s) != TI_OK) return 0;
    return (jlong)(uintptr_t)s;
}
JNIEXPORT void TI_FN(nSamplerRelease)(JNIEnv *, jclass, jlong h) {
    ti_sampler_release((TiSampler *)(uintptr_t)h);
}

/* ---------------- shaders & pipelines ----------------------------- */

JNIEXPORT jlong TI_FN(nLibraryFromSource)(JNIEnv *env, jclass, jlong dev,
                                          jstring msl, jstring key) {
    JStr s(env, msl), k(env, key);
    TiLibrary *l = nullptr;
    if (ti_library_from_source((TiDevice *)(uintptr_t)dev, s.get(), k.get(), &l) != TI_OK)
        return 0;
    return (jlong)(uintptr_t)l;
}
JNIEXPORT void TI_FN(nLibraryRelease)(JNIEnv *, jclass, jlong h) {
    ti_library_release((TiLibrary *)(uintptr_t)h);
}
JNIEXPORT jboolean TI_FN(nLibraryHasFunction)(JNIEnv *env, jclass, jlong h, jstring name) {
    JStr n(env, name);
    return ti_library_has_function((TiLibrary *)(uintptr_t)h, n.get()) ? JNI_TRUE : JNI_FALSE;
}

/*
 * attrs:   flattened 4-tuples  {location, offset, bufferIndex, format}
 * layouts: flattened 3-tuples  {stride, stepFunction, stepRate}
 * blend:   {enabled, srcRGB, dstRGB, srcAlpha, dstAlpha, opRGB, opAlpha, writeMask}
 * One colour target, matching RenderPipeline's single-target model.
 */
JNIEXPORT jlong TI_FN(nPipelineCreate)(JNIEnv *env, jclass, jlong dev, jlong lib,
                                       jstring vsFn, jstring fsFn,
                                       jintArray attrs, jintArray layouts,
                                       jint colorFormat, jintArray blend,
                                       jint depthFormat, jint stencilFormat,
                                       jint sampleCount, jboolean alphaToCoverage,
                                       jstring label) {
    JStr vs(env, vsFn), fs(env, fsFn), lb(env, label);

    jsize na = attrs ? env->GetArrayLength(attrs) : 0;
    jsize nl = layouts ? env->GetArrayLength(layouts) : 0;
    std::vector<jint> av(na), lv(nl), bv(8, 0);
    if (na) env->GetIntArrayRegion(attrs, 0, na, av.data());
    if (nl) env->GetIntArrayRegion(layouts, 0, nl, lv.data());
    if (blend && env->GetArrayLength(blend) >= 8) env->GetIntArrayRegion(blend, 0, 8, bv.data());

    std::vector<TiVertexAttr> ta(na / 4);
    for (jsize i = 0; i + 3 < na; i += 4)
        ta[i / 4] = { (uint32_t)av[i], (uint32_t)av[i+1], (uint32_t)av[i+2],
                      (TiVertexFormat)av[i+3] };

    std::vector<TiVertexBufferLayout> tl(nl / 3);
    for (jsize i = 0; i + 2 < nl; i += 3)
        tl[i / 3] = { (uint32_t)lv[i], (TiStepFunction)lv[i+1], (uint32_t)lv[i+2] };

    TiPipelineDesc d = {};
    d.library = (TiLibrary *)(uintptr_t)lib;
    d.vertex_fn = vs.get();
    d.fragment_fn = fs.get();
    d.attrs = ta.empty() ? nullptr : ta.data();
    d.attr_count = (uint32_t)ta.size();
    d.layouts = tl.empty() ? nullptr : tl.data();
    d.layout_count = (uint32_t)tl.size();
    d.color_count = (colorFormat == TI_PF_INVALID) ? 0 : 1;
    d.color[0].format        = (TiPixelFormat)colorFormat;
    d.color[0].blend_enabled = bv[0] != 0;
    d.color[0].src_rgb       = (TiBlendFactor)bv[1];
    d.color[0].dst_rgb       = (TiBlendFactor)bv[2];
    d.color[0].src_alpha     = (TiBlendFactor)bv[3];
    d.color[0].dst_alpha     = (TiBlendFactor)bv[4];
    d.color[0].op_rgb        = (TiBlendOp)bv[5];
    d.color[0].op_alpha      = (TiBlendOp)bv[6];
    d.color[0].write_mask    = (uint32_t)bv[7];
    d.depth_format   = (TiPixelFormat)depthFormat;
    d.stencil_format = (TiPixelFormat)stencilFormat;
    d.sample_count   = (uint32_t)sampleCount;
    d.alpha_to_coverage = alphaToCoverage;
    d.label = lb.get();

    TiPipeline *p = nullptr;
    if (ti_pipeline_create((TiDevice *)(uintptr_t)dev, &d, &p) != TI_OK) return 0;
    return (jlong)(uintptr_t)p;
}
JNIEXPORT void TI_FN(nPipelineRelease)(JNIEnv *, jclass, jlong h) {
    ti_pipeline_release((TiPipeline *)(uintptr_t)h);
}

JNIEXPORT jlong TI_FN(nDepthStencilCreate)(JNIEnv *env, jclass, jlong dev,
                                           jint compare, jboolean write, jstring label) {
    JStr l(env, label);
    TiDepthStencilDesc d = {};
    d.depth_compare = (TiCompareFunc)compare;
    d.depth_write = write;
    d.label = l.get();
    TiDepthStencil *ds = nullptr;
    if (ti_depth_stencil_create((TiDevice *)(uintptr_t)dev, &d, &ds) != TI_OK) return 0;
    return (jlong)(uintptr_t)ds;
}
JNIEXPORT void TI_FN(nDepthStencilRelease)(JNIEnv *, jclass, jlong h) {
    ti_depth_stencil_release((TiDepthStencil *)(uintptr_t)h);
}

/* ---------------- surface ----------------------------------------- */

/* nsWindow comes from GLFWNativeCocoa.glfwGetCocoaWindow(windowHandle). */
JNIEXPORT jlong TI_FN(nSurfaceCreateForNSWindow)(JNIEnv *, jclass, jlong dev,
                                                 jlong nsWindow, jint format,
                                                 jboolean vsync, jdouble scale,
                                                 jboolean opaque, jboolean edr) {
    TiSurfaceDesc d = {};
    d.ns_window = (void *)(uintptr_t)nsWindow;
    d.format = (TiPixelFormat)format;
    d.vsync = vsync;
    d.drawable_scale = scale;
    d.opaque = opaque;
    d.wants_extended_dynamic_range = edr;
    TiSurface *s = nullptr;
    if (ti_surface_create_for_nswindow((TiDevice *)(uintptr_t)dev, &d, &s) != TI_OK) return 0;
    return (jlong)(uintptr_t)s;
}
JNIEXPORT void TI_FN(nSurfaceRelease)(JNIEnv *, jclass, jlong h) {
    ti_surface_release((TiSurface *)(uintptr_t)h);
}
JNIEXPORT jint TI_FN(nSurfaceSetDrawableSize)(JNIEnv *, jclass, jlong h, jint w, jint th) {
    return ti_surface_set_drawable_size((TiSurface *)(uintptr_t)h, (uint32_t)w, (uint32_t)th);
}
/* Packs width in the high 32 bits, height in the low 32. */
JNIEXPORT jlong TI_FN(nSurfaceDrawableSize)(JNIEnv *, jclass, jlong h) {
    uint32_t w = 0, ht = 0;
    ti_surface_drawable_size((TiSurface *)(uintptr_t)h, &w, &ht);
    return ((jlong)w << 32) | (jlong)ht;
}
JNIEXPORT jint TI_FN(nSurfaceSetVsync)(JNIEnv *, jclass, jlong h, jboolean v) {
    return ti_surface_set_vsync((TiSurface *)(uintptr_t)h, v);
}
JNIEXPORT jint TI_FN(nSurfaceSetMaxFps)(JNIEnv *, jclass, jlong h, jint fps) {
    return ti_surface_set_max_fps((TiSurface *)(uintptr_t)h, (uint32_t)fps);
}
JNIEXPORT jint TI_FN(nSurfaceDisplayRefreshHz)(JNIEnv *, jclass, jlong h) {
    return (jint)ti_surface_display_refresh_hz((TiSurface *)(uintptr_t)h);
}
JNIEXPORT jint TI_FN(nSurfaceHandleDisplayChange)(JNIEnv *, jclass, jlong h) {
    return ti_surface_handle_display_change((TiSurface *)(uintptr_t)h);
}

/* ---------------- frames, passes, draws --------------------------- */

JNIEXPORT jlong TI_FN(nFrameBegin)(JNIEnv *, jclass, jlong dev, jlong surface) {
    TiFrame *f = nullptr;
    if (ti_frame_begin((TiDevice *)(uintptr_t)dev,
                       surface ? (TiSurface *)(uintptr_t)surface : nullptr, &f) != TI_OK)
        return 0;
    return (jlong)(uintptr_t)f;
}
JNIEXPORT jint TI_FN(nFrameEnd)(JNIEnv *, jclass, jlong h, jboolean present) {
    return ti_frame_end((TiFrame *)(uintptr_t)h, present);
}
JNIEXPORT jint TI_FN(nFrameEndAndWait)(JNIEnv *, jclass, jlong h, jboolean present) {
    return ti_frame_end_and_wait((TiFrame *)(uintptr_t)h, present);
}

JNIEXPORT jlong TI_FN(nPassBegin)(JNIEnv *env, jclass, jlong frame,
                                  jlong colorTex, jboolean useDrawable,
                                  jint colorLoad, jint colorStore,
                                  jdouble r, jdouble g, jdouble b, jdouble a,
                                  jlong depthTex, jint depthLoad, jint depthStore,
                                  jdouble clearDepth, jstring label) {
    JStr l(env, label);
    TiRenderPassDesc d = {};
    d.color_count = 1;
    d.color[0].texture = (TiTexture *)(uintptr_t)colorTex;
    d.color[0].use_drawable = useDrawable;
    d.color[0].load = (TiLoadAction)colorLoad;
    d.color[0].store = (TiStoreAction)colorStore;
    d.color[0].clear_r = r; d.color[0].clear_g = g;
    d.color[0].clear_b = b; d.color[0].clear_a = a;
    if (depthTex) {
        d.has_depth = true;
        d.depth.texture = (TiTexture *)(uintptr_t)depthTex;
        d.depth.load = (TiLoadAction)depthLoad;
        d.depth.store = (TiStoreAction)depthStore;
        d.depth.clear_depth = clearDepth;
    }
    d.label = l.get();
    TiPass *p = nullptr;
    if (ti_pass_begin((TiFrame *)(uintptr_t)frame, &d, &p) != TI_OK) return 0;
    return (jlong)(uintptr_t)p;
}
JNIEXPORT jint TI_FN(nPassEnd)(JNIEnv *, jclass, jlong h) {
    return ti_pass_end((TiPass *)(uintptr_t)h);
}

JNIEXPORT jint TI_FN(nPassSetPipeline)(JNIEnv *, jclass, jlong p, jlong pipe) {
    return ti_pass_set_pipeline((TiPass *)(uintptr_t)p, (TiPipeline *)(uintptr_t)pipe);
}
JNIEXPORT jint TI_FN(nPassSetDepthStencil)(JNIEnv *, jclass, jlong p, jlong ds) {
    return ti_pass_set_depth_stencil((TiPass *)(uintptr_t)p, (TiDepthStencil *)(uintptr_t)ds);
}
JNIEXPORT jint TI_FN(nPassSetViewport)(JNIEnv *, jclass, jlong p, jdouble x, jdouble y,
                                       jdouble w, jdouble h, jdouble zn, jdouble zf) {
    return ti_pass_set_viewport((TiPass *)(uintptr_t)p, x, y, w, h, zn, zf);
}
JNIEXPORT jint TI_FN(nPassSetScissor)(JNIEnv *, jclass, jlong p, jint x, jint y,
                                      jint w, jint h) {
    return ti_pass_set_scissor((TiPass *)(uintptr_t)p, x, y, w, h);
}
JNIEXPORT jint TI_FN(nPassSetCullMode)(JNIEnv *, jclass, jlong p, jint mode) {
    return ti_pass_set_cull_mode((TiPass *)(uintptr_t)p, mode);
}
JNIEXPORT jint TI_FN(nPassSetFrontFaceCcw)(JNIEnv *, jclass, jlong p, jboolean ccw) {
    return ti_pass_set_front_face_ccw((TiPass *)(uintptr_t)p, ccw);
}
JNIEXPORT jint TI_FN(nPassSetBlendColor)(JNIEnv *, jclass, jlong p, jdouble r, jdouble g,
                                         jdouble b, jdouble a) {
    return ti_pass_set_blend_color((TiPass *)(uintptr_t)p, r, g, b, a);
}
JNIEXPORT jint TI_FN(nPassSetVertexBuffer)(JNIEnv *, jclass, jlong p, jint idx,
                                           jlong buf, jlong off) {
    return ti_pass_set_vertex_buffer((TiPass *)(uintptr_t)p, idx,
                                     (TiBuffer *)(uintptr_t)buf, (uint64_t)off);
}
JNIEXPORT jint TI_FN(nPassSetFragmentBuffer)(JNIEnv *, jclass, jlong p, jint idx,
                                             jlong buf, jlong off) {
    return ti_pass_set_fragment_buffer((TiPass *)(uintptr_t)p, idx,
                                       (TiBuffer *)(uintptr_t)buf, (uint64_t)off);
}
JNIEXPORT jint TI_FN(nPassSetVertexBytes)(JNIEnv *env, jclass, jlong p, jint idx,
                                          jobject data, jint offset, jint size) {
    uint8_t *base = (uint8_t *)env->GetDirectBufferAddress(data);
    if (!base) return TI_ERR_INVALID_ARGUMENT;
    return ti_pass_set_vertex_bytes((TiPass *)(uintptr_t)p, idx, base + offset, (uint32_t)size);
}
JNIEXPORT jint TI_FN(nPassSetFragmentBytes)(JNIEnv *env, jclass, jlong p, jint idx,
                                            jobject data, jint offset, jint size) {
    uint8_t *base = (uint8_t *)env->GetDirectBufferAddress(data);
    if (!base) return TI_ERR_INVALID_ARGUMENT;
    return ti_pass_set_fragment_bytes((TiPass *)(uintptr_t)p, idx, base + offset, (uint32_t)size);
}
JNIEXPORT jint TI_FN(nPassSetFragmentTexture)(JNIEnv *, jclass, jlong p, jint idx, jlong t) {
    return ti_pass_set_fragment_texture((TiPass *)(uintptr_t)p, idx, (TiTexture *)(uintptr_t)t);
}
JNIEXPORT jint TI_FN(nPassSetVertexTexture)(JNIEnv *, jclass, jlong p, jint idx, jlong t) {
    return ti_pass_set_vertex_texture((TiPass *)(uintptr_t)p, idx, (TiTexture *)(uintptr_t)t);
}
JNIEXPORT jint TI_FN(nPassSetFragmentSampler)(JNIEnv *, jclass, jlong p, jint idx, jlong s) {
    return ti_pass_set_fragment_sampler((TiPass *)(uintptr_t)p, idx, (TiSampler *)(uintptr_t)s);
}
JNIEXPORT jint TI_FN(nPassDraw)(JNIEnv *, jclass, jlong p, jint prim, jint first,
                                jint count, jint instances) {
    return ti_pass_draw((TiPass *)(uintptr_t)p, (TiPrimitive)prim, first, count, instances);
}
JNIEXPORT jint TI_FN(nPassDrawIndexed)(JNIEnv *, jclass, jlong p, jint prim, jint indexCount,
                                       jint indexType, jlong ib, jlong ibOffset,
                                       jint instances, jint baseVertex) {
    return ti_pass_draw_indexed((TiPass *)(uintptr_t)p, (TiPrimitive)prim, indexCount,
                                (TiIndexType)indexType, (TiBuffer *)(uintptr_t)ib,
                                (uint64_t)ibOffset, instances, baseVertex);
}

/* ---------------- power / scheduling ------------------------------ */

JNIEXPORT jlong TI_FN(nActivityBegin)(JNIEnv *env, jclass, jstring reason,
                                      jboolean allowIdleSleep, jboolean latencyCritical) {
    JStr r(env, reason);
    uint64_t tok = 0;
    if (ti_activity_begin(r.get(), allowIdleSleep, latencyCritical, &tok) != TI_OK) return 0;
    return (jlong)tok;
}
JNIEXPORT jint TI_FN(nActivityEnd)(JNIEnv *, jclass, jlong token) {
    return ti_activity_end((uint64_t)token);
}
JNIEXPORT jint TI_FN(nThreadSetQos)(JNIEnv *, jclass, jint qos) {
    return ti_thread_set_qos(qos);
}

} /* extern "C" */
