// metal_terrain.h -- Phase D terrain rendering via Metal
#pragma once

#import <Metal/Metal.h>
#include <stdbool.h>
#include <stdint.h>

// Max chunk sections we track at once
#define METAL_MAX_CHUNKS 8192

// Max quads per chunk section (16384 quads * 4 verts = 65536 = fits uint16)
#define METAL_MAX_QUADS_PER_CHUNK 16384

// Render type indices (match Minecraft's order)
#define METAL_RT_SOLID          0
#define METAL_RT_CUTOUT_MIPPED  1
#define METAL_RT_CUTOUT         2
#define METAL_RT_TRANSLUCENT    3
#define METAL_RT_COUNT          4

// Per-chunk metadata
typedef struct {
    float offsetX, offsetY, offsetZ;
    float _pad0;
    uint32_t vertexOffset;   // offset into mega-buffer (in vertices)
    uint32_t vertexCount;    // number of vertices (multiple of 4, since quads)
    uint32_t _pad1[2];
} MetalChunkInfo;

// Per-frame uniforms (shared across all chunks in a render type)
typedef struct {
    float viewProj[16];      // 4x4 column-major
    float fogStart;
    float fogEnd;
    float _pad0[2];
    float fogColor[4];
    float alphaThreshold;
    float _pad1[3];
} MetalFrameUniforms;

// Initialize terrain rendering system. Requires metal_renderer_init() first.
bool metal_terrain_init(id<MTLDevice> device, id<MTLCommandQueue> queue);

// Shut down terrain system.
void metal_terrain_shutdown(void);

// Upload chunk vertex data. vertexData is raw BLOCK-format vertices (32 bytes each).
// Returns true if successful. chunkIndex is a unique identifier for this chunk+renderType.
bool metal_terrain_set_chunk(int renderType, int chunkIndex,
                              const void *vertexData, int numVertices,
                              float offsetX, float offsetY, float offsetZ);

// Clear all chunk data for a render type (e.g., when rebuilding visible set).
void metal_terrain_clear_chunks(int renderType);

// Import a GL texture as a Metal texture. pixelData is RGBA8 pixels.
// type: 0 = block atlas, 1 = lightmap
bool metal_terrain_import_texture(int type, int width, int height,
                                   const void *pixelData, int dataLength);

// Render terrain for one render type.
// viewProj: 16 floats (4x4 column-major view-projection matrix)
// alphaThreshold: 0.0 for SOLID, 0.5 for CUTOUT_MIPPED, 0.1 for CUTOUT
void metal_terrain_render(int renderType, const float *viewProj,
                           float fogStart, float fogEnd, const float *fogColor,
                           float alphaThreshold);

// --- v0.2: Frame-level API (batch all render types into one command buffer) ---

// Begin a terrain frame. If toScreen is true, renders to CAMetalLayer drawable.
// If false, renders to private offscreen textures (v0.1 behavior).
// width/height: render resolution in pixels.
// Returns true if frame started successfully.
bool metal_terrain_begin_frame(int width, int height, bool toScreen);

// End the terrain frame. Commits the command buffer. If toScreen, presents drawable.
void metal_terrain_end_frame(void);

// --- Diagnostics ---

// Get GPU render time for the last terrain frame (nanoseconds).
uint64_t metal_terrain_get_gpu_time_nanos(void);

// Get number of draw calls issued in last frame.
int metal_terrain_get_draw_count(void);

// Get total vertices drawn in last frame.
int metal_terrain_get_vertex_count(void);

// Per-render-type stats (0=SOLID, 1=CUTOUT_MIPPED, 2=CUTOUT, 3=TRANSLUCENT)
int metal_terrain_get_rt_draw_count(int renderType);
int metal_terrain_get_rt_vertex_count(int renderType);
