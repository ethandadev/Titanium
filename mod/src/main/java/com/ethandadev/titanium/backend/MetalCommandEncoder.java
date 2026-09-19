package com.ethandadev.titanium.backend;

import com.ethandadev.titanium.Titanium;
import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.buffers.GpuFence;
import com.mojang.blaze3d.platform.NativeImage;
import com.mojang.blaze3d.systems.CommandEncoder;
import com.mojang.blaze3d.systems.GpuQuery;
import com.mojang.blaze3d.systems.RenderPass;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.textures.GpuTexture;
import com.mojang.blaze3d.textures.GpuTextureView;
import org.jetbrains.annotations.Nullable;
import org.lwjgl.system.MemoryUtil;

import java.nio.ByteBuffer;
import java.util.OptionalDouble;
import java.util.OptionalInt;
import java.util.function.Supplier;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * Minecraft's CommandEncoder on top of Metal command buffers.
 *
 * <p>The model: OpenGL is one implicit, in-order stream. Titanium keeps one
 * open Metal command buffer (a "batch") and encodes everything into it in call
 * order — render passes, uploads, copies, clears — so ordering is exactly GL's.
 * A batch is committed when the frame is presented, or earlier only when the
 * CPU genuinely has to observe GPU results (a read-mapping, or a fence wait
 * with a non-zero timeout).
 */
final class MetalCommandEncoder implements CommandEncoder {
    final MetalDevice device;
    private long frame;              // open batch, 0 if none
    private long frameSerial;
    private long lastCommitted;      // serial of the last committed batch
    private boolean inRenderPass;

    MetalCommandEncoder(MetalDevice device) { this.device = device; }

    // ---------------------------------------------------------------- batches

    long frame() {
        if (frame == 0) {
            frame = nFrameBegin(device.handle, 0);
            if (frame == 0) throw new IllegalStateException("Titanium: could not begin a command buffer: " + nLastError());
            frameSerial = nFrameSerial(frame);
        }
        return frame;
    }

    /** Serial covering everything encoded so far. */
    long currentSerial() { return frame != 0 ? frameSerial : lastCommitted; }

    boolean isCommitted(long serial) { return serial <= lastCommitted; }

    /** Commit the open batch without presenting. */
    void flush() {
        if (frame == 0) return;
        if (inRenderPass) throw new IllegalStateException("Titanium: flush requested inside a render pass");
        int rc = nFrameEnd(frame, false);
        lastCommitted = frameSerial;
        frame = 0;
        if (rc != OK) Titanium.LOG.error("Titanium: command buffer commit failed: {}", nLastError());
    }

    void flushAndWait() {
        flush();
        if (lastCommitted != 0) nDeviceWaitSerial(device.handle, lastCommitted, -1);
    }

    void passClosed() { inRenderPass = false; }

    private void requireNoPass() {
        if (inRenderPass) throw new IllegalStateException("Close the existing render pass before creating a new one!");
    }

    private static void check(int rc, String what) {
        if (rc != OK) throw new IllegalStateException("Titanium: " + what + " failed (" + resultName(rc) + "): " + nLastError());
    }

    // ---------------------------------------------------------------- passes

    @Override
    public RenderPass createRenderPass(Supplier<String> label, GpuTextureView color, OptionalInt clearColor) {
        return createRenderPass(label, color, clearColor, null, OptionalDouble.empty());
    }

