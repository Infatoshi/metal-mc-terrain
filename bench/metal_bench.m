// metal_bench.m -- Standalone Metal terrain kernel benchmark
//
// Profiles the terrain rendering pipeline offline, without launching Minecraft.
// Generates synthetic chunk data matching real-world distribution, then benchmarks:
//   A) Current approach: N drawIndexedPrimitives per render type (one per chunk)
//   B) Instanced approach: 1 drawIndexedPrimitives per render type (instanceCount=N)
//
// Build:  clang -framework Metal -framework QuartzCore -framework Foundation \
//         -O2 -fobjc-arc -o metal_bench metal_bench.m
// Run:    ./metal_bench [--chunks N] [--verts-per-chunk N] [--iterations N] [--width W] [--height H]

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <math.h>
#include <mach/mach_time.h>

// ============================================================
// Structs (match metal_terrain.h)
// ============================================================

typedef struct {
    float x, y, z;          // position
    uint8_t cr, cg, cb, ca; // color
    float u0, v0;           // uv0 (block atlas)
    int16_t u2, v2;         // uv2 (lightmap)
    uint8_t nx, ny, nz, nw; // normal + pad
} __attribute__((packed)) BlockVertex;

_Static_assert(sizeof(BlockVertex) == 32, "BlockVertex must be 32 bytes");

typedef struct {
    float offset[3];
    float _pad;
} ChunkOffset;

typedef struct {
    float viewProj[16];
    float fogStart;
    float fogEnd;
    float _pad0[2];
    float fogColor[4];
    float alphaThreshold;
    float _pad1[3];
} FrameUniforms;

// ============================================================
// Shader source (exact copy from metal_terrain.m + instanced variant)
// ============================================================

static NSString *kShaderSource = @
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
    // ---- Approach A: Current (one draw per chunk, offset via setVertexBytes) ----
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
    "    return color;\n"
    "}\n"
    "\n"
    // ---- Approach B: Instanced (one draw per render type, offset via instance_id) ----
    "vertex TerrainOut terrain_vertex_instanced(\n"
    "    BlockVertex in [[stage_in]],\n"
    "    constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]],\n"
    "    uint iid [[instance_id]]\n"
    ") {\n"
    "    TerrainOut out;\n"
    "    float3 worldPos = in.position + float3(chunks[iid].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = float4(in.color) / 255.0;\n"
    "    out.uv0 = in.uv0;\n"
    "    out.uv2 = float2(in.uv2) / 256.0;\n"
    "    out.normal = float3(float3(in.normal.xyz)) / 127.0;\n"
    "    float dist = length(worldPos);\n"
    "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
    "    return out;\n"
    "}\n";

// ============================================================
// Test data generation
// ============================================================

static void generate_identity_viewproj(float *out) {
    // Simple perspective-ish matrix
    memset(out, 0, 16 * sizeof(float));
    float fov = 70.0f * M_PI / 180.0f;
    float aspect = 16.0f / 9.0f;
    float near = 0.05f, far = 512.0f;
    float f = 1.0f / tanf(fov / 2.0f);
    out[0]  = f / aspect;
    out[5]  = f;
    out[10] = (far + near) / (near - far);
    out[11] = -1.0f;
    out[14] = (2.0f * far * near) / (near - far);
}

static void generate_chunk_vertices(BlockVertex *verts, int numVerts, float chunkX, float chunkZ) {
    // Generate plausible terrain-like quads within a 16x16x16 chunk section
    for (int i = 0; i < numVerts; i += 4) {
        float bx = (float)(rand() % 16);
        float by = (float)(rand() % 16);
        float bz = (float)(rand() % 16);
        float size = 1.0f;

        // Quad vertices (top face of a block)
        float positions[4][3] = {
            {bx,        by + size, bz},
            {bx + size, by + size, bz},
            {bx + size, by + size, bz + size},
            {bx,        by + size, bz + size},
        };

        for (int v = 0; v < 4 && (i + v) < numVerts; v++) {
            BlockVertex *vert = &verts[i + v];
            vert->x = positions[v][0];
            vert->y = positions[v][1];
            vert->z = positions[v][2];
            vert->cr = 200 + rand() % 56;
            vert->cg = 200 + rand() % 56;
            vert->cb = 200 + rand() % 56;
            vert->ca = 255;
            vert->u0 = (float)(rand() % 1024) / 1024.0f;
            vert->v0 = (float)(rand() % 1024) / 1024.0f;
            vert->u2 = (int16_t)(rand() % 256);
            vert->v2 = (int16_t)(rand() % 256);
            vert->nx = 0;
            vert->ny = 127;
            vert->nz = 0;
            vert->nw = 0;
        }
    }
}

