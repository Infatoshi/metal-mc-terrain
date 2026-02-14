package com.example.examplemod.profiler;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintWriter;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.WorldRenderer;
import net.minecraft.client.renderer.chunk.ChunkRenderDispatcher;
import net.minecraft.entity.Entity;
import net.minecraftforge.client.event.RenderWorldLastEvent;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL15;

/**
 * Collects per-frame render timing using pure Forge events (no Mixins).
 *
 * Measures:
 * - Total frame time (RenderTickEvent PRE->POST)
 * - World render time (RenderTickEvent PRE -> RenderWorldLastEvent)
 * - Entity count, block entity count
 * - Chunk dispatcher queue depth (via reflection)
 *
 * Auto-accumulates all frames for a session summary on world exit.
 */
public class RenderProfiler {

    private static final Logger LOGGER = LogManager.getLogger();
    public static final RenderProfiler INSTANCE = new RenderProfiler();

    // Timing state
    private long frameStartNano;
    private long worldRenderEndNano;
    private long frameEndNano;
    private boolean frameActive = false;

    // Current frame values
    private double currentFrameMs;
    private double currentWorldMs;

    // Rolling averages
    private static final int HISTORY_SIZE = 120;
    private final double[] frameHistory = new double[HISTORY_SIZE];
    private final double[] worldHistory = new double[HISTORY_SIZE];
    private int historyIndex = 0;
    private int historyCount = 0;
    private double avgFrameMs;
    private double avgWorldMs;

    // GPU timer query (GL_EXT_timer_query / GL_TIME_ELAPSED)
    private static final int GL_TIME_ELAPSED = 0x88BF;
    private int[] gpuQueryIds;
    private int gpuQueryIndex = 0;
    private boolean gpuTimerAvailable = false;
    private boolean gpuTimerChecked = false;
    private boolean gpuFirstFrame = true;
    private double currentGpuMs;
    private double avgGpuMs;
    private final double[] gpuHistory = new double[HISTORY_SIZE];
    private final List<Double> allGpuTimes = new ArrayList<>();

    // Counts
    private int entityCount;
    private int blockEntityCount;
    private String chunkStatus = "";

    // Session accumulation
    private final List<double[]> allFrames = new ArrayList<>(); // [frameMs, worldMs]
    private final List<int[]> allCounts = new ArrayList<>();    // [entities, BEs]
    private long frameCount = 0;
    private File gameDir;
    private boolean sessionActive = false;

    // External culling stats
    private int cullingTotalCulled;
    private int cullingTotalRendered;
    private int cullingBudgetCulled;
    private int beCullingTotalCulled;
    private int beCullingTotalRendered;
    private int beCullingWrappedCount;

    // External per-stage timing (set by ExampleMod on session end)
    private double totalEntityRenderMs;
    private double totalBeRenderMs;

    // Per-type profiling data (set by ExampleMod on session end)
    private List<String[]> entityTypeBreakdown = new ArrayList<>(); // [name, avgMs, totalMs, calls]
    private List<String[]> beTypeBreakdown = new ArrayList<>();

    // Upload budget stats
    private int uploadBudgetUploaded;
    private int uploadBudgetDeferred;
    private int uploadBudgetFramesDeferred;

    // GC monitoring
    private final List<GarbageCollectorMXBean> gcBeans = ManagementFactory.getGarbageCollectorMXBeans();
    private final MemoryMXBean memBean = ManagementFactory.getMemoryMXBean();
    private long lastGcCount;
    private long lastGcTimeMs;
    private long gcPausesThisSession;
    private long gcTotalPauseMs;
    private double gcPauseMsThisFrame;
    private double maxGcPauseMs;
    private final List<Double> gcPausePerFrame = new ArrayList<>();

    // Server TPS tracking (via ClientTickEvent timing)
    private long lastClientTickNano;
    private double currentServerTps;
    private final double[] tpsHistory = new double[60]; // 3 sec window
    private int tpsHistoryIdx;
    private int tpsHistoryCount;
    private double avgServerTps;
    private final List<Double> allTps = new ArrayList<>();
    private long clientTickCounter;

    // Spike categorization
    private static final double SPIKE_THRESHOLD_MS = 33.3; // below 30fps
    private int spikesFromWorldRender;
    private int spikesFromHud;
    private int spikesCorrelatedWithGc;

    // Reflection cache for ChunkRenderDispatcher field
    private Field chunkDispatcherField;
    private boolean reflectionFailed = false;

