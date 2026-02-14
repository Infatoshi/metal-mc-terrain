// metal_terrain.m -- Phase D: Metal terrain chunk rendering
//
// Replaces ~10k GL draw calls per frame with batched Metal draws.
// Chunk vertex data is uploaded to a shared mega-buffer. Each chunk section
// is drawn with its own offset (camera-relative chunk position).
// Quads (GL_QUADS) are converted to triangles via a shared index buffer.

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Cocoa/Cocoa.h>
#import <simd/simd.h>
#include "metal_terrain.h"

// ============================================================
// State
// ============================================================

static id<MTLDevice> t_device = nil;
static id<MTLCommandQueue> t_queue = nil;

// Pipeline (per-chunk draws -- legacy fallback)
static id<MTLRenderPipelineState> t_solidPipeline = nil;
static id<MTLRenderPipelineState> t_cutoutPipeline = nil;
static id<MTLRenderPipelineState> t_translucentPipeline = nil;

// Pipeline (instanced draws -- 2.84x faster, legacy)
static id<MTLRenderPipelineState> t_solidPipelineInst = nil;
static id<MTLRenderPipelineState> t_cutoutPipelineInst = nil;
static id<MTLRenderPipelineState> t_translucentPipelineInst = nil;

// Pipeline (tight-packed draws -- 3x faster than instanced, 9x faster than per-chunk)
static id<MTLRenderPipelineState> t_solidPipelineTight = nil;
static id<MTLRenderPipelineState> t_cutoutPipelineTight = nil;
static id<MTLRenderPipelineState> t_translucentPipelineTight = nil;

static id<MTLDepthStencilState> t_depthState = nil;
static id<MTLDepthStencilState> t_depthStateReadOnly = nil;  // for translucent

// Quad-to-triangle index buffer
static id<MTLBuffer> t_quadIndexBuffer = nil;
static int t_maxQuadIndices = 0;

// Textures
static id<MTLTexture> t_blockAtlas = nil;
static id<MTLTexture> t_lightmap = nil;
static id<MTLSamplerState> t_atlasSampler = nil;
static id<MTLSamplerState> t_lightmapSampler = nil;

// Per render type: slot-based mega-buffer + offset buffer for instanced rendering
// Each chunk gets a fixed-size slot (maxVerticesThisFrame * 32 bytes).
// Zero-padded slots produce degenerate triangles (zero area, culled by rasterizer).
typedef struct {
    // Staging area: vertex data packed contiguously during set_chunk
    id<MTLBuffer> stagingBuffer;
    uint32_t stagingCapacity;    // in bytes
    uint32_t stagingUsed;        // in bytes

    // Per-chunk metadata (for repacking into slots)
    MetalChunkInfo chunks[METAL_MAX_CHUNKS];
    int numChunks;
    uint32_t maxVertexCount;     // max vertex count across all chunks this frame

    // Instanced draw buffers (legacy, kept for fallback)
    id<MTLBuffer> slotBuffer;
    uint32_t slotBufferCapacity;
    id<MTLBuffer> offsetBuffer;    // ChunkOffset array (shared by instanced & tight)
    uint32_t offsetBufferCapacity;

    // Tight-packed draw buffers (primary path -- 9x faster than per-chunk)
    id<MTLBuffer> globalIndexBuffer;   // uint32 index buffer mapping all chunks
    uint32_t globalIndexCapacity;      // capacity in bytes
    uint32_t globalIndexCount;         // number of uint32 indices this frame
} RenderTypeState;

static RenderTypeState t_rtState[METAL_RT_COUNT];

// Render target (offscreen for v0.1, depth-only for v0.2)
static id<MTLTexture> t_colorTarget = nil;
static id<MTLTexture> t_depthTarget = nil;
static int t_targetWidth = 0;
static int t_targetHeight = 0;

// v0.2: Frame-level state for batched rendering
static id<CAMetalDrawable> t_frameDrawable = nil;
static id<MTLCommandBuffer> t_frameCmdBuf = nil;
static id<MTLRenderCommandEncoder> t_frameEncoder = nil;
static bool t_frameActive = false;
static bool t_frameToScreen = false;

// Stats (totals)
static uint64_t t_lastGPUTimeNanos = 0;
static int t_lastDrawCount = 0;
static int t_lastVertexCount = 0;

// Per-render-type stats
typedef struct {
    int drawCount;
    int vertexCount;
    int chunkCount;
} RenderTypeStats;
static RenderTypeStats t_rtStats[METAL_RT_COUNT];

// Shader library
static id<MTLLibrary> t_library = nil;

// ============================================================
// External: CAMetalLayer accessor from metal_renderer.m
// ============================================================
extern CAMetalLayer* metal_renderer_get_layer(void);
extern NSView* metal_renderer_get_view(void);

// ============================================================
// Forward declarations
// ============================================================

static bool terrain_compile_shaders(void);
static bool terrain_create_pipelines(void);
static bool terrain_create_quad_index_buffer(int maxQuads);
static bool terrain_create_samplers(void);
static void terrain_ensure_render_targets(int width, int height);

// ============================================================
// Init / Shutdown
// ============================================================

