// metal_bench_validate.m -- Correctness validation for instanced rendering
//
// Renders a scene two ways:
//   A) Per-chunk draws with [[stage_in]] vertex descriptor (known correct)
//   B) Instanced with manual buffer indexing (production approach)
//
// Compares pixel output to verify instanced rendering is correct.
//
// Build:  clang -framework Metal -framework QuartzCore -framework Foundation \
//         -O2 -fobjc-arc -o metal_bench_validate metal_bench_validate.m
// Run:    ./metal_bench_validate [--chunks N]

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <math.h>

// ============================================================
// Structs (must match production metal_terrain.m)
// ============================================================

typedef struct {
    float x, y, z;
    uint8_t cr, cg, cb, ca;
    float u0, v0;
    int16_t u2, v2;
    uint8_t nx, ny, nz, nw;
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
// Shader source -- both approaches in one library
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
    // Approach A: per-chunk with [[stage_in]]
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
    // Approach B: instanced with manual buffer indexing (production)
    "struct BlockVertexRaw {\n"
    "    packed_float3 position;\n"
    "    uchar4 color;\n"
    "    packed_float2 uv0;\n"
    "    packed_short2 uv2;\n"
    "    uchar4 normal;\n"
    "};\n"
    "\n"
    "struct InstUniforms {\n"
    "    uint slotSize;\n"
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
    // Simple fragment: just output vertex color (no textures needed for validation)
    "fragment float4 terrain_fragment_simple(\n"
    "    TerrainOut in [[stage_in]]\n"
    ") {\n"
    "    float4 color = in.color;\n"
    "    color.rgb = mix(float3(0.7, 0.8, 1.0), color.rgb, in.fogFactor);\n"
    "    return color;\n"
    "}\n"
    "\n"
    // Debug vertex: hardcode positions, output iid as color
    "vertex TerrainOut terrain_vertex_debug(\n"
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
    "    // Encode debug info as color\n"
    "    out.color = float4(float(iid) / 4.0, float(inst.slotSize) / 256.0, float(idx) / 1024.0, 1.0);\n"
    "    out.uv0 = float2(0);\n"
    "    out.uv2 = float2(0);\n"
    "    out.normal = float3(0, 1, 0);\n"
    "    out.fogFactor = 1.0;\n"
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int numChunks = 8;  // Small for validation
        int vertsPerChunk = 200;  // Uniform for easier validation

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--chunks") == 0 && i+1 < argc) numChunks = atoi(argv[++i]);
            if (strcmp(argv[i], "--verts") == 0 && i+1 < argc) vertsPerChunk = atoi(argv[++i]);
        }

        // Must be multiple of 4 for quads
        vertsPerChunk = (vertsPerChunk / 4) * 4;

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "No Metal device\n"); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];

        int width = 512, height = 512;

        printf("=== Metal Instanced Rendering Correctness Validation ===\n");
        printf("Device: %s\n", [[device name] UTF8String]);
        printf("Chunks: %d  Verts/chunk: %d  Resolution: %dx%d\n\n",
               numChunks, vertsPerChunk, width, height);

        // Compile shaders
        NSError *error = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;
        id<MTLLibrary> library = [device newLibraryWithSource:kShaderSource options:opts error:&error];
        if (!library) {
            fprintf(stderr, "Shader compilation error: %s\n", [[error description] UTF8String]);
            return 1;
        }
        printf("[OK] Shaders compiled\n");

        MTLVertexDescriptor *vd = make_vertex_descriptor();

        // Pipeline A: per-chunk with vertex descriptor
        MTLRenderPipelineDescriptor *pdA = [[MTLRenderPipelineDescriptor alloc] init];
        pdA.vertexFunction = [library newFunctionWithName:@"terrain_vertex_batched"];
        pdA.fragmentFunction = [library newFunctionWithName:@"terrain_fragment_simple"];
        pdA.vertexDescriptor = vd;
        pdA.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pdA.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> pipeA = [device newRenderPipelineStateWithDescriptor:pdA error:&error];
        if (!pipeA) { fprintf(stderr, "Pipeline A error: %s\n", [[error description] UTF8String]); return 1; }

        // Pipeline B: instanced with NO vertex descriptor (manual indexing)
        MTLRenderPipelineDescriptor *pdB = [[MTLRenderPipelineDescriptor alloc] init];
        pdB.vertexFunction = [library newFunctionWithName:@"terrain_vertex_instanced"];
        pdB.fragmentFunction = [library newFunctionWithName:@"terrain_fragment_simple"];
        // No vertex descriptor -- shader reads from raw buffer
        pdB.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pdB.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> pipeB = [device newRenderPipelineStateWithDescriptor:pdB error:&error];
        if (!pipeB) { fprintf(stderr, "Pipeline B error: %s\n", [[error description] UTF8String]); return 1; }

        printf("[OK] Pipelines created\n");

        // Depth state
        MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
        dd.depthCompareFunction = MTLCompareFunctionLess;
        dd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:dd];

        // Render targets (two color targets to compare)
        MTLTextureDescriptor *td;
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;  // Need to read back
        id<MTLTexture> colorA = [device newTextureWithDescriptor:td];
        id<MTLTexture> colorB = [device newTextureWithDescriptor:td];

        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depthTex = [device newTextureWithDescriptor:td];

        // Generate deterministic vertex data
        srand(42);  // Fixed seed for reproducibility
        int totalVerts = numChunks * vertsPerChunk;

        // Per-chunk vertex buffers for approach A
        id<MTLBuffer> chunkBuffers[numChunks];
        ChunkOffset offsets[numChunks];

        BlockVertex *allVerts = (BlockVertex *)calloc(totalVerts, sizeof(BlockVertex));

        for (int c = 0; c < numChunks; c++) {
            // Chunk offset: spread chunks far apart to avoid ANY overlap
            offsets[c].offset[0] = (float)(c % 4) * 32.0f;
            offsets[c].offset[1] = 0.0f;
            offsets[c].offset[2] = (float)(c / 4) * 32.0f - 64.0f;
            offsets[c]._pad = 0.0f;

            BlockVertex *chunk = &allVerts[c * vertsPerChunk];
            for (int v = 0; v < vertsPerChunk; v++) {
                int quadIdx = v / 4;
                int vertIdx = v % 4;
                // Place quads within chunk's 14x14x14 interior (no edge overlap)
                float bx = (float)((quadIdx * 7) % 14) + 1.0f;
                float by = (float)((quadIdx * 3) % 14) + 1.0f;
                float bz = (float)((quadIdx * 11) % 14) + 1.0f;
                // Quad vertex offsets (small quad face)
                float dx = (vertIdx & 1) ? 1.0f : 0.0f;
                float dy = (vertIdx & 2) ? 1.0f : 0.0f;
                chunk[v].x = bx + dx;
                chunk[v].y = by + dy;
                chunk[v].z = bz;
                chunk[v].cr = 100 + (uint8_t)(c * 15);
                chunk[v].cg = 150;
                chunk[v].cb = 200 - (uint8_t)(c * 10);
                chunk[v].ca = 255;
                chunk[v].u0 = dx;
                chunk[v].v0 = dy;
                chunk[v].u2 = 240;
                chunk[v].v2 = 240;
                chunk[v].nx = 0; chunk[v].ny = 127; chunk[v].nz = 0; chunk[v].nw = 0;
            }

            chunkBuffers[c] = [device newBufferWithBytes:chunk
                                                  length:vertsPerChunk * sizeof(BlockVertex)
                                                 options:MTLResourceStorageModeShared];
        }

        // Slot-based mega-buffer for approach B
        uint32_t slotSize = vertsPerChunk;  // All chunks same size, no padding needed
        uint32_t slotBytes = slotSize * 32;
        uint32_t totalSlotBytes = numChunks * slotBytes;

        id<MTLBuffer> slotBuffer = [device newBufferWithLength:totalSlotBytes
                                                       options:MTLResourceStorageModeShared];
        uint8_t *slotDst = (uint8_t *)[slotBuffer contents];
        memset(slotDst, 0, totalSlotBytes);

        for (int c = 0; c < numChunks; c++) {
            memcpy(slotDst + c * slotBytes,
                   &allVerts[c * vertsPerChunk],
                   vertsPerChunk * sizeof(BlockVertex));
        }

        // (reversed buffer test moved below after uniforms/indexBuffer are created)

        id<MTLBuffer> offsetBuffer = [device newBufferWithBytes:offsets
                                                         length:numChunks * sizeof(ChunkOffset)
                                                        options:MTLResourceStorageModeShared];

        // Quad-to-triangle index buffer
        int maxQuads = vertsPerChunk / 4;
        int numIndices = maxQuads * 6;
        uint16_t *indices = (uint16_t *)malloc(numIndices * sizeof(uint16_t));
        for (int q = 0; q < maxQuads; q++) {
            indices[q * 6 + 0] = (uint16_t)(q * 4 + 0);
            indices[q * 6 + 1] = (uint16_t)(q * 4 + 1);
            indices[q * 6 + 2] = (uint16_t)(q * 4 + 2);
            indices[q * 6 + 3] = (uint16_t)(q * 4 + 0);
            indices[q * 6 + 4] = (uint16_t)(q * 4 + 2);
            indices[q * 6 + 5] = (uint16_t)(q * 4 + 3);
        }
        id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indices
                                                        length:numIndices * sizeof(uint16_t)
                                                       options:MTLResourceStorageModeShared];
        free(indices);

        // Frame uniforms
        FrameUniforms uniforms;
        generate_viewproj(uniforms.viewProj);
        uniforms.fogStart = 100.0f;
        uniforms.fogEnd = 200.0f;
        uniforms._pad0[0] = 0; uniforms._pad0[1] = 0;
        uniforms.fogColor[0] = 0.7f; uniforms.fogColor[1] = 0.8f;
        uniforms.fogColor[2] = 1.0f; uniforms.fogColor[3] = 1.0f;
        uniforms.alphaThreshold = 0.0f;
        uniforms._pad1[0] = 0; uniforms._pad1[1] = 0; uniforms._pad1[2] = 0;

        printf("[OK] Data generated (%d chunks, %d verts/chunk, %d total verts)\n",
               numChunks, vertsPerChunk, totalVerts);

        // Debug: verify slot buffer contents
        printf("\n[DEBUG] Slot buffer verification:\n");
        printf("  slotSize=%u verts, slotBytes=%u, totalSlotBytes=%u\n",
               slotSize, slotBytes, totalSlotBytes);
        BlockVertex *slotVerts = (BlockVertex *)[slotBuffer contents];
        for (int c = 0; c < numChunks && c < 4; c++) {
            BlockVertex *v0 = &slotVerts[c * slotSize];
            printf("  Slot %d: vert[0] pos=(%.1f, %.1f, %.1f) color=(%d,%d,%d,%d)\n",
                   c, v0->x, v0->y, v0->z, v0->cr, v0->cg, v0->cb, v0->ca);
            printf("          offset=(%.1f, %.1f, %.1f)\n",
                   offsets[c].offset[0], offsets[c].offset[1], offsets[c].offset[2]);
            printf("          world pos=(%.1f, %.1f, %.1f)\n",
                   v0->x + offsets[c].offset[0], v0->y + offsets[c].offset[1],
                   v0->z + offsets[c].offset[2]);
        }
        printf("\n");

        // ============================================================
        // Render A: per-chunk draws
        // ============================================================
        {
            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorA;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rpd.depthAttachment.texture = depthTex;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeA];
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeBack];
            [enc setFrontFacingWinding:MTLWindingCounterClockwise];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];

            for (int c = 0; c < numChunks; c++) {
                [enc setVertexBuffer:chunkBuffers[c] offset:0 atIndex:0];
                [enc setVertexBytes:&offsets[c] length:sizeof(ChunkOffset) atIndex:1];
                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:numIndices
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:indexBuffer
                         indexBufferOffset:0];
            }

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
        }
        printf("[OK] Approach A rendered (%d per-chunk draws)\n", numChunks);

        // ============================================================
        // Render B: single instanced draw with manual buffer indexing
        // ============================================================
        {
            // Need to re-clear depth for fair comparison
            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorB;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rpd.depthAttachment.texture = depthTex;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeB];
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeBack];
            [enc setFrontFacingWinding:MTLWindingCounterClockwise];

            [enc setVertexBuffer:slotBuffer offset:0 atIndex:0];
            [enc setVertexBuffer:offsetBuffer offset:0 atIndex:1];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];

            // Use a proper buffer for InstUniforms instead of setVertexBytes
            uint32_t instSlotSize = slotSize;
            id<MTLBuffer> instBuf = [device newBufferWithBytes:&instSlotSize
                                                        length:sizeof(instSlotSize)
                                                       options:MTLResourceStorageModeShared];
            [enc setVertexBuffer:instBuf offset:0 atIndex:3];

            printf("[DEBUG] instSlotSize=%u, buffer length=%lu\n", instSlotSize, sizeof(instSlotSize));

            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:numIndices
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:indexBuffer
                     indexBufferOffset:0
                         instanceCount:numChunks
                            baseVertex:0
                          baseInstance:0];

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
        }
        printf("[OK] Approach B rendered (1 instanced draw, %d instances, NO CULL)\n", numChunks);

        // Reversed buffer test: chunk 1 data in slot 0, chunk 0 data in slot 1
        if (numChunks == 2) {
            id<MTLBuffer> slotBufferRev = [device newBufferWithLength:totalSlotBytes
                                                               options:MTLResourceStorageModeShared];
            uint8_t *revDst = (uint8_t *)[slotBufferRev contents];
            memset(revDst, 0, totalSlotBytes);
            memcpy(revDst + 0, &allVerts[1 * vertsPerChunk], vertsPerChunk * sizeof(BlockVertex));
            memcpy(revDst + slotBytes, &allVerts[0 * vertsPerChunk], vertsPerChunk * sizeof(BlockVertex));

            ChunkOffset revOffsets[2] = { offsets[1], offsets[0] };
            id<MTLBuffer> revOffBuf = [device newBufferWithBytes:revOffsets
                                                           length:2 * sizeof(ChunkOffset)
                                                          options:MTLResourceStorageModeShared];

            MTLTextureDescriptor *td3 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                  width:width height:height mipmapped:NO];
            td3.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td3.storageMode = MTLStorageModeShared;
            id<MTLTexture> colorRev = [device newTextureWithDescriptor:td3];

            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorRev;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rpd.depthAttachment.texture = depthTex;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeB];
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeNone];

            [enc setVertexBuffer:slotBufferRev offset:0 atIndex:0];
            [enc setVertexBuffer:revOffBuf offset:0 atIndex:1];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
            uint32_t ss = slotSize;
            [enc setVertexBytes:&ss length:sizeof(ss) atIndex:3];

            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:numIndices
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:indexBuffer
                     indexBufferOffset:0
                         instanceCount:2
                            baseVertex:0
                          baseInstance:0];

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];

            uint8_t *pixelsR = (uint8_t *)malloc(width * height * 4);
            [colorRev getBytes:pixelsR bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            int nonBlackR = 0;
            for (int p = 0; p < width * height; p++) {
                uint8_t *px = &pixelsR[p * 4];
                if (px[0] || px[1] || px[2] || px[3]) nonBlackR++;
            }
            printf("[DEBUG] Reversed buffer: %d non-black pixels (expect ~45 if both instances work)\n", nonBlackR);
            free(pixelsR);
        }

        // ============================================================
        // Render C: instance 1 only (debug: does the GPU see slot 1 data?)
        // ============================================================
        id<MTLTexture> colorC;
        {
            MTLTextureDescriptor *td2 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                  width:width height:height mipmapped:NO];
            td2.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td2.storageMode = MTLStorageModeShared;
            colorC = [device newTextureWithDescriptor:td2];

            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorC;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rpd.depthAttachment.texture = depthTex;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeB];
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeBack];
            [enc setFrontFacingWinding:MTLWindingCounterClockwise];

            // Bind full slot buffer but start from instance 1
            [enc setVertexBuffer:slotBuffer offset:0 atIndex:0];
            [enc setVertexBuffer:offsetBuffer offset:0 atIndex:1];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
            uint32_t instSlotSize = slotSize;
            [enc setVertexBytes:&instSlotSize length:sizeof(instSlotSize) atIndex:3];

            // Draw only instance 1
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:numIndices
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:indexBuffer
                     indexBufferOffset:0
                         instanceCount:1
                            baseVertex:0
                          baseInstance:1];

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
        }

        // Render D: debug shader (outputs iid, slotSize, idx as color)
        {
            id<MTLFunction> vertDebug = [library newFunctionWithName:@"terrain_vertex_debug"];
            id<MTLFunction> fragSimple = [library newFunctionWithName:@"terrain_fragment_simple"];
            MTLRenderPipelineDescriptor *pdD = [[MTLRenderPipelineDescriptor alloc] init];
            pdD.vertexFunction = vertDebug;
            pdD.fragmentFunction = fragSimple;
            pdD.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pdD.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            id<MTLRenderPipelineState> pipeD = [device newRenderPipelineStateWithDescriptor:pdD error:&error];
            if (!pipeD) {
                printf("[ERROR] Debug pipeline: %s\n", [[error description] UTF8String]);
            } else {
                id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
                MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                rpd.colorAttachments[0].texture = colorB;  // reuse B's target
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
                rpd.depthAttachment.texture = depthTex;
                rpd.depthAttachment.loadAction = MTLLoadActionClear;
                rpd.depthAttachment.clearDepth = 1.0;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;

                id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
                [enc setRenderPipelineState:pipeD];
                [enc setDepthStencilState:depthState];
                [enc setCullMode:MTLCullModeNone];

                [enc setVertexBuffer:slotBuffer offset:0 atIndex:0];
                [enc setVertexBuffer:offsetBuffer offset:0 atIndex:1];
                [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
                uint32_t instSlotSize2 = slotSize;
                id<MTLBuffer> instBuf2 = [device newBufferWithBytes:&instSlotSize2
                                                              length:sizeof(instSlotSize2)
                                                             options:MTLResourceStorageModeShared];
                [enc setVertexBuffer:instBuf2 offset:0 atIndex:3];

                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:numIndices
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:indexBuffer
                         indexBufferOffset:0
                             instanceCount:numChunks
                                baseVertex:0
                              baseInstance:0];

                [enc endEncoding];
                [cmdBuf commit];
                [cmdBuf waitUntilCompleted];

                // Read back and analyze debug colors
                uint8_t *pixelsD = (uint8_t *)malloc(width * height * 4);
                [colorB getBytes:pixelsD bytesPerRow:width*4
                      fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

                printf("[DEBUG] Render D (debug shader) pixel analysis:\n");
                int inst0_count = 0, inst1_count = 0, other_count = 0;
                for (int p = 0; p < width * height; p++) {
                    // BGRA format: B=pixelsD[0], G=pixelsD[1], R=pixelsD[2], A=pixelsD[3]
                    uint8_t b = pixelsD[p * 4 + 0];
                    uint8_t g = pixelsD[p * 4 + 1];
                    uint8_t r = pixelsD[p * 4 + 2];
                    uint8_t a = pixelsD[p * 4 + 3];
                    if (a == 0) continue;
                    // r = iid / 4.0 * 255 -> iid 0 = r=0, iid 1 = r=64
                    // g = slotSize / 256.0 * 255 -> slotSize 8 = g~8
                    if (r == 0) inst0_count++;
                    else if (r > 50) inst1_count++;
                    else other_count++;

                    // Print first few non-black pixels with decoded info
                    if (inst0_count + inst1_count + other_count <= 5) {
                        float decoded_iid = r / 255.0f * 4.0f;
                        float decoded_slot = g / 255.0f * 256.0f;
                        float decoded_idx = b / 255.0f * 1024.0f;
                        printf("  pixel (%d,%d): BGRA=(%d,%d,%d,%d) -> iid=%.1f slotSize=%.0f idx=%.0f\n",
                               p % width, p / width, b, g, r, a,
                               decoded_iid, decoded_slot, decoded_idx);
                    }
                }
                printf("  Instance 0 pixels: %d\n", inst0_count);
                printf("  Instance 1 pixels: %d\n", inst1_count);
                printf("  Other pixels:      %d\n\n", other_count);
                free(pixelsD);
            }
        }

        // Check if instance 1 alone renders anything
        {
            uint32_t bpr = width * 4;
            uint32_t tb = bpr * height;
            int tp = width * height;
            uint8_t *pixelsC = (uint8_t *)malloc(tb);
            [colorC getBytes:pixelsC bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            int nonBlackC = 0;
            for (int p = 0; p < tp; p++) {
                uint8_t *px = &pixelsC[p * 4];
                if (px[0] || px[1] || px[2] || px[3]) nonBlackC++;
            }
            printf("[DEBUG] Render C (instance 1 only, baseInstance=1): %d non-black pixels\n\n", nonBlackC);
            free(pixelsC);
        }

        // ============================================================
        // Compare pixel output
        // ============================================================
        uint32_t bytesPerRow = width * 4;
        uint32_t totalBytes = bytesPerRow * height;
        uint8_t *pixelsA = (uint8_t *)malloc(totalBytes);
        uint8_t *pixelsB = (uint8_t *)malloc(totalBytes);

        [colorA getBytes:pixelsA bytesPerRow:bytesPerRow fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [colorB getBytes:pixelsB bytesPerRow:bytesPerRow fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        int exactMatch = 0;
        int closeMatch = 0;  // within 1/255 (rounding)
        int mismatch = 0;
        int nonBlackA = 0;
        int nonBlackB = 0;
        int maxDiff = 0;
        int totalPixels = width * height;

        for (int p = 0; p < totalPixels; p++) {
            uint8_t *a = &pixelsA[p * 4];
            uint8_t *b = &pixelsB[p * 4];

            if (a[0] || a[1] || a[2] || a[3]) nonBlackA++;
            if (b[0] || b[1] || b[2] || b[3]) nonBlackB++;

            bool exact = (a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3]);
            if (exact) {
                exactMatch++;
            } else {
                int dr = abs((int)a[0] - (int)b[0]);
                int dg = abs((int)a[1] - (int)b[1]);
                int db = abs((int)a[2] - (int)b[2]);
                int da = abs((int)a[3] - (int)b[3]);
                int md = dr > dg ? dr : dg;
                md = md > db ? md : db;
                md = md > da ? md : da;
                if (md > maxDiff) maxDiff = md;
                if (md <= 1) {
                    closeMatch++;
                } else {
                    mismatch++;
                    if (mismatch <= 10) {
                        int x = p % width, y = p / width;
                        printf("  MISMATCH at (%d,%d): A=(%d,%d,%d,%d) B=(%d,%d,%d,%d) diff=%d\n",
                               x, y, a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3], md);
                    }
                }
            }
        }

        printf("\n=== RESULTS ===\n");
        printf("Total pixels:    %d\n", totalPixels);
        printf("Non-black A:     %d (%.1f%%)\n", nonBlackA, 100.0 * nonBlackA / totalPixels);
        printf("Non-black B:     %d (%.1f%%)\n", nonBlackB, 100.0 * nonBlackB / totalPixels);
        printf("Exact match:     %d (%.2f%%)\n", exactMatch, 100.0 * exactMatch / totalPixels);
        printf("Close match (1): %d (%.2f%%)\n", closeMatch, 100.0 * closeMatch / totalPixels);
        printf("Mismatch (>1):   %d (%.4f%%)\n", mismatch, 100.0 * mismatch / totalPixels);
        printf("Max diff:        %d/255\n", maxDiff);

        if (mismatch == 0) {
            printf("\n>>> PASS: Instanced rendering matches per-chunk rendering <<<\n");
        } else {
            printf("\n>>> FAIL: %d pixels differ by more than 1/255 <<<\n", mismatch);
        }

        free(pixelsA);
        free(pixelsB);
        free(allVerts);

        // Also run performance comparison
        printf("\n=== Performance Comparison ===\n");
        int perfIters = 100;

        // Approach A timing
        double aGpuTimes[perfIters];
        for (int iter = 0; iter < perfIters; iter++) {
            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorA;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rpd.depthAttachment.texture = depthTex;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeA];
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeBack];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
            for (int c = 0; c < numChunks; c++) {
                [enc setVertexBuffer:chunkBuffers[c] offset:0 atIndex:0];
                [enc setVertexBytes:&offsets[c] length:sizeof(ChunkOffset) atIndex:1];
                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:numIndices indexType:MTLIndexTypeUInt16
                               indexBuffer:indexBuffer indexBufferOffset:0];
            }
            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
            aGpuTimes[iter] = (cmdBuf.GPUEndTime - cmdBuf.GPUStartTime) * 1000.0;
        }

        // Approach B timing
        double bGpuTimes[perfIters];
        for (int iter = 0; iter < perfIters; iter++) {
            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorB;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rpd.depthAttachment.texture = depthTex;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeB];
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeBack];
            [enc setVertexBuffer:slotBuffer offset:0 atIndex:0];
            [enc setVertexBuffer:offsetBuffer offset:0 atIndex:1];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
            uint32_t instSlotSize = slotSize;
            [enc setVertexBytes:&instSlotSize length:sizeof(instSlotSize) atIndex:3];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:numIndices indexType:MTLIndexTypeUInt16
                           indexBuffer:indexBuffer indexBufferOffset:0
                         instanceCount:numChunks baseVertex:0 baseInstance:0];
            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
            bGpuTimes[iter] = (cmdBuf.GPUEndTime - cmdBuf.GPUStartTime) * 1000.0;
        }

        // Compute stats (skip warmup)
        int skip = 10;
        int count = perfIters - skip;
        double aSum = 0, bSum = 0;
        for (int i = skip; i < perfIters; i++) { aSum += aGpuTimes[i]; bSum += bGpuTimes[i]; }
        double aAvg = aSum / count, bAvg = bSum / count;
        printf("A (per-chunk, %d draws): avg=%.3fms\n", numChunks, aAvg);
        printf("B (instanced, 1 draw):   avg=%.3fms\n", bAvg);
        printf("Speedup: %.2fx\n", aAvg / bAvg);

        return (mismatch > 0) ? 1 : 0;
    }
}
