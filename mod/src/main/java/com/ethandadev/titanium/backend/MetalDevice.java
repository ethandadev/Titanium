package com.ethandadev.titanium.backend;

import com.ethandadev.titanium.Titanium;
import com.ethandadev.titanium.natives.TiCaps;
import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.pipeline.CompiledRenderPipeline;
import com.mojang.blaze3d.pipeline.RenderPipeline;
import com.mojang.blaze3d.preprocessor.GlslPreprocessor;
import com.mojang.blaze3d.shaders.ShaderType;
import net.minecraft.client.renderer.ShaderDefines;
import net.minecraft.resources.Identifier;
import com.mojang.blaze3d.shaders.ShaderSource;
import com.mojang.blaze3d.systems.CommandEncoder;
import com.mojang.blaze3d.systems.GpuDevice;
import com.mojang.blaze3d.textures.AddressMode;
import com.mojang.blaze3d.textures.FilterMode;
import com.mojang.blaze3d.textures.GpuSampler;
import com.mojang.blaze3d.textures.GpuTexture;
import com.mojang.blaze3d.textures.GpuTextureView;
import com.mojang.blaze3d.textures.TextureFormat;
import net.fabricmc.loader.api.FabricLoader;
import org.jetbrains.annotations.Nullable;
import org.lwjgl.glfw.GLFWNativeCocoa;

import java.nio.ByteBuffer;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.OptionalDouble;
import java.util.function.Supplier;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * Titanium's replacement for GlDevice: the whole Minecraft backend contract
 * (GpuDevice + CommandEncoder + RenderPass, 57 methods) implemented on Metal.
 */
public final class MetalDevice implements GpuDevice {
    final long handle;
    final long surface;
    private final TiCaps caps;
    private final ShaderSource defaultShaderSource;
    private final MetalCommandEncoder encoder;
    private final Map<RenderPipeline, MetalPipeline> pipelineCache = new IdentityHashMap<>();
    private final Map<Integer, Long> depthStates = new HashMap<>();
    /**
     * Per-shader cache keyed like GlDevice's shader-module cache: (id, stage,
     * defines). This is not just an optimisation. During startup the loading
     * overlay's pipelines reuse shaders the GUI preload already compiled, and
     * GL finds them in its module cache before ShaderManager can supply any
     * source. A per-pipeline cache alone would look the source up afresh, get
     * null, and leave the Mojang logo unrendered (found by A/B against GL).
     */
    private final Map<ShaderKey, String> shaderSources = new HashMap<>();
    private record ShaderKey(Identifier id, ShaderType type, ShaderDefines defines) {}
    private final long activityToken;
    private final ShaderCache shaderCache;
    private int drawableW = -1, drawableH = -1;
    private boolean closed;

    public MetalDevice(long window, int debugVerbosity, boolean syncDebug, ShaderSource shaderSource,
                       boolean debugLabels) {
        this.defaultShaderSource = shaderSource;
        Path cache = FabricLoader.getInstance().getGameDir().resolve("titanium").resolve("cache");
        this.shaderCache = new ShaderCache(cache.resolve("msl"));
        this.handle = nDeviceCreate(cache.toString(), 3, debugLabels);
        if (handle == 0) throw Titanium.fatal("could not create the Metal device", nLastError());
        this.caps = com.ethandadev.titanium.natives.TiCapsAccess.parse(nDeviceCaps(handle));

        long nsWindow = GLFWNativeCocoa.glfwGetCocoaWindow(window);
        if (nsWindow == 0) throw Titanium.fatal("GLFW returned no NSWindow for the game window", "");
        this.surface = nSurfaceCreateForNSWindow(handle, nsWindow, PF_BGRA8_UNORM, Titanium.vsync(),
                                                 0.0, true, false);
        if (surface == 0) throw Titanium.fatal("could not attach a CAMetalLayer to the game window", nLastError());

        this.encoder = new MetalCommandEncoder(this);
        // Keep App Nap from throttling the game while it renders, without
        // disabling idle/display sleep (docs/architecture.md section 7).
        this.activityToken = nActivityBegin("Minecraft rendering (Titanium)", true, false);
        nThreadSetQos(QOS_USER_INTERACTIVE);   // this (render) thread only
        Titanium.LOG.info("Titanium active: {}", getImplementationInformation());
    }

