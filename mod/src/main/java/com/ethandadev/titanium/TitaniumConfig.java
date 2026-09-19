package com.ethandadev.titanium;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.fabricmc.loader.api.FabricLoader;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;

/**
 * {@code config/titanium.json}. Every optimisation is a setting here, off or at
 * its conservative value unless it is both always-correct and verified.
 *
 * <p>Validation is strict and explicit: an unknown key, a wrong type or an
 * out-of-range value is reported by name in the log and replaced by its
 * default — the game never starts with a half-understood configuration. The
 * file is rewritten (atomically) with every key present so users can see what
 * is available.
 */
public final class TitaniumConfig {
    /** Hard switch; same effect as -Dtitanium.enabled=false. */
    public boolean enabled = true;

    /**
     * TBDR: fold full-texture clears into the next render pass's load action
     * instead of a separate clear pass. Correct (pending clears are
     * materialised before anything else can observe the texture; pixel-checked)
     * but OFF by default: on an M3 Max it showed no measurable benefit — the
     * saved traffic (~13 MB/frame) is ~0.03 ms at that bandwidth, below the
     * benchmark's noise floor. Might help lower-bandwidth chips (untested).
     */
    public boolean deferredClears = false;

    /** Log a one-line capability and settings summary at startup. */
    public boolean logSummary = true;

    private static final Path FILE = FabricLoader.getInstance().getConfigDir().resolve("titanium.json");
    private static TitaniumConfig instance;

    public static synchronized TitaniumConfig get() {
        if (instance == null) instance = load();
        return instance;
    }

    static TitaniumConfig load() {
        TitaniumConfig defaults = new TitaniumConfig();
        TitaniumConfig c = new TitaniumConfig();
        List<String> problems = new ArrayList<>();
        if (Files.isRegularFile(FILE)) {
            try {
                JsonElement root = JsonParser.parseString(Files.readString(FILE, StandardCharsets.UTF_8));
                if (!root.isJsonObject()) {
                    problems.add("top level is not a JSON object");
                } else {
                    JsonObject o = root.getAsJsonObject();
                    for (String key : o.keySet()) {
                        JsonElement v = o.get(key);
                        switch (key) {
                            case "enabled" -> c.enabled = bool(key, v, defaults.enabled, problems);
                            case "deferredClears" -> c.deferredClears = bool(key, v, defaults.deferredClears, problems);
                            case "logSummary" -> c.logSummary = bool(key, v, defaults.logSummary, problems);
                            default -> problems.add("unknown key '" + key + "' (ignored)");
                        }
                    }
                }
            } catch (Exception e) {
                problems.add("unreadable (" + e.getMessage() + "); using defaults");
                c = new TitaniumConfig();
            }
        }
        for (String p : problems) Titanium.LOG.warn("Titanium config {}: {}", FILE.getFileName(), p);
        c.save();
        // -Dtitanium.<key>=<value> overrides for this launch only (testing, A/B
        // runs); validated exactly like the file, and never written back.
        c.deferredClears = sysBool("deferredClears", c.deferredClears);
        c.logSummary = sysBool("logSummary", c.logSummary);
        return c;
    }

    private static boolean sysBool(String key, boolean current) {
        String v = System.getProperty("titanium." + key);
        if (v == null) return current;
        if (v.equals("true") || v.equals("false")) return Boolean.parseBoolean(v);
        Titanium.LOG.warn("Titanium: -Dtitanium.{}={} is not true/false; ignored", key, v);
        return current;
    }

    private static boolean bool(String key, JsonElement v, boolean def, List<String> problems) {
        if (v.isJsonPrimitive() && v.getAsJsonPrimitive().isBoolean()) return v.getAsBoolean();
        problems.add("'" + key + "' must be true or false, got " + v + "; using " + def);
        return def;
    }

    void save() {
        try {
            Files.createDirectories(FILE.getParent());
            Path tmp = FILE.resolveSibling(FILE.getFileName() + ".tmp");
            Gson gson = new GsonBuilder().setPrettyPrinting().create();
            Files.writeString(tmp, gson.toJson(this), StandardCharsets.UTF_8);
            Files.move(tmp, FILE, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            Titanium.LOG.warn("Titanium: could not write {}: {}", FILE, e.toString());
        }
    }
}
