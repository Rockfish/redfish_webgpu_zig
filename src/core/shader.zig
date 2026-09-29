//! A WGSL shader loaded from a file, with its pipeline layout and one render pipeline per
//! `RenderState`. The source gets the generated `bindings.wgsl_header` and `common.wgsl`
//! prepended, so a shader file only declares its own vertex I/O, bindings, and entry points.
//!
//! Replaces redfish's GL program + named uniforms: per-draw values go through
//! `DrawUniforms` and the uniform ring instead of `setMat4` / `setVec4`.

const std = @import("std");
const wgpu = @import("wgpu");
const utils = @import("utils/root.zig");
const bindings = @import("bindings.zig");
const gpu_debug = @import("gpu_debug.zig");
const pipeline = @import("pipeline.zig");
const gpu_context = @import("gpu_context.zig");

const c = wgpu.c;
const stringView = wgpu.stringView;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const GpuContext = gpu_context.GpuContext;
const PipelineVariants = pipeline.PipelineVariants;
const RenderState = pipeline.RenderState;
const MaterialKind = bindings.MaterialKind;
const PassKind = bindings.PassKind;
const Topology = pipeline.Topology;
const ColorTarget = pipeline.ColorTarget;
const OverrideConstant = pipeline.OverrideConstant;
const DepthBias = pipeline.DepthBias;

/// How a shader's pipelines are built.
pub const ShaderConfig = struct {
    /// The vertex layout of the geometry it draws (e.g. `Shape.vertex_buffer_layouts`).
    vertex_buffers: []const c.WGPUVertexBufferLayout,
    /// What it binds at group 1.
    material: MaterialKind = .none,
    topology: Topology = .triangle_list,
    /// Replaces the `Less` depth test, e.g. `LessEqual` for a skybox at depth 1.
    depth_compare: ?c.WGPUCompareFunction = null,
    /// What the pipelines draw into: the window's format, another format (a render
    /// target), or nothing (a depth-only shadow pass, which has no fragment stage).
    color_target: ColorTarget = .surface,
    /// False for passes without a depth attachment (full-screen post-processing).
    depth: bool = true,
    /// False: the pipelines write depth but no color, e.g. an occluder in a pass whose
    /// color it shouldn't change (GL's glColorMask off).
    color_writes: bool = true,
    /// What the shader binds at group 3.
    pass: PassKind = .none,
    /// Values for the shader's `override` constants, e.g. `DEPTH_MODE` for a shadow
    /// pipeline made from a lit shader.
    constants: []const OverrideConstant = &.{},
    /// Depth bias for shadow casters (see `DepthBias`); zero for everything else.
    depth_bias: DepthBias = .{},
    /// A render-target (`.format`) pipeline that draws in a multisampled pass, one whose
    /// target has a `resolve` view: it gets the window's sample count
    /// (`gpu_context.window_sample_count`, 1 without MSAA). `.surface` pipelines always do.
    multisampled: bool = false,
};

const log = std.log.scoped(.shader);

const common_wgsl = @embedFile("shaders/common.wgsl");

/// Lines before the shader file's own source; naga's line numbers include them.
const PREPENDED_LINES = blk: {
    @setEvalBranchQuota(20_000);
    break :blk std.mem.count(u8, bindings.wgsl_header, "\n") + std.mem.count(u8, common_wgsl, "\n");
};

pub const Shader = struct {
    file_path: []const u8,
    material: MaterialKind,
    module: c.WGPUShaderModule,
    pipeline_layout: c.WGPUPipelineLayout,
    variants: PipelineVariants,

    const Self = @This();

    pub fn init(
        io: Io,
        allocator: Allocator,
        gpu: *const GpuContext,
        file_path: []const u8,
        config: ShaderConfig,
    ) !*Shader {
        const module = try createModule(io, allocator, gpu, file_path);
        const pipeline_layout = createPipelineLayout(gpu, config.material, config.pass);

        const shader = try allocator.create(Shader);
        shader.* = .{
            .file_path = try allocator.dupe(u8, file_path),
            .material = config.material,
            .module = module,
            .pipeline_layout = pipeline_layout,
            .variants = PipelineVariants.init(gpu.device, .{
                .label = file_path,
                .module = module,
                .layout = pipeline_layout,
                .vertex_buffers = config.vertex_buffers,
                .topology = config.topology,
                .depth_compare = config.depth_compare,
                .color_format = switch (config.color_target) {
                    .surface => gpu.surface_format,
                    .format => |format| format,
                    .none => null,
                },
                .depth_format = if (config.depth) gpu_context.depth_format else null,
                .constants = config.constants,
                .color_writes = config.color_writes,
                .depth_bias = config.depth_bias,
                // The window pass is multisampled with MSAA; render targets only when the
                // shader says so, and shadow passes never
                .sample_count = if (config.color_target == .surface or config.multisampled) gpu_context.window_sample_count else 1,
            }),
        };
        return shader;
    }

    pub fn getPipeline(self: *const Self, state: RenderState) c.WGPURenderPipeline {
        return self.variants.get(state);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.variants.releaseGpuObjects();
        c.wgpuPipelineLayoutRelease(self.pipeline_layout);
        c.wgpuShaderModuleRelease(self.module);
    }
};

/// Compile inside a validation error scope so a WGSL error is reported here, with the
/// file name, instead of as an uncaptured error at first use.
fn createModule(io: Io, allocator: Allocator, gpu: *const GpuContext, file_path: []const u8) !c.WGPUShaderModule {
    const file_source = try utils.readFileToEnd(io, allocator, file_path);
    defer allocator.free(file_source);

    const source = try std.mem.concat(allocator, u8, &.{ bindings.wgsl_header, common_wgsl, file_source });
    defer allocator.free(source);

    const wgsl: c.WGPUShaderSourceWGSL = .{
        .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
        .code = stringView(source),
    };

    gpu_debug.pushValidationScope(gpu.device);
    const module = c.wgpuDeviceCreateShaderModule(gpu.device, &.{
        .nextInChain = @constCast(&wgsl.chain),
        .label = stringView(file_path),
    });
    if (gpu_debug.popValidationScope(gpu.instance, gpu.device)) |scope_error| {
        log.err("{s} (subtract {d} from naga's line numbers): {s}", .{ file_path, PREPENDED_LINES, scope_error.message() });
        if (module != null) {
            c.wgpuShaderModuleRelease(module);
        }
        return error.ShaderCompile;
    }
    return module;
}

/// Groups 0-2: frame, material, object; group 3 when the shader binds pass resources.
fn createPipelineLayout(gpu: *const GpuContext, material: MaterialKind, pass: PassKind) c.WGPUPipelineLayout {
    const shared = &gpu.bindings;
    const pass_layout = shared.passLayout(pass);
    const layouts = [_]c.WGPUBindGroupLayout{ shared.frame_layout, shared.materialLayout(material), shared.object_layout, pass_layout };
    return c.wgpuDeviceCreatePipelineLayout(gpu.device, &.{
        .bindGroupLayoutCount = if (pass_layout != null) 4 else 3,
        .bindGroupLayouts = &layouts,
    });
}
