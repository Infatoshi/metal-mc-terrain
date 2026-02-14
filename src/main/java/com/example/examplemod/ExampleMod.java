package com.example.examplemod;

import com.example.examplemod.culling.BlockEntityCullingHandler;
import com.example.examplemod.culling.EntityCullingHandler;
import com.example.examplemod.metal.MetalIntegration;
import com.example.examplemod.metal.MetalTerrainRenderer;
import com.example.examplemod.optimization.ChunkUploadBudgeter;
import com.example.examplemod.overlay.ProfilerOverlay;
import com.example.examplemod.profiler.RenderProfiler;
import net.minecraft.client.Minecraft;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import net.minecraft.client.settings.KeyBinding;
import net.minecraft.util.text.StringTextComponent;
import net.minecraft.util.text.TextFormatting;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.event.entity.EntityJoinWorldEvent;
import net.minecraftforge.event.world.WorldEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.client.registry.ClientRegistry;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.event.lifecycle.FMLClientSetupEvent;
import net.minecraftforge.fml.javafmlmod.FMLJavaModLoadingContext;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.lwjgl.glfw.GLFW;

@Mod("examplemod")
public class ExampleMod {
    private static final Logger LOGGER = LogManager.getLogger();
    private boolean joinMessageSent = false;
    private boolean metalActivated = false;

    private ProfilerOverlay profilerOverlay;
    private KeyBinding toggleOverlayKey;
    private KeyBinding toggleMetalKey;

    public static final EntityCullingHandler ENTITY_CULLER = new EntityCullingHandler();
    public static final BlockEntityCullingHandler BE_CULLER = new BlockEntityCullingHandler();
    public static final MetalIntegration METAL = new MetalIntegration();
    public static final ChunkUploadBudgeter UPLOAD_BUDGETER = new ChunkUploadBudgeter();
    public static final MetalTerrainRenderer METAL_TERRAIN = new MetalTerrainRenderer();

    public ExampleMod() {
        FMLJavaModLoadingContext.get().getModEventBus().addListener(this::doClientStuff);
        MinecraftForge.EVENT_BUS.register(this);
    }

    private void doClientStuff(final FMLClientSetupEvent event) {
        MinecraftForge.EVENT_BUS.register(RenderProfiler.INSTANCE);
        MinecraftForge.EVENT_BUS.register(ENTITY_CULLER);
        MinecraftForge.EVENT_BUS.register(METAL);
        MinecraftForge.EVENT_BUS.register(METAL_TERRAIN);

        profilerOverlay = new ProfilerOverlay();
        MinecraftForge.EVENT_BUS.register(profilerOverlay);

        // F6 toggle profiler overlay
        toggleOverlayKey = new KeyBinding(
                "key.skyfactory.toggleProfiler",
                GLFW.GLFW_KEY_F6,
                "key.categories.misc"
        );
        ClientRegistry.registerKeyBinding(toggleOverlayKey);

        // F8 toggle Metal terrain on/off (A/B compare with GL baseline)
        toggleMetalKey = new KeyBinding(
                "key.skyfactory.toggleMetal",
                GLFW.GLFW_KEY_F8,
                "key.categories.misc"
        );
        ClientRegistry.registerKeyBinding(toggleMetalKey);

        LOGGER.info("[SKYFACTORY-PERF] Metal terrain + culling + profiler loaded.");
    }

    @SubscribeEvent
    public void onRenderTick(TickEvent.RenderTickEvent event) {
        if (event.phase == TickEvent.Phase.START) {
            UPLOAD_BUDGETER.onFrameStart();
            return;
        }

        // Deferred installs
        if (!BE_CULLER.isInstalled()) {
            BE_CULLER.tryInstall();
        }
        if (!UPLOAD_BUDGETER.isInstalled()) {
            UPLOAD_BUDGETER.tryInstall();
        }

        // Init Metal + auto-activate terrain rendering
        METAL.tryInit();
        if (!metalActivated && METAL.isAvailable()) {
            METAL_TERRAIN.activate();
            metalActivated = true;
        }

        ENTITY_CULLER.onFrameEnd();
        BE_CULLER.onFrameEnd();
    }

