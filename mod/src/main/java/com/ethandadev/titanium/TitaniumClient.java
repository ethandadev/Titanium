package com.ethandadev.titanium;

import net.fabricmc.api.ClientModInitializer;

/** Fabric entrypoint. The real work happens in the mixins, which run before
 *  the window is created; this only reports the outcome. */
public final class TitaniumClient implements ClientModInitializer {
    @Override
    public void onInitializeClient() {
        Titanium.LOG.info("Titanium loaded; renderer: {}", Titanium.active() ? "Metal" : "stock OpenGL");
    }
}
