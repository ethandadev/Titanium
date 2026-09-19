package com.ethandadev.titanium;

import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.systems.TimerQuery;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import com.mojang.blaze3d.platform.NativeImage;
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
    /** clear | rain | thunder. Weather has its own passes (streaks, splashes, translucency). */
    private static final String WEATHER = System.getProperty("titanium.selfcheck.weather", "clear");
    private static boolean weatherStepping;
    private static int lastChunks = -1;
    private static long chunksChangedAt;
    private static final long CHUNK_QUIET_NS = 3_000_000_000L;
    /** Minimum settle time; a long one pre-generates a larger render distance once. */
    private static final long SETTLE_MIN_SECONDS = Long.getLong("titanium.selfcheck.settleMinSeconds", 0L);
    private static long settleStart;

    private static boolean weatherAtTarget(Minecraft mc) {
        float rain = WEATHER.equals("clear") ? 0f : 1f, thunder = WEATHER.equals("thunder") ? 1f : 0f;
        return Math.abs(mc.level.getRainLevel(1f) - rain) < 1e-3 && Math.abs(mc.level.getThunderLevel(1f) - thunder) < 1e-3;
    }
    private static final int WARMUP = Integer.getInteger("titanium.selfcheck.warmup", 240);
    private static final int FRAMES = Integer.getInteger("titanium.selfcheck.frames", 600);
    /** The scene must be provably the same workload on both backends: all
     *  sections built AND the count unchanged for STABLE_FRAMES in a row. */
    private static final int SETTLE_MIN = 600, SETTLE_MAX = 20000, STABLE_FRAMES = 240;
    private static int stableFor, lastSections = -1, sectionsAtStart;

    private enum Phase { WAITING, OPENING, SETUP, SETTLING, STRESS, SOAK, WARMUP, MEASURING, SHOT, EQUIV, DONE }
    /** Extended session: travel through new terrain for N minutes, logging
     *  memory and live native objects every minute (leak detection). */
    private static final int SOAK_MINUTES = Integer.getInteger("titanium.selfcheck.soak", 0);
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
                    // -Dtitanium.selfcheck.weather=rain exercises rain, splashes and
                    // translucent particles (weather has its own pipelines).
                    c.sendCommand("weather " + WEATHER);
                    // Weather persists in the saved world and its level ramps ~0.01/tick,
                    // which a frozen world never does. If the saved level is not already
                    // the target, step the world until it is (SETTLING waits for the step
                    // to finish, then re-pins the time of day the step advanced).
                    if (!weatherAtTarget(mc)) { c.sendCommand("tick step 120"); weatherStepping = true; }
                    // ABSOLUTE position: the world saves the player, so a
                    // relative tp drifted 12 blocks per run and the first A/B
                    // compared different views (caught by the image diff).
                    c.sendCommand(CAMERA.equals("vista") ? "tp @s 0.5 120 -6.5 135 25"
                                                         : "tp @s 0.5 80 -6.5 135 20");
                    // No chat, toasts or per-run player names in the frame.
                    mc.options.hideGui = !Boolean.getBoolean("titanium.selfcheck.gui");
                    // -Dtitanium.selfcheck.renderDistance=N: geometry-heavy scenes (not saved to options.txt).
                    Integer rd = Integer.getInteger("titanium.selfcheck.renderDistance");
                    if (rd != null) {
                        mc.options.renderDistance().set(rd);
                        // The server sends chunks for the view distance the client
                        // *requested* (ClientInformation), not the local option.
                        mc.options.broadcastOptions();
                    }
                    applyUncapped(mc);
                    // -Dtitanium.selfcheck.window=WxH (points): measure at a chosen size,
                    // e.g. near-fullscreen Retina, where pixel fill actually matters.
                    String win = System.getProperty("titanium.selfcheck.window");
                    if (win != null && win.matches("\\d+x\\d+")) {
                        String[] p = win.split("x");
                        org.lwjgl.glfw.GLFW.glfwSetWindowSize(mc.getWindow().handle(),
                                Integer.parseInt(p[0]), Integer.parseInt(p[1]));
                    }
                    phase = Phase.SETTLING; counter = 0;
                }
            }
            case SETTLING -> {
                counter++;
                if (weatherStepping) {
                    boolean done = !mc.level.tickRateManager().isSteppingForward() && weatherAtTarget(mc);
                    if (!done && counter < SETTLE_MAX) { stableFor = 0; break; }
                    if (!done) Titanium.LOG.warn("SELFCHECK weather did not reach '{}' (rain={}, thunder={})",
                                                 WEATHER, mc.level.getRainLevel(1f), mc.level.getThunderLevel(1f));
                    mc.player.connection.sendCommand("time set 6000");
                    weatherStepping = false; stableFor = 0; lastSections = -1;
                    Titanium.LOG.info("SELFCHECK weather '{}' reached after {} frames", WEATHER, counter);
                }
                int sec = mc.levelRenderer.countRenderedSections();
                // Loaded chunks too: while far chunks are still generating, the
                // rendered-section count can sit still between arrivals.
                // Chunks arrive in bursts while generating, so their count must also
                // hold for CHUNK_QUIET_NS of wall time, not just STABLE_FRAMES.
                int chunks = mc.level.getChunkSource().getLoadedChunksCount();
                if (chunks != lastChunks) chunksChangedAt = now;
                boolean built = sec > 10 && mc.levelRenderer.hasRenderedAllSections()
                                && now - chunksChangedAt >= CHUNK_QUIET_NS;
                stableFor = (built && sec == lastSections) ? stableFor + 1 : 0;
                lastSections = sec;
                lastChunks = chunks;
                if (settleStart == 0) settleStart = now;
                boolean minTime = now - settleStart >= SETTLE_MIN_SECONDS * 1_000_000_000L;
                if ((stableFor >= STABLE_FRAMES && counter >= SETTLE_MIN && minTime)
                    || (counter >= SETTLE_MAX && minTime)) {
                    Titanium.LOG.info("SELFCHECK world settled after {} frames (stable={}, sections={}, chunks={})",
                                      counter, stableFor >= STABLE_FRAMES, sec, chunks);
                    if (SOAK_MINUTES > 0) { phase = Phase.SOAK; counter = 0; soakStart = System.nanoTime(); soakLastLog = soakStart; }
                    else if (STRESS && stressStep == 0) { phase = Phase.STRESS; counter = 0; stableFor = 0; lastSections = -1; }
                    else if (STRESS) { stressShot(mc, "rejoin"); phase = Phase.SHOT; counter = 0; }
                    else { phase = Phase.WARMUP; counter = 0; }
                }
            }
            case STRESS -> stress(mc);
            case SOAK -> soak(mc, now);
            case WARMUP -> {
                // Frozen world: pin the weather animation phase (see LevelRendererAccessor).
                if (counter == 0 && WORLD != null)
                    ((com.ethandadev.titanium.mixin.LevelRendererAccessor) mc.levelRenderer).titanium$setTicks(0);
                if (++counter >= WARMUP) {
                    phase = Phase.MEASURING; counter = 0;
                    sectionsAtStart = mc.levelRenderer.countRenderedSections();
                    samples = new long[FRAMES];
                    cpuAtStart = processCpuNs(); wallAtStart = System.nanoTime();
                    threadCpuAtStart = THREADS.getCurrentThreadCpuTime();
                    Titanium.resetPassProfile();
                    waitsAtStart = Titanium.waitStats();
                    multiAtStart = Titanium.multiDrawStats();
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
                    cpuDuring = processCpuNs() - cpuAtStart; wallDuring = System.nanoTime() - wallAtStart;
                    threadCpuDuring = THREADS.getCurrentThreadCpuTime() - threadCpuAtStart;
                    Titanium.stopPassProfile();
                    waitsDuring = diff(Titanium.waitStats(), waitsAtStart);
                    long[] m1 = Titanium.multiDrawStats();
                    if (m1 != null && multiAtStart != null)
                        multiDuring = new long[] { m1[0] - multiAtStart[0], m1[1] - multiAtStart[1], m1[2] - multiAtStart[2] };
                    Screenshot.grab(mc.gameDirectory, "titanium-selfcheck-" + LABEL + ".png",
                                    mc.getMainRenderTarget(), 1,
                                    msg -> Titanium.LOG.info("SELFCHECK screenshot callback: {}", msg.getString()));
                    phase = Phase.SHOT; counter = 0;
                }
            }
            case SHOT -> {
                pollGpu();
                if (counter == 30 && !STRESS && SOAK_MINUTES == 0) report(mc);   // after outstanding GPU timers have resolved
                // Screenshot completion is a fenced task; give it frames to retire.
                if (++counter >= 120) {
                    if (EQUIVALENCE && WORLD != null && Titanium.setBatchDraws(true)) {
                        phase = Phase.EQUIV; counter = 0; equivAttempt = 0;
                        return;
                    }
                    Titanium.LOG.info("SELFCHECK done (label={}, backend={})", LABEL,
                                      RenderSystem.getDevice().getBackendName());
                    phase = Phase.DONE;
                    if (EXIT) mc.stop();
                }
            }
            case EQUIV -> equivalence(mc);
            case DONE -> {}
        }
        last = now;
    }

    // --------------------------------------------------------- equivalence

    /**
     * -Dtitanium.selfcheck.equivalence=true: proves chunk-draw batching renders
     * exactly what per-draw calls render, inside one run (so world state is
     * identical): three consecutive frames rendered batched, unbatched,
     * batched, each captured. If the two batched frames differ, a client tick
     * (texture animation) fell between them and the attempt is repeated.
     * Called once per frame, after the frame was rendered.
     */
    private static final boolean EQUIVALENCE = Boolean.getBoolean("titanium.selfcheck.equivalence");
    private static int equivAttempt, equivPending;
    private static final NativeImage[] equivShots = new NativeImage[3];

    private static void equivalence(Minecraft mc) {
        int c = counter++;
        if (c >= 1 && c <= 3) {
            int k = c - 1;
            equivPending++;
            Screenshot.takeScreenshot(mc.getMainRenderTarget(), img -> { equivShots[k] = img; equivPending--; });
            Titanium.setBatchDraws(k != 0);   // frame after shot 0 unbatched, then batched again
            return;
        }
        if (c < 4 || equivPending > 0) {
            if (c > 600) { Titanium.LOG.warn("SELFCHECK equivalence: captures did not complete"); finishEquiv(mc); }
            return;
        }
        long abDiff = diffPixels(equivShots[0], equivShots[2]);
        long batchVsPlain = diffPixels(equivShots[0], equivShots[1]);
        for (int i = 0; i < 3; i++) { if (equivShots[i] != null) equivShots[i].close(); equivShots[i] = null; }
        if (abDiff != 0 && ++equivAttempt < 5) { counter = 0; return; }   // a tick intervened; retry
        Titanium.LOG.info("SELFCHECK equivalence batchDraws: batched-vs-batched differing_pixels={} "
                          + "batched-vs-per-draw differing_pixels={} attempts={} verdict={}",
                          abDiff, batchVsPlain, equivAttempt + 1,
                          abDiff != 0 ? "INCONCLUSIVE" : batchVsPlain == 0 ? "IDENTICAL" : "DIFFERENT");
        finishEquiv(mc);
    }

    private static long diffPixels(NativeImage a, NativeImage b) {
        if (a == null || b == null || a.getWidth() != b.getWidth() || a.getHeight() != b.getHeight()) return -1;
        long n = 0;
        for (int y = 0; y < a.getHeight(); y++)
            for (int x = 0; x < a.getWidth(); x++)
                if (a.getPixel(x, y) != b.getPixel(x, y)) n++;
        return n;
    }

    private static void finishEquiv(Minecraft mc) {
        Titanium.setBatchDraws(!"false".equals(System.getProperty("titanium.batchDraws")));
        Titanium.LOG.info("SELFCHECK done (label={}, backend={})", LABEL, RenderSystem.getDevice().getBackendName());
        phase = Phase.DONE;
        if (EXIT) mc.stop();
    }

    // ---------------------------------------------------------------- soak

    private static long soakStart, soakLastLog;
    private static int soakX = 0, soakMinute = 0;
    private static final List<Long> soakFrames = new ArrayList<>();

    private static void soak(Minecraft mc, long now) {
        if (counter++ == 0 && mc.player != null) {
            mc.player.connection.sendCommand("tick unfreeze");   // time, weather and entities run
        }
        soakFrames.add(now - last);
        // Keep generating new terrain: 48 blocks (3 chunks) east every 3 s.
        if (counter % 360 == 0 && mc.player != null) {
            soakX += 48;
            mc.player.connection.sendCommand("tp @s " + soakX + " 120 -6.5 90 25");
        }
        if (now - soakLastLog >= 60_000_000_000L) {
            soakLastLog = now;
            soakMinute++;
            long[] f = soakFrames.stream().mapToLong(Long::longValue).sorted().toArray();
            soakFrames.clear();
            Runtime rt = Runtime.getRuntime();
            Titanium.LOG.info(String.format(
                "SELFCHECK soak minute=%d frames=%d p50=%.2fms p99=%.2fms gpu_alloc=%s heap_used=%dMB %s sections=%d x=%d",
                soakMinute, f.length, f.length == 0 ? 0 : f[f.length / 2] / 1e6,
                f.length == 0 ? 0 : f[(int) (f.length * 0.99)] / 1e6, Titanium.gpuAllocatedMB(),
                (rt.totalMemory() - rt.freeMemory()) >> 20, Titanium.liveObjects(),
                mc.levelRenderer.countRenderedSections(), soakX));
            if (soakMinute >= SOAK_MINUTES) {
                Titanium.LOG.info("SELFCHECK soak complete after {} minutes", soakMinute);
                phase = Phase.SHOT; counter = 0;
                Screenshot.grab(mc.gameDirectory, "titanium-selfcheck-" + LABEL + ".png", mc.getMainRenderTarget(), 1,
                                msg -> Titanium.LOG.info("SELFCHECK screenshot callback: {}", msg.getString()));
            }
        }
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

    private static long cpuAtStart, wallAtStart, cpuDuring, wallDuring, threadCpuAtStart, threadCpuDuring;
    private static double[] waitsAtStart, waitsDuring;
    private static long[] multiAtStart, multiDuring;

    private static double[] diff(double[] a, double[] b) {
        if (a == null || b == null) return null;
        double[] d = new double[a.length];
        for (int i = 0; i < a.length; i++) d[i] = a[i] - b[i];
        return d;
    }
    private static final java.lang.management.ThreadMXBean THREADS = java.lang.management.ManagementFactory.getThreadMXBean();

    /** Process CPU time (all threads), backend-neutral. */
    private static long processCpuNs() {
        var os = java.lang.management.ManagementFactory.getOperatingSystemMXBean();
        return os instanceof com.sun.management.OperatingSystemMXBean s ? s.getProcessCpuTime() : -1;
    }

    /** Resident set size from the OS, backend-neutral (includes driver/GPU-mapped memory). */
    private static long rssMB() {
        try {
            Process p = new ProcessBuilder("ps", "-o", "rss=", "-p", Long.toString(ProcessHandle.current().pid()))
                        .redirectErrorStream(true).start();
            String out = new String(p.getInputStream().readAllBytes()).trim();
            p.waitFor();
            return Long.parseLong(out) / 1024;
        } catch (Exception e) { return -1; }
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
          + "renderDistance=%d sections=%d->%d%s cpu_cores=%.2f cpu_ms_per_frame=%.3f render_thread_cpu_ms_per_frame=%.3f rss=%dMB %s",
            LABEL, RenderSystem.getDevice().getBackendName(), WORLD == null ? "menu" : "world:" + WORLD + ":" + CAMERA + ":" + WEATHER,
            s.length, mean, s[s.length / 2] / 1e6, s[(int) (s.length * 0.95)] / 1e6,
            s[(int) (s.length * 0.99)] / 1e6, s[s.length - 1] / 1e6, 1000.0 / mean, gpuStats,
            (rt.totalMemory() - rt.freeMemory()) >> 20, Titanium.gpuAllocatedMB(),
            mc.getWindow().getWidth(), mc.getWindow().getHeight(),
            mc.options.enableVsync().get(), mc.options.framerateLimit().get(),
            mc.options.renderDistance().get(), sectionsAtStart, mc.levelRenderer.countRenderedSections(),
            (WORLD != null && sectionsAtStart != mc.levelRenderer.countRenderedSections()) ? " UNSTABLE" : "",
            cpuDuring > 0 && wallDuring > 0 ? (double) cpuDuring / wallDuring : -1.0,
            cpuDuring > 0 ? cpuDuring / 1e6 / s.length : -1.0,
            threadCpuDuring > 0 ? threadCpuDuring / 1e6 / s.length : -1.0, rssMB(),
            Titanium.clearStats() + " " + WorldScaler.describe() + " " + Titanium.pipelineStats()));
        if (waitsDuring != null)
            Titanium.LOG.info(String.format("SELFCHECK gpuwait label=%s per_frame: frame_slot=%.4fms (%.2f waits) "
                                            + "fence=%.4fms (%.2f) drawable=%.4fms (%.2f)", LABEL,
                                            waitsDuring[1] / s.length, waitsDuring[0] / s.length,
                                            waitsDuring[3] / s.length, waitsDuring[2] / s.length,
                                            waitsDuring[5] / s.length, waitsDuring[4] / s.length));
        if (multiDuring != null)
            Titanium.LOG.info(String.format("SELFCHECK multidraw label=%s per_frame: calls=%.1f draws=%.1f ms=%.4f ns_per_draw=%.1f",
                                            LABEL, (double) multiDuring[0] / s.length, (double) multiDuring[1] / s.length,
                                            multiDuring[2] / 1e6 / s.length,
                                            multiDuring[1] == 0 ? 0.0 : (double) multiDuring[2] / multiDuring[1]));
        var profile = Titanium.passProfile(s.length);
        if (profile != null) for (String line : profile) Titanium.LOG.info("SELFCHECK passprofile {}", line);
    }
}
