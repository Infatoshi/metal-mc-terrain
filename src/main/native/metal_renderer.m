#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Cocoa/Cocoa.h>

// ============================================================
// Metal Renderer - manages device, pipelines, and rendering
// ============================================================

// Singleton state
static id<MTLDevice> g_device = nil;
static id<MTLCommandQueue> g_commandQueue = nil;
static CAMetalLayer *g_metalLayer = nil;
static NSView *g_metalView = nil;

// Phase B: triangle pipeline
static id<MTLRenderPipelineState> g_trianglePipeline = nil;
static id<MTLBuffer> g_triangleVertexBuffer = nil;
static id<MTLLibrary> g_library = nil;

// Frame timing
static id<MTLCommandBuffer> g_lastCommandBuffer = nil;
static uint64_t g_gpuTimeNanos = 0;

// When terrain v0.2 is active, skip test triangle rendering
static bool g_terrainActive = false;

// Forward declarations
static bool metal_renderer_compile_shaders(void);
static bool metal_renderer_create_triangle_pipeline(void);

// Triangle vertex data: position (x,y) + color (r,g,b,a) as floats
// 6 floats per vertex, 3 vertices
static const float kTriangleVertices[] = {
    // x,    y,     r,   g,   b,   a
     0.0f,  0.3f,  1.0f, 0.2f, 0.2f, 0.7f,  // top - red
    -0.3f, -0.3f,  0.2f, 1.0f, 0.2f, 0.7f,  // bottom-left - green
     0.3f, -0.3f,  0.2f, 0.2f, 1.0f, 0.7f,  // bottom-right - blue
};

// ============================================================
// Init / Shutdown
// ============================================================

bool metal_renderer_init(long nsWindowPtr) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)(void *)nsWindowPtr;
        if (!window) {
            NSLog(@"[METAL] NSWindow pointer is null");
            return false;
        }

        // Get the default Metal device
        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device) {
            NSLog(@"[METAL] No Metal device available");
            return false;
        }
        NSLog(@"[METAL] Device: %@", g_device.name);

        // Create command queue
        g_commandQueue = [g_device newCommandQueue];
        if (!g_commandQueue) {
            NSLog(@"[METAL] Failed to create command queue");
            return false;
        }

        // Create a CAMetalLayer
        g_metalLayer = [CAMetalLayer layer];
        g_metalLayer.device = g_device;
        g_metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_metalLayer.framebufferOnly = YES;
        g_metalLayer.opaque = NO; // transparent so GL content shows through

        // Get the content view's bounds
        NSView *contentView = [window contentView];
        NSRect bounds = contentView.bounds;

        // Create a child NSView for the Metal layer, overlaid on the GL view
        g_metalView = [[NSView alloc] initWithFrame:bounds];
        g_metalView.wantsLayer = YES;
        g_metalView.layer = g_metalLayer;
        g_metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        // Add as subview ON TOP of the GL view
        [contentView addSubview:g_metalView positioned:NSWindowAbove relativeTo:nil];

        // Set layer size
        CGFloat scale = window.backingScaleFactor;
        g_metalLayer.contentsScale = scale;
        g_metalLayer.drawableSize = CGSizeMake(bounds.size.width * scale,
                                                bounds.size.height * scale);

        NSLog(@"[METAL] Layer size: %.0fx%.0f (scale %.1f)",
              bounds.size.width * scale, bounds.size.height * scale, scale);

        // Compile shaders
        if (!metal_renderer_compile_shaders()) {
            NSLog(@"[METAL] Shader compilation failed");
            return false;
        }

        // Create triangle pipeline
        if (!metal_renderer_create_triangle_pipeline()) {
            NSLog(@"[METAL] Triangle pipeline creation failed");
            return false;
        }

        NSLog(@"[METAL] Renderer initialized successfully");
        return true;
    }
}

void metal_renderer_shutdown(void) {
    @autoreleasepool {
        if (g_metalView) {
            [g_metalView removeFromSuperview];
            g_metalView = nil;
        }
        g_triangleVertexBuffer = nil;
        g_trianglePipeline = nil;
        g_library = nil;
        g_metalLayer = nil;
        g_commandQueue = nil;
        g_device = nil;
        NSLog(@"[METAL] Renderer shut down");
    }
}

// ============================================================
// Shader compilation
// ============================================================

static bool metal_renderer_compile_shaders(void) {
    NSError *error = nil;

    // Try loading pre-compiled metallib from resources first
    NSString *libPath = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"];
    if (libPath) {
        g_library = [g_device newLibraryWithFile:libPath error:&error];
        if (g_library) {
            NSLog(@"[METAL] Loaded pre-compiled metallib");
            return true;
        }
    }

    // Fall back to compiling MSL source at runtime
    // The shader source is embedded as a string for portability
    NSString *shaderSource = @
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "\n"
        "struct TriangleVertex {\n"
        "    float2 position [[attribute(0)]];\n"
        "    float4 color    [[attribute(1)]];\n"
        "};\n"
        "\n"
        "struct TriangleOut {\n"
        "    float4 position [[position]];\n"
        "    float4 color;\n"
        "};\n"
        "\n"
        "vertex TriangleOut triangle_vertex(\n"
        "    TriangleVertex in [[stage_in]],\n"
        "    constant float &alpha [[buffer(1)]]\n"
        ") {\n"
        "    TriangleOut out;\n"
        "    out.position = float4(in.position, 0.0, 1.0);\n"
        "    out.color = float4(in.color.rgb, in.color.a * alpha);\n"
        "    return out;\n"
        "}\n"
        "\n"
        "fragment float4 triangle_fragment(TriangleOut in [[stage_in]]) {\n"
        "    return in.color;\n"
        "}\n";

    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.languageVersion = MTLLanguageVersion2_4;

    g_library = [g_device newLibraryWithSource:shaderSource options:opts error:&error];
    if (!g_library) {
        NSLog(@"[METAL] Shader compilation error: %@", error);
        return false;
    }

    NSLog(@"[METAL] Compiled shaders from source");
    return true;
}

