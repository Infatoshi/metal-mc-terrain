#!/bin/bash
# SkyFactory One - Native ARM64 launcher (NO Rosetta)
# Zulu JDK 8 arm64 + LWJGL 3.3.1 arm64 natives + patched fastutil
# Expected: 2-3x FPS improvement over Rosetta x86_64
#
# Auto-refreshes Microsoft auth token via refresh_token.py

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAVA="/Users/infatoshi/java/zulu8.92.0.21-ca-jdk8.0.482-macosx_aarch64/zulu-8.jdk/Contents/Home/bin/java"
GAME_DIR="/Users/infatoshi/Documents/curseforge/minecraft/Instances/SkyFactory One"
ASSETS_DIR="/Users/infatoshi/Documents/curseforge/minecraft/Install/assets"
NATIVES_DIR="/tmp/mc-natives-arm64"
LIBS="/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries"
LWJGL="/tmp/lwjgl-arm64"

# Auto-refresh auth token
echo "Refreshing auth token..."
AUTH_OUTPUT=$(python3 "$SCRIPT_DIR/refresh_token.py")
TOKEN=$(echo "$AUTH_OUTPUT" | grep "^TOKEN=" | cut -d= -f2-)
UUID=$(echo "$AUTH_OUTPUT" | grep "^UUID=" | cut -d= -f2-)
NAME=$(echo "$AUTH_OUTPUT" | grep "^NAME=" | cut -d= -f2-)

if [ -z "$TOKEN" ] || [ -z "$UUID" ]; then
    echo "ERROR: Failed to get auth token. Check refresh_token.py output."
    exit 1
fi
echo "Authenticated as $NAME"
echo "JVM: $($JAVA -version 2>&1 | head -1)"
echo "Arch: $(file $JAVA | grep -o 'arm64\|x86_64')"

cd "$GAME_DIR"

