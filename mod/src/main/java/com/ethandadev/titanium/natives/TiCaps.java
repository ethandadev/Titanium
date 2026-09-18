package com.ethandadev.titanium.natives;

import java.util.HashMap;
import java.util.Map;

/**
 * Parsed snapshot of the Metal device's capabilities.
 *
 * <p>Every field here is read from a live {@code MTLDevice} query at runtime.
 * Nothing is inferred from the macOS version or the chip name, because those
 * are not reliable predictors of feature availability.
 */
public final class TiCaps {
    public final String deviceName;
    public final int appleFamily;
    public final boolean metal3, metal4, appleSilicon, unifiedMemory;
    public final long maxBufferLength, recommendedMaxWorkingSet;
    public final int maxTextureSize2D, argumentBuffersTier;
    public final boolean meshShaders, raytracing, programmableBlending, memorylessTargets;
    public final boolean depth24Stencil8, metalfxSpatial, metalfxTemporal;
    public final int maxDisplayRefreshHz;
    public final boolean variableRefresh;
    public final int osMajor, osMinor, osPatch;
    private final Map<String, String> raw;

    private TiCaps(Map<String, String> m) {
        this.raw = m;
        deviceName               = m.getOrDefault("deviceName", "unknown");
        appleFamily              = i(m, "appleFamily");
        metal3                   = b(m, "metal3");
        metal4                   = b(m, "metal4");
        appleSilicon             = b(m, "appleSilicon");
        unifiedMemory            = b(m, "unifiedMemory");
        maxBufferLength          = l(m, "maxBufferLength");
        recommendedMaxWorkingSet = l(m, "recommendedMaxWorkingSet");
        maxTextureSize2D         = i(m, "maxTextureSize2D");
        argumentBuffersTier      = i(m, "argumentBuffersTier");
        meshShaders              = b(m, "meshShaders");
        raytracing               = b(m, "raytracing");
        programmableBlending     = b(m, "programmableBlending");
        memorylessTargets        = b(m, "memorylessTargets");
        depth24Stencil8          = b(m, "depth24Stencil8");
        metalfxSpatial           = b(m, "metalfxSpatial");
        metalfxTemporal          = b(m, "metalfxTemporal");
        maxDisplayRefreshHz      = i(m, "maxDisplayRefreshHz");
        variableRefresh          = b(m, "variableRefresh");
        osMajor                  = i(m, "osMajor");
        osMinor                  = i(m, "osMinor");
        osPatch                  = i(m, "osPatch");
    }

    private static int  i(Map<String,String> m, String k) { try { return Integer.parseInt(m.getOrDefault(k,"0")); } catch (NumberFormatException e) { return 0; } }
    private static long l(Map<String,String> m, String k) { try { return Long.parseLong(m.getOrDefault(k,"0")); }    catch (NumberFormatException e) { return 0L; } }
    private static boolean b(Map<String,String> m, String k) { return "1".equals(m.get(k)); }

    static TiCaps parse(String s) {
        Map<String, String> m = new HashMap<>();
        if (s != null) {
            for (String line : s.split("\n")) {
                int eq = line.indexOf('=');
                if (eq > 0) m.put(line.substring(0, eq), line.substring(eq + 1));
            }
        }
        return new TiCaps(m);
    }

    /** Raw key/value pairs, for crash reports and the diagnostics screen. */
    public Map<String, String> raw() { return Map.copyOf(raw); }

    public String osVersion() { return osMajor + "." + osMinor + "." + osPatch; }

    @Override public String toString() {
        return String.format(
            "%s (Apple family %d, Metal3=%b Metal4=%b, unified=%b, %.1f GiB working set, "
          + "mesh=%b, MetalFX spatial=%b temporal=%b, display %d Hz variable=%b, macOS %s)",
            deviceName, appleFamily, metal3, metal4, unifiedMemory,
            recommendedMaxWorkingSet / 1073741824.0, meshShaders,
            metalfxSpatial, metalfxTemporal, maxDisplayRefreshHz, variableRefresh, osVersion());
    }
}
