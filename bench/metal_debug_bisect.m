// metal_debug_bisect.m -- Bisect what causes instance 1 to fail
//
// Progressively adds complexity to the minimal working test until instance 1 breaks.
//
// Build:  clang -framework Metal -framework QuartzCore -framework Foundation \
//         -O2 -fobjc-arc -o metal_debug_bisect metal_debug_bisect.m

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <math.h>

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

// ============================================================
// Shader variants: each adds one more feature
// ============================================================

// V1: Simple position + color (2 buffers, no transform) -- known working
static NSString *kShaderV1 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Vert { packed_float3 position; uchar4 color; packed_float2 uv0; packed_short2 uv2; uchar4 normal; };\n"
    "struct InstU { uint slotSize; };\n"
    "struct Out { float4 position [[position]]; float4 color; };\n"
    "vertex Out v1(constant Vert* verts [[buffer(0)]], constant InstU& inst [[buffer(1)]],\n"
    "    uint vid [[vertex_id]], uint iid [[instance_id]]) {\n"
    "    uint idx = iid * inst.slotSize + vid;\n"
    "    Out out; out.position = float4(float3(verts[idx].position), 1.0);\n"
    "    out.color = float4(verts[idx].color) / 255.0; return out;\n"
    "}\n"
    "fragment float4 f1(Out in [[stage_in]]) { return in.color; }\n";

// V2: Add chunk offset (3 buffers)
static NSString *kShaderV2 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Vert { packed_float3 position; uchar4 color; packed_float2 uv0; packed_short2 uv2; uchar4 normal; };\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct InstU { uint slotSize; };\n"
    "struct Out { float4 position [[position]]; float4 color; };\n"
    "vertex Out v2(constant Vert* verts [[buffer(0)]], constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant InstU& inst [[buffer(2)]],\n"
    "    uint vid [[vertex_id]], uint iid [[instance_id]]) {\n"
    "    uint idx = iid * inst.slotSize + vid;\n"
    "    Out out;\n"
    "    float3 worldPos = float3(verts[idx].position) + float3(chunks[iid].offset);\n"
    "    out.position = float4(worldPos, 1.0);\n"
    "    out.color = float4(verts[idx].color) / 255.0; return out;\n"
    "}\n"
    "fragment float4 f2(Out in [[stage_in]]) { return in.color; }\n";

