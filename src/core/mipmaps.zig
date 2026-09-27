//! Mipmap generation. WebGPU has none built in. Each level is rendered from the one above
//! with a full-screen triangle and a linear sampler, so any size works (non-square,
//! non-power-of-two) and sRGB formats downsample in linear space: sampling decodes,
//! the render target encodes.

const std = @import("std");
const wgpu = @import("wgpu");

const c = wgpu.c;
const stringView = wgpu.stringView;

const log = std.log.scoped(.mipmaps);

/// Formats `generate` accepts; one pipeline each.
pub const formats = [_]c.WGPUTextureFormat{
    c.WGPUTextureFormat_RGBA8Unorm,
    c.WGPUTextureFormat_RGBA8UnormSrgb,
};

const downsample_wgsl =
    \\@group(0) @binding(0) var source: texture_2d<f32>;
    \\@group(0) @binding(1) var source_sampler: sampler;
    \\
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4f,
    \\    @location(0) uv: vec2f,
    \\}
    \\
    \\// One triangle covering the target: uv (0,0) (2,0) (0,2), top-left origin.
    \\@vertex
    \\fn vs_main(@builtin(vertex_index) index: u32) -> VertexOutput {
    \\    let uv = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
    \\    var out: VertexOutput;
    \\    out.position = vec4f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    \\    out.uv = uv;
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    \\    return textureSample(source, source_sampler, in.uv);
    \\}
;

/// Number of levels in a full chain for the given size.
pub fn levelCount(width: u32, height: u32) u32 {
    return std.math.log2_int(u32, @max(width, height, 1)) + 1;
}

pub const MipmapGenerator = struct {
    module: c.WGPUShaderModule,
    layout: c.WGPUBindGroupLayout,
    pipeline_layout: c.WGPUPipelineLayout,
    pipelines: [formats.len]c.WGPURenderPipeline,
    sampler: c.WGPUSampler,

    const Self = @This();

    pub fn init(device: c.WGPUDevice) Self {
        const wgsl: c.WGPUShaderSourceWGSL = .{
            .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = stringView(downsample_wgsl),
        };
        const module = c.wgpuDeviceCreateShaderModule(device, &.{
            .nextInChain = @constCast(&wgsl.chain),
            .label = stringView("mipmap downsample"),
        });

        const entries = [_]c.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Fragment,
                .texture = .{ .sampleType = c.WGPUTextureSampleType_Float, .viewDimension = c.WGPUTextureViewDimension_2D },
            },
            .{
                .binding = 1,
                .visibility = c.WGPUShaderStage_Fragment,
                .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering },
            },
        };
        const layout = c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = stringView("mipmap layout"),
            .entryCount = entries.len,
            .entries = &entries,
        });
        const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &.{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &layout,
        });

        var self: Self = .{
            .module = module,
            .layout = layout,
            .pipeline_layout = pipeline_layout,
            .pipelines = undefined,
            .sampler = c.wgpuDeviceCreateSampler(device, &.{
                .label = stringView("mipmap sampler"),
                .addressModeU = c.WGPUAddressMode_ClampToEdge,
                .addressModeV = c.WGPUAddressMode_ClampToEdge,
                .addressModeW = c.WGPUAddressMode_ClampToEdge,
                .magFilter = c.WGPUFilterMode_Linear,
                .minFilter = c.WGPUFilterMode_Linear,
                .mipmapFilter = c.WGPUMipmapFilterMode_Nearest,
                .lodMaxClamp = 32.0,
                .maxAnisotropy = 1,
            }),
        };
        for (&self.pipelines, formats) |*pipeline, format| {
            pipeline.* = createPipeline(device, module, pipeline_layout, format);
        }
        return self;
    }

    /// Fill levels 1.. of `texture` from level 0. The texture needs `TextureBinding` and
    /// `RenderAttachment` usage and a format from `formats`.
    pub fn generate(
        self: *const Self,
        device: c.WGPUDevice,
        queue: c.WGPUQueue,
        texture: c.WGPUTexture,
        format: c.WGPUTextureFormat,
        level_count: u32,
    ) void {
        const pipeline = self.pipelineFor(format) orelse {
            log.err("no mipmap pipeline for format {d}", .{format});
            return;
        };
        const encoder = c.wgpuDeviceCreateCommandEncoder(device, &.{ .label = stringView("mipmaps") });

        for (1..level_count) |level| {
            const source_view = createLevelView(texture, format, @intCast(level - 1));
            defer c.wgpuTextureViewRelease(source_view);
            const target_view = createLevelView(texture, format, @intCast(level));
            defer c.wgpuTextureViewRelease(target_view);

            const entries = [_]c.WGPUBindGroupEntry{
                .{ .binding = 0, .textureView = source_view },
                .{ .binding = 1, .sampler = self.sampler },
            };
            const bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
                .layout = self.layout,
                .entryCount = entries.len,
                .entries = &entries,
            });
            defer c.wgpuBindGroupRelease(bind_group);

            const color_attachment: c.WGPURenderPassColorAttachment = .{
                .view = target_view,
                .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
                .loadOp = c.WGPULoadOp_Clear,
                .storeOp = c.WGPUStoreOp_Store,
            };
            const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &.{
                .colorAttachmentCount = 1,
                .colorAttachments = &color_attachment,
            });
            c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
            c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
            c.wgpuRenderPassEncoderEnd(pass);
            c.wgpuRenderPassEncoderRelease(pass);
        }

        const commands = c.wgpuCommandEncoderFinish(encoder, &.{});
        c.wgpuQueueSubmit(queue, 1, &commands);
        c.wgpuCommandBufferRelease(commands);
        c.wgpuCommandEncoderRelease(encoder);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuSamplerRelease(self.sampler);
        for (self.pipelines) |pipeline| c.wgpuRenderPipelineRelease(pipeline);
        c.wgpuPipelineLayoutRelease(self.pipeline_layout);
        c.wgpuBindGroupLayoutRelease(self.layout);
        c.wgpuShaderModuleRelease(self.module);
    }

    fn pipelineFor(self: *const Self, format: c.WGPUTextureFormat) ?c.WGPURenderPipeline {
        for (formats, self.pipelines) |candidate, pipeline| {
            if (candidate == format) return pipeline;
        }
        return null;
    }
};

