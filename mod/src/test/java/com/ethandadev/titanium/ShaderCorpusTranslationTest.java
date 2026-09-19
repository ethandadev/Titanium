package com.ethandadev.titanium;

import com.ethandadev.titanium.natives.NativeLoader;
import com.ethandadev.titanium.shader.GlslPreprocessor;

import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Stream;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * Runs every vanilla 1.21.11 shader through the full Metal path:
 * import resolution, GLSL to MSL translation, and compilation by the Metal
 * shader compiler. Pairs are translated LINKED, as in-game pipelines are.
 *
 * <p>Two passes: no defines (every #ifdef branch off), then every macro the
 * corpus tests turned on, so both sides of each conditional are compiled.
 *
 * <p>Minecraft's assets are not redistributed: pass a directory containing
 * {@code assets/minecraft/shaders}. Without one the test reports SKIPPED.
 */
public final class ShaderCorpusTranslationTest {

    private static int pass = 0, fail = 0;

    static void check(boolean ok, String what) {
        if (ok) { pass++; System.out.println("  ok    " + what); }
        else    { fail++; System.out.println("  FAIL  " + what); }
    }

    /** Every macro the vanilla corpus branches on (surveyed from the jar). */
    static final Map<String, String> ALL_DEFINES = new LinkedHashMap<>();
    static {
        ALL_DEFINES.put("ALPHA_CUTOUT", "0.1");
        ALL_DEFINES.put("PER_FACE_LIGHTING", "");
        ALL_DEFINES.put("EMISSIVE", "");
        ALL_DEFINES.put("NO_CARDINAL_LIGHTING", "");
        ALL_DEFINES.put("NO_OVERLAY", "");
        ALL_DEFINES.put("APPLY_TEXTURE_MATRIX", "");
    }

    record Job(String name, Path vs, Path fs) {}

    public static void main(String[] args) throws Exception {
        System.out.println("=== Titanium vanilla shader corpus -> Metal ===");
        Path root = args.length > 0 ? Paths.get(args[0]) : null;
        if (root == null || !Files.isDirectory(root.resolve("assets/minecraft/shaders"))) {
            System.out.println("SKIPPED - pass a directory containing assets/minecraft/shaders");
            return;
        }
        NativeLoader.Support s = NativeLoader.check();
        if (!s.supported()) { System.out.println("SKIPPED - " + s.reason()); return; }
        nSetLogLevel(LOG_ERROR - 1);   // silence expected per-shader error logs; we report ourselves

        Path shaders = root.resolve("assets/minecraft/shaders");
        GlslPreprocessor pre = new GlslPreprocessor(GlslPreprocessor.directoryResolver(rel -> {
            try { Path p = root.resolve(rel); return Files.isRegularFile(p) ? Files.readString(p) : null; }
            catch (IOException e) { return null; }
        }));

        List<Job> jobs = planJobs(shaders);
        long linked = jobs.stream().filter(j -> j.vs != null && j.fs != null).count();
        System.out.println("  " + jobs.size() + " pipelines to build (" + linked + " linked pairs)");

        long dev = nDeviceCreate(null, 1, false);
        check(dev != 0, "device");

        /* PORTAL_LAYERS is not optional: end_portal loops over it, and the game
         * always supplies it (15 for end_portal, 16 for end_gateway — read from
         * RenderPipelines' bytecode). */
        Map<String, String> required = Map.of("PORTAL_LAYERS", "15");
        Map<String, String> allOn = new LinkedHashMap<>(required);
        allOn.putAll(ALL_DEFINES);
        for (Map<String, String> defines : List.of(required, allOn)) {
            String label = defines.size() == 1 ? "required defines only" : "all " + defines.size() + " defines";
            System.out.println("\n[" + label + "]");
            int ok = 0;
            List<String> problems = new ArrayList<>();
            for (Job j : jobs) {
                String err = runJob(dev, pre, shaders, j, defines);
                if (err == null) ok++; else problems.add(j.name + ": " + err);
            }
            problems.stream().limit(12).forEach(p -> System.out.println("        " + p));
            check(problems.isEmpty(), ok + "/" + jobs.size() + " pipelines translate AND compile with Metal (" + label + ")");
        }

        nDeviceRelease(dev);
        System.out.println("\n=== " + pass + " passed, " + fail + " failed ===");
        if (fail > 0) System.exit(1);
    }

    /** Same-name core pairs are linked; post fragment shaders share the one post vertex shader. */
    static List<Job> planJobs(Path shaders) throws IOException {
        List<Job> jobs = new ArrayList<>();
        Set<Path> used = new HashSet<>();

        Path core = shaders.resolve("core");
        for (Path vs : list(core, ".vsh")) {
            Path fs = core.resolve(stem(vs) + ".fsh");
            if (Files.isRegularFile(fs)) {
                jobs.add(new Job("core/" + stem(vs), vs, fs));
                used.add(vs); used.add(fs);
            }
        }
        Path post = shaders.resolve("post");
        List<Path> postVs = list(post, ".vsh");
        for (Path fs : list(post, ".fsh")) {
            Path vs = postVs.size() == 1 ? postVs.get(0) : null;
            jobs.add(new Job("post/" + stem(fs), vs, fs));
            used.add(fs);
            if (vs != null) used.add(vs);
        }
        for (Path dir : List.of(core, post))
            for (Path p : list(dir, ".vsh", ".fsh"))
                if (!used.contains(p)) {
                    boolean isVs = p.toString().endsWith(".vsh");
                    jobs.add(new Job(shaders.relativize(p) + " (single)", isVs ? p : null, isVs ? null : p));
                }
        return jobs;
    }

    /** @return null on success, otherwise a one-line reason. */
    static String runJob(long dev, GlslPreprocessor pre, Path shaders, Job j, Map<String, String> defines) {
        String vsrc, fsrc;
        try {
            vsrc = j.vs == null ? null : pre.process(j.name + ".vsh", Files.readString(j.vs), defines);
            fsrc = j.fs == null ? null : pre.process(j.name + ".fsh", Files.readString(j.fs), defines);
        } catch (Exception e) { return "preprocess: " + e.getMessage(); }

        long t = nTranslateGlsl(vsrc, fsrc, j.name);
        if (t == 0) return "translate: " + firstLines(nLastError());
        try {
            for (int stage : new int[]{STAGE_VERTEX, STAGE_FRAGMENT}) {
                String msl = nTranslationMsl(t, stage);
                if (msl == null) continue;
                long lib = nLibraryFromSource(dev, msl, null);
                if (lib == 0) return (stage == 0 ? "vertex" : "fragment") + " MSL rejected by Metal: "
                                     + firstLines(nLastError());
                boolean hasEntry = nLibraryHasFunction(lib, nTranslationEntryPoint(t, stage));
                nLibraryRelease(lib);
                if (!hasEntry) return "entry point missing after compile";
            }
            return null;
        } finally {
            nTranslationRelease(t);
        }
    }

    static String firstLines(String s) {
        if (s == null) return "?";
        String[] l = s.split("\n");
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < Math.min(3, l.length); i++) b.append(l[i].trim()).append(" | ");
        return b.toString();
    }

    static String stem(Path p) {
        String n = p.getFileName().toString();
        return n.substring(0, n.lastIndexOf('.'));
    }

    static List<Path> list(Path dir, String... exts) throws IOException {
        if (!Files.isDirectory(dir)) return List.of();
        try (Stream<Path> s = Files.list(dir)) {
            return s.filter(p -> Arrays.stream(exts).anyMatch(e -> p.toString().endsWith(e)))
                    .sorted().toList();
        }
    }
}
