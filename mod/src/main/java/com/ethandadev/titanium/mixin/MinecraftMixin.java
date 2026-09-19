package com.ethandadev.titanium.mixin;

import com.ethandadev.titanium.WorldScaler;
import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(Minecraft.class)
public abstract class MinecraftMixin {
    /** During the world block, the "main" target is the reduced-resolution world target. */
    @Inject(method = "getMainRenderTarget", at = @At("HEAD"), cancellable = true)
    private void titanium$mainTarget(CallbackInfoReturnable<RenderTarget> cir) {
        RenderTarget t = WorldScaler.override();
        if (t != null) cir.setReturnValue(t);
    }
}
