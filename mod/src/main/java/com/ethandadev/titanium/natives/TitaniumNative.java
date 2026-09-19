package com.ethandadev.titanium.natives;

import java.nio.ByteBuffer;

/**
 * Raw JNI bindings to {@code libtitanium.dylib}.
 *
 * <p>This class is intentionally a thin, allocation-free surface: handles are
 * {@code long}s and bulk data crosses as direct {@link ByteBuffer}s. On a
 * unified-memory device {@link #nBufferContents} returns a buffer that aliases
 * the memory the GPU reads, so vertex data never needs a staging copy.
 *
 * <p>All methods are unsafe in the usual JNI sense: passing a released handle
 * is a programming error. The native side tags every handle and returns
 * {@code INVALID_HANDLE} instead of dereferencing wild pointers, so mistakes
 * surface as errors rather than as crashes.
 */
public final class TitaniumNative {
    private TitaniumNative() {}

    // ---- result codes (mirror TiResult) ----
    public static final int OK = 0, ERR_UNSUPPORTED = -1, ERR_INVALID_ARGUMENT = -2,
            ERR_INVALID_HANDLE = -3, ERR_OUT_OF_MEMORY = -4, ERR_SHADER_COMPILE = -5,
            ERR_PIPELINE_CREATE = -6, ERR_NO_DEVICE = -7, ERR_SURFACE_LOST = -8,
            ERR_INTERNAL = -9, ERR_TIMEOUT = -10, ERR_IO = -11;

    // ---- log levels ----
    public static final int LOG_ERROR = 0, LOG_WARN = 1, LOG_INFO = 2, LOG_DEBUG = 3;

    // ---- pixel formats (mirror TiPixelFormat) ----
    public static final int PF_INVALID = 0, PF_R8_UNORM = 1, PF_RG8_UNORM = 2,
            PF_RGBA8_UNORM = 3, PF_RGBA8_UNORM_SRGB = 4, PF_BGRA8_UNORM = 5,
            PF_BGRA8_UNORM_SRGB = 6, PF_RGB10A2_UNORM = 7, PF_R16_FLOAT = 8,
            PF_RG16_FLOAT = 9, PF_RGBA16_FLOAT = 10, PF_R32_FLOAT = 11,
            PF_DEPTH32_FLOAT = 12, PF_DEPTH32_FLOAT_STENCIL8 = 13, PF_STENCIL8 = 14,
            PF_R8_SINT = 15;

    // ---- storage modes ----
    public static final int STORAGE_SHARED = 0, STORAGE_PRIVATE = 1, STORAGE_MEMORYLESS = 2;

    // ---- vertex formats ----
    public static final int VF_FLOAT1 = 1, VF_FLOAT2 = 2, VF_FLOAT3 = 3, VF_FLOAT4 = 4,
            VF_UCHAR4_NORM = 5, VF_UCHAR4 = 6, VF_CHAR4_NORM = 7, VF_SHORT2 = 8,
            VF_SHORT2_NORM = 9, VF_USHORT2 = 10, VF_UINT1 = 11;

    // ---- load/store actions ----
    public static final int LOAD_DONT_CARE = 0, LOAD_LOAD = 1, LOAD_CLEAR = 2;
    public static final int STORE_DONT_CARE = 0, STORE_STORE = 1, STORE_RESOLVE = 2;

    // ---- compare functions ----
    public static final int CMP_NEVER = 0, CMP_LESS = 1, CMP_EQUAL = 2, CMP_LEQUAL = 3,
            CMP_GREATER = 4, CMP_NOTEQUAL = 5, CMP_GEQUAL = 6, CMP_ALWAYS = 7;

