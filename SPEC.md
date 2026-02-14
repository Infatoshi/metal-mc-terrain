# SPEC: Metal Rendering Backend for SkyFactory One

## Problem Statement

Minecraft 1.16.5 on macOS M4 Max runs through a catastrophically slow rendering stack:

```
Java -> LWJGL 3.2.1 -> Apple OpenGL 2.1 compat -> GL-to-Metal translation (90.5) -> Metal -> GPU
```

The game makes ~10,000 `glDrawArrays` calls per frame for terrain alone. Each call costs ~5us of CPU overhead through the translation layer. Total: ~50ms/frame on draw call submission -- 3x over the 16.6ms budget for 60fps. The 32-core M4 Max GPU sits at <10% utilization.

**Profiled numbers (baseline, no culling):**

| Metric | Value |
|--------|-------|
| Avg frame time | 13.1ms (76 FPS) |
| p50 frame time | 7.5ms (133 FPS) |
| p95 frame time | 38.5ms |
| p99 frame time | 87.7ms |
| Max spike | 741.6ms |
| Spike rate (>2x avg) | 8.2% |
| Entity count | 457 avg, 1585 max |
| Block entity count | 756 avg |

The 741ms spikes are likely MTLRenderPipelineState compilation when the GL translation layer encounters a new shader/state combination.

## Target

Replace OpenGL terrain rendering with native Metal via JNI. Expected outcome:
- Terrain draw calls: 10,000 -> 1-5 (indirect command buffers)
- CPU draw overhead: ~50ms -> <0.5ms
- Frame spikes from pipeline state compilation: eliminated (pre-compiled MSL)
- GPU utilization: <10% -> meaningful use of M4 Max's 14.7 TFLOPS

## Hardware

- Apple M4 Max (32 GPU cores, 4096 ALUs, 14.7 TFLOPS FP32)
- 36GB unified memory, 410 GB/s bandwidth
- Metal 4 support (mesh shaders, ICBs, hardware RT, TBDR)
- 3nm process, tile-based deferred rendering architecture

## Current Architecture

### Rendering Pipeline (per frame, single-threaded)

```
GameRenderer.render()
  -> LevelRenderer.renderLevel()
       1. LightEngine.runUpdates(MAX_VALUE)     -- unbounded light updates
       2. Frustum setup                          -- build culling frustum
       3. setupRender()                          -- BFS from camera, build visible chunk list
       4. compileChunksUntil()                   -- drain chunk rebuild queue + GL buffer upload
       5. renderChunkLayer(SOLID)                -- glDrawArrays per non-empty chunk section
       6. renderChunkLayer(CUTOUT_MIPPED)        -- same
       7. renderChunkLayer(CUTOUT)               -- same
       8. Entity rendering                       -- linear scan of ALL world entities
       9. Block entity rendering                 -- iterate TileEntityRenderers
       10. renderChunkLayer(TRANSLUCENT)          -- same, with alpha blending
       11. Particles, clouds, weather
```

Steps 5-7 and 10 are the terrain draw calls (~10,000 total). This is the primary target.

### Terrain Shading

**MC 1.16.5 uses the OpenGL fixed-function pipeline for terrain.** There are no custom GLSL vertex/fragment shaders for chunk rendering. The fixed-function behavior is:

- Vertex: transform by ModelViewProjection matrix, pass through color/UV/lightmap UV
- Fragment: sample block texture atlas (texture unit 0), sample lightmap (texture unit 2), multiply by vertex color

Post-processing shaders exist (`assets/minecraft/shaders/program/`) but only for "Fabulous" mode OIT compositing, FXAA, and effects. These use GLSL 1.10 (`#version 110`).

### Vertex Format: `DefaultVertexFormats.BLOCK`

32 bytes per vertex, used for all chunk geometry:

```
Offset  Size  Type           Name        Description
------  ----  ----           ----        -----------
 0      12    3x float       POSITION    World-space XYZ (chunk-relative)
12       4    4x ubyte       COLOR       RGBA (normalized 0-255 -> 0.0-1.0)
16       8    2x float       UV0         Block texture atlas UV coordinates
24       4    2x short       UV2         Lightmap texture UV (packed shorts)
28       3    3x byte        NORMAL      Surface normal XYZ (signed, normalized)
31       1    1x byte        PADDING     Alignment padding
------  ----
 0      32    TOTAL STRIDE
```

