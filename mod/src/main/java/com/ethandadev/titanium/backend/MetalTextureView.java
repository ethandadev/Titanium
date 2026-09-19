package com.ethandadev.titanium.backend;

import com.mojang.blaze3d.textures.GpuTextureView;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * GL implements views by rewriting GL_TEXTURE_BASE_LEVEL/MAX_LEVEL on the
 * texture at bind time. Metal has real views, so a partial mip range becomes
 * its own MTLTexture view; a full-range view just reuses the texture.
 */
public final class MetalTextureView extends GpuTextureView {
    private long ownHandle;
    private boolean closed;

    MetalTextureView(MetalTexture texture, int baseMip, int mipLevels) {
        super(texture, baseMip, mipLevels);
        if (baseMip != 0 || mipLevels != texture.getMipLevels()) {
            ownHandle = nTextureCreateView(texture.handle, baseMip, mipLevels);
            if (ownHandle == 0)
                throw new IllegalStateException("Titanium: texture view failed: " + nLastError());
            LiveObjects.views.incrementAndGet();
        }
    }

    long handle() {
        return ownHandle != 0 ? ownHandle : ((MetalTexture) texture()).handle;
    }

    @Override public boolean isClosed() { return closed || texture().isClosed(); }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        if (ownHandle != 0) { nTextureRelease(ownHandle); ownHandle = 0; LiveObjects.views.decrementAndGet(); }
    }
}