    // ---- blend ----
    public static final int BF_ZERO = 0, BF_ONE = 1, BF_SRC_COLOR = 2,
            BF_ONE_MINUS_SRC_COLOR = 3, BF_SRC_ALPHA = 4, BF_ONE_MINUS_SRC_ALPHA = 5,
            BF_DST_COLOR = 6, BF_ONE_MINUS_DST_COLOR = 7, BF_DST_ALPHA = 8,
            BF_ONE_MINUS_DST_ALPHA = 9, BF_SRC_ALPHA_SATURATED = 10,
            BF_CONSTANT_COLOR = 11, BF_ONE_MINUS_CONSTANT_COLOR = 12,
            BF_CONSTANT_ALPHA = 13, BF_ONE_MINUS_CONSTANT_ALPHA = 14;
    public static final int BO_ADD = 0, BO_SUBTRACT = 1, BO_REVERSE_SUBTRACT = 2,
            BO_MIN = 3, BO_MAX = 4;

    // ---- filters / addressing ----
    public static final int FILTER_NEAREST = 0, FILTER_LINEAR = 1;
    public static final int MIP_NONE = 0, MIP_NEAREST = 1, MIP_LINEAR = 2;
    public static final int ADDR_CLAMP_TO_EDGE = 0, ADDR_REPEAT = 1,
            ADDR_MIRROR_REPEAT = 2, ADDR_CLAMP_TO_ZERO = 3;

    // ---- primitives / indices ----
    public static final int PRIM_TRIANGLES = 0, PRIM_TRIANGLE_STRIP = 1,
            PRIM_LINES = 2, PRIM_POINTS = 3, PRIM_LINE_STRIP = 4;

    /** Vertex component kinds for {@link #vertexFormat}; order matches TiVertexComponent. */
    public static final int VC_FLOAT = 0, VC_UBYTE = 1, VC_BYTE = 2, VC_USHORT = 3,
            VC_SHORT = 4, VC_UINT = 5, VC_INT = 6;

    /** Java twin of TI_VF_MAKE(component, count, normalized). */
    public static int vertexFormat(int component, int count, boolean normalized) {
        return 0x1000 | (component << 4) | (normalized ? 8 : 0) | count;
    }
    public static final int INDEX_U16 = 0, INDEX_U32 = 1;

    // ---- QoS ----
    public static final int QOS_DEFAULT = 0, QOS_UTILITY = 1,
            QOS_USER_INITIATED = 2, QOS_USER_INTERACTIVE = 3;

    // ============ library-level ============
    public static native String nVersion();
    public static native void   nSetLogLevel(int level);
    public static native String nLastError();
    /** @return capability string, or null if there is no Metal device at all. */
    public static native String nProbe();

    // ============ device ============
    public static native long   nDeviceCreate(String cacheDir, int framesInFlight, boolean debugLabels);
    public static native void   nDeviceRelease(long dev);
    public static native String nDeviceCaps(long dev);
    public static native long   nDeviceAllocatedBytes(long dev);
    public static native int    nDeviceWaitIdle(long dev);
    public static native double nDeviceLastGpuMs(long dev);
    public static native int    nDeviceFlushPipelineCache(long dev);

    // ============ buffers ============
    public static native long nBufferCreate(long dev, long size, int mode, String label);
    public static native void nBufferRelease(long buf);
    public static native long nBufferSize(long buf);
    /** Direct buffer aliasing GPU-visible memory; null for private storage. */
    public static native ByteBuffer nBufferContents(long buf);
    public static native int  nBufferUpload(long buf, long offset, ByteBuffer src, int srcOffset, int size);

    // ============ textures ============
    public static native long nTextureCreate(long dev, int w, int h, int mips, int arrayLen,
                                             int samples, int format, int storage,
                                             boolean renderTarget, boolean shaderRead,
                                             boolean shaderWrite, String label, boolean cube);
    public static native void nTextureRelease(long tex);
    public static native int  nTextureUpload(long tex, int mip, int slice, int x, int y,
                                             int w, int h, ByteBuffer src, int srcOffset, int rowBytes);
    public static native int  nTextureReadback(long tex, int mip, int x, int y, int w, int h,
                                               ByteBuffer dst, int dstOffset, int rowBytes);
    public static native int  nTextureGenerateMipmaps(long tex);

    // ============ samplers ============
    public static native long nSamplerCreate(long dev, int minF, int magF, int mipF,
                                             int addrU, int addrV, int addrW, int aniso,
                                             float lodMin, float lodMax, String label);
    public static native void nSamplerRelease(long s);

