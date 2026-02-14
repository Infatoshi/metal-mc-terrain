// metal_bench_v2.m -- Variable-size chunk benchmarks
//
// Tests approaches that handle real-world variable chunk sizes:
//   A) Current: N per-chunk draws (baseline)
//   B) Instanced with padding to max (wastes some GPU work)
//   C) Indirect command buffer (ICB) -- variable size, GPU-driven
//
// Build:  clang -framework Metal -framework QuartzCore -framework Foundation \
//         -O2 -fobjc-arc -o metal_bench_v2 metal_bench_v2.m
// Run:    ./metal_bench_v2 [--chunks N] [--iterations N]

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <math.h>
#include <mach/mach_time.h>

// ============================================================
// Structs
// ============================================================

typedef struct {
    float x, y, z;
    uint8_t cr, cg, cb, ca;
    float u0, v0;
    int16_t u2, v2;
    uint8_t nx, ny, nz, nw;
} __attribute__((packed)) BlockVertex;

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

// Per-chunk metadata for variable-size approach
typedef struct {
    uint32_t vertexOffset;   // into mega-buffer (in vertices)
    uint32_t vertexCount;    // actual vertex count
    uint32_t indexCount;     // vertexCount/4 * 6
    uint32_t _pad;
} ChunkMeta;

// ============================================================
// Shader source
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
    // Approach A: current
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
    // Approach B: instanced (uniform size)
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
// Helpers
// ============================================================

