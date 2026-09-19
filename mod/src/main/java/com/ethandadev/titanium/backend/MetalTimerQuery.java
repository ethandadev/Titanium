package com.ethandadev.titanium.backend;

import com.mojang.blaze3d.systems.GpuQuery;

import java.util.OptionalLong;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * Approximation, documented as such: GL brackets an exact command range with
 * GL_TIME_ELAPSED. Titanium reports the driver's GPU time for the most recently
 * completed command buffer once the bracketed work has finished. Minecraft
 * brackets a whole frame, which is also one command buffer here, so the two
 * normally coincide; they diverge only if a frame was split by a forced flush.
 */
final class MetalTimerQuery implements GpuQuery {
    private final MetalCommandEncoder encoder;
    private long endSerial = -1;

    MetalTimerQuery(MetalCommandEncoder encoder) { this.encoder = encoder; }

    void end(long serial) { endSerial = serial; }

    @Override
    public OptionalLong getValue() {
        if (endSerial < 0) return OptionalLong.empty();
        if (nDeviceCompletedSerial(encoder.device.handle) < endSerial) return OptionalLong.empty();
        double ms = nDeviceLastGpuMs(encoder.device.handle);
        return ms < 0 ? OptionalLong.empty() : OptionalLong.of((long) (ms * 1_000_000.0));
    }

    @Override public void close() {}
}
