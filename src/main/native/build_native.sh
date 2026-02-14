#!/bin/bash
# Build the native Metal renderer dylib for SkyFactory mod.
#
# Usage: ./build_native.sh
#
# Requires: Xcode command line tools (xcrun, clang, metal compiler)
# Output:   libmetalrenderer.dylib (in this directory and in resources/natives/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/src/main/resources/natives"

# Detect JAVA_HOME (game runs Java 8, but we compile against system headers)
if [ -z "${JAVA_HOME:-}" ]; then
    # Try common macOS locations
    if [ -d "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" ]; then
        export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
    elif [ -d "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" ]; then
        export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    elif [ -d "$(/usr/libexec/java_home 2>/dev/null || true)" ]; then
        export JAVA_HOME="$(/usr/libexec/java_home)"
    else
        echo "Error: JAVA_HOME not set and could not auto-detect"
        exit 1
    fi
fi

echo "[BUILD] JAVA_HOME=$JAVA_HOME"
echo "[BUILD] Compiling Metal shaders..."

# Compile Metal shaders to metallib
xcrun -sdk macosx metal -c "$SCRIPT_DIR/metal_shaders.metal" -o "$SCRIPT_DIR/metal_shaders.air" 2>&1
xcrun -sdk macosx metallib "$SCRIPT_DIR/metal_shaders.air" -o "$SCRIPT_DIR/default.metallib" 2>&1

echo "[BUILD] Compiling native library..."

# Compile for both architectures (game JVM is x86_64 Rosetta, native is arm64)
for ARCH in arm64 x86_64; do
    echo "[BUILD] Compiling for $ARCH..."
    clang -shared -o "$SCRIPT_DIR/libmetalrenderer_${ARCH}.dylib" \
        -framework Metal \
        -framework MetalKit \
        -framework QuartzCore \
        -framework Cocoa \
        -framework IOSurface \
        -I"$JAVA_HOME/include" \
        -I"$JAVA_HOME/include/darwin" \
        -arch "$ARCH" \
        -O2 \
        -fobjc-arc \
        -Wno-deprecated-declarations \
        "$SCRIPT_DIR/metal_bridge.m" \
        "$SCRIPT_DIR/metal_renderer.m" \
        "$SCRIPT_DIR/metal_terrain.m" \
        2>&1
done

echo "[BUILD] Creating universal binary..."
lipo -create \
    "$SCRIPT_DIR/libmetalrenderer_arm64.dylib" \
    "$SCRIPT_DIR/libmetalrenderer_x86_64.dylib" \
    -output "$SCRIPT_DIR/libmetalrenderer.dylib"

rm -f "$SCRIPT_DIR/libmetalrenderer_arm64.dylib" "$SCRIPT_DIR/libmetalrenderer_x86_64.dylib"

echo "[BUILD] Signing dylib..."

# Ad-hoc code sign (required on macOS)
codesign -s - "$SCRIPT_DIR/libmetalrenderer.dylib"

echo "[BUILD] Copying to resources..."

# Copy to resources for jar packaging
mkdir -p "$OUTPUT_DIR"
cp "$SCRIPT_DIR/libmetalrenderer.dylib" "$OUTPUT_DIR/"

# Also copy to java.library.path locations used by launch scripts
# This prevents stale dylib issues when System.loadLibrary() finds the old one first
for NATIVE_DIR in /tmp/mc-natives-arm64; do
    if [ -d "$NATIVE_DIR" ]; then
        cp "$SCRIPT_DIR/libmetalrenderer.dylib" "$NATIVE_DIR/"
        echo "  $NATIVE_DIR/libmetalrenderer.dylib (java.library.path)"
    fi
done

echo "[BUILD] Done! Output:"
echo "  $SCRIPT_DIR/libmetalrenderer.dylib"
echo "  $OUTPUT_DIR/libmetalrenderer.dylib"
echo ""
file "$SCRIPT_DIR/libmetalrenderer.dylib"
otool -L "$SCRIPT_DIR/libmetalrenderer.dylib" | head -10
