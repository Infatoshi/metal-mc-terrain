# Metal Terrain Renderer for Minecraft 1.16.5 (Forge)

**10x client FPS on Apple Silicon by replacing macOS OpenGL with native Metal.**

Minecraft on macOS runs through Apple's deprecated OpenGL-to-Metal translation layer. Every `glDrawArrays` call costs ~5us of CPU overhead. With ~10,000 draw calls per frame for terrain alone, the CPU spends ~50ms just submitting commands while the GPU sits idle at <10% utilization.

This mod replaces the entire GL terrain rendering path with a native Metal backend. 4 draw calls replace 10,000. The M4 Max GPU finally gets fed.

## Results

Tested on SkyFactory One (80+ mods, loaded factory base with machines, mob farms, conveyors):

| Config | Avg FPS | Range | Frame Time |
|--------|---------|-------|------------|
| Baseline (Rosetta + Java 11 + GL) | ~20-30 | 5-76 | 13-200ms |
| arm64 Java 17 + ZGC | ~80-120 | 40-198 | 5-25ms |
| **+ Metal terrain + CPU culling** | **~300** | **200-1000** | **1-5ms** |

The baseline numbers are with all SkyFactory mods loaded in a real factory world -- not a flat test world.

## What It Does

### Metal Terrain Renderer (the big win)
- Native Metal rendering via JNI (`libmetalrenderer.dylib`)
- Extracts chunk vertex data from GL VBOs, uploads to Metal staging buffers
- Tight-packed vertex layout with embedded `chunkId` -- one indexed draw per render type
- CAMetalLayer composited over the GL context (entities/HUD still render via GL)
- Quad-to-triangle conversion via global uint32 index buffer
- GPU time for terrain: ~0.05ms (was ~2.1ms through GL translation)

### CPU-Side Optimizations
- **Entity culling**: Distance + frustum + rate limiting. 60% of entities skipped per frame.
- **Block entity culling**: 85% of TileEntity renders skipped (Mekanism machines, AE2 interfaces, etc.)
- **Chunk upload budgeting**: Per-frame time cap prevents block-break stalls
- **arm64 + ZGC**: Native Apple Silicon JVM eliminates Rosetta overhead. ZGC gives <1ms GC pauses.

### Runtime Controls
- **F8**: Toggle Metal terrain on/off (A/B compare with GL baseline)
- **F6**: Toggle profiler overlay (per-stage timing, entity counts, GPU time)

## Architecture

```
Java (Forge mod)
  MetalTerrainRenderer.java    -- extracts GL VBOs, uploads to Metal, drives frame
  MetalBridge.java             -- JNI declarations (27 native methods)
  WorldRendererMixin.java      -- cancels GL terrain when Metal active
  EntityCullingHandler.java    -- distance/frustum/rate culling
  BlockEntityCullingHandler.java -- TileEntity render wrapping

Native (Objective-C + Metal Shading Language)
  metal_terrain.m              -- terrain rendering: tight-packed draws, index buffers
  metal_renderer.m             -- Metal device init, CAMetalLayer setup
  metal_bridge.m               -- JNI bridge functions
  metal_terrain.h              -- public API
```

### Tight-Packed Vertex Layout

The key optimization. Standard instanced rendering pads each chunk to `maxVertexCount`, wasting ~97% of GPU bandwidth on zero-padded degenerate triangles. Our tight-packed layout:

1. Pack all chunk vertices contiguously in a staging buffer
2. Stamp a 16-bit `chunkId` into each vertex (replaces unused normal bytes)
3. Build a global uint32 index buffer mapping quads to triangles across all chunks
4. Single `drawIndexedPrimitives` call per render type

Benchmark (`bench/metal_bench_bandwidth.m`):
- Slot-based instanced: 0.147ms, 310 GB/s (76% of M4 Max bandwidth -- on padding waste)
- Tight-packed: 0.049ms, 9 MB/frame (3x faster, not bandwidth-bound)

## Requirements

- **macOS** on Apple Silicon (M1/M2/M3/M4)
- **Java 17** (arm64 native -- Homebrew `openjdk@17`)
- **Minecraft 1.16.5 + Forge 36.2.34**
- **Xcode Command Line Tools** (for building native library)

## Building

```bash
# 1. Build native Metal library (requires Xcode CLT)
cd src/main/native
bash build_native.sh

# 2. Build mod jar
cd ../../..
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ./gradlew build --no-daemon

# 3. Copy to your Minecraft mods folder
cp build/libs/modid-1.0.jar /path/to/your/mods/folder/
```

Or use the one-liner: `./build.sh` (edit paths inside first).

### Launch Script

The included `launch-arm64-zgc.sh` configures:
- arm64 Java 17 (no Rosetta)
- ZGC garbage collector
- LWJGL 3.3.1 arm64 natives
- Required `--add-opens` flags for Forge on Java 17

You'll need to set up:
- LWJGL 3.3.1 arm64 jars in `/tmp/lwjgl-arm64/`
- LWJGL 3.3.1 arm64 native dylibs in `/tmp/mc-natives-arm64/`
- Microsoft auth (the script calls `refresh_token.py` which you'll need to provide)

## Benchmarks

The `bench/` directory contains standalone Metal benchmarks that run outside Minecraft:

```bash
cd bench

# Compile and run bandwidth benchmark (slot vs tight packing)
clang -O2 -framework Metal -framework QuartzCore -framework Cocoa \
  metal_bench_bandwidth.m -o metal_bench_bandwidth
./metal_bench_bandwidth

# Other benchmarks: metal_bench.m, metal_bench_opt.m, metal_bench_v2.m
```

## For AI Agents / LLMs

If you're an AI agent pointed at this repo and told to "make Minecraft faster on Mac" or "get this working" -- read **[LLMs.md](LLMs.md)**. It has step-by-step instructions with verification commands for every stage, common failure modes, and architecture notes. It assumes nothing about the user's setup and walks through the entire process from zero to running game.

This project was built entirely by Claude (Opus 4.6) via Claude Code. An AI agent can reproduce the full setup, diagnose crashes from error messages, and adapt the mod to different modpacks -- all from the terminal.

## Why This Matters

Apple deprecated OpenGL in 2018. The translation layer gets worse, not better. Every Mac sold today has a Metal GPU that Minecraft can't use. On an M4 Max (32 GPU cores, 410 GB/s bandwidth), Minecraft's GL renderer uses <10% of available GPU power.

This isn't a Minecraft problem -- it's a macOS OpenGL problem. Any Java application using LWJGL on macOS pays the same tax. The right long-term fix is a Vulkan backend in Sodium (which MoltenVK would translate to Metal), but until that exists, native Metal via JNI works now.

## License

MIT