    @SubscribeEvent
    public void onClientTick(TickEvent.ClientTickEvent event) {
        if (event.phase != TickEvent.Phase.END) return;
        if (Minecraft.getInstance().player == null) return;

        while (toggleOverlayKey.consumeClick()) {
            profilerOverlay.toggleVisible();
        }

        while (toggleMetalKey.consumeClick()) {
            boolean nowActive = !MetalTerrainRenderer.isActive();
            if (nowActive && METAL.isAvailable()) {
                METAL_TERRAIN.activate();
            } else {
                METAL_TERRAIN.deactivate();
            }
            String state = nowActive ? TextFormatting.GREEN + "ON (Metal terrain)" : TextFormatting.YELLOW + "OFF (GL baseline)";
            Minecraft.getInstance().player.sendMessage(
                    new StringTextComponent(TextFormatting.GOLD + "[F8] " + TextFormatting.WHITE + "Metal terrain: " + state),
                    Minecraft.getInstance().player.getUUID()
            );
        }
    }

    @SubscribeEvent
    public void onPlayerJoin(EntityJoinWorldEvent event) {
        if (!event.getWorld().isClientSide()) return;
        if (event.getEntity() != Minecraft.getInstance().player) return;
        if (joinMessageSent) return;
        joinMessageSent = true;

        ENTITY_CULLER.resetStats();
        BE_CULLER.resetStats();
        RenderProfiler.INSTANCE.startSession(Minecraft.getInstance().gameDirectory);

        String status = metalActivated
                ? TextFormatting.GREEN + "Metal terrain active" + TextFormatting.WHITE + " | GL terrain suppressed"
                : TextFormatting.YELLOW + "Metal not available" + TextFormatting.WHITE + " | GL terrain active";
        Minecraft.getInstance().player.sendMessage(
                new StringTextComponent(TextFormatting.GOLD + "[PERF] " +
                        TextFormatting.WHITE + "Profiler + culling on. " + status),
                Minecraft.getInstance().player.getUUID()
        );
        METAL.onPlayerJoin();
    }

    @SubscribeEvent
    public void onWorldUnload(WorldEvent.Unload event) {
        if (!event.getWorld().isClientSide()) return;
        RenderProfiler.INSTANCE.setCullingStats(
                ENTITY_CULLER.getTotalCulled(), ENTITY_CULLER.getTotalRendered(),
                ENTITY_CULLER.getTotalBudgetCulled());
        RenderProfiler.INSTANCE.setBECullingStats(
                BE_CULLER.getTotalCulled(), BE_CULLER.getTotalRendered(),
                BE_CULLER.getWrappedCount());
        RenderProfiler.INSTANCE.setStageTiming(
                ENTITY_CULLER.getTotalEntityRenderMs(),
                BE_CULLER.getTotalBeRenderMs());
        RenderProfiler.INSTANCE.setEntityTypeBreakdown(buildTypeBreakdown(ENTITY_CULLER.getTopTypes()));
        RenderProfiler.INSTANCE.setBETypeBreakdown(buildBETypeBreakdown(BE_CULLER.getTopTypes()));
        RenderProfiler.INSTANCE.setUploadBudgetStats(
                UPLOAD_BUDGETER.getTotalUploaded(),
                UPLOAD_BUDGETER.getTotalDeferred(),
                UPLOAD_BUDGETER.getFramesWithDeferral());
        RenderProfiler.INSTANCE.endSession();
        UPLOAD_BUDGETER.reset();
        METAL_TERRAIN.clearCache();
        joinMessageSent = false;
        LOGGER.info("[SKYFACTORY-PERF] Session ended. Summary written to profiler_summary.txt");
    }

    private List<String[]> buildTypeBreakdown(List<EntityCullingHandler.TypeStats> types) {
        List<String[]> rows = new ArrayList<>();
        List<EntityCullingHandler.TypeStats> sorted = new ArrayList<>(types);
        sorted.sort(Comparator.comparingDouble((EntityCullingHandler.TypeStats ts) -> ts.totalMs).reversed());
        for (EntityCullingHandler.TypeStats ts : sorted) {
            if (ts.totalMs < 0.01) continue;
            rows.add(new String[]{
                ts.name,
                String.format("%.2f", ts.avgMs),
                String.format("%.0f", ts.totalMs),
                String.valueOf(ts.totalCalls)
            });
        }
        return rows;
    }

    private List<String[]> buildBETypeBreakdown(List<BlockEntityCullingHandler.TypeStats> types) {
        List<String[]> rows = new ArrayList<>();
        List<BlockEntityCullingHandler.TypeStats> sorted = new ArrayList<>(types);
        sorted.sort(Comparator.comparingDouble((BlockEntityCullingHandler.TypeStats ts) -> ts.totalMs).reversed());
        for (BlockEntityCullingHandler.TypeStats ts : sorted) {
            if (ts.totalMs < 0.01) continue;
            rows.add(new String[]{
                ts.name,
                String.format("%.2f", ts.avgMs),
                String.format("%.0f", ts.totalMs),
                String.valueOf(ts.totalCalls)
            });
        }
        return rows;
    }
}