# Classpath: same as original but LWJGL 3.2.1 jars replaced with 3.3.1
exec "$JAVA" \
  -XstartOnFirstThread \
  -Xmx6G -Xms4G \
  -XX:+UnlockExperimentalVMOptions \
  -XX:+UseG1GC \
  -XX:G1NewSizePercent=40 \
  -XX:G1MaxNewSizePercent=50 \
  -XX:G1HeapRegionSize=16M \
  -XX:MaxGCPauseMillis=15 \
  -XX:InitiatingHeapOccupancyPercent=30 \
  -XX:G1MixedGCCountTarget=4 \
  -XX:+ParallelRefProcEnabled \
  -XX:ParallelGCThreads=8 \
  -XX:+AlwaysPreTouch \
  -Dfml.earlyprogresswindow=false \
  -Djava.library.path="$NATIVES_DIR" \
  -Dforge.logging.console.level=info \
  -cp "$LIBS/net/minecraftforge/forge/1.16.5-36.2.34/forge-1.16.5-36.2.34.jar:$LIBS/org/ow2/asm/asm/9.1/asm-9.1.jar:$LIBS/org/ow2/asm/asm-commons/9.1/asm-commons-9.1.jar:$LIBS/org/ow2/asm/asm-tree/9.1/asm-tree-9.1.jar:$LIBS/org/ow2/asm/asm-util/9.1/asm-util-9.1.jar:$LIBS/org/ow2/asm/asm-analysis/9.1/asm-analysis-9.1.jar:$LIBS/cpw/mods/modlauncher/8.1.3/modlauncher-8.1.3.jar:$LIBS/cpw/mods/grossjava9hacks/1.3.3/grossjava9hacks-1.3.3.jar:$LIBS/net/minecraftforge/accesstransformers/3.0.1/accesstransformers-3.0.1.jar:$LIBS/org/antlr/antlr4-runtime/4.9.1/antlr4-runtime-4.9.1.jar:$LIBS/net/minecraftforge/eventbus/4.0.0/eventbus-4.0.0.jar:$LIBS/net/minecraftforge/forgespi/3.2.0/forgespi-3.2.0.jar:$LIBS/net/minecraftforge/coremods/4.0.6/coremods-4.0.6.jar:$LIBS/net/minecraftforge/unsafe/0.2.0/unsafe-0.2.0.jar:$LIBS/com/electronwill/night-config/core/3.6.3/core-3.6.3.jar:$LIBS/com/electronwill/night-config/toml/3.6.3/toml-3.6.3.jar:$LIBS/org/jline/jline/3.12.1/jline-3.12.1.jar:$LIBS/org/apache/maven/maven-artifact/3.6.3/maven-artifact-3.6.3.jar:$LIBS/net/jodah/typetools/0.8.3/typetools-0.8.3.jar:$LIBS/org/apache/logging/log4j/log4j-api/2.15.0/log4j-api-2.15.0.jar:$LIBS/org/apache/logging/log4j/log4j-core/2.15.0/log4j-core-2.15.0.jar:$LIBS/org/apache/logging/log4j/log4j-slf4j18-impl/2.15.0/log4j-slf4j18-impl-2.15.0.jar:$LIBS/net/minecrell/terminalconsoleappender/1.2.0/terminalconsoleappender-1.2.0.jar:$LIBS/net/sf/jopt-simple/jopt-simple/5.0.4/jopt-simple-5.0.4.jar:$LIBS/org/spongepowered/mixin/0.8.4/mixin-0.8.4.jar:$LIBS/net/minecraftforge/nashorn-core-compat/15.1.1.1/nashorn-core-compat-15.1.1.1.jar:$LIBS/com/mojang/patchy/1.3.9/patchy-1.3.9.jar:$LIBS/oshi-project/oshi-core/1.1/oshi-core-1.1.jar:$LIBS/net/java/dev/jna/jna/4.4.0/jna-4.4.0.jar:$LIBS/net/java/dev/jna/platform/3.4.0/platform-3.4.0.jar:$LIBS/com/ibm/icu/icu4j/66.1/icu4j-66.1.jar:$LIBS/com/mojang/javabridge/1.0.22/javabridge-1.0.22.jar:$LIBS/net/sf/jopt-simple/jopt-simple/5.0.3/jopt-simple-5.0.3.jar:$LIBS/io/netty/netty-all/4.1.25.Final/netty-all-4.1.25.Final.jar:$LIBS/com/google/guava/guava/21.0/guava-21.0.jar:$LIBS/org/apache/commons/commons-lang3/3.5/commons-lang3-3.5.jar:$LIBS/commons-io/commons-io/2.5/commons-io-2.5.jar:$LIBS/commons-codec/commons-codec/1.10/commons-codec-1.10.jar:$LIBS/net/java/jinput/jinput/2.0.5/jinput-2.0.5.jar:$LIBS/net/java/jutils/jutils/1.0.0/jutils-1.0.0.jar:$LIBS/com/mojang/brigadier/1.0.17/brigadier-1.0.17.jar:$LIBS/com/mojang/datafixerupper/4.0.26/datafixerupper-4.0.26.jar:$LIBS/com/google/code/gson/gson/2.8.0/gson-2.8.0.jar:$LIBS/com/mojang/authlib/2.1.28/authlib-2.1.28.jar:$LIBS/org/apache/commons/commons-compress/1.8.1/commons-compress-1.8.1.jar:$LIBS/org/apache/httpcomponents/httpclient/4.3.3/httpclient-4.3.3.jar:$LIBS/commons-logging/commons-logging/1.1.3/commons-logging-1.1.3.jar:$LIBS/org/apache/httpcomponents/httpcore/4.3.2/httpcore-4.3.2.jar:$LIBS/it/unimi/dsi/fastutil/8.5.15/fastutil-8.5.15.jar:$LIBS/org/apache/logging/log4j/log4j-api/2.8.1/log4j-api-2.8.1.jar:$LIBS/org/apache/logging/log4j/log4j-core/2.8.1/log4j-core-2.8.1.jar:$LWJGL/lwjgl-3.3.1.jar:$LWJGL/lwjgl-jemalloc-3.3.1.jar:$LWJGL/lwjgl-openal-3.3.1.jar:$LWJGL/lwjgl-opengl-3.3.1.jar:$LWJGL/lwjgl-glfw-3.3.1.jar:$LWJGL/lwjgl-stb-3.3.1.jar:$LWJGL/lwjgl-tinyfd-3.3.1.jar:$LIBS/com/mojang/text2speech/1.11.3/text2speech-1.11.3.jar:$LIBS/ca/weblite/java-objc-bridge/1.0.0/java-objc-bridge-1.0.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/versions/1.16.5/1.16.5.jar" \
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