    // ============ shaders & pipelines ============
    public static native long    nLibraryFromSource(long dev, String msl, String key);
    public static native void    nLibraryRelease(long lib);
    public static native boolean nLibraryHasFunction(long lib, String name);

    /**
     * @param fragLib library holding {@code fsFn}; 0 means {@code lib}. Translated
     *                shaders need a separate one (see ti_api.h).
     * @param attrs   flattened 4-tuples {location, offset, bufferIndex, vertexFormat}
     * @param layouts flattened 4-tuples {bufferIndex, stride, stepFunction, stepRate}
     * @param blend   {enabled, srcRGB, dstRGB, srcAlpha, dstAlpha, opRGB, opAlpha, writeMask}
     */
    public static native long nPipelineCreate(long dev, long lib, long fragLib, String vsFn, String fsFn,
                                              int[] attrs, int[] layouts, int colorFormat,
                                              int[] blend, int depthFormat, int stencilFormat,
                                              int sampleCount, boolean alphaToCoverage, String label);
    public static native void nPipelineRelease(long pipe);

    public static native long nDepthStencilCreate(long dev, int compare, boolean write, String label);
    public static native void nDepthStencilRelease(long ds);

    // ============ surface ============
    /** @param nsWindow from {@code GLFWNativeCocoa.glfwGetCocoaWindow(handle)}. */
    public static native long nSurfaceCreateForNSWindow(long dev, long nsWindow, int format,
                                                        boolean vsync, double scale,
                                                        boolean opaque, boolean edr);
    public static native void nSurfaceRelease(long s);
    public static native int  nSurfaceSetDrawableSize(long s, int w, int h);
    /** Width in the high 32 bits, height in the low 32. */
    public static native long nSurfaceDrawableSize(long s);
    public static native int  nSurfaceSetVsync(long s, boolean vsync);
    public static native int  nSurfaceSetMaxFps(long s, int fps);
    public static native int  nSurfaceDisplayRefreshHz(long s);
    public static native int  nSurfaceHandleDisplayChange(long s);

    // ============ frames / passes / draws ============
    public static native long nFrameBegin(long dev, long surface);
    public static native int  nFrameEnd(long frame, boolean present);
    public static native int  nFrameEndAndWait(long frame, boolean present);

    public static native long nPassBegin(long frame, long colorTex, boolean useDrawable,
                                         int colorLoad, int colorStore,
                                         double r, double g, double b, double a,
                                         long depthTex, int depthLoad, int depthStore,
                                         double clearDepth, String label);
    public static native int  nPassEnd(long pass);

    public static native int nPassSetPipeline(long pass, long pipe);
    public static native int nPassSetDepthStencil(long pass, long ds);
    public static native int nPassSetViewport(long pass, double x, double y, double w, double h,
                                              double zn, double zf);
    public static native int nPassSetScissor(long pass, int x, int y, int w, int h);
    public static native int nPassSetCullMode(long pass, int mode);
    public static native int nPassSetFrontFaceCcw(long pass, boolean ccw);
    public static native int nPassSetBlendColor(long pass, double r, double g, double b, double a);
    public static native int nPassSetVertexBuffer(long pass, int idx, long buf, long off);
    public static native int nPassSetFragmentBuffer(long pass, int idx, long buf, long off);
    public static native int nPassSetVertexBytes(long pass, int idx, ByteBuffer data, int off, int size);
    public static native int nPassSetFragmentBytes(long pass, int idx, ByteBuffer data, int off, int size);
    public static native int nPassSetFragmentTexture(long pass, int idx, long tex);
    public static native int nPassSetVertexTexture(long pass, int idx, long tex);
    public static native int nPassSetFragmentSampler(long pass, int idx, long sampler);
    public static native int nPassDraw(long pass, int prim, int first, int count, int instances);
    public static native int nPassDrawIndexed(long pass, int prim, int indexCount, int indexType,
                                              long ib, long ibOffset, int instances, int baseVertex);

    // ============ views, texel buffers ============
    public static native long nTextureCreateView(long tex, int baseMip, int mipCount);
    public static native long nTextureCreateBufferView(long buf, int format, long offset, long size);

