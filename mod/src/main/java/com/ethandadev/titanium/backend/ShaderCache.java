package com.ethandadev.titanium.backend;

import com.ethandadev.titanium.Titanium;
import com.ethandadev.titanium.shader.GlslPreprocessor;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.stream.Stream;

/**
 * On-disk cache of translated MSL.
 *
 * <p>Measured: GLSL->MSL translation is the dominant shader cost at startup
 * (~131 ms for 96 pipeline compilations on an M3 Max), while compiling the MSL
 * (~4 ms) and creating pipeline states (~3 ms) are already cheap thanks to the
 * OS's own Metal compiler cache. So this cache stores translator output.
 *
 * <p>Key: GlslPreprocessor.cacheKey over (translator version, vertex source,
 * fragment source), every component length-prefixed so no concatenation can
 * collide. Sources already have defines injected, so a resource pack or define
 * change is a different key. Entries are length-prefixed text written
 * atomically; anything unreadable is ignored and retranslated. Entries not used
 * during a session are pruned at shutdown, bounding the directory to the last
 * session's working set.
 */
final class ShaderCache {
    /** Bump when translation output could change: native ABI, pinned compilers, fixups. */
    static final String TRANSLATOR_VERSION = "ti-0.2/glslang+spvc-vulkan-sdk-1.4.357.0/fixups-3";
    private static final String MAGIC = "TI-MSL-CACHE 1";

    record Entry(String vsMsl, String fsMsl, String vsEntry, String fsEntry, String reflection) {}

    private final Path dir;
    private final Set<String> used = new HashSet<>();
    long hits, misses;

    ShaderCache(Path dir) {
        this.dir = dir;
        try { Files.createDirectories(dir); } catch (IOException e) { /* cache just stays cold */ }
    }

    static String key(String vs, String fs) {
        return GlslPreprocessor.cacheKey(TRANSLATOR_VERSION, vs, Map.of("fragment", fs));
    }

    Entry get(String key) {
        used.add(key);
        Path p = dir.resolve(key + ".msl");
        if (!Files.isRegularFile(p)) { misses++; return null; }
        try {
            String s = Files.readString(p, StandardCharsets.UTF_8);
            int[] pos = { 0 };
            if (!next(s, pos).equals(MAGIC)) throw new IOException("bad magic");
            Entry e = new Entry(next(s, pos), next(s, pos), next(s, pos), next(s, pos), next(s, pos));
            hits++;
            return e;
        } catch (Exception ex) {
            Titanium.LOG.debug("Titanium shader cache: ignoring unreadable entry {}: {}", key, ex.toString());
            misses++;
            return null;
        }
    }

    void put(String key, Entry e) {
        used.add(key);
        StringBuilder b = new StringBuilder();
        for (String part : new String[]{ MAGIC, e.vsMsl(), e.fsMsl(), e.vsEntry(), e.fsEntry(), e.reflection() })
            b.append(part.length()).append('\n').append(part);
        try {
            Path tmp = dir.resolve(key + ".tmp");
            Files.writeString(tmp, b.toString(), StandardCharsets.UTF_8);
            Files.move(tmp, dir.resolve(key + ".msl"), StandardCopyOption.REPLACE_EXISTING,
                       StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException ex) {
            Titanium.LOG.debug("Titanium shader cache: could not write {}: {}", key, ex.toString());
        }
    }

    void remove(String key) {
        try { Files.deleteIfExists(dir.resolve(key + ".msl")); } catch (IOException ignored) {}
    }

    /** Drop entries this session never asked for. */
    void prune() {
        try (Stream<Path> s = Files.list(dir)) {
            s.filter(p -> p.toString().endsWith(".msl"))
             .filter(p -> !used.contains(p.getFileName().toString().replace(".msl", "")))
             .forEach(p -> { try { Files.delete(p); } catch (IOException ignored) {} });
        } catch (IOException ignored) {}
    }

    /** Length-prefixed field: "<len>" newline "<len chars>". */
    private static String next(String s, int[] pos) throws IOException {
        int nl = s.indexOf('\n', pos[0]);
        if (nl < 0) throw new IOException("truncated");
        int len = Integer.parseInt(s.substring(pos[0], nl));
        int start = nl + 1, end = start + len;
        if (end > s.length()) throw new IOException("truncated");
        pos[0] = end;
        return s.substring(start, end);
    }
}