// ============================================================
// Benchmark
// ============================================================

typedef struct {
    double gpuMs;
    double cpuEncodeMs;
    int drawCalls;
    int totalVerts;
} BenchResult;

static MTLVertexDescriptor* make_vertex_descriptor(void) {
    MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
    vd.attributes[0].format = MTLVertexFormatFloat3;    // position
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatUChar4;    // color
    vd.attributes[1].offset = 12;
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatFloat2;    // uv0
    vd.attributes[2].offset = 16;
    vd.attributes[2].bufferIndex = 0;
    vd.attributes[3].format = MTLVertexFormatShort2;    // uv2
    vd.attributes[3].offset = 24;
    vd.attributes[3].bufferIndex = 0;
    vd.attributes[4].format = MTLVertexFormatUChar4;    // normal
    vd.attributes[4].offset = 28;
    vd.attributes[4].bufferIndex = 0;
    vd.layouts[0].stride = 32;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    return vd;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Parse args
        int numChunks = 1200;       // typical visible chunk count
        int vertsPerChunk = 800;    // ~200 quads per chunk section avg
        int iterations = 200;       // benchmark iterations
        int width = 2560;           // render target width
        int height = 1440;          // render target height

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--chunks") == 0 && i+1 < argc) numChunks = atoi(argv[++i]);
            else if (strcmp(argv[i], "--verts-per-chunk") == 0 && i+1 < argc) vertsPerChunk = atoi(argv[++i]);
            else if (strcmp(argv[i], "--iterations") == 0 && i+1 < argc) iterations = atoi(argv[++i]);
            else if (strcmp(argv[i], "--width") == 0 && i+1 < argc) width = atoi(argv[++i]);
            else if (strcmp(argv[i], "--height") == 0 && i+1 < argc) height = atoi(argv[++i]);
            else if (strcmp(argv[i], "--help") == 0) {
                printf("Usage: metal_bench [options]\n");
                printf("  --chunks N           Number of chunk sections (default: 1200)\n");
                printf("  --verts-per-chunk N  Vertices per chunk (must be multiple of 4, default: 800)\n");
                printf("  --iterations N       Benchmark iterations (default: 200)\n");
                printf("  --width W            Render target width (default: 2560)\n");
                printf("  --height H           Render target height (default: 1440)\n");
                return 0;
            }
        }

        // Round verts to multiple of 4 (quads)
        vertsPerChunk = (vertsPerChunk / 4) * 4;
        if (vertsPerChunk < 4) vertsPerChunk = 4;

        int totalVerts = numChunks * vertsPerChunk;
        int totalQuads = totalVerts / 4;
        int maxQuadsPerChunk = vertsPerChunk / 4;

        printf("=== Metal Terrain Kernel Benchmark ===\n");
        printf("Device: ");

        // Create Metal device (headless)
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "No Metal device\n"); return 1; }
        printf("%s\n", [[device name] UTF8String]);

        id<MTLCommandQueue> queue = [device newCommandQueue];

        printf("Resolution: %dx%d\n", width, height);
        printf("Chunks: %d  Verts/chunk: %d  Total verts: %d (%.1fM)\n",
               numChunks, vertsPerChunk, totalVerts, totalVerts / 1e6);
        printf("Total quads: %d  Total triangles: %d\n", totalQuads, totalQuads * 2);
        printf("Vertex data: %.1f MB\n", (double)totalVerts * 32 / (1024*1024));
        printf("Iterations: %d\n\n", iterations);

        // Compile shaders
        NSError *error = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;
        id<MTLLibrary> library = [device newLibraryWithSource:kShaderSource options:opts error:&error];
        if (!library) {
            fprintf(stderr, "Shader compilation failed: %s\n", [[error description] UTF8String]);
            return 1;
        }

        // Pipelines
        MTLVertexDescriptor *vd = make_vertex_descriptor();

        // Pipeline A: current (per-chunk draws)
        id<MTLFunction> vertA = [library newFunctionWithName:@"terrain_vertex_batched"];
        id<MTLFunction> fragA = [library newFunctionWithName:@"terrain_fragment_batched"];
        // Pipeline B: instanced
        id<MTLFunction> vertB = [library newFunctionWithName:@"terrain_vertex_instanced"];

        MTLRenderPipelineDescriptor *pdA = [[MTLRenderPipelineDescriptor alloc] init];
        pdA.vertexFunction = vertA;
        pdA.fragmentFunction = fragA;
        pdA.vertexDescriptor = vd;
        pdA.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pdA.colorAttachments[0].blendingEnabled = NO;
        pdA.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

        id<MTLRenderPipelineState> pipelineA = [device newRenderPipelineStateWithDescriptor:pdA error:&error];
        if (!pipelineA) { fprintf(stderr, "Pipeline A failed: %s\n", [[error description] UTF8String]); return 1; }

        MTLRenderPipelineDescriptor *pdB = [[MTLRenderPipelineDescriptor alloc] init];
        pdB.vertexFunction = vertB;
        pdB.fragmentFunction = fragA;  // same fragment shader
        pdB.vertexDescriptor = vd;
        pdB.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pdB.colorAttachments[0].blendingEnabled = NO;
        pdB.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

        id<MTLRenderPipelineState> pipelineB = [device newRenderPipelineStateWithDescriptor:pdB error:&error];
        if (!pipelineB) { fprintf(stderr, "Pipeline B failed: %s\n", [[error description] UTF8String]); return 1; }

        // Depth state
        MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
        dd.depthCompareFunction = MTLCompareFunctionLess;
        dd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:dd];

        // Render targets (offscreen)
        MTLTextureDescriptor *colorDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width height:height mipmapped:NO];
        colorDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        colorDesc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> colorTarget = [device newTextureWithDescriptor:colorDesc];

        MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
            width:width height:height mipmapped:NO];
        depthDesc.usage = MTLTextureUsageRenderTarget;
        depthDesc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depthTarget = [device newTextureWithDescriptor:depthDesc];

        // Dummy textures (1024x1024 atlas, 16x16 lightmap)
        MTLTextureDescriptor *atlasDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:1024 height:1024 mipmapped:NO];
        atlasDesc.usage = MTLTextureUsageShaderRead;
        atlasDesc.storageMode = MTLStorageModeShared;
        id<MTLTexture> atlas = [device newTextureWithDescriptor:atlasDesc];
        // Fill with random color data
        {
            uint8_t *pixels = malloc(1024 * 1024 * 4);
            for (int i = 0; i < 1024 * 1024 * 4; i++) pixels[i] = rand() % 256;
            // Ensure alpha is mostly opaque for solid test
            for (int i = 3; i < 1024 * 1024 * 4; i += 4) pixels[i] = 255;
            [atlas replaceRegion:MTLRegionMake2D(0, 0, 1024, 1024)
                     mipmapLevel:0 withBytes:pixels bytesPerRow:1024*4];
            free(pixels);
        }

        MTLTextureDescriptor *lmDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:16 height:16 mipmapped:NO];
        lmDesc.usage = MTLTextureUsageShaderRead;
        lmDesc.storageMode = MTLStorageModeShared;
        id<MTLTexture> lightmap = [device newTextureWithDescriptor:lmDesc];
        {
            uint8_t pixels[16 * 16 * 4];
            for (int i = 0; i < 16 * 16 * 4; i++) pixels[i] = 200 + rand() % 56;
            [lightmap replaceRegion:MTLRegionMake2D(0, 0, 16, 16)
                        mipmapLevel:0 withBytes:pixels bytesPerRow:16*4];
        }

        // Samplers
        MTLSamplerDescriptor *atlasSamplerDesc = [[MTLSamplerDescriptor alloc] init];
        atlasSamplerDesc.minFilter = MTLSamplerMinMagFilterNearest;
        atlasSamplerDesc.magFilter = MTLSamplerMinMagFilterNearest;
        atlasSamplerDesc.mipFilter = MTLSamplerMipFilterLinear;
        atlasSamplerDesc.sAddressMode = MTLSamplerAddressModeRepeat;
        atlasSamplerDesc.tAddressMode = MTLSamplerAddressModeRepeat;
        id<MTLSamplerState> atlasSampler = [device newSamplerStateWithDescriptor:atlasSamplerDesc];

        MTLSamplerDescriptor *lmSamplerDesc = [[MTLSamplerDescriptor alloc] init];
        lmSamplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
        lmSamplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
        lmSamplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        lmSamplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        id<MTLSamplerState> lmSampler = [device newSamplerStateWithDescriptor:lmSamplerDesc];

        // Generate test data
        printf("Generating test data...\n");

        // Mega-buffer (all chunk vertices packed contiguously)
        id<MTLBuffer> megaBuffer = [device newBufferWithLength:totalVerts * 32
                                                       options:MTLResourceStorageModeShared];
        BlockVertex *allVerts = (BlockVertex *)[megaBuffer contents];

        // Chunk offsets (camera-relative positions scattered in a grid)
        ChunkOffset *offsets = calloc(numChunks, sizeof(ChunkOffset));
        int gridSize = (int)ceil(sqrt(numChunks));

        for (int i = 0; i < numChunks; i++) {
            int gx = i % gridSize;
            int gz = i / gridSize;
            float chunkX = (gx - gridSize / 2) * 16.0f;
            float chunkZ = (gz - gridSize / 2) * 16.0f;
            float chunkY = 64.0f; // typical overworld Y

            offsets[i].offset[0] = chunkX;
            offsets[i].offset[1] = chunkY;
            offsets[i].offset[2] = chunkZ;

            generate_chunk_vertices(&allVerts[i * vertsPerChunk], vertsPerChunk, chunkX, chunkZ);
        }

        // Chunk offset buffer for instanced rendering
        id<MTLBuffer> offsetBuffer = [device newBufferWithBytes:offsets
                                                         length:numChunks * sizeof(ChunkOffset)
                                                        options:MTLResourceStorageModeShared];

        // Quad-to-triangle index buffer (same as metal_terrain.m)
        int numIndices = maxQuadsPerChunk * 6;
        uint16_t *indices = malloc(numIndices * sizeof(uint16_t));
        for (int q = 0; q < maxQuadsPerChunk; q++) {
            indices[q * 6 + 0] = (uint16_t)(q * 4 + 0);
            indices[q * 6 + 1] = (uint16_t)(q * 4 + 1);
            indices[q * 6 + 2] = (uint16_t)(q * 4 + 2);
            indices[q * 6 + 3] = (uint16_t)(q * 4 + 0);
            indices[q * 6 + 4] = (uint16_t)(q * 4 + 2);
            indices[q * 6 + 5] = (uint16_t)(q * 4 + 3);
        }
        id<MTLBuffer> indexBuffer = [device newBufferWithLength:numIndices * sizeof(uint16_t)
                                                        options:MTLResourceStorageModeShared];
        memcpy([indexBuffer contents], indices, numIndices * sizeof(uint16_t));
        free(indices);

        // Frame uniforms
        FrameUniforms uniforms;
        generate_identity_viewproj(uniforms.viewProj);
        uniforms.fogStart = 192.0f;
        uniforms.fogEnd = 256.0f;
        uniforms._pad0[0] = 0; uniforms._pad0[1] = 0;
        uniforms.fogColor[0] = 0.7f; uniforms.fogColor[1] = 0.8f;
        uniforms.fogColor[2] = 1.0f; uniforms.fogColor[3] = 1.0f;
        uniforms.alphaThreshold = 0.0f;  // solid
        uniforms._pad1[0] = 0; uniforms._pad1[1] = 0; uniforms._pad1[2] = 0;

        free(offsets);

        printf("Test data ready. Mega-buffer: %.1f MB\n\n",
               (double)totalVerts * 32 / (1024*1024));

        // ========================================
        // Warmup (5 frames each)
        // ========================================
        printf("Warming up...\n");
        for (int w = 0; w < 5; w++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                rpd.colorAttachments[0].texture = colorTarget;
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
                rpd.depthAttachment.texture = depthTarget;
                rpd.depthAttachment.loadAction = MTLLoadActionClear;
                rpd.depthAttachment.clearDepth = 1.0;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;

                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
                [enc setRenderPipelineState:pipelineA];
                [enc setDepthStencilState:depthState];
                [enc setVertexBuffer:megaBuffer offset:0 atIndex:0];
                [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
                [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:2];
                [enc setFragmentTexture:atlas atIndex:0];
                [enc setFragmentTexture:lightmap atIndex:1];
                [enc setFragmentSamplerState:atlasSampler atIndex:0];
                [enc setFragmentSamplerState:lmSampler atIndex:1];

                for (int c = 0; c < numChunks; c++) {
                    float chunkData[4] = {
                        (float)((c % gridSize) - gridSize/2) * 16.0f,
                        64.0f,
                        (float)((c / gridSize) - gridSize/2) * 16.0f,
                        0.0f
                    };
                    [enc setVertexBytes:chunkData length:sizeof(chunkData) atIndex:1];
                    int numQuads = vertsPerChunk / 4;
                    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:numQuads * 6
                                     indexType:MTLIndexTypeUInt16
                                   indexBuffer:indexBuffer
                             indexBufferOffset:0
                                 instanceCount:1
                                    baseVertex:c * vertsPerChunk
                                  baseInstance:0];
                }
                [enc endEncoding];
                [cmd commit];
                [cmd waitUntilCompleted];
            }
        }

        // ========================================
        // Benchmark A: Current approach (N draws per type)
        // ========================================
        printf("--- Approach A: Per-Chunk Draws (%d draws/frame) ---\n", numChunks);

        double gpuTimesA[iterations];
        double cpuTimesA[iterations];

        for (int iter = 0; iter < iterations; iter++) {
            @autoreleasepool {
                uint64_t cpuStart = mach_absolute_time();

                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                rpd.colorAttachments[0].texture = colorTarget;
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
                rpd.depthAttachment.texture = depthTarget;
                rpd.depthAttachment.loadAction = MTLLoadActionClear;
                rpd.depthAttachment.clearDepth = 1.0;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;

                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
                [enc setRenderPipelineState:pipelineA];
                [enc setDepthStencilState:depthState];
                [enc setCullMode:MTLCullModeBack];
                [enc setFrontFacingWinding:MTLWindingCounterClockwise];
                [enc setVertexBuffer:megaBuffer offset:0 atIndex:0];
                [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
                [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:2];
                [enc setFragmentTexture:atlas atIndex:0];
                [enc setFragmentTexture:lightmap atIndex:1];
                [enc setFragmentSamplerState:atlasSampler atIndex:0];
                [enc setFragmentSamplerState:lmSampler atIndex:1];

                for (int c = 0; c < numChunks; c++) {
                    float chunkData[4] = {
                        (float)((c % gridSize) - gridSize/2) * 16.0f,
                        64.0f,
                        (float)((c / gridSize) - gridSize/2) * 16.0f,
                        0.0f
                    };
                    [enc setVertexBytes:chunkData length:sizeof(chunkData) atIndex:1];
                    int numQuads = vertsPerChunk / 4;
                    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:numQuads * 6
                                     indexType:MTLIndexTypeUInt16
                                   indexBuffer:indexBuffer
                             indexBufferOffset:0
                                 instanceCount:1
                                    baseVertex:c * vertsPerChunk
                                  baseInstance:0];
                }
                [enc endEncoding];

                __block double gpuTime = 0;
                [cmd addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                    if (buf.GPUStartTime > 0 && buf.GPUEndTime > 0) {
                        gpuTime = (buf.GPUEndTime - buf.GPUStartTime) * 1000.0;
                    }
                }];
                [cmd commit];
                [cmd waitUntilCompleted];

                uint64_t cpuEnd = mach_absolute_time();

                // Convert mach time to ms
                mach_timebase_info_data_t timebase;
                mach_timebase_info(&timebase);
                cpuTimesA[iter] = (double)(cpuEnd - cpuStart) * timebase.numer / timebase.denom / 1e6;
                gpuTimesA[iter] = gpuTime;
            }
        }

        // ========================================
        // Benchmark B: Instanced approach (1 draw per type)
        // ========================================
        printf("--- Approach B: Instanced Draw (1 draw/frame, %d instances) ---\n", numChunks);

        double gpuTimesB[iterations];
        double cpuTimesB[iterations];

        for (int iter = 0; iter < iterations; iter++) {
            @autoreleasepool {
                uint64_t cpuStart = mach_absolute_time();

                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                rpd.colorAttachments[0].texture = colorTarget;
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
                rpd.depthAttachment.texture = depthTarget;
                rpd.depthAttachment.loadAction = MTLLoadActionClear;
                rpd.depthAttachment.clearDepth = 1.0;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;

                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
                [enc setRenderPipelineState:pipelineB];
                [enc setDepthStencilState:depthState];
                [enc setCullMode:MTLCullModeBack];
                [enc setFrontFacingWinding:MTLWindingCounterClockwise];
                [enc setVertexBuffer:megaBuffer offset:0 atIndex:0];
                [enc setVertexBuffer:offsetBuffer offset:0 atIndex:1];
                [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
                [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:2];
                [enc setFragmentTexture:atlas atIndex:0];
                [enc setFragmentTexture:lightmap atIndex:1];
                [enc setFragmentSamplerState:atlasSampler atIndex:0];
                [enc setFragmentSamplerState:lmSampler atIndex:1];

                int numQuads = vertsPerChunk / 4;
                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:numQuads * 6
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:indexBuffer
                         indexBufferOffset:0
                             instanceCount:numChunks
                                baseVertex:0
                              baseInstance:0];

                [enc endEncoding];

                __block double gpuTime = 0;
                [cmd addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                    if (buf.GPUStartTime > 0 && buf.GPUEndTime > 0) {
                        gpuTime = (buf.GPUEndTime - buf.GPUStartTime) * 1000.0;
                    }
                }];
                [cmd commit];
                [cmd waitUntilCompleted];

                uint64_t cpuEnd = mach_absolute_time();

                mach_timebase_info_data_t timebase;
                mach_timebase_info(&timebase);
                cpuTimesB[iter] = (double)(cpuEnd - cpuStart) * timebase.numer / timebase.denom / 1e6;
                gpuTimesB[iter] = gpuTime;
            }
        }

        // ========================================
        // Results
        // ========================================
        printf("\n=== Results (dropping first 10%% as warmup) ===\n\n");

        int skip = iterations / 10;
        int count = iterations - skip;

        // Compute stats
        double gpuSumA = 0, cpuSumA = 0, gpuMinA = 1e9, gpuMaxA = 0;
        double gpuSumB = 0, cpuSumB = 0, gpuMinB = 1e9, gpuMaxB = 0;
        double cpuMinA = 1e9, cpuMaxA = 0, cpuMinB = 1e9, cpuMaxB = 0;

        for (int i = skip; i < iterations; i++) {
            gpuSumA += gpuTimesA[i];
            cpuSumA += cpuTimesA[i];
            if (gpuTimesA[i] < gpuMinA) gpuMinA = gpuTimesA[i];
            if (gpuTimesA[i] > gpuMaxA) gpuMaxA = gpuTimesA[i];
            if (cpuTimesA[i] < cpuMinA) cpuMinA = cpuTimesA[i];
            if (cpuTimesA[i] > cpuMaxA) cpuMaxA = cpuTimesA[i];

            gpuSumB += gpuTimesB[i];
            cpuSumB += cpuTimesB[i];
            if (gpuTimesB[i] < gpuMinB) gpuMinB = gpuTimesB[i];
            if (gpuTimesB[i] > gpuMaxB) gpuMaxB = gpuTimesB[i];
            if (cpuTimesB[i] < cpuMinB) cpuMinB = cpuTimesB[i];
            if (cpuTimesB[i] > cpuMaxB) cpuMaxB = cpuTimesB[i];
        }

        double gpuAvgA = gpuSumA / count, cpuAvgA = cpuSumA / count;
        double gpuAvgB = gpuSumB / count, cpuAvgB = cpuSumB / count;

        // Sort for percentiles
        // (simple bubble sort, N is small)
        double gpuSortedA[count], gpuSortedB[count];
        double cpuSortedA[count], cpuSortedB[count];
        for (int i = 0; i < count; i++) {
            gpuSortedA[i] = gpuTimesA[i + skip];
            gpuSortedB[i] = gpuTimesB[i + skip];
            cpuSortedA[i] = cpuTimesA[i + skip];
            cpuSortedB[i] = cpuTimesB[i + skip];
        }
        for (int i = 0; i < count - 1; i++) {
            for (int j = i + 1; j < count; j++) {
                if (gpuSortedA[j] < gpuSortedA[i]) { double t = gpuSortedA[i]; gpuSortedA[i] = gpuSortedA[j]; gpuSortedA[j] = t; }
                if (gpuSortedB[j] < gpuSortedB[i]) { double t = gpuSortedB[i]; gpuSortedB[i] = gpuSortedB[j]; gpuSortedB[j] = t; }
                if (cpuSortedA[j] < cpuSortedA[i]) { double t = cpuSortedA[i]; cpuSortedA[i] = cpuSortedA[j]; cpuSortedA[j] = t; }
                if (cpuSortedB[j] < cpuSortedB[i]) { double t = cpuSortedB[i]; cpuSortedB[i] = cpuSortedB[j]; cpuSortedB[j] = t; }
            }
        }

        int p50 = count / 2;
        int p95 = (int)(count * 0.95);
        int p99 = (int)(count * 0.99);

        printf("Approach A: Per-Chunk Draws (%d draws/frame)\n", numChunks);
        printf("  GPU:  avg=%.3fms  p50=%.3fms  p95=%.3fms  p99=%.3fms  min=%.3fms  max=%.3fms\n",
               gpuAvgA, gpuSortedA[p50], gpuSortedA[p95], gpuSortedA[p99], gpuMinA, gpuMaxA);
        printf("  CPU:  avg=%.3fms  p50=%.3fms  p95=%.3fms  p99=%.3fms  min=%.3fms  max=%.3fms\n",
               cpuAvgA, cpuSortedA[p50], cpuSortedA[p95], cpuSortedA[p99], cpuMinA, cpuMaxA);
        printf("  Throughput: %.1fM verts/ms GPU, %.1fM tris/frame\n",
               totalVerts / gpuAvgA / 1e6 * 1000.0, totalQuads * 2 / 1e6);

        printf("\nApproach B: Instanced Draw (1 draw/frame, %d instances)\n", numChunks);
        printf("  GPU:  avg=%.3fms  p50=%.3fms  p95=%.3fms  p99=%.3fms  min=%.3fms  max=%.3fms\n",
               gpuAvgB, gpuSortedB[p50], gpuSortedB[p95], gpuSortedB[p99], gpuMinB, gpuMaxB);
        printf("  CPU:  avg=%.3fms  p50=%.3fms  p95=%.3fms  p99=%.3fms  min=%.3fms  max=%.3fms\n",
               cpuAvgB, cpuSortedB[p50], cpuSortedB[p95], cpuSortedB[p99], cpuMinB, cpuMaxB);
        printf("  Throughput: %.1fM verts/ms GPU, %.1fM tris/frame\n",
               totalVerts / gpuAvgB / 1e6 * 1000.0, totalQuads * 2 / 1e6);

        printf("\n=== Speedup (B vs A) ===\n");
        printf("  GPU: %.2fx (%.3fms -> %.3fms, saved %.3fms)\n",
               gpuAvgA / gpuAvgB, gpuAvgA, gpuAvgB, gpuAvgA - gpuAvgB);
        printf("  CPU: %.2fx (%.3fms -> %.3fms, saved %.3fms)\n",
               cpuAvgA / cpuAvgB, cpuAvgA, cpuAvgB, cpuAvgA - cpuAvgB);

        double bandwidth = (double)totalVerts * 32 / (1024*1024*1024);
        printf("\n=== Memory ===\n");
        printf("  Vertex bandwidth/frame: %.1f MB (%.1f GB/s at avg GPU time A)\n",
               bandwidth * 1024, bandwidth / (gpuAvgA / 1000.0));
        printf("  M4 Max bandwidth: 410 GB/s (utilization: %.1f%%)\n",
               bandwidth / (gpuAvgA / 1000.0) / 410.0 * 100.0);

        return 0;
    }
}
