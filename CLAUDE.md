# SkyFactory One Client-Side Performance Mod

## Goal

Identify and fix client-side rendering bottlenecks in SkyFactory One (Minecraft 1.16.5 + Forge 36.2.34). The server is already running and not our problem. We care about FPS, frame time spikes, and rendering throughput on the client.

## Build & Deploy

```bash
# One-liner: build mod jar and copy to SkyFactory mods folder
./build.sh

# Or manually:
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew build --no-daemon
cp build/libs/modid-1.0.jar ~/Documents/curseforge/minecraft/Instances/SkyFactory\ One/mods/patched-overlay-1.0.jar
```

Launch from CurseForge (handles Microsoft auth). CLI launch script exists at `./launch.sh` but only works offline.

## Java Versions

- **Gradle build**: Java 17 (`/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`)
- **Game runtime**: Java 8 (`~/Documents/curseforge/minecraft/Install/java/jre-legacy/Contents/Home/bin/java`)
- **build.gradle toolchain**: targets Java 8

## File Locations

```
~/skyfactory-dev/                              # This project (Forge MDK workspace)
  src/main/java/com/example/examplemod/        # Mod source
    ExampleMod.java                            # Entry point, join message handler
    PatchedOverlay.java                        # HUD overlay (red "[PATCHED]" text)
  src/main/resources/META-INF/mods.toml        # Mod metadata
  build.sh                                     # Build + deploy script
  launch.sh                                    # CLI launch (offline only)

~/Documents/curseforge/minecraft/
  Install/
    versions/1.16.5/1.16.5.jar                 # Vanilla client jar (obfuscated)
    versions/forge-36.2.34/forge-36.2.34.jar   # Forge jar
    libraries/org/lwjgl/                       # LWJGL 3.2.1 (OpenGL bindings)
    java/jre-legacy/                           # Bundled Java 8
    assets/                                    # Game assets
    natives/                                   # Native libraries
  Instances/SkyFactory One/
    mods/                                      # ~80+ mod jars, our jar goes here
    config/                                    # Mod configs

/tmp/mc-decompile/
  client_mappings.txt                          # Mojang official mappings for 1.16.5
  decompiled/                                  # CFR-decompiled classes (obfuscated names)
    eae.java                                   # LevelRenderer
    ecu.java                                   # ChunkRenderDispatcher
    dzz.java                                   # GameRenderer
    com/mojang/blaze3d/systems/RenderSystem.java
```

## Mappings (obfuscated -> real names)

The vanilla jar uses obfuscated class names. Mojang mappings at `/tmp/mc-decompile/client_mappings.txt`.

| Real Name | Obfuscated | Role |
|-----------|-----------|------|
| `net.minecraft.client.renderer.LevelRenderer` | `eae` | Main world renderer (chunks, entities, block entities) |
| `net.minecraft.client.renderer.chunk.ChunkRenderDispatcher` | `ecu` | Chunk compilation thread pool + GPU upload |
| `net.minecraft.client.renderer.GameRenderer` | `dzz` | Top-level render loop |
| `com.mojang.blaze3d.systems.RenderSystem` | (not obfuscated) | OpenGL wrapper |
| `net.minecraft.client.renderer.entity.EntityRenderDispatcher` | `eet` | Entity rendering dispatch |
| `net.minecraft.client.renderer.entity.EntityRenderer` | `eeu` | Base entity renderer |
| `net.minecraft.client.renderer.chunk.ChunkRenderDispatcher$RenderChunk` | `ecu$c` | Single chunk section (16x16x16) |
| `net.minecraft.client.renderer.chunk.ChunkRenderDispatcher$CompiledChunk` | `ecu$b` | Compiled chunk data |
| `net.minecraft.client.renderer.chunk.VisGraph` | `ecw` | Occlusion/visibility graph per chunk |
| `net.minecraft.client.renderer.chunk.RenderChunkRegion` | `ecv` | 3x3 chunk snapshot for compilation |