GL vertex attribute setup (per render type):
- Attribute 0: POSITION - 3 floats, offset 0, stride 32
- Attribute 1: COLOR - 4 ubytes normalized, offset 12, stride 32
- Attribute 2: UV0 - 2 floats, offset 16, stride 32
- Attribute 3: UV2 - 2 shorts, offset 24, stride 32
- Attribute 4: NORMAL - 3 bytes normalized, offset 28, stride 32

### Render Types

| Render Type | GL State | Description |
|-------------|----------|-------------|
| SOLID | depth_test, no blend, cull_face | Opaque blocks (stone, dirt, etc.) |
| CUTOUT_MIPPED | depth_test, no blend, cull_face, alpha_test(0.5), mipmap | Leaves, tall grass with mipmapping |
| CUTOUT | depth_test, no blend, cull_face, alpha_test(0.1), no mipmap | Glass panes, flowers |
| TRANSLUCENT | depth_test, blend(SRC_ALPHA, ONE_MINUS_SRC_ALPHA), cull_face | Water, ice, stained glass |

### Chunk Compilation

`ChunkRenderDispatcher` compiles chunks on 4 worker threads (hardcoded cap):
1. Worker thread builds vertex data into a `BufferBuilder` (CPU memory)
2. On render thread: `BufferBuilder.end()` -> `VertexBuffer.upload()` -> `glBufferData(GL_ARRAY_BUFFER, data)`
3. Each `VertexBuffer` holds one chunk section (16x16x16) for one render type
4. ~2000 non-empty chunk sections visible at typical render distance

### Key Classes (Forge-mapped names)

| Class | Role |
|-------|------|
| `WorldRenderer` (net.minecraft.client.renderer) | Main world renderer, owns chunk list and render loop |
| `ChunkRenderDispatcher` | Chunk compilation thread pool + buffer upload |
| `ChunkRenderDispatcher.CompiledChunk` | Compiled vertex data for one chunk section |
| `ChunkRenderDispatcher.ChunkRender` | A single 16x16x16 chunk section |
| `VertexBuffer` | GL VBO wrapper for one chunk's vertex data |
| `TileEntityRendererDispatcher` | Block entity renderer dispatch |
| `DefaultVertexFormats` | Vertex format definitions |
| `GameRenderer` | Top-level render loop |

### Key Fields (reflection targets, with SRG fallbacks)

| Class | Field | Type | SRG Name |
|-------|-------|------|----------|
| WorldRenderer | chunkRenderDispatcher | ChunkRenderDispatcher | field_174995_M |
| WorldRenderer | renderChunksInFrustum | ObjectList | (scan by type) |
| WorldRenderer | globalBlockEntities | Set<TileEntity> | (scan by type) |
| TileEntityRendererDispatcher | renderers | Map<TileEntityType, TileEntityRenderer> | field_147557_n |

### GLFW Window Access

```java
import org.lwjgl.glfw.GLFWNativeCocoa;

long glfwWindow = Minecraft.getInstance().getWindow().getWindow();
long nsWindow = GLFWNativeCocoa.glfwGetCocoaWindow(glfwWindow);
// nsWindow is an NSWindow* pointer (as Java long)
```

Native libraries at: `~/Documents/curseforge/minecraft/Install/natives/forge-36.2.34/`
- `libglfw.dylib`, `liblwjgl.dylib`, `liblwjgl_opengl.dylib`, `libjcocoa.dylib`

---

## Metal Backend Design

### Architecture

```
                      Java (Forge Mod)
                           |
                    [JNI - 1 call/frame]
                           |
                libmetalrenderer.dylib
                    (Objective-C)
                      /         \
            Metal Shaders    MTLIndirectCommandBuffer
            (pre-compiled)    (all chunks, 1 draw)
                      \         /
                   M4 Max GPU (direct)
```

### JNI Interface (`MetalBridge.java`)

