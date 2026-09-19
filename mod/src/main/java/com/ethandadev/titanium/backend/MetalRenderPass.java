package com.ethandadev.titanium.backend;

import com.ethandadev.titanium.Titanium;
import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.pipeline.RenderPipeline;
import com.mojang.blaze3d.platform.DepthTestFunction;
import com.mojang.blaze3d.platform.LogicOp;
import com.mojang.blaze3d.platform.PolygonMode;
import com.mojang.blaze3d.systems.RenderPass;
import com.mojang.blaze3d.textures.GpuSampler;
import com.mojang.blaze3d.textures.GpuTextureView;
import com.mojang.blaze3d.vertex.VertexFormat;
import org.jetbrains.annotations.Nullable;
import org.lwjgl.system.MemoryUtil;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import java.util.Collection;
import java.util.HashMap;
import java.util.Map;
import java.util.function.BiConsumer;
import java.util.function.Supplier;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * A Minecraft RenderPass over one MTLRenderCommandEncoder.
 *
 * <p>Mirrors GlRenderPass + GlCommandEncoder.trySetup: state is recorded by name
 * and resolved against the pipeline's reflection at draw time. Metal encoder
 * state persists across draws, so each binding is only re-issued when it
 * actually changes — the per-draw JNI cost stays proportional to real state
 * changes, not to the number of uniforms a pipeline declares.
 */
final class MetalRenderPass implements RenderPass {
    private final MetalCommandEncoder encoder;
    private final long pass;
    private final int colorFormat, depthFormat;
    private final int targetW, targetH;

    private @Nullable MetalPipeline pipeline;
    private final Map<String, GpuBufferSlice> uniforms = new HashMap<>();
    private final Map<String, GpuTextureView> textures = new HashMap<>();
    private final Map<String, GpuSampler> samplers = new HashMap<>();
    private @Nullable GpuBuffer vertexBuffer;
    private @Nullable GpuBuffer indexBuffer;
    private VertexFormat.IndexType indexType = VertexFormat.IndexType.SHORT;
    private boolean scissor;
    private int sx, sy, sw, sh;
    private boolean closed;

    // --- what the encoder currently has bound (to skip redundant calls) ---
    private long boundPso, boundDepthState, boundVertexBuffer;
    private int boundCull = -1, boundWire = -1;
    private float boundBiasC = Float.NaN, boundBiasS = Float.NaN;
    private int bSx = -1, bSy = -1, bSw = -1, bSh = -1;
    private final long[][] boundBuf = { new long[31], new long[31] };      // [stage][slot]
    private final long[][] boundOff = { new long[31], new long[31] };
    private final long[][] boundTex = { new long[32], new long[32] };
    private final long[][] boundSmp = { new long[16], new long[16] };

    MetalRenderPass(MetalCommandEncoder encoder, long pass, int colorFormat, int depthFormat, int w, int h) {
        this.encoder = encoder; this.pass = pass;
        this.colorFormat = colorFormat; this.depthFormat = depthFormat;
        this.targetW = w; this.targetH = h;
        for (long[] a : boundOff) Arrays.fill(a, -1);
        nPassSetViewport(pass, 0, 0, w, h, 0, 1);            // GL: viewport = full view
        // GL's front face is CCW; clip-space Y is negated by the translator, so
        // Metal must treat CW as front (verified by golden test 6).
        nPassSetFrontFaceCcw(pass, false);
    }

    // ---------------------------------------------------------------- state

    @Override public void pushDebugGroup(Supplier<String> label) { nPassPushDebugGroup(pass, label.get()); }
    @Override public void popDebugGroup() { nPassPopDebugGroup(pass); }

    @Override
    public void setPipeline(RenderPipeline p) {
        this.pipeline = encoder.device.pipelineFor(p);
    }

    @Override
    public void bindTexture(String name, @Nullable GpuTextureView view, @Nullable GpuSampler sampler) {
        // GlRenderPass: a null sampler unbinds the name.
        if (sampler == null) { textures.remove(name); samplers.remove(name); return; }
        textures.put(name, view);
        samplers.put(name, sampler);
    }

    @Override public void setUniform(String name, GpuBuffer buffer) { uniforms.put(name, buffer.slice()); }

