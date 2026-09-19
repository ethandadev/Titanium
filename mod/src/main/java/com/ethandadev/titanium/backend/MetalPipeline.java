package com.ethandadev.titanium.backend;

import com.ethandadev.titanium.Titanium;
import com.mojang.blaze3d.pipeline.BlendFunction;
import com.mojang.blaze3d.pipeline.CompiledRenderPipeline;
import com.mojang.blaze3d.pipeline.RenderPipeline;
import com.mojang.blaze3d.platform.DestFactor;
import com.mojang.blaze3d.platform.SourceFactor;
import com.mojang.blaze3d.shaders.ShaderSource;
import com.mojang.blaze3d.shaders.ShaderType;
import com.mojang.blaze3d.vertex.VertexFormat;
import com.mojang.blaze3d.vertex.VertexFormatElement;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * A translated Minecraft pipeline.
 *
 * <p>OpenGL lets one program render into any framebuffer; Metal bakes the
 * attachment pixel formats into the pipeline state object. So translation and
 * shader compilation (the expensive part) happen once here, and a PSO variant
 * is created lazily for each (colour format, depth format) the pipeline is
 * actually drawn into.
 */
final class MetalPipeline implements CompiledRenderPipeline {
    final RenderPipeline info;
    private final MetalDevice device;
    private final boolean valid;
    private long vsLib, fsLib;
    private String vsEntry, fsEntry;
    final Reflection refl;
    private final Map<Long, Long> psoByTarget = new HashMap<>();
    private final Map<Long, Boolean> psoFailed = new HashMap<>();

    /** Startup cost accounting: where shader time actually goes. */
    static long translateNs, mslCompileNs, compiledPipelines;

    public static String compileStats() {
        return String.format("pipelines_compiled=%d translate_ms=%.1f msl_compile_ms=%.1f",
                             compiledPipelines, translateNs / 1e6, mslCompileNs / 1e6);
    }

    static String cacheStats(ShaderCache c) {
        return "msl_cache_hits=" + c.hits + " msl_cache_misses=" + c.misses;
    }

    static MetalPipeline compile(MetalDevice device, RenderPipeline p, ShaderSource source) {
        String name = p.getLocation().toString();
        String vs = device.shaderSource(p.getVertexShader(), ShaderType.VERTEX, p.getShaderDefines(), source);
        String fs = device.shaderSource(p.getFragmentShader(), ShaderType.FRAGMENT, p.getShaderDefines(), source);
        if (vs == null || fs == null) {
            return new MetalPipeline(device, p);
        }

        compiledPipelines++;
        ShaderCache cache = device.shaderCache();
        String key = ShaderCache.key(vs, fs);
        ShaderCache.Entry e = cache.get(key);
        boolean fromCache = e != null;
        if (e == null) {
            long t0 = System.nanoTime();
            long t = nTranslateGlsl(vs, fs, name);
            translateNs += System.nanoTime() - t0;
            if (t == 0) {
                Titanium.LOG.error("Titanium could not translate pipeline {}:\n{}", name, nLastError());
                return new MetalPipeline(device, p);
            }
            try {
                e = new ShaderCache.Entry(nTranslationMsl(t, STAGE_VERTEX), nTranslationMsl(t, STAGE_FRAGMENT),
                                          nTranslationEntryPoint(t, STAGE_VERTEX),
                                          nTranslationEntryPoint(t, STAGE_FRAGMENT), nTranslationReflection(t));
            } finally {
                nTranslationRelease(t);
            }
        }
        long t1 = System.nanoTime();
        long vl = nLibraryFromSource(device.handle, e.vsMsl(), null);
        long fl = nLibraryFromSource(device.handle, e.fsMsl(), null);
        mslCompileNs += System.nanoTime() - t1;
        if (vl == 0 || fl == 0) {
            if (vl != 0) nLibraryRelease(vl);
            if (fl != 0) nLibraryRelease(fl);
            if (fromCache) {
                // Stale entry (e.g. the system Metal compiler changed): drop it and translate afresh.
                cache.remove(key);
                return compile(device, p, source);
            }
            Titanium.LOG.error("Metal rejected translated MSL for {}:\n{}", name, nLastError());
            return new MetalPipeline(device, p);
        }
        if (!fromCache) cache.put(key, e);
        return new MetalPipeline(device, p, vl, fl, e.vsEntry(), e.fsEntry(), Reflection.parse(e.reflection()));
    }