bool metal_terrain_init(id<MTLDevice> device, id<MTLCommandQueue> queue) {
    t_device = device;
    t_queue = queue;

    // Compile shaders
    if (!terrain_compile_shaders()) {
        NSLog(@"[METAL-TERRAIN] Shader compilation failed");
        return false;
    }

    // Create pipelines
    if (!terrain_create_pipelines()) {
        NSLog(@"[METAL-TERRAIN] Pipeline creation failed");
        return false;
    }

    // Create quad index buffer (support up to 16384 quads per chunk)
    if (!terrain_create_quad_index_buffer(METAL_MAX_QUADS_PER_CHUNK)) {
        NSLog(@"[METAL-TERRAIN] Index buffer creation failed");
        return false;
    }

    // Create samplers
    if (!terrain_create_samplers()) {
        NSLog(@"[METAL-TERRAIN] Sampler creation failed");
        return false;
    }

    // Init render type states
    for (int i = 0; i < METAL_RT_COUNT; i++) {
        t_rtState[i].stagingBuffer = nil;
        t_rtState[i].stagingCapacity = 0;
        t_rtState[i].stagingUsed = 0;
        t_rtState[i].numChunks = 0;
        t_rtState[i].maxVertexCount = 0;
        t_rtState[i].slotBuffer = nil;
        t_rtState[i].slotBufferCapacity = 0;
        t_rtState[i].offsetBuffer = nil;
        t_rtState[i].offsetBufferCapacity = 0;
        t_rtState[i].globalIndexBuffer = nil;
        t_rtState[i].globalIndexCapacity = 0;
        t_rtState[i].globalIndexCount = 0;
    }

    NSLog(@"[METAL-TERRAIN] Terrain renderer initialized");
    return true;
}

void metal_terrain_shutdown(void) {
    for (int i = 0; i < METAL_RT_COUNT; i++) {
        t_rtState[i].stagingBuffer = nil;
        t_rtState[i].slotBuffer = nil;
        t_rtState[i].offsetBuffer = nil;
        t_rtState[i].globalIndexBuffer = nil;
        t_rtState[i].numChunks = 0;
    }
    t_quadIndexBuffer = nil;
    t_colorTarget = nil;
    t_depthTarget = nil;
    t_solidPipeline = nil;
    t_cutoutPipeline = nil;
    t_translucentPipeline = nil;
    t_solidPipelineInst = nil;
    t_cutoutPipelineInst = nil;
    t_translucentPipelineInst = nil;
    t_solidPipelineTight = nil;
    t_cutoutPipelineTight = nil;
    t_translucentPipelineTight = nil;
    t_depthState = nil;
    t_depthStateReadOnly = nil;
    t_blockAtlas = nil;
    t_lightmap = nil;
    t_atlasSampler = nil;
    t_lightmapSampler = nil;
    t_library = nil;
    t_device = nil;
    t_queue = nil;
    NSLog(@"[METAL-TERRAIN] Terrain renderer shut down");
}

// ============================================================
// Shader compilation
// ============================================================

