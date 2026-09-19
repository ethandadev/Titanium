package com.ethandadev.titanium;

import com.ethandadev.titanium.backend.MetalDevice;
import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.pipeline.TextureTarget;
import com.mojang.blaze3d.systems.RenderSystem;
import net.minecraft.client.Minecraft;
import org.jetbrains.annotations.Nullable;

import static com.ethandadev.titanium.natives.TitaniumNative.*;

/**
 * Decoupled world resolution.
 *
 * <p>GameRenderer.render draws the world (renderLevel, entity outlines, post
 * effects) into the main target, then clears the main target's depth and draws
 * the GUI on top. Everything in that world block fetches the target through
 * {@code Minecraft.getMainRenderTarget()} at use time (verified in the 1.21.11
 * sources), so for exactly that block the getter returns a smaller world
 * target; at its end the world is upscaled into the real main target and the
 * GUI renders at full resolution — text and UI stay sharp.
 */
public final class WorldScaler {
    private WorldScaler() {}

    private static @Nullable TextureTarget worldTarget;
    private static boolean active;
    private static boolean metalfxUnavailable;

    /** Called by the Minecraft.getMainRenderTarget mixin. */
    public static @Nullable RenderTarget override() { return active ? worldTarget : null; }

    public static void beginWorld(Minecraft mc) {
        MetalDevice dev = Titanium.device();
        double scale = TitaniumConfig.get().worldScale;
        if (dev == null || scale >= 0.999) return;
        RenderTarget main = mc.getMainRenderTarget();
        int w = Math.max(1, (int) Math.round(main.width * scale));
        int h = Math.max(1, (int) Math.round(main.height * scale));
        if (worldTarget == null) worldTarget = new TextureTarget("Titanium world", w, h, true);
        else if (worldTarget.width != w || worldTarget.height != h) worldTarget.resize(w, h);
        // The vanilla frame-start clear targets the real main target; the world
        // target needs its own (stale depth would otherwise reject geometry).
        RenderSystem.getDevice().createCommandEncoder()
            .clearColorAndDepthTextures(worldTarget.getColorTexture(), 0, worldTarget.getDepthTexture(), 1.0);
        active = true;
    }

    public static void endWorld(Minecraft mc) {
        if (!active) return;
        active = false;   // from here on getMainRenderTarget() is the real one again
        MetalDevice dev = Titanium.device();
        RenderTarget main = mc.getMainRenderTarget();
        boolean wantFx = TitaniumConfig.get().upscaler.equals("metalfx") && !metalfxUnavailable;
        int rc = dev.upscale(worldTarget.getColorTexture(), main.getColorTexture(),
                             wantFx ? UPSCALE_METALFX_SPATIAL : UPSCALE_BILINEAR);
        if (rc == ERR_UNSUPPORTED && wantFx) {
            metalfxUnavailable = true;
            Titanium.warnOnce("metalfx-unavailable", "MetalFX spatial scaling unavailable ("
                              + nLastError() + "); using bilinear upscaling");
            dev.upscale(worldTarget.getColorTexture(), main.getColorTexture(), UPSCALE_BILINEAR);
        } else if (rc != OK) {
            Titanium.warnOnce("upscale-failed", "world upscale failed: " + nLastError());
        }
    }

    public static String describe() {
        double s = TitaniumConfig.get().worldScale;
        return s >= 0.999 ? "worldScale=1.0(off)"
             : "worldScale=" + s + " upscaler=" + (metalfxUnavailable ? "bilinear(fallback)" : TitaniumConfig.get().upscaler)
               + (worldTarget != null ? " world=" + worldTarget.width + "x" + worldTarget.height : "");
    }
}