    private MetalPipeline(MetalDevice device, RenderPipeline info) {
        this.device = device; this.info = info; this.valid = false; this.refl = Reflection.EMPTY;
    }

    private MetalPipeline(MetalDevice device, RenderPipeline info, long vsLib, long fsLib,
                          String vsEntry, String fsEntry, Reflection refl) {
        this.device = device; this.info = info; this.valid = true;
        this.vsLib = vsLib; this.fsLib = fsLib; this.vsEntry = vsEntry; this.fsEntry = fsEntry;
        this.refl = refl;
    }

    @Override public boolean isValid() { return valid; }

    /** @return a PSO handle for these attachment formats, or 0 if it cannot be built. */
    long pso(int colorFormat, int depthFormat) {
        if (!valid) return 0;
        long key = ((long) colorFormat << 32) | (depthFormat & 0xffffffffL);
        Long cached = psoByTarget.get(key);
        if (cached != null) return cached;
        if (psoFailed.containsKey(key)) return 0;

        VertexFormat fmt = info.getVertexFormat();
        List<Integer> attrs = new ArrayList<>();
        for (VertexFormatElement e : fmt.getElements()) {
            Integer loc = refl.vertexInputs.get(fmt.getElementName(e));
            if (loc == null) continue;   // not statically used by the shader
            attrs.add(loc);
            attrs.add(fmt.getOffset(e));
            attrs.add(VERTEX_BUFFER_INDEX);
            attrs.add(vertexFormat(e));
        }
        int[] layouts = fmt.getElements().isEmpty() ? new int[0]
                      : new int[]{ VERTEX_BUFFER_INDEX, fmt.getVertexSize(), 0, 1 };

        int[] blend = new int[8];
        if (info.getBlendFunction().isPresent()) {
            BlendFunction b = info.getBlendFunction().get();
            blend[0] = 1;
            blend[1] = factor(b.sourceColor()); blend[2] = factor(b.destColor());
            blend[3] = factor(b.sourceAlpha()); blend[4] = factor(b.destAlpha());
            blend[5] = BO_ADD; blend[6] = BO_ADD;   // GL's default blend equation
        }
        blend[7] = (info.isWriteColor() ? 0x7 : 0) | (info.isWriteAlpha() ? 0x8 : 0);

        long pso = nPipelineCreate(device.handle, vsLib, fsLib, vsEntry, fsEntry,
                                   attrs.stream().mapToInt(Integer::intValue).toArray(), layouts,
                                   colorFormat, blend, depthFormat, PF_INVALID, 1, false,
                                   info.getLocation().toString());
        if (pso == 0) {
            Titanium.LOG.error("Titanium: pipeline state for {} (color {}, depth {}) failed: {}",
                               info.getLocation(), colorFormat, depthFormat, nLastError());
            psoFailed.put(key, true);
            return 0;
        }
        psoByTarget.put(key, pso);
        return pso;
    }

    /**
     * VertexArrayCache's rules, exactly: POSITION/GENERIC/UV elements are
     * floats when FLOAT and *integer* inputs otherwise (glVertexAttribIPointer);
     * NORMAL and COLOR are always normalised.
     */
    private static int vertexFormat(VertexFormatElement e) {
        int comp = switch (e.type()) {
            case FLOAT -> VC_FLOAT;
            case UBYTE -> VC_UBYTE;
            case BYTE -> VC_BYTE;
            case USHORT -> VC_USHORT;
            case SHORT -> VC_SHORT;
            case UINT -> VC_UINT;
            case INT -> VC_INT;
        };
        boolean normalized = e.type() != VertexFormatElement.Type.FLOAT
                && (e.usage() == VertexFormatElement.Usage.NORMAL || e.usage() == VertexFormatElement.Usage.COLOR);
        return TitaniumVertex.format(comp, e.count(), normalized);
    }