static bool terrain_compile_shaders(void) {
    NSError *error = nil;

    // Terrain shaders embedded as string for portability
    NSString *src = @
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "\n"
        "struct BlockVertex {\n"
        "    float3 position  [[attribute(0)]];\n"
        "    uchar4 color     [[attribute(1)]];\n"
        "    float2 uv0       [[attribute(2)]];\n"
        "    short2 uv2       [[attribute(3)]];\n"
        "    uchar4 normal    [[attribute(4)]];\n"
        "};\n"
        "\n"
        "struct ChunkOffset {\n"
        "    packed_float3 offset;\n"
        "    float _pad;\n"
        "};\n"
        "\n"
        "struct FrameUniforms {\n"
        "    float4x4 viewProj;\n"
        "    float fogStart;\n"
        "    float fogEnd;\n"
        "    float2 _pad0;\n"
        "    float4 fogColor;\n"
        "    float alphaThreshold;\n"
        "    float _pad1[3];\n"
        "};\n"
        "\n"
        "struct TerrainOut {\n"
        "    float4 position [[position]];\n"
        "    float4 color;\n"
        "    float2 uv0;\n"
        "    float2 uv2;\n"
        "    float3 normal;\n"
        "    float fogFactor;\n"
        "};\n"
        "\n"
        "vertex TerrainOut terrain_vertex_batched(\n"
        "    BlockVertex in [[stage_in]],\n"
        "    constant ChunkOffset& chunk [[buffer(1)]],\n"
        "    constant FrameUniforms& frame [[buffer(2)]]\n"
        ") {\n"
        "    TerrainOut out;\n"
        "    float3 worldPos = in.position + float3(chunk.offset);\n"
        "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
        "    out.color = float4(in.color) / 255.0;\n"
        "    out.uv0 = in.uv0;\n"
        "    out.uv2 = float2(in.uv2) / 256.0;\n"
        "    out.normal = float3(float3(in.normal.xyz)) / 127.0;\n"
        "    float dist = length(worldPos);\n"
        "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
        "    return out;\n"
        "}\n"
        "\n"
        "fragment float4 terrain_fragment_batched(\n"
        "    TerrainOut in [[stage_in]],\n"
        "    texture2d<float> blockAtlas [[texture(0)]],\n"
        "    texture2d<float> lightmap [[texture(1)]],\n"
        "    sampler atlasSampler [[sampler(0)]],\n"
        "    sampler lightmapSampler [[sampler(1)]],\n"
        "    constant FrameUniforms& frame [[buffer(2)]]\n"
        ") {\n"
        "    float4 texColor = blockAtlas.sample(atlasSampler, in.uv0);\n"
        "    if (texColor.a < frame.alphaThreshold) { discard_fragment(); }\n"
        "    float4 light = lightmap.sample(lightmapSampler, in.uv2);\n"
        "    float4 color = texColor * light * in.color;\n"
        "    color.rgb = mix(frame.fogColor.rgb, color.rgb, in.fogFactor);\n"
        "    // Force alpha=1.0 for CAMetalLayer compositing (opaque=NO means alpha matters).\n"
        "    // Without this, nil textures produce alpha=0 -> invisible on transparent layer.\n"
        "    color.a = 1.0;\n"
        "    return color;\n"
        "}\n"
        "\n"
        "// Instanced variant: each instance reads from its slot in the mega-buffer.\n"
        "// Slot layout: vertex[instance_id * slotSize + vertex_id]\n"
        "// slotSize is passed as chunks[0]._pad (repurposed) -- NO, use buffer offset.\n"
        "// Actually: we use stage_in which reads vertex_id within the index buffer.\n"
        "// With slot-based layout, instance N's vertices start at N * slotSize.\n"
        "// We achieve this by using vertex buffer offset per instance via stepFunction.\n"
        "// Simpler approach: manual buffer indexing with vertex_id + instance_id.\n"
        "\n"
        "struct BlockVertexRaw {\n"
        "    packed_float3 position;\n"
        "    uchar4 color;\n"
        "    packed_float2 uv0;\n"
        "    packed_short2 uv2;\n"
        "    uchar4 normal;\n"
        "};\n"
        "\n"
        "struct InstUniforms {\n"
        "    uint slotSize;\n"   // vertices per slot
        "};\n"
        "\n"
        "vertex TerrainOut terrain_vertex_instanced(\n"
        "    constant BlockVertexRaw* vertices [[buffer(0)]],\n"
        "    constant ChunkOffset* chunks [[buffer(1)]],\n"
        "    constant FrameUniforms& frame [[buffer(2)]],\n"
        "    constant InstUniforms& inst [[buffer(3)]],\n"
        "    uint vid [[vertex_id]],\n"
        "    uint iid [[instance_id]]\n"
        ") {\n"
        "    uint idx = iid * inst.slotSize + vid;\n"
        "    constant BlockVertexRaw& v = vertices[idx];\n"
        "    TerrainOut out;\n"
        "    float3 worldPos = float3(v.position) + float3(chunks[iid].offset);\n"
        "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
        "    out.color = float4(v.color) / 255.0;\n"
        "    out.uv0 = float2(v.uv0);\n"
        "    out.uv2 = float2(v.uv2) / 256.0;\n"
        "    out.normal = float3(float3(v.normal.xyz)) / 127.0;\n"
        "    float dist = length(worldPos);\n"
        "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
        "    return out;\n"
        "}\n"
        "\n"
        "// Tight-packed variant: chunkId embedded in vertex, no instancing.\n"
        "// Benchmark-proven 3x faster than slot-based instancing (eliminates padding waste).\n"
        "// Uses staging buffer directly -- no slot repacking needed.\n"
        "struct BlockVertexTight {\n"
        "    packed_float3 position;\n"
        "    uchar4 color;\n"
        "    packed_float2 uv0;\n"
        "    packed_short2 uv2;\n"
        "    ushort chunkId;\n"
        "    ushort _pad;\n"
        "};\n"
        "\n"
        "vertex TerrainOut terrain_vertex_tight(\n"
        "    constant BlockVertexTight* vertices [[buffer(0)]],\n"
        "    constant ChunkOffset* chunks [[buffer(1)]],\n"
        "    constant FrameUniforms& frame [[buffer(2)]],\n"
        "    uint vid [[vertex_id]]\n"
        ") {\n"
        "    constant BlockVertexTight& v = vertices[vid];\n"
        "    TerrainOut out;\n"
        "    float3 worldPos = float3(v.position) + float3(chunks[v.chunkId].offset);\n"
        "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
        "    out.color = float4(v.color) / 255.0;\n"
        "    out.uv0 = float2(v.uv0);\n"
        "    out.uv2 = float2(v.uv2) / 256.0;\n"
        "    out.normal = float3(0, 1, 0);\n"
        "    float dist = length(worldPos);\n"
        "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
        "    return out;\n"
        "}\n";

    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.languageVersion = MTLLanguageVersion2_4;

    t_library = [t_device newLibraryWithSource:src options:opts error:&error];
    if (!t_library) {
        NSLog(@"[METAL-TERRAIN] Shader compilation error: %@", error);
        return false;
    }

    NSLog(@"[METAL-TERRAIN] Shaders compiled");
    return true;
}

// ============================================================
// Pipeline creation
// ============================================================

