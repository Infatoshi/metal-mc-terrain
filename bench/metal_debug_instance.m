// metal_debug_instance.m -- Minimal test for instanced manual buffer indexing
//
// Renders 2 colored triangles: one per instance. Each instance reads from its own
// slot in the vertex buffer using manual indexing (iid * slotSize + vid).
//
// Build:  clang -framework Metal -framework QuartzCore -framework Foundation \
//         -O2 -fobjc-arc -o metal_debug_instance metal_debug_instance.m

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>

static NSString *kShader = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct Vertex {\n"
    "    packed_float3 position;\n"
    "    uchar4 color;\n"
    "};\n"
    "\n"
    "struct InstUniforms {\n"
    "    uint slotSize;\n"
    "};\n"
    "\n"
    "struct Out {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "};\n"
    "\n"
    "vertex Out test_vertex(\n"
    "    constant Vertex* vertices [[buffer(0)]],\n"
    "    constant InstUniforms& inst [[buffer(1)]],\n"
    "    uint vid [[vertex_id]],\n"
    "    uint iid [[instance_id]]\n"
    ") {\n"
    "    uint idx = iid * inst.slotSize + vid;\n"
    "    constant Vertex& v = vertices[idx];\n"
    "    Out out;\n"
    "    out.position = float4(float3(v.position), 1.0);\n"
    "    out.color = float4(v.color) / 255.0;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 test_fragment(Out in [[stage_in]]) {\n"
    "    return in.color;\n"
    "}\n";

