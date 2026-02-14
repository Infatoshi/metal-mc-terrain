#!/bin/bash
# SkyFactory One - Java 11 + Shenandoah launcher
# Auto-refreshes Microsoft auth token via refresh_token.py

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAVA="/Users/infatoshi/java/jdk-11.0.30+7/Contents/Home/bin/java"
GAME_DIR="/Users/infatoshi/Documents/curseforge/minecraft/Instances/SkyFactory One"
ASSETS_DIR="/Users/infatoshi/Documents/curseforge/minecraft/Install/assets"
NATIVES_DIR="/tmp/mc-natives"

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

cd "$GAME_DIR"

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
  -Djava.library.path="$NATIVES_DIR" \
  -Dforge.logging.console.level=info \
  -cp "/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/minecraftforge/forge/1.16.5-36.2.34/forge-1.16.5-36.2.34.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/ow2/asm/asm/9.1/asm-9.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/ow2/asm/asm-commons/9.1/asm-commons-9.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/ow2/asm/asm-tree/9.1/asm-tree-9.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/ow2/asm/asm-util/9.1/asm-util-9.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/ow2/asm/asm-analysis/9.1/asm-analysis-9.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/cpw/mods/modlauncher/8.1.3/modlauncher-8.1.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/cpw/mods/grossjava9hacks/1.3.3/grossjava9hacks-1.3.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/minecraftforge/accesstransformers/3.0.1/accesstransformers-3.0.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/antlr/antlr4-runtime/4.9.1/antlr4-runtime-4.9.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/minecraftforge/eventbus/4.0.0/eventbus-4.0.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/minecraftforge/forgespi/3.2.0/forgespi-3.2.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/minecraftforge/coremods/4.0.6/coremods-4.0.6.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/minecraftforge/unsafe/0.2.0/unsafe-0.2.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/electronwill/night-config/core/3.6.3/core-3.6.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/electronwill/night-config/toml/3.6.3/toml-3.6.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/jline/jline/3.12.1/jline-3.12.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/maven/maven-artifact/3.6.3/maven-artifact-3.6.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/jodah/typetools/0.8.3/typetools-0.8.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/logging/log4j/log4j-api/2.15.0/log4j-api-2.15.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/logging/log4j/log4j-core/2.15.0/log4j-core-2.15.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/logging/log4j/log4j-slf4j18-impl/2.15.0/log4j-slf4j18-impl-2.15.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/minecrell/terminalconsoleappender/1.2.0/terminalconsoleappender-1.2.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/sf/jopt-simple/jopt-simple/5.0.4/jopt-simple-5.0.4.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/spongepowered/mixin/0.8.4/mixin-0.8.4.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/minecraftforge/nashorn-core-compat/15.1.1.1/nashorn-core-compat-15.1.1.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/mojang/patchy/1.3.9/patchy-1.3.9.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/oshi-project/oshi-core/1.1/oshi-core-1.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/java/dev/jna/jna/4.4.0/jna-4.4.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/java/dev/jna/platform/3.4.0/platform-3.4.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/ibm/icu/icu4j/66.1/icu4j-66.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/mojang/javabridge/1.0.22/javabridge-1.0.22.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/sf/jopt-simple/jopt-simple/5.0.3/jopt-simple-5.0.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/io/netty/netty-all/4.1.25.Final/netty-all-4.1.25.Final.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/google/guava/guava/21.0/guava-21.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/commons/commons-lang3/3.5/commons-lang3-3.5.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/commons-io/commons-io/2.5/commons-io-2.5.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/commons-codec/commons-codec/1.10/commons-codec-1.10.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/java/jinput/jinput/2.0.5/jinput-2.0.5.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/net/java/jutils/jutils/1.0.0/jutils-1.0.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/mojang/brigadier/1.0.17/brigadier-1.0.17.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/mojang/datafixerupper/4.0.26/datafixerupper-4.0.26.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/google/code/gson/gson/2.8.0/gson-2.8.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/mojang/authlib/2.1.28/authlib-2.1.28.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/commons/commons-compress/1.8.1/commons-compress-1.8.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/httpcomponents/httpclient/4.3.3/httpclient-4.3.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/commons-logging/commons-logging/1.1.3/commons-logging-1.1.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/httpcomponents/httpcore/4.3.2/httpcore-4.3.2.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/it/unimi/dsi/fastutil/8.5.15/fastutil-8.5.15.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/logging/log4j/log4j-api/2.8.1/log4j-api-2.8.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/apache/logging/log4j/log4j-core/2.8.1/log4j-core-2.8.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/lwjgl/lwjgl/3.2.1/lwjgl-3.2.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/lwjgl/lwjgl-jemalloc/3.2.1/lwjgl-jemalloc-3.2.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/lwjgl/lwjgl-openal/3.2.1/lwjgl-openal-3.2.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/lwjgl/lwjgl-opengl/3.2.1/lwjgl-opengl-3.2.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/lwjgl/lwjgl-glfw/3.2.1/lwjgl-glfw-3.2.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/lwjgl/lwjgl-stb/3.2.1/lwjgl-stb-3.2.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/org/lwjgl/lwjgl-tinyfd/3.2.1/lwjgl-tinyfd-3.2.1.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/com/mojang/text2speech/1.11.3/text2speech-1.11.3.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/libraries/ca/weblite/java-objc-bridge/1.0.0/java-objc-bridge-1.0.0.jar:/Users/infatoshi/Documents/curseforge/minecraft/Install/versions/1.16.5/1.16.5.jar" \
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