    @Override
    public RenderPass createRenderPass(Supplier<String> label, GpuTextureView color, OptionalInt clearColor,
                                       @Nullable GpuTextureView depth, OptionalDouble clearDepth) {
        requireNoPass();
        if (color.isClosed()) throw new IllegalStateException("Color texture is closed");
        if ((color.texture().usage() & GpuTexture.USAGE_RENDER_ATTACHMENT) == 0)
            throw new IllegalStateException("Color texture must have USAGE_RENDER_ATTACHMENT");
        if (color.texture().getDepthOrLayers() > 1)
            throw new UnsupportedOperationException("Textures with multiple depths or layers are not yet supported as an attachment");
        long f = frame();
        double r = 0, g = 0, b = 0, a = 0;
        if (clearColor.isPresent()) {
            int c = clearColor.getAsInt();
            r = ((c >> 16) & 0xFF) / 255.0; g = ((c >> 8) & 0xFF) / 255.0;
            b = (c & 0xFF) / 255.0; a = ((c >>> 24) & 0xFF) / 255.0;
        }
        long depthHandle = depth == null ? 0 : ((MetalTextureView) depth).handle();
        long pass = nPassBegin(f, ((MetalTextureView) color).handle(), false,
                               clearColor.isPresent() ? LOAD_CLEAR : LOAD_LOAD, STORE_STORE, r, g, b, a,
                               depthHandle,
                               depth != null && clearDepth.isPresent() ? LOAD_CLEAR : LOAD_LOAD,
                               STORE_STORE, clearDepth.orElse(1.0), label.get());
        if (pass == 0) throw new IllegalStateException("Titanium: render pass failed: " + nLastError());
        inRenderPass = true;
        return new MetalRenderPass(this, pass,
                MetalTexture.pixelFormat(color.texture().getFormat()),
                depth == null ? PF_INVALID : MetalTexture.pixelFormat(depth.texture().getFormat()),
                color.getWidth(0), color.getHeight(0));
    }

    // ---------------------------------------------------------------- clears

    @Override
    public void clearColorTexture(GpuTexture tex, int argb) {
        requireNoPass();
        check(nFrameClear(frame(), ((MetalTexture) tex).handle, true, rf(argb), gf(argb), bf(argb), af(argb),
                          0, false, 0, false, 0, 0, 0, 0), "clearColorTexture");
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture color, int argb, GpuTexture depth, double d) {
        requireNoPass();
        check(nFrameClear(frame(), ((MetalTexture) color).handle, true, rf(argb), gf(argb), bf(argb), af(argb),
                          ((MetalTexture) depth).handle, true, d, false, 0, 0, 0, 0), "clearColorAndDepthTextures");
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture color, int argb, GpuTexture depth, double d,
                                           int x, int y, int w, int h) {
        requireNoPass();
        check(nFrameClear(frame(), ((MetalTexture) color).handle, true, rf(argb), gf(argb), bf(argb), af(argb),
                          ((MetalTexture) depth).handle, true, d, true, x, y, w, h), "clearColorAndDepthTextures(rect)");
    }

    @Override
    public void clearDepthTexture(GpuTexture depth, double d) {
        requireNoPass();
        check(nFrameClear(frame(), 0, false, 0, 0, 0, 0, ((MetalTexture) depth).handle, true, d,
                          false, 0, 0, 0, 0), "clearDepthTexture");
    }

    private static double rf(int c) { return ((c >> 16) & 0xFF) / 255.0; }
    private static double gf(int c) { return ((c >> 8) & 0xFF) / 255.0; }
    private static double bf(int c) { return (c & 0xFF) / 255.0; }
    private static double af(int c) { return ((c >>> 24) & 0xFF) / 255.0; }

    // ---------------------------------------------------------------- buffers

    @Override
    public void writeToBuffer(GpuBufferSlice slice, ByteBuffer data) {
        requireNoPass();
        MetalBuffer buf = (MetalBuffer) slice.buffer();
        if ((buf.usage() & GpuBuffer.USAGE_COPY_DST) == 0)
            throw new IllegalStateException("Buffer needs USAGE_COPY_DST to be a destination for a copy");
        int n = data.remaining();
        if (n > slice.length()) throw new IllegalArgumentException("Cannot write more data than the slice allows");
        // glBufferSubData semantics: ordered with the passes around it.
        if (data.isDirect()) {
            check(nFrameUploadBuffer(frame(), buf.handle, slice.offset(), data, data.position(), n), "writeToBuffer");
        } else {
            ByteBuffer tmp = MemoryUtil.memAlloc(n);
            try {
                tmp.put(data.duplicate()).flip();
                check(nFrameUploadBuffer(frame(), buf.handle, slice.offset(), tmp, 0, n), "writeToBuffer");
            } finally { MemoryUtil.memFree(tmp); }
        }
    }