    @Override
    public void setUniform(String name, GpuBufferSlice slice) {
        int align = encoder.device.getUniformOffsetAlignment();
        if (slice.offset() % align > 0)
            throw new IllegalArgumentException("Uniform buffer offset must be aligned to " + align);
        uniforms.put(name, slice);
    }

    @Override
    public void enableScissor(int x, int y, int w, int h) {
        scissor = true; sx = x; sy = y; sw = w; sh = h;
    }

    @Override public void disableScissor() { scissor = false; }

    @Override
    public void setVertexBuffer(int slot, GpuBuffer buffer) {
        if (slot != 0) throw new IllegalArgumentException("Vertex buffer slot is out of range: " + slot);
        vertexBuffer = buffer;
    }

    @Override
    public void setIndexBuffer(@Nullable GpuBuffer buffer, VertexFormat.IndexType type) {
        indexBuffer = buffer;
        indexType = type;
    }

    // ---------------------------------------------------------------- draws

    @Override
    public void drawIndexed(int baseVertex, int firstIndex, int indexCount, int instanceCount) {
        if (closed) throw new IllegalStateException("Can't use a closed render pass");
        if (!setup()) return;
        drawFromBuffers(baseVertex, firstIndex, indexCount, indexType, instanceCount);
    }

    @Override
    public <T> void drawMultipleIndexed(Collection<Draw<T>> draws, @Nullable GpuBuffer defaultIndexBuffer,
                                        @Nullable VertexFormat.IndexType defaultType,
                                        Collection<String> dynamicUniforms, T userData) {
        if (closed) throw new IllegalStateException("Can't use a closed render pass");
        if (!setup()) return;
        VertexFormat.IndexType fallback = defaultType == null ? VertexFormat.IndexType.SHORT : defaultType;
        for (Draw<T> d : draws) {
            VertexFormat.IndexType t = d.indexType() == null ? fallback : d.indexType();
            indexBuffer = d.indexBuffer() == null ? defaultIndexBuffer : d.indexBuffer();
            indexType = t;
            vertexBuffer = d.vertexBuffer();
            BiConsumer<T, UniformUploader> up = d.uniformUploaderConsumer();
            if (up != null) up.accept(userData, (name, slice) -> {
                uniforms.put(name, slice);
                bindBlock(name, slice);
            });
            bindVertexBuffer();
            drawFromBuffers(0, d.firstIndex(), d.indexCount(), t, 1);
        }
    }

    @Override
    public void draw(int first, int count) {
        if (closed) throw new IllegalStateException("Can't use a closed render pass");
        if (!setup()) return;
        MetalPipeline p = pipeline;
        if (p.info.getVertexFormatMode() == VertexFormat.Mode.TRIANGLE_FAN) {
            drawFan(first, count, null, 0);
            return;
        }
        nPassDraw(pass, primitive(p.info.getVertexFormatMode()), first, count, 1);
    }

    private void drawFromBuffers(int baseVertex, int firstIndex, int count,
                                 VertexFormat.IndexType type, int instances) {
        MetalBuffer ib = (MetalBuffer) indexBuffer;
        if (ib == null) { Titanium.warnOnce("draw-no-index", "indexed draw without an index buffer; skipped"); return; }
        if (pipeline.info.getVertexFormatMode() == VertexFormat.Mode.TRIANGLE_FAN) {
            drawFan(firstIndex, count, ib, baseVertex);
            return;
        }
        nPassDrawIndexed(pass, primitive(pipeline.info.getVertexFormatMode()), count,
                         type == VertexFormat.IndexType.INT ? INDEX_U32 : INDEX_U16,
                         ib.handle, (long) firstIndex * type.bytes, instances, baseVertex);
    }

