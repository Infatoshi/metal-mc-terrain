// metal_bench_bandwidth.m -- Vertex data layout & bandwidth benchmark
//
// Slot-based instancing pads each chunk to maxVertexCount, wasting ~97% of
// bandwidth on zero-padded degenerate triangles. This benchmark tests whether
// eliminating that waste (tight packing) improves GPU performance.
//
// Variants:
//   V0: Slot-based instanced (current production) -- 1 draw, N instances
//   V1: Tight-packed 32B (chunkId in vertex) -- 1 draw, no instancing
//   V2: Tight-packed 20B (compressed + chunkId) -- 1 draw, no instancing
//
// Build: clang -framework Metal -framework QuartzCore -framework Foundation \
//        -O2 -fobjc-arc -o metal_bench_bandwidth metal_bench_bandwidth.m
// Run:   ./metal_bench_bandwidth [--chunks N] [--iterations N]

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <math.h>
#include <string.h>
#include <mach/mach_time.h>

// ============================================================
// C-side vertex structs
// ============================================================

typedef struct {
    float x, y, z;
    uint8_t cr, cg, cb, ca;
    float u0, v0;
    int16_t u2, v2;
    uint8_t nx, ny, nz, nw;
} __attribute__((packed)) Vert32;
_Static_assert(sizeof(Vert32) == 32, "Vert32 must be 32 bytes");

typedef struct {
    float x, y, z;
    uint8_t cr, cg, cb, ca;
    float u0, v0;
    int16_t u2, v2;
    uint16_t chunkId;
    uint16_t _pad;
} __attribute__((packed)) Vert32T;
_Static_assert(sizeof(Vert32T) == 32, "Vert32T must be 32 bytes");

typedef struct {
    uint16_t px, py, pz;     // half-float position
    uint16_t chunkId;
    uint8_t cr, cg, cb, ca;
    uint16_t u0x, u0y;       // half-float atlas UV
    uint8_t u2x, u2y;        // lightmap UV
    uint8_t _pad[2];
} __attribute__((packed)) Vert20T;
_Static_assert(sizeof(Vert20T) == 20, "Vert20T must be 20 bytes");

typedef struct { float offset[3]; float _pad; } ChunkOffset;
typedef struct {
    float viewProj[16];
    float fogStart, fogEnd;
    float _pad0[2];
    float fogColor[4];
    float alphaThreshold;
    float _pad1[3];
} FrameUniforms;

// ============================================================
// Float -> half conversion
// ============================================================

static uint16_t f32_to_f16(float value) {
    uint32_t f32;
    memcpy(&f32, &value, 4);
    uint32_t sign = (f32 >> 16) & 0x8000;
    int32_t exp = (int32_t)((f32 >> 23) & 0xFF) - 127 + 15;
    uint32_t mant = f32 & 0x007FFFFF;
    if (exp <= 0) return (uint16_t)sign;
    if (exp >= 31) return (uint16_t)(sign | 0x7C00);
    return (uint16_t)(sign | (exp << 10) | (mant >> 13));
}

// ============================================================
// Shaders
// ============================================================

