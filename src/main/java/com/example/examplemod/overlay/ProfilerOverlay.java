package com.example.examplemod.overlay;

import com.example.examplemod.ExampleMod;
import com.example.examplemod.culling.BlockEntityCullingHandler;
import com.example.examplemod.culling.EntityCullingHandler;
import com.example.examplemod.metal.MetalTerrainRenderer;
import com.example.examplemod.profiler.RenderProfiler;
import com.mojang.blaze3d.matrix.MatrixStack;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.AbstractGui;
import net.minecraftforge.client.event.RenderGameOverlayEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;

import java.util.List;

/**
 * HUD overlay displaying per-frame render timing and per-type breakdown.
 * Toggle with F6. All data auto-logged to profiler_summary.txt on world exit.
 */
public class ProfilerOverlay {

    private boolean visible = true;

    private static final int COLOR_GREEN  = 0xFF00FF00;
    private static final int COLOR_YELLOW = 0xFFFFFF00;
    private static final int COLOR_RED    = 0xFFFF4444;
    private static final int COLOR_WHITE  = 0xFFFFFFFF;
    private static final int COLOR_GRAY   = 0xFFAAAAAA;
    private static final int COLOR_BG     = 0x90000000;
    private static final int COLOR_HEADER = 0xFF00CCFF;
    private static final int COLOR_CYAN   = 0xFF00DDCC;

    private static final int LINE_H = 10;
    private static final int BAR_MAX_WIDTH = 100;
    private static final double BAR_SCALE_MS = 16.67; // one frame at 60fps = full bar

    public void toggleVisible() { this.visible = !this.visible; }

