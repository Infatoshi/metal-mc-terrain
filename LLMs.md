# LLMs.md -- Instructions for AI Agents

You are an AI agent tasked with getting this Metal terrain renderer working end-to-end on the user's Apple Silicon Mac. This file contains everything you need. Read it fully before doing anything.

## What This Is

A Forge mod for Minecraft 1.16.5 that replaces macOS OpenGL terrain rendering with native Metal. It achieved 10x FPS improvement on SkyFactory One (a heavily modded Minecraft pack). The same approach should work for any Minecraft 1.16.5 + Forge modpack on Apple Silicon.

## End-to-End Setup (Zero to Running Game)

Follow these steps in order. Each step has a verification command. Do not proceed until verification passes.

### Step 1: Check Hardware

```bash
uname -m
# MUST output: arm64
# If x86_64, this mod won't help. Stop here.

system_profiler SPHardwareDataType | grep "Chip"
# Should show M1, M2, M3, M4, or variant
```

### Step 2: Install Dependencies

```bash
# Java 17 arm64 (for both building and running)
brew install openjdk@17

# Verify
/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java -version
# Must show: openjdk version "17.x.x" and aarch64

# Xcode Command Line Tools (for compiling native Metal library)
xcode-select --install
# If already installed, this errors -- that's fine

# Verify
xcrun -sdk macosx metal --version
# Must show Metal compiler version
```

### Step 3: Download LWJGL 3.3.1 arm64

Minecraft ships LWJGL 3.2.1 (x86_64 only). We need 3.3.1 with arm64 natives.

```bash
mkdir -p /tmp/lwjgl-arm64 /tmp/mc-natives-arm64

# Download LWJGL 3.3.1 Java jars
cd /tmp/lwjgl-arm64
for lib in lwjgl lwjgl-glfw lwjgl-opengl lwjgl-openal lwjgl-stb lwjgl-jemalloc lwjgl-tinyfd; do
  curl -sLO "https://repo1.maven.org/maven2/org/lwjgl/${lib}/3.3.1/${lib}-3.3.1.jar"
done

# Download and extract arm64 native dylibs
for lib in lwjgl lwjgl-glfw lwjgl-opengl lwjgl-openal lwjgl-stb lwjgl-jemalloc lwjgl-tinyfd; do
  curl -sL "https://repo1.maven.org/maven2/org/lwjgl/${lib}/3.3.1/${lib}-3.3.1-natives-macos-arm64.jar" -o native.jar
  unzip -o native.jar "*.dylib" -d /tmp/mc-natives-arm64/ 2>/dev/null
  rm native.jar
done

# Verify
ls /tmp/lwjgl-arm64/*.jar | wc -l
# Must be 7

ls /tmp/mc-natives-arm64/*.dylib | wc -l
# Must be 7+
```

### Step 4: Build the Native Metal Library

```bash
cd src/main/native
bash build_native.sh
```

**Verify:**
```bash
file src/main/resources/natives/libmetalrenderer.dylib
# Must contain: arm64

nm -g src/main/resources/natives/libmetalrenderer.dylib | grep terrainRender
# Must show: T _Java_com_example_examplemod_metal_MetalBridge_terrainRender
```

**If build fails:**
- "metal: command not found" -- install Xcode CLT: `xcode-select --install`
- "jni.h not found" -- set `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`
- Linker errors about frameworks -- you need macOS SDK, comes with Xcode CLT

### Step 5: Build the Mod Jar

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ./gradlew build --no-daemon
```

**Verify:**
```bash
jar tf build/libs/modid-1.0.jar | grep -c "\.class\|\.dylib"
# Must be 15+ (14 classes + 1 dylib)
```

### Step 6: Install Minecraft + Forge

The user needs Minecraft 1.16.5 + Forge 36.2.34 installed. This is typically done through CurseForge or Prism Launcher. Ask the user:

> "Do you have Minecraft 1.16.5 with Forge 36.2.34 installed? If you're using a modpack like SkyFactory One, it includes Forge already. I need the path to your Minecraft instance."

You need to find these paths (ask the user if you can't locate them):

```bash
# Common locations:
# CurseForge:
GAME_DIR="$HOME/Documents/curseforge/minecraft/Instances/<INSTANCE_NAME>"
LIBS="$HOME/Documents/curseforge/minecraft/Install/libraries"
ASSETS="$HOME/Documents/curseforge/minecraft/Install/assets"