    @Override
    public GpuBuffer.MappedView mapBuffer(GpuBuffer buffer, boolean read, boolean write) {
        return mapBuffer(buffer.slice(), read, write);
    }

    @Override
    public GpuBuffer.MappedView mapBuffer(GpuBufferSlice slice, boolean read, boolean write) {
        requireNoPass();
        MetalBuffer buf = (MetalBuffer) slice.buffer();
        if (!read && !write) throw new IllegalArgumentException("At least read or write must be true");
        if (read && (buf.usage() & GpuBuffer.USAGE_MAP_READ) == 0) throw new IllegalStateException("Buffer is not readable");
        if (write && (buf.usage() & GpuBuffer.USAGE_MAP_WRITE) == 0) throw new IllegalStateException("Buffer is not writable");
        // Reading must observe completed GPU work (e.g. the copy behind a
        // screenshot). Writes follow the persistent-mapping contract: the
        // caller's fences (MappableRingBuffer) guarantee exclusivity.
        if (read) flushAndWait();
        return new MetalBuffer.Mapped(buf.view(slice.offset(), slice.length()));
    }

    @Override
    public void copyToBuffer(GpuBufferSlice src, GpuBufferSlice dst) {
        requireNoPass();
        if (src.length() != dst.length()) throw new IllegalArgumentException("Cannot copy slices of different lengths");
        check(nFrameCopyBuffer(frame(), ((MetalBuffer) src.buffer()).handle, src.offset(),
                               ((MetalBuffer) dst.buffer()).handle, dst.offset(), src.length()), "copyToBuffer");
    }

    // ---------------------------------------------------------------- textures

    @Override
    public void writeToTexture(GpuTexture tex, NativeImage image) {
        writeToTexture(tex, image, 0, 0, 0, 0, tex.getWidth(0), tex.getHeight(0), 0, 0);
    }

    @Override
    public void writeToTexture(GpuTexture tex, NativeImage image, int mip, int layer, int dstX, int dstY,
                               int w, int h, int srcX, int srcY) {
        requireNoPass();
        int comps = image.format().components();
        long base = image.getPointer() + ((long) srcY * image.getWidth() + srcX) * comps;
        upload((MetalTexture) tex, mip, layer, dstX, dstY, w, h, base, image.getWidth() * comps, comps);
    }

    @Override
    public void writeToTexture(GpuTexture tex, ByteBuffer data, NativeImage.Format format, int mip, int layer,
                               int x, int y, int w, int h) {
        requireNoPass();
        int comps = format.components();
        if ((long) w * h * comps > data.remaining())
            throw new IllegalArgumentException("Copy would overrun the source buffer");
        ByteBuffer direct = data;
        boolean tmp = !data.isDirect();
        if (tmp) { direct = MemoryUtil.memAlloc(data.remaining()); direct.put(data.duplicate()).flip(); }
        try {
            upload((MetalTexture) tex, mip, layer, x, y, w, h, MemoryUtil.memAddress(direct), w * comps, comps);
        } finally { if (tmp) MemoryUtil.memFree(direct); }
    }

    /**
     * glTexSubImage2D converts between the client and texture formats
     * implicitly; Metal copies bytes verbatim. So the conversions GL would do
     * are reproduced here: RGB -> (r,g,b,1), RG -> (r,g,0,1), RED -> (r,0,0,1)
     * into RGBA8, and the first channel only into single-channel textures.
     */
    private void upload(MetalTexture tex, int mip, int layer, int x, int y, int w, int h,
                        long src, int srcRowBytes, int srcComps) {
        int dstComps = tex.getFormat().pixelSize();
        long f = frame();
        if (srcComps == dstComps) {
            check(nFrameUploadTextureAddr(f, tex.handle, mip, layer, x, y, w, h, src, srcRowBytes), "writeToTexture");
            return;
        }
        ByteBuffer conv = MemoryUtil.memAlloc(w * h * dstComps);
        try {
            long dst = MemoryUtil.memAddress(conv);
            for (int row = 0; row < h; row++) {
                long s = src + (long) row * srcRowBytes, d = dst + (long) row * w * dstComps;
                for (int col = 0; col < w; col++) {
                    for (int c = 0; c < dstComps; c++) {
                        byte v;
                        if (c < srcComps) v = MemoryUtil.memGetByte(s + (long) col * srcComps + c);
                        else v = (c == 3) ? (byte) 0xFF : 0;
                        MemoryUtil.memPutByte(d + (long) col * dstComps + c, v);
                    }
                }
            }
            check(nFrameUploadTextureAddr(f, tex.handle, mip, layer, x, y, w, h, dst, w * dstComps), "writeToTexture(converted)");
        } finally { MemoryUtil.memFree(conv); }
    }