    private RenderProfiler() {
        // Snapshot initial GC state
        long[] gc = gcSnapshot();
        lastGcCount = gc[0];
        lastGcTimeMs = gc[1];
    }

    // --- Forge event handlers ---

    @SubscribeEvent
    public void onRenderTickPre(TickEvent.RenderTickEvent event) {
        if (event.phase != TickEvent.Phase.START) return;
        frameStartNano = System.nanoTime();
        worldRenderEndNano = 0;
        frameActive = true;

        // GPU timer: init on first call (must be on render thread with GL context)
        if (!gpuTimerChecked) {
            initGpuTimer();
        }

        if (gpuTimerAvailable) {
            // Read previous frame's GPU time (1 frame latency for async readback)
            if (!gpuFirstFrame) {
                int prevQuery = 1 - gpuQueryIndex;
                int available = GL15.glGetQueryObjecti(gpuQueryIds[prevQuery],
                        GL15.GL_QUERY_RESULT_AVAILABLE);
                if (available != 0) {
                    int gpuNanos = GL15.glGetQueryObjecti(gpuQueryIds[prevQuery],
                            GL15.GL_QUERY_RESULT);
                    currentGpuMs = Integer.toUnsignedLong(gpuNanos) / 1_000_000.0;
                }
            }
            // Begin this frame's query
            GL15.glBeginQuery(GL_TIME_ELAPSED, gpuQueryIds[gpuQueryIndex]);
        }
    }

    @SubscribeEvent
    public void onRenderTickPost(TickEvent.RenderTickEvent event) {
        if (event.phase != TickEvent.Phase.END) return;
        if (!frameActive) return;
        frameActive = false;

        // End GPU timer query before reading CPU time
        if (gpuTimerAvailable) {
            GL15.glEndQuery(GL_TIME_ELAPSED);
            gpuQueryIndex = 1 - gpuQueryIndex;
            gpuFirstFrame = false;
        }

        frameEndNano = System.nanoTime();
        currentFrameMs = (frameEndNano - frameStartNano) / 1_000_000.0;
        currentWorldMs = worldRenderEndNano > 0
                ? (worldRenderEndNano - frameStartNano) / 1_000_000.0
                : 0;

        // GC pause detection: check if GC ran during this frame
        long[] gc = gcSnapshot();
        long gcCountDelta = gc[0] - lastGcCount;
        long gcTimeDelta = gc[1] - lastGcTimeMs;
        lastGcCount = gc[0];
        lastGcTimeMs = gc[1];
        gcPauseMsThisFrame = gcTimeDelta;
        if (gcCountDelta > 0) {
            gcPausesThisSession += gcCountDelta;
            gcTotalPauseMs += gcTimeDelta;
            if (gcTimeDelta > maxGcPauseMs) maxGcPauseMs = gcTimeDelta;
        }

        // Rolling averages (CPU + GPU)
        int idx = historyIndex;
        frameHistory[idx] = currentFrameMs;
        worldHistory[idx] = currentWorldMs;
        gpuHistory[idx] = currentGpuMs;
        historyIndex = (idx + 1) % HISTORY_SIZE;
        if (historyCount < HISTORY_SIZE) historyCount++;

        double sumFrame = 0, sumWorld = 0, sumGpu = 0;
        for (int i = 0; i < historyCount; i++) {
            sumFrame += frameHistory[i];
            sumWorld += worldHistory[i];
            sumGpu += gpuHistory[i];
        }
        avgFrameMs = sumFrame / historyCount;
        avgWorldMs = sumWorld / historyCount;
        avgGpuMs = sumGpu / historyCount;

        // Update counts (cheap, once per frame)
        updateCounts();

        // Spike categorization
        if (currentFrameMs > SPIKE_THRESHOLD_MS) {
            double hudMs = currentFrameMs - currentWorldMs;
            if (currentWorldMs > hudMs) {
                spikesFromWorldRender++;
            } else {
                spikesFromHud++;
            }
            if (gcTimeDelta > 5) { // >5ms GC during this frame
                spikesCorrelatedWithGc++;
            }
        }

        // Accumulate for session summary
        if (sessionActive) {
            allFrames.add(new double[]{currentFrameMs, currentWorldMs});
            allCounts.add(new int[]{entityCount, blockEntityCount});
            allGpuTimes.add(currentGpuMs);
            gcPausePerFrame.add(gcPauseMsThisFrame);
        }

        frameCount++;
    }

