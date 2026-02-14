// metal_bench_opt.m -- Shader & pipeline optimization benchmark
//
// Tests multiple optimization variants on top of instanced rendering:
//   V0: Instanced baseline (current shader, proven 2.84x over per-chunk)
//   V1: Remove dead normal output
//   V2: V1 + UChar4Normalized color (hardware unorm, no shader divide)
//   V3: V2 + fast fog (squared distance, no sqrt)
//   V4: V3 + half-precision intermediates
//   V5: V4 + simplified fragment (remove fog entirely for perf ceiling)
//
// Build:  clang -framework Metal -framework QuartzCore -framework Foundation \
//         -O2 -fobjc-arc -o metal_bench_opt metal_bench_opt.m
// Run:    ./metal_bench_opt [--chunks N] [--iterations N]

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

// Variant with squared fog distances
typedef struct {
    float viewProj[16];
    float fogStartSq;      // fogStart^2
    float fogRangeSqInv;    // 1.0 / (fogEnd^2 - fogStart^2)
    float _pad0[2];
    float fogColor[4];
    float alphaThreshold;
    float _pad1[3];
} FrameUniformsV3;

// ============================================================
// Shader variants
// ============================================================

// V0: Instanced baseline (same as current shader, just reads offset from buffer)
static NSString *kShaderV0 = @
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
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms {\n"
    "    float4x4 viewProj; float fogStart; float fogEnd; float2 _pad0;\n"
    "    float4 fogColor; float alphaThreshold; float _pad1[3];\n"
    "};\n"
    "struct TerrainOut {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "    float2 uv0;\n"
    "    float2 uv2;\n"
    "    float3 normal;\n"       // DEAD -- not read by fragment
    "    float fogFactor;\n"
    "};\n"
    "\n"
    "vertex TerrainOut vert_v0(\n"
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
    "}\n"
    "fragment float4 frag_v0(\n"
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

// V1: Remove dead normal output
static NSString *kShaderV1 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct BlockVertex {\n"
    "    float3 position  [[attribute(0)]];\n"
    "    uchar4 color     [[attribute(1)]];\n"
    "    float2 uv0       [[attribute(2)]];\n"
    "    short2 uv2       [[attribute(3)]];\n"
    "    uchar4 normal    [[attribute(4)]];\n"
    "};\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms {\n"
    "    float4x4 viewProj; float fogStart; float fogEnd; float2 _pad0;\n"
    "    float4 fogColor; float alphaThreshold; float _pad1[3];\n"
    "};\n"
    "struct TerrainOut {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "    float2 uv0;\n"
    "    float2 uv2;\n"
    // normal removed -- saves 12 bytes interpolation per fragment
    "    float fogFactor;\n"
    "};\n"
    "\n"
    "vertex TerrainOut vert_v1(\n"
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
    // normal computation removed
    "    float dist = length(worldPos);\n"
    "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
    "    return out;\n"
    "}\n"
    "fragment float4 frag_v1(\n"
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

// V2: V1 + UChar4Normalized color (requires vertex descriptor change)
// The shader receives color as float4 [0,1] from the hardware, no divide needed
static NSString *kShaderV2 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct BlockVertex {\n"
    "    float3 position  [[attribute(0)]];\n"
    "    float4 color     [[attribute(1)]];\n"  // UChar4Normalized -> float4 by hardware
    "    float2 uv0       [[attribute(2)]];\n"
    "    short2 uv2       [[attribute(3)]];\n"
    "    uchar4 normal    [[attribute(4)]];\n"
    "};\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms {\n"
    "    float4x4 viewProj; float fogStart; float fogEnd; float2 _pad0;\n"
    "    float4 fogColor; float alphaThreshold; float _pad1[3];\n"
    "};\n"
    "struct TerrainOut {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "    float2 uv0;\n"
    "    float2 uv2;\n"
    "    float fogFactor;\n"
    "};\n"
    "\n"
    "vertex TerrainOut vert_v2(\n"
    "    BlockVertex in [[stage_in]],\n"
    "    constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]],\n"
    "    uint iid [[instance_id]]\n"
    ") {\n"
    "    TerrainOut out;\n"
    "    float3 worldPos = in.position + float3(chunks[iid].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = in.color;\n"  // already float4 [0,1] from hardware
    "    out.uv0 = in.uv0;\n"
    "    out.uv2 = float2(in.uv2) / 256.0;\n"
    "    float dist = length(worldPos);\n"
    "    out.fogFactor = clamp((frame.fogEnd - dist) / (frame.fogEnd - frame.fogStart), 0.0, 1.0);\n"
    "    return out;\n"
    "}\n"
    "fragment float4 frag_v2(\n"
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

// V3: V2 + fast fog (squared distance -- eliminates sqrt)
static NSString *kShaderV3 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct BlockVertex {\n"
    "    float3 position  [[attribute(0)]];\n"
    "    float4 color     [[attribute(1)]];\n"
    "    float2 uv0       [[attribute(2)]];\n"
    "    short2 uv2       [[attribute(3)]];\n"
    "    uchar4 normal    [[attribute(4)]];\n"
    "};\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms {\n"
    "    float4x4 viewProj;\n"
    "    float fogStartSq;\n"       // fogStart^2
    "    float fogRangeSqInv;\n"    // 1.0 / (fogEnd^2 - fogStart^2)
    "    float2 _pad0;\n"
    "    float4 fogColor;\n"
    "    float alphaThreshold;\n"
    "    float _pad1[3];\n"
    "};\n"
    "struct TerrainOut {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "    float2 uv0;\n"
    "    float2 uv2;\n"
    "    float fogFactor;\n"
    "};\n"
    "\n"
    "vertex TerrainOut vert_v3(\n"
    "    BlockVertex in [[stage_in]],\n"
    "    constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]],\n"
    "    uint iid [[instance_id]]\n"
    ") {\n"
    "    TerrainOut out;\n"
    "    float3 worldPos = in.position + float3(chunks[iid].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = in.color;\n"
    "    out.uv0 = in.uv0;\n"
    "    out.uv2 = float2(in.uv2) / 256.0;\n"
    "    float distSq = dot(worldPos, worldPos);\n"  // no sqrt!
    "    out.fogFactor = saturate(1.0 - (distSq - frame.fogStartSq) * frame.fogRangeSqInv);\n"
    "    return out;\n"
    "}\n"
    "fragment float4 frag_v3(\n"
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

// V4: V3 + half-precision intermediates in vertex shader
static NSString *kShaderV4 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct BlockVertex {\n"
    "    float3 position  [[attribute(0)]];\n"
    "    float4 color     [[attribute(1)]];\n"
    "    float2 uv0       [[attribute(2)]];\n"
    "    short2 uv2       [[attribute(3)]];\n"
    "    uchar4 normal    [[attribute(4)]];\n"
    "};\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms {\n"
    "    float4x4 viewProj;\n"
    "    float fogStartSq;\n"
    "    float fogRangeSqInv;\n"
    "    float2 _pad0;\n"
    "    float4 fogColor;\n"
    "    float alphaThreshold;\n"
    "    float _pad1[3];\n"
    "};\n"
    "struct TerrainOut {\n"
    "    float4 position [[position]];\n"
    "    half4 color;\n"          // half precision for interpolation
    "    half2 uv0;\n"
    "    half2 uv2;\n"
    "    half fogFactor;\n"
    "};\n"
    "\n"
    "vertex TerrainOut vert_v4(\n"
    "    BlockVertex in [[stage_in]],\n"
    "    constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]],\n"
    "    uint iid [[instance_id]]\n"
    ") {\n"
    "    TerrainOut out;\n"
    "    float3 worldPos = in.position + float3(chunks[iid].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = half4(in.color);\n"
    "    out.uv0 = half2(in.uv0);\n"
    "    out.uv2 = half2(float2(in.uv2) / 256.0);\n"
    "    float distSq = dot(worldPos, worldPos);\n"
    "    out.fogFactor = half(saturate(1.0 - (distSq - frame.fogStartSq) * frame.fogRangeSqInv));\n"
    "    return out;\n"
    "}\n"
    "fragment half4 frag_v4(\n"
    "    TerrainOut in [[stage_in]],\n"
    "    texture2d<half> blockAtlas [[texture(0)]],\n"
    "    texture2d<half> lightmap [[texture(1)]],\n"
    "    sampler atlasSampler [[sampler(0)]],\n"
    "    sampler lmSampler [[sampler(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]]\n"
    ") {\n"
    "    half4 texColor = blockAtlas.sample(atlasSampler, float2(in.uv0));\n"
    "    if (texColor.a < half(frame.alphaThreshold)) { discard_fragment(); }\n"
    "    half4 light = lightmap.sample(lmSampler, float2(in.uv2));\n"
    "    half4 color = texColor * light * in.color;\n"
    "    color.rgb = mix(half3(frame.fogColor.rgb), color.rgb, in.fogFactor);\n"
    "    return color;\n"
    "}\n";

// V5: V4 + no fog (performance ceiling -- how fast can we go?)
static NSString *kShaderV5 = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct BlockVertex {\n"
    "    float3 position  [[attribute(0)]];\n"
    "    float4 color     [[attribute(1)]];\n"
    "    float2 uv0       [[attribute(2)]];\n"
    "    short2 uv2       [[attribute(3)]];\n"
    "    uchar4 normal    [[attribute(4)]];\n"
    "};\n"
    "struct ChunkOffset { packed_float3 offset; float _pad; };\n"
    "struct FrameUniforms {\n"
    "    float4x4 viewProj;\n"
    "    float fogStartSq;\n"
    "    float fogRangeSqInv;\n"
    "    float2 _pad0;\n"
    "    float4 fogColor;\n"
    "    float alphaThreshold;\n"
    "    float _pad1[3];\n"
    "};\n"
    "struct TerrainOut {\n"
    "    float4 position [[position]];\n"
    "    half4 color;\n"
    "    half2 uv0;\n"
    "    half2 uv2;\n"
    "};\n"
    "\n"
    "vertex TerrainOut vert_v5(\n"
    "    BlockVertex in [[stage_in]],\n"
    "    constant ChunkOffset* chunks [[buffer(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]],\n"
    "    uint iid [[instance_id]]\n"
    ") {\n"
    "    TerrainOut out;\n"
    "    float3 worldPos = in.position + float3(chunks[iid].offset);\n"
    "    out.position = frame.viewProj * float4(worldPos, 1.0);\n"
    "    out.color = half4(in.color);\n"
    "    out.uv0 = half2(in.uv0);\n"
    "    out.uv2 = half2(float2(in.uv2) / 256.0);\n"
    "    return out;\n"
    "}\n"
    "fragment half4 frag_v5(\n"
    "    TerrainOut in [[stage_in]],\n"
    "    texture2d<half> blockAtlas [[texture(0)]],\n"
    "    texture2d<half> lightmap [[texture(1)]],\n"
    "    sampler atlasSampler [[sampler(0)]],\n"
    "    sampler lmSampler [[sampler(1)]],\n"
    "    constant FrameUniforms& frame [[buffer(2)]]\n"
    ") {\n"
    "    half4 texColor = blockAtlas.sample(atlasSampler, float2(in.uv0));\n"
    "    if (texColor.a < half(frame.alphaThreshold)) { discard_fragment(); }\n"
    "    half4 light = lightmap.sample(lmSampler, float2(in.uv2));\n"
    "    return texColor * light * in.color;\n"
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

static void fill_vert(BlockVertex *v) {
    v->x = (float)(rand()%16); v->y = (float)(rand()%16); v->z = (float)(rand()%16);
    v->cr = 180+rand()%76; v->cg = 180+rand()%76; v->cb = 180+rand()%76; v->ca = 255;
    v->u0 = (float)(rand()%1024)/1024.0f; v->v0 = (float)(rand()%1024)/1024.0f;
    v->u2 = (int16_t)(rand()%256); v->v2 = (int16_t)(rand()%256);
    v->nx = 0; v->ny = 127; v->nz = 0; v->nw = 0;
}

typedef struct { double avg, p50, p95, p99, min, max; } Stats;

static int cmp_double(const void *a, const void *b) {
    double da = *(const double*)a, db = *(const double*)b;
    return (da > db) - (da < db);
}

static Stats calc_stats(double *data, int n) {
    Stats s = {0, 0, 0, 0, 1e9, 0};
    double sum = 0;
    for (int i = 0; i < n; i++) {
        sum += data[i];
        if (data[i] < s.min) s.min = data[i];
        if (data[i] > s.max) s.max = data[i];
    }
    s.avg = sum / n;
    double sorted[n];
    memcpy(sorted, data, n * sizeof(double));
    qsort(sorted, n, sizeof(double), cmp_double);
    s.p50 = sorted[n/2];
    s.p95 = sorted[(int)(n*0.95)];
    s.p99 = sorted[(int)(n*0.99)];
    return s;
}

// ============================================================
// Benchmark runner
// ============================================================

typedef struct {
    const char *name;
    NSString *source;
    const char *vertName;
    const char *fragName;
    bool useNormalizedColor;  // MTLVertexFormatUChar4Normalized
    bool useV3Uniforms;       // FrameUniformsV3 with squared fog
} Variant;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int numChunks = 1200;
        int iterations = 300;
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

        printf("=== Metal Terrain Shader Optimization Benchmark ===\n");
        printf("Device: %s\n", [[device name] UTF8String]);

        // Variable-size chunks (log-normal distribution)
        srand(42);
        int totalVerts = 0, maxVPC = 0;
        int *chunkVerts = calloc(numChunks, sizeof(int));
        for (int i = 0; i < numChunks; i++) {
            float r = (float)rand() / RAND_MAX;
            int v = (int)(expf(r * 5.0f + 2.0f));
            v = (v/4)*4; if (v<4) v=4; if (v>4096) v=4096;
            chunkVerts[i] = v;
            totalVerts += v;
            if (v > maxVPC) maxVPC = v;
        }

        printf("Chunks: %d  Avg verts/chunk: %d  Max: %d  Total: %.1fM\n",
               numChunks, totalVerts/numChunks, maxVPC, totalVerts/1e6);
        printf("Resolution: %dx%d  Iterations: %d\n", width, height, iterations);

        // Build padded mega-buffer (slot size = maxVPC)
        int paddedTotal = numChunks * maxVPC;
        id<MTLBuffer> megaBuf = [device newBufferWithLength:paddedTotal*32
                                                     options:MTLResourceStorageModeShared];
        BlockVertex *verts = (BlockVertex*)[megaBuf contents];
        memset(verts, 0, paddedTotal * 32);

        ChunkOffset *offs = calloc(numChunks, sizeof(ChunkOffset));
        int gridSz = (int)ceil(sqrt(numChunks));
        int runningOff = 0;
        for (int c = 0; c < numChunks; c++) {
            offs[c].offset[0] = (float)((c%gridSz)-gridSz/2)*16.0f;
            offs[c].offset[1] = 64.0f;
            offs[c].offset[2] = (float)((c/gridSz)-gridSz/2)*16.0f;
            for (int v = 0; v < chunkVerts[c]; v++)
                fill_vert(&verts[c * maxVPC + v]);
        }

        id<MTLBuffer> offBuf = [device newBufferWithBytes:offs
                                                    length:numChunks*sizeof(ChunkOffset)
                                                   options:MTLResourceStorageModeShared];
        free(offs);

        // Index buffer
        int maxQuads = maxVPC / 4;
        int numIdx = maxQuads * 6;
        uint16_t *idx = malloc(numIdx * 2);
        for (int q = 0; q < maxQuads; q++) {
            idx[q*6+0]=(uint16_t)(q*4); idx[q*6+1]=(uint16_t)(q*4+1); idx[q*6+2]=(uint16_t)(q*4+2);
            idx[q*6+3]=(uint16_t)(q*4); idx[q*6+4]=(uint16_t)(q*4+2); idx[q*6+5]=(uint16_t)(q*4+3);
        }
        id<MTLBuffer> idxBuf = [device newBufferWithBytes:idx length:numIdx*2
                                                   options:MTLResourceStorageModeShared];
        free(idx);

        // Textures + samplers
        MTLTextureDescriptor *td;
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
              width:1024 height:1024 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> atlas = [device newTextureWithDescriptor:td];
        { uint8_t *px=malloc(1024*1024*4); for(int i=0;i<1024*1024*4;i++) px[i]=(i%4==3)?255:rand()%256;
          [atlas replaceRegion:MTLRegionMake2D(0,0,1024,1024) mipmapLevel:0 withBytes:px bytesPerRow:1024*4]; free(px); }

        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
              width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> lm = [device newTextureWithDescriptor:td];
        { uint8_t px[1024]; for(int i=0;i<1024;i++) px[i]=200;
          [lm replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:px bytesPerRow:64]; }

        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter=MTLSamplerMinMagFilterNearest; sd.magFilter=MTLSamplerMinMagFilterNearest;
        id<MTLSamplerState> aSamp = [device newSamplerStateWithDescriptor:sd];
        sd.minFilter=MTLSamplerMinMagFilterLinear; sd.magFilter=MTLSamplerMinMagFilterLinear;
        id<MTLSamplerState> lSamp = [device newSamplerStateWithDescriptor:sd];

        // Render targets
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> colorTex = [device newTextureWithDescriptor:td];
        td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depthTex = [device newTextureWithDescriptor:td];

        // Depth state
        MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
        dd.depthCompareFunction = MTLCompareFunctionLess; dd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> dsState = [device newDepthStencilStateWithDescriptor:dd];

        // Uniforms
        FrameUniforms u;
        gen_viewproj(u.viewProj);
        u.fogStart = 192.0f; u.fogEnd = 256.0f;
        u._pad0[0]=0; u._pad0[1]=0;
        u.fogColor[0]=0.7f; u.fogColor[1]=0.8f; u.fogColor[2]=1.0f; u.fogColor[3]=1.0f;
        u.alphaThreshold = 0.0f;
        u._pad1[0]=0; u._pad1[1]=0; u._pad1[2]=0;

        FrameUniformsV3 u3;
        memcpy(u3.viewProj, u.viewProj, 64);
        u3.fogStartSq = 192.0f * 192.0f;
        u3.fogRangeSqInv = 1.0f / (256.0f*256.0f - 192.0f*192.0f);
        u3._pad0[0]=0; u3._pad0[1]=0;
        memcpy(u3.fogColor, u.fogColor, 16);
        u3.alphaThreshold = 0.0f;
        u3._pad1[0]=0; u3._pad1[1]=0; u3._pad1[2]=0;

        // Define variants
        Variant variants[] = {
            {"V0: instanced baseline",              kShaderV0, "vert_v0", "frag_v0", false, false},
            {"V1: - dead normal",                   kShaderV1, "vert_v1", "frag_v1", false, false},
            {"V2: + UChar4Normalized",              kShaderV2, "vert_v2", "frag_v2", true,  false},
            {"V3: + fast fog (no sqrt)",            kShaderV3, "vert_v3", "frag_v3", true,  true},
            {"V4: + half precision",                kShaderV4, "vert_v4", "frag_v4", true,  true},
            {"V5: + no fog (perf ceiling)",         kShaderV5, "vert_v5", "frag_v5", true,  true},
        };
        int numVariants = sizeof(variants) / sizeof(variants[0]);

        // Compile all variants
        id<MTLRenderPipelineState> pipelines[numVariants];
        NSError *error = nil;
        MTLCompileOptions *copts = [[MTLCompileOptions alloc] init];
        copts.languageVersion = MTLLanguageVersion2_4;

        for (int v = 0; v < numVariants; v++) {
            id<MTLLibrary> lib = [device newLibraryWithSource:variants[v].source options:copts error:&error];
            if (!lib) { fprintf(stderr, "%s: shader error: %s\n", variants[v].name, [[error description] UTF8String]); return 1; }

            MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
            vd.attributes[0].format = MTLVertexFormatFloat3;  vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
            // Color: normalized or not
            vd.attributes[1].format = variants[v].useNormalizedColor ? MTLVertexFormatUChar4Normalized : MTLVertexFormatUChar4;
            vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0;
            vd.attributes[2].format = MTLVertexFormatFloat2;  vd.attributes[2].offset = 16; vd.attributes[2].bufferIndex = 0;
            vd.attributes[3].format = MTLVertexFormatShort2;  vd.attributes[3].offset = 24; vd.attributes[3].bufferIndex = 0;
            vd.attributes[4].format = MTLVertexFormatUChar4;  vd.attributes[4].offset = 28; vd.attributes[4].bufferIndex = 0;
            vd.layouts[0].stride = 32;
            vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

            MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
            pd.vertexFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:variants[v].vertName]];
            pd.fragmentFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:variants[v].fragName]];
            pd.vertexDescriptor = vd;
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

            pipelines[v] = [device newRenderPipelineStateWithDescriptor:pd error:&error];
            if (!pipelines[v]) { fprintf(stderr, "%s: pipeline error: %s\n", variants[v].name, [[error description] UTF8String]); return 1; }
            printf("Compiled: %s\n", variants[v].name);
        }

        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);

        printf("\nWarming up...\n");

        // Warmup all variants
        for (int v = 0; v < numVariants; v++) {
            for (int w = 0; w < 10; w++) {
                @autoreleasepool {
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
                    [enc setRenderPipelineState:pipelines[v]];
                    [enc setDepthStencilState:dsState];
                    [enc setCullMode:MTLCullModeBack];
                    [enc setVertexBuffer:megaBuf offset:0 atIndex:0];
                    [enc setVertexBuffer:offBuf offset:0 atIndex:1];
                    if (variants[v].useV3Uniforms) {
                        [enc setVertexBytes:&u3 length:sizeof(u3) atIndex:2];
                        [enc setFragmentBytes:&u3 length:sizeof(u3) atIndex:2];
                    } else {
                        [enc setVertexBytes:&u length:sizeof(u) atIndex:2];
                        [enc setFragmentBytes:&u length:sizeof(u) atIndex:2];
                    }
                    [enc setFragmentTexture:atlas atIndex:0];
                    [enc setFragmentTexture:lm atIndex:1];
                    [enc setFragmentSamplerState:aSamp atIndex:0];
                    [enc setFragmentSamplerState:lSamp atIndex:1];
                    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:maxQuads*6 indexType:MTLIndexTypeUInt16
                                   indexBuffer:idxBuf indexBufferOffset:0
                                 instanceCount:numChunks baseVertex:0 baseInstance:0];
                    [enc endEncoding];
                    [cmd commit]; [cmd waitUntilCompleted];
                }
            }
        }

        // Benchmark each variant
        int skip = iterations / 10;
        int count = iterations - skip;

        printf("\nRunning %d iterations per variant...\n\n", iterations);

        double allGpu[numVariants][iterations];
        double allCpu[numVariants][iterations];

        for (int v = 0; v < numVariants; v++) {
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
                    [enc setRenderPipelineState:pipelines[v]];
                    [enc setDepthStencilState:dsState];
                    [enc setCullMode:MTLCullModeBack];
                    [enc setFrontFacingWinding:MTLWindingCounterClockwise];
                    [enc setVertexBuffer:megaBuf offset:0 atIndex:0];
                    [enc setVertexBuffer:offBuf offset:0 atIndex:1];
                    if (variants[v].useV3Uniforms) {
                        [enc setVertexBytes:&u3 length:sizeof(u3) atIndex:2];
                        [enc setFragmentBytes:&u3 length:sizeof(u3) atIndex:2];
                    } else {
                        [enc setVertexBytes:&u length:sizeof(u) atIndex:2];
                        [enc setFragmentBytes:&u length:sizeof(u) atIndex:2];
                    }
                    [enc setFragmentTexture:atlas atIndex:0];
                    [enc setFragmentTexture:lm atIndex:1];
                    [enc setFragmentSamplerState:aSamp atIndex:0];
                    [enc setFragmentSamplerState:lSamp atIndex:1];

                    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:maxQuads*6 indexType:MTLIndexTypeUInt16
                                   indexBuffer:idxBuf indexBufferOffset:0
                                 instanceCount:numChunks baseVertex:0 baseInstance:0];

                    [enc endEncoding];

                    __block double gt = 0;
                    [cmd addCompletedHandler:^(id<MTLCommandBuffer> buf) {
                        if (buf.GPUStartTime > 0) gt = (buf.GPUEndTime - buf.GPUStartTime) * 1000.0;
                    }];
                    [cmd commit]; [cmd waitUntilCompleted];

                    allCpu[v][iter] = (double)(mach_absolute_time()-t0) * tb.numer / tb.denom / 1e6;
                    allGpu[v][iter] = gt;
                }
            }
        }

        // Results
        printf("=== Results (dropping first %d iterations) ===\n\n", skip);
        printf("%-35s  %8s %8s %8s %8s  %8s %8s\n",
               "Variant", "GPU avg", "GPU p50", "GPU p95", "GPU p99", "CPU avg", "CPU p50");
        printf("%-35s  %8s %8s %8s %8s  %8s %8s\n",
               "-------", "-------", "-------", "-------", "-------", "-------", "-------");

        Stats baseGpu, baseCpu;
        for (int v = 0; v < numVariants; v++) {
            Stats sg = calc_stats(&allGpu[v][skip], count);
            Stats sc = calc_stats(&allCpu[v][skip], count);
            if (v == 0) { baseGpu = sg; baseCpu = sc; }

            printf("%-35s  %7.3fms %7.3fms %7.3fms %7.3fms  %7.3fms %7.3fms\n",
                   variants[v].name, sg.avg, sg.p50, sg.p95, sg.p99, sc.avg, sc.p50);
        }

        printf("\n=== Speedup vs V0 (instanced baseline) ===\n\n");
        for (int v = 1; v < numVariants; v++) {
            Stats sg = calc_stats(&allGpu[v][skip], count);
            Stats sc = calc_stats(&allCpu[v][skip], count);
            printf("%-35s  GPU: %.2fx (saved %.3fms)  CPU: %.2fx (saved %.3fms)\n",
                   variants[v].name,
                   baseGpu.avg / sg.avg, baseGpu.avg - sg.avg,
                   baseCpu.avg / sc.avg, baseCpu.avg - sc.avg);
        }

        printf("\n=== Total speedup V0 -> best (V4/V5) ===\n");
        Stats sg4 = calc_stats(&allGpu[4][skip], count);
        Stats sg5 = calc_stats(&allGpu[5][skip], count);
        printf("V4 (with fog):    GPU %.3fms  (%.2fx faster than V0)\n", sg4.avg, baseGpu.avg/sg4.avg);
        printf("V5 (no fog):      GPU %.3fms  (%.2fx faster than V0, perf ceiling)\n", sg5.avg, baseGpu.avg/sg5.avg);
        printf("Fog overhead:     %.3fms (%.1f%% of V4)\n", sg4.avg-sg5.avg, (sg4.avg-sg5.avg)/sg4.avg*100);

        free(chunkVerts);
        return 0;
    }
}
