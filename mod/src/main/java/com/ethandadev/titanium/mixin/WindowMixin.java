package com.ethandadev.titanium.mixin;

import com.ethandadev.titanium.Titanium;
import com.mojang.blaze3d.platform.Window;
import org.lwjgl.glfw.GLFW;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Window.class)
public abstract class WindowMixin {

    /**
     * Window's constructor requests an OpenGL 3.3 core context
     * (GLFW_CLIENT_API = GLFW_OPENGL_API). With Titanium active, ask for no
     * client API at all: no GL context is created, and the CAMetalLayer is
     * attached to the window's content view instead. GLFW ignores the other
     * context hints under GLFW_NO_API, so they pass through untouched.
     */
    @Redirect(method = "<init>", at = @At(value = "INVOKE", target = "Lorg/lwjgl/glfw/GLFW;glfwWindowHint(II)V"))
    private void titanium$windowHint(int hint, int value) {
        if (hint == GLFW.GLFW_CLIENT_API && Titanium.active()) value = GLFW.GLFW_NO_API;
        GLFW.glfwWindowHint(hint, value);
    }

    /** glfwSwapInterval needs a current GL context; under Titanium, vsync is a CAMetalLayer property. */
    @Redirect(method = "updateVsync", at = @At(value = "INVOKE", target = "Lorg/lwjgl/glfw/GLFW;glfwSwapInterval(I)V"))
    private void titanium$swapInterval(int interval) {
        if (Titanium.active()) Titanium.setVsync(interval != 0);
        else GLFW.glfwSwapInterval(interval);
    }

    @Inject(method = "onFramebufferResize", at = @At("HEAD"))
    private void titanium$framebufferResize(long window, int w, int h, CallbackInfo ci) {
        if (Titanium.active()) Titanium.onFramebufferResized();
    }
}
