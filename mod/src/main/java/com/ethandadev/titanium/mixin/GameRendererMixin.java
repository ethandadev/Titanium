package com.ethandadev.titanium.mixin;

import com.ethandadev.titanium.WorldScaler;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.GameRenderer;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Brackets the world block of GameRenderer.render: from just before
 * renderLevel to just before fogRenderer.endFrame(), after which vanilla clears
 * the main depth buffer and draws the GUI.
 */
@Mixin(GameRenderer.class)
public abstract class GameRendererMixin {
    @Shadow @Final private Minecraft minecraft;

    @Inject(method = "render", at = @At(value = "INVOKE",
            target = "Lnet/minecraft/client/renderer/GameRenderer;renderLevel(Lnet/minecraft/client/DeltaTracker;)V"))
    private void titanium$beginWorld(DeltaTracker delta, boolean renderLevel, CallbackInfo ci) {
        WorldScaler.beginWorld(minecraft);
    }

    @Inject(method = "render", at = @At(value = "INVOKE",
            target = "Lnet/minecraft/client/renderer/fog/FogRenderer;endFrame()V"))
    private void titanium$endWorld(DeltaTracker delta, boolean renderLevel, CallbackInfo ci) {
        WorldScaler.endWorld(minecraft);
    }
}