    /**
     * Metal has no triangle fans. Expand to a triangle list: (0,i,i+1) for each
     * i. For indexed fans the source indices are read straight out of shared
     * memory. The temporary index buffer is released immediately; the command
     * buffer retains it until the GPU is done.
     */
    private void drawFan(int first, int count, @Nullable MetalBuffer srcIndices, int baseVertex) {
        if (count < 3) return;
        int tris = count - 2;
        ByteBuffer idx = MemoryUtil.memAlloc(tris * 3 * 4).order(ByteOrder.nativeOrder());
        try {
            ByteBuffer src = srcIndices == null ? null : srcIndices.view(0, srcIndices.size());
            int bytes = indexType.bytes;
            for (int i = 1; i <= tris; i++) {
                int[] tri = { 0, i, i + 1 };
                for (int k : tri) {
                    int v;
                    if (src == null) v = first + k;
                    else {
                        int at = (first + k) * bytes;
                        v = bytes == 2 ? (src.getShort(at) & 0xffff) : src.getInt(at);
                    }
                    idx.putInt(v);
                }
            }
            idx.flip();
            long tmp = nBufferCreate(encoder.device.handle, idx.remaining(), STORAGE_SHARED, "titanium-fan");
            if (tmp == 0) return;
            nBufferContents(tmp).put(idx);
            nPassDrawIndexed(pass, PRIM_TRIANGLES, tris * 3, INDEX_U32, tmp, 0, 1, baseVertex);
            nBufferRelease(tmp);
        } finally {
            MemoryUtil.memFree(idx);
        }
    }

    /** GlConst.toGl(VertexFormat.Mode): LINES and QUADS are *triangles* (index-expanded). */
    private static int primitive(VertexFormat.Mode m) {
        return switch (m) {
            case LINES, TRIANGLES, QUADS, TRIANGLE_FAN -> PRIM_TRIANGLES;
            case TRIANGLE_STRIP -> PRIM_TRIANGLE_STRIP;
            case DEBUG_LINES -> PRIM_LINES;
            case DEBUG_LINE_STRIP -> PRIM_LINE_STRIP;
            case POINTS -> PRIM_POINTS;
        };
    }

    /** GlCommandEncoder.trySetup + applyPipelineState, against Metal encoder state. */
    private boolean setup() {
        MetalPipeline p = pipeline;
        if (p == null || !p.isValid()) return false;
        RenderPipeline info = p.info;
        if (info.getColorLogic() != LogicOp.NONE) {
            // Metal has no logic ops (docs/architecture.md 4.4). Refuse rather
            // than draw something subtly wrong.
            Titanium.warnOnce("logicop:" + info.getLocation(),
                "pipeline " + info.getLocation() + " uses LogicOp." + info.getColorLogic()
                + ", which Metal cannot express; its draws are skipped");
            return false;
        }
        long pso = p.pso(colorFormat, depthFormat);
        if (pso == 0) return false;
        if (pso != boundPso) { nPassSetPipeline(pass, pso); boundPso = pso; }

        // GL: with the depth test disabled the depth buffer is not written
        // either, whatever the depth mask says.
        long ds;
        if (depthFormat == PF_INVALID || info.getDepthTestFunction() == DepthTestFunction.NO_DEPTH_TEST)
            ds = encoder.device.depthState(CMP_ALWAYS, false);
        else
            ds = encoder.device.depthState(compare(info.getDepthTestFunction()), info.isWriteDepth());
        if (ds != boundDepthState) { nPassSetDepthStencil(pass, ds); boundDepthState = ds; }

        int cull = info.isCull() ? 2 : 0;
        if (cull != boundCull) { nPassSetCullMode(pass, cull); boundCull = cull; }
        int wire = info.getPolygonMode() == PolygonMode.WIREFRAME ? 1 : 0;
        if (wire != boundWire) { nPassSetWireframe(pass, wire == 1); boundWire = wire; }
        float bc = info.getDepthBiasConstant(), bs = info.getDepthBiasScaleFactor();
        if (bc != boundBiasC || bs != boundBiasS) {
            nPassSetDepthBias(pass, bc, bs, 0f);   // glPolygonOffset(factor=scale, units=constant)
            boundBiasC = bc; boundBiasS = bs;
        }

        for (Map.Entry<String, int[]> e : p.refl.blocks.entrySet()) {
            GpuBufferSlice s = uniforms.get(e.getKey());
            if (s != null) bindBlock(e.getKey(), s);
        }
        for (Map.Entry<String, int[]> e : p.refl.samplers.entrySet()) {
            int slot = e.getValue()[0], stages = e.getValue()[1];
            if (e.getValue()[2] == 1) {
                // Texel buffer, supplied through setUniform (UniformType.TEXEL_BUFFER).
                GpuBufferSlice s = uniforms.get(e.getKey());
                if (s == null) continue;
                int fmt = texelFormat(info, e.getKey());
                if (fmt == PF_INVALID) continue;
                bindTexture(stages, slot, ((MetalBuffer) s.buffer()).texelView(fmt), 0);
            } else {
                GpuTextureView v = textures.get(e.getKey());
                GpuSampler smp = samplers.get(e.getKey());
                if (v == null || smp == null) continue;
                bindTexture(stages, slot, ((MetalTextureView) v).handle(), ((MetalSampler) smp).handle);
            }
        }

        bindVertexBuffer();

        int x = 0, y = 0, w = targetW, h = targetH;
        if (scissor) {
            // GL window coords; render targets keep GL's memory layout, so y
            // maps straight onto Metal rows. Clamp: Metal rejects out-of-bounds rects.
            x = Math.max(0, Math.min(sx, targetW)); y = Math.max(0, Math.min(sy, targetH));
            w = Math.max(0, Math.min(sw, targetW - x)); h = Math.max(0, Math.min(sh, targetH - y));
        }
        if (x != bSx || y != bSy || w != bSw || h != bSh) {
            nPassSetScissor(pass, x, y, w, h);
            bSx = x; bSy = y; bSw = w; bSh = h;
        }
        return true;
    }

