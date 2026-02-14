package com.example.examplemod.metal;

import net.minecraft.client.Minecraft;
import net.minecraft.util.text.StringTextComponent;
import net.minecraft.util.text.TextFormatting;
import net.minecraftforge.client.event.RenderWorldLastEvent;
import net.minecraftforge.event.world.WorldEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.lwjgl.glfw.GLFWNativeCocoa;

/**
 * Manages the Metal renderer lifecycle within the Forge mod.
 *
 * Phase B: Renders a test triangle via Metal overlay on each frame.
 * Phase D+: Will replace GL chunk rendering with Metal batched draws.
 */
public class MetalIntegration {

    private static final Logger LOGGER = LogManager.getLogger();

    private boolean initialized = false;
    private boolean initAttempted = false;
    private boolean metalAvailable = false;
    private String deviceName = "unknown";

    /**
     * Try to initialize Metal. Called on first render tick when GL context is active.
     */
    public void tryInit() {
        if (initAttempted) return;
        initAttempted = true;

        // Check OS -- Metal only on macOS
        String os = System.getProperty("os.name", "").toLowerCase();
        if (!os.contains("mac")) {
            LOGGER.info("[METAL] Not macOS, skipping Metal init");
            return;
        }

        // Load native library
        if (!MetalBridge.loadNative()) {
            LOGGER.warn("[METAL] Native library not available, Metal rendering disabled");
            return;
        }

        try {
            // Get NSWindow pointer from GLFW
            long glfwWindow = Minecraft.getInstance().getWindow().getWindow();
            long nsWindow = GLFWNativeCocoa.glfwGetCocoaWindow(glfwWindow);

            if (nsWindow == 0) {
                LOGGER.error("[METAL] Failed to get NSWindow pointer");
                return;
            }

            LOGGER.info("[METAL] NSWindow ptr: 0x{}", Long.toHexString(nsWindow));

            // Initialize Metal renderer
            boolean ok = MetalBridge.init(nsWindow);
            if (!ok) {
                LOGGER.error("[METAL] Metal renderer init failed");
                return;
            }

            deviceName = MetalBridge.getDeviceName();
            metalAvailable = true;
            initialized = true;

            LOGGER.info("[METAL] Initialized successfully on {}", deviceName);

        } catch (Exception e) {
            LOGGER.error("[METAL] Init exception", e);
        }
    }

    // Test triangle removed -- Metal terrain owns the CAMetalLayer.

    /**
     * Send status message when player joins world.
     */
    public void onPlayerJoin() {
        if (!initialized) return;

        Minecraft mc = Minecraft.getInstance();
        if (mc.player == null) return;

        String msg = metalAvailable
                ? TextFormatting.GREEN + "[METAL] " + TextFormatting.WHITE +
                  "Active on " + deviceName + ". Triangle overlay should be visible."
                : TextFormatting.RED + "[METAL] " + TextFormatting.WHITE +
                  "Not available. Using GL fallback.";

        mc.player.sendMessage(
                new StringTextComponent(msg),
                mc.player.getUUID()
        );
    }

    /**
     * Clean up on world unload.
     */
    public void onWorldUnload() {
        // Metal persists across world loads (tied to window, not world)
    }

    public void shutdown() {
        if (initialized) {
            try {
                MetalBridge.shutdown();
            } catch (Exception e) {
                LOGGER.error("[METAL] Shutdown failed", e);
            }
            initialized = false;
            metalAvailable = false;
        }
    }

    public boolean isAvailable() { return metalAvailable; }
    public String getDeviceName() { return deviceName; }
}
