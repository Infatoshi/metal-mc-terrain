#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <jni.h>
#include "metal_terrain.h"

// ============================================================
// JNI bridge: Java <-> Metal renderer
//
// JNI method naming convention:
//   Java_com_example_examplemod_metal_MetalBridge_<methodName>
// ============================================================

// Forward declarations from metal_renderer.m
extern bool metal_renderer_init(long nsWindowPtr);
extern void metal_renderer_shutdown(void);
extern void metal_renderer_render_frame(void);
extern const char* metal_renderer_get_device_name(void);
extern uint64_t metal_renderer_get_gpu_time_nanos(void);

// Access to Metal device/queue/layer from metal_renderer.m
extern id<MTLDevice> metal_renderer_get_device(void);
extern id<MTLCommandQueue> metal_renderer_get_queue(void);
extern void metal_renderer_set_terrain_active(bool active);

// Terrain system initialized flag
static bool g_terrainInited = false;

// --- Phase B: Init + test rendering ---

JNIEXPORT jboolean JNICALL
Java_com_example_examplemod_metal_MetalBridge_init(JNIEnv *env, jclass cls, jlong nsWindowPtr) {
    @autoreleasepool {
        bool result = metal_renderer_init((long)nsWindowPtr);
        if (result && !g_terrainInited) {
            id<MTLDevice> dev = metal_renderer_get_device();
            id<MTLCommandQueue> q = metal_renderer_get_queue();
            if (dev && q) {
                g_terrainInited = metal_terrain_init(dev, q);
                if (g_terrainInited) {
                    NSLog(@"[METAL-BRIDGE] Terrain system initialized");
                }
            }
        }
        return result ? JNI_TRUE : JNI_FALSE;
    }
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_shutdown(JNIEnv *env, jclass cls) {
    @autoreleasepool {
        if (g_terrainInited) {
            metal_terrain_shutdown();
            g_terrainInited = false;
        }
        metal_renderer_shutdown();
    }
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_renderFrame(JNIEnv *env, jclass cls) {
    @autoreleasepool {
        metal_renderer_render_frame();
    }
}

// --- Phase C: Buffer management (MTLBuffer shared with Java) ---

JNIEXPORT jlong JNICALL
Java_com_example_examplemod_metal_MetalBridge_createBuffer(JNIEnv *env, jclass cls, jint sizeBytes) {
    @autoreleasepool {
        id<MTLDevice> dev = metal_renderer_get_device();
        if (!dev) return 0;
        id<MTLBuffer> buf = [dev newBufferWithLength:sizeBytes
                                             options:MTLResourceStorageModeShared];
        return (jlong)(__bridge_retained void *)buf;
    }
}

JNIEXPORT jobject JNICALL
Java_com_example_examplemod_metal_MetalBridge_getBufferContents(JNIEnv *env, jclass cls,
                                                                  jlong bufferHandle, jint sizeBytes) {
    @autoreleasepool {
        id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(void *)bufferHandle;
        if (!buf) return NULL;
        return (*env)->NewDirectByteBuffer(env, [buf contents], sizeBytes);
    }
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_releaseBuffer(JNIEnv *env, jclass cls,
                                                              jlong bufferHandle) {
    @autoreleasepool {
        if (bufferHandle) {
            id<MTLBuffer> buf = (__bridge_transfer id<MTLBuffer>)(void *)bufferHandle;
            (void)buf;  // release
        }
    }
}

// --- Phase D: Terrain rendering ---

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainSetChunk(JNIEnv *env, jclass cls,
    jint renderType, jint chunkIndex, jobject vertexData, jint numVertices,
    jfloat offsetX, jfloat offsetY, jfloat offsetZ) {
    @autoreleasepool {
        if (!g_terrainInited) return;
        void *data = (*env)->GetDirectBufferAddress(env, vertexData);
        if (!data) return;
        metal_terrain_set_chunk(renderType, chunkIndex, data, numVertices,
                                offsetX, offsetY, offsetZ);
    }
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainClearChunks(JNIEnv *env, jclass cls,
    jint renderType) {
    @autoreleasepool {
        if (!g_terrainInited) return;
        metal_terrain_clear_chunks(renderType);
    }
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainImportTexture(JNIEnv *env, jclass cls,
    jint type, jint width, jint height, jobject pixelData, jint dataLength) {
    @autoreleasepool {
        if (!g_terrainInited) return;
        void *data = (*env)->GetDirectBufferAddress(env, pixelData);
        if (!data) return;
        metal_terrain_import_texture(type, width, height, data, dataLength);
    }
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainRender(JNIEnv *env, jclass cls,
    jint renderType, jfloatArray viewProjArr, jfloat fogStart, jfloat fogEnd,
    jfloatArray fogColorArr, jfloat alphaThreshold) {
    @autoreleasepool {
        if (!g_terrainInited) return;

        float viewProj[16];
        (*env)->GetFloatArrayRegion(env, viewProjArr, 0, 16, viewProj);

        float fogColor[4] = {0.7f, 0.8f, 1.0f, 1.0f};
        if (fogColorArr) {
            (*env)->GetFloatArrayRegion(env, fogColorArr, 0, 4, fogColor);
        }

        metal_terrain_render(renderType, viewProj, fogStart, fogEnd, fogColor, alphaThreshold);
    }
}

JNIEXPORT jboolean JNICALL
Java_com_example_examplemod_metal_MetalBridge_isTerrainReady(JNIEnv *env, jclass cls) {
    return g_terrainInited ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainGetGPUTimeNanos(JNIEnv *env, jclass cls) {
    return (jlong)metal_terrain_get_gpu_time_nanos();
}

JNIEXPORT jint JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainGetDrawCount(JNIEnv *env, jclass cls) {
    return (jint)metal_terrain_get_draw_count();
}

JNIEXPORT jint JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainGetVertexCount(JNIEnv *env, jclass cls) {
    return (jint)metal_terrain_get_vertex_count();
}

JNIEXPORT jint JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainGetRTDrawCount(JNIEnv *env, jclass cls,
    jint renderType) {
    return (jint)metal_terrain_get_rt_draw_count((int)renderType);
}

JNIEXPORT jint JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainGetRTVertexCount(JNIEnv *env, jclass cls,
    jint renderType) {
    return (jint)metal_terrain_get_rt_vertex_count((int)renderType);
}

// --- v0.2: Frame-level terrain rendering ---

JNIEXPORT jboolean JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainBeginFrame(JNIEnv *env, jclass cls,
    jint width, jint height, jboolean toScreen) {
    @autoreleasepool {
        if (!g_terrainInited) return JNI_FALSE;
        bool result = metal_terrain_begin_frame((int)width, (int)height, toScreen == JNI_TRUE);
        return result ? JNI_TRUE : JNI_FALSE;
    }
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_terrainEndFrame(JNIEnv *env, jclass cls) {
    @autoreleasepool {
        if (!g_terrainInited) return;
        metal_terrain_end_frame();
    }
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_setTerrainActive(JNIEnv *env, jclass cls,
    jboolean active) {
    @autoreleasepool {
        metal_renderer_set_terrain_active(active == JNI_TRUE);
    }
}

// --- Phase B stubs (existing, kept for backward compat) ---

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_beginFrame(JNIEnv *env, jclass cls,
    jfloatArray viewMatrix, jfloatArray projectionMatrix, jfloatArray chunkOffset,
    jlong textureAtlasPtr, jlong lightmapPtr) {
    // Phase B stub -- terrain rendering uses terrainRender() instead
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_drawChunkBatch(JNIEnv *env, jclass cls,
    jlong vertexBuffer, jintArray offsets, jintArray vertexCounts,
    jint numChunks, jint renderType) {
    // Phase B stub
}

JNIEXPORT void JNICALL
Java_com_example_examplemod_metal_MetalBridge_endFrame(JNIEnv *env, jclass cls) {
    // Phase B stub
}

// --- Diagnostics ---

JNIEXPORT jstring JNICALL
Java_com_example_examplemod_metal_MetalBridge_getDeviceName(JNIEnv *env, jclass cls) {
    const char *name = metal_renderer_get_device_name();
    return (*env)->NewStringUTF(env, name);
}

JNIEXPORT jlong JNICALL
Java_com_example_examplemod_metal_MetalBridge_getGPUTimeNanos(JNIEnv *env, jclass cls) {
    return (jlong)metal_renderer_get_gpu_time_nanos();
}