// ============================================================
// Pipeline creation
// ============================================================

static bool metal_renderer_create_triangle_pipeline(void) {
    NSError *error = nil;

    id<MTLFunction> vertexFunc = [g_library newFunctionWithName:@"triangle_vertex"];
    id<MTLFunction> fragmentFunc = [g_library newFunctionWithName:@"triangle_fragment"];

    if (!vertexFunc || !fragmentFunc) {
        NSLog(@"[METAL] Could not find triangle shader functions");
        return false;
    }

    // Vertex descriptor: position (2 floats) + color (4 floats) = 24 bytes/vertex
    MTLVertexDescriptor *vertexDesc = [[MTLVertexDescriptor alloc] init];

    // Attribute 0: position (float2, offset 0)
    vertexDesc.attributes[0].format = MTLVertexFormatFloat2;
    vertexDesc.attributes[0].offset = 0;
    vertexDesc.attributes[0].bufferIndex = 0;

    // Attribute 1: color (float4, offset 8)
    vertexDesc.attributes[1].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[1].offset = 8;
    vertexDesc.attributes[1].bufferIndex = 0;

    // Layout: 24 bytes stride
    vertexDesc.layouts[0].stride = 24;
    vertexDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    // Pipeline descriptor
    MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeDesc.vertexFunction = vertexFunc;
    pipeDesc.fragmentFunction = fragmentFunc;
    pipeDesc.vertexDescriptor = vertexDesc;
    pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    // Enable alpha blending so triangle blends over GL content
    pipeDesc.colorAttachments[0].blendingEnabled = YES;
    pipeDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pipeDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    g_trianglePipeline = [g_device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
    if (!g_trianglePipeline) {
        NSLog(@"[METAL] Pipeline state creation failed: %@", error);
        return false;
    }

    // Create vertex buffer
    g_triangleVertexBuffer = [g_device newBufferWithBytes:kTriangleVertices
                                                   length:sizeof(kTriangleVertices)
                                                  options:MTLResourceStorageModeShared];

    NSLog(@"[METAL] Triangle pipeline created");
    return true;
}

// ============================================================
// Frame rendering (Phase B: triangle)
// ============================================================

static float g_frameCounter = 0.0f;

void metal_renderer_render_frame(void) {
    @autoreleasepool {
        if (!g_metalLayer || !g_trianglePipeline) return;
        if (g_terrainActive) return; // terrain v0.2 owns the layer

        // Update layer size if window resized
        NSRect bounds = g_metalView.bounds;
        CGFloat scale = g_metalView.window.backingScaleFactor;
        CGSize newSize = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
        if (g_metalLayer.drawableSize.width != newSize.width ||
            g_metalLayer.drawableSize.height != newSize.height) {
            g_metalLayer.drawableSize = newSize;
        }

        id<CAMetalDrawable> drawable = [g_metalLayer nextDrawable];
        if (!drawable) return;

        MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        passDesc.colorAttachments[0].texture = drawable.texture;
        passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); // transparent

        id<MTLCommandBuffer> commandBuffer = [g_commandQueue commandBuffer];
        commandBuffer.label = @"SkyFactory Metal Frame";

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
        encoder.label = @"Triangle Pass";

        [encoder setRenderPipelineState:g_trianglePipeline];
        [encoder setVertexBuffer:g_triangleVertexBuffer offset:0 atIndex:0];

        // Pulsing alpha to show it's alive
        g_frameCounter += 0.02f;
        float alpha = 0.4f + 0.3f * sinf(g_frameCounter);
        [encoder setVertexBytes:&alpha length:sizeof(float) atIndex:1];

        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];

        [commandBuffer presentDrawable:drawable];

        // Track GPU time
        g_lastCommandBuffer = commandBuffer;

        [commandBuffer commit];
    }
}

// ============================================================
// Diagnostics
// ============================================================

const char* metal_renderer_get_device_name(void) {
    if (!g_device) return "No Metal device";
    return [g_device.name UTF8String];
}

uint64_t metal_renderer_get_gpu_time_nanos(void) {
    return g_gpuTimeNanos;
}

// Accessors for metal_bridge.m to pass device/queue/layer to terrain system
id<MTLDevice> metal_renderer_get_device(void) {
    return g_device;
}

id<MTLCommandQueue> metal_renderer_get_queue(void) {
    return g_commandQueue;
}

CAMetalLayer* metal_renderer_get_layer(void) {
    return g_metalLayer;
}

NSView* metal_renderer_get_view(void) {
    return g_metalView;
}

void metal_renderer_set_terrain_active(bool active) {
    g_terrainActive = active;
}