static MTLVertexDescriptor* terrain_vertex_descriptor(void) {
    MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];

    // Attribute 0: position (float3, offset 0)
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;

    // Attribute 1: color (uchar4, offset 12)
    vd.attributes[1].format = MTLVertexFormatUChar4;
    vd.attributes[1].offset = 12;
    vd.attributes[1].bufferIndex = 0;

    // Attribute 2: uv0 (float2, offset 16)
    vd.attributes[2].format = MTLVertexFormatFloat2;
    vd.attributes[2].offset = 16;
    vd.attributes[2].bufferIndex = 0;

    // Attribute 3: uv2/lightmap (short2, offset 24)
    vd.attributes[3].format = MTLVertexFormatShort2;
    vd.attributes[3].offset = 24;
    vd.attributes[3].bufferIndex = 0;

    // Attribute 4: normal+padding (uchar4, offset 28)
    vd.attributes[4].format = MTLVertexFormatUChar4;
    vd.attributes[4].offset = 28;
    vd.attributes[4].bufferIndex = 0;

    // Layout: 32 bytes per vertex
    vd.layouts[0].stride = 32;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    return vd;
}

static bool terrain_create_pipelines(void) {
    NSError *error = nil;

    id<MTLFunction> vertFunc = [t_library newFunctionWithName:@"terrain_vertex_batched"];
    id<MTLFunction> vertFuncInst = [t_library newFunctionWithName:@"terrain_vertex_instanced"];
    id<MTLFunction> vertFuncTight = [t_library newFunctionWithName:@"terrain_vertex_tight"];
    id<MTLFunction> fragFunc = [t_library newFunctionWithName:@"terrain_fragment_batched"];
    if (!vertFunc || !vertFuncInst || !vertFuncTight || !fragFunc) {
        NSLog(@"[METAL-TERRAIN] Could not find terrain shader functions");
        return false;
    }

    MTLVertexDescriptor *vd = terrain_vertex_descriptor();

    // Solid pipeline (no blending, no alpha test -- alphaThreshold = 0.0)
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFunc;
        pd.fragmentFunction = fragFunc;
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = NO;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_solidPipeline = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_solidPipeline) {
            NSLog(@"[METAL-TERRAIN] Solid pipeline error: %@", error);
            return false;
        }
    }

    // Cutout pipeline (alpha test, no blending -- alphaThreshold > 0)
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFunc;
        pd.fragmentFunction = fragFunc;
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = NO;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_cutoutPipeline = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_cutoutPipeline) {
            NSLog(@"[METAL-TERRAIN] Cutout pipeline error: %@", error);
            return false;
        }
    }

    // Translucent pipeline (alpha blending)
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFunc;
        pd.fragmentFunction = fragFunc;
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_translucentPipeline = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_translucentPipeline) {
            NSLog(@"[METAL-TERRAIN] Translucent pipeline error: %@", error);
            return false;
        }
    }

    // Instanced pipelines (manual buffer indexing -- no vertex descriptor)
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFuncInst;
        pd.fragmentFunction = fragFunc;
        // No vertexDescriptor: instanced shader reads from raw buffer via vertex_id/instance_id
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = NO;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_solidPipelineInst = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_solidPipelineInst) {
            NSLog(@"[METAL-TERRAIN] Solid instanced pipeline error: %@", error);
            return false;
        }
    }
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFuncInst;
        pd.fragmentFunction = fragFunc;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = NO;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_cutoutPipelineInst = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_cutoutPipelineInst) {
            NSLog(@"[METAL-TERRAIN] Cutout instanced pipeline error: %@", error);
            return false;
        }
    }
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFuncInst;
        pd.fragmentFunction = fragFunc;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_translucentPipelineInst = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_translucentPipelineInst) {
            NSLog(@"[METAL-TERRAIN] Translucent instanced pipeline error: %@", error);
            return false;
        }
    }

    // Tight-packed pipelines (manual buffer indexing, no instancing, no vertex descriptor)
    // Benchmark: 3x faster than instanced, 9x faster than per-chunk
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFuncTight;
        pd.fragmentFunction = fragFunc;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = NO;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_solidPipelineTight = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_solidPipelineTight) {
            NSLog(@"[METAL-TERRAIN] Solid tight pipeline error: %@", error);
            return false;
        }
    }
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFuncTight;
        pd.fragmentFunction = fragFunc;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = NO;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_cutoutPipelineTight = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_cutoutPipelineTight) {
            NSLog(@"[METAL-TERRAIN] Cutout tight pipeline error: %@", error);
            return false;
        }
    }
    {
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vertFuncTight;
        pd.fragmentFunction = fragFunc;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        t_translucentPipelineTight = [t_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!t_translucentPipelineTight) {
            NSLog(@"[METAL-TERRAIN] Translucent tight pipeline error: %@", error);
            return false;
        }
    }

    // Depth stencil states
    {
        MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
        dd.depthCompareFunction = MTLCompareFunctionLess;
        dd.depthWriteEnabled = YES;
        t_depthState = [t_device newDepthStencilStateWithDescriptor:dd];

        dd.depthWriteEnabled = NO;  // translucent doesn't write depth
        t_depthStateReadOnly = [t_device newDepthStencilStateWithDescriptor:dd];
    }

    NSLog(@"[METAL-TERRAIN] Pipelines created (per-chunk + instanced + tight)");
    return true;
}

// ============================================================
// Quad-to-triangle index buffer
// ============================================================