static NSString *kShaderCommon = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms {\n"
    "    float4x4 viewProj;\n"
    "    float fogStart; float fogEnd; float2 _pad0;\n"
    "    float4 fogColor;\n"
    "    float alphaThreshold; float _pad1[3];\n"
    "};\n"
    "struct InstUniforms { uint slotSize; };\n"
    "\n"
    "struct TerrainOut {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "    float2 uv0;\n"
    "    float2 uv2;\n"
    "    float fogFactor;\n"
    "};\n"
    "\n"
    "fragment float4 terrain_frag(\n"
    "    TerrainOut in [[stage_in]],\n"
    "    texture2d<float> blockAtlas [[texture(0)]],\n"
    "    texture2d<float> lightmap [[texture(1)]],\n"
    "    sampler atlasSampler [[sampler(0)]],\n"
    "    sampler lmSampler [[sampler(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]]\n"
    ") {\n"
    "    float4 texColor = blockAtlas.sample(atlasSampler, in.uv0);\n"
    "    if (texColor.a < frame.alphaThreshold) { discard_fragment(); }\n"
    "    float4 light = lightmap.sample(lmSampler, in.uv2);\n"
    "    float4 color = texColor * light * in.color;\n"
    "    color.rgb = mix(frame.fogColor.rgb, color.rgb, in.fogFactor);\n"
    "    return color;\n"
    "}\n";

// V0: Slot-based instanced (manual buffer indexing)
static NSString *kShaderV0 = @
    "struct Vert32 {\n"
    "    packed_float3 position;\n"
    "    uchar4 color;\n"
    "    packed_float2 uv0;\n"
    "    packed_short2 uv2;\n"
    "    uchar4 normal;\n"
    "};\n"
    "vertex TerrainOut vert_v0(\n"
    "    constant Vert32* vertices [[buffer(0)]],\n"
    "    constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]],\n"
    "    constant InstUniforms& inst [[buffer(3)]],\n"
    "    uint vid [[vertex_id]],\n"
    "    uint iid [[instance_id]]\n"
    ") {\n"
    "    uint idx = iid * inst.slotSize + vid;\n"
    "    constant Vert32& v = vertices[idx];\n"
    "    TerrainOut out;\n"
    "    float3 worldPos = float3(v.position) + float3(chunks[iid].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = float4(v.color) / 255.0;\n"
    "    out.uv0 = float2(v.uv0);\n"
    "    out.uv2 = float2(v.uv2) / 256.0;\n"
    "    float dist = length(worldPos);\n"
    "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
    "    return out;\n"
    "}\n";

// V1: Tight-packed 32B (chunkId in vertex, no instancing)
static NSString *kShaderV1 = @
    "struct Vert32T {\n"
    "    packed_float3 position;\n"
    "    uchar4 color;\n"
    "    packed_float2 uv0;\n"
    "    packed_short2 uv2;\n"
    "    ushort chunkId;\n"
    "    ushort _pad;\n"
    "};\n"
    "vertex TerrainOut vert_v1(\n"
    "    constant Vert32T* vertices [[buffer(0)]],\n"
    "    constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]],\n"
    "    uint vid [[vertex_id]]\n"
    ") {\n"
    "    constant Vert32T& v = vertices[vid];\n"
    "    TerrainOut out;\n"
    "    float3 worldPos = float3(v.position) + float3(chunks[v.chunkId].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = float4(v.color) / 255.0;\n"
    "    out.uv0 = float2(v.uv0);\n"
    "    out.uv2 = float2(v.uv2) / 256.0;\n"
    "    float dist = length(worldPos);\n"
    "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
    "    return out;\n"
    "}\n";

// V2: Tight-packed 20B (compressed vertex)
static NSString *kShaderV2 = @
    "struct Vert20T {\n"
    "    packed_half3 position;\n"
    "    ushort chunkId;\n"
    "    uchar4 color;\n"
    "    packed_half2 uv0;\n"
    "    uchar2 uv2;\n"
    "    uchar2 _pad;\n"
    "};\n"
    "vertex TerrainOut vert_v2(\n"
    "    constant Vert20T* vertices [[buffer(0)]],\n"
    "    constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]],\n"
    "    uint vid [[vertex_id]]\n"
    ") {\n"
    "    constant Vert20T& v = vertices[vid];\n"
    "    TerrainOut out;\n"
    "    float3 worldPos = float3(v.position) + float3(chunks[v.chunkId].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = float4(v.color) / 255.0;\n"
    "    out.uv0 = float2(v.uv0);\n"
    "    out.uv2 = float2(v.uv2) / 256.0;\n"
    "    float dist = length(worldPos);\n"
    "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
    "    return out;\n"
    "}\n";

// ============================================================
// Helpers
// ============================================================

static void gen_viewproj(float *out) {
    memset(out, 0, 64);
    float f = 1.0f / tanf(35.0f * M_PI / 180.0f);
    out[0] = f / (16.0f/9.0f); out[5] = f;
    out[10] = -513.0f / 511.95f; out[11] = -1.0f;
    out[14] = -2.0f * 512.0f * 0.05f / 511.95f;
}

typedef struct { double avg, p50, p95, p99, min, max; } Stats;
static int cmp_dbl(const void *a, const void *b) {
    double da = *(const double*)a, db = *(const double*)b;
    return (da > db) - (da < db);
}
static Stats calc_stats(double *data, int n) {
    Stats s = {0,0,0,0,1e9,0};
    double sum = 0;
    for (int i = 0; i < n; i++) {
        sum += data[i];
        if (data[i] < s.min) s.min = data[i];
        if (data[i] > s.max) s.max = data[i];
    }
    s.avg = sum / n;
    double *sorted = malloc(n * sizeof(double));
    memcpy(sorted, data, n * sizeof(double));
    qsort(sorted, n, sizeof(double), cmp_dbl);
    s.p50 = sorted[n/2];
    s.p95 = sorted[(int)(n*0.95)];
    s.p99 = sorted[(int)(n*0.99)];
    free(sorted);
    return s;
}

// ============================================================
// Draw config
// ============================================================

typedef struct {
    const char *name;
    id<MTLRenderPipelineState> pipeline;
    id<MTLBuffer> vertexBuf;
    id<MTLBuffer> offsetBuf;
    id<MTLBuffer> indexBuf;
    uint32_t indexCount;
    MTLIndexType indexType;
    uint32_t instanceCount;  // 0 = no instancing
    uint32_t slotSize;       // V0 only
    double dataBytes;        // vertex + index data per frame
} DrawConfig;

// ============================================================
// Main
// ============================================================

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int numChunks = 1200;
        int iterations = 300;
        int width = 2560, height = 1440;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--chunks") == 0 && i+1 < argc) numChunks = atoi(argv[++i]);
            else if (strcmp(argv[i], "--iterations") == 0 && i+1 < argc) iterations = atoi(argv[++i]);
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "No Metal device\n"); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];

        printf("=== Metal Vertex Bandwidth Benchmark ===\n");
        printf("Device: %s\n", [[device name] UTF8String]);

        // Generate chunk vertex counts (log-normal distribution)
        srand(42);
        int totalVerts = 0, maxVPC = 0;
        int *chunkVerts = calloc(numChunks, sizeof(int));
        for (int i = 0; i < numChunks; i++) {
            float r = (float)rand() / RAND_MAX;
            int v = (int)(expf(r * 5.0f + 2.0f));
            v = (v/4)*4; if (v < 4) v = 4; if (v > 4096) v = 4096;
            chunkVerts[i] = v;
            totalVerts += v;
            if (v > maxVPC) maxVPC = v;
        }

        printf("Chunks: %d  Total verts: %d  Avg: %d  Max: %d\n",
               numChunks, totalVerts, totalVerts/numChunks, maxVPC);
        printf("Resolution: %dx%d  Iterations: %d\n\n", width, height, iterations);

        // Chunk offsets (shared by all variants)
        ChunkOffset *offs = calloc(numChunks, sizeof(ChunkOffset));
        int gridSz = (int)ceil(sqrt(numChunks));
        for (int c = 0; c < numChunks; c++) {
            offs[c].offset[0] = (float)((c % gridSz) - gridSz/2) * 16.0f;
            offs[c].offset[1] = 64.0f;
            offs[c].offset[2] = (float)((c / gridSz) - gridSz/2) * 16.0f;
        }
        id<MTLBuffer> offsetBuf = [device newBufferWithBytes:offs
                                                       length:numChunks * sizeof(ChunkOffset)
                                                      options:MTLResourceStorageModeShared];

        // ---- V0: Slot-based mega-buffer ----
        printf("Building V0 slot buffer...\n");
        uint32_t slotSize = (uint32_t)maxVPC;
        uint64_t slotBufBytes = (uint64_t)numChunks * slotSize * 32;
        id<MTLBuffer> slotBuf = [device newBufferWithLength:(NSUInteger)slotBufBytes
                                                     options:MTLResourceStorageModeShared];
        Vert32 *slotData = (Vert32 *)[slotBuf contents];
        memset(slotData, 0, slotBufBytes);

        srand(42);
        for (int c = 0; c < numChunks; c++) {
            for (int v = 0; v < chunkVerts[c]; v++) {
                Vert32 *dst = &slotData[(uint64_t)c * slotSize + v];
                dst->x = (float)(rand()%16); dst->y = (float)(rand()%16); dst->z = (float)(rand()%16);
                dst->cr = 180+rand()%76; dst->cg = 180+rand()%76; dst->cb = 180+rand()%76; dst->ca = 255;
                dst->u0 = (float)(rand()%1024)/1024.0f; dst->v0 = (float)(rand()%1024)/1024.0f;
                dst->u2 = (int16_t)(rand()%256); dst->v2 = (int16_t)(rand()%256);
                dst->nx = 0; dst->ny = 127; dst->nz = 0; dst->nw = 0;
            }
        }

        // V0 index buffer (uint16, per-instance)
        int maxQuads = maxVPC / 4;
        int v0IdxCount = maxQuads * 6;
        uint16_t *v0Idx = malloc(v0IdxCount * 2);
        for (int q = 0; q < maxQuads; q++) {
            v0Idx[q*6+0] = (uint16_t)(q*4);   v0Idx[q*6+1] = (uint16_t)(q*4+1);
            v0Idx[q*6+2] = (uint16_t)(q*4+2); v0Idx[q*6+3] = (uint16_t)(q*4);
            v0Idx[q*6+4] = (uint16_t)(q*4+2); v0Idx[q*6+5] = (uint16_t)(q*4+3);
        }
        id<MTLBuffer> v0IdxBuf = [device newBufferWithBytes:v0Idx length:v0IdxCount*2
                                                     options:MTLResourceStorageModeShared];
        free(v0Idx);

        double v0DataBytes = (double)slotBufBytes + (double)v0IdxCount * 2 * numChunks;

        // ---- V1: Tight-packed 32B ----
        printf("Building V1 tight-packed 32B buffer...\n");
        id<MTLBuffer> tight32Buf = [device newBufferWithLength:totalVerts * 32
                                                        options:MTLResourceStorageModeShared];
        Vert32T *t32Data = (Vert32T *)[tight32Buf contents];

        srand(42);  // same seed for same vertex positions
        int vOff = 0;
        for (int c = 0; c < numChunks; c++) {
            for (int v = 0; v < chunkVerts[c]; v++) {
                Vert32T *dst = &t32Data[vOff++];
                dst->x = (float)(rand()%16); dst->y = (float)(rand()%16); dst->z = (float)(rand()%16);
                dst->cr = 180+rand()%76; dst->cg = 180+rand()%76; dst->cb = 180+rand()%76; dst->ca = 255;
                dst->u0 = (float)(rand()%1024)/1024.0f; dst->v0 = (float)(rand()%1024)/1024.0f;
                dst->u2 = (int16_t)(rand()%256); dst->v2 = (int16_t)(rand()%256);
                dst->chunkId = (uint16_t)c;
                dst->_pad = 0;
            }
        }

        // ---- V2: Tight-packed 20B ----
        printf("Building V2 tight-packed 20B buffer...\n");
        id<MTLBuffer> tight20Buf = [device newBufferWithLength:totalVerts * 20
                                                        options:MTLResourceStorageModeShared];
        Vert20T *t20Data = (Vert20T *)[tight20Buf contents];

        srand(42);
        vOff = 0;
        for (int c = 0; c < numChunks; c++) {
            for (int v = 0; v < chunkVerts[c]; v++) {
                Vert20T *dst = &t20Data[vOff++];
                float fx = (float)(rand()%16), fy = (float)(rand()%16), fz = (float)(rand()%16);
                dst->px = f32_to_f16(fx); dst->py = f32_to_f16(fy); dst->pz = f32_to_f16(fz);
                dst->chunkId = (uint16_t)c;
                dst->cr = 180+rand()%76; dst->cg = 180+rand()%76; dst->cb = 180+rand()%76; dst->ca = 255;
                float fu0 = (float)(rand()%1024)/1024.0f, fv0 = (float)(rand()%1024)/1024.0f;
                dst->u0x = f32_to_f16(fu0); dst->u0y = f32_to_f16(fv0);
                dst->u2x = (uint8_t)(rand()%256); dst->u2y = (uint8_t)(rand()%256);
                dst->_pad[0] = 0; dst->_pad[1] = 0;
            }
        }

        // Global index buffer (uint32, for V1/V2)
        uint32_t totalTriIdx = 0;
        for (int c = 0; c < numChunks; c++) totalTriIdx += (chunkVerts[c] / 4) * 6;

        uint32_t *gIdx = malloc(totalTriIdx * 4);
        uint32_t idxPos = 0, vertBase = 0;
        for (int c = 0; c < numChunks; c++) {
            int nq = chunkVerts[c] / 4;
            for (int q = 0; q < nq; q++) {
                uint32_t b = vertBase + q * 4;
                gIdx[idxPos++] = b;     gIdx[idxPos++] = b + 1;
                gIdx[idxPos++] = b + 2; gIdx[idxPos++] = b;
                gIdx[idxPos++] = b + 2; gIdx[idxPos++] = b + 3;
            }
            vertBase += chunkVerts[c];
        }
        id<MTLBuffer> globalIdxBuf = [device newBufferWithBytes:gIdx length:totalTriIdx * 4
                                                         options:MTLResourceStorageModeShared];
        free(gIdx);

        double v1DataBytes = (double)totalVerts * 32 + (double)totalTriIdx * 4;
        double v2DataBytes = (double)totalVerts * 20 + (double)totalTriIdx * 4;

        printf("Data volumes per frame:\n");
        printf("  V0 (slot):      %.1f MB  (%.1f MB vertex + %.1f MB index)\n",
               v0DataBytes/1e6, slotBufBytes/1e6, (double)v0IdxCount*2*numChunks/1e6);
        printf("  V1 (tight 32B): %.1f MB  (%.1f MB vertex + %.1f MB index)\n",
               v1DataBytes/1e6, totalVerts*32.0/1e6, totalTriIdx*4.0/1e6);
        printf("  V2 (tight 20B): %.1f MB  (%.1f MB vertex + %.1f MB index)\n",
               v2DataBytes/1e6, totalVerts*20.0/1e6, totalTriIdx*4.0/1e6);
        printf("  Ratio V0/V1: %.1fx\n\n", v0DataBytes / v1DataBytes);

        // Textures + samplers
        MTLTextureDescriptor *td;
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
              width:1024 height:1024 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> atlas = [device newTextureWithDescriptor:td];
        { uint8_t *px = malloc(1024*1024*4);
          for (int i = 0; i < 1024*1024*4; i++) px[i] = (i%4==3) ? 255 : rand()%256;
          [atlas replaceRegion:MTLRegionMake2D(0,0,1024,1024) mipmapLevel:0
                     withBytes:px bytesPerRow:1024*4]; free(px); }

        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
              width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> lm = [device newTextureWithDescriptor:td];
        { uint8_t px[1024]; for (int i = 0; i < 1024; i++) px[i] = 200;
          [lm replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:px bytesPerRow:64]; }

        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterNearest; sd.magFilter = MTLSamplerMinMagFilterNearest;
        id<MTLSamplerState> aSamp = [device newSamplerStateWithDescriptor:sd];
        sd.minFilter = MTLSamplerMinMagFilterLinear; sd.magFilter = MTLSamplerMinMagFilterLinear;
        id<MTLSamplerState> lSamp = [device newSamplerStateWithDescriptor:sd];

        // Render targets
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> colorTex = [device newTextureWithDescriptor:td];
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depthTex = [device newTextureWithDescriptor:td];

        MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
        dd.depthCompareFunction = MTLCompareFunctionLess; dd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> dsState = [device newDepthStencilStateWithDescriptor:dd];

        // Uniforms
        FrameUniforms u;
        gen_viewproj(u.viewProj);
        u.fogStart = 192.0f; u.fogEnd = 256.0f;
        u._pad0[0] = 0; u._pad0[1] = 0;
        u.fogColor[0] = 0.7f; u.fogColor[1] = 0.8f; u.fogColor[2] = 1.0f; u.fogColor[3] = 1.0f;
        u.alphaThreshold = 0.0f;
        u._pad1[0] = 0; u._pad1[1] = 0; u._pad1[2] = 0;

        // Compile shaders
        printf("Compiling shaders...\n");
        MTLCompileOptions *copts = [[MTLCompileOptions alloc] init];
        copts.languageVersion = MTLLanguageVersion2_4;
        NSError *error = nil;

        NSString *sources[3] = {
            [NSString stringWithFormat:@"%@%@", kShaderCommon, kShaderV0],
            [NSString stringWithFormat:@"%@%@", kShaderCommon, kShaderV1],
            [NSString stringWithFormat:@"%@%@", kShaderCommon, kShaderV2],
        };
        const char *vertNames[3] = { "vert_v0", "vert_v1", "vert_v2" };

        id<MTLRenderPipelineState> pipelines[3];
        for (int v = 0; v < 3; v++) {
            id<MTLLibrary> lib = [device newLibraryWithSource:sources[v] options:copts error:&error];
            if (!lib) {
                fprintf(stderr, "V%d shader error: %s\n", v, [[error description] UTF8String]);
                return 1;
            }
            MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
            pd.vertexFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:vertNames[v]]];
            pd.fragmentFunction = [lib newFunctionWithName:@"terrain_frag"];
            // No vertex descriptor (manual buffer indexing for all variants)
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            pipelines[v] = [device newRenderPipelineStateWithDescriptor:pd error:&error];
            if (!pipelines[v]) {
                fprintf(stderr, "V%d pipeline error: %s\n", v, [[error description] UTF8String]);
                return 1;
            }
            printf("  V%d compiled OK\n", v);
        }

        // Draw configs
        DrawConfig configs[3] = {
            { "V0: slot instanced 32B", pipelines[0], slotBuf, offsetBuf,
              v0IdxBuf, (uint32_t)v0IdxCount, MTLIndexTypeUInt16,
              (uint32_t)numChunks, slotSize, v0DataBytes },
            { "V1: tight-packed 32B", pipelines[1], tight32Buf, offsetBuf,
              globalIdxBuf, totalTriIdx, MTLIndexTypeUInt32,
              0, 0, v1DataBytes },
            { "V2: tight-packed 20B", pipelines[2], tight20Buf, offsetBuf,
              globalIdxBuf, totalTriIdx, MTLIndexTypeUInt32,
              0, 0, v2DataBytes },
        };

        // Warmup
        printf("\nWarming up...\n");
        for (int v = 0; v < 3; v++) {
            for (int w = 0; w < 10; w++) {
                @autoreleasepool {
                    DrawConfig *cfg = &configs[v];
                    id<MTLCommandBuffer> cmd = [queue commandBuffer];
                    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                    rpd.colorAttachments[0].texture = colorTex;
                    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
                    rpd.depthAttachment.texture = depthTex;
                    rpd.depthAttachment.loadAction = MTLLoadActionClear;
                    rpd.depthAttachment.clearDepth = 1.0;
                    rpd.depthAttachment.storeAction = MTLStoreActionStore;

                    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
                    [enc setRenderPipelineState:cfg->pipeline];
                    [enc setDepthStencilState:dsState];
                    [enc setCullMode:MTLCullModeBack];
                    [enc setVertexBuffer:cfg->vertexBuf offset:0 atIndex:0];
                    [enc setVertexBuffer:cfg->offsetBuf offset:0 atIndex:1];
                    [enc setVertexBytes:&u length:sizeof(u) atIndex:2];
                    [enc setFragmentBytes:&u length:sizeof(u) atIndex:2];
                    [enc setFragmentTexture:atlas atIndex:0];
                    [enc setFragmentTexture:lm atIndex:1];
                    [enc setFragmentSamplerState:aSamp atIndex:0];
                    [enc setFragmentSamplerState:lSamp atIndex:1];

                    if (cfg->instanceCount > 0) {
                        [enc setVertexBytes:&cfg->slotSize length:4 atIndex:3];
                        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:cfg->indexCount indexType:cfg->indexType
                                       indexBuffer:cfg->indexBuf indexBufferOffset:0
                                     instanceCount:cfg->instanceCount baseVertex:0 baseInstance:0];
                    } else {
                        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:cfg->indexCount indexType:cfg->indexType
                                       indexBuffer:cfg->indexBuf indexBufferOffset:0];
                    }
                    [enc endEncoding];
                    [cmd commit]; [cmd waitUntilCompleted];
                }
            }
        }

        // Benchmark
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        int skip = iterations / 10;
        int count = iterations - skip;

        printf("\nRunning %d iterations per variant...\n\n", iterations);

        double allGpu[3][iterations];
        double allCpu[3][iterations];

        for (int v = 0; v < 3; v++) {
            DrawConfig *cfg = &configs[v];
            for (int iter = 0; iter < iterations; iter++) {
                @autoreleasepool {
                    uint64_t t0 = mach_absolute_time();
                    id<MTLCommandBuffer> cmd = [queue commandBuffer];
                    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                    rpd.colorAttachments[0].texture = colorTex;
                    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
                    rpd.depthAttachment.texture = depthTex;
                    rpd.depthAttachment.loadAction = MTLLoadActionClear;
                    rpd.depthAttachment.clearDepth = 1.0;
                    rpd.depthAttachment.storeAction = MTLStoreActionStore;

                    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
                    [enc setRenderPipelineState:cfg->pipeline];
                    [enc setDepthStencilState:dsState];
                    [enc setCullMode:MTLCullModeBack];
                    [enc setFrontFacingWinding:MTLWindingCounterClockwise];
                    [enc setVertexBuffer:cfg->vertexBuf offset:0 atIndex:0];
                    [enc setVertexBuffer:cfg->offsetBuf offset:0 atIndex:1];
                    [enc setVertexBytes:&u length:sizeof(u) atIndex:2];
                    [enc setFragmentBytes:&u length:sizeof(u) atIndex:2];
                    [enc setFragmentTexture:atlas atIndex:0];
                    [enc setFragmentTexture:lm atIndex:1];
                    [enc setFragmentSamplerState:aSamp atIndex:0];
                    [enc setFragmentSamplerState:lSamp atIndex:1];

                    if (cfg->instanceCount > 0) {
                        [enc setVertexBytes:&cfg->slotSize length:4 atIndex:3];
                        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:cfg->indexCount indexType:cfg->indexType
                                       indexBuffer:cfg->indexBuf indexBufferOffset:0
                                     instanceCount:cfg->instanceCount baseVertex:0 baseInstance:0];
                    } else {
                        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:cfg->indexCount indexType:cfg->indexType
                                       indexBuffer:cfg->indexBuf indexBufferOffset:0];
                    }
                    [enc endEncoding];

                    __block double gt = 0;
                    [cmd addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                        if (buf.GPUStartTime > 0) gt = (buf.GPUEndTime - buf.GPUStartTime) * 1000.0;
                    }];
                    [cmd commit]; [cmd waitUntilCompleted];

                    allCpu[v][iter] = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
                    allGpu[v][iter] = gt;
                }
            }
        }

        // Results
        printf("=== Results (dropping first %d iterations) ===\n\n", skip);
        printf("%-30s  %8s %8s %8s %8s  %8s %8s  %10s\n",
               "Variant", "GPU avg", "GPU p50", "GPU p95", "GPU p99", "CPU avg", "CPU p50", "Data/frame");
        printf("%-30s  %8s %8s %8s %8s  %8s %8s  %10s\n",
               "-------", "-------", "-------", "-------", "-------", "-------", "-------", "----------");

        Stats baseGpu;
        for (int v = 0; v < 3; v++) {
            Stats sg = calc_stats(&allGpu[v][skip], count);
            Stats sc = calc_stats(&allCpu[v][skip], count);
            if (v == 0) baseGpu = sg;
            printf("%-30s  %7.3fms %7.3fms %7.3fms %7.3fms  %7.3fms %7.3fms  %8.1f MB\n",
                   configs[v].name, sg.avg, sg.p50, sg.p95, sg.p99, sc.avg, sc.p50,
                   configs[v].dataBytes / 1e6);
        }

        printf("\n=== Speedup vs V0 ===\n\n");
        for (int v = 1; v < 3; v++) {
            Stats sg = calc_stats(&allGpu[v][skip], count);
            Stats sc = calc_stats(&allCpu[v][skip], count);
            Stats s0c = calc_stats(&allCpu[0][skip], count);
            printf("%-30s  GPU: %.2fx (%.3fms -> %.3fms)  CPU: %.2fx (%.3fms -> %.3fms)\n",
                   configs[v].name,
                   baseGpu.avg / sg.avg, baseGpu.avg, sg.avg,
                   s0c.avg / sc.avg, s0c.avg, sc.avg);
        }

        printf("\n=== Bandwidth Analysis ===\n\n");
        for (int v = 0; v < 3; v++) {
            Stats sg = calc_stats(&allGpu[v][skip], count);
            double bw = configs[v].dataBytes / (sg.avg / 1000.0) / 1e9;
            printf("%-30s  Effective BW: %.1f GB/s  (%.1f%% of 410 GB/s)\n",
                   configs[v].name, bw, bw / 410.0 * 100.0);
        }

        printf("\n=== Triangle Counts ===\n");
        printf("V0 (slot, incl. degenerate): %d triangles/frame\n", numChunks * maxQuads * 2);
        printf("V1/V2 (tight, actual):       %d triangles/frame\n", totalTriIdx / 3);
        printf("Ratio: %.1fx fewer triangles\n", (double)(numChunks * maxQuads * 2) / (totalTriIdx / 3));

        free(chunkVerts);
        free(offs);
        return 0;
    }
}
