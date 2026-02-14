#include <metal_stdlib>
using namespace metal;

// ============================================================
// Phase B: Simple triangle shaders for proof-of-concept
// ============================================================

struct TriangleVertex {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct TriangleOut {
    float4 position [[position]];
    float4 color;
};

vertex TriangleOut triangle_vertex(
    TriangleVertex in [[stage_in]],
    constant float &alpha [[buffer(1)]]
) {
    TriangleOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.color = float4(in.color.rgb, in.color.a * alpha);
    return out;
}

fragment float4 triangle_fragment(TriangleOut in [[stage_in]]) {
    return in.color;
}

// ============================================================
// Phase D: Terrain chunk shaders (MC 1.16.5 fixed-function replacement)
// ============================================================

// Matches DefaultVertexFormats.BLOCK exactly (32 bytes/vertex)
struct BlockVertex {
    float3 position  [[attribute(0)]];  // offset 0,  12 bytes
    uchar4 color     [[attribute(1)]];  // offset 12,  4 bytes
    float2 uv0       [[attribute(2)]];  // offset 16,  8 bytes
    short2 uv2       [[attribute(3)]];  // offset 24,  4 bytes
    char4  normal    [[attribute(4)]];  // offset 28,  4 bytes (char4 for alignment, use .xyz)
};

struct Uniforms {
    float4x4 modelViewProj;
    float3   chunkOffset;    // camera-relative chunk origin
    float    _pad0;
    float2   fogRange;       // fog start, fog end
    float2   _pad1;
    float4   fogColor;
    float    alphaThreshold; // 0.0 for SOLID, 0.5 for CUTOUT_MIPPED, 0.1 for CUTOUT
    float3   _pad2;
};

struct TerrainOut {
    float4 position [[position]];
    float4 color;
    float2 uv0;
    float2 uv2;
    float3 normal;
    float  fogFactor;
};

vertex TerrainOut terrain_vertex(
    BlockVertex in [[stage_in]],
    constant Uniforms& u [[buffer(1)]]
) {
    TerrainOut out;

    float3 worldPos = in.position + u.chunkOffset;
    out.position = u.modelViewProj * float4(worldPos, 1.0);

    // Color: ubyte4 normalized to 0-1
    out.color = float4(in.color) / 255.0;

    // Block atlas UV
    out.uv0 = in.uv0;

    // Lightmap UV: shorts are raw lightmap coords (0-240), normalize to 0-1
    out.uv2 = float2(in.uv2) / 256.0;

    // Normal: signed bytes normalized to -1..1
    out.normal = float3(in.normal.xyz) / 127.0;

    // Linear fog
    float dist = length(worldPos);
    out.fogFactor = clamp((u.fogRange.y - dist) / (u.fogRange.y - u.fogRange.x), 0.0, 1.0);

    return out;
}

fragment float4 terrain_fragment(
    TerrainOut in [[stage_in]],
    texture2d<float> blockAtlas [[texture(0)]],
    texture2d<float> lightmap   [[texture(1)]],
    sampler atlasSampler        [[sampler(0)]],
    sampler lightmapSampler     [[sampler(1)]],
    constant Uniforms& u        [[buffer(1)]]
) {
    // Sample block texture
    float4 texColor = blockAtlas.sample(atlasSampler, in.uv0);

    // Alpha test (for CUTOUT / CUTOUT_MIPPED render types)
    if (texColor.a < u.alphaThreshold) {
        discard_fragment();
    }

    // Sample lightmap
    float4 light = lightmap.sample(lightmapSampler, in.uv2);

    // Combine: texture * lightmap * vertex color
    float4 color = texColor * light * in.color;

    // Apply fog
    color.rgb = mix(u.fogColor.rgb, color.rgb, in.fogFactor);

    return color;
}
