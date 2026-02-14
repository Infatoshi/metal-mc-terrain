package com.example.examplemod.culling;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import net.minecraft.client.Minecraft;
import net.minecraft.entity.EntityType;
import net.minecraft.entity.LivingEntity;
import net.minecraft.entity.player.PlayerEntity;
import net.minecraft.util.math.vector.Vector3d;
import net.minecraftforge.client.event.RenderLivingEvent;
import net.minecraftforge.eventbus.api.EventPriority;
import net.minecraftforge.eventbus.api.SubscribeEvent;

/**
 * Distance-based + budget-based entity render culling using RenderLivingEvent.Pre.
 * Now includes per-entity-type CPU profiling.
 *
 * Three layers of culling:
 * 1. Hard cull beyond 48 blocks
 * 2. Rate-limit between 24-48 blocks
 * 3. Per-frame render budget: when >BUDGET entities rendered, start skipping
 */
public class EntityCullingHandler {

    // Distance thresholds (squared)
    private static final double HARD_CULL_DIST_SQ = 48.0 * 48.0;
    private static final double RATE_LIMIT_DIST_SQ = 24.0 * 24.0;
    private static final double NEAR_RATE_DIST_SQ = 32.0 * 32.0;

    // Rate limit: render every Nth frame at distance tiers
    private static final int RATE_MID = 2;   // 24-32 blocks: every 2nd frame
    private static final int RATE_FAR = 4;   // 32-48 blocks: every 4th frame

    // Per-frame render budget (handles dense nearby areas)
    private static final int SOFT_BUDGET = 40;  // after this, start culling 50%
    private static final int HARD_BUDGET = 80;  // after this, cull 75%

    // Per-frame counters
    private int culledThisFrame;
    private int renderedThisFrame;

    // Per-entity render timing
    private long entityRenderStartNano;
    private String currentEntityType;
    private double entityRenderMsThisFrame;
    private double entityRenderMsAvg;
    private static final int HISTORY_SIZE = 120;
    private final double[] entityRenderHistory = new double[HISTORY_SIZE];
    private int historyIndex = 0;
    private int historyCount = 0;

    // Session stats
    private int totalCulled;
    private int totalRendered;
    private int totalBudgetCulled;
    private long frameCounter;
    private double totalEntityRenderMs;

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

    private TypeStats getTypeStats(LivingEntity entity) {
        EntityType<?> type = entity.getType();
        String name = type.getRegistryName() != null ? type.getRegistryName().toString()
                : entity.getClass().getSimpleName();
        return typeStatsMap.computeIfAbsent(name, TypeStats::new);
    }

    @SubscribeEvent
    public void onRenderLivingPre(RenderLivingEvent.Pre<?, ?> event) {
        LivingEntity entity = event.getEntity();

        // Never cull players
        if (entity instanceof PlayerEntity) return;

        Minecraft mc = Minecraft.getInstance();
        if (mc.player == null) return;

        TypeStats stats = getTypeStats(entity);

        Vector3d camPos = mc.gameRenderer.getMainCamera().getPosition();
        double distSq = entity.distanceToSqr(camPos);

        // Layer 1: Hard cull beyond max distance
        if (distSq > HARD_CULL_DIST_SQ) {
            event.setCanceled(true);
            culledThisFrame++;
            stats.addCulled();
            return;
        }

        // Layer 2: Rate-limit at medium distances
        if (distSq > RATE_LIMIT_DIST_SQ) {
            int entityHash = entity.getId();
            int rate = distSq > NEAR_RATE_DIST_SQ ? RATE_FAR : RATE_MID;
            if ((frameCounter + entityHash) % rate != 0) {
                event.setCanceled(true);
                culledThisFrame++;
                stats.addCulled();
                return;
            }
        }

        // Layer 3: Per-frame render budget (for dense nearby areas like chicken farms)
        if (renderedThisFrame >= HARD_BUDGET) {
            if ((frameCounter + entity.getId()) % 4 != 0) {
                event.setCanceled(true);
                culledThisFrame++;
                totalBudgetCulled++;
                stats.addCulled();
                return;
            }
        } else if (renderedThisFrame >= SOFT_BUDGET) {
            if ((frameCounter + entity.getId()) % 2 != 0) {
                event.setCanceled(true);
                culledThisFrame++;
                totalBudgetCulled++;
                stats.addCulled();
                return;
            }
        }

        renderedThisFrame++;
        entityRenderStartNano = System.nanoTime();
        currentEntityType = stats.name;
    }

    @SubscribeEvent(priority = EventPriority.LOWEST)
    public void onRenderLivingPost(RenderLivingEvent.Post<?, ?> event) {
        if (entityRenderStartNano > 0) {
            long elapsed = System.nanoTime() - entityRenderStartNano;
            entityRenderMsThisFrame += elapsed / 1_000_000.0;
            if (currentEntityType != null) {
                TypeStats stats = typeStatsMap.get(currentEntityType);
                if (stats != null) {
                    stats.addRenderNanos(elapsed);
                }
            }
            entityRenderStartNano = 0;
            currentEntityType = null;
        }
    }

    public void onFrameEnd() {
        totalCulled += culledThisFrame;
        totalRendered += renderedThisFrame;
        totalEntityRenderMs += entityRenderMsThisFrame;

        // Rolling average for entity render time
        entityRenderHistory[historyIndex] = entityRenderMsThisFrame;
        historyIndex = (historyIndex + 1) % HISTORY_SIZE;
        if (historyCount < HISTORY_SIZE) historyCount++;
        double sum = 0;
        for (int i = 0; i < historyCount; i++) sum += entityRenderHistory[i];
        entityRenderMsAvg = sum / historyCount;

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
        entityRenderMsThisFrame = 0;
        entityRenderStartNano = 0;
        currentEntityType = null;
        frameCounter++;
    }

    public int getTotalCulled() { return totalCulled; }
    public int getTotalRendered() { return totalRendered; }
    public int getTotalBudgetCulled() { return totalBudgetCulled; }
    public long getFrameCount() { return frameCounter; }
    public double getEntityRenderMsAvg() { return entityRenderMsAvg; }
    public double getTotalEntityRenderMs() { return totalEntityRenderMs; }
    public List<TypeStats> getTopTypes() { return topTypes; }

    public void resetStats() {
        totalCulled = 0;
        totalRendered = 0;
        totalBudgetCulled = 0;
        frameCounter = 0;
        typeStatsMap.clear();
        topTypes.clear();
    }
}
