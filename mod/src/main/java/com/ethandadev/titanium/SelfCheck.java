package com.ethandadev.titanium;

import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.systems.TimerQuery;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.world.Difficulty;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.LevelSettings;
import net.minecraft.world.level.WorldDataConfiguration;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPresets;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Automated verification and A/B measurement harness. Inert unless launched
 * with {@code -Dtitanium.selfcheck=<label>}.
 *
 * <p>Menu mode (default): once loading finishes, measure {@code frames} frame
 * intervals at the menu, screenshot through Minecraft's own Screenshot path,
 * exit. Under Titanium that path exercises copyTextureToBuffer, the fenced
 * callback queue and a read-mapped buffer, so a correct PNG is itself a test of
 * readback and synchronisation.
 *
 * <p>World mode ({@code -Dtitanium.selfcheck.world=<name>}): create (or open) a
 * deterministic world — Mojang's own "DEBUG world" recipe, seed
 * {@code "test1".hashCode()} — freeze ticking, fix time, weather and camera,
 * wait until every section is built (GameRenderer's own "loaded" test), then
 * measure and screenshot.
 *
 * <p>{@code -Dtitanium.selfcheck.uncapped=true} turns off vsync and the FPS
 * limit before measuring, so the numbers reflect throughput, not pacing.
 *
 * <p>Runs identically with Titanium disabled: same scene, same settings, only
 * the backend differs. That is what makes it an A/B harness.
 */
public final class SelfCheck {
    private SelfCheck() {}

    private static final String LABEL = System.getProperty("titanium.selfcheck");
    private static final String WORLD = System.getProperty("titanium.selfcheck.world");
    private static final boolean EXIT = Boolean.getBoolean("titanium.selfcheck.exit");
    private static final boolean UNCAPPED = Boolean.getBoolean("titanium.selfcheck.uncapped");
    /** Lifecycle stress instead of a benchmark: resize, fullscreen, resource
     *  reload, leave and rejoin the world — each followed by a screenshot. */
    private static final boolean STRESS = Boolean.getBoolean("titanium.selfcheck.stress");
    /** "canopy" (default, historical A/B position) or "vista" (open view). */
    private static final String CAMERA = System.getProperty("titanium.selfcheck.camera", "canopy");
    private static final int WARMUP = Integer.getInteger("titanium.selfcheck.warmup", 240);
    private static final int FRAMES = Integer.getInteger("titanium.selfcheck.frames", 600);
    /** The scene must be provably the same workload on both backends: all
     *  sections built AND the count unchanged for STABLE_FRAMES in a row. */
    private static final int SETTLE_MIN = 600, SETTLE_MAX = 20000, STABLE_FRAMES = 240;
    private static int stableFor, lastSections = -1, sectionsAtStart;

    private enum Phase { WAITING, OPENING, SETUP, SETTLING, STRESS, WARMUP, MEASURING, SHOT, DONE }
    private static Phase phase = Phase.WAITING;
    private static int counter;
    private static long last;
    private static long[] samples;
    /** Minecraft's own TimerQuery (GL_TIME_ELAPSED on OpenGL; per-command-buffer
     *  GPU time on Titanium) — the same instrument on both backends. */
    private static final List<TimerQuery.FrameProfile> pendingGpu = new ArrayList<>();
    private static final List<Long> gpuNs = new ArrayList<>();

    /** Re-entrancy guard: world creation renders progress screens
     *  synchronously, which re-enters flipFrame -> onFrame. */
    private static boolean inHook;

    public static void onFrame() {
        if (LABEL == null || inHook) return;
        inHook = true;
        try { step(); } finally { inHook = false; }
    }

    private static void step() {
        Minecraft mc = Minecraft.getInstance();
        long now = System.nanoTime();
        switch (phase) {
            case WAITING -> {
                // Loading finished and a menu is up (not "is TitleScreen": a
                // fresh game directory shows the accessibility onboarding first).
                if (mc.getOverlay() == null && mc.screen != null) {
                    Titanium.LOG.info("SELFCHECK start: screen={} world={}", mc.screen.getClass().getSimpleName(), WORLD);
                    if (WORLD == null) { phase = Phase.WARMUP; applyUncapped(mc); }
                    else { phase = Phase.OPENING; openWorld(mc); }   // phase first: openWorld renders
                    counter = 0;
                }
            }
            case OPENING -> {
                if (mc.level != null && mc.player != null && mc.screen == null) { phase = Phase.SETUP; counter = 0; }
            }
            case SETUP -> {
                // A few frames in, so the connection is fully up.
                if (++counter == 20) {
                    var c = mc.player.connection;
                    c.sendCommand("tick freeze");
                    c.sendCommand("time set 6000");
                    c.sendCommand("weather clear");
                    // ABSOLUTE position: the world saves the player, so a
                    // relative tp drifted 12 blocks per run and the first A/B
                    // compared different views (caught by the image diff).
                    c.sendCommand(CAMERA.equals("vista") ? "tp @s 0.5 120 -6.5 135 25"
                                                         : "tp @s 0.5 80 -6.5 135 20");
                    // No chat, toasts or per-run player names in the frame.
                    mc.options.hideGui = true;
                    applyUncapped(mc);
                    phase = Phase.SETTLING; counter = 0;
                }
            }
            case SETTLING -> {
                counter++;
                int sec = mc.levelRenderer.countRenderedSections();
                boolean built = sec > 10 && mc.levelRenderer.hasRenderedAllSections();
                stableFor = (built && sec == lastSections) ? stableFor + 1 : 0;
                lastSections = sec;
                if ((stableFor >= STABLE_FRAMES && counter >= SETTLE_MIN) || counter >= SETTLE_MAX) {
                    Titanium.LOG.info("SELFCHECK world settled after {} frames (stable={}, sections={})",
                                      counter, stableFor >= STABLE_FRAMES, sec);
                    if (STRESS && stressStep == 0) { phase = Phase.STRESS; counter = 0; stableFor = 0; lastSections = -1; }
                    else if (STRESS) { stressShot(mc, "rejoin"); phase = Phase.SHOT; counter = 0; }
                    else { phase = Phase.WARMUP; counter = 0; }
                }
            }
            case STRESS -> stress(mc);
            case WARMUP -> {
                if (++counter >= WARMUP) {
                    phase = Phase.MEASURING; counter = 0;
                    sectionsAtStart = mc.levelRenderer.countRenderedSections();
                    samples = new long[FRAMES];
                    TimerQuery.getInstance().beginProfile();
                }
            }
            case MEASURING -> {
                if (counter < FRAMES) {
                    samples[counter] = now - last;
                    counter++;
                }
                TimerQuery tq = TimerQuery.getInstance();
                if (tq.isRecording()) pendingGpu.add(tq.endProfile());
                if (counter < FRAMES) tq.beginProfile();
                pollGpu();
                if (counter >= FRAMES) {
                    Screenshot.grab(mc.gameDirectory, "titanium-selfcheck-" + LABEL + ".png",
                                    mc.getMainRenderTarget(), 1,
                                    msg -> Titanium.LOG.info("SELFCHECK screenshot callback: {}", msg.getString()));
                    phase = Phase.SHOT; counter = 0;
                }
            }
            case SHOT -> {
                pollGpu();
                if (counter == 30 && !STRESS) report(mc);   // after outstanding GPU timers have resolved
                // Screenshot completion is a fenced task; give it frames to retire.
                if (++counter >= 120) {
                    Titanium.LOG.info("SELFCHECK done (label={}, backend={})", LABEL,
                                      RenderSystem.getDevice().getBackendName());
                    phase = Phase.DONE;
                    if (EXIT) mc.stop();
                }
            }
            case DONE -> {}
        }
        last = now;
    }

    // ---------------------------------------------------------------- stress

    private static int stressStep;
    private static int origW, origH;
    private static java.util.concurrent.CompletableFuture<Void> reload;

    /** One step per call; `counter` counts frames spent in the current step. */
    private static void stress(Minecraft mc) {
        long h = mc.getWindow().handle();
        counter++;
        switch (stressStep) {
            case 0 -> {                                           // baseline
                stressShot(mc, "baseline");
                int[] w = new int[1], hh = new int[1];
                org.lwjgl.glfw.GLFW.glfwGetWindowSize(h, w, hh);
                origW = w[0]; origH = hh[0];
                next();
            }
            case 1 -> { if (counter == 1) org.lwjgl.glfw.GLFW.glfwSetWindowSize(h, 960, 540);
                        if (counter >= 90) { stressShot(mc, "resize-small"); next(); } }
            case 2 -> { if (counter == 1) org.lwjgl.glfw.GLFW.glfwSetWindowSize(h, origW, origH);
                        if (counter >= 90) { stressShot(mc, "resize-restored"); next(); } }
            case 3 -> { if (counter == 1) mc.getWindow().toggleFullScreen();
                        if (counter >= 240) { stressShot(mc, "fullscreen-on"); next(); } }
            case 4 -> { if (counter == 1) mc.getWindow().toggleFullScreen();
                        if (counter >= 240) { stressShot(mc, "fullscreen-off"); next(); } }
            case 5 -> {                                           // full resource reload: every pipeline recompiled
                if (counter == 1) reload = mc.reloadResourcePacks();
                if (reload != null && reload.isDone() && mc.getOverlay() == null && counter >= 120) {
                    stressShot(mc, "resource-reload"); next();
                }
            }
            case 6 -> {                                           // leave the world
                // Exactly the pause menu's "Save and Quit to Title" (PauseScreen):
                // level.disconnect() halts the integrated server first. Calling
                // disconnectWithSavingScreen() alone waits forever (found the hard way).
                if (counter == 1) mc.disconnectFromWorld(net.minecraft.client.multiplayer.ClientLevel.DEFAULT_QUIT_MESSAGE);
                if (mc.level == null && mc.screen != null && counter >= 60) { stressShot(mc, "left-world"); next(); }
            }
            case 7 -> {                                           // rejoin; SETTLING finishes the job
                if (counter == 1) { mc.options.hideGui = false; openWorld(mc); }
                if (mc.level != null && mc.player != null && mc.screen == null) {
                    stressStep = 8; phase = Phase.SETUP; counter = 0;
                }
            }
            default -> {}
        }
    }

    private static void next() { stressStep++; counter = 0; }

    private static void stressShot(Minecraft mc, String step) {
        var t = mc.getMainRenderTarget();
        Titanium.LOG.info("SELFCHECK stress step={} target={}x{} framebuffer={}x{} fullscreen={} level={}",
                          step, t.width, t.height, mc.getWindow().getWidth(), mc.getWindow().getHeight(),
                          mc.getWindow().isFullscreen(), mc.level != null);
        Screenshot.grab(mc.gameDirectory, "titanium-selfcheck-" + LABEL + "-" + step + ".png", t, 1,
                        msg -> Titanium.LOG.info("SELFCHECK stress screenshot {}: {}", step, msg.getString()));
    }

    private static void pollGpu() {
        pendingGpu.removeIf(fp -> {
            if (!fp.isDone()) return false;
            long v = fp.get();
            if (v > 0) gpuNs.add(v);
            return true;
        });
    }

    private static void openWorld(Minecraft mc) {
        if (mc.getLevelSource().levelExists(WORLD)) {
            mc.createWorldOpenFlows().openWorld(WORLD, () -> {});
            return;
        }
        // Mojang's own debug-world recipe (SelectWorldScreen), made deterministic.
        LevelSettings settings = new LevelSettings(WORLD, GameType.SPECTATOR, false, Difficulty.NORMAL, true,
                new GameRules(WorldDataConfiguration.DEFAULT.enabledFeatures()), WorldDataConfiguration.DEFAULT);
        WorldOptions options = new WorldOptions("test1".hashCode(), true, false);
        mc.createWorldOpenFlows().createFreshLevel(WORLD, settings, options,
                WorldPresets::createNormalWorldDimensions, mc.screen);
    }

    private static void applyUncapped(Minecraft mc) {
        if (!UNCAPPED) return;
        mc.options.enableVsync().set(false);
        mc.getWindow().updateVsync(false);
        mc.options.framerateLimit().set(260);   // 260 = "Unlimited" in the options screen
    }

    private static void report(Minecraft mc) {
        long[] s = Arrays.copyOf(samples, samples.length);
        Arrays.sort(s);
        double sum = 0;
        for (long v : s) sum += v;
        double mean = sum / s.length / 1e6;
        double[] g = gpuNs.stream().mapToDouble(v -> v / 1e6).sorted().toArray();
        String gpuStats = g.length == 0 ? "gpu=n/a"
            : String.format("gpu_n=%d gpu_mean=%.3fms gpu_p50=%.3fms gpu_p99=%.3fms", g.length,
                            Arrays.stream(g).average().orElse(0), g[g.length / 2], g[(int) (g.length * 0.99)]);
        Runtime rt = Runtime.getRuntime();
        Titanium.LOG.info(String.format(
            "SELFCHECK frametimes label=%s backend=%s scene=%s frames=%d mean=%.3fms p50=%.3fms p95=%.3fms "
          + "p99=%.3fms max=%.3fms fps=%.1f %s heap_used=%dMB gpu_alloc=%s window=%dx%d vsync=%s fpslimit=%d "
          + "renderDistance=%d sections=%d->%d%s",
            LABEL, RenderSystem.getDevice().getBackendName(), WORLD == null ? "menu" : "world:" + WORLD,
            s.length, mean, s[s.length / 2] / 1e6, s[(int) (s.length * 0.95)] / 1e6,
            s[(int) (s.length * 0.99)] / 1e6, s[s.length - 1] / 1e6, 1000.0 / mean, gpuStats,
            (rt.totalMemory() - rt.freeMemory()) >> 20, Titanium.gpuAllocatedMB(),
            mc.getWindow().getWidth(), mc.getWindow().getHeight(),
            mc.options.enableVsync().get(), mc.options.framerateLimit().get(),
            mc.options.renderDistance().get(), sectionsAtStart, mc.levelRenderer.countRenderedSections(),
            (WORLD != null && sectionsAtStart != mc.levelRenderer.countRenderedSections()) ? " UNSTABLE" : ""));
    }
}
