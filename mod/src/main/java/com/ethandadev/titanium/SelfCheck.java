package com.ethandadev.titanium;

import com.mojang.blaze3d.systems.RenderSystem;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;

import java.util.Arrays;

/**
 * Automated verification and A/B measurement harness. Inert unless launched
 * with {@code -Dtitanium.selfcheck=<label>}.
 *
 * <p>Once the title screen is up it records {@code frames} frame intervals
 * (wall time between presents, measured at RenderSystem.flipFrame), writes
 * the statistics to the log, and captures a screenshot through Minecraft's own
 * Screenshot path. Under Titanium that path exercises copyTextureToBuffer,
 * the fenced callback queue and a read-mapped buffer — so a correct PNG is
 * itself a test of readback and synchronisation. With
 * {@code -Dtitanium.selfcheck.exit=true} the game then quits.
 *
 * <p>It runs identically with Titanium disabled, which is what makes it an A/B
 * harness: same scene, same settings, only the backend differs.
 */
public final class SelfCheck {
    private SelfCheck() {}

    private static final String LABEL = System.getProperty("titanium.selfcheck");
    private static final boolean EXIT = Boolean.getBoolean("titanium.selfcheck.exit");
    private static final int WARMUP = Integer.getInteger("titanium.selfcheck.warmup", 240);
    private static final int FRAMES = Integer.getInteger("titanium.selfcheck.frames", 600);

    private enum Phase { WAITING, WARMUP, MEASURING, SHOT, DONE }
    private static Phase phase = Phase.WAITING;
    private static int counter;
    private static long last;
    private static long[] samples;
    private static int shotWait;

    public static void onFrame() {
        if (LABEL == null) return;
        Minecraft mc = Minecraft.getInstance();
        long now = System.nanoTime();
        switch (phase) {
            case WAITING -> {
                // Resource loading finished and a menu is up. Not "is TitleScreen":
                // a fresh game directory shows the accessibility onboarding first.
                if (mc.getOverlay() == null && mc.screen != null) {
                    Titanium.LOG.info("SELFCHECK start: screen={}", mc.screen.getClass().getSimpleName());
                    phase = Phase.WARMUP; counter = 0;
                }
            }
            case WARMUP -> {
                if (++counter >= WARMUP) { phase = Phase.MEASURING; counter = 0; samples = new long[FRAMES]; }
            }
            case MEASURING -> {
                if (counter < FRAMES) samples[counter++] = now - last;
                if (counter >= FRAMES) {
                    report(mc);
                    String name = "titanium-selfcheck-" + LABEL + ".png";
                    Screenshot.grab(mc.gameDirectory, name, mc.getMainRenderTarget(), 1,
                        msg -> Titanium.LOG.info("SELFCHECK screenshot callback: {}", msg.getString()));
                    phase = Phase.SHOT; shotWait = 0;
                }
            }
            case SHOT -> {
                // Screenshot completion is a fenced task; give it frames to retire.
                if (++shotWait >= 120) {
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

    private static void report(Minecraft mc) {
        long[] s = Arrays.copyOf(samples, samples.length);
        Arrays.sort(s);
        double sum = 0;
        for (long v : s) sum += v;
        double mean = sum / s.length / 1e6;
        Titanium.LOG.info(String.format(
            "SELFCHECK frametimes label=%s backend=%s frames=%d mean=%.3fms p50=%.3fms p95=%.3fms "
          + "p99=%.3fms max=%.3fms fps=%.1f window=%dx%d vsync=%s fpslimit=%d",
            LABEL, RenderSystem.getDevice().getBackendName(), s.length, mean,
            s[s.length / 2] / 1e6, s[(int) (s.length * 0.95)] / 1e6, s[(int) (s.length * 0.99)] / 1e6,
            s[s.length - 1] / 1e6, 1000.0 / mean,
            mc.getWindow().getWidth(), mc.getWindow().getHeight(),
            mc.options.enableVsync().get(), mc.options.framerateLimit().get()));
    }
}