# Prism Launcher:
GAME_DIR="$HOME/Library/Application Support/PrismLauncher/instances/<INSTANCE_NAME>/.minecraft"
LIBS="$HOME/Library/Application Support/PrismLauncher/libraries"
ASSETS="$HOME/Library/Application Support/PrismLauncher/assets"

# MultiMC:
GAME_DIR="$HOME/Library/Application Support/MultiMC/instances/<INSTANCE_NAME>/.minecraft"
```

**Verify the instance exists:**
```bash
ls "$GAME_DIR/mods/" | head -5
# Should show .jar files if it's a modded instance
```

### Step 7: Deploy the Mod

```bash
cp build/libs/modid-1.0.jar "$GAME_DIR/mods/metal-terrain-1.0.jar"
```

### Step 8: Set Up Authentication

Minecraft requires Microsoft account auth. The user must provide credentials. Ask them:

> "I need to launch Minecraft from the terminal. Can you provide your Microsoft account access token, UUID, and username? The easiest way is to launch the game once from CurseForge/Prism, then check the launcher logs for the --accessToken, --uuid, and --username values."

**How to extract auth from launcher logs:**
- **CurseForge**: Check `~/.curseforge/minecraft/Install/launcher_log.txt` or process list while game is running
- **Prism**: Settings > Java > "Show console while game is running", copy the launch command
- **Alternative**: Write a `refresh_token.py` that reads from the launcher's accounts database

Store the credentials:
```bash
# Create auth script that the launch script will call
cat > refresh_token.py << 'PYEOF'
# The user needs to fill in their credentials here.
# These can be extracted from their launcher's accounts database.
print("TOKEN=<access_token>")
print("UUID=<uuid>")
print("NAME=<username>")
PYEOF
```

**IMPORTANT:** Never commit auth tokens to git. `refresh_token.py` is in `.gitignore`.

### Step 9: Create the Launch Script

The launch script needs paths specific to the user's machine. Generate it:

```bash
cat > launch.sh << 'LAUNCH_EOF'
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAVA="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java"
GAME_DIR="__GAME_DIR__"          # <-- FILL THIS IN
ASSETS_DIR="__ASSETS_DIR__"      # <-- FILL THIS IN
LIBS="__LIBS_DIR__"              # <-- FILL THIS IN
NATIVES_DIR="/tmp/mc-natives-arm64"
LWJGL="/tmp/lwjgl-arm64"

# Auth
AUTH_OUTPUT=$(python3 "$SCRIPT_DIR/refresh_token.py")
TOKEN=$(echo "$AUTH_OUTPUT" | grep "^TOKEN=" | cut -d= -f2-)
UUID=$(echo "$AUTH_OUTPUT" | grep "^UUID=" | cut -d= -f2-)
NAME=$(echo "$AUTH_OUTPUT" | grep "^NAME=" | cut -d= -f2-)

if [ -z "$TOKEN" ] || [ -z "$UUID" ]; then
    echo "ERROR: Auth failed. Edit refresh_token.py with your credentials."
    exit 1
fi
echo "Authenticated as $NAME"

cd "$GAME_DIR"