    @SubscribeEvent
    public void onRenderWorldLast(RenderWorldLastEvent event) {
        worldRenderEndNano = System.nanoTime();
    }

    @SubscribeEvent
    public void onClientTick(TickEvent.ClientTickEvent event) {
        if (event.phase != TickEvent.Phase.END) return;
        long now = System.nanoTime();
        clientTickCounter++;

        if (lastClientTickNano > 0) {
            double deltaSec = (now - lastClientTickNano) / 1_000_000_000.0;
            if (deltaSec > 0.001 && deltaSec < 5.0) {
                currentServerTps = 1.0 / deltaSec;
                // Clamp to 20 max (server can't tick faster than 20 TPS)
                if (currentServerTps > 20.0) currentServerTps = 20.0;

                tpsHistory[tpsHistoryIdx] = currentServerTps;
                tpsHistoryIdx = (tpsHistoryIdx + 1) % tpsHistory.length;
                if (tpsHistoryCount < tpsHistory.length) tpsHistoryCount++;

                double sum = 0;
                for (int i = 0; i < tpsHistoryCount; i++) sum += tpsHistory[i];
                avgServerTps = sum / tpsHistoryCount;

                if (sessionActive) {
                    allTps.add(currentServerTps);
                }
            }
        }
        lastClientTickNano = now;
    }

    // --- GC helpers ---

    private long[] gcSnapshot() {
        long count = 0, timeMs = 0;
        for (GarbageCollectorMXBean bean : gcBeans) {
            long c = bean.getCollectionCount();
            long t = bean.getCollectionTime();
            if (c >= 0) count += c;
            if (t >= 0) timeMs += t;
        }
        return new long[]{count, timeMs};
    }

    // --- GPU timer init ---

    private void initGpuTimer() {
        gpuTimerChecked = true;
        try {
            // Clear any pending GL errors
            while (GL11.glGetError() != GL11.GL_NO_ERROR) {}

            gpuQueryIds = new int[2];
            gpuQueryIds[0] = GL15.glGenQueries();
            gpuQueryIds[1] = GL15.glGenQueries();

            // Test if GL_TIME_ELAPSED target is accepted
            GL15.glBeginQuery(GL_TIME_ELAPSED, gpuQueryIds[0]);
            int err = GL11.glGetError();
            if (err == GL11.GL_NO_ERROR) {
                GL15.glEndQuery(GL_TIME_ELAPSED);
                // Drain the test query result
                GL15.glGetQueryObjecti(gpuQueryIds[0], GL15.GL_QUERY_RESULT);
                gpuTimerAvailable = true;
                LOGGER.info("[PROFILER] GPU timer queries enabled (GL_TIME_ELAPSED supported)");
            } else {
                LOGGER.info("[PROFILER] GPU timer queries unavailable (GL error 0x{})",
                        Integer.toHexString(err));
                GL15.glDeleteQueries(gpuQueryIds[0]);
                GL15.glDeleteQueries(gpuQueryIds[1]);
            }
        } catch (Exception e) {
            LOGGER.warn("[PROFILER] GPU timer init failed: {}", e.getMessage());
            gpuTimerAvailable = false;
        }
    }

    // --- Count updates ---

    private void updateCounts() {
        Minecraft mc = Minecraft.getInstance();
        if (mc.level == null) return;

        // Entity count
        int ents = 0;
        for (Entity e : mc.level.entitiesForRendering()) {
            ents++;
        }
        entityCount = ents;

        // Block entity count
        blockEntityCount = mc.level.blockEntityList.size();

        // Chunk dispatcher via reflection
        if (!reflectionFailed) {
            try {
                if (chunkDispatcherField == null) {
                    chunkDispatcherField = WorldRenderer.class.getDeclaredField("chunkRenderDispatcher");
                    chunkDispatcherField.setAccessible(true);
                }
                ChunkRenderDispatcher dispatcher =
                        (ChunkRenderDispatcher) chunkDispatcherField.get(mc.levelRenderer);
                if (dispatcher != null) {
                    chunkStatus = dispatcher.getStats();
                }
            } catch (NoSuchFieldException e) {
                // Try SRG name for production
                try {
                    chunkDispatcherField = WorldRenderer.class.getDeclaredField("field_174995_M");
                    chunkDispatcherField.setAccessible(true);
                } catch (NoSuchFieldException e2) {
                    reflectionFailed = true;
                }
            } catch (Exception e) {
                reflectionFailed = true;
            }
        }
    }

    // --- Session lifecycle ---

