package com.ethandadev.titanium;

import com.ethandadev.titanium.backend.MetalDevice;
import com.ethandadev.titanium.natives.NativeLoader;
import net.fabricmc.loader.api.FabricLoader;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Global switch. The decision must be made before Minecraft creates its window:
 * a window created with GLFW_NO_API has no OpenGL context and can never fall
 * back to the stock renderer. So everything that could make Titanium unusable
 * is checked up front, and any doubt means "stay off".
 */
public final class Titanium {
    private Titanium() {}

    public static final Logger LOG = LoggerFactory.getLogger("Titanium");

    /** Mods that call OpenGL directly or replace rendering below the seam. */
    private static final List<String> INCOMPATIBLE = List.of("iris", "sodium", "optifabric", "canvas");

    private static volatile Boolean active;
    private static volatile boolean vsync = true;
    private static volatile MetalDevice device;
    private static final Set<String> warned = ConcurrentHashMap.newKeySet();

    public static boolean active() {
        Boolean a = active;
        if (a == null) {
            synchronized (Titanium.class) {
                if (active == null) active = decide();
                a = active;
            }
        }
        return a;
    }

    private static boolean decide() {
        if (!TitaniumConfig.get().enabled) {
            LOG.warn("Titanium disabled by config/titanium.json (\"enabled\": false). Using the stock OpenGL renderer.");
            return false;
        }
        for (String id : INCOMPATIBLE) {
            if (FabricLoader.getInstance().isModLoaded(id)) {
                LOG.warn("Titanium disabled: '{}' is installed and is incompatible with a Metal backend "
                         + "(it calls OpenGL directly). Using the stock OpenGL renderer.", id);
                return false;
            }
        }
        NativeLoader.Support s = NativeLoader.check();
        if (!s.supported()) {
            LOG.warn("Titanium disabled: {}. Using the stock OpenGL renderer.", s.reason());
            return false;
        }
        LOG.info("Titanium enabled on {}", s.caps());
        if (TitaniumConfig.get().logSummary)
            LOG.info("Titanium settings: deferredClears={} worldScale={} upscaler={}",
                     TitaniumConfig.get().deferredClears, TitaniumConfig.get().worldScale, TitaniumConfig.get().upscaler);
        return true;
    }

    public static void setDevice(MetalDevice d) { device = d; }

    public static MetalDevice device() { return device; }

    public static boolean vsync() { return vsync; }

    public static void setVsync(boolean v) {
        vsync = v;
        MetalDevice d = device;
        if (d != null) d.setVsync(v);
    }

    public static void onFramebufferResized() {
        MetalDevice d = device;
        if (d != null) d.onFramebufferResized();
    }

    /** GPU time of the last completed Metal command buffer, or -1 (stock GL / unknown). */
    public static double lastGpuMs() {
        MetalDevice d = device;
        return d == null ? -1 : d.lastGpuMs();
    }

    public static String pipelineStats() {
        MetalDevice d = device;
        return d == null ? "pso=n/a" : d.pipelineStats();
    }

    /** {calls, draws, ns} spent in drawMultipleIndexed so far; null on stock GL. */
    public static long[] multiDrawStats() {
        MetalDevice d = device;
        return d == null ? null : d.multiDrawStats();
    }

    /** Self-check only; false on stock GL. */
    public static boolean setBatchDraws(boolean on) {
        MetalDevice d = device;
        if (d == null) return false;
        d.setBatchDraws(on);
        return true;
    }

    /** Cumulative blocked-on-GPU waits (see TitaniumNative.nDeviceWaitStats); null on stock GL. */
    public static double[] waitStats() {
        MetalDevice d = device;
        return d == null ? null : d.waitStats();
    }

    /** Start a profiled interval: drop earlier samples and (re)enable sampling. */
    public static void resetPassProfile() {
        MetalDevice d = device;
        if (d != null && Boolean.getBoolean("titanium.profilePasses")) d.setPassProfiling(true).resetPassProfile();
    }

    /** End the interval: frames encoded after this are not sampled; in-flight ones still land. */
    public static void stopPassProfile() {
        MetalDevice d = device;
        if (d != null && Boolean.getBoolean("titanium.profilePasses")) d.setPassProfiling(false);
    }

    /**
     * Per-pass GPU stage times averaged over {@code frames}, heaviest first, one
     * line per pass label; null when not profiling. Vertex = vertex shading +
     * tiling, fragment = tile shading; stages of different passes can overlap,
     * so these are busy times, not a partition of the frame.
     */
    public static java.util.List<String> passProfile(int frames) {
        MetalDevice d = device;
        if (d == null || !Boolean.getBoolean("titanium.profilePasses")) return null;
        String raw = d.passProfile();
        if (raw == null) return null;
        String[] lines = raw.split("\n");
        String[] h = lines[0].split("\t");
        record Row(String label, long passes, long invalid, double v, double f) {}
        java.util.List<Row> rows = new java.util.ArrayList<>();
        for (int i = 1; i < lines.length; i++) {
            String[] c = lines[i].split("\t");
            if (c.length == 5) rows.add(new Row(c[0], Long.parseLong(c[1]), Long.parseLong(c[2]),
                                                Double.parseDouble(c[3]), Double.parseDouble(c[4])));
        }
        rows.sort((a, b) -> Double.compare(b.v + b.f, a.v + a.f));
        double sumV = 0, sumF = 0;
        for (Row r : rows) { sumV += r.v; sumF += r.f; }
        java.util.List<String> out = new java.util.ArrayList<>();
        out.add(String.format("command_buffers=%s unsampled_passes=%s ns_per_tick=%s frames=%d "
                              + "total_vertex_ms_per_frame=%.3f total_fragment_ms_per_frame=%.3f",
                              h[0], h[1], h[2], frames, sumV / frames, sumF / frames));
        for (Row r : rows)
            out.add(String.format("pass=\"%s\" per_frame=%.2f vertex_ms=%.4f fragment_ms=%.4f invalid=%d",
                                  r.label, (double) r.passes / frames, r.v / frames, r.f / frames, r.invalid));
        return out;
    }

    public static String liveObjects() {
        return device == null ? "live=n/a" : com.ethandadev.titanium.backend.LiveObjects.describe();
    }

    public static String clearStats() {
        MetalDevice d = device;
        return d == null ? "clears=n/a" : d.clearStats() + " deferredClears=" + TitaniumConfig.get().deferredClears;
    }

    /** Bytes Metal reports as allocated by this process, in MB; "n/a" on stock GL. */
    public static String gpuAllocatedMB() {
        MetalDevice d = device;
        return d == null ? "n/a" : (d.allocatedBytes() >> 20) + "MB";
    }

    public static void warnOnce(String key, String message) {
        if (warned.add(key)) LOG.warn("Titanium: {}", message);
    }

    /**
     * Failure after the window already exists without an OpenGL context: there
     * is no renderer to fall back to, so fail with an actionable message.
     */
    public static RuntimeException fatal(String what, String detail) {
        return new IllegalStateException("Titanium " + what + (detail.isEmpty() ? "" : ": " + detail)
            + ". Remove Titanium from the mods folder, or launch with -Dtitanium.enabled=false, "
            + "to use the stock OpenGL renderer.");
    }
}
