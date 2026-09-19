package com.ethandadev.titanium.backend;

import com.mojang.blaze3d.buffers.GpuFence;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * A fence covers everything encoded before it was created, identified by the
 * submission serial of that batch.
 *
 * <p>Load-bearing: MappableRingBuffer relies on these fences before handing a
 * buffer back for CPU writes into shared memory.
 *
 * <p>GL's glClientWaitSync is called without GL_SYNC_FLUSH_COMMANDS_BIT, so a
 * zero-timeout poll never forces a flush (RenderSystem.executePendingTasks polls
 * with 0 every frame; flushing there would split frames into many command
 * buffers). A real wait on an unsubmitted batch commits it first — otherwise it
 * could never complete.
 */
final class MetalFence implements GpuFence {
    private final MetalCommandEncoder encoder;
    private final long serial;

    MetalFence(MetalCommandEncoder encoder, long serial) {
        this.encoder = encoder;
        this.serial = serial;
    }

    @Override
    public boolean awaitCompletion(long timeoutNs) {
        if (serial == 0) return true;
        long dev = encoder.device.handle;
        if (nDeviceCompletedSerial(dev) >= serial) return true;
        if (!encoder.isCommitted(serial)) {
            if (timeoutNs == 0) return false;
            encoder.flush();
        }
        int rc = nDeviceWaitSerial(dev, serial, timeoutNs == Long.MAX_VALUE ? -1 : timeoutNs);
        return rc == OK;
    }

    @Override public void close() {}
}