```java
package com.example.examplemod.metal;

import java.nio.ByteBuffer;

public class MetalBridge {
    static {
        System.loadLibrary("metalrenderer");
    }

    // Phase B: Initialize Metal device and layer
    public static native boolean init(long nsWindowPtr);
    public static native void shutdown();

    // Phase C: Buffer management (zero-copy via unified memory)
    public static native long createBuffer(int sizeBytes);
    public static native ByteBuffer getBufferContents(long bufferHandle, int sizeBytes);
    public static native void releaseBuffer(long bufferHandle);

    // Phase D: Frame rendering
    public static native void beginFrame(
        float[] viewMatrix,        // 16 floats (4x4 column-major)
        float[] projectionMatrix,  // 16 floats (4x4 column-major)
        float[] chunkOffset,       // 3 floats (camera-relative chunk origin)
        long textureAtlasPtr,      // GL texture ID for block atlas (shared via IOSurface)
        long lightmapPtr           // GL texture ID for lightmap
    );

    // Draw a batch of chunk sections
    public static native void drawChunkBatch(
        long vertexBuffer,         // Metal buffer handle
        int[] offsets,             // byte offset per chunk section
        int[] vertexCounts,        // vertex count per chunk section
        int numChunks,             // number of chunks in this batch
        int renderType             // 0=SOLID, 1=CUTOUT_MIPPED, 2=CUTOUT, 3=TRANSLUCENT
    );

    public static native void endFrame();

    // Diagnostics
    public static native String getDeviceName();
    public static native long getGPUTimeNanos();  // last frame GPU execution time
}
```

### Metal Vertex Descriptor

Matches `DefaultVertexFormats.BLOCK` exactly:

```metal
struct BlockVertex {
    float3 position  [[attribute(0)]];  // offset 0,  12 bytes
    uchar4 color     [[attribute(1)]];  // offset 12,  4 bytes
    float2 uv0       [[attribute(2)]];  // offset 16,  8 bytes
    short2 uv2       [[attribute(3)]];  // offset 24,  4 bytes
    char3  normal    [[attribute(4)]];  // offset 28,  3 bytes
    // 1 byte padding implicit          // offset 31,  1 byte
};                                       // total: 32 bytes
```

### Metal Shaders (MSL)

Replicate the fixed-function pipeline behavior:

```metal
#include <metal_stdlib>
using namespace metal;

struct BlockVertex {
    float3 position  [[attribute(0)]];
    uchar4 color     [[attribute(1)]];
    float2 uv0       [[attribute(2)]];
    short2 uv2       [[attribute(3)]];
    char4  normal    [[attribute(4)]];  // char4 for alignment, use .xyz
};

struct Uniforms {
    float4x4 modelViewProj;
    float3   chunkOffset;    // camera-relative chunk origin
    float2   fogRange;       // fog start, fog end
    float4   fogColor;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv0;
    float2 uv2;
    float3 normal;
    float  fogFactor;
};

vertex VertexOut terrain_vertex(
    BlockVertex in [[stage_in]],
    constant Uniforms& u [[buffer(1)]]
) {
    VertexOut out;

    float3 worldPos = in.position + u.chunkOffset;
    out.position = u.modelViewProj * float4(worldPos, 1.0);

    // Color: ubyte4 normalized to 0-1
    out.color = float4(in.color) / 255.0;

    // Texture UV (block atlas)
    out.uv0 = in.uv0;

    // Lightmap UV: shorts are raw lightmap coords
    // Minecraft lightmap is 16x16, coords are 0-240 packed as shorts
    out.uv2 = float2(in.uv2) / 256.0;

    // Normal
    out.normal = float3(in.normal.xyz) / 127.0;

    // Linear fog
    float dist = length(worldPos);
    out.fogFactor = clamp((u.fogRange.y - dist) / (u.fogRange.y - u.fogRange.x), 0.0, 1.0);

    return out;
}

fragment float4 terrain_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> blockAtlas [[texture(0)]],
    texture2d<float> lightmap   [[texture(1)]],
    sampler atlasSampler        [[sampler(0)]],
    sampler lightmapSampler     [[sampler(1)]],
    constant Uniforms& u        [[buffer(1)]]
) {
    // Sample block texture
    float4 texColor = blockAtlas.sample(atlasSampler, in.uv0);

    // Sample lightmap
    float4 light = lightmap.sample(lightmapSampler, in.uv2);

    // Combine: texture * lightmap * vertex color
    float4 color = texColor * light * in.color;

    // Apply fog
    color.rgb = mix(u.fogColor.rgb, color.rgb, in.fogFactor);

    return color;
}
```

### Render Type Pipeline States

Pre-compile 4 pipeline states (one per render type):

| Render Type | Depth | Blend | Alpha Test | Notes |
|-------------|-------|-------|------------|-------|
| SOLID | write+test | none | none | Fastest path, TBDR gives free HSR |
| CUTOUT_MIPPED | write+test | none | discard if alpha < 0.5 | Mipmapped sampler |
| CUTOUT | write+test | none | discard if alpha < 0.1 | Nearest sampler |
| TRANSLUCENT | test only (no write) | src_alpha, 1-src_alpha | none | Must render back-to-front |

