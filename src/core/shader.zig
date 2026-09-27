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

const log = std.log.scoped(.shader);

const common_wgsl = @embedFile("shaders/common.wgsl");

/// Lines before the shader file's own source; naga's line numbers include them.
const PREPENDED_LINES = std.mem.count(u8, bindings.wgsl_header, "\n") + std.mem.count(u8, common_wgsl, "\n");

pub const Shader = struct {
    file_path: []const u8,
    material: MaterialKind,
    module: c.WGPUShaderModule,
    pipeline_layout: c.WGPUPipelineLayout,
    variants: PipelineVariants,

    const Self = @This();

    /// `vertex_buffers` is the vertex layout of the geometry this shader draws
    /// (e.g. `Shape.vertex_buffer_layouts`); `material` is what it binds at group 1.
    pub fn init(
        io: Io,
        allocator: Allocator,
        gpu: *const GpuContext,
        file_path: []const u8,
        vertex_buffers: []const c.WGPUVertexBufferLayout,
        material: MaterialKind,
    ) !*Shader {
        const module = try createModule(io, allocator, gpu, file_path);
        const pipeline_layout = createPipelineLayout(gpu, material);

        const shader = try allocator.create(Shader);
        shader.* = .{
            .file_path = try allocator.dupe(u8, file_path),
            .material = material,
            .module = module,
            .pipeline_layout = pipeline_layout,
            .variants = PipelineVariants.init(gpu.device, .{
                .label = file_path,
                .module = module,
                .layout = pipeline_layout,
                .vertex_buffers = vertex_buffers,
                .color_format = gpu.surface_format,
                .depth_format = gpu_context.depth_format,
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
        if (module != null) c.wgpuShaderModuleRelease(module);
        return error.ShaderCompile;
    }
    return module;
}

/// Groups 0-2: frame, material, object.
fn createPipelineLayout(gpu: *const GpuContext, material: MaterialKind) c.WGPUPipelineLayout {
    const shared = &gpu.bindings;
    const layouts = [_]c.WGPUBindGroupLayout{ shared.frame_layout, shared.materialLayout(material), shared.object_layout };
    return c.wgpuDeviceCreatePipelineLayout(gpu.device, &.{
        .bindGroupLayoutCount = layouts.len,
        .bindGroupLayouts = &layouts,
    });
}