    public void startSession(File gameDirectory) {
        this.gameDir = gameDirectory;
        this.sessionActive = true;
        this.frameCount = 0;
        allFrames.clear();
        allCounts.clear();
        allGpuTimes.clear();
        gcPausePerFrame.clear();
        allTps.clear();
        gcPausesThisSession = 0;
        gcTotalPauseMs = 0;
        maxGcPauseMs = 0;
        spikesFromWorldRender = 0;
        spikesFromHud = 0;
        spikesCorrelatedWithGc = 0;
        long[] gc = gcSnapshot();
        lastGcCount = gc[0];
        lastGcTimeMs = gc[1];
    }

    public void endSession() {
        if (!sessionActive) return;
        sessionActive = false;
        writeSummary();
    }

    // --- Getters for overlay ---

    public double getAvgFrameMs() { return avgFrameMs; }
    public double getAvgWorldMs() { return avgWorldMs; }
    public double getCurrentFrameMs() { return currentFrameMs; }
    public double getCurrentWorldMs() { return currentWorldMs; }
    public int getEntityCount() { return entityCount; }
    public int getBlockEntityCount() { return blockEntityCount; }
    public String getChunkStatus() { return chunkStatus; }
    public long getFrameCount() { return frameCount; }
    public boolean isActive() { return frameCount > 10; }
    public double getAvgGpuMs() { return avgGpuMs; }
    public double getCurrentGpuMs() { return currentGpuMs; }
    public boolean isGpuTimerAvailable() { return gpuTimerAvailable; }
    public double getGcPauseMsThisFrame() { return gcPauseMsThisFrame; }
    public long getGcPausesThisSession() { return gcPausesThisSession; }
    public long getGcTotalPauseMs() { return gcTotalPauseMs; }
    public double getAvgServerTps() { return avgServerTps; }
    public double getCurrentServerTps() { return currentServerTps; }

    public void setCullingStats(int totalCulled, int totalRendered, int budgetCulled) {
        this.cullingTotalCulled = totalCulled;
        this.cullingTotalRendered = totalRendered;
        this.cullingBudgetCulled = budgetCulled;
    }

    public void setBECullingStats(int totalCulled, int totalRendered, int wrappedCount) {
        this.beCullingTotalCulled = totalCulled;
        this.beCullingTotalRendered = totalRendered;
        this.beCullingWrappedCount = wrappedCount;
    }

    public void setStageTiming(double totalEntityRenderMs, double totalBeRenderMs) {
        this.totalEntityRenderMs = totalEntityRenderMs;
        this.totalBeRenderMs = totalBeRenderMs;
    }

    public void setEntityTypeBreakdown(List<String[]> breakdown) {
        this.entityTypeBreakdown = breakdown;
    }

    public void setBETypeBreakdown(List<String[]> breakdown) {
        this.beTypeBreakdown = breakdown;
    }

    public void setUploadBudgetStats(int uploaded, int deferred, int framesDeferred) {
        this.uploadBudgetUploaded = uploaded;
        this.uploadBudgetDeferred = deferred;
        this.uploadBudgetFramesDeferred = framesDeferred;
    }

    // --- Summary ---

