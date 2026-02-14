package com.example.examplemod.culling;

import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.mojang.blaze3d.matrix.MatrixStack;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.IRenderTypeBuffer;
import net.minecraft.client.renderer.tileentity.TileEntityRenderer;
import net.minecraft.client.renderer.tileentity.TileEntityRendererDispatcher;
import net.minecraft.tileentity.TileEntity;
import net.minecraft.tileentity.TileEntityType;
import net.minecraft.util.math.BlockPos;
import net.minecraft.util.math.vector.Vector3d;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

/**
 * Wraps all registered TileEntityRenderers with distance-based culling
 * and per-type CPU profiling.
 *
 * Fix for Java 17: modifies map entries IN-PLACE instead of replacing
 * the final map field (avoids JIT inlining of the old map reference).
 */
public class BlockEntityCullingHandler {

    private static final Logger LOGGER = LogManager.getLogger();

    private static final double HARD_CULL_DIST_SQ = 48.0 * 48.0;
    private static final double RATE_LIMIT_DIST_SQ = 24.0 * 24.0;
    private static final int RATE_FAR = 3;

    private boolean installed = false;
    private boolean attemptedInstall = false;
    private int wrappedCount = 0;

    private int culledThisFrame;
    private int renderedThisFrame;
    private int totalCulled;
    private int totalRendered;
    private long frameCounter;

    // BE render timing
    private double beRenderMsThisFrame;
    private double beRenderMsAvg;
    private static final int HISTORY_SIZE = 120;
    private final double[] beRenderHistory = new double[HISTORY_SIZE];
    private int historyIndex = 0;
    private int historyCount = 0;
    private double totalBeRenderMs;

    // Per-type profiling
    private final Map<String, TypeStats> typeStatsMap = new HashMap<>();
    private List<TypeStats> topTypes = new ArrayList<>();
    private static final int TOP_N = 8;

    public static class TypeStats {
        public String name;
        public double totalMs;
        public long totalCalls;
        public double thisFrameMs;
        public int thisFrameCalls;
        public int thisFrameCulled;
        // Rolling average
        private final double[] history = new double[120];
        private int histIdx;
        private int histCount;
        public double avgMs;

        TypeStats(String name) {
            this.name = name;
        }

        void addRenderNanos(long nanos) {
            double ms = nanos / 1_000_000.0;
            thisFrameMs += ms;
            thisFrameCalls++;
        }

        void addCulled() {
            thisFrameCulled++;
        }

        void onFrameEnd() {
            totalMs += thisFrameMs;
            totalCalls += thisFrameCalls;
            history[histIdx] = thisFrameMs;
            histIdx = (histIdx + 1) % history.length;
            if (histCount < history.length) histCount++;
            double sum = 0;
            for (int i = 0; i < histCount; i++) sum += history[i];
            avgMs = sum / histCount;
            thisFrameMs = 0;
            thisFrameCalls = 0;
            thisFrameCulled = 0;
        }
    }

    /**
     * Attempt to install renderer wrappers. Safe to call every frame --
     * will only actually install once, on the first successful attempt.
     */
    @SuppressWarnings({"unchecked", "rawtypes"})
    public void tryInstall() {
        if (attemptedInstall) return;

        TileEntityRendererDispatcher dispatcher = TileEntityRendererDispatcher.instance;
        if (dispatcher == null) return;
        if (Minecraft.getInstance().level == null) return;

        attemptedInstall = true;

        try {
            Field renderersField = findRenderersField(dispatcher);
            if (renderersField == null) {
                LOGGER.warn("[BE-CULL] Could not find renderers field on TileEntityRendererDispatcher");
                return;
            }

            renderersField.setAccessible(true);

            Map<TileEntityType<?>, TileEntityRenderer<?>> original =
                    (Map<TileEntityType<?>, TileEntityRenderer<?>>) renderersField.get(dispatcher);

            if (original == null || original.isEmpty()) {
                LOGGER.warn("[BE-CULL] Renderer map is null or empty ({} entries)",
                        original == null ? "null" : original.size());
                return;
            }

            LOGGER.info("[BE-CULL] Found {} registered TileEntityRenderers", original.size());

            // CRITICAL FIX: modify map entries IN-PLACE instead of replacing the map.
            // On Java 17, the JIT inlines final field references. Replacing the map via
            // Field.set() changes the field value but JIT-compiled getRenderer() still
            // reads the old map. By modifying entries in the SAME map object, the JIT's
            // cached reference still points to our modified map.
            List<Map.Entry<TileEntityType<?>, TileEntityRenderer<?>>> entries =
                    new ArrayList<>(original.entrySet());

            for (Map.Entry<TileEntityType<?>, TileEntityRenderer<?>> entry : entries) {
                TileEntityRenderer orig = entry.getValue();
                if (orig instanceof CullingWrapper) continue;
                original.put(entry.getKey(), new CullingWrapper(orig, dispatcher, this));
                wrappedCount++;
            }

            installed = true;

            // Verify installation by checking a random entry
            if (!original.isEmpty()) {
                Object firstVal = original.values().iterator().next();
                boolean verified = firstVal instanceof CullingWrapper;
                LOGGER.info("[BE-CULL] Wrapped {} renderers in-place (verified: {})", wrappedCount, verified);
            }

        } catch (Exception e) {
            LOGGER.error("[BE-CULL] Failed to install renderer wrappers", e);
        }
    }

