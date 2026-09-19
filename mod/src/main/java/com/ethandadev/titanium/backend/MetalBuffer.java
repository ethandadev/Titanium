package com.ethandadev.titanium.backend;

import com.mojang.blaze3d.buffers.GpuBuffer;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.HashMap;
import java.util.Map;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * A GpuBuffer backed by a shared-storage MTLBuffer.
 *
 * <p>On Apple silicon the CPU and GPU address the same memory, so a mapped view
 * is simply a window onto the buffer: no staging allocation and no copy. That
 * matches the persistent-mapping model Minecraft already uses on OpenGL 4.4+
 * (see BufferStorage.Immutable), where synchronisation is the caller's job via
 * MappableRingBuffer's fences — which is why {@link MetalFence} must be exact.
 */
public final class MetalBuffer extends GpuBuffer {
    final MetalDevice device;
    long handle;
    private final ByteBuffer contents;
    private boolean closed;
    /** Texel-buffer views (isamplerBuffer), keyed by Titanium pixel format. */
    private final Map<Integer, Long> texelViews = new HashMap<>();

    MetalBuffer(MetalDevice device, String label, int usage, long size) {
        super(usage, size);
        this.device = device;
        this.handle = nBufferCreate(device.handle, Math.max(size, 1L), STORAGE_SHARED, label);
        if (handle == 0)
            throw new IllegalStateException("Titanium: Metal buffer allocation of " + size
                                            + " bytes failed: " + nLastError());
        LiveObjects.buffers.incrementAndGet();
        ByteBuffer c = nBufferContents(handle);
        this.contents = c == null ? null : c.order(ByteOrder.nativeOrder());
    }

    /** A native-order window onto [offset, offset+length) of GPU-visible memory. */
    ByteBuffer view(long offset, long length) {
        return contents.slice((int) offset, (int) length).order(ByteOrder.nativeOrder());
    }

    long texelView(int pixelFormat) {
        return texelViews.computeIfAbsent(pixelFormat, f -> {
            long v = nTextureCreateBufferView(handle, f, 0, size());
            if (v == 0) throw new IllegalStateException("Titanium: texel buffer view failed: " + nLastError());
            return v;
        });
    }

    @Override public boolean isClosed() { return closed; }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        // Command buffers retain what they reference, so releasing here is safe
        // even while in-flight frames still read this buffer (GL's deferred
        // delete gives the same guarantee).
        texelViews.values().forEach(v -> nTextureRelease(v));
        texelViews.clear();
        nBufferRelease(handle);
        handle = 0;
        LiveObjects.buffers.decrementAndGet();
    }

    /** GpuBuffer.MappedView over shared memory. Closing it has nothing to flush. */
    record Mapped(ByteBuffer data) implements GpuBuffer.MappedView {
        @Override public void close() {}
    }
}