typedef struct {
    float x, y, z;
    uint8_t r, g, b, a;
} __attribute__((packed)) Vertex;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];

        printf("=== Minimal Instance Buffer Indexing Test ===\n");
        printf("Device: %s\n\n", [[device name] UTF8String]);

        NSError *error = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;
        id<MTLLibrary> lib = [device newLibraryWithSource:kShader options:opts error:&error];
        if (!lib) { fprintf(stderr, "Shader error: %s\n", [[error description] UTF8String]); return 1; }

        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = [lib newFunctionWithName:@"test_vertex"];
        pd.fragmentFunction = [lib newFunctionWithName:@"test_fragment"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) { fprintf(stderr, "Pipeline error: %s\n", [[error description] UTF8String]); return 1; }

        int width = 64, height = 64;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
              width:width height:height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> colorTex = [device newTextureWithDescriptor:td];

        // 2 instances, 3 vertices each (1 triangle per instance)
        // Instance 0: red triangle on the left
        // Instance 1: green triangle on the right
        uint32_t slotSize = 3;
        Vertex verts[6] = {
            // Slot 0 (instance 0): red triangle, left side
            { -0.8f, -0.5f, 0.5f,  255, 0, 0, 255 },
            { -0.2f, -0.5f, 0.5f,  255, 0, 0, 255 },
            { -0.5f,  0.5f, 0.5f,  255, 0, 0, 255 },
            // Slot 1 (instance 1): green triangle, right side
            {  0.2f, -0.5f, 0.5f,  0, 255, 0, 255 },
            {  0.8f, -0.5f, 0.5f,  0, 255, 0, 255 },
            {  0.5f,  0.5f, 0.5f,  0, 255, 0, 255 },
        };

        id<MTLBuffer> vertBuffer = [device newBufferWithBytes:verts
                                                        length:sizeof(verts)
                                                       options:MTLResourceStorageModeShared];

        printf("Buffer size: %lu bytes (%lu vertices of %lu bytes each)\n",
               sizeof(verts), sizeof(verts)/sizeof(Vertex), sizeof(Vertex));
        printf("Slot size: %u vertices\n", slotSize);

        // Test 1: draw both instances
        {
            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorTex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeline];
            [enc setVertexBuffer:vertBuffer offset:0 atIndex:0];
            [enc setVertexBytes:&slotSize length:sizeof(slotSize) atIndex:1];

            [enc drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:slotSize
                  instanceCount:2
                   baseInstance:0];

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
        }

        // Read back and check
        uint8_t *pixels = (uint8_t *)malloc(width * height * 4);
        [colorTex getBytes:pixels bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        int redPixels = 0, greenPixels = 0, blackPixels = 0, otherPixels = 0;
        for (int i = 0; i < width * height; i++) {
            uint8_t b = pixels[i*4+0], g = pixels[i*4+1], r = pixels[i*4+2], a = pixels[i*4+3];
            if (a == 0) { blackPixels++; }
            else if (r > 200 && g < 50 && b < 50) { redPixels++; }
            else if (g > 200 && r < 50 && b < 50) { greenPixels++; }
            else { otherPixels++; }
        }

        printf("\nTest 1: drawPrimitives with 2 instances\n");
        printf("  Red pixels (instance 0):   %d\n", redPixels);
        printf("  Green pixels (instance 1): %d\n", greenPixels);
        printf("  Black pixels:              %d\n", blackPixels);
        printf("  Other pixels:              %d\n", otherPixels);

        if (redPixels > 0 && greenPixels > 0) {
            printf("  >>> PASS: Both instances rendered <<<\n");
        } else if (redPixels > 0 && greenPixels == 0) {
            printf("  >>> FAIL: Only instance 0 rendered <<<\n");
        } else {
            printf("  >>> FAIL: Unexpected result <<<\n");
        }

        // Test 3: indexed draw with 2 instances (like production code)
        {
            // 4 verts per quad, 2 quads per instance = 8 verts per slot
            uint32_t slotSize3 = 8;
            Vertex verts3[16] = {
                // Slot 0 (instance 0): red quad left, red quad left-2
                { -0.9f, -0.4f, 0.5f,  255, 0, 0, 255 },
                { -0.5f, -0.4f, 0.5f,  255, 0, 0, 255 },
                { -0.9f,  0.0f, 0.5f,  255, 0, 0, 255 },
                { -0.5f,  0.0f, 0.5f,  255, 0, 0, 255 },
                { -0.9f,  0.1f, 0.5f,  255, 0, 0, 255 },
                { -0.5f,  0.1f, 0.5f,  255, 0, 0, 255 },
                { -0.9f,  0.5f, 0.5f,  255, 0, 0, 255 },
                { -0.5f,  0.5f, 0.5f,  255, 0, 0, 255 },
                // Slot 1 (instance 1): green quad right, green quad right-2
                {  0.5f, -0.4f, 0.5f,  0, 255, 0, 255 },
                {  0.9f, -0.4f, 0.5f,  0, 255, 0, 255 },
                {  0.5f,  0.0f, 0.5f,  0, 255, 0, 255 },
                {  0.9f,  0.0f, 0.5f,  0, 255, 0, 255 },
                {  0.5f,  0.1f, 0.5f,  0, 255, 0, 255 },
                {  0.9f,  0.1f, 0.5f,  0, 255, 0, 255 },
                {  0.5f,  0.5f, 0.5f,  0, 255, 0, 255 },
                {  0.9f,  0.5f, 0.5f,  0, 255, 0, 255 },
            };

            id<MTLBuffer> vertBuf3 = [device newBufferWithBytes:verts3
                                                          length:sizeof(verts3)
                                                         options:MTLResourceStorageModeShared];

            // Index buffer: 2 quads -> 12 indices
            uint16_t idx3[12] = {
                0, 1, 2, 1, 3, 2,  // quad 0
                4, 5, 6, 5, 7, 6,  // quad 1
            };
            id<MTLBuffer> idxBuf3 = [device newBufferWithBytes:idx3
                                                         length:sizeof(idx3)
                                                        options:MTLResourceStorageModeShared];

            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorTex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeline];
            [enc setVertexBuffer:vertBuf3 offset:0 atIndex:0];
            [enc setVertexBytes:&slotSize3 length:sizeof(slotSize3) atIndex:1];

            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:12
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:idxBuf3
                     indexBufferOffset:0
                         instanceCount:2
                            baseVertex:0
                          baseInstance:0];

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
        }

        [colorTex getBytes:pixels bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        redPixels = greenPixels = blackPixels = otherPixels = 0;
        for (int i = 0; i < width * height; i++) {
            uint8_t b = pixels[i*4+0], g = pixels[i*4+1], r = pixels[i*4+2], a = pixels[i*4+3];
            if (a == 0) { blackPixels++; }
            else if (r > 200 && g < 50 && b < 50) { redPixels++; }
            else if (g > 200 && r < 50 && b < 50) { greenPixels++; }
            else { otherPixels++; }
        }

        printf("\nTest 3: drawIndexedPrimitives with 2 instances (indexed, like production)\n");
        printf("  Red pixels (instance 0):   %d\n", redPixels);
        printf("  Green pixels (instance 1): %d\n", greenPixels);
        printf("  Black pixels:              %d\n", blackPixels);
        printf("  Other pixels:              %d\n", otherPixels);

        if (redPixels > 0 && greenPixels > 0) {
            printf("  >>> PASS <<<\n");
        } else if (redPixels > 0 && greenPixels == 0) {
            printf("  >>> FAIL: Only instance 0 <<<\n");
        } else {
            printf("  >>> UNEXPECTED <<<\n");
        }

        // Test 2: draw instance 1 only
        {
            id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = colorTex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc setRenderPipelineState:pipeline];
            [enc setVertexBuffer:vertBuffer offset:0 atIndex:0];
            [enc setVertexBytes:&slotSize length:sizeof(slotSize) atIndex:1];

            [enc drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:slotSize
                  instanceCount:1
                   baseInstance:1];

            [enc endEncoding];
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
        }

        [colorTex getBytes:pixels bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        redPixels = greenPixels = blackPixels = otherPixels = 0;
        for (int i = 0; i < width * height; i++) {
            uint8_t b = pixels[i*4+0], g = pixels[i*4+1], r = pixels[i*4+2], a = pixels[i*4+3];
            if (a == 0) { blackPixels++; }
            else if (r > 200 && g < 50 && b < 50) { redPixels++; }
            else if (g > 200 && r < 50 && b < 50) { greenPixels++; }
            else { otherPixels++; }
        }

        printf("\nTest 2: drawPrimitives instance 1 only (baseInstance=1)\n");
        printf("  Red pixels (instance 0 data): %d\n", redPixels);
        printf("  Green pixels (instance 1 data): %d\n", greenPixels);
        printf("  Black pixels:                   %d\n", blackPixels);
        printf("  Other pixels:                   %d\n", otherPixels);

        if (greenPixels > 0) {
            printf("  >>> PASS: Instance 1 rendered correctly <<<\n");
        } else {
            printf("  >>> FAIL: Instance 1 did not render <<<\n");
        }

        free(pixels);
        return 0;
    }
}