ForgeGradle uses `official` mappings channel. **Method/field names** use Mojang's official names (e.g. `renderLevel`, `chunkRenderDispatcher`). **Class names** use MCP/SRG intermediary names, NOT Mojang names:

| Mojang Class Name | Dev Class Name (use this in code) |
|---|---|
| `LevelRenderer` | `WorldRenderer` (`net.minecraft.client.renderer.WorldRenderer`) |
| `PoseStack` | `MatrixStack` (`com.mojang.blaze3d.matrix.MatrixStack`) |
| `Camera` | `ActiveRenderInfo` (`net.minecraft.client.renderer.ActiveRenderInfo`) |
| `Matrix4f` | `Matrix4f` (`net.minecraft.util.math.vector.Matrix4f`) |
| `ProfilerFiller` | `IProfiler` (`net.minecraft.profiler.IProfiler`) |
| `KeyMapping` | `KeyBinding` (`net.minecraft.client.settings.KeyBinding`) |
| `ChunkRenderDispatcher` | `ChunkRenderDispatcher` (same) |
| `GameRenderer` | `GameRenderer` (same) |
| `LightTexture` | `LightTexture` (same) |
| `TileEntity` | `TileEntity` (`net.minecraft.tileentity.TileEntity`) |

## Graphics API

**OpenGL** via LWJGL 3.2.1. NOT Metal, NOT Vulkan.

On macOS (M4 Max), this runs through Apple's deprecated OpenGL framework, capped at OpenGL 4.1. The GPU sits mostly idle; bottleneck is CPU-side draw call overhead through Apple's broken GL driver. No compute shaders, no DSA, no bindless textures, no multi-draw indirect.

## Rendering Pipeline (per frame)

All runs on the render thread (single-threaded):

```
GameRenderer.render()
  -> LevelRenderer.renderLevel()
       1. Light updates              -- LightEngine.runUpdates(MAX_VALUE) -- UNBOUNDED
       2. Frustum setup              -- build culling frustum
       3. setupRender()              -- BFS flood-fill from camera chunk, builds visible chunk list
       4. compileChunksUntil()       -- drain chunk rebuild queue + GPU upload
       5. renderChunkLayer(solid)    -- one glDrawArrays per non-empty chunk section
       6. renderChunkLayer(cutout_mipped)
       7. renderChunkLayer(cutout)
       8. Entity rendering           -- linear scan of ALL world entities
       9. Block entity rendering     -- iterate all visible TileEntity renderers
       10. renderChunkLayer(translucent)
       11. Particles, clouds, weather
```

## The 6 Client-Side Bottlenecks (ranked for SkyFactory)

### 1. Entity Rendering (LevelRenderer, line ~946 in decompiled eae.java)
- Single-threaded loop over **every entity in the world**
- No spatial index; frustum culling inside the loop, not before
- Each entity = separate render call
- SkyFactory impact: mob farms, item entities on conveyors, AE2 patterns, Botania sparks

### 2. Block Entity (TileEntity) Rendering (LevelRenderer, line ~973-1003)
- Sequential iteration of all visible TileEntityRenderers
- `synchronized(globalBlockEntities)` contends with chunk loading threads
- SkyFactory impact: every Mekanism machine, AE2 interface, Industrial Foregoing block

### 3. Per-Chunk Draw Calls (LevelRenderer.renderChunkLayer, line ~1133)
- One `glDrawArrays` per non-empty chunk section per render type
- 5 render types x ~2000 non-empty sections = ~10,000 draw calls/frame for terrain
- No batching, no instancing, no multi-draw indirect
- macOS OpenGL driver makes each draw call 2-3x more expensive than Windows/NVIDIA

### 4. Chunk Compilation Thread Cap (ChunkRenderDispatcher, line ~97)
- Worker threads **capped at 4** regardless of CPU core count
- M4 Max has way more cores but only 4 used
- Buffer pool capped at 30% of heap, causes starvation

