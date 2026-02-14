package com.example.examplemod.metal;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

/**
 * JNI bridge to native Metal renderer (libmetalrenderer.dylib).
 *
 * Phase B: Initialize Metal device + CAMetalLayer on the MC window,
 * render a test triangle to prove GL + Metal coexistence.
 *
 * Phase D: Terrain chunk rendering via Metal batched draws.
 */
public class MetalBridge {

    private static final Logger LOGGER = LogManager.getLogger();
    private static boolean loaded = false;
    private static boolean available = false;

    /**
     * Load the native library. Tries java.library.path first,
     * then extracts from jar resources as fallback.
     */
    public static boolean loadNative() {
        if (loaded) return available;
        loaded = true;

        // Try java.library.path first (for dev environment)
        try {
            System.loadLibrary("metalrenderer");
            available = true;
            LOGGER.info("[METAL] Loaded libmetalrenderer from java.library.path");
            return true;
        } catch (UnsatisfiedLinkError e) {
            LOGGER.info("[METAL] Not on java.library.path: {}", e.getMessage());
        }

        // Extract from jar resources
        try {
            InputStream is = MetalBridge.class.getResourceAsStream("/natives/libmetalrenderer.dylib");
            if (is == null) {
                LOGGER.warn("[METAL] libmetalrenderer.dylib not found in jar resources");
                return false;
            }

            File tmpDir = new File(System.getProperty("java.io.tmpdir"), "skyfactory-metal");
            tmpDir.mkdirs();
            File tmpLib = new File(tmpDir, "libmetalrenderer.dylib");

            try (FileOutputStream fos = new FileOutputStream(tmpLib)) {
                byte[] buf = new byte[8192];
                int read;
                while ((read = is.read(buf)) != -1) {
                    fos.write(buf, 0, read);
                }
            }
            is.close();

            System.load(tmpLib.getAbsolutePath());
            available = true;
            LOGGER.info("[METAL] Loaded libmetalrenderer from extracted resource");
            return true;
        } catch (Throwable e) {
            LOGGER.warn("[METAL] Failed to load native library: {}. Metal rendering disabled.", e.getMessage());
            return false;
        }
    }

    public static boolean isAvailable() {
        return available;
    }

    // --- Phase B: Init + test rendering ---

    /** Initialize Metal device and add CAMetalLayer to the NSWindow. Also inits terrain system. */
    public static native boolean init(long nsWindowPtr);

    /** Shut down Metal renderer and clean up. */
    public static native void shutdown();

    /** Render a test frame (Phase B triangle overlay). */
    public static native void renderFrame();

    // --- Phase C: Buffer management (zero-copy via unified memory) ---

    /** Create a shared Metal buffer. Returns a handle (MTLBuffer pointer as long). */
    public static native long createBuffer(int sizeBytes);

    /** Get a direct ByteBuffer wrapping the Metal buffer's contents (zero-copy). */
    public static native ByteBuffer getBufferContents(long bufferHandle, int sizeBytes);

    /** Release a Metal buffer. */
    public static native void releaseBuffer(long bufferHandle);

    // --- Phase D: Terrain rendering ---

    /** Check if terrain rendering system is initialized. */
    public static native boolean isTerrainReady();

    /**
     * Upload chunk vertex data for a render type.
     * @param renderType 0=SOLID, 1=CUTOUT_MIPPED, 2=CUTOUT, 3=TRANSLUCENT
     * @param chunkIndex unique index for this chunk section
     * @param vertexData direct ByteBuffer with raw BLOCK-format vertices (32 bytes each)
     * @param numVertices number of vertices
     * @param offsetX camera-relative chunk X offset
     * @param offsetY camera-relative chunk Y offset
     * @param offsetZ camera-relative chunk Z offset
     */
    public static native void terrainSetChunk(int renderType, int chunkIndex,
                                               ByteBuffer vertexData, int numVertices,
                                               float offsetX, float offsetY, float offsetZ);

    /** Clear all chunk data for a render type. Call before uploading new frame's chunks. */
    public static native void terrainClearChunks(int renderType);

    /**
     * Import a GL texture as a Metal texture.
     * @param type 0 = block atlas, 1 = lightmap
     * @param width texture width
     * @param height texture height
     * @param pixelData direct ByteBuffer with RGBA8 pixel data
     * @param dataLength length of pixel data in bytes
     */
    public static native void terrainImportTexture(int type, int width, int height,
                                                    ByteBuffer pixelData, int dataLength);

    /**
     * Render terrain for one render type.
     * @param renderType 0=SOLID, 1=CUTOUT_MIPPED, 2=CUTOUT, 3=TRANSLUCENT
     * @param viewProj 16-float view-projection matrix (column-major)
     * @param fogStart fog start distance
     * @param fogEnd fog end distance
     * @param fogColor 4-float fog color (RGBA)
     * @param alphaThreshold alpha test threshold (0.0 for SOLID, 0.5 for CUTOUT_MIPPED, 0.1 for CUTOUT)
     */
    public static native void terrainRender(int renderType, float[] viewProj,
                                             float fogStart, float fogEnd,
                                             float[] fogColor, float alphaThreshold);

    // --- v0.2: Frame-level terrain rendering ---

    /**
     * Begin a terrain frame. If toScreen, renders to CAMetalLayer (visible).
     * Otherwise renders to offscreen texture (v0.1).
     */
    public static native boolean terrainBeginFrame(int width, int height, boolean toScreen);

    /** End the terrain frame. Commits command buffer and presents drawable if on-screen. */
    public static native void terrainEndFrame();

    /** Tell metal_renderer whether terrain v0.2 owns the CAMetalLayer. */
    public static native void setTerrainActive(boolean active);

    /** Get GPU render time for last terrain frame (nanoseconds). */
    public static native long terrainGetGPUTimeNanos();

    /** Get number of draw calls in last terrain frame. */
    public static native int terrainGetDrawCount();

    /** Get total vertices drawn in last terrain frame. */
    public static native int terrainGetVertexCount();

    /** Get draw count for a specific render type (0=SOLID, 1=CUTOUT_MIPPED, 2=CUTOUT, 3=TRANSLUCENT). */
    public static native int terrainGetRTDrawCount(int renderType);

    /** Get vertex count for a specific render type. */
    public static native int terrainGetRTVertexCount(int renderType);

    // --- Phase B legacy stubs (kept for MetalIntegration.java compatibility) ---

    public static native void beginFrame(float[] viewMatrix, float[] projectionMatrix,
                                          float[] chunkOffset, long textureAtlasPtr,
                                          long lightmapPtr);
    public static native void drawChunkBatch(long vertexBuffer, int[] offsets,
                                              int[] vertexCounts, int numChunks,
                                              int renderType);
    public static native void endFrame();

    // --- Diagnostics ---

    /** Get the Metal device name (e.g. "Apple M4 Max"). */
    public static native String getDeviceName();

    /** Get GPU execution time for the last frame in nanoseconds. */
    public static native long getGPUTimeNanos();
}