    private void bindVertexBuffer() {
        MetalBuffer vb = (MetalBuffer) vertexBuffer;
        long h = vb == null ? 0 : vb.handle;
        if (h != 0 && h != boundVertexBuffer) {
            nPassSetVertexBuffer(pass, VERTEX_BUFFER_INDEX, h, 0);
            boundVertexBuffer = h;
        }
    }

    private void bindBlock(String name, GpuBufferSlice s) {
        MetalPipeline p = pipeline;
        if (p == null) return;
        int[] b = p.refl.blocks.get(name);
        if (b == null) return;   // GL: binding an inactive uniform is a no-op
        long h = ((MetalBuffer) s.buffer()).handle, off = s.offset();
        int slot = b[0];
        if ((b[1] & 1) != 0 && (boundBuf[0][slot] != h || boundOff[0][slot] != off)) {
            nPassSetVertexBuffer(pass, slot, h, off);
            boundBuf[0][slot] = h; boundOff[0][slot] = off;
        }
        if ((b[1] & 2) != 0 && (boundBuf[1][slot] != h || boundOff[1][slot] != off)) {
            nPassSetFragmentBuffer(pass, slot, h, off);
            boundBuf[1][slot] = h; boundOff[1][slot] = off;
        }
    }

    private void bindTexture(int stages, int slot, long tex, long smp) {
        if ((stages & 1) != 0) {
            if (boundTex[0][slot] != tex) { nPassSetVertexTexture(pass, slot, tex); boundTex[0][slot] = tex; }
            if (smp != 0 && boundSmp[0][slot] != smp) { nPassSetVertexSampler(pass, slot, smp); boundSmp[0][slot] = smp; }
        }
        if ((stages & 2) != 0) {
            if (boundTex[1][slot] != tex) { nPassSetFragmentTexture(pass, slot, tex); boundTex[1][slot] = tex; }
            if (smp != 0 && boundSmp[1][slot] != smp) { nPassSetFragmentSampler(pass, slot, smp); boundSmp[1][slot] = smp; }
        }
    }

    private static int texelFormat(RenderPipeline info, String name) {
        for (RenderPipeline.UniformDescription u : info.getUniforms()) {
            if (u.name().equals(name) && u.textureFormat() != null) return MetalTexture.pixelFormat(u.textureFormat());
        }
        return PF_INVALID;
    }

    private static int compare(DepthTestFunction f) {
        return switch (f) {
            case NO_DEPTH_TEST -> CMP_ALWAYS;
            case EQUAL_DEPTH_TEST -> CMP_EQUAL;
            case LEQUAL_DEPTH_TEST -> CMP_LEQUAL;
            case LESS_DEPTH_TEST -> CMP_LESS;
            case GREATER_DEPTH_TEST -> CMP_GREATER;
        };
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        nPassEnd(pass);
        encoder.passClosed();
    }
}