    @SubscribeEvent
    public void onRenderOverlay(RenderGameOverlayEvent.Post event) {
        if (event.getType() != RenderGameOverlayEvent.ElementType.ALL) return;
        if (!visible) return;

        Minecraft mc = Minecraft.getInstance();
        MatrixStack stack = event.getMatrixStack();
        RenderProfiler p = RenderProfiler.INSTANCE;

        if (!p.isActive()) return;

        int x = 4;
        int y = 4;

        // Gather timing data
        double frameMs = p.getAvgFrameMs();
        double worldMs = p.getAvgWorldMs();
        double gpuMs = p.isGpuTimerAvailable() ? p.getAvgGpuMs() : 0;
        double entityMs = ExampleMod.ENTITY_CULLER.getEntityRenderMsAvg();
        double beMs = ExampleMod.BE_CULLER.getBeRenderMsAvg();
        double terrainMs = Math.max(0, worldMs - entityMs - beMs);
        double hudMs = frameMs - worldMs;
        int fps = frameMs > 0.001 ? (int)(1000.0 / frameMs) : 0;

        // Count per-type lines
        List<EntityCullingHandler.TypeStats> entityTypes = ExampleMod.ENTITY_CULLER.getTopTypes();
        List<BlockEntityCullingHandler.TypeStats> beTypes = ExampleMod.BE_CULLER.getTopTypes();
        int entityTypeLines = 0;
        for (EntityCullingHandler.TypeStats ts : entityTypes) {
            if (ts.avgMs >= 0.001) entityTypeLines++;
        }
        int beTypeLines = 0;
        for (BlockEntityCullingHandler.TypeStats ts : beTypes) {
            if (ts.avgMs >= 0.001) beTypeLines++;
        }

        // Metal stats
        MetalTerrainRenderer metal = ExampleMod.METAL_TERRAIN;
        boolean metalActive = MetalTerrainRenderer.isActive();
        int metalLines = metalActive ? 7 : 0; // header + GPU + CPU total + 4 RT lines

        // Background
        int bgWidth = 310;
        int lines = 14 + (p.isGpuTimerAvailable() ? 1 : 0) + metalLines;
        if (entityTypeLines > 0) lines += entityTypeLines + 1; // header + entries
        if (beTypeLines > 0) lines += beTypeLines + 1;
        int bgHeight = LINE_H * lines + 12;
        AbstractGui.fill(stack, x - 2, y - 2, x + bgWidth, y + bgHeight, COLOR_BG);

        // Header
        double tps = p.getAvgServerTps();
        int tpsColor = tps >= 18 ? COLOR_GREEN : tps >= 12 ? COLOR_YELLOW : COLOR_RED;
        String header = String.format("[PROFILER] %.1fms (%d FPS) GPU:%.1fms", frameMs, fps, gpuMs);
        mc.font.drawShadow(stack, header, x, y, COLOR_HEADER);
        y += LINE_H;

        // TPS + GC line
        String tpsGc = String.format("TPS: %.0f  GC: %dms total (%d pauses)",
                tps, p.getGcTotalPauseMs(), p.getGcPausesThisSession());
        mc.font.drawShadow(stack, tpsGc, x, y, tpsColor);
        y += LINE_H + 2;

        // CPU breakdown
        mc.font.drawShadow(stack, "--- CPU Breakdown ---", x + 2, y, COLOR_GRAY);
        y += LINE_H;

        drawTimingLine(mc, stack, x, y, "Terrain+other", terrainMs);
        y += LINE_H;

        drawTimingLine(mc, stack, x, y, "Entities", entityMs);
        y += LINE_H;

        drawTimingLine(mc, stack, x, y, "Block entities", beMs);
        y += LINE_H;

        drawTimingLine(mc, stack, x, y, "HUD/post", hudMs);
        y += LINE_H;

        // GPU time
        if (p.isGpuTimerAvailable()) {
            drawTimingLine(mc, stack, x, y, "GPU total", gpuMs);
            y += LINE_H;
        }

        y += 2;

        // Counts + culling stats
        int entCulled = ExampleMod.ENTITY_CULLER.getTotalCulled();
        int entRendered = ExampleMod.ENTITY_CULLER.getTotalRendered();
        int entTotal = entCulled + entRendered;
        double entCullPct = entTotal > 0 ? (entCulled * 100.0) / entTotal : 0;
        int beCulled = ExampleMod.BE_CULLER.getTotalCulled();
        int beRendered = ExampleMod.BE_CULLER.getTotalRendered();
        int beTotal = beCulled + beRendered;
        double beCullPct = beTotal > 0 ? (beCulled * 100.0) / beTotal : 0;

        mc.font.drawShadow(stack, String.format("Ent: %d  BE: %d  Culled: E%.0f%% BE%.0f%%",
                p.getEntityCount(), p.getBlockEntityCount(), entCullPct, beCullPct),
                x, y, COLOR_WHITE);
        y += LINE_H;

        // Chunk dispatcher
        String chunkStatus = p.getChunkStatus();
        if (chunkStatus != null && !chunkStatus.isEmpty()) {
            mc.font.drawShadow(stack, "Chunks: " + chunkStatus, x, y, COLOR_GRAY);
            y += LINE_H;
        }

        // Bottleneck indicator
        String bottleneck;
        if (terrainMs > entityMs && terrainMs > beMs) {
            bottleneck = String.format("Bottleneck: TERRAIN (%.0f%%)", worldMs > 0 ? terrainMs / worldMs * 100 : 0);
        } else if (entityMs > beMs) {
            bottleneck = String.format("Bottleneck: ENTITIES (%.0f%%)", worldMs > 0 ? entityMs / worldMs * 100 : 0);
        } else {
            bottleneck = String.format("Bottleneck: BLOCK ENTITIES (%.0f%%)", worldMs > 0 ? beMs / worldMs * 100 : 0);
        }
        mc.font.drawShadow(stack, bottleneck, x, y, COLOR_YELLOW);
        y += LINE_H + 2;

        // Metal terrain profiling
        if (metalActive) {
            mc.font.drawShadow(stack, "--- Metal Terrain ---", x + 2, y, COLOR_CYAN);
            y += LINE_H;

            double metalGpuMs = metal.getMetalGPUTimeNanos() / 1_000_000.0;
            double metalCpuMs = metal.getUploadTimeNanos() / 1_000_000.0;
            int totalDraws = metal.getMetalDrawCount();
            int totalVerts = metal.getMetalVertexCount();

            String gpuLine = String.format("GPU: %.2fms  CPU: %.2fms  draws:%d  verts:%dk",
                    metalGpuMs, metalCpuMs, totalDraws, totalVerts / 1000);
            mc.font.drawShadow(stack, gpuLine, x + 2, y, timingColor(metalGpuMs));
            y += LINE_H;

            // Per render-type breakdown
            for (int rt = 0; rt < 4; rt++) {
                double rtMs = metal.getRTCpuNanos(rt) / 1_000_000.0;
                int rtDraws = metal.getRTDrawCount(rt);
                int rtVerts = metal.getRTVertexCount(rt);
                String rtLine = String.format("  %-14s %5.2fms  %4d draws  %5dk verts",
                        MetalTerrainRenderer.getRTName(rt), rtMs, rtDraws, rtVerts / 1000);
                mc.font.drawShadow(stack, rtLine, x, y, timingColor(rtMs));
                y += LINE_H;
            }

            // Cache info
            String cacheLine = String.format("VBO cache: %d entries", metal.getCacheSize());
            mc.font.drawShadow(stack, cacheLine, x + 2, y, COLOR_GRAY);
            y += LINE_H + 2;
        }

        // Per-type entity breakdown
        if (entityTypeLines > 0) {
            mc.font.drawShadow(stack, "--- Entity Types (by CPU) ---", x + 2, y, COLOR_CYAN);
            y += LINE_H;
            for (EntityCullingHandler.TypeStats ts : entityTypes) {
                if (ts.avgMs < 0.001) continue;
                String shortName = shortenName(ts.name);
                String line = String.format("  %-22s %5.2fms (%d/f)", shortName, ts.avgMs, ts.thisFrameCalls);
                mc.font.drawShadow(stack, line, x, y, timingColor(ts.avgMs));
                y += LINE_H;
            }
        }

        // Per-type BE breakdown
        if (beTypeLines > 0) {
            mc.font.drawShadow(stack, "--- BE Types (by CPU) ---", x + 2, y, COLOR_CYAN);
            y += LINE_H;
            for (BlockEntityCullingHandler.TypeStats ts : beTypes) {
                if (ts.avgMs < 0.001) continue;
                String shortName = shortenName(ts.name);
                String line = String.format("  %-22s %5.2fms (%d/f)", shortName, ts.avgMs, ts.thisFrameCalls);
                mc.font.drawShadow(stack, line, x, y, timingColor(ts.avgMs));
                y += LINE_H;
            }
        }

        mc.font.drawShadow(stack, "[F6] toggle  [auto-log on exit]", x, y, COLOR_GRAY);
    }

