package com.ethandadev.titanium.backend;

import java.util.concurrent.atomic.AtomicInteger;

/** Live native-backed objects, for leak detection in soak tests and crash reports. */
public final class LiveObjects {
    private LiveObjects() {}
    static final AtomicInteger buffers = new AtomicInteger(), textures = new AtomicInteger(),
                               views = new AtomicInteger(), samplers = new AtomicInteger();

    public static String describe() {
        return "live_buffers=" + buffers.get() + " live_textures=" + textures.get()
             + " live_views=" + views.get() + " live_samplers=" + samplers.get();
    }
}