    private static int factor(SourceFactor f) {
        return switch (f) {
            case CONSTANT_ALPHA -> BF_CONSTANT_ALPHA;
            case CONSTANT_COLOR -> BF_CONSTANT_COLOR;
            case DST_ALPHA -> BF_DST_ALPHA;
            case DST_COLOR -> BF_DST_COLOR;
            case ONE -> BF_ONE;
            case ONE_MINUS_CONSTANT_ALPHA -> BF_ONE_MINUS_CONSTANT_ALPHA;
            case ONE_MINUS_CONSTANT_COLOR -> BF_ONE_MINUS_CONSTANT_COLOR;
            case ONE_MINUS_DST_ALPHA -> BF_ONE_MINUS_DST_ALPHA;
            case ONE_MINUS_DST_COLOR -> BF_ONE_MINUS_DST_COLOR;
            case ONE_MINUS_SRC_ALPHA -> BF_ONE_MINUS_SRC_ALPHA;
            case ONE_MINUS_SRC_COLOR -> BF_ONE_MINUS_SRC_COLOR;
            case SRC_ALPHA -> BF_SRC_ALPHA;
            case SRC_ALPHA_SATURATE -> BF_SRC_ALPHA_SATURATED;
            case SRC_COLOR -> BF_SRC_COLOR;
            case ZERO -> BF_ZERO;
        };
    }

    private static int factor(DestFactor f) {
        return switch (f) {
            case CONSTANT_ALPHA -> BF_CONSTANT_ALPHA;
            case CONSTANT_COLOR -> BF_CONSTANT_COLOR;
            case DST_ALPHA -> BF_DST_ALPHA;
            case DST_COLOR -> BF_DST_COLOR;
            case ONE -> BF_ONE;
            case ONE_MINUS_CONSTANT_ALPHA -> BF_ONE_MINUS_CONSTANT_ALPHA;
            case ONE_MINUS_CONSTANT_COLOR -> BF_ONE_MINUS_CONSTANT_COLOR;
            case ONE_MINUS_DST_ALPHA -> BF_ONE_MINUS_DST_ALPHA;
            case ONE_MINUS_DST_COLOR -> BF_ONE_MINUS_DST_COLOR;
            case ONE_MINUS_SRC_ALPHA -> BF_ONE_MINUS_SRC_ALPHA;
            case ONE_MINUS_SRC_COLOR -> BF_ONE_MINUS_SRC_COLOR;
            case SRC_ALPHA -> BF_SRC_ALPHA;
            case SRC_COLOR -> BF_SRC_COLOR;
            case ZERO -> BF_ZERO;
        };
    }

    void release() {
        psoByTarget.values().forEach(p -> nPipelineRelease(p));
        psoByTarget.clear();
        if (vsLib != 0) { nLibraryRelease(vsLib); vsLib = 0; }
        if (fsLib != 0) { nLibraryRelease(fsLib); fsLib = 0; }
    }

    /** Parsed ti_translation_reflection() output. */
    static final class Reflection {
        static final Reflection EMPTY = new Reflection();
        final Map<String, Integer> vertexInputs = new HashMap<>();
        /** name -> {slot, stagesMask(1=v,2=f)} */
        final Map<String, int[]> blocks = new HashMap<>();
        /** name -> {slot, stagesMask, isBuffer(1/0)} */
        final Map<String, int[]> samplers = new HashMap<>();
        /** Any fragment input declared `flat` (provoking-vertex reordering needed). */
        boolean hasFlat;

        static Reflection parse(String s) {
            Reflection r = new Reflection();
            if (s == null) return r;
            for (String line : s.split("\n")) {
                String[] f = line.trim().split(" ");
                if (f.length < 2) continue;
                switch (f[0]) {
                    case "vertex_input" -> r.vertexInputs.put(f[1], Integer.parseInt(f[2]));
                    case "uniform_block" -> r.blocks.put(f[1],
                            new int[]{ Integer.parseInt(f[2]), stages(f[4]) });
                    case "flat_input" -> r.hasFlat = true;
                    case "sampler" -> r.samplers.put(f[1],
                            new int[]{ Integer.parseInt(f[2]), stages(f[5]), "buffer".equals(f[4]) ? 1 : 0 });
                    default -> {}
                }
            }
            return r;
        }

        private static int stages(String s) {
            return (s.indexOf('v') >= 0 ? 1 : 0) | (s.indexOf('f') >= 0 ? 2 : 0);
        }
    }
}