    // ---------------------------------------------------------------- creation

    @Override public CommandEncoder createCommandEncoder() { return encoder; }

    @Override
    public GpuSampler createSampler(AddressMode u, AddressMode v, FilterMode min, FilterMode mag,
                                   int aniso, OptionalDouble maxLod) {
        if (aniso < 1 || aniso > getMaxSupportedAnisotropy())
            throw new IllegalArgumentException("maxAnisotropy out of range; must be >= 1 and <= "
                                               + getMaxSupportedAnisotropy() + ", but was " + aniso);
        return new MetalSampler(this, u, v, min, mag, aniso, maxLod);
    }

    @Override
    public GpuTexture createTexture(@Nullable Supplier<String> label, int usage, TextureFormat format,
                                    int w, int h, int layers, int mips) {
        return createTexture(label == null ? null : label.get(), usage, format, w, h, layers, mips);
    }

    @Override
    public GpuTexture createTexture(@Nullable String label, int usage, TextureFormat format,
                                    int w, int h, int layers, int mips) {
        if (mips < 1) throw new IllegalArgumentException("mipLevels must be at least 1");
        if (layers < 1) throw new IllegalArgumentException("depthOrLayers must be at least 1");
        boolean cube = (usage & GpuTexture.USAGE_CUBEMAP_COMPATIBLE) != 0;
        if (cube && (w != h || layers % 6 != 0 || layers > 6))
            throw new IllegalArgumentException("Cubemap-compatible textures must be square with 6 layers");
        if (!cube && layers > 1)
            throw new UnsupportedOperationException("Array or 3D textures are not yet supported");
        return new MetalTexture(this, usage, label == null ? "texture" : label, format, w, h, layers, mips);
    }

    @Override
    public GpuTextureView createTextureView(GpuTexture tex) {
        return createTextureView(tex, 0, tex.getMipLevels());
    }

    @Override
    public GpuTextureView createTextureView(GpuTexture tex, int baseMip, int mips) {
        if (tex.isClosed()) throw new IllegalArgumentException("Can't create texture view with closed texture");
        if (baseMip < 0 || baseMip + mips > tex.getMipLevels())
            throw new IllegalArgumentException(mips + " mip levels starting from " + baseMip
                                               + " would be out of range for texture with only " + tex.getMipLevels());
        return new MetalTextureView((MetalTexture) tex, baseMip, mips);
    }

    @Override
    public GpuBuffer createBuffer(@Nullable Supplier<String> label, int usage, long size) {
        if (size <= 0) throw new IllegalArgumentException("Buffer size must be greater than zero");
        return new MetalBuffer(this, label == null ? null : label.get(), usage, size);
    }

    @Override
    public GpuBuffer createBuffer(@Nullable Supplier<String> label, int usage, ByteBuffer data) {
        if (!data.hasRemaining()) throw new IllegalArgumentException("Buffer source must not be empty");
        MetalBuffer b = new MetalBuffer(this, label == null ? null : label.get(), usage, data.remaining());
        // A brand-new buffer cannot be in use by the GPU: a direct write is safe.
        b.view(0, data.remaining()).put(data.duplicate());
        return b;
    }

    // ---------------------------------------------------------------- pipelines

    @Override
    public CompiledRenderPipeline precompilePipeline(RenderPipeline p, @Nullable ShaderSource source) {
        ShaderSource s = source == null ? defaultShaderSource : source;
        return pipelineCache.computeIfAbsent(p, key -> MetalPipeline.compile(this, key, s));
    }

    ShaderCache shaderCache() { return shaderCache; }

    MetalPipeline pipelineFor(RenderPipeline p) {
        return pipelineCache.computeIfAbsent(p, key -> MetalPipeline.compile(this, key, defaultShaderSource));
    }

    @Override
    public void clearPipelineCache() {
        encoder.flushAndWait();   // nothing in flight may still use these PSOs
        pipelineCache.values().forEach(MetalPipeline::release);
        pipelineCache.clear();
        shaderSources.clear();    // GlDevice drops its shader modules here too
    }

