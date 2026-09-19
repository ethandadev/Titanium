package com.ethandadev.titanium.backend;

import com.mojang.blaze3d.textures.GpuTexture;
import com.mojang.blaze3d.textures.TextureFormat;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/** A GpuTexture backed by a private-storage MTLTexture. Uploads go through
 *  frame-ordered staging copies so they respect GL command order. */
public final class MetalTexture extends GpuTexture {
    long handle;
    private boolean closed;

    MetalTexture(MetalDevice device, int usage, String label, TextureFormat format,
                 int width, int height, int depthOrLayers, int mipLevels) {
        super(usage, label, format, width, height, depthOrLayers, mipLevels);
        boolean cube = (usage & USAGE_CUBEMAP_COMPATIBLE) != 0;
        boolean attachment = (usage & USAGE_RENDER_ATTACHMENT) != 0;
        this.handle = nTextureCreate(device.handle, width, height, mipLevels,
                                     cube ? 6 : depthOrLayers, 1, pixelFormat(format),
                                     STORAGE_PRIVATE, attachment, true, false, label, cube);
        if (handle == 0)
            throw new IllegalStateException("Titanium: texture '" + label + "' " + width + "x" + height
                                            + " " + format + " failed: " + nLastError());
    }

    static int pixelFormat(TextureFormat f) {
        return switch (f) {
            case RGBA8 -> PF_RGBA8_UNORM;
            case RED8 -> PF_R8_UNORM;
            case RED8I -> PF_R8_SINT;
            case DEPTH32 -> PF_DEPTH32_FLOAT;
        };
    }

    @Override public boolean isClosed() { return closed; }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        nTextureRelease(handle);
        handle = 0;
    }
}