static bool terrain_create_quad_index_buffer(int maxQuads) {
    int numIndices = maxQuads * 6;
    uint16_t *indices = (uint16_t *)malloc(numIndices * sizeof(uint16_t));
    if (!indices) return false;

    for (int q = 0; q < maxQuads; q++) {
        // Quad vertices: 0,1,2,3 -> triangles: (0,1,2), (0,2,3)
        indices[q * 6 + 0] = (uint16_t)(q * 4 + 0);
        indices[q * 6 + 1] = (uint16_t)(q * 4 + 1);
        indices[q * 6 + 2] = (uint16_t)(q * 4 + 2);
        indices[q * 6 + 3] = (uint16_t)(q * 4 + 0);
        indices[q * 6 + 4] = (uint16_t)(q * 4 + 2);
        indices[q * 6 + 5] = (uint16_t)(q * 4 + 3);
    }

    t_quadIndexBuffer = [t_device newBufferWithBytes:indices
                                              length:numIndices * sizeof(uint16_t)
                                             options:MTLResourceStorageModeShared];
    t_maxQuadIndices = numIndices;
    free(indices);

    if (!t_quadIndexBuffer) {
        NSLog(@"[METAL-TERRAIN] Failed to create index buffer");
        return false;
    }

    NSLog(@"[METAL-TERRAIN] Quad index buffer created (%d quads, %d indices)",
          maxQuads, numIndices);
    return true;
}

// ============================================================
// Samplers
// ============================================================

static bool terrain_create_samplers(void) {
    // Block atlas: nearest-neighbor with mipmap (for cutout_mipped)
    {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterNearest;
        sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.mipFilter = MTLSamplerMipFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeRepeat;
        sd.tAddressMode = MTLSamplerAddressModeRepeat;
        sd.maxAnisotropy = 1;
        t_atlasSampler = [t_device newSamplerStateWithDescriptor:sd];
    }

    // Lightmap: linear filtering, clamp
    {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        t_lightmapSampler = [t_device newSamplerStateWithDescriptor:sd];
    }

    return t_atlasSampler && t_lightmapSampler;
}

// ============================================================
// Render targets
// ============================================================

static void terrain_ensure_render_targets(int width, int height) {
    if (t_targetWidth == width && t_targetHeight == height &&
        t_colorTarget && t_depthTarget) {
        return;
    }

    // Color target (BGRA8, shared for IOSurface compatibility)
    {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        t_colorTarget = [t_device newTextureWithDescriptor:td];
    }

    // Depth target
    {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
            width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        t_depthTarget = [t_device newTextureWithDescriptor:td];
    }

    t_targetWidth = width;
    t_targetHeight = height;

    NSLog(@"[METAL-TERRAIN] Render targets created: %dx%d", width, height);
}

// ============================================================
// Chunk data management
// ============================================================

static void terrain_ensure_staging(int renderType, uint32_t requiredBytes) {
    RenderTypeState *rts = &t_rtState[renderType];

    if (rts->stagingBuffer && rts->stagingCapacity >= requiredBytes) {
        return;
    }

    // Grow to at least 32MB, or 2x required
    uint32_t newCap = requiredBytes * 2;
    if (newCap < 32 * 1024 * 1024) newCap = 32 * 1024 * 1024;

    rts->stagingBuffer = [t_device newBufferWithLength:newCap
                                               options:MTLResourceStorageModeShared];
    rts->stagingCapacity = newCap;
}

bool metal_terrain_set_chunk(int renderType, int chunkIndex,
                              const void *vertexData, int numVertices,
                              float offsetX, float offsetY, float offsetZ) {
    if (renderType < 0 || renderType >= METAL_RT_COUNT) return false;

    RenderTypeState *rts = &t_rtState[renderType];

    if (rts->numChunks >= METAL_MAX_CHUNKS) {
        return false;
    }

    uint32_t dataSize = numVertices * 32;  // 32 bytes per vertex
    uint32_t requiredTotal = rts->stagingUsed + dataSize;
    terrain_ensure_staging(renderType, requiredTotal);

    // Copy vertex data into staging buffer (contiguous)
    uint8_t *dst = (uint8_t *)[rts->stagingBuffer contents] + rts->stagingUsed;
    memcpy(dst, vertexData, dataSize);

    // Stamp chunkId into bytes 28-29 of each vertex (replaces normal.xy).
    // The tight-packed shader reads this to look up chunk offset.
    uint16_t chunkIdVal = (uint16_t)rts->numChunks;
    for (int v = 0; v < numVertices; v++) {
        memcpy(dst + v * 32 + 28, &chunkIdVal, 2);
        dst[v * 32 + 30] = 0;
        dst[v * 32 + 31] = 0;
    }

    // Record chunk info
    int idx = rts->numChunks;
    rts->chunks[idx].offsetX = offsetX;
    rts->chunks[idx].offsetY = offsetY;
    rts->chunks[idx].offsetZ = offsetZ;
    rts->chunks[idx].vertexOffset = rts->stagingUsed / 32;  // staging offset in vertices
    rts->chunks[idx].vertexCount = numVertices;
    rts->numChunks++;

    rts->stagingUsed += dataSize;

    // Track max vertex count for instanced slot sizing
    if ((uint32_t)numVertices > rts->maxVertexCount) {
        rts->maxVertexCount = numVertices;
    }

    return true;
}

