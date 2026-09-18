package com.ethandadev.titanium.natives;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Locale;

/**
 * Locates and loads {@code libtitanium.dylib}, and decides — before touching
 * any native code — whether this machine can run Titanium at all.
 *
 * <p>Startup contract: {@link #check()} never throws and never loads native
 * code on an unsupported system. It returns a {@link Support} describing
 * exactly why Titanium is or is not available, so the caller can fall back to
 * the stock renderer with a log line a user can act on.
 */
public final class NativeLoader {
    private NativeLoader() {}

    /** Path override for development: {@code -Dtitanium.native.path=/path/to/libtitanium.dylib}. */
    public static final String PROP_PATH = "titanium.native.path";
    /** Hard off switch: {@code -Dtitanium.enabled=false}. */
    public static final String PROP_ENABLED = "titanium.enabled";

    private static final String RESOURCE = "/natives/macos-arm64/libtitanium.dylib";

    public record Support(boolean supported, String reason, TiCaps caps) {
        public static Support no(String why)  { return new Support(false, why, null); }
        public static Support yes(TiCaps c)   { return new Support(true, "ok", c); }
    }

    private static volatile boolean loaded = false;
    private static volatile String loadError = null;

    /**
     * Full startup check. Safe to call on any OS; performs the cheap platform
     * checks first and only then loads the library and probes Metal.
     */
    public static synchronized Support check() {
        if ("false".equalsIgnoreCase(System.getProperty(PROP_ENABLED)))
            return Support.no("disabled by -D" + PROP_ENABLED + "=false");

        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        if (!os.contains("mac"))
            return Support.no("Titanium is a macOS-only renderer (running on: "
                              + System.getProperty("os.name") + ")");

        String arch = System.getProperty("os.arch", "");
        if (!"aarch64".equals(arch))
            return Support.no("Titanium ships an arm64 native library; this JVM reports os.arch="
                              + arch + ". Use an Apple silicon JVM, or run without Titanium.");

        try {
            load();
        } catch (Throwable t) {
            return Support.no("could not load libtitanium.dylib: " + t);
        }

        String probe;
        try {
            probe = TitaniumNative.nProbe();
        } catch (Throwable t) {
            return Support.no("native probe failed: " + t);
        }
        if (probe == null)
            return Support.no("no Metal device available on this machine");

        TiCaps caps = TiCaps.parse(probe);
        if (caps.osMajor < 12)
            return Support.no("Titanium requires macOS 12 or newer; found " + caps.osVersion());
        if (!caps.appleSilicon)
            return Support.no("Titanium currently targets Apple silicon; device '"
                              + caps.deviceName + "' is not a unified-memory Apple GPU");

        return Support.yes(caps);
    }

    /** Loads the native library, extracting it from the jar when necessary. */
    public static synchronized void load() throws IOException {
        if (loaded) return;
        if (loadError != null) throw new IOException(loadError);

        String override = System.getProperty(PROP_PATH);
        try {
            if (override != null && !override.isBlank()) {
                System.load(Paths.get(override).toAbsolutePath().toString());
            } else {
                System.load(extractFromJar().toString());
            }
            loaded = true;
        } catch (Throwable t) {
            loadError = String.valueOf(t);
            throw new IOException("failed to load native library", t);
        }
    }

    public static boolean isLoaded() { return loaded; }

    /**
     * Extracts the bundled dylib to a cache directory keyed by its own SHA-256,
     * so a new build never collides with a stale extracted copy and repeated
     * launches reuse the same file.
     */
    private static Path extractFromJar() throws IOException {
        byte[] bytes;
        try (InputStream in = NativeLoader.class.getResourceAsStream(RESOURCE)) {
            if (in == null)
                throw new IOException("native library not found on the classpath at " + RESOURCE
                        + " (set -D" + PROP_PATH + " when running from a development tree)");
            bytes = in.readAllBytes();
        }

        String digest;
        try {
            digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes))
                               .substring(0, 16);
        } catch (Exception e) {
            throw new IOException("cannot hash native library", e);
        }

        Path dir = Paths.get(System.getProperty("java.io.tmpdir"), "titanium-natives", digest);
        Path out = dir.resolve("libtitanium.dylib");
        if (Files.isRegularFile(out) && Files.size(out) == bytes.length) return out;

        Files.createDirectories(dir);
        Path tmp = Files.createTempFile(dir, "libtitanium", ".dylib.tmp");
        Files.write(tmp, bytes);
        try {
            Files.setPosixFilePermissions(tmp, PosixFilePermissions.fromString("r-xr-xr-x"));
        } catch (UnsupportedOperationException ignored) {
            // Non-POSIX filesystem; the dylib does not need the executable bit to be dlopen'd.
        }
        try {
            Files.move(tmp, out, StandardCopyOption.ATOMIC_MOVE);
        } catch (FileAlreadyExistsException | AtomicMoveNotSupportedException e) {
            // Another JVM won the race, or the FS cannot do atomic moves; either is fine.
            Files.deleteIfExists(tmp);
        }
        return out;
    }
}
