package com.ethandadev.titanium;

import com.ethandadev.titanium.natives.NativeLoader;
import com.ethandadev.titanium.natives.TiCaps;
import com.ethandadev.titanium.natives.TitaniumNative;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * End-to-end verification that the JVM can drive the Metal backend through JNI
 * and get pixel-exact results back. Mirrors the native self-test, but every
 * call crosses the JNI boundary and the pixels are checked in Java.
 */
public final class JvmEndToEndTest {

    private static int pass = 0, fail = 0;

    static void check(boolean ok, String what) {
        if (ok) { pass++; System.out.println("  ok    " + what); }
        else    { fail++; System.out.println("  FAIL  " + what
                          + "  (native: " + TitaniumNative.nLastError() + ")"); }
    }

    static void checkRc(int rc, String what) {
        check(rc == OK, what + (rc == OK ? "" : " -> " + resultName(rc)));
    }

    private static final String MSL = """
        #include <metal_stdlib>
        using namespace metal;
        struct VIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vs_main(VIn in [[stage_in]]) {
            VOut o; o.pos = float4(in.pos, 0.5, 1.0); o.uv = in.uv; return o;
        }
        fragment float4 fs_tex(VOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
            return tex.sample(smp, in.uv);
        }
        """;

    public static void main(String[] args) {
        System.out.println("=== Titanium JVM end-to-end test ===");
        System.out.println("java " + System.getProperty("java.version")
                           + " on " + System.getProperty("os.arch"));

        // ---- 1. startup support check -------------------------------------
        System.out.println("\n[1] startup support check");
        NativeLoader.Support s = NativeLoader.check();
        System.out.println("        supported = " + s.supported() + " (" + s.reason() + ")");
        check(s.supported(), "NativeLoader.check() reports a supported machine");
        if (!s.supported()) {
            System.out.println("\nStopping: this machine is not supported. "
                             + "That is the intended behaviour, not a crash.");
            System.exit(1);
        }
        TiCaps caps = s.caps();
        System.out.println("        " + caps);
        check(nVersion() != null && nVersion().startsWith("Titanium"), "nVersion() round-trips");
        check(caps.unifiedMemory, "caps report unified memory");
        check(caps.maxTextureSize2D >= 8192, "caps report a sane max texture size");

        nSetLogLevel(LOG_WARN);

        // ---- 2. device -----------------------------------------------------
        System.out.println("\n[2] device creation");
        String cacheDir = System.getProperty("java.io.tmpdir") + "/titanium-jvm-test-cache";
        long dev = nDeviceCreate(cacheDir, 3, true);
        check(dev != 0, "nDeviceCreate returns a handle");
        if (dev == 0) { summary(); return; }
        check(nDeviceCaps(dev) != null, "nDeviceCaps returns capabilities");
        long baseline = nDeviceAllocatedBytes(dev);
        System.out.println("        allocated at start: " + baseline + " bytes");

        // ---- 3. zero-copy buffer writes from Java --------------------------
        System.out.println("\n[3] zero-copy vertex upload from the JVM");
        // x, y, u, v  — a full-screen quad, top-left origin UVs
        float[] verts = {
            -1f,  1f, 0f, 0f,
             1f,  1f, 1f, 0f,
            -1f, -1f, 0f, 1f,
             1f, -1f, 1f, 1f,
        };
        short[] idx = { 0, 1, 2, 2, 1, 3 };

        long vb = nBufferCreate(dev, verts.length * 4L, STORAGE_SHARED, "jvm-vb");
        check(vb != 0, "create shared vertex buffer");
        ByteBuffer vbuf = nBufferContents(vb);
        check(vbuf != null, "nBufferContents returns a direct ByteBuffer");
        check(vbuf != null && vbuf.isDirect(), "buffer is direct (aliases GPU memory)");
        check(vbuf != null && vbuf.capacity() == verts.length * 4,
              "buffer capacity matches the allocation");
        if (vbuf != null) {
            vbuf.order(ByteOrder.nativeOrder()).asFloatBuffer().put(verts);
        }

        long ib = nBufferCreate(dev, idx.length * 2L, STORAGE_SHARED, "jvm-ib");
        ByteBuffer ibuf = nBufferContents(ib);
        if (ibuf != null) ibuf.order(ByteOrder.nativeOrder()).asShortBuffer().put(idx);
        check(ib != 0 && ibuf != null, "create and fill index buffer");

        // A private buffer must not expose CPU memory.
        long priv = nBufferCreate(dev, 256, STORAGE_PRIVATE, "jvm-private");
        check(priv != 0, "create private buffer");
        check(nBufferContents(priv) == null, "private buffer exposes no CPU pointer");
        nBufferRelease(priv);

        // ---- 4. shaders and pipeline ---------------------------------------
        System.out.println("\n[4] shader compilation and pipeline creation from Java");
        long lib = nLibraryFromSource(dev, MSL, "jvm-e2e");
        check(lib != 0, "compile MSL through JNI");
        check(lib != 0 && nLibraryHasFunction(lib, "vs_main"), "library exposes vs_main");
        check(lib != 0 && !nLibraryHasFunction(lib, "missing"), "unknown function reported absent");

        long badLib = nLibraryFromSource(dev, "definitely not MSL", "jvm-bad");
        check(badLib == 0, "invalid MSL fails cleanly rather than crashing the JVM");
        check(!nLastError().isEmpty(), "nLastError() is populated after a failure");

        int[] attrs = { 0, 0, 0, VF_FLOAT2,      // location 0: position at offset 0
                        1, 8, 0, VF_FLOAT2 };    // location 1: uv at offset 8
        int[] layouts = { 0, 16, 0, 1 };         // buffer 0: stride 16, per-vertex
        int[] blend = { 0, 0, 0, 0, 0, 0, 0, 0xF };

        long pipe = nPipelineCreate(dev, lib, 0, "vs_main", "fs_tex", attrs, layouts,
                                    PF_RGBA8_UNORM, blend, PF_INVALID, PF_INVALID,
                                    1, false, "jvm-pipe");
        check(pipe != 0, "create render pipeline");

        // ---- 5. texture + sampler ------------------------------------------
        System.out.println("\n[5] texture upload and sampling");
        long src = nTextureCreate(dev, 2, 2, 1, 1, 1, PF_RGBA8_UNORM, STORAGE_SHARED,
                                  false, true, false, "jvm-src");
        check(src != 0, "create 2x2 source texture");
        ByteBuffer texels = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder());
        byte[] data = {
            (byte)255, 0, 0, (byte)255,          0, (byte)255, 0, (byte)255,
            0, 0, (byte)255, (byte)255,          (byte)255, (byte)255, 0, (byte)255,
        };
        texels.put(data).flip();
        checkRc(nTextureUpload(src, 0, 0, 0, 0, 2, 2, texels, 0, 8), "upload texels");