    private void drawTimingLine(Minecraft mc, MatrixStack stack, int x, int y,
                                 String label, double ms) {
        int color = timingColor(ms);
        String text = String.format("%-16s %5.1f ms", label, ms);
        mc.font.drawShadow(stack, text, x + 2, y, color);

        int barX = x + 155;
        int barWidth = (int)(Math.min(ms / BAR_SCALE_MS, 1.0) * BAR_MAX_WIDTH);
        if (barWidth > 0) {
            AbstractGui.fill(stack, barX, y + 1, barX + barWidth, y + LINE_H - 2, color);
        }
    }

    /** Shorten "minecraft:zombie" to "zombie", "mekanism:tile_machine" to "mek:tile_machine" */
    private static String shortenName(String name) {
        if (name == null) return "?";
        int colon = name.indexOf(':');
        if (colon < 0) return truncate(name, 22);
        String namespace = name.substring(0, colon);
        String path = name.substring(colon + 1);
        if ("minecraft".equals(namespace)) return truncate(path, 22);
        // Abbreviate common mod namespaces
        if (namespace.length() > 6) namespace = namespace.substring(0, 3);
        return truncate(namespace + ":" + path, 22);
    }

    private static String truncate(String s, int max) {
        return s.length() <= max ? s : s.substring(0, max - 1) + "~";
    }

    private static int timingColor(double ms) {
        if (ms < 0.5) return COLOR_GREEN;
        if (ms < 2.0) return COLOR_YELLOW;
        return COLOR_RED;
    }
}
