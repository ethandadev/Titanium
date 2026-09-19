package com.ethandadev.titanium.mixin;

import com.ethandadev.titanium.Titanium;
import com.ethandadev.titanium.backend.MetalDevice;
import com.mojang.blaze3d.shaders.ShaderSource;
import com.mojang.blaze3d.systems.GpuDevice;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.systems.SamplerCache;
import net.minecraft.client.renderer.DynamicUniforms;
import org.lwjgl.glfw.GLFW;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(RenderSystem.class)
public abstract class RenderSystemMixin {
    @Shadow private static GpuDevice DEVICE;
    @Shadow private static String apiDescription;
    @Shadow private static DynamicUniforms dynamicUniforms;
    @Shadow private static SamplerCache samplerCache;

    /**
     * Vanilla initRenderer is four statements: construct GlDevice into DEVICE,
     * record its description, create DynamicUniforms, initialise the sampler
     * cache (verified against 1.21.11 bytecode and source). This replays them
     * with a MetalDevice in place of GlDevice.
     */
    @Inject(method = "initRenderer", at = @At("HEAD"), cancellable = true)
    private static void titanium$initRenderer(long window, int debugVerbosity, boolean syncDebug,
                                              ShaderSource shaderSource, boolean debugLabels, CallbackInfo ci) {
        if (!Titanium.active()) return;
        MetalDevice device = new MetalDevice(window, debugVerbosity, syncDebug, shaderSource, debugLabels);
        Titanium.setDevice(device);
        DEVICE = device;
        apiDescription = device.getImplementationInformation();
        dynamicUniforms = new DynamicUniforms();
        samplerCache.initialize();
        ci.cancel();
    }

    /** Test/benchmark harness hook; inert unless -Dtitanium.selfcheck is set. */
    @Inject(method = "flipFrame", at = @At("TAIL"))
    private static void titanium$afterFlip(CallbackInfo ci) {
        com.ethandadev.titanium.SelfCheck.onFrame();
    }

    /** Presentation already happened in CommandEncoder.presentTexture; with no GL
     *  context, glfwSwapBuffers would raise a GLFW error. */
    @Redirect(method = "flipFrame", at = @At(value = "INVOKE", target = "Lorg/lwjgl/glfw/GLFW;glfwSwapBuffers(J)V"))
    private static void titanium$swapBuffers(long window) {
        if (!Titanium.active()) GLFW.glfwSwapBuffers(window);
    }
}
