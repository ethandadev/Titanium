package com.ethandadev.titanium.shader;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;

/**
 * Resolves Minecraft's {@code #moj_import} directives and normalises a shader
 * into a single translation unit that a GLSL front end will accept.
 *
 * <p>This is the first stage of the GLSL to MSL path. It runs on the Java side
 * because that is where the resource-pack stack lives: a pack may override any
 * shader or include, and the override must be picked up by the same lookup
 * vanilla uses.
 *
 * <p>What it guarantees about its output, because a GLSL front end rejects
 * anything else:
 * <ul>
 *   <li>exactly one {@code #version} directive, first;</li>
 *   <li>no {@code #moj_import} directives remain;</li>
 *   <li>each imported file is inlined at most once, however many times it is
 *       imported;</li>
 *   <li>{@code #line} directives are emitted so compiler errors point back at
 *       the original file and line rather than at an offset into the
 *       concatenated blob.</li>
 * </ul>
 *
 * <p>Import forms, matching vanilla's own preprocessor:
 * <pre>
 *   #moj_import &lt;namespace:file.glsl&gt;   resolves to the shaders/include directory
 *   #moj_import "file.glsl"             resolves relative to the shaders root
 * </pre>
 * Vanilla 1.21.11 only uses the angle-bracket form (8 distinct includes across
 * 93 shader files), but the quoted form is supported because packs may use it.
 */
public final class GlslPreprocessor {

    /** Thrown for a missing import, a circular import, or a malformed directive. */
    public static final class ShaderPreprocessException extends RuntimeException {
        public ShaderPreprocessException(String message) { super(message); }
    }

    /**
     * Resolves an import id to source text, or returns {@code null} if absent.
     * Backed by the resource manager in the mod, by a directory in tests.
     */
    @FunctionalInterface
    public interface SourceResolver {
        String resolve(String namespace, String path);
    }

    private final SourceResolver resolver;

    public GlslPreprocessor(SourceResolver resolver) {
        this.resolver = resolver;
    }

    /**
     * @param rootName identifier for the entry-point shader, used in messages
     * @param source   the entry-point shader source
     * @param defines  macros injected immediately after {@code #version}
     */
    public String process(String rootName, String source, Map<String, String> defines) {
        Result r = new Result();
        // `imported` tracks files already inlined; `stack` detects cycles.
        expand(rootName, source, r, new LinkedHashSet<>(), new ArrayDeque<>());

        StringBuilder out = new StringBuilder(source.length() + 2048);
        out.append(r.version != null ? r.version : "#version 330").append('\n');

        if (defines != null && !defines.isEmpty()) {
            for (Map.Entry<String, String> e : defines.entrySet()) {
                out.append("#define ").append(e.getKey());
                if (e.getValue() != null && !e.getValue().isEmpty())
                    out.append(' ').append(e.getValue());
                out.append('\n');
            }
        }
        for (String line : r.lines) out.append(line).append('\n');
        return out.toString();
    }

    private static final class Result {
        String version;                       // the first #version seen wins
        final List<String> lines = new ArrayList<>();
    }

    private void expand(String name, String source, Result out,
                        Set<String> imported, Deque<String> stack) {
        if (stack.contains(name))
            throw new ShaderPreprocessException(
                    "circular #moj_import: " + String.join(" -> ", stack) + " -> " + name);
        stack.push(name);

        String[] lines = source.split("\n", -1);
        out.lines.add("#line 1");

        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            String trimmed = line.trim();

            if (trimmed.startsWith("#version")) {
                // Only the outermost version survives; an inlined include's own
                // #version would be a syntax error mid-file.
                if (out.version == null) out.version = trimmed;
                out.lines.add("");   // keep line numbering stable
                continue;
            }

            if (trimmed.startsWith("#moj_import")) {
                Import imp = parseImport(name, i + 1, trimmed);
                String key = imp.namespace() + ":" + imp.path();

                // Dedup alone would terminate a cycle by silently skipping the
                // second visit, producing a confusingly half-inlined file. Check
                // the active stack first so a real cycle is reported. A diamond
                // (A->C, B->C) is not a cycle: C has finished expanding and is
                // off the stack by the time B imports it.
                if (stack.contains(key))
                    throw new ShaderPreprocessException(
                            "circular #moj_import: " + String.join(" -> ", stack)
                            + " -> " + key);

                if (imported.add(key)) {
                    String text = resolver.resolve(imp.namespace(), imp.path());
                    if (text == null)
                        throw new ShaderPreprocessException(
                                "unresolved #moj_import '" + key + "' in " + name
                                + " at line " + (i + 1));
                    expand(key, text, out, imported, stack);
                } else {
                    out.lines.add("// already included: " + key);
                }
                // Resume the importing file's numbering after the inlined block.
                out.lines.add("#line " + (i + 2));
                continue;
            }

            out.lines.add(line);
        }
        stack.pop();
    }

    private record Import(String namespace, String path) {}

    private Import parseImport(String inFile, int lineNo, String directive) {
        String rest = directive.substring("#moj_import".length()).trim();
        if (rest.startsWith("<") && rest.endsWith(">")) {
            String body = rest.substring(1, rest.length() - 1).trim();
            int colon = body.indexOf(':');
            // A bare <file.glsl> means the minecraft namespace.
            if (colon < 0) return new Import("minecraft", "include/" + body);
            return new Import(body.substring(0, colon),
                              "include/" + body.substring(colon + 1));
        }
        if (rest.startsWith("\"") && rest.endsWith("\"") && rest.length() >= 2) {
            String body = rest.substring(1, rest.length() - 1).trim();
            int colon = body.indexOf(':');
            if (colon < 0) return new Import("minecraft", body);
            return new Import(body.substring(0, colon), body.substring(colon + 1));
        }
        throw new ShaderPreprocessException(
                "malformed #moj_import in " + inFile + " at line " + lineNo + ": " + directive);
    }

    /**
     * Stable cache key for a preprocessed shader. Identical source and defines
     * must map to the same key so translated MSL is reused across launches, and
     * any resource-pack change must produce a different one.
     *
     * <p>Each component is length-prefixed so that no concatenation of
     * different inputs can collide by accident.
     */
    public static String cacheKey(String backendVersion, String source,
                                  Map<String, String> defines) {
        StringBuilder sb = new StringBuilder();
        appendLengthPrefixed(sb, backendVersion);
        appendLengthPrefixed(sb, source);
        if (defines != null) {
            // Sorted so iteration order cannot change the key.
            defines.entrySet().stream()
                   .sorted(Map.Entry.comparingByKey())
                   .forEach(e -> {
                       appendLengthPrefixed(sb, e.getKey());
                       appendLengthPrefixed(sb, String.valueOf(e.getValue()));
                   });
        }
        return Long.toHexString(hash64(sb.toString()));
    }

    private static void appendLengthPrefixed(StringBuilder sb, String s) {
        String v = (s == null) ? "" : s;
        sb.append(v.length()).append(':').append(v);
    }

    private static long hash64(String s) {
        long h = 0xcbf29ce484222325L;               // FNV-1a 64
        for (int i = 0; i < s.length(); i++) {
            h ^= s.charAt(i);
            h *= 0x100000001b3L;
        }
        return h;
    }

    /** Convenience resolver over a tree laid out like {@code assets/<ns>/shaders}. */
    public static SourceResolver directoryResolver(Function<String, String> reader) {
        return (ns, path) -> reader.apply("assets/" + ns + "/shaders/" + path);
    }
}
