package com.ethandadev.titanium.backend;

/**
 * Builds triangle-list index streams for primitive semantics Metal lacks.
 * Pure and dependency-free, so it is unit-tested outside the game.
 *
 * <ul>
 *   <li><b>Triangle fans</b> do not exist in Metal: fan triangle i is
 *       (v0, v[i], v[i+1]).</li>
 *   <li><b>Provoking vertex</b>: for {@code flat} varyings OpenGL uses a
 *       primitive's LAST vertex, Metal its FIRST, with no setting to change it.
 *       Rotating a triangle (a,b,c) to (c,a,b) moves GL's provoking vertex to
 *       the front while keeping the cyclic order, i.e. the winding.
 *       Strip triangles alternate orientation: even i is (i, i+1, i+2), odd i is
 *       (i+1, i, i+2), and GL's provoking vertex is i+2 in both. Verified against
 *       rendered pixels in ti_translate_test golden test 12.</li>
 * </ul>
 */
public final class PrimitiveExpander {
    private PrimitiveExpander() {}

    public enum Kind { LIST, STRIP, FAN }

    /**
     * @param src           source vertex indices (already resolved from any index buffer)
     * @param count         number of source indices to use
     * @param provokingLast reorder so each triangle's GL-provoking (last) vertex comes first
     * @return triangle-list indices
     */
    public static int[] expand(Kind kind, int[] src, int count, boolean provokingLast) {
        int tris = switch (kind) {
            case LIST -> count / 3;
            case STRIP, FAN -> Math.max(0, count - 2);
        };
        int[] out = new int[tris * 3];
        for (int t = 0; t < tris; t++) {
            int a, b, c;
            switch (kind) {
                case LIST -> { a = src[3 * t]; b = src[3 * t + 1]; c = src[3 * t + 2]; }
                case STRIP -> {
                    if ((t & 1) == 0) { a = src[t]; b = src[t + 1]; }
                    else              { a = src[t + 1]; b = src[t]; }
                    c = src[t + 2];
                }
                default -> { a = src[0]; b = src[t + 1]; c = src[t + 2]; }   // FAN
            }
            if (provokingLast) { out[3 * t] = c; out[3 * t + 1] = a; out[3 * t + 2] = b; }
            else               { out[3 * t] = a; out[3 * t + 1] = b; out[3 * t + 2] = c; }
        }
        return out;
    }
}
