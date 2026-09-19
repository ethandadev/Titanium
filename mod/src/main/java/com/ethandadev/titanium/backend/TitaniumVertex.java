package com.ethandadev.titanium.backend;

import com.ethandadev.titanium.natives.TitaniumNative;

/** Thin indirection so pipeline code reads as intent rather than bit-twiddling. */
final class TitaniumVertex {
    private TitaniumVertex() {}
    static int format(int component, int count, boolean normalized) {
        return TitaniumNative.vertexFormat(component, count, normalized);
    }
}