void metal_terrain_clear_chunks(int renderType) {
    if (renderType < 0 || renderType >= METAL_RT_COUNT) return;
    t_rtState[renderType].numChunks = 0;
    t_rtState[renderType].stagingUsed = 0;
    t_rtState[renderType].maxVertexCount = 0;
    t_rtState[renderType].globalIndexCount = 0;
}

// Build slot-based buffer and offset buffer from staging data for instanced rendering
static void terrain_build_instanced_buffers(int renderType) {
    RenderTypeState *rts = &t_rtState[renderType];
    if (rts->numChunks == 0 || rts->maxVertexCount == 0) return;

    uint32_t slotSize = rts->maxVertexCount;  // vertices per slot
    uint32_t slotBytes = slotSize * 32;
    uint32_t totalSlotBytes = (uint32_t)rts->numChunks * slotBytes;

    // Ensure slot buffer capacity
    if (!rts->slotBuffer || rts->slotBufferCapacity < totalSlotBytes) {
        uint32_t newCap = totalSlotBytes * 2;
        if (newCap < 64 * 1024 * 1024) newCap = 64 * 1024 * 1024;
        rts->slotBuffer = [t_device newBufferWithLength:newCap
                                                options:MTLResourceStorageModeShared];
        rts->slotBufferCapacity = newCap;
    }

    // Ensure offset buffer capacity
    uint32_t offsetBytes = (uint32_t)rts->numChunks * 16;  // ChunkOffset = 16 bytes
    if (!rts->offsetBuffer || rts->offsetBufferCapacity < offsetBytes) {
        uint32_t newCap = offsetBytes * 2;
        if (newCap < 128 * 1024) newCap = 128 * 1024;
        rts->offsetBuffer = [t_device newBufferWithLength:newCap
                                                   options:MTLResourceStorageModeShared];
        rts->offsetBufferCapacity = newCap;
    }

    // Pack vertex data into slots (zero-padded)
    uint8_t *slotDst = (uint8_t *)[rts->slotBuffer contents];
    uint8_t *stagingSrc = (uint8_t *)[rts->stagingBuffer contents];
    memset(slotDst, 0, totalSlotBytes);  // zero-fill for degenerate padding

    // Build offset buffer
    float *offsetDst = (float *)[rts->offsetBuffer contents];

    for (int i = 0; i < rts->numChunks; i++) {
        MetalChunkInfo *ci = &rts->chunks[i];

        // Copy this chunk's vertex data into its slot
        uint32_t srcOffset = ci->vertexOffset * 32;
        uint32_t dstOffset = (uint32_t)i * slotBytes;
        memcpy(slotDst + dstOffset, stagingSrc + srcOffset, ci->vertexCount * 32);

        // Write chunk offset (ChunkOffset struct = float3 + pad)
        offsetDst[i * 4 + 0] = ci->offsetX;
        offsetDst[i * 4 + 1] = ci->offsetY;
        offsetDst[i * 4 + 2] = ci->offsetZ;
        offsetDst[i * 4 + 3] = 0.0f;
    }
}

// Build offset buffer and global uint32 index buffer for tight-packed rendering.
// Uses staging buffer directly (already packed contiguously) -- no slot repacking.
static void terrain_build_tight_buffers(int renderType) {
    RenderTypeState *rts = &t_rtState[renderType];
    if (rts->numChunks == 0) return;

    // Ensure offset buffer capacity
    uint32_t offsetBytes = (uint32_t)rts->numChunks * 16;
    if (!rts->offsetBuffer || rts->offsetBufferCapacity < offsetBytes) {
        uint32_t newCap = offsetBytes * 2;
        if (newCap < 128 * 1024) newCap = 128 * 1024;
        rts->offsetBuffer = [t_device newBufferWithLength:newCap
                                                   options:MTLResourceStorageModeShared];
        rts->offsetBufferCapacity = newCap;
    }

    // Build offset buffer
    float *offsetDst = (float *)[rts->offsetBuffer contents];
    for (int i = 0; i < rts->numChunks; i++) {
        MetalChunkInfo *ci = &rts->chunks[i];
        offsetDst[i * 4 + 0] = ci->offsetX;
        offsetDst[i * 4 + 1] = ci->offsetY;
        offsetDst[i * 4 + 2] = ci->offsetZ;
        offsetDst[i * 4 + 3] = 0.0f;
    }

    // Calculate total triangle indices
    uint32_t totalIdx = 0;
    for (int i = 0; i < rts->numChunks; i++) {
        totalIdx += (rts->chunks[i].vertexCount / 4) * 6;
    }

    // Ensure global index buffer capacity
    uint32_t idxBytes = totalIdx * sizeof(uint32_t);
    if (!rts->globalIndexBuffer || rts->globalIndexCapacity < idxBytes) {
        uint32_t newCap = idxBytes * 2;
        if (newCap < 4 * 1024 * 1024) newCap = 4 * 1024 * 1024;
        rts->globalIndexBuffer = [t_device newBufferWithLength:newCap
                                                        options:MTLResourceStorageModeShared];
        rts->globalIndexCapacity = newCap;
    }

    // Build global index buffer (maps directly into staging buffer positions)
    uint32_t *idx = (uint32_t *)[rts->globalIndexBuffer contents];
    uint32_t idxPos = 0;
    for (int i = 0; i < rts->numChunks; i++) {
        uint32_t base = rts->chunks[i].vertexOffset;
        int nq = rts->chunks[i].vertexCount / 4;
        for (int q = 0; q < nq; q++) {
            uint32_t b = base + q * 4;
            idx[idxPos++] = b;     idx[idxPos++] = b + 1;
            idx[idxPos++] = b + 2; idx[idxPos++] = b;
            idx[idxPos++] = b + 2; idx[idxPos++] = b + 3;
        }
    }
    rts->globalIndexCount = totalIdx;
}