static void generate_viewproj(float *out) {
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

static void fill_block_vertex(BlockVertex *v) {
    v->x = (float)(rand() % 16);
    v->y = (float)(rand() % 16);
    v->z = (float)(rand() % 16);
    v->cr = 200; v->cg = 200; v->cb = 200; v->ca = 255;
    v->u0 = (float)(rand() % 1024) / 1024.0f;
    v->v0 = (float)(rand() % 1024) / 1024.0f;
    v->u2 = (int16_t)(rand() % 256);
    v->v2 = (int16_t)(rand() % 256);
    v->nx = 0; v->ny = 127; v->nz = 0; v->nw = 0;
}

static MTLVertexDescriptor* make_vertex_descriptor(void) {
    MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
    vd.attributes[0].format = MTLVertexFormatFloat3;  vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatUChar4;   vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatFloat2;   vd.attributes[2].offset = 16; vd.attributes[2].bufferIndex = 0;
    vd.attributes[3].format = MTLVertexFormatShort2;   vd.attributes[3].offset = 24; vd.attributes[3].bufferIndex = 0;
    vd.attributes[4].format = MTLVertexFormatUChar4;   vd.attributes[4].offset = 28; vd.attributes[4].bufferIndex = 0;
    vd.layouts[0].stride = 32;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    return vd;
}

typedef struct {
    double avg, p50, p95, p99, min, max;
} Stats;

static Stats compute_stats(double *data, int count) {
    Stats s;
    s.min = 1e9; s.max = 0;
    double sum = 0;
    for (int i = 0; i < count; i++) {
        sum += data[i];
        if (data[i] < s.min) s.min = data[i];
        if (data[i] > s.max) s.max = data[i];
    }
    s.avg = sum / count;
    // Sort for percentiles
    double sorted[count];
    memcpy(sorted, data, count * sizeof(double));
    for (int i = 0; i < count - 1; i++)
        for (int j = i + 1; j < count; j++)
            if (sorted[j] < sorted[i]) { double t = sorted[i]; sorted[i] = sorted[j]; sorted[j] = t; }
    s.p50 = sorted[count/2];
    s.p95 = sorted[(int)(count*0.95)];
    s.p99 = sorted[(int)(count*0.99)];
    return s;
}

static void print_stats(const char *label, Stats s) {
    printf("  %s avg=%.3fms  p50=%.3fms  p95=%.3fms  p99=%.3fms  min=%.3f  max=%.3f\n",
           label, s.avg, s.p50, s.p95, s.p99, s.min, s.max);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int numChunks = 1200;
        int iterations = 200;
        int width = 2560, height = 1440;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--chunks") == 0 && i+1 < argc) numChunks = atoi(argv[++i]);
            else if (strcmp(argv[i], "--iterations") == 0 && i+1 < argc) iterations = atoi(argv[++i]);
            else if (strcmp(argv[i], "--width") == 0 && i+1 < argc) width = atoi(argv[++i]);
            else if (strcmp(argv[i], "--height") == 0 && i+1 < argc) height = atoi(argv[++i]);
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "No Metal device\n"); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];

        printf("=== Metal Terrain Benchmark v2 (Variable Chunk Sizes) ===\n");
        printf("Device: %s\n", [[device name] UTF8String]);
        printf("Resolution: %dx%d  Chunks: %d  Iterations: %d\n\n", width, height, numChunks, iterations);

        // Compile
        NSError *error = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;
        id<MTLLibrary> library = [device newLibraryWithSource:kShaderSource options:opts error:&error];
        if (!library) { fprintf(stderr, "Shader error: %s\n", [[error description] UTF8String]); return 1; }

        MTLVertexDescriptor *vd = make_vertex_descriptor();

        // Pipeline A (per-chunk)
        MTLRenderPipelineDescriptor *pdA = [[MTLRenderPipelineDescriptor alloc] init];
        pdA.vertexFunction = [library newFunctionWithName:@"terrain_vertex_batched"];
        pdA.fragmentFunction = [library newFunctionWithName:@"terrain_fragment_batched"];
        pdA.vertexDescriptor = vd;
        pdA.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pdA.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> pipeA = [device newRenderPipelineStateWithDescriptor:pdA error:&error];

        // Pipeline B (instanced)
        MTLRenderPipelineDescriptor *pdB = [[MTLRenderPipelineDescriptor alloc] init];
        pdB.vertexFunction = [library newFunctionWithName:@"terrain_vertex_instanced"];
        pdB.fragmentFunction = [library newFunctionWithName:@"terrain_fragment_batched"];
        pdB.vertexDescriptor = vd;
        pdB.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pdB.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> pipeB = [device newRenderPipelineStateWithDescriptor:pdB error:&error];

        // Depth
        MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
        dd.depthCompareFunction = MTLCompareFunctionLess;
        dd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:dd];

        // Render targets
        MTLTextureDescriptor *td;
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> colorTex = [device newTextureWithDescriptor:td];

        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depthTex = [device newTextureWithDescriptor:td];

        // Dummy textures
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
              width:1024 height:1024 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> atlas = [device newTextureWithDescriptor:td];
        {
            uint8_t *px = malloc(1024*1024*4);
            for (int i = 0; i < 1024*1024*4; i++) px[i] = (i % 4 == 3) ? 255 : rand() % 256;
            [atlas replaceRegion:MTLRegionMake2D(0,0,1024,1024) mipmapLevel:0 withBytes:px bytesPerRow:1024*4];
            free(px);
        }
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
              width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> lm = [device newTextureWithDescriptor:td];
        { uint8_t px[16*16*4]; for (int i=0;i<16*16*4;i++) px[i]=200; [lm replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:px bytesPerRow:16*4]; }

        // Samplers
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterNearest;
        sd.magFilter = MTLSamplerMinMagFilterNearest;
        id<MTLSamplerState> aSampler = [device newSamplerStateWithDescriptor:sd];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        id<MTLSamplerState> lSampler = [device newSamplerStateWithDescriptor:sd];

        // ============================================================
        // Generate VARIABLE-SIZE chunk data
        // Real Minecraft: chunk vert counts follow roughly log-normal
        // Range: 4 (nearly empty) to 4000+ (complex terrain surface)
        // ============================================================

        printf("Generating variable-size chunks...\n");

        ChunkMeta *metas = calloc(numChunks, sizeof(ChunkMeta));
        ChunkOffset *offsets = calloc(numChunks, sizeof(ChunkOffset));

        int totalVerts = 0;
        int maxVertsPerChunk = 0;
        int gridSize = (int)ceil(sqrt(numChunks));

        srand(42); // deterministic

        for (int i = 0; i < numChunks; i++) {
            // Log-normal-ish distribution: many small, few large
            float r = (float)rand() / RAND_MAX;
            int verts = (int)(expf(r * 5.0f + 2.0f)); // range ~7 to ~1097
            verts = (verts / 4) * 4; // round to quads
            if (verts < 4) verts = 4;
            if (verts > 4096) verts = 4096;

            metas[i].vertexOffset = totalVerts;
            metas[i].vertexCount = verts;
            metas[i].indexCount = (verts / 4) * 6;
            totalVerts += verts;
            if (verts > maxVertsPerChunk) maxVertsPerChunk = verts;

            offsets[i].offset[0] = (float)((i % gridSize) - gridSize/2) * 16.0f;
            offsets[i].offset[1] = 64.0f;
            offsets[i].offset[2] = (float)((i / gridSize) - gridSize/2) * 16.0f;
        }

        int maxQuadsPerChunk = maxVertsPerChunk / 4;
        int avgVerts = totalVerts / numChunks;

        printf("  Total verts: %d (%.1fM)  Avg/chunk: %d  Max/chunk: %d\n",
               totalVerts, totalVerts/1e6, avgVerts, maxVertsPerChunk);
        printf("  Vertex data: %.1f MB\n", (double)totalVerts * 32 / (1024*1024));

        // Fill mega-buffer
        id<MTLBuffer> megaBuffer = [device newBufferWithLength:totalVerts * 32
                                                       options:MTLResourceStorageModeShared];
        BlockVertex *allVerts = (BlockVertex *)[megaBuffer contents];
        for (int i = 0; i < totalVerts; i++) fill_block_vertex(&allVerts[i]);

        // For instanced: pad each chunk to maxVertsPerChunk
        int paddedTotalVerts = numChunks * maxVertsPerChunk;
        id<MTLBuffer> paddedMegaBuffer = [device newBufferWithLength:paddedTotalVerts * 32
                                                              options:MTLResourceStorageModeShared];
        BlockVertex *paddedVerts = (BlockVertex *)[paddedMegaBuffer contents];
        memset(paddedVerts, 0, paddedTotalVerts * 32);
        for (int c = 0; c < numChunks; c++) {
            memcpy(&paddedVerts[c * maxVertsPerChunk],
                   &allVerts[metas[c].vertexOffset],
                   metas[c].vertexCount * 32);
            // Degenerate verts (zero position) for padding -- rasterized but clipped
        }

        printf("  Padded mega-buffer: %.1f MB (%.1f%% waste)\n",
               (double)paddedTotalVerts * 32 / (1024*1024),
               100.0 * (paddedTotalVerts - totalVerts) / (double)paddedTotalVerts);

        // Offset buffer
        id<MTLBuffer> offsetBuffer = [device newBufferWithBytes:offsets
                                                         length:numChunks * sizeof(ChunkOffset)
                                                        options:MTLResourceStorageModeShared];

        // Quad-to-triangle index buffer (sized for max chunk)
        int numIndices = maxQuadsPerChunk * 6;
        uint16_t *idx = malloc(numIndices * sizeof(uint16_t));
        for (int q = 0; q < maxQuadsPerChunk; q++) {
            idx[q*6+0] = (uint16_t)(q*4+0); idx[q*6+1] = (uint16_t)(q*4+1); idx[q*6+2] = (uint16_t)(q*4+2);
            idx[q*6+3] = (uint16_t)(q*4+0); idx[q*6+4] = (uint16_t)(q*4+2); idx[q*6+5] = (uint16_t)(q*4+3);
        }
        id<MTLBuffer> indexBuffer = [device newBufferWithLength:numIndices * sizeof(uint16_t)
                                                        options:MTLResourceStorageModeShared];
        memcpy([indexBuffer contents], idx, numIndices * sizeof(uint16_t));
        free(idx);

        // Uniforms
        FrameUniforms uniforms;
        generate_viewproj(uniforms.viewProj);
        uniforms.fogStart = 192.0f; uniforms.fogEnd = 256.0f;
        uniforms._pad0[0] = 0; uniforms._pad0[1] = 0;
        uniforms.fogColor[0] = 0.7f; uniforms.fogColor[1] = 0.8f; uniforms.fogColor[2] = 1.0f; uniforms.fogColor[3] = 1.0f;
        uniforms.alphaThreshold = 0.0f;
        uniforms._pad1[0] = 0; uniforms._pad1[1] = 0; uniforms._pad1[2] = 0;

        free(metas);
        free(offsets);

        printf("\n");

        // Helper: create render pass descriptor
        MTLRenderPassDescriptor* (^makeRPD)(void) = ^{
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorTex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
            rpd.depthAttachment.texture = depthTex;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;
            return rpd;
        };

        void (^bindCommon)(id<MTLRenderCommandEncoder>) = ^(id<MTLRenderCommandEncoder> enc) {
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeBack];
            [enc setFrontFacingWinding:MTLWindingCounterClockwise];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
            [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:2];
            [enc setFragmentTexture:atlas atIndex:0];
            [enc setFragmentTexture:lm atIndex:1];
            [enc setFragmentSamplerState:aSampler atIndex:0];
            [enc setFragmentSamplerState:lSampler atIndex:1];
        };

        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);

        int skip = iterations / 10;
        int count = iterations - skip;

        // Warmup
        printf("Warming up...\n");
        for (int w = 0; w < 10; w++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:makeRPD()];
                [enc setRenderPipelineState:pipeA];
                bindCommon(enc);
                [enc setVertexBuffer:megaBuffer offset:0 atIndex:0];
                float cd[4] = {0,0,0,0};
                [enc setVertexBytes:cd length:16 atIndex:1];
                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6
                                 indexType:MTLIndexTypeUInt16 indexBuffer:indexBuffer indexBufferOffset:0];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }
        }

        // Reload metas (we freed them, regenerate)
        ChunkMeta *metas2 = calloc(numChunks, sizeof(ChunkMeta));
        {
            srand(42);
            int off = 0;
            for (int i = 0; i < numChunks; i++) {
                float r = (float)rand() / RAND_MAX;
                int verts = (int)(expf(r * 5.0f + 2.0f));
                verts = (verts / 4) * 4;
                if (verts < 4) verts = 4;
                if (verts > 4096) verts = 4096;
                metas2[i].vertexOffset = off;
                metas2[i].vertexCount = verts;
                metas2[i].indexCount = (verts / 4) * 6;
                off += verts;
            }
        }

        // ============================================================
        // Approach A: Per-chunk draws with variable sizes (current)
        // ============================================================
        printf("--- A: Per-Chunk Draws (variable size, %d draws) ---\n", numChunks);
        double gpuA[iterations], cpuA[iterations];

        for (int iter = 0; iter < iterations; iter++) {
            @autoreleasepool {
                uint64_t t0 = mach_absolute_time();
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:makeRPD()];
                [enc setRenderPipelineState:pipeA];
                bindCommon(enc);
                [enc setVertexBuffer:megaBuffer offset:0 atIndex:0];

                for (int c = 0; c < numChunks; c++) {
                    float cd[4] = {
                        (float)((c % gridSize) - gridSize/2) * 16.0f, 64.0f,
                        (float)((c / gridSize) - gridSize/2) * 16.0f, 0.0f
                    };
                    [enc setVertexBytes:cd length:16 atIndex:1];
                    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:metas2[c].indexCount
                                     indexType:MTLIndexTypeUInt16
                                   indexBuffer:indexBuffer
                             indexBufferOffset:0
                                 instanceCount:1
                                    baseVertex:metas2[c].vertexOffset
                                  baseInstance:0];
                }
                [enc endEncoding];

                __block double gt = 0;
                [cmd addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                    if (buf.GPUStartTime > 0) gt = (buf.GPUEndTime - buf.GPUStartTime) * 1000.0;
                }];
                [cmd commit]; [cmd waitUntilCompleted];
                cpuA[iter] = (double)(mach_absolute_time()-t0) * timebase.numer / timebase.denom / 1e6;
                gpuA[iter] = gt;
            }
        }

        // ============================================================
        // Approach B: Instanced with padding to max
        // ============================================================
        printf("--- B: Instanced + Padded (1 draw, %d instances, max=%d verts) ---\n",
               numChunks, maxVertsPerChunk);
        double gpuB[iterations], cpuB[iterations];

        for (int iter = 0; iter < iterations; iter++) {
            @autoreleasepool {
                uint64_t t0 = mach_absolute_time();
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:makeRPD()];
                [enc setRenderPipelineState:pipeB];
                bindCommon(enc);
                [enc setVertexBuffer:paddedMegaBuffer offset:0 atIndex:0];
                [enc setVertexBuffer:offsetBuffer offset:0 atIndex:1];

                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:maxQuadsPerChunk * 6
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:indexBuffer
                         indexBufferOffset:0
                             instanceCount:numChunks
                                baseVertex:0
                              baseInstance:0];

                [enc endEncoding];
                __block double gt = 0;
                [cmd addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                    if (buf.GPUStartTime > 0) gt = (buf.GPUEndTime - buf.GPUStartTime) * 1000.0;
                }];
                [cmd commit]; [cmd waitUntilCompleted];
                cpuB[iter] = (double)(mach_absolute_time()-t0) * timebase.numer / timebase.denom / 1e6;
                gpuB[iter] = gt;
            }
        }

        // ============================================================
        // Approach C: Multiple instanced draws by size bucket
        // Group chunks into a few buckets by vertex count, one instanced draw per bucket
        // ============================================================
        // Create 4 buckets: [4-128], [132-512], [516-1500], [1504+]
        int bucketThresholds[] = {128, 512, 1500, 99999};
        int numBuckets = 4;

        // Sort chunks into buckets
        typedef struct { int *chunkIds; int count; int maxVerts; } Bucket;
        Bucket buckets[4];
        for (int b = 0; b < numBuckets; b++) {
            buckets[b].chunkIds = malloc(numChunks * sizeof(int));
            buckets[b].count = 0;
            buckets[b].maxVerts = 0;
        }
        for (int c = 0; c < numChunks; c++) {
            int verts = metas2[c].vertexCount;
            for (int b = 0; b < numBuckets; b++) {
                if (verts <= bucketThresholds[b]) {
                    buckets[b].chunkIds[buckets[b].count++] = c;
                    if (verts > buckets[b].maxVerts) buckets[b].maxVerts = verts;
                    break;
                }
            }
        }

        // Build per-bucket padded buffers and offset buffers
        id<MTLBuffer> bucketMegaBuffers[4];
        id<MTLBuffer> bucketOffsetBuffers[4];
        id<MTLBuffer> bucketIndexBuffers[4];

        int totalBucketDraws = 0;
        for (int b = 0; b < numBuckets; b++) {
            if (buckets[b].count == 0) continue;
            totalBucketDraws++;
            int maxV = buckets[b].maxVerts;
            int paddedSize = buckets[b].count * maxV;

            bucketMegaBuffers[b] = [device newBufferWithLength:paddedSize * 32
                                                        options:MTLResourceStorageModeShared];
            BlockVertex *bv = (BlockVertex *)[bucketMegaBuffers[b] contents];
            memset(bv, 0, paddedSize * 32);

            ChunkOffset *boff = calloc(buckets[b].count, sizeof(ChunkOffset));
            for (int i = 0; i < buckets[b].count; i++) {
                int c = buckets[b].chunkIds[i];
                memcpy(&bv[i * maxV], &allVerts[metas2[c].vertexOffset], metas2[c].vertexCount * 32);
                boff[i].offset[0] = (float)((c % gridSize) - gridSize/2) * 16.0f;
                boff[i].offset[1] = 64.0f;
                boff[i].offset[2] = (float)((c / gridSize) - gridSize/2) * 16.0f;
            }
            bucketOffsetBuffers[b] = [device newBufferWithBytes:boff
                                                         length:buckets[b].count * sizeof(ChunkOffset)
                                                        options:MTLResourceStorageModeShared];
            free(boff);

            // Index buffer for this bucket's max
            int bMaxQuads = maxV / 4;
            int bNumIdx = bMaxQuads * 6;
            uint16_t *bidx = malloc(bNumIdx * sizeof(uint16_t));
            for (int q = 0; q < bMaxQuads; q++) {
                bidx[q*6+0]=(uint16_t)(q*4+0); bidx[q*6+1]=(uint16_t)(q*4+1); bidx[q*6+2]=(uint16_t)(q*4+2);
                bidx[q*6+3]=(uint16_t)(q*4+0); bidx[q*6+4]=(uint16_t)(q*4+2); bidx[q*6+5]=(uint16_t)(q*4+3);
            }
            bucketIndexBuffers[b] = [device newBufferWithLength:bNumIdx * sizeof(uint16_t)
                                                         options:MTLResourceStorageModeShared];
            memcpy([bucketIndexBuffers[b] contents], bidx, bNumIdx * sizeof(uint16_t));
            free(bidx);
        }

        printf("--- C: Bucketed Instanced (%d draws, 4 size buckets) ---\n", totalBucketDraws);
        for (int b = 0; b < numBuckets; b++) {
            if (buckets[b].count == 0) continue;
            printf("  Bucket %d (max %4d verts): %4d chunks\n", b, buckets[b].maxVerts, buckets[b].count);
        }

        double gpuC[iterations], cpuC[iterations];

        for (int iter = 0; iter < iterations; iter++) {
            @autoreleasepool {
                uint64_t t0 = mach_absolute_time();
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:makeRPD()];
                [enc setRenderPipelineState:pipeB];
                bindCommon(enc);

                for (int b = 0; b < numBuckets; b++) {
                    if (buckets[b].count == 0) continue;
                    [enc setVertexBuffer:bucketMegaBuffers[b] offset:0 atIndex:0];
                    [enc setVertexBuffer:bucketOffsetBuffers[b] offset:0 atIndex:1];

                    int bMaxQuads = buckets[b].maxVerts / 4;
                    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:bMaxQuads * 6
                                     indexType:MTLIndexTypeUInt16
                                   indexBuffer:bucketIndexBuffers[b]
                             indexBufferOffset:0
                                 instanceCount:buckets[b].count
                                    baseVertex:0
                                  baseInstance:0];
                }

                [enc endEncoding];
                __block double gt = 0;
                [cmd addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                    if (buf.GPUStartTime > 0) gt = (buf.GPUEndTime - buf.GPUStartTime) * 1000.0;
                }];
                [cmd commit]; [cmd waitUntilCompleted];
                cpuC[iter] = (double)(mach_absolute_time()-t0) * timebase.numer / timebase.denom / 1e6;
                gpuC[iter] = gt;
            }
        }

        // ============================================================
        // Results
        // ============================================================
        printf("\n=== Results (dropping first 10%%) ===\n\n");

        Stats sga = compute_stats(&gpuA[skip], count);
        Stats sca = compute_stats(&cpuA[skip], count);
        Stats sgb = compute_stats(&gpuB[skip], count);
        Stats scb = compute_stats(&cpuB[skip], count);
        Stats sgc = compute_stats(&gpuC[skip], count);
        Stats scc = compute_stats(&cpuC[skip], count);

        printf("A: Per-Chunk Draws (%d draws)\n", numChunks);
        print_stats("GPU:", sga);
        print_stats("CPU:", sca);

        printf("\nB: Instanced + Padded (1 draw, padded to max=%d verts)\n", maxVertsPerChunk);
        print_stats("GPU:", sgb);
        print_stats("CPU:", scb);

        printf("\nC: Bucketed Instanced (%d draws)\n", totalBucketDraws);
        print_stats("GPU:", sgc);
        print_stats("CPU:", scc);

        printf("\n=== Speedup vs A (per-chunk) ===\n");
        printf("  B GPU: %.2fx  CPU: %.2fx  (saved GPU %.3fms  CPU %.3fms)\n",
               sga.avg/sgb.avg, sca.avg/scb.avg, sga.avg-sgb.avg, sca.avg-scb.avg);
        printf("  C GPU: %.2fx  CPU: %.2fx  (saved GPU %.3fms  CPU %.3fms)\n",
               sga.avg/sgc.avg, sca.avg/scc.avg, sga.avg-sgc.avg, sca.avg-scc.avg);

        printf("\n=== Speedup C vs B ===\n");
        printf("  GPU: %.2fx  CPU: %.2fx\n", sgb.avg/sgc.avg, scb.avg/scc.avg);

        for (int b = 0; b < numBuckets; b++) free(buckets[b].chunkIds);
        free(metas2);

        return 0;
    }
}