        long smp = nSamplerCreate(dev, FILTER_NEAREST, FILTER_NEAREST, MIP_NONE,
                                  ADDR_CLAMP_TO_EDGE, ADDR_CLAMP_TO_EDGE, ADDR_CLAMP_TO_EDGE,
                                  1, 0f, 0f, "jvm-nearest");
        check(smp != 0, "create nearest sampler");

        final int N = 128;
        long color = nTextureCreate(dev, N, N, 1, 1, 1, PF_RGBA8_UNORM, STORAGE_PRIVATE,
                                    true, true, false, "jvm-color");
        check(color != 0, "create render target");

        // ---- 6. render and verify pixels in Java ---------------------------
        System.out.println("\n[6] render a frame and verify pixels in Java");
        long frame = nFrameBegin(dev, 0);
        check(frame != 0, "begin offscreen frame");
        long p = nPassBegin(frame, color, false, LOAD_CLEAR, STORE_STORE,
                            0, 0, 0, 1, 0, 0, 0, 1.0, "jvm-pass");
        check(p != 0, "begin render pass");
        checkRc(nPassSetPipeline(p, pipe), "bind pipeline");
        checkRc(nPassSetViewport(p, 0, 0, N, N, 0, 1), "set viewport");
        checkRc(nPassSetVertexBuffer(p, 0, vb, 0), "bind vertex buffer");
        checkRc(nPassSetFragmentTexture(p, 0, src), "bind texture");
        checkRc(nPassSetFragmentSampler(p, 0, smp), "bind sampler");
        checkRc(nPassDrawIndexed(p, PRIM_TRIANGLES, 6, INDEX_U16, ib, 0, 1, 0), "draw indexed");
        checkRc(nPassEnd(p), "end pass");
        checkRc(nFrameEndAndWait(frame, false), "submit and wait");

        ByteBuffer px = ByteBuffer.allocateDirect(N * N * 4).order(ByteOrder.nativeOrder());
        checkRc(nTextureReadback(color, 0, 0, 0, N, N, px, 0, N * 4), "read pixels back");

        check(rgbAt(px, N, 32, 32).equals("255,0,0"),     "top-left quadrant is red");
        check(rgbAt(px, N, 96, 32).equals("0,255,0"),     "top-right quadrant is green");
        check(rgbAt(px, N, 32, 96).equals("0,0,255"),     "bottom-left quadrant is blue");
        check(rgbAt(px, N, 96, 96).equals("255,255,0"),   "bottom-right quadrant is yellow");

        double gpuMs = nDeviceLastGpuMs(dev);
        System.out.printf("        GPU time for that frame: %.4f ms%n", gpuMs);
        check(gpuMs > 0, "driver reported a GPU time");

        long afterAlloc = nDeviceAllocatedBytes(dev);
        System.out.println("        allocated after resources: " + afterAlloc + " bytes");
        check(afterAlloc > baseline, "allocation tracking reflects created resources");

        // ---- 7. power management and thread QoS -----------------------------
        System.out.println("\n[7] App Nap suppression and thread QoS");
        long token = nActivityBegin("Titanium JVM test", true, false);
        check(token != 0, "begin a user-initiated activity (App Nap suppressed)");
        checkRc(nActivityEnd(token), "end the activity");
        check(nActivityEnd(token) == ERR_INVALID_ARGUMENT,
              "ending an already-ended activity is refused, not a crash");
        checkRc(nThreadSetQos(QOS_USER_INTERACTIVE), "raise this thread to user-interactive QoS");
        check(nThreadSetQos(99) == ERR_INVALID_ARGUMENT, "invalid QoS class refused");

        // ---- 8. teardown ----------------------------------------------------
        System.out.println("\n[8] teardown");
        checkRc(nDeviceFlushPipelineCache(dev), "flush pipeline cache to disk");
        nTextureRelease(color);
        nTextureRelease(src);
        nSamplerRelease(smp);
        nPipelineRelease(pipe);
        nLibraryRelease(lib);
        nBufferRelease(ib);
        nBufferRelease(vb);
        checkRc(nDeviceWaitIdle(dev), "device idles cleanly");
        nDeviceRelease(dev);
        check(true, "device released without crashing");

        summary();
    }

    private static String rgbAt(ByteBuffer px, int stride, int x, int y) {
        int o = (y * stride + x) * 4;
        return (px.get(o) & 0xFF) + "," + (px.get(o + 1) & 0xFF) + "," + (px.get(o + 2) & 0xFF);
    }

    private static void summary() {
        System.out.println("\n=== " + pass + " passed, " + fail + " failed ===");
        if (fail > 0) System.exit(1);
    }
}
