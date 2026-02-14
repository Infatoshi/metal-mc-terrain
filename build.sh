#!/bin/bash
# Build mod and deploy to SkyFactory One mods folder
set -e
cd "$(dirname "$0")"
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew build --no-daemon
cp build/libs/modid-1.0.jar "$HOME/Documents/curseforge/minecraft/Instances/SkyFactory One/mods/patched-overlay-1.0.jar"
echo "Deployed to SkyFactory One mods/"