// ============================================================
// Texture import
// ============================================================

bool metal_terrain_import_texture(int type, int width, int height,
                                   const void *pixelData, int dataLength) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;

    id<MTLTexture> tex = [t_device newTextureWithDescriptor:td];
    if (!tex) {
        NSLog(@"[METAL-TERRAIN] Failed to create texture (type=%d, %dx%d)", type, width, height);
        return false;
    }

    [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
           mipmapLevel:0
             withBytes:pixelData
           bytesPerRow:width * 4];

    if (type == 0) {
        t_blockAtlas = tex;
        NSLog(@"[METAL-TERRAIN] Block atlas imported: %dx%d", width, height);
    } else if (type == 1) {
        t_lightmap = tex;
        NSLog(@"[METAL-TERRAIN] Lightmap imported: %dx%d", width, height);
    }

    return true;
}

// ============================================================
// v0.2: Frame-level begin/end API
// ============================================================

bool metal_terrain_begin_frame(int width, int height, bool toScreen) {
    @autoreleasepool {
        if (!t_device || !t_queue) return false;
        if (t_frameActive) return false;

        t_frameToScreen = toScreen;
        id<MTLTexture> colorTarget;
        id<MTLTexture> depthTarget;

        if (toScreen) {
            CAMetalLayer *layer = metal_renderer_get_layer();
            if (!layer) {
                NSLog(@"[METAL-TERRAIN] begin_frame: no CAMetalLayer");
                return false;
            }

            // Update layer size to match requested resolution
            NSView *view = metal_renderer_get_view();
            if (view) {
                CGFloat scale = view.window.backingScaleFactor;
                layer.contentsScale = scale;
                layer.drawableSize = CGSizeMake(width, height);
            }

            t_frameDrawable = [layer nextDrawable];
            if (!t_frameDrawable) {
                NSLog(@"[METAL-TERRAIN] begin_frame: no drawable");
                return false;
            }

            colorTarget = t_frameDrawable.texture;

            // Ensure depth target matches drawable size
            terrain_ensure_render_targets(width, height);
            depthTarget = t_depthTarget;
        } else {
            // Offscreen mode (v0.1)
            terrain_ensure_render_targets(width, height);
            colorTarget = t_colorTarget;
            depthTarget = t_depthTarget;
        }

        // Create command buffer
        t_frameCmdBuf = [t_queue commandBuffer];
        t_frameCmdBuf.label = @"Terrain Frame";

        // Create render pass with clear
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = colorTarget;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        rpd.depthAttachment.texture = depthTarget;
        rpd.depthAttachment.loadAction = MTLLoadActionClear;
        rpd.depthAttachment.clearDepth = 1.0;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;

        t_frameEncoder = [t_frameCmdBuf renderCommandEncoderWithDescriptor:rpd];
        t_frameEncoder.label = @"Terrain Frame";
        t_frameActive = true;

        // Reset per-frame stats
        t_lastDrawCount = 0;
        t_lastVertexCount = 0;
        for (int i = 0; i < METAL_RT_COUNT; i++) {
            t_rtStats[i].drawCount = 0;
            t_rtStats[i].vertexCount = 0;
            t_rtStats[i].chunkCount = 0;
        }

        return true;
    }
}

void metal_terrain_end_frame(void) {
    @autoreleasepool {
        if (!t_frameActive) return;

        [t_frameEncoder endEncoding];
        t_frameEncoder = nil;

        if (t_frameToScreen && t_frameDrawable) {
            [t_frameCmdBuf presentDrawable:t_frameDrawable];
        }

        [t_frameCmdBuf addCompletedHandler:^(id<MTLCommandBuffer> buf) {
            if (buf.GPUStartTime > 0 && buf.GPUEndTime > 0) {
                t_lastGPUTimeNanos = (uint64_t)((buf.GPUEndTime - buf.GPUStartTime) * 1e9);
            }
        }];

        [t_frameCmdBuf commit];

        t_frameDrawable = nil;
        t_frameCmdBuf = nil;
        t_frameActive = false;
    }
}

// ============================================================
// Terrain rendering -- tight-packed (1 draw per render type, no instancing)
// Benchmark-proven 3x faster than instanced, 9x faster than per-chunk draws.
// Uses staging buffer directly with global uint32 index buffer.
// ============================================================