    @Nullable
    String shaderSource(Identifier id, ShaderType type, ShaderDefines defines, ShaderSource source) {
        ShaderKey key = new ShaderKey(id, type, defines);
        String cached = shaderSources.get(key);
        if (cached != null) return cached;
        String raw = source.get(id, type);
        if (raw == null) {
            Titanium.LOG.error("Couldn't find source for {} shader ({})", type, id);   // GlDevice's wording
            return null;
        }
        // Exactly what GlDevice does: ShaderManager has already resolved
        // #moj_import; only the pipeline's defines remain to be injected.
        String text = GlslPreprocessor.injectDefines(raw, defines);
        shaderSources.put(key, text);
        return text;
    }

    long depthState(int compare, boolean write) {
        return depthStates.computeIfAbsent((compare << 1) | (write ? 1 : 0), k -> {
            long ds = nDepthStencilCreate(handle, compare, write, null);
            if (ds == 0) throw new IllegalStateException("Titanium: depth state failed: " + nLastError());
            return ds;
        });
    }

    void syncDrawableSize(int w, int h) {
        if (w != drawableW || h != drawableH) {
            nSurfaceSetDrawableSize(surface, w, h);
            drawableW = w; drawableH = h;
        }
    }

    /** Called when the window's framebuffer changes size or moves display. */
    public void onFramebufferResized() {
        nSurfaceHandleDisplayChange(surface);
        drawableW = drawableH = -1;
    }

    public void setVsync(boolean vsync) { nSurfaceSetVsync(surface, vsync); }

    public double lastGpuMs() { return nDeviceLastGpuMs(handle); }

    /** Upscale for decoupled world resolution; see WorldScaler. */
    public int upscale(GpuTexture src, GpuTexture dst, int mode) { return encoder.upscale(src, dst, mode); }

    public String clearStats() {
        return "clears_folded=" + encoder.clearsFolded + " clears_materialised=" + encoder.clearsMaterialised;
    }

    public long allocatedBytes() { return nDeviceAllocatedBytes(handle); }

    public String pipelineStats() {
        double[] s = nDevicePipelineStats(handle);
        return String.format("pso_created=%d pso_ms=%.1f %s %s", (long) s[0], s[1], MetalPipeline.compileStats(),
                             MetalPipeline.cacheStats(shaderCache));
    }

    // ---------------------------------------------------------------- info

    @Override
    public String getImplementationInformation() {
        return nVersion() + " on Metal, " + caps.deviceName + " (Apple family "
               + caps.appleFamily + (caps.metal4 ? ", Metal 4" : caps.metal3 ? ", Metal 3" : "")
               + "), macOS " + caps.osVersion();
    }
    @Override public List<String> getLastDebugMessages() { return List.of(); }
    @Override public boolean isDebuggingEnabled() { return false; }
    @Override public String getVendor() { return "Apple"; }
    @Override public String getBackendName() { return "Metal (Titanium)"; }
    @Override public String getVersion() { return nVersion(); }
    @Override public String getRenderer() { return caps.deviceName; }
    @Override public int getMaxTextureSize() { return caps.maxTextureSize2D; }
    /** Conservative; see docs/architecture.md 4.2. Over-aligning only wastes space. */
    @Override public int getUniformOffsetAlignment() { return 256; }
    @Override public int getMaxSupportedAnisotropy() { return 16; }

    @Override
    public List<String> getEnabledExtensions() {
        // Capabilities detected on this device (not optimisations in use).
        List<String> l = new ArrayList<>();
        l.add("Metal");
        if (caps.unifiedMemory) l.add("unified memory");
        if (caps.memorylessTargets) l.add("TBDR memoryless attachments");
        if (caps.metalfxSpatial) l.add("MetalFX spatial (capable)");
        if (caps.variableRefresh) l.add("variable refresh " + caps.maxDisplayRefreshHz + " Hz");
        return l;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        encoder.flushAndWait();
        shaderCache.prune();
        pipelineCache.values().forEach(MetalPipeline::release);
        pipelineCache.clear();
        depthStates.values().forEach(ds -> nDepthStencilRelease(ds));
        depthStates.clear();
        if (activityToken != 0) nActivityEnd(activityToken);
        nSurfaceRelease(surface);
        nDeviceRelease(handle);
    }
}