For CUTOUT types, add to fragment shader:
```metal
if (color.a < alphaThreshold) discard_fragment();
```

### Texture Sharing (GL <-> Metal)

The block atlas and lightmap textures are managed by OpenGL. To use them in Metal without copying:

**Option A: IOSurface sharing** (preferred)
- Both OpenGL and Metal can create textures backed by the same `IOSurface`
- `CGLTexImageIOSurface2D()` on GL side, `newTexture(descriptor:iosurface:)` on Metal side
- Zero-copy, both APIs read from the same VRAM

**Option B: Pixel buffer readback** (fallback)
- `glGetTexImage()` to read atlas into CPU memory
- Upload to Metal texture
- Expensive but guaranteed to work
- Only needed once per atlas change (not per frame)

**Option C: Render to Metal texture directly** (future)
- Replace the texture loading pipeline entirely
- Load block textures directly into Metal textures
- Eliminates GL texture dependency

### Dylib Compilation

```bash
# Compile the native Metal renderer
clang -shared -o libmetalrenderer.dylib \
    -framework Metal \
    -framework MetalKit \
    -framework QuartzCore \
    -framework Cocoa \
    -framework IOSurface \
    -I"$JAVA_HOME/include" \
    -I"$JAVA_HOME/include/darwin" \
    -arch arm64 \
    -O2 \
    src/main/native/metal_bridge.m \
    src/main/native/metal_renderer.m \
    src/main/native/metal_shaders.metal

# Or compile shaders separately:
xcrun -sdk macosx metal -c metal_shaders.metal -o metal_shaders.air
xcrun -sdk macosx metallib metal_shaders.air -o default.metallib
```

The dylib goes in `src/main/resources/natives/` and is extracted + loaded at runtime.

### Zero-Copy Buffer Path

```
[Java] ByteBuffer vertexData = MetalBridge.getBufferContents(handle, size);
                |
                | (same physical memory, unified address space)
                v
[Metal] id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:ptr length:size ...]
                |
                | (GPU reads directly, no copy, no upload)
                v
[GPU]   vertex VertexOut terrain_vertex(BlockVertex in [[stage_in]], ...)
```

Critical: `MTLResourceStorageModeShared` on Apple Silicon means CPU and GPU access the same memory. `newBufferWithBytesNoCopy:` wraps existing memory. The Java `DirectByteBuffer` and Metal buffer point to the same physical bytes.

---

## File Structure

```
src/main/
  java/com/example/examplemod/
    ExampleMod.java                    # Entry point, event registration
    metal/
      MetalBridge.java                 # JNI interface to native Metal renderer
      MetalChunkRenderer.java          # Replaces GL chunk rendering with Metal calls
      ChunkDataCapture.java            # Intercepts compiled chunk vertex data
    culling/
      EntityCullingHandler.java        # RenderLivingEvent.Pre distance culling
      BlockEntityCullingHandler.java   # TileEntityRenderer wrapper culling
    profiler/
      RenderProfiler.java             # Frame timing, session summary
    overlay/
      ProfilerOverlay.java            # HUD display
  native/
    metal_bridge.m                     # JNI implementations (Objective-C)
    metal_renderer.m                   # Metal device/pipeline/rendering (Objective-C)
    metal_shaders.metal                # MSL vertex + fragment shaders
    build_native.sh                    # Compile script for dylib
  resources/
    META-INF/mods.toml
    natives/
      libmetalrenderer.dylib           # Compiled native library (built by build_native.sh)
```

---

## Implementation Phases

### Phase A: GPU Profiling (1 session, ~1 hour)

**Goal:** Confirm CPU-bound via GL timer queries. Measure GPU execution time vs frame time.

**Deliverable:** Updated profiler_summary.txt with GPU time column.

**Implementation:**
1. Check if `GL_ARB_timer_query` extension is available (may work on GL 2.1 via extension)
2. If yes: wrap world render pass with `glBeginQuery(GL_TIME_ELAPSED)` / `glEndQuery`
3. Read result from previous frame (async)
4. Add to profiler summary: GPU time avg/p50/p95/p99/max
5. If GPU time << CPU time: confirmed CPU-bound (proceed to Phase B)
6. If timer queries unavailable: use `powermetrics` externally or skip to Phase B

### Phase B: JNI Metal Bridge PoC (1 session, ~2-4 hours)

**Goal:** Render a colored triangle via Metal in the Minecraft window, proving GL + Metal coexistence.

