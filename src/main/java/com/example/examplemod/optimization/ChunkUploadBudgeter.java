package com.example.examplemod.optimization;

import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.util.AbstractQueue;
import java.util.Iterator;
import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;

import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.WorldRenderer;
import net.minecraft.client.renderer.chunk.ChunkRenderDispatcher;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

/**
 * Budgets chunk GPU uploads to prevent frame spikes.
 *
 * ChunkRenderDispatcher.uploadAllPendingUploads() drains its entire
 * toUpload queue (ConcurrentLinkedQueue) with no time limit. With many
 * chunks compiling simultaneously (mob farms, auto-crafting, etc.),
 * this can stall the frame for 20-100ms+.
 *
 * We replace the upload queue with a time-budgeted wrapper that stops
 * yielding items after a configurable budget. Remaining uploads are
 * deferred to the next frame. Visually, this means some chunks render
 * with 1-frame-stale data during heavy compilation, which is invisible
 * in practice.
 */
public class ChunkUploadBudgeter {

    private static final Logger LOGGER = LogManager.getLogger();

    // 3ms budget for uploads per frame (~18% of a 16.67ms frame at 60fps).
    private static final long UPLOAD_BUDGET_NS = 3_000_000;

    // Always process at least this many uploads even if budget exceeded,
    // to prevent unbounded queue growth during sustained heavy compilation.
    private static final int MIN_UPLOADS_PER_FRAME = 4;

    private boolean installed = false;
    private boolean attemptedInstall = false;
    private BudgetedQueue<Runnable> budgetedQueue;
    private Field uploadQueueField;
    private Field dispatcherField;

    // Stats
    private int totalDeferred;
    private int totalUploaded;
    private int framesWithDeferral;
    private long frameCounter;

    public void tryInstall() {
        if (attemptedInstall) return;

        Minecraft mc = Minecraft.getInstance();
        if (mc.level == null || mc.levelRenderer == null) return;

        attemptedInstall = true;

        try {
            // Get ChunkRenderDispatcher from WorldRenderer
            dispatcherField = findField(WorldRenderer.class,
                    "chunkRenderDispatcher", "field_174995_M");
            if (dispatcherField == null) {
                // Scan all fields for ChunkRenderDispatcher type
                for (Field f : WorldRenderer.class.getDeclaredFields()) {
                    if (ChunkRenderDispatcher.class.isAssignableFrom(f.getType())) {
                        dispatcherField = f;
                        break;
                    }
                }
            }
            if (dispatcherField == null) {
                LOGGER.warn("[UPLOAD-BUDGET] Could not find chunkRenderDispatcher field");
                return;
            }
            dispatcherField.setAccessible(true);

            ChunkRenderDispatcher dispatcher =
                    (ChunkRenderDispatcher) dispatcherField.get(mc.levelRenderer);
            if (dispatcher == null) {
                LOGGER.warn("[UPLOAD-BUDGET] ChunkRenderDispatcher is null");
                return;
            }

            // Find the toUpload queue (ConcurrentLinkedQueue<Runnable>)
            uploadQueueField = findUploadQueueField(dispatcher);
            if (uploadQueueField == null) {
                LOGGER.warn("[UPLOAD-BUDGET] Could not find toUpload queue field");
                return;
            }

            // Remove final modifier
            try {
                Field modifiersField = Field.class.getDeclaredField("modifiers");
                modifiersField.setAccessible(true);
                modifiersField.setInt(uploadQueueField,
                        uploadQueueField.getModifiers() & ~Modifier.FINAL);
            } catch (NoSuchFieldException e) {
                LOGGER.info("[UPLOAD-BUDGET] No modifiers field (Java 12+)");
            }

            @SuppressWarnings("unchecked")
            Queue<Runnable> originalQueue = (Queue<Runnable>) uploadQueueField.get(dispatcher);
            if (originalQueue == null) {
                LOGGER.warn("[UPLOAD-BUDGET] toUpload queue is null");
                return;
            }

            // Create budgeted wrapper, drain existing items into it
            budgetedQueue = new BudgetedQueue<>(UPLOAD_BUDGET_NS, MIN_UPLOADS_PER_FRAME);
            Runnable item;
            while ((item = originalQueue.poll()) != null) {
                budgetedQueue.offer(item);
            }

            // Replace the field
            uploadQueueField.set(dispatcher, budgetedQueue);
            installed = true;

            LOGGER.info("[UPLOAD-BUDGET] Installed ({}ms budget, min {} per frame, field '{}')",
                    UPLOAD_BUDGET_NS / 1_000_000.0, MIN_UPLOADS_PER_FRAME,
                    uploadQueueField.getName());

        } catch (Exception e) {
            LOGGER.error("[UPLOAD-BUDGET] Failed to install", e);
        }
    }

