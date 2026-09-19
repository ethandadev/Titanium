package com.ethandadev.titanium.natives;

/** Lets the backend parse a caps string without widening TiCaps' API. */
public final class TiCapsAccess {
    private TiCapsAccess() {}
    public static TiCaps parse(String s) { return TiCaps.parse(s); }
}