**Deliverables:**
- `metal_bridge.m` with `init()`, `beginFrame()`, `endFrame()`
- `metal_shaders.metal` with simple passthrough vertex/fragment
- `MetalBridge.java` with native method declarations
- `build_native.sh` that produces `libmetalrenderer.dylib`
- Triangle visible on screen alongside normal MC rendering

**Key risks:**
- Can a CAMetalLayer coexist with NSOpenGLContext on the same NSView?
  - Mitigation: use a child NSView with the Metal layer, overlaid on the GL view
  - Alternative: replace the entire view with Metal, composite GL FBO as a texture
- GLFW window handle access via `GLFWNativeCocoa.glfwGetCocoaWindow()`
- dylib loading from a Forge mod (`System.loadLibrary` or extract from jar + `System.load`)

**Validation:** Visual -- human eyes confirm triangle renders without crashing the game.

### Phase C: Chunk Vertex Data Capture (1 session, ~2-3 hours)

**Goal:** Capture compiled chunk vertex data into Metal-accessible buffers.

**Deliverables:**
- `ChunkDataCapture.java` that intercepts `VertexBuffer.upload()` data
- Vertex data stored in Metal shared-memory buffers
- Logging: number of chunks captured, total vertex count, memory usage

**Implementation:**
- Via reflection: access `VertexBuffer`'s GL buffer ID and data
- Or: wrap `VertexBuffer.upload()` to copy data into our Metal buffers simultaneously
- Or: after chunk compilation, read back GL buffer data via `glGetBufferSubData`
- Build a registry: `Map<ChunkPos+RenderType, MetalBufferSlice>`

**Key risk:** Without Mixins, intercepting the upload path requires creative reflection. May need to poll compiled chunks and capture data post-upload via GL readback.

### Phase D: Metal Chunk Renderer (2-3 sessions)

**Goal:** Replace `renderChunkLayer()` for SOLID render type with Metal batched draw.

**Session D1: Single chunk rendering**
- Render one chunk section via Metal using captured vertex data
- Correct vertex format interpretation (validate visually)
- Correct MVP matrix passing
- Block atlas texture sharing via IOSurface

**Session D2: Batched rendering**
- Build MTLIndirectCommandBuffer from visible chunk list
- Single `executeCommandsInBuffer` call for all visible SOLID chunks
- Disable GL rendering for SOLID type (use `RenderWorldLastEvent` timing to compare)

**Session D3: All render types**
- Add CUTOUT_MIPPED, CUTOUT, TRANSLUCENT pipeline states
- Handle alpha testing (discard_fragment in shader)
- Handle translucent blending and sort order
- Lightmap texture sharing

**Validation:** Side-by-side comparison with screenshots. Metal output should match GL output pixel-for-pixel (within floating point tolerance).

### Phase E: Full Pipeline (3+ sessions, future)

- Entity rendering via Metal
- Block entity rendering via Metal
- Particle system via Metal compute shader
- GPU-side frustum culling (compute shader writes ICB)
- GPU-side occlusion culling
- Remove GL dependency entirely for world rendering

---

## Known Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| CAMetalLayer + NSOpenGLContext conflict | High | Child NSView overlay; or replace GL context entirely |
| Mixin crash on Apple Silicon (fastutil bug) | High | Already mitigated: using pure Forge events + reflection |
| GL texture sharing via IOSurface | Medium | Fallback to pixel readback if IOSurface fails |
| Vertex format mismatch (Metal vs GL) | Medium | Validate with known geometry; compare screenshots |
| Pipeline state compilation stalls in Metal | Low | Pre-compile all 4 states at init time |
| Thread safety (chunk compilation + render) | Medium | Metal buffers are CPU-writable from any thread; fence on render thread |
| JNI overhead | Low | One JNI call per frame, not per chunk. ~50ns JNI overhead is negligible |
| Game runs on Java 8 (no Panama FFI) | Low | Standard JNI works fine on Java 8 |
| dylib code signing on macOS | Medium | Ad-hoc sign: `codesign -s - libmetalrenderer.dylib` |

---

## Success Metrics

| Metric | Current (GL 2.1) | Target (Metal) |
|--------|-------------------|----------------|
| Avg frame time | 13.1ms | <5ms |
| p95 frame time | 38.5ms | <10ms |
| p99 frame time | 87.7ms | <16ms |
| Max spike | 741ms | <50ms |
| Effective FPS | 76 | 200+ |
| GPU utilization | <10% | 30-50% |
| Draw calls (terrain) | ~10,000 | 1-5 |
