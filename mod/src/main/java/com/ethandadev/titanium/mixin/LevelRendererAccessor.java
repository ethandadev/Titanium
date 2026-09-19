package com.ethandadev.titanium.mixin;

import net.minecraft.client.renderer.LevelRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/**
 * Self-check only: rain and snow animate from {@code LevelRenderer.ticks}, a
 * client counter that {@code tick freeze} stops but does not reset, so its
 * value at the freeze differs run to run. Pinning it makes weather scenes
 * pixel-comparable across runs and backends. Not used in normal play.
 */
@Mixin(LevelRenderer.class)
public interface LevelRendererAccessor {
    @Accessor("ticks")
    void titanium$setTicks(int ticks);
}