    // ============ frame-ordered transfers (GL command order) ============
    public static native int  nFrameUploadBuffer(long frame, long buf, long offset, ByteBuffer src, int srcOffset, int size);
    public static native int  nFrameUploadTextureAddr(long frame, long tex, int mip, int slice, int x, int y,
                                                      int w, int h, long address, int rowBytes);
    public static native int  nFrameCopyBuffer(long frame, long src, long srcOff, long dst, long dstOff, long size);
    public static native int  nFrameCopyTextureToBuffer(long frame, long tex, int mip, int x, int y, int w, int h,
                                                        long buf, long offset, int rowBytes);
    public static native int  nFrameCopyTexture(long frame, long src, int srcMip, int sx, int sy,
                                                long dst, int dstMip, int dx, int dy, int w, int h);
    public static native int  nFrameGenerateMipmaps(long frame, long tex);
    public static native int  nFrameClear(long frame, long color, boolean clearColor,
                                          double r, double g, double b, double a,
                                          long depth, boolean clearDepth, double depthValue,
                                          boolean hasRect, int x, int y, int w, int h);
    /** dst 0 = the surface drawable (acquired late). */
    public static native int  nFrameBlitFlipped(long frame, long src, long dst, long surface);
    public static native long nFrameSerial(long frame);
    public static native long nDeviceCompletedSerial(long dev);
    /** @param timeoutNs negative waits forever. */
    public static native int  nDeviceWaitSerial(long dev, long serial, long timeoutNs);

    // ============ extra pass state ============
    public static native int nPassSetDepthBias(long pass, float constant, float slope, float clamp);
    public static native int nPassSetWireframe(long pass, boolean wireframe);
    public static native int nPassPushDebugGroup(long pass, String label);
    public static native int nPassPopDebugGroup(long pass);
    public static native int nPassSetVertexSampler(long pass, int idx, long sampler);

    // ============ shader translation ============
    /** Vertex data slot for translated pipelines (TI_VERTEX_BUFFER_INDEX). */
    public static final int VERTEX_BUFFER_INDEX = 30;
    public static final int STAGE_VERTEX = 0, STAGE_FRAGMENT = 1;

    /**
     * Translate Minecraft GLSL to MSL. Input must already have imports resolved
     * and defines injected. Either stage may be null. Returns 0 on failure with
     * the compiler diagnostics in {@link #nLastError()}.
     */
    public static native long   nTranslateGlsl(String vertexGlsl, String fragmentGlsl, String debugName);
    public static native String nTranslationMsl(long t, int stage);
    public static native String nTranslationEntryPoint(long t, int stage);
    /** Records: vertex_input / uniform_block / sampler lines; see ti_api.h. */
    public static native String nTranslationReflection(long t);
    public static native void   nTranslationRelease(long t);

    // ============ power / scheduling ============
    public static native long nActivityBegin(String reason, boolean allowIdleSleep,
                                             boolean latencyCritical);
    public static native int  nActivityEnd(long token);
    public static native int  nThreadSetQos(int qos);

    /** Human-readable name for a result code, for logs and crash reports. */
    public static String resultName(int rc) {
        return switch (rc) {
            case OK -> "OK";
            case ERR_UNSUPPORTED -> "UNSUPPORTED";
            case ERR_INVALID_ARGUMENT -> "INVALID_ARGUMENT";
            case ERR_INVALID_HANDLE -> "INVALID_HANDLE";
            case ERR_OUT_OF_MEMORY -> "OUT_OF_MEMORY";
            case ERR_SHADER_COMPILE -> "SHADER_COMPILE";
            case ERR_PIPELINE_CREATE -> "PIPELINE_CREATE";
            case ERR_NO_DEVICE -> "NO_DEVICE";
            case ERR_SURFACE_LOST -> "SURFACE_LOST";
            case ERR_INTERNAL -> "INTERNAL";
            case ERR_TIMEOUT -> "TIMEOUT";
            case ERR_IO -> "IO";
            default -> "UNKNOWN(" + rc + ")";
        };
    }
}