    private void writeSummary() {
        if (allFrames.isEmpty() || gameDir == null) return;

        File outFile = new File(gameDir, "profiler_summary.txt");
        try (PrintWriter w = new PrintWriter(new BufferedWriter(new FileWriter(outFile)))) {
            int n = allFrames.size();

            w.println("=== SkyFactory Render Profiler Summary ===");
            w.printf("Frames: %d%n%n", n);

            // Frame time stats
            double[] frameTimes = new double[n];
            double[] worldTimes = new double[n];
            for (int i = 0; i < n; i++) {
                frameTimes[i] = allFrames.get(i)[0];
                worldTimes[i] = allFrames.get(i)[1];
            }

            Arrays.sort(frameTimes);
            Arrays.sort(worldTimes);

            w.println("Metric           |   avg   |   p50   |   p95   |   p99   |   max");
            w.println("-----------------|---------|---------|---------|---------|--------");
            printPercentiles(w, "Frame time", frameTimes, n);
            printPercentiles(w, "World render", worldTimes, n);

            // GPU time stats (if timer queries were available)
            if (!allGpuTimes.isEmpty()) {
                double[] gpuTimes = new double[allGpuTimes.size()];
                for (int i = 0; i < gpuTimes.length; i++) {
                    gpuTimes[i] = allGpuTimes.get(i);
                }
                Arrays.sort(gpuTimes);
                printPercentiles(w, "GPU time", gpuTimes, gpuTimes.length);
            } else {
                w.printf("%-17s| (timer queries unavailable on GL 2.1 compat)%n", "GPU time");
            }

            // Derived: HUD/other = frame - world
            double avgFrame = avg(frameTimes);
            double avgWorld = avg(worldTimes);
            w.printf("%-17s| %5.1f ms|         |         |         |%n", "HUD/other", avgFrame - avgWorld);

            // FPS
            w.println();
            double fps = avgFrame > 0 ? 1000.0 / avgFrame : 0;
            w.printf("Effective FPS: %.0f%n", fps);

            // CPU vs GPU analysis
            if (!allGpuTimes.isEmpty()) {
                double[] gpuTimes = new double[allGpuTimes.size()];
                for (int i = 0; i < gpuTimes.length; i++) {
                    gpuTimes[i] = allGpuTimes.get(i);
                }
                double avgGpu = avg(gpuTimes);
                w.println();
                w.println("--- CPU vs GPU Analysis ---");
                w.printf("Avg CPU frame time: %.1f ms%n", avgFrame);
                w.printf("Avg GPU frame time: %.1f ms%n", avgGpu);
                if (avgGpu > 0.001) {
                    double ratio = avgFrame / avgGpu;
                    String bottleneck = ratio > 2.0 ? "CPU-BOUND"
                            : ratio < 0.5 ? "GPU-BOUND" : "BALANCED";
                    w.printf("CPU/GPU ratio: %.1fx (%s)%n", ratio, bottleneck);
                }
                w.printf("GPU utilization estimate: %.0f%%%n",
                        avgFrame > 0 ? (avgGpu / avgFrame) * 100.0 : 0);
            }

            // Per-stage CPU breakdown
            if (n > 0 && (totalEntityRenderMs > 0 || totalBeRenderMs > 0)) {
                double avgEntityMs = totalEntityRenderMs / n;
                double avgBeMs = totalBeRenderMs / n;
                double avgTerrainMs = Math.max(0, avgWorld - avgEntityMs - avgBeMs);
                double avgHudMs = avgFrame - avgWorld;

                w.println();
                w.println("--- Per-Stage CPU Breakdown (session avg per frame) ---");
                w.printf("%-20s %6.2f ms  (%4.1f%% of frame)%n", "Terrain+chunks",
                        avgTerrainMs, avgFrame > 0 ? avgTerrainMs / avgFrame * 100 : 0);
                w.printf("%-20s %6.2f ms  (%4.1f%% of frame)%n", "Entity rendering",
                        avgEntityMs, avgFrame > 0 ? avgEntityMs / avgFrame * 100 : 0);
                w.printf("%-20s %6.2f ms  (%4.1f%% of frame)%n", "Block entity render",
                        avgBeMs, avgFrame > 0 ? avgBeMs / avgFrame * 100 : 0);
                w.printf("%-20s %6.2f ms  (%4.1f%% of frame)%n", "HUD/post-process",
                        avgHudMs, avgFrame > 0 ? avgHudMs / avgFrame * 100 : 0);
                w.printf("%-20s %6.2f ms%n", "World render total", avgWorld);
                w.printf("%-20s %6.2f ms%n", "Frame total", avgFrame);

                // Identify biggest bottleneck
                String topBottleneck;
                double topMs;
                if (avgTerrainMs >= avgEntityMs && avgTerrainMs >= avgBeMs) {
                    topBottleneck = "TERRAIN+CHUNKS";
                    topMs = avgTerrainMs;
                } else if (avgEntityMs >= avgBeMs) {
                    topBottleneck = "ENTITY RENDERING";
                    topMs = avgEntityMs;
                } else {
                    topBottleneck = "BLOCK ENTITY RENDERING";
                    topMs = avgBeMs;
                }
                w.printf("Primary CPU bottleneck: %s (%.2f ms, %.1f%% of world render)%n",
                        topBottleneck, topMs, avgWorld > 0 ? topMs / avgWorld * 100 : 0);
            }

            // Entity/BE stats
            w.println();
            int maxEnt = 0, maxBE = 0;
            long sumEnt = 0, sumBE = 0;
            for (int[] c : allCounts) {
                sumEnt += c[0]; sumBE += c[1];
                if (c[0] > maxEnt) maxEnt = c[0];
                if (c[1] > maxBE) maxBE = c[1];
            }
            w.printf("Entities:      avg=%d  max=%d%n", (int)(sumEnt / (double)n), maxEnt);
            w.printf("BlockEntities: avg=%d  max=%d%n", (int)(sumBE / (double)n), maxBE);

            // Chunk status (last known)
            if (chunkStatus != null && !chunkStatus.isEmpty()) {
                w.printf("ChunkDispatcher: %s%n", chunkStatus);
            }

            // Spike analysis
            w.println();
            double avgF = avg(frameTimes);
            int spikeCount = 0;
            double worstSpike = 0;
            for (double[] frame : allFrames) {
                if (frame[0] > avgF * 2) {
                    spikeCount++;
                    if (frame[0] > worstSpike) worstSpike = frame[0];
                }
            }
            w.printf("Frame spikes (>2x avg): %d / %d frames (%.1f%%)%n",
                    spikeCount, n, (spikeCount * 100.0) / n);
            if (worstSpike > 0) {
                w.printf("Worst spike: %.1f ms%n", worstSpike);
            }

            // Frame pacing analysis
            w.println();
            w.println("--- Frame Pacing ---");
            int over16 = 0, over33 = 0, over50 = 0, over100 = 0;
            for (double[] frame : allFrames) {
                double t = frame[0];
                if (t > 16.67) over16++;
                if (t > 33.33) over33++;
                if (t > 50.0) over50++;
                if (t > 100.0) over100++;
            }
            w.printf("Frames >16.7ms (below 60fps): %d / %d (%.1f%%)%n", over16, n, (over16 * 100.0) / n);
            w.printf("Frames >33.3ms (below 30fps): %d / %d (%.1f%%)%n", over33, n, (over33 * 100.0) / n);
            w.printf("Frames >50ms   (stutter):     %d / %d (%.1f%%)%n", over50, n, (over50 * 100.0) / n);
            w.printf("Frames >100ms  (freeze):      %d / %d (%.1f%%)%n", over100, n, (over100 * 100.0) / n);
            double jitter = frameTimes[(int)(n * 0.95)] - frameTimes[(int)(n * 0.05)];
            w.printf("Frame time jitter (p95-p05): %.1f ms%n", jitter);

            // Bottleneck hints
            w.println();
            w.println("--- Bottleneck Hints ---");
            int avgEnts = (int)(sumEnt / (double)n);
            int avgBEs = (int)(sumBE / (double)n);
            if (avgEnts > 200) {
                w.printf("HIGH ENTITY COUNT (%d avg). Mob farms, item entities, or modded entities likely contributing.%n", avgEnts);
            }
            if (avgBEs > 500) {
                w.printf("HIGH BLOCK ENTITY COUNT (%d avg). Mekanism, AE2, Industrial Foregoing machines likely contributing.%n", avgBEs);
            }
            if (avgWorld > 12) {
                w.printf("WORLD RENDER TIME HIGH (%.1f ms avg). Terrain + entities + BEs combined are the bottleneck.%n", avgWorld);
            }
            double spikeRate = (spikeCount * 100.0) / n;
            if (spikeRate > 5) {
                w.printf("FREQUENT SPIKES (%.1f%%). Likely chunk rebuilds or light updates causing frame stalls.%n", spikeRate);
            }

            // Entity culling stats
            if (cullingTotalCulled > 0 || cullingTotalRendered > 0) {
                w.println();
                w.println("--- Entity Culling Stats ---");
                int totalAttempts = cullingTotalCulled + cullingTotalRendered;
                double cullRate = totalAttempts > 0
                        ? (cullingTotalCulled * 100.0) / totalAttempts : 0;
                w.printf("Living entities culled: %d / %d (%.1f%%)%n",
                        cullingTotalCulled, totalAttempts, cullRate);
                w.printf("Avg culled per frame: %.1f%n",
                        n > 0 ? cullingTotalCulled / (double) n : 0);
                if (cullingBudgetCulled > 0) {
                    w.printf("Budget-culled (nearby density cap): %d%n", cullingBudgetCulled);
                }
            }

            // Block entity culling stats
            w.println();
            w.println("--- Block Entity Culling Stats ---");
            w.printf("Wrapped renderers: %d%n", beCullingWrappedCount);
            if (beCullingTotalCulled > 0 || beCullingTotalRendered > 0) {
                int beTotal = beCullingTotalCulled + beCullingTotalRendered;
                double beCullRate = beTotal > 0
                        ? (beCullingTotalCulled * 100.0) / beTotal : 0;
                w.printf("BE render calls culled: %d / %d (%.1f%%)%n",
                        beCullingTotalCulled, beTotal, beCullRate);
                w.printf("Avg BE culled per frame: %.1f%n",
                        n > 0 ? beCullingTotalCulled / (double) n : 0);
                w.printf("Avg BE rendered per frame: %.1f%n",
                        n > 0 ? beCullingTotalRendered / (double) n : 0);
            } else {
                w.println("No BE render calls intercepted (wrapper may not have installed)");
            }

            // Per-type entity breakdown
            if (!entityTypeBreakdown.isEmpty()) {
                w.println();
                w.println("--- Entity Type CPU Breakdown ---");
                w.printf("%-35s %8s %8s %8s%n", "Type", "AvgMs/f", "TotalMs", "Calls");
                for (String[] row : entityTypeBreakdown) {
                    w.printf("%-35s %8s %8s %8s%n", row[0], row[1], row[2], row[3]);
                }
            }

            // Per-type BE breakdown
            if (!beTypeBreakdown.isEmpty()) {
                w.println();
                w.println("--- Block Entity Type CPU Breakdown ---");
                w.printf("%-35s %8s %8s %8s%n", "Type", "AvgMs/f", "TotalMs", "Calls");
                for (String[] row : beTypeBreakdown) {
                    w.printf("%-35s %8s %8s %8s%n", row[0], row[1], row[2], row[3]);
                }
            }

            // Chunk upload budget stats
            if (uploadBudgetUploaded > 0 || uploadBudgetDeferred > 0) {
                w.println();
                w.println("--- Chunk Upload Budget ---");
                int totalUploadAttempts = uploadBudgetUploaded + uploadBudgetDeferred;
                w.printf("Uploads processed: %d%n", uploadBudgetUploaded);
                w.printf("Uploads deferred: %d (%.1f%%)%n", uploadBudgetDeferred,
                        totalUploadAttempts > 0
                                ? (uploadBudgetDeferred * 100.0) / totalUploadAttempts : 0);
                w.printf("Frames with deferral: %d / %d (%.1f%%)%n",
                        uploadBudgetFramesDeferred, n,
                        n > 0 ? (uploadBudgetFramesDeferred * 100.0) / n : 0);
                w.printf("Avg uploads per frame: %.1f%n",
                        n > 0 ? uploadBudgetUploaded / (double) n : 0);
            }

            // GC analysis
            w.println();
            w.println("--- Garbage Collection ---");
            w.printf("GC pauses during session: %d%n", gcPausesThisSession);
            w.printf("Total GC pause time: %d ms%n", gcTotalPauseMs);
            w.printf("Worst GC pause: %.0f ms%n", maxGcPauseMs);
            if (n > 0) {
                w.printf("Avg GC time per frame: %.2f ms%n", gcTotalPauseMs / (double) n);
            }
            // GC time percentiles
            if (!gcPausePerFrame.isEmpty()) {
                double[] gcTimes = new double[gcPausePerFrame.size()];
                for (int i = 0; i < gcTimes.length; i++) gcTimes[i] = gcPausePerFrame.get(i);
                Arrays.sort(gcTimes);
                int gn = gcTimes.length;
                int framesWithGc = 0;
                for (double g : gcTimes) if (g > 0.1) framesWithGc++;
                w.printf("Frames with GC activity: %d / %d (%.1f%%)%n",
                        framesWithGc, gn, (framesWithGc * 100.0) / gn);
                if (framesWithGc > 0) {
                    // Among frames that had GC, what were the pause times?
                    double[] nonZeroGc = new double[framesWithGc];
                    int j = 0;
                    for (double g : gcTimes) if (g > 0.1) nonZeroGc[j++] = g;
                    Arrays.sort(nonZeroGc);
                    w.printf("GC pause p50: %.1f ms  p95: %.1f ms  p99: %.1f ms%n",
                            nonZeroGc[(int)(framesWithGc * 0.50)],
                            nonZeroGc[(int)(framesWithGc * 0.95)],
                            nonZeroGc[Math.min((int)(framesWithGc * 0.99), framesWithGc - 1)]);
                }
                MemoryMXBean mem = ManagementFactory.getMemoryMXBean();
                long heapUsed = mem.getHeapMemoryUsage().getUsed() / (1024 * 1024);
                long heapMax = mem.getHeapMemoryUsage().getMax() / (1024 * 1024);
                w.printf("Heap at session end: %d / %d MB (%.0f%% used)%n",
                        heapUsed, heapMax, heapMax > 0 ? (heapUsed * 100.0) / heapMax : 0);
            }

            // Server TPS analysis
            if (!allTps.isEmpty()) {
                w.println();
                w.println("--- Server TPS ---");
                double[] tpsSorted = new double[allTps.size()];
                for (int i = 0; i < tpsSorted.length; i++) tpsSorted[i] = allTps.get(i);
                Arrays.sort(tpsSorted);
                int tn = tpsSorted.length;
                double tpsAvg = avg(tpsSorted);
                double tpsP05 = tpsSorted[(int)(tn * 0.05)];
                double tpsP50 = tpsSorted[(int)(tn * 0.50)];
                w.printf("Avg TPS: %.1f  Median: %.1f  Worst 5%%: %.1f%n",
                        tpsAvg, tpsP50, tpsP05);
                int below15 = 0, below10 = 0, below5 = 0;
                for (double t : tpsSorted) {
                    if (t < 15) below15++;
                    if (t < 10) below10++;
                    if (t < 5) below5++;
                }
                w.printf("Ticks below 15 TPS: %d / %d (%.1f%%)%n",
                        below15, tn, (below15 * 100.0) / tn);
                w.printf("Ticks below 10 TPS: %d / %d (%.1f%%)%n",
                        below10, tn, (below10 * 100.0) / tn);
                if (below5 > 0) {
                    w.printf("Ticks below 5 TPS: %d / %d (%.1f%%)%n",
                            below5, tn, (below5 * 100.0) / tn);
                }
                if (tpsAvg < 18) {
                    w.println("** SERVER IS LAGGING ** - Low TPS causes entity stutter");
                    w.println("   regardless of client FPS. This is NOT a client-side issue.");
                }
            }

            // Spike categorization
            int totalSpikes = spikesFromWorldRender + spikesFromHud;
            if (totalSpikes > 0) {
                w.println();
                w.println("--- Spike Breakdown (frames >33ms) ---");
                w.printf("Total spikes: %d%n", totalSpikes);
                w.printf("Caused by world render: %d (%.0f%%)%n",
                        spikesFromWorldRender,
                        (spikesFromWorldRender * 100.0) / totalSpikes);
                w.printf("Caused by HUD/post: %d (%.0f%%)%n",
                        spikesFromHud,
                        (spikesFromHud * 100.0) / totalSpikes);
                w.printf("Correlated with GC: %d (%.0f%%)%n",
                        spikesCorrelatedWithGc,
                        (spikesCorrelatedWithGc * 100.0) / totalSpikes);
            }

            // Diagnosis summary
            w.println();
            w.println("--- DIAGNOSIS ---");
            if (maxGcPauseMs > 100) {
                w.printf("GC PAUSES are causing freezes (worst: %.0f ms). Tune JVM GC args.%n",
                        maxGcPauseMs);
            }
            if (!allTps.isEmpty()) {
                double[] tpsSorted = new double[allTps.size()];
                for (int i = 0; i < tpsSorted.length; i++) tpsSorted[i] = allTps.get(i);
                double tpsAvgD = avg(tpsSorted);
                if (tpsAvgD < 18) {
                    w.printf("SERVER LAG (%.1f avg TPS). Entities will stutter at server tick rate%n", tpsAvgD);
                    w.println("regardless of client FPS. Server-side optimization needed.");
                }
            }
            if (avgWorld > 8 && avgFrame > 12) {
                w.println("TERRAIN DRAW CALLS dominate world render time (macOS GL overhead).");
                w.println("Metal chunk renderer (Phase D) would reduce this by ~5-10x.");
            }

            w.flush();
        } catch (IOException e) {
            e.printStackTrace();
        }
    }

    private void printPercentiles(PrintWriter w, String label, double[] sorted, int n) {
        double a = avg(sorted);
        double p50 = sorted[(int)(n * 0.50)];
        double p95 = sorted[(int)(n * 0.95)];
        double p99 = sorted[Math.min((int)(n * 0.99), n - 1)];
        double max = sorted[n - 1];
        w.printf("%-17s| %5.1f ms| %5.1f ms| %5.1f ms| %5.1f ms| %5.1f ms%n",
                label, a, p50, p95, p99, max);
    }

    private static double avg(double[] arr) {
        double sum = 0;
        for (double v : arr) sum += v;
        return arr.length == 0 ? 0 : sum / arr.length;
    }
}