void metal_terrain_render(int renderType, const float *viewProj,
                           float fogStart, float fogEnd, const float *fogColor,
                           float alphaThreshold) {
    @autoreleasepool {
        if (!t_device || !t_queue) return;

        RenderTypeState *rts = &t_rtState[renderType];
        if (rts->numChunks == 0) return;
        if (!rts->stagingBuffer) return;

        // Build tight-packed offset + index buffers
        terrain_build_tight_buffers(renderType);
        if (!rts->offsetBuffer || !rts->globalIndexBuffer || rts->globalIndexCount == 0) return;

        // Choose tight pipeline
        id<MTLRenderPipelineState> pipeline;
        id<MTLDepthStencilState> depthState;
        if (renderType == METAL_RT_TRANSLUCENT) {
            pipeline = t_translucentPipelineTight;
            depthState = t_depthStateReadOnly;
        } else if (alphaThreshold > 0.0f) {
            pipeline = t_cutoutPipelineTight;
            depthState = t_depthState;
        } else {
            pipeline = t_solidPipelineTight;
            depthState = t_depthState;
        }

        if (!pipeline) return;

        // Build frame uniforms
        MetalFrameUniforms uniforms;
        memcpy(uniforms.viewProj, viewProj, 16 * sizeof(float));
        uniforms.fogStart = fogStart;
        uniforms.fogEnd = fogEnd;
        uniforms._pad0[0] = 0; uniforms._pad0[1] = 0;
        if (fogColor) {
            memcpy(uniforms.fogColor, fogColor, 4 * sizeof(float));
        } else {
            uniforms.fogColor[0] = 0.7f;
            uniforms.fogColor[1] = 0.8f;
            uniforms.fogColor[2] = 1.0f;
            uniforms.fogColor[3] = 1.0f;
        }
        uniforms.alphaThreshold = alphaThreshold;
        uniforms._pad1[0] = 0; uniforms._pad1[1] = 0; uniforms._pad1[2] = 0;

        id<MTLRenderCommandEncoder> enc;
        bool ownCmdBuf = false;

        if (t_frameActive) {
            enc = t_frameEncoder;
        } else {
            if (!t_colorTarget || !t_depthTarget) {
                terrain_ensure_render_targets(1920, 1080);
            }
            id<MTLCommandBuffer> cmdBuf = [t_queue commandBuffer];
            cmdBuf.label = @"Terrain Render";
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = t_colorTarget;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.depthAttachment.texture = t_depthTarget;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;
            if (renderType == METAL_RT_SOLID) {
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
                rpd.depthAttachment.loadAction = MTLLoadActionClear;
                rpd.depthAttachment.clearDepth = 1.0;
            } else {
                rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
                rpd.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            enc.label = @"Terrain";
            ownCmdBuf = true;
            t_frameCmdBuf = cmdBuf;
        }

        [enc setRenderPipelineState:pipeline];
        [enc setDepthStencilState:depthState];
        [enc setCullMode:MTLCullModeBack];
        [enc setFrontFacingWinding:MTLWindingCounterClockwise];

        // Bind frame uniforms
        [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
        [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:2];

        // Bind textures
        if (t_blockAtlas) {
            [enc setFragmentTexture:t_blockAtlas atIndex:0];
            [enc setFragmentSamplerState:t_atlasSampler atIndex:0];
        }
        if (t_lightmap) {
            [enc setFragmentTexture:t_lightmap atIndex:1];
            [enc setFragmentSamplerState:t_lightmapSampler atIndex:1];
        }

        // Bind staging buffer directly as vertex data (already packed contiguously)
        [enc setVertexBuffer:rts->stagingBuffer offset:0 atIndex:0];
        [enc setVertexBuffer:rts->offsetBuffer offset:0 atIndex:1];

        // Single non-instanced draw with global index buffer
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:rts->globalIndexCount
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:rts->globalIndexBuffer
                 indexBufferOffset:0];

        // Compute actual vertex count
        int totalVerts = 0;
        for (int i = 0; i < rts->numChunks; i++) {
            totalVerts += rts->chunks[i].vertexCount;
        }

        t_lastDrawCount += 1;
        t_lastVertexCount += totalVerts;

        // Per-render-type stats
        if (renderType >= 0 && renderType < METAL_RT_COUNT) {
            t_rtStats[renderType].drawCount = 1;
            t_rtStats[renderType].vertexCount = totalVerts;
            t_rtStats[renderType].chunkCount = rts->numChunks;
        }

        if (ownCmdBuf) {
            [enc endEncoding];
            [t_frameCmdBuf addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                if (buf.GPUStartTime > 0 && buf.GPUEndTime > 0) {
                    t_lastGPUTimeNanos = (uint64_t)((buf.GPUEndTime - buf.GPUStartTime) * 1e9);
                }
            }];
            [t_frameCmdBuf commit];
        }
    }
}

// ============================================================
// Diagnostics
// ============================================================

uint64_t metal_terrain_get_gpu_time_nanos(void) {
    return t_lastGPUTimeNanos;
}

int metal_terrain_get_draw_count(void) {
    return t_lastDrawCount;
}

int metal_terrain_get_vertex_count(void) {
    return t_lastVertexCount;
}

int metal_terrain_get_rt_draw_count(int renderType) {
    if (renderType < 0 || renderType >= METAL_RT_COUNT) return 0;
    return t_rtStats[renderType].drawCount;
}

int metal_terrain_get_rt_vertex_count(int renderType) {
    if (renderType < 0 || renderType >= METAL_RT_COUNT) return 0;
    return t_rtStats[renderType].vertexCount;
}