    private Field findRenderersField(TileEntityRendererDispatcher dispatcher) {
        LOGGER.info("[BE-CULL] Scanning all fields for renderer map...");
        logAllFields();

        for (Field f : TileEntityRendererDispatcher.class.getDeclaredFields()) {
            if (!Map.class.isAssignableFrom(f.getType())) continue;

            try {
                f.setAccessible(true);
                Object value = f.get(dispatcher);
                if (!(value instanceof Map)) continue;

                Map<?, ?> map = (Map<?, ?>) value;
                if (map.isEmpty()) continue;

                Object firstValue = map.values().iterator().next();
                if (firstValue instanceof TileEntityRenderer) {
                    LOGGER.info("[BE-CULL] Found renderer map: field '{}' ({} entries)",
                            f.getName(), map.size());
                    return f;
                }
            } catch (Exception e) {
                LOGGER.debug("[BE-CULL] Skipping field '{}': {}", f.getName(), e.getMessage());
            }
        }

        return null;
    }

    private void logAllFields() {
        LOGGER.info("[BE-CULL] All fields on TileEntityRendererDispatcher:");
        for (Field f : TileEntityRendererDispatcher.class.getDeclaredFields()) {
            LOGGER.info("[BE-CULL]   {} {} {}", Modifier.toString(f.getModifiers()),
                    f.getType().getSimpleName(), f.getName());
        }
    }

    boolean shouldCull(TileEntity te) {
        Minecraft mc = Minecraft.getInstance();
        if (mc.player == null) return false;

        BlockPos pos = te.getBlockPos();
        Vector3d camPos = mc.gameRenderer.getMainCamera().getPosition();
        double dx = pos.getX() + 0.5 - camPos.x;
        double dy = pos.getY() + 0.5 - camPos.y;
        double dz = pos.getZ() + 0.5 - camPos.z;
        double distSq = dx * dx + dy * dy + dz * dz;

        if (distSq > HARD_CULL_DIST_SQ) {
            culledThisFrame++;
            return true;
        }

        if (distSq > RATE_LIMIT_DIST_SQ) {
            int hash = pos.hashCode();
            if ((frameCounter + hash) % RATE_FAR != 0) {
                culledThisFrame++;
                return true;
            }
        }

        renderedThisFrame++;
        return false;
    }

    TypeStats getTypeStats(TileEntity te) {
        String typeName = getTypeName(te);
        return typeStatsMap.computeIfAbsent(typeName, TypeStats::new);
    }

    private String getTypeName(TileEntity te) {
        // Use registry name if available, otherwise class simple name
        TileEntityType<?> type = te.getType();
        if (type != null && type.getRegistryName() != null) {
            return type.getRegistryName().toString();
        }
        return te.getClass().getSimpleName();
    }

    void addBeRenderNanos(long nanos) {
        beRenderMsThisFrame += nanos / 1_000_000.0;
    }

    public void onFrameEnd() {
        totalCulled += culledThisFrame;
        totalRendered += renderedThisFrame;
        totalBeRenderMs += beRenderMsThisFrame;

        // Rolling average
        beRenderHistory[historyIndex] = beRenderMsThisFrame;
        historyIndex = (historyIndex + 1) % HISTORY_SIZE;
        if (historyCount < HISTORY_SIZE) historyCount++;
        double sum = 0;
        for (int i = 0; i < historyCount; i++) sum += beRenderHistory[i];
        beRenderMsAvg = sum / historyCount;

        // Per-type frame end
        for (TypeStats ts : typeStatsMap.values()) {
            ts.onFrameEnd();
        }

        // Rebuild top-N every 30 frames
        if (frameCounter % 30 == 0 && !typeStatsMap.isEmpty()) {
            List<TypeStats> sorted = new ArrayList<>(typeStatsMap.values());
            sorted.sort(Comparator.comparingDouble((TypeStats ts) -> ts.avgMs).reversed());
            topTypes = sorted.subList(0, Math.min(TOP_N, sorted.size()));
        }

        culledThisFrame = 0;
        renderedThisFrame = 0;
        beRenderMsThisFrame = 0;
        frameCounter++;
    }

    public boolean isInstalled() { return installed; }
    public int getTotalCulled() { return totalCulled; }
    public int getTotalRendered() { return totalRendered; }
    public int getWrappedCount() { return wrappedCount; }
    public long getFrameCount() { return frameCounter; }
    public double getBeRenderMsAvg() { return beRenderMsAvg; }
    public double getTotalBeRenderMs() { return totalBeRenderMs; }
    public List<TypeStats> getTopTypes() { return topTypes; }

    public void resetStats() {
        totalCulled = 0;
        totalRendered = 0;
        frameCounter = 0;
        typeStatsMap.clear();
        topTypes.clear();
    }

    // --- Inner wrapper class ---

    @SuppressWarnings("unchecked")
    static class CullingWrapper<T extends TileEntity> extends TileEntityRenderer<T> {

        private final TileEntityRenderer<T> delegate;
        private final BlockEntityCullingHandler handler;

        CullingWrapper(TileEntityRenderer<T> delegate,
                       TileEntityRendererDispatcher dispatcher,
                       BlockEntityCullingHandler handler) {
            super(dispatcher);
            this.delegate = delegate;
            this.handler = handler;
        }

        @Override
        public void render(T tileEntity, float partialTicks, MatrixStack matrixStack,
                           IRenderTypeBuffer buffer, int light, int overlay) {
            TypeStats stats = handler.getTypeStats(tileEntity);
            if (handler.shouldCull(tileEntity)) {
                stats.addCulled();
                return;
            }
            long start = System.nanoTime();
            delegate.render(tileEntity, partialTicks, matrixStack, buffer, light, overlay);
            long elapsed = System.nanoTime() - start;
            handler.addBeRenderNanos(elapsed);
            stats.addRenderNanos(elapsed);
        }

        @Override
        public boolean shouldRenderOffScreen(T tileEntity) {
            return delegate.shouldRenderOffScreen(tileEntity);
        }
    }
}
