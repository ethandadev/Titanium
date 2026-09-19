package com.ethandadev.titanium;

import com.ethandadev.titanium.backend.PrimitiveExpander;
import com.ethandadev.titanium.backend.PrimitiveExpander.Kind;

import java.util.Arrays;

/** Pure-function tests for fan expansion and GL provoking-vertex reordering. */
public final class PrimitiveExpanderTest {
    static int pass, fail;
    static void eq(int[] got, int[] want, String what) {
        boolean ok = Arrays.equals(got, want);
        if (ok) pass++; else fail++;
        System.out.println((ok ? "  ok    " : "  FAIL  ") + what + (ok ? "" : "  got " + Arrays.toString(got)));
    }
    public static void main(String[] a) {
        System.out.println("=== PrimitiveExpander ===");
        int[] seq = { 0, 1, 2, 3, 4 };
        eq(PrimitiveExpander.expand(Kind.LIST, seq, 3, false), new int[]{0,1,2}, "list passthrough");
        eq(PrimitiveExpander.expand(Kind.LIST, new int[]{0,1,2,3,4,5}, 6, true), new int[]{2,0,1, 5,3,4},
           "list, provoking-last: each triangle rotated (c,a,b)");
        eq(PrimitiveExpander.expand(Kind.STRIP, seq, 4, true), new int[]{2,0,1, 3,2,1},
           "strip, provoking-last: even (i+2,i,i+1), odd (i+2,i+1,i) — the pixel-verified order");
        eq(PrimitiveExpander.expand(Kind.STRIP, seq, 5, false), new int[]{0,1,2, 2,1,3, 2,3,4},
           "strip without flat: GL's alternating winding preserved");
        eq(PrimitiveExpander.expand(Kind.FAN, seq, 5, false), new int[]{0,1,2, 0,2,3, 0,3,4}, "fan -> list");
        eq(PrimitiveExpander.expand(Kind.FAN, seq, 4, true), new int[]{2,0,1, 3,0,2},
           "fan, provoking-last (GL's last vertex is v[i+1])");
        eq(PrimitiveExpander.expand(Kind.STRIP, seq, 2, true), new int[0], "degenerate strip -> nothing");
        eq(PrimitiveExpander.expand(Kind.LIST, new int[]{7,8,9}, 3, false), new int[]{7,8,9},
           "indices are passed through, not renumbered");
        System.out.println("=== " + pass + " passed, " + fail + " failed ===");
        if (fail > 0) System.exit(1);
    }
}