    private Field findField(Class<?> clazz, String... names) {
        for (String name : names) {
            try {
                return clazz.getDeclaredField(name);
            } catch (NoSuchFieldException ignored) {}
        }
        return null;
    }

    @SuppressWarnings("unchecked")
    private Field findUploadQueueField(ChunkRenderDispatcher dispatcher) {
        // Log all fields for debugging
        LOGGER.info("[UPLOAD-BUDGET] Fields on ChunkRenderDispatcher:");
        for (Field f : ChunkRenderDispatcher.class.getDeclaredFields()) {
            LOGGER.info("[UPLOAD-BUDGET]   {} {} {}",
                    Modifier.toString(f.getModifiers()), f.getType().getSimpleName(), f.getName());
        }

        // Find the ConcurrentLinkedQueue field (there should be exactly one)
        for (Field f : ChunkRenderDispatcher.class.getDeclaredFields()) {
            try {
                f.setAccessible(true);
                Object value = f.get(dispatcher);
                if (value instanceof ConcurrentLinkedQueue) {
                    LOGGER.info("[UPLOAD-BUDGET] Found upload queue: field '{}' (ConcurrentLinkedQueue, {} items)",
                            f.getName(), ((ConcurrentLinkedQueue<?>) value).size());
                    return f;
                }
            } catch (Exception e) {
                LOGGER.debug("[UPLOAD-BUDGET] Skipping field '{}': {}", f.getName(), e.getMessage());
            }
        }

        return null;
    }

    /**
     * Call at the start of each render frame to reset the upload budget.
     */
    public void onFrameStart() {
        if (!installed || budgetedQueue == null) return;

        int processed = budgetedQueue.getProcessedCount();
        int deferred = budgetedQueue.getRemainingCount();

        totalUploaded += processed;
        if (deferred > 0) {
            totalDeferred += deferred;
            framesWithDeferral++;
        }

        budgetedQueue.resetBudget();
        frameCounter++;
    }

    /**
     * Reset installation state so budgeter can reinstall on next world join.
     */
    public void reset() {
        installed = false;
        attemptedInstall = false;
        budgetedQueue = null;
    }

    public boolean isInstalled() { return installed; }
    public int getTotalDeferred() { return totalDeferred; }
    public int getTotalUploaded() { return totalUploaded; }
    public int getFramesWithDeferral() { return framesWithDeferral; }
    public long getFrameCount() { return frameCounter; }

    /**
     * Queue wrapper that enforces a per-frame time budget on poll().
     *
     * Worker threads add items via offer() (delegated to ConcurrentLinkedQueue,
     * thread-safe). The render thread drains via poll() (budgeted, single-threaded).
     */
    static class BudgetedQueue<T> extends AbstractQueue<T> {
        private final ConcurrentLinkedQueue<T> delegate = new ConcurrentLinkedQueue<>();
        private final long budgetNanos;
        private final int minPerFrame;

        private long pollStartNano;
        private int processedThisFrame;
        private boolean budgetExceeded;

        BudgetedQueue(long budgetNanos, int minPerFrame) {
            this.budgetNanos = budgetNanos;
            this.minPerFrame = minPerFrame;
        }

        @Override
        public boolean offer(T item) {
            return delegate.offer(item);
        }

        @Override
        public T poll() {
            if (budgetExceeded) {
                return null;
            }

            if (processedThisFrame == 0) {
                pollStartNano = System.nanoTime();
            } else if (processedThisFrame >= minPerFrame) {
                // Only check budget after minimum guaranteed uploads
                if ((System.nanoTime() - pollStartNano) > budgetNanos) {
                    budgetExceeded = true;
                    return null;
                }
            }

            T item = delegate.poll();
            if (item != null) processedThisFrame++;
            return item;
        }

        @Override
        public T peek() {
            return delegate.peek();
        }

        @Override
        public Iterator<T> iterator() {
            return delegate.iterator();
        }

        @Override
        public int size() {
            return delegate.size();
        }

        int getProcessedCount() {
            return processedThisFrame;
        }

        int getRemainingCount() {
            return delegate.size();
        }

        void resetBudget() {
            processedThisFrame = 0;
            budgetExceeded = false;
        }
    }
}
