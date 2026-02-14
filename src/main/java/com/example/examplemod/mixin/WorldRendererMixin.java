package com.example.examplemod.mixin;

import com.example.examplemod.metal.MetalTerrainRenderer;
import com.mojang.blaze3d.matrix.MatrixStack;
import net.minecraft.client.renderer.RenderType;
import net.minecraft.client.renderer.WorldRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Suppresses GL terrain rendering when Metal terrain is active.
 * Saves ~2.1ms/frame of macOS GL draw call overhead.
 *
 * renderChunkLayer is called 4 times per frame (solid, cutout_mipped, cutout, translucent).
 * Entity and block entity rendering are separate methods and unaffected.
 */
@Mixin(WorldRenderer.class)
public abstract class WorldRendererMixin {

    @Inject(method = "renderChunkLayer", at = @At("HEAD"), cancellable = true)
    private void skipGLTerrain(RenderType renderType, MatrixStack matrixStack,
                               double camX, double camY, double camZ, CallbackInfo ci) {
        if (MetalTerrainRenderer.isActive()) {
            ci.cancel();
        }
    }
}