# Build classpath from Forge libraries
CP=""
for jar in \
  "$LIBS/net/minecraftforge/forge/1.16.5-36.2.34/forge-1.16.5-36.2.34.jar" \
  "$LIBS/org/ow2/asm/asm/9.1/asm-9.1.jar" \
  "$LIBS/org/ow2/asm/asm-commons/9.1/asm-commons-9.1.jar" \
  "$LIBS/org/ow2/asm/asm-tree/9.1/asm-tree-9.1.jar" \
  "$LIBS/org/ow2/asm/asm-util/9.1/asm-util-9.1.jar" \
  "$LIBS/org/ow2/asm/asm-analysis/9.1/asm-analysis-9.1.jar" \
  "$LIBS/cpw/mods/modlauncher/8.1.3/modlauncher-8.1.3.jar" \
  "$LIBS/cpw/mods/grossjava9hacks/1.3.3/grossjava9hacks-1.3.3.jar" \
  "$LIBS/net/minecraftforge/accesstransformers/3.0.1/accesstransformers-3.0.1.jar" \
  "$LIBS/org/antlr/antlr4-runtime/4.9.1/antlr4-runtime-4.9.1.jar" \
  "$LIBS/net/minecraftforge/eventbus/4.0.0/eventbus-4.0.0.jar" \
  "$LIBS/net/minecraftforge/forgespi/3.2.0/forgespi-3.2.0.jar" \
  "$LIBS/net/minecraftforge/coremods/4.0.6/coremods-4.0.6.jar" \
  "$LIBS/net/minecraftforge/unsafe/0.2.0/unsafe-0.2.0.jar" \
  "$LIBS/com/electronwill/night-config/core/3.6.3/core-3.6.3.jar" \
  "$LIBS/com/electronwill/night-config/toml/3.6.3/toml-3.6.3.jar" \
  "$LIBS/org/jline/jline/3.12.1/jline-3.12.1.jar" \
  "$LIBS/org/apache/maven/maven-artifact/3.6.3/maven-artifact-3.6.3.jar" \
  "$LIBS/net/jodah/typetools/0.8.3/typetools-0.8.3.jar" \
  "$LIBS/org/apache/logging/log4j/log4j-api/2.15.0/log4j-api-2.15.0.jar" \
  "$LIBS/org/apache/logging/log4j/log4j-core/2.15.0/log4j-core-2.15.0.jar" \
  "$LIBS/org/apache/logging/log4j/log4j-slf4j18-impl/2.15.0/log4j-slf4j18-impl-2.15.0.jar" \
  "$LIBS/net/minecrell/terminalconsoleappender/1.2.0/terminalconsoleappender-1.2.0.jar" \
  "$LIBS/net/sf/jopt-simple/jopt-simple/5.0.4/jopt-simple-5.0.4.jar" \
  "$LIBS/org/spongepowered/mixin/0.8.4/mixin-0.8.4.jar" \
  "$LIBS/net/minecraftforge/nashorn-core-compat/15.1.1.1/nashorn-core-compat-15.1.1.1.jar" \
  "$LIBS/com/mojang/patchy/1.3.9/patchy-1.3.9.jar" \
  "$LIBS/oshi-project/oshi-core/1.1/oshi-core-1.1.jar" \
  "$LIBS/net/java/dev/jna/jna/4.4.0/jna-4.4.0.jar" \
  "$LIBS/net/java/dev/jna/platform/3.4.0/platform-3.4.0.jar" \
  "$LIBS/com/ibm/icu/icu4j/66.1/icu4j-66.1.jar" \
  "$LIBS/com/mojang/javabridge/1.0.22/javabridge-1.0.22.jar" \
  "$LIBS/net/sf/jopt-simple/jopt-simple/5.0.3/jopt-simple-5.0.3.jar" \
  "$LIBS/io/netty/netty-all/4.1.25.Final/netty-all-4.1.25.Final.jar" \
  "$LIBS/com/google/guava/guava/21.0/guava-21.0.jar" \
  "$LIBS/org/apache/commons/commons-lang3/3.5/commons-lang3-3.5.jar" \
  "$LIBS/commons-io/commons-io/2.5/commons-io-2.5.jar" \
  "$LIBS/commons-codec/commons-codec/1.10/commons-codec-1.10.jar" \
  "$LIBS/net/java/jinput/jinput/2.0.5/jinput-2.0.5.jar" \
  "$LIBS/net/java/jutils/jutils/1.0.0/jutils-1.0.0.jar" \
  "$LIBS/com/mojang/brigadier/1.0.17/brigadier-1.0.17.jar" \
  "$LIBS/com/mojang/datafixerupper/4.0.26/datafixerupper-4.0.26.jar" \
  "$LIBS/com/google/code/gson/gson/2.8.0/gson-2.8.0.jar" \
  "$LIBS/com/mojang/authlib/2.1.28/authlib-2.1.28.jar" \
  "$LIBS/org/apache/commons/commons-compress/1.8.1/commons-compress-1.8.1.jar" \
  "$LIBS/org/apache/httpcomponents/httpclient/4.3.3/httpclient-4.3.3.jar" \
  "$LIBS/commons-logging/commons-logging/1.1.3/commons-logging-1.1.3.jar" \
  "$LIBS/org/apache/httpcomponents/httpcore/4.3.2/httpcore-4.3.2.jar" \
  "$LIBS/it/unimi/dsi/fastutil/8.5.15/fastutil-8.5.15.jar" \
  "$LIBS/com/mojang/text2speech/1.11.3/text2speech-1.11.3.jar" \
  "$LIBS/ca/weblite/java-objc-bridge/1.0.0/java-objc-bridge-1.0.0.jar" \