fn createPipeline(
    device: c.WGPUDevice,
    module: c.WGPUShaderModule,
    layout: c.WGPUPipelineLayout,
    format: c.WGPUTextureFormat,
) c.WGPURenderPipeline {
    const target: c.WGPUColorTargetState = .{ .format = format, .writeMask = c.WGPUColorWriteMask_All };
    const fragment: c.WGPUFragmentState = .{
        .module = module,
        .entryPoint = stringView("fs_main"),
        .targetCount = 1,
        .targets = &target,
    };
    return c.wgpuDeviceCreateRenderPipeline(device, &.{
        .label = stringView("mipmap downsample"),
        .layout = layout,
        .vertex = .{ .module = module, .entryPoint = stringView("vs_main") },
        .primitive = .{
            .topology = c.WGPUPrimitiveTopology_TriangleList,
            .frontFace = c.WGPUFrontFace_CCW,
            .cullMode = c.WGPUCullMode_None,
        },
        .multisample = .{ .count = 1, .mask = 0xFFFF_FFFF },
        .fragment = &fragment,
    });
}

fn createLevelView(texture: c.WGPUTexture, format: c.WGPUTextureFormat, level: u32) c.WGPUTextureView {
    return c.wgpuTextureCreateView(texture, &.{
        .format = format,
        .dimension = c.WGPUTextureViewDimension_2D,
        .baseMipLevel = level,
        .mipLevelCount = 1,
        .baseArrayLayer = 0,
        .arrayLayerCount = 1,
        .aspect = c.WGPUTextureAspect_All,
    });
}

test "levelCount covers the largest dimension down to 1" {
    try std.testing.expectEqual(@as(u32, 1), levelCount(1, 1));
    try std.testing.expectEqual(@as(u32, 10), levelCount(512, 512));
    try std.testing.expectEqual(@as(u32, 10), levelCount(512, 300));
    try std.testing.expectEqual(@as(u32, 10), levelCount(1000, 1)); // 1000, 500, ..., 3, 1
}
