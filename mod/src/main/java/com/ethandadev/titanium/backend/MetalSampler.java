package com.ethandadev.titanium.backend;

import com.mojang.blaze3d.textures.AddressMode;
import com.mojang.blaze3d.textures.FilterMode;
import com.mojang.blaze3d.textures.GpuSampler;

import java.util.OptionalDouble;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/** Mirrors GlSampler: the minification filter always uses linear mip blending
 *  (GL_NEAREST_MIPMAP_LINEAR / GL_LINEAR_MIPMAP_LINEAR), and maxLod is a hard clamp. */
public final class MetalSampler extends GpuSampler {
    final long handle;
    private final AddressMode u, v;
    private final FilterMode min, mag;
    private final int aniso;
    private final OptionalDouble maxLod;
    private boolean closed;

    MetalSampler(MetalDevice device, AddressMode u, AddressMode v, FilterMode min, FilterMode mag,
                 int aniso, OptionalDouble maxLod) {
        this.u = u; this.v = v; this.min = min; this.mag = mag; this.aniso = aniso; this.maxLod = maxLod;
        this.handle = nSamplerCreate(device.handle, filter(min), filter(mag), MIP_LINEAR,
                                     address(u), address(v), address(u), aniso,
                                     0f, maxLod.isPresent() ? (float) maxLod.getAsDouble() : -1f, null);
        if (handle == 0) throw new IllegalStateException("Titanium: sampler failed: " + nLastError());
    }

    private static int filter(FilterMode f) { return f == FilterMode.LINEAR ? FILTER_LINEAR : FILTER_NEAREST; }
    private static int address(AddressMode a) { return a == AddressMode.REPEAT ? ADDR_REPEAT : ADDR_CLAMP_TO_EDGE; }

    @Override public AddressMode getAddressModeU() { return u; }
    @Override public AddressMode getAddressModeV() { return v; }
    @Override public FilterMode getMinFilter() { return min; }
    @Override public FilterMode getMagFilter() { return mag; }
    @Override public int getMaxAnisotropy() { return aniso; }
    @Override public OptionalDouble getMaxLod() { return maxLod; }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        nSamplerRelease(handle);
    }
}