    @Override
    public void copyTextureToBuffer(GpuTexture tex, GpuBuffer buf, long offset, Runnable callback, int mip) {
        copyTextureToBuffer(tex, buf, offset, callback, mip, 0, 0, tex.getWidth(mip), tex.getHeight(mip));
    }

    @Override
    public void copyTextureToBuffer(GpuTexture tex, GpuBuffer buf, long offset, Runnable callback, int mip,
                                    int x, int y, int w, int h) {
        requireNoPass();
        if (tex.getDepthOrLayers() > 1)
            throw new UnsupportedOperationException("Textures with multiple depths or layers are not yet supported for copying");
        // Render targets keep GL's memory layout, so the bytes land exactly as
        // glReadPixels would have produced them (bottom row first).
        check(nFrameCopyTextureToBuffer(frame(), ((MetalTexture) tex).handle, mip, x, y, w, h,
                                        ((MetalBuffer) buf).handle, offset, w * tex.getFormat().pixelSize()),
              "copyTextureToBuffer");
        RenderSystem.queueFencedTask(callback);   // exactly what GlCommandEncoder does
    }

    @Override
    public void copyTextureToTexture(GpuTexture src, GpuTexture dst, int mip, int dstX, int dstY,
                                     int srcX, int srcY, int w, int h) {
        requireNoPass();
        check(nFrameCopyTexture(frame(), ((MetalTexture) src).handle, mip, srcX, srcY,
                                ((MetalTexture) dst).handle, mip, dstX, dstY, w, h), "copyTextureToTexture");
    }

    // ---------------------------------------------------------------- present

    @Override
    public void presentTexture(GpuTextureView view) {
        requireNoPass();
        if (!view.texture().getFormat().hasColorAspect())
            throw new IllegalStateException("Cannot present a non-color texture!");
        long f = frame();
        device.syncDrawableSize(view.getWidth(0), view.getHeight(0));
        int rc = nFrameBlitFlipped(f, ((MetalTextureView) view).handle(), 0, device.surface);
        boolean present = rc == OK;
        if (rc == SKIPPED_PRESENT) {
            // vsync off and the compositor still holds every drawable: the frame
            // was rendered but the display couldn't show it anyway (GL drops such
            // frames implicitly at swap interval 0).
        } else if (rc == ERR_SURFACE_LOST) {
            // Occluded / minimised / reconfiguring: skip this present, keep the work.
            Titanium.warnOnce("surface-lost", "no drawable available (window hidden?); frames are being skipped");
        } else if (rc != OK) {
            Titanium.LOG.error("Titanium: present failed: {}", nLastError());
        }
        int end = nFrameEnd(f, present);
        lastCommitted = frameSerial;
        frame = 0;
        if (end != OK) Titanium.LOG.error("Titanium: frame commit failed: {}", nLastError());
    }

    // ---------------------------------------------------------------- sync

    @Override
    public GpuFence createFence() {
        requireNoPass();
        return new MetalFence(this, currentSerial());
    }

    @Override
    public GpuQuery timerQueryBegin() {
        frame();
        return new MetalTimerQuery(this);
    }

    @Override
    public void timerQueryEnd(GpuQuery q) {
        ((MetalTimerQuery) q).end(currentSerial());
    }
}
