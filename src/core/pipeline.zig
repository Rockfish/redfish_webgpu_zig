//! Render state is pipeline state. `RenderState` flags replace GL's per-draw state toggles;
//! a `PipelineVariants` creates one pipeline per flag combination at init, and draws pick
//! theirs by index.

const std = @import("std");
const wgpu = @import("wgpu");

const c = wgpu.c;
const stringView = wgpu.stringView;

/// Straight alpha blending: src * a + dst * (1 - a).
const alpha_blend: c.WGPUBlendState = .{
    .color = .{
        .operation = c.WGPUBlendOperation_Add,
        .srcFactor = c.WGPUBlendFactor_SrcAlpha,
        .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
    },
    .alpha = .{
        .operation = c.WGPUBlendOperation_Add,
        .srcFactor = c.WGPUBlendFactor_One,
        .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
    },
};

/// Stencil unused: always pass, keep the value.
const keep_stencil: c.WGPUStencilFaceState = .{
    .compare = c.WGPUCompareFunction_Always,
    .failOp = c.WGPUStencilOperation_Keep,
    .depthFailOp = c.WGPUStencilOperation_Keep,
    .passOp = c.WGPUStencilOperation_Keep,
};

/// The per-draw render state GL toggled with enable/disable. Zero value is an opaque,
/// back-face-culled, depth-tested, depth-writing draw.
pub const RenderState = packed struct(u4) {
    transparent: bool = false,
    double_sided: bool = false,
    no_depth_write: bool = false,
    no_depth_test: bool = false,

    pub const count = 16;

    pub fn index(self: RenderState) usize {
        return @as(u4, @bitCast(self));
    }
};

/// Everything a pipeline needs except its render state.
pub const PipelineConfig = struct {
    label: []const u8,
    module: c.WGPUShaderModule,
    layout: c.WGPUPipelineLayout,
    vertex_buffers: []const c.WGPUVertexBufferLayout,
    color_format: c.WGPUTextureFormat,
    depth_format: c.WGPUTextureFormat,
    topology: c.WGPUPrimitiveTopology = c.WGPUPrimitiveTopology_TriangleList,
};

pub const PipelineVariants = struct {
    pipelines: [RenderState.count]c.WGPURenderPipeline,

    const Self = @This();

    pub fn init(device: c.WGPUDevice, config: PipelineConfig) Self {
        var self: Self = undefined;
        for (&self.pipelines, 0..) |*pipeline, i| {
            const state: RenderState = @bitCast(@as(u4, @intCast(i)));
            pipeline.* = createRenderPipeline(device, config, state);
        }
        return self;
    }

    pub fn get(self: *const Self, state: RenderState) c.WGPURenderPipeline {
        return self.pipelines[state.index()];
    }

    pub fn releaseGpuObjects(self: *Self) void {
        for (self.pipelines) |pipeline| c.wgpuRenderPipelineRelease(pipeline);
    }
};

/// Entry points are `vs_main` / `fs_main` (STYLE.md section 10). Every zero default that
/// would be wrong (write mask, sample count, step mode) is set here explicitly.
pub fn createRenderPipeline(device: c.WGPUDevice, config: PipelineConfig, state: RenderState) c.WGPURenderPipeline {
    const color_target: c.WGPUColorTargetState = .{
        .format = config.color_format,
        .blend = if (state.transparent) &alpha_blend else null,
        .writeMask = c.WGPUColorWriteMask_All,
    };
    const fragment: c.WGPUFragmentState = .{
        .module = config.module,
        .entryPoint = stringView("fs_main"),
        .targetCount = 1,
        .targets = &color_target,
    };
    const depth_stencil: c.WGPUDepthStencilState = .{
        .format = config.depth_format,
        .depthWriteEnabled = if (state.no_depth_write) c.WGPUOptionalBool_False else c.WGPUOptionalBool_True,
        .depthCompare = if (state.no_depth_test) c.WGPUCompareFunction_Always else c.WGPUCompareFunction_Less,
        .stencilFront = keep_stencil,
        .stencilBack = keep_stencil,
    };

    return c.wgpuDeviceCreateRenderPipeline(device, &.{
        .label = stringView(config.label),
        .layout = config.layout,
        .vertex = .{
            .module = config.module,
            .entryPoint = stringView("vs_main"),
            .bufferCount = config.vertex_buffers.len,
            .buffers = config.vertex_buffers.ptr,
        },
        .primitive = .{
            .topology = config.topology,
            .frontFace = c.WGPUFrontFace_CCW,
            .cullMode = if (state.double_sided) c.WGPUCullMode_None else c.WGPUCullMode_Back,
        },
        .depthStencil = &depth_stencil,
        .multisample = .{ .count = 1, .mask = 0xFFFF_FFFF },
        .fragment = &fragment,
    });
}

test "RenderState zero value is index 0 and flags map to distinct indices" {
    try std.testing.expectEqual(@as(usize, 0), (RenderState{}).index());
    try std.testing.expectEqual(@as(usize, 1), (RenderState{ .transparent = true }).index());
    try std.testing.expectEqual(@as(usize, 15), (RenderState{
        .transparent = true,
        .double_sided = true,
        .no_depth_write = true,
        .no_depth_test = true,
    }).index());
}