; do
  CP="$CP:$jar"
done

# Add LWJGL 3.3.1 arm64 jars
for jar in "$LWJGL"/*.jar; do
  CP="$CP:$jar"
done

# Add vanilla client
CP="$CP:__VERSIONS_DIR__/1.16.5/1.16.5.jar"  # <-- FILL THIS IN

exec "$JAVA" \
  -XstartOnFirstThread \
  -Xmx6G -Xms4G \
  -XX:+UseZGC \
  -XX:ConcGCThreads=4 \
  -XX:+AlwaysPreTouch \
  -XX:+ParallelRefProcEnabled \
  -Dfml.earlyprogresswindow=false \
  --add-opens java.base/java.lang.reflect=ALL-UNNAMED \
  --add-opens java.base/java.lang=ALL-UNNAMED \
  --add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.io=ALL-UNNAMED \
  --add-opens java.base/java.net=ALL-UNNAMED \
  --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
  --add-opens java.base/java.nio=ALL-UNNAMED \
  --add-opens java.base/java.security=ALL-UNNAMED \
  --add-opens java.base/sun.security.ssl=ALL-UNNAMED \
  --add-exports java.base/sun.security.util=ALL-UNNAMED \
  --add-opens java.base/sun.security.util=ALL-UNNAMED \
  --add-opens java.base/java.util.jar=ALL-UNNAMED \
  --add-opens java.base/jdk.internal.misc=ALL-UNNAMED \
  -Djava.library.path="$NATIVES_DIR" \
  -Dforge.logging.console.level=info \
  -cp "${CP#:}" \
  cpw.mods.modlauncher.Launcher \
  --launchTarget fmlclient \
  --fml.forgeVersion 36.2.34 \
  --fml.mcVersion 1.16.5 \
  --fml.forgeGroup net.minecraftforge \
  --fml.mcpVersion 20210115.111550 \
  --gameDir "$GAME_DIR" \
  --assetsDir "$ASSETS_DIR" \
  --assetIndex 1.16 \
  --username "$NAME" \
  --uuid "$UUID" \
  --accessToken "$TOKEN" \
  --userType msa \
  --version forge-36.2.34 \
  --versionType release
LAUNCH_EOF
chmod +x launch.sh
```

Replace the `__FILL_THIS_IN__` placeholders with the paths found in Step 6.

### Step 10: Launch and Verify

```bash
./launch.sh
```

**In-game verification:**
1. Join a world/server
2. You should see a chat message: `[PERF] Profiler + culling on. Metal terrain active | GL terrain suppressed`
3. Press **F6** to see the profiler overlay -- look for "Metal GPU" timing
4. Press **F8** to toggle Metal off -- FPS should drop significantly (this is the A/B test)
5. Press **F8** again to re-enable Metal

**If the game crashes:**
- Check the crash report at `$GAME_DIR/crash-reports/`
- `UnsatisfiedLinkError`: The native dylib didn't load. Run `build_native.sh` again and verify it copied to `/tmp/mc-natives-arm64/`
- `ClassNotFoundException` for mixin: Forge version mismatch. Must be exactly 36.2.34
- Black screen or invisible terrain: This was fixed (alpha compositing bug). Make sure you built from latest source.

## Common Bugs and Fixes

### Stale dylib (UnsatisfiedLinkError)
`build_native.sh` copies the dylib to both `src/main/resources/natives/` (for jar packaging) AND `/tmp/mc-natives-arm64/` (for `java.library.path`). If you only rebuilt the jar but not the native lib, the old dylib at `/tmp/mc-natives-arm64/` gets loaded first. Always run `build_native.sh` before `gradlew build`.

### CAMetalLayer alpha (invisible terrain)
The fragment shader MUST output `color.a = 1.0`. The CAMetalLayer has `opaque=NO` for transparent compositing over GL. Without forced alpha, nil textures produce alpha=0 and terrain is invisible. This is already fixed in the current code.

### Metal float3 alignment (wrong rendering after chunk 0)
Metal `float3` is 16 bytes, not 12. Use `packed_float3` in shader struct definitions when matching C struct layouts. Symptom: first chunk renders correctly, all others are displaced or invisible.

### Catch Throwable not Exception
`UnsatisfiedLinkError` extends `Error`, not `Exception`. The render loop catches `Throwable` to degrade gracefully instead of crashing the game.

## Architecture Notes for Modifications

### How it works
1. `MetalIntegration.java` initializes Metal on first render tick (gets NSWindow from GLFW, creates CAMetalLayer)
2. `MetalTerrainRenderer.java` hooks `RenderWorldLastEvent` to:
   - Extract visible chunks from `WorldRenderer.renderChunksInFrustum` via reflection
   - Read vertex data from GL VBOs via `glGetBufferSubData`
   - Upload to Metal staging buffers via JNI (`MetalBridge.terrainSetChunk`)
   - Render via Metal (`MetalBridge.terrainRender`)
3. `WorldRendererMixin.java` cancels GL terrain rendering when Metal is active
4. Entity/block entity rendering stays on GL (composited under the Metal layer)

### Key files
- `metal_terrain.m`: All terrain rendering logic (shaders, pipelines, draw calls)
- `metal_bridge.m`: JNI bridge (thin wrappers calling into metal_terrain.m)
- `metal_renderer.m`: Metal device/layer initialization
- `MetalTerrainRenderer.java`: Java-side orchestration (reflection, GL readback, frame management)

### ForgeGradle mapping gotcha
The `official` mappings channel uses MCP/SRG **class names** but Mojang **method/field names**:
- `WorldRenderer` not `LevelRenderer`
- `MatrixStack` not `PoseStack`
- `ActiveRenderInfo` not `Camera`
- See the mapping table in `CLAUDE.md` for the full list

### Vertex format
Minecraft 1.16.5 BLOCK format: 32 bytes per vertex
```
offset 0:  float3  position  (12 bytes)
offset 12: uchar4  color     (4 bytes)
offset 16: float2  uv0       (8 bytes) -- block atlas texture coords
offset 24: short2  uv2       (4 bytes) -- lightmap coords
offset 28: uchar4  normal    (4 bytes) -- we repurpose bytes 28-29 as uint16 chunkId
```

## Adapting to Other Modpacks

This mod was built for SkyFactory One but should work with any Minecraft 1.16.5 + Forge 36.2.34 modpack. The terrain renderer is game-version specific (it hooks into `WorldRenderer` internals), not modpack specific.

To adapt to a different Minecraft version:
1. Update `build.gradle` mappings and Forge version
2. Update the SRG method/field names in mixins and reflection code
3. Check if the vertex format changed (it's been 32-byte BLOCK format since 1.15)
4. Rebuild
