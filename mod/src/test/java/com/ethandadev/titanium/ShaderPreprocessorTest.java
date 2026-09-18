package com.ethandadev.titanium;

import com.ethandadev.titanium.shader.GlslPreprocessor;
import com.ethandadev.titanium.shader.GlslPreprocessor.ShaderPreprocessException;

import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Stream;

/**
 * Exercises the preprocessor against the real vanilla shader set.
 *
 * <p>Minecraft's assets are not redistributed with Titanium, so the corpus is
 * located at runtime. Point it at an extracted client jar:
 *
 * <pre>
 *   java ... ShaderPreprocessorTest /path/to/extracted   # contains assets/minecraft/shaders
 * </pre>
 *
 * Without a corpus the synthetic tests still run and the corpus tests are
 * reported as skipped — never as passed.
 */
public final class ShaderPreprocessorTest {

    private static int pass = 0, fail = 0, skip = 0;

    static void check(boolean ok, String what) {
        if (ok) { pass++; System.out.println("  ok    " + what); }
        else    { fail++; System.out.println("  FAIL  " + what); }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("=== Titanium GLSL preprocessor tests ===");

        syntheticTests();

        Path root = locateCorpus(args);
        if (root == null) {
            skip++;
            System.out.println("\n[corpus] SKIPPED - no extracted Minecraft shaders found.");
            System.out.println("         Pass a directory containing assets/minecraft/shaders,");
            System.out.println("         or set TITANIUM_MC_ASSETS.");
        } else {
            corpusTests(root);
        }

        System.out.println("\n=== " + pass + " passed, " + fail + " failed, " + skip + " skipped ===");
        if (fail > 0) System.exit(1);
    }

    // ---------------------------------------------------------------- corpus

    private static Path locateCorpus(String[] args) {
        List<String> candidates = new ArrayList<>();
        if (args.length > 0) candidates.add(args[0]);
        String env = System.getenv("TITANIUM_MC_ASSETS");
        if (env != null) candidates.add(env);
        String tmp = System.getProperty("java.io.tmpdir");
        if (tmp != null) candidates.add(tmp + "/titanium-mc-verify/shaders");
        for (String c : candidates) {
            Path p = Paths.get(c);
            if (Files.isDirectory(p.resolve("assets/minecraft/shaders"))) return p;
        }
        return null;
    }

    private static void corpusTests(Path root) throws IOException {
        Path shaders = root.resolve("assets/minecraft/shaders");
        System.out.println("\n[corpus] " + shaders);

        GlslPreprocessor pre = new GlslPreprocessor(
            GlslPreprocessor.directoryResolver(rel -> {
                try {
                    Path p = root.resolve(rel);
                    return Files.isRegularFile(p) ? Files.readString(p) : null;
                } catch (IOException e) { return null; }
            }));

        // Entry points are core/ and post/; include/ files are never compiled alone.
        List<Path> entries = new ArrayList<>();
        for (String dir : new String[]{"core", "post"}) {
            Path d = shaders.resolve(dir);
            if (!Files.isDirectory(d)) continue;
            try (Stream<Path> s = Files.walk(d)) {
                s.filter(Files::isRegularFile)
                 .filter(p -> { String n = p.getFileName().toString();
                                return n.endsWith(".vsh") || n.endsWith(".fsh"); })
                 .sorted().forEach(entries::add);
            }
        }
        System.out.println("         " + entries.size() + " entry-point shaders");
        check(entries.size() >= 80, "found the vanilla shader corpus (>=80 entry points)");

        Map<String, String> defines = new LinkedHashMap<>();
        defines.put("ALPHA_CUTOUT", "0.1");
        defines.put("TITANIUM", "1");

        int ok = 0, imports = 0;
        List<String> problems = new ArrayList<>();

        for (Path p : entries) {
            String name = shaders.relativize(p).toString();
            String src;
            try { src = Files.readString(p); }
            catch (IOException e) { problems.add(name + ": unreadable"); continue; }

            if (src.contains("#moj_import")) imports++;

            String out;
            try {
                out = pre.process(name, src, defines);
            } catch (ShaderPreprocessException e) {
                problems.add(name + ": " + e.getMessage());
                continue;
            }

            if (out.contains("#moj_import ")) { problems.add(name + ": unresolved import remains"); continue; }

            long versions = out.lines().filter(l -> l.trim().startsWith("#version")).count();
            if (versions != 1) { problems.add(name + ": " + versions + " #version lines"); continue; }

            String firstMeaningful = out.lines()
                    .map(String::trim)
                    .filter(l -> !l.isEmpty())
                    .findFirst().orElse("");
            if (!firstMeaningful.startsWith("#version")) {
                problems.add(name + ": #version is not first (" + firstMeaningful + ")"); continue;
            }
            if (!out.contains("#define ALPHA_CUTOUT 0.1")) {
                problems.add(name + ": defines not injected"); continue;
            }
            ok++;
        }

        System.out.println("         " + imports + " of them use #moj_import");
        if (!problems.isEmpty()) {
            System.out.println("         problems:");
            problems.stream().limit(10).forEach(s -> System.out.println("           " + s));
        }
        check(problems.isEmpty(), "all " + entries.size() + " vanilla shaders preprocess cleanly"
                                  + " (" + ok + " verified)");
        check(imports > 50, "corpus genuinely exercises the import path");

        // Deduplication against REAL content: vanilla's own
        // rendertype_end_portal.vsh imports projection.glsl twice (lines 4 and 6).
        Path dup = shaders.resolve("core/rendertype_end_portal.vsh");
        if (Files.isRegularFile(dup)) {
            String src = Files.readString(dup);
            long importCount = src.lines()
                    .filter(l -> l.trim().equals("#moj_import <minecraft:projection.glsl>"))
                    .count();
            check(importCount == 2, "vanilla end_portal really does import projection.glsl twice");

            String out = pre.process("core/rendertype_end_portal.vsh", src, Map.of());
            long projBlocks = out.lines().filter(l -> l.contains("uniform Projection")).count();
            check(projBlocks == 1,
                  "a doubly-imported include is inlined exactly once (would be a redefinition error otherwise)");
        } else {
            skip++;
            System.out.println("         (dedup check skipped - end_portal shader not present)");
        }
    }