### 5. Synchronous Chunk Rebuilds (LevelRenderer, line ~1692)
- Player breaks/places block -> chunk rebuilt **on the render thread** (rebuildChunkSync)
- `uploadAllPendingUploads()` drains entire upload queue with no time budget
- Frame stall every player block interaction

### 6. Unbounded Light Updates (LevelRenderer, line ~875)
- `LightEngine.runUpdates(MAX_VALUE, true, true)` -- processes ALL pending updates
- Breaking a block in a dark cave = cascading light recalculations that freeze the frame

## Implementation Plan

### Phase 1: Instrumentation (do this first)
Build a profiling overlay that shows per-frame timing for each pipeline stage. This tells us exactly where time is going in practice, not just in theory.

- Hook `RenderGameOverlayEvent.Post` to draw timing data on screen
- Use `RenderWorldLastEvent` or Mixin into `LevelRenderer.renderLevel()` to measure:
  - Entity render time (ms) + entity count
  - Block entity render time (ms) + count
  - Chunk layer draw time per render type
  - Chunk compile queue depth
  - Light update count
- Show top-N most expensive entities and block entities by render time
- Log to file for offline analysis

### Phase 2: Entity Culling
- Mixin into `LevelRenderer.renderLevel()` entity loop
- Add distance-based LOD: skip entity rendering beyond configurable distance
- Add occlusion culling: use depth buffer from terrain pass to skip entities behind walls
- Add rate limiting: render distant entities every Nth frame instead of every frame

### Phase 3: Block Entity Batching
- Mixin to batch TileEntity renders by type (all Mekanism machines together, etc.)
- Skip TileEntity rendering for blocks outside frustum (some mods don't check)
- Add distance-based LOD for TileEntity renderers

### Phase 4: Chunk Upload Budgeting
- Mixin into `ChunkRenderDispatcher.uploadAllPendingUploads()` to add a per-frame time budget
- Mixin into `compileChunksUntil()` to avoid synchronous rebuilds when possible
- Increase thread cap from 4 to match available cores

### Phase 5: Light Update Budgeting
- Mixin into the light update call to cap updates per frame
- Spread cascading light updates across multiple frames

## Forge Modding Notes

- Forge uses `cpw.mods.modlauncher.Launcher` as entry point, not vanilla Main
- Mod jars dropped in `mods/` are auto-discovered
- Use Forge events (`RenderGameOverlayEvent`, `RenderWorldLastEvent`, `EntityJoinWorldEvent`) for non-invasive hooks
- Use Mixins for deeper patches (need `mixin` dependency + refmap in build.gradle if going that route)
- ForgeGradle `official` mappings = Mojang names in source, auto-reobfuscated at build time
- `jar.finalizedBy('reobfJar')` in build.gradle handles SRG remapping for production

## Current State

- Forge MDK workspace set up and compiling with Mixin support (MixinGradle 0.7)
- **Phase 1 (Instrumentation) deployed**: render profiler overlay with per-stage timing
- Mixin into `WorldRenderer.renderLevel()` at 6 injection points (HEAD, RETURN, and 4 INVOKE_STRING at profiler section transitions)
- Refmap generated and verified: maps official -> SRG names for production
- HUD overlay shows: light updates, terrain setup, chunks+terrain, entities, block entities timing (ms + color-coded bars)
- Also shows entity/block entity counts and chunk dispatcher queue depth
- F6 toggles overlay, F7 toggles CSV logging to `<gameDir>/profiler_logs/`
- `LevelRendererAccessor` mixin provides access to private `chunkRenderDispatcher` field
- Decompiled key rendering classes available at `/tmp/mc-decompile/decompiled/`
- Mojang mappings downloaded for cross-referencing obfuscated bytecode
- CFR decompiler installed (`cfr-decompiler`)

### Key SRG Mappings (for production/runtime)

| Official Name | SRG Name |
|---|---|
| `WorldRenderer.renderLevel()` | `func_228426_a_` |
| `IProfiler.popPush(String)` | `func_219895_b` |
| `WorldRenderer.chunkRenderDispatcher` | `field_174995_M` |