// V3: Add viewProj transform (4 buffers)
static NSString *kShaderV3 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Vert { packed_float3 position; uchar4 color; packed_float2 uv0; packed_short2 uv2; uchar4 normal; };\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms { float4x4 viewProj; float fogStart; float fogEnd; float2 _pad0;\n"
    "    float4 fogColor; float alphaThreshold; float _pad1[3]; };\n"
    "struct InstU { uint slotSize; };\n"
    "struct Out { float4 position [[position]]; float4 color; };\n"
    "vertex Out v3(constant Vert* verts [[buffer(0)]], constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]], constant InstU& inst [[buffer(3)]],\n"
    "    uint vid [[vertex_id]], uint iid [[instance_id]]) {\n"
    "    uint idx = iid * inst.slotSize + vid;\n"
    "    Out out;\n"
    "    float3 worldPos = float3(verts[idx].position) + float3(chunks[iid].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = float4(verts[idx].color) / 255.0; return out;\n"
    "}\n"
    "fragment float4 f3(Out in [[stage_in]]) { return in.color; }\n";

// V4: Add fog + full output struct (4 buffers, full TerrainOut)
static NSString *kShaderV4 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Vert { packed_float3 position; uchar4 color; packed_float2 uv0; packed_short2 uv2; uchar4 normal; };\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms { float4x4 viewProj; float fogStart; float fogEnd; float2 _pad0;\n"
    "    float4 fogColor; float alphaThreshold; float _pad1[3]; };\n"
    "struct InstU { uint slotSize; };\n"
    "struct TerrainOut { float4 position [[position]]; float4 color; float2 uv0; float2 uv2;\n"
    "    float3 normal; float fogFactor; };\n"
    "vertex TerrainOut v4(constant Vert* verts [[buffer(0)]], constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]], constant InstU& inst [[buffer(3)]],\n"
    "    uint vid [[vertex_id]], uint iid [[instance_id]]) {\n"
    "    uint idx = iid * inst.slotSize + vid;\n"
    "    constant Vert& v = verts[idx];\n"
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
    "fragment float4 f4(TerrainOut in [[stage_in]]) { return in.color; }\n";

static int test_variant(id<MTLDevice> device, id<MTLCommandQueue> queue,
                         NSString *shaderSrc, const char *vertName, const char *fragName,
                         const char *label, int numBuffers,
                         BlockVertex *verts, int numVerts, int numChunks,
                         ChunkOffset *offsets, FrameUniforms *uniforms) {
    int width = 1024, height = 1024;
    uint32_t slotSize = numVerts / numChunks;

    NSError *error = nil;
    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.languageVersion = MTLLanguageVersion2_4;
    id<MTLLibrary> lib = [device newLibraryWithSource:shaderSrc options:opts error:&error];
    if (!lib) { printf("  %s: SHADER ERROR: %s\n", label, [[error description] UTF8String]); return -1; }

    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:vertName]];
    pd.fragmentFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:fragName]];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!pipeline) { printf("  %s: PIPELINE ERROR: %s\n", label, [[error description] UTF8String]); return -1; }

    // Render targets
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
          width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> colorTex = [device newTextureWithDescriptor:td];

    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
          width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depthTex = [device newTextureWithDescriptor:td];

    // Slot buffer
    uint32_t slotBytes = slotSize * 32;
    uint32_t totalSlotBytes = numChunks * slotBytes;
    id<MTLBuffer> slotBuffer = [device newBufferWithLength:totalSlotBytes options:MTLResourceStorageModeShared];
    uint8_t *dst = (uint8_t *)[slotBuffer contents];
    memset(dst, 0, totalSlotBytes);
    for (int c = 0; c < numChunks; c++) {
        memcpy(dst + c * slotBytes, &verts[c * slotSize], slotSize * 32);
    }

    id<MTLBuffer> offsetBuffer = [device newBufferWithBytes:offsets
                                                      length:numChunks * sizeof(ChunkOffset)
                                                     options:MTLResourceStorageModeShared];

    // Index buffer (quads to triangles)
    int maxQuads = slotSize / 4;
    int numIndices = maxQuads * 6;
    uint16_t *indices = (uint16_t *)malloc(numIndices * sizeof(uint16_t));
    for (int q = 0; q < maxQuads; q++) {
        indices[q*6+0] = q*4+0; indices[q*6+1] = q*4+1; indices[q*6+2] = q*4+2;
        indices[q*6+3] = q*4+0; indices[q*6+4] = q*4+2; indices[q*6+5] = q*4+3;
    }
    id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indices length:numIndices*2 options:MTLResourceStorageModeShared];
    free(indices);

    // Render
    id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = colorTex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.depthAttachment.texture = depthTex;
    rpd.depthAttachment.loadAction = MTLLoadActionClear;
    rpd.depthAttachment.clearDepth = 1.0;
    rpd.depthAttachment.storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:pipeline];

    MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled = YES;
    [enc setDepthStencilState:[device newDepthStencilStateWithDescriptor:dd]];
    [enc setCullMode:MTLCullModeNone];

    // Bind buffers based on variant
    if (numBuffers == 2) {
        [enc setVertexBuffer:slotBuffer offset:0 atIndex:0];
        [enc setVertexBytes:&slotSize length:sizeof(slotSize) atIndex:1];
    } else if (numBuffers == 3) {
        [enc setVertexBuffer:slotBuffer offset:0 atIndex:0];
        [enc setVertexBuffer:offsetBuffer offset:0 atIndex:1];
        [enc setVertexBytes:&slotSize length:sizeof(slotSize) atIndex:2];
    } else if (numBuffers == 4) {
        [enc setVertexBuffer:slotBuffer offset:0 atIndex:0];
        [enc setVertexBuffer:offsetBuffer offset:0 atIndex:1];
        [enc setVertexBytes:uniforms length:sizeof(FrameUniforms) atIndex:2];
        [enc setVertexBytes:&slotSize length:sizeof(slotSize) atIndex:3];
    }

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

    // Read back
    uint8_t *pixels = (uint8_t *)malloc(width * height * 4);
    [colorTex getBytes:pixels bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    int nonBlack = 0, redCount = 0, greenCount = 0;
    for (int p = 0; p < width * height; p++) {
        uint8_t *px = &pixels[p * 4];  // BGRA
        if (px[0] || px[1] || px[2] || px[3]) {
            nonBlack++;
            uint8_t b = px[0], g = px[1], r = px[2];
            if (r > g && r > b) redCount++;
            else if (g > r && g > b) greenCount++;
        }
    }
    free(pixels);

    const char *status;
    if (redCount > 0 && greenCount > 0) status = "PASS (both instances)";
    else if (redCount > 0) status = "PARTIAL (instance 0 only)";
    else if (greenCount > 0) status = "PARTIAL (instance 1 only)";
    else if (nonBlack > 0) status = "PARTIAL (no distinct colors)";
    else status = "FAIL (nothing)";
    printf("  %s: %d px (red=%d, green=%d) -> %s\n", label, nonBlack, redCount, greenCount, status);
    return nonBlack;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];

        printf("=== Instanced Rendering Bisection Test ===\n");
        printf("Device: %s\n\n", [[device name] UTF8String]);

        int numChunks = 2;
        int vertsPerChunk = 8;
        int totalVerts = numChunks * vertsPerChunk;

        // Generate vertex data
        BlockVertex verts[16];
        ChunkOffset offsets[2];

        // NDC-space coordinates for V1/V2 (no projection)
        // Chunk 0: left side, red-ish
        for (int v = 0; v < 8; v++) {
            int q = v / 4, vi = v % 4;
            float dx = (vi & 1) ? 0.3f : 0.0f;
            float dy = (vi & 2) ? 0.3f : 0.0f;
            verts[v].x = -0.8f + (float)q * 0.4f + dx;
            verts[v].y = -0.4f + dy;
            verts[v].z = 0.5f;
            verts[v].cr = 255; verts[v].cg = 0; verts[v].cb = 0; verts[v].ca = 255;
            verts[v].u0 = 0; verts[v].v0 = 0;
            verts[v].u2 = 240; verts[v].v2 = 240;
            verts[v].nx = 0; verts[v].ny = 127; verts[v].nz = 0; verts[v].nw = 0;
        }
        // Chunk 1: right side, green
        for (int v = 0; v < 8; v++) {
            int q = v / 4, vi = v % 4;
            float dx = (vi & 1) ? 0.3f : 0.0f;
            float dy = (vi & 2) ? 0.3f : 0.0f;
            verts[8+v].x = 0.2f + (float)q * 0.4f + dx;
            verts[8+v].y = -0.4f + dy;
            verts[8+v].z = 0.5f;
            verts[8+v].cr = 0; verts[8+v].cg = 255; verts[8+v].cb = 0; verts[8+v].ca = 255;
            verts[8+v].u0 = 0; verts[8+v].v0 = 0;
            verts[8+v].u2 = 240; verts[8+v].v2 = 240;
            verts[8+v].nx = 0; verts[8+v].ny = 127; verts[8+v].nz = 0; verts[8+v].nw = 0;
        }

        offsets[0] = (ChunkOffset){{ 0.0f, 0.0f, 0.0f }, 0.0f};
        offsets[1] = (ChunkOffset){{ 0.0f, 0.0f, 0.0f }, 0.0f};  // no offset for NDC tests

        FrameUniforms uniforms;
        memset(&uniforms, 0, sizeof(uniforms));
        // Identity matrix for V3 without projection
        uniforms.viewProj[0] = 1.0f;
        uniforms.viewProj[5] = 1.0f;
        uniforms.viewProj[10] = 1.0f;
        uniforms.viewProj[15] = 1.0f;
        uniforms.fogStart = 100.0f;
        uniforms.fogEnd = 200.0f;
        uniforms.fogColor[0] = 0.7f; uniforms.fogColor[1] = 0.8f;
        uniforms.fogColor[2] = 1.0f; uniforms.fogColor[3] = 1.0f;
        uniforms.alphaThreshold = 0.0f;

        printf("Test with NDC coordinates (no projection needed):\n");
        test_variant(device, queue, kShaderV1, "v1", "f1", "V1 (2 bufs, no offset)",
                     2, verts, totalVerts, numChunks, offsets, &uniforms);
        test_variant(device, queue, kShaderV2, "v2", "f2", "V2 (3 bufs, +offset)",
                     3, verts, totalVerts, numChunks, offsets, &uniforms);
        test_variant(device, queue, kShaderV3, "v3", "f3", "V3 (4 bufs, +identity viewProj)",
                     4, verts, totalVerts, numChunks, offsets, &uniforms);
        test_variant(device, queue, kShaderV4, "v4", "f4", "V4 (4 bufs, +fog, full output)",
                     4, verts, totalVerts, numChunks, offsets, &uniforms);

        // Now test with perspective projection and world-space coords
        printf("\nTest with world-space coordinates + perspective projection:\n");

        // Regenerate vertices in world space (within 16x16x16 chunk sections)
        for (int c = 0; c < 2; c++) {
            for (int v = 0; v < 8; v++) {
                int q = v / 4, vi = v % 4;
                float dx = (vi & 1) ? 1.0f : 0.0f;
                float dy = (vi & 2) ? 1.0f : 0.0f;
                float bx = (float)((q * 7) % 14) + 1.0f;
                float by = (float)((q * 3) % 14) + 1.0f;
                float bz = (float)((q * 11) % 14) + 1.0f;
                verts[c*8+v].x = bx + dx;
                verts[c*8+v].y = by + dy;
                verts[c*8+v].z = bz;
                verts[c*8+v].cr = c == 0 ? 255 : 0;
                verts[c*8+v].cg = c == 0 ? 0 : 255;
                verts[c*8+v].cb = 0;
                verts[c*8+v].ca = 255;
            }
        }

        offsets[0] = (ChunkOffset){{ 0.0f, 0.0f, -64.0f }, 0.0f};
        offsets[1] = (ChunkOffset){{ 32.0f, 0.0f, -64.0f }, 0.0f};

        generate_viewproj(uniforms.viewProj);

        test_variant(device, queue, kShaderV3, "v3", "f3", "V3 (perspective, world coords)",
                     4, verts, totalVerts, numChunks, offsets, &uniforms);
        test_variant(device, queue, kShaderV4, "v4", "f4", "V4 (perspective, full shader)",
                     4, verts, totalVerts, numChunks, offsets, &uniforms);

        // Test: render each instance separately with single draw calls
        printf("\nTest: render instances separately with perspective:\n");
        for (int testInst = 0; testInst < 2; testInst++) {
            NSError *error = nil;
            MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
            opts.languageVersion = MTLLanguageVersion2_4;
            id<MTLLibrary> lib = [device newLibraryWithSource:kShaderV3 options:opts error:&error];
            MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
            pd.vertexFunction = [lib newFunctionWithName:@"v3"];
            pd.fragmentFunction = [lib newFunctionWithName:@"f3"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];

            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                  width:1024 height:1024 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> ct = [device newTextureWithDescriptor:td];
            td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                  width:1024 height:1024 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> dt = [device newTextureWithDescriptor:td];

            uint32_t slotSz = vertsPerChunk;
            uint32_t slotByteSz = slotSz * 32;
            id<MTLBuffer> sb = [device newBufferWithLength:2 * slotByteSz options:MTLResourceStorageModeShared];
            memset([sb contents], 0, 2 * slotByteSz);
            memcpy((uint8_t*)[sb contents] + 0, &verts[0], 8 * 32);
            memcpy((uint8_t*)[sb contents] + slotByteSz, &verts[8], 8 * 32);

            id<MTLBuffer> ob = [device newBufferWithBytes:offsets length:2*sizeof(ChunkOffset) options:MTLResourceStorageModeShared];

            int maxQ = 2; int nIdx = maxQ * 6;
            uint16_t idx2[12] = { 0,1,2, 0,2,3, 4,5,6, 4,6,7 };
            id<MTLBuffer> ib = [device newBufferWithBytes:idx2 length:24 options:MTLResourceStorageModeShared];

            MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
            dd.depthCompareFunction = MTLCompareFunctionLess;
            dd.depthWriteEnabled = YES;
            id<MTLDepthStencilState> ds = [device newDepthStencilStateWithDescriptor:dd];

            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = ct;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rpd.depthAttachment.texture = dt;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeline];
            [enc setDepthStencilState:ds];
            [enc setCullMode:MTLCullModeNone];

            [enc setVertexBuffer:sb offset:0 atIndex:0];
            [enc setVertexBuffer:ob offset:0 atIndex:1];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
            [enc setVertexBytes:&slotSz length:sizeof(slotSz) atIndex:3];

            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:nIdx
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:ib
                     indexBufferOffset:0
                         instanceCount:1
                            baseVertex:0
                          baseInstance:testInst];

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];

            uint8_t *px = (uint8_t *)malloc(1024*1024*4);
            [ct getBytes:px bytesPerRow:1024*4 fromRegion:MTLRegionMake2D(0, 0, 1024, 1024) mipmapLevel:0];
            int nb = 0;
            for (int p = 0; p < 1024*1024; p++) {
                if (px[p*4] || px[p*4+1] || px[p*4+2] || px[p*4+3]) nb++;
            }
            printf("  Instance %d alone (baseInstance=%d): %d non-black pixels\n", testInst, testInst, nb);
            free(px);
        }

        // Test: render instance 1's data as instance 0 (with its own offset)
        printf("\nTest: render chunk 1 data at slot 0 with chunk 1 offset:\n");
        {
            NSError *error = nil;
            MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
            opts.languageVersion = MTLLanguageVersion2_4;
            id<MTLLibrary> lib = [device newLibraryWithSource:kShaderV3 options:opts error:&error];
            MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
            pd.vertexFunction = [lib newFunctionWithName:@"v3"];
            pd.fragmentFunction = [lib newFunctionWithName:@"f3"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];

            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                  width:1024 height:1024 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> ct = [device newTextureWithDescriptor:td];
            td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                  width:1024 height:1024 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> dt = [device newTextureWithDescriptor:td];

            // Put chunk 1 data at slot 0
            uint32_t slotSz = vertsPerChunk;
            id<MTLBuffer> sb = [device newBufferWithLength:slotSz * 32 options:MTLResourceStorageModeShared];
            memcpy([sb contents], &verts[8], 8 * 32);

            // Use chunk 1's offset
            id<MTLBuffer> ob = [device newBufferWithBytes:&offsets[1] length:sizeof(ChunkOffset) options:MTLResourceStorageModeShared];

            uint16_t idx2[12] = { 0,1,2, 0,2,3, 4,5,6, 4,6,7 };
            id<MTLBuffer> ib = [device newBufferWithBytes:idx2 length:24 options:MTLResourceStorageModeShared];

            MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
            dd.depthCompareFunction = MTLCompareFunctionLess;
            dd.depthWriteEnabled = YES;
            id<MTLDepthStencilState> ds = [device newDepthStencilStateWithDescriptor:dd];

            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = ct;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            rpd.depthAttachment.texture = dt;
            rpd.depthAttachment.loadAction = MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 1.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeline];
            [enc setDepthStencilState:ds];
            [enc setCullMode:MTLCullModeNone];

            [enc setVertexBuffer:sb offset:0 atIndex:0];
            [enc setVertexBuffer:ob offset:0 atIndex:1];
            [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
            [enc setVertexBytes:&slotSz length:sizeof(slotSz) atIndex:3];

            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:12
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:ib
                     indexBufferOffset:0
                         instanceCount:1
                            baseVertex:0
                          baseInstance:0];

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];

            uint8_t *px = (uint8_t *)malloc(1024*1024*4);
            [ct getBytes:px bytesPerRow:1024*4 fromRegion:MTLRegionMake2D(0, 0, 1024, 1024) mipmapLevel:0];
            int nb = 0;
            for (int p = 0; p < 1024*1024; p++) {
                if (px[p*4] || px[p*4+1] || px[p*4+2] || px[p*4+3]) nb++;
            }
            printf("  Chunk 1 at slot 0 (instance 0): %d non-black pixels\n", nb);
            free(px);
        }

        return 0;
    }
}