    // ------------------------------------------------------------- synthetic

    private static void syntheticTests() {
        System.out.println("\n[synthetic]");

        Map<String, String> files = new HashMap<>();
        files.put("assets/minecraft/shaders/include/a.glsl",
                  "#version 330\nfloat a_fn() { return 1.0; }");
        files.put("assets/minecraft/shaders/include/loop1.glsl",
                  "#version 330\n#moj_import <minecraft:loop2.glsl>\n");
        files.put("assets/minecraft/shaders/include/loop2.glsl",
                  "#version 330\n#moj_import <minecraft:loop1.glsl>\n");

        GlslPreprocessor pre = new GlslPreprocessor(
                GlslPreprocessor.directoryResolver(files::get));

        String out = pre.process("t.vsh",
                "#version 330\n#moj_import <minecraft:a.glsl>\nvoid main(){ gl_Position = vec4(a_fn()); }",
                Map.of("FOO", "1"));
        check(out.contains("float a_fn()"), "import is inlined");
        check(!out.contains("#moj_import "), "no import directive survives");
        check(out.lines().filter(l -> l.trim().startsWith("#version")).count() == 1,
              "inlined file's own #version is stripped");
        check(out.startsWith("#version 330"), "#version is the first line");
        check(out.contains("#define FOO 1"), "defines are injected");
        check(out.contains("#line "), "#line directives are emitted for diagnostics");

        try {
            pre.process("bad.vsh", "#version 330\n#moj_import <minecraft:missing.glsl>\n", Map.of());
            check(false, "missing import raises");
        } catch (ShaderPreprocessException e) {
            check(e.getMessage().contains("unresolved"), "missing import reports 'unresolved' with context");
        }

        try {
            pre.process("cyc.vsh", "#version 330\n#moj_import <minecraft:loop1.glsl>\n", Map.of());
            check(false, "circular import raises");
        } catch (ShaderPreprocessException e) {
            check(e.getMessage().contains("circular"), "circular import is detected, not a stack overflow");
        }

        try {
            pre.process("mal.vsh", "#version 330\n#moj_import notabracket\n", Map.of());
            check(false, "malformed import raises");
        } catch (ShaderPreprocessException e) {
            check(e.getMessage().contains("malformed"), "malformed directive reports the line");
        }

        // Cache keys
        String k1 = GlslPreprocessor.cacheKey("v1", "source", Map.of("A", "1"));
        String k2 = GlslPreprocessor.cacheKey("v1", "source", Map.of("A", "1"));
        String k3 = GlslPreprocessor.cacheKey("v1", "source", Map.of("A", "2"));
        String k4 = GlslPreprocessor.cacheKey("v2", "source", Map.of("A", "1"));
        String k5 = GlslPreprocessor.cacheKey("v1", "sourc",  Map.of("A", "1"));
        check(k1.equals(k2), "cache key is stable for identical input");
        check(!k1.equals(k3), "cache key changes when a define changes");
        check(!k1.equals(k4), "cache key changes when the backend version changes");
        check(!k1.equals(k5), "cache key changes when the source changes");
        check(GlslPreprocessor.cacheKey("v1", "a", Map.of("BC", "1"))
                .equals(GlslPreprocessor.cacheKey("v1", "a", Map.of("BC", "1"))),
              "length-prefixed key components do not collide across boundaries");
        check(!GlslPreprocessor.cacheKey("v1", "a", Map.of("B", "C1"))
                .equals(GlslPreprocessor.cacheKey("v1", "a", Map.of("BC", "1"))),
              "ambiguous define concatenations produce different keys");
    }
}
