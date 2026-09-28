const std = @import("std");
const zstbi = @import("zstbi");
const math = @import("math");
const wgpu = @import("wgpu");
const utils = @import("../utils/root.zig");
const bindings = @import("../bindings.zig");
const gpu_context = @import("../gpu_context.zig");
const texture_ = @import("../texture.zig");
const Shader = @import("../shader.zig").Shader;

const c = wgpu.c;
const stringView = wgpu.stringView;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const BindGroup = bindings.BindGroup;
const DrawUniforms = bindings.DrawUniforms;
const GpuContext = gpu_context.GpuContext;
const Frame = gpu_context.Frame;
const Mat4 = math.Mat4;

const SHADER_PATH = "src/core/shaders/skybox.wgsl";

const SKYBOX_VERTICES = [_]f32{
    -1.0, 1.0,  -1.0,
    -1.0, -1.0, -1.0,
    1.0,  -1.0, -1.0,
    1.0,  -1.0, -1.0,
    1.0,  1.0,  -1.0,
    -1.0, 1.0,  -1.0,

    -1.0, -1.0, 1.0,
    -1.0, -1.0, -1.0,
    -1.0, 1.0,  -1.0,
    -1.0, 1.0,  -1.0,
    -1.0, 1.0,  1.0,
    -1.0, -1.0, 1.0,

    1.0,  -1.0, -1.0,
    1.0,  -1.0, 1.0,
    1.0,  1.0,  1.0,
    1.0,  1.0,  1.0,
    1.0,  1.0,  -1.0,
    1.0,  -1.0, -1.0,

    -1.0, -1.0, 1.0,
    -1.0, 1.0,  1.0,
    1.0,  1.0,  1.0,
    1.0,  1.0,  1.0,
    1.0,  -1.0, 1.0,
    -1.0, -1.0, 1.0,

    -1.0, 1.0,  -1.0,
    1.0,  1.0,  -1.0,
    1.0,  1.0,  1.0,
    1.0,  1.0,  1.0,
    -1.0, 1.0,  1.0,
    -1.0, 1.0,  -1.0,

    -1.0, -1.0, -1.0,
    -1.0, -1.0, 1.0,
    1.0,  -1.0, -1.0,
    1.0,  -1.0, -1.0,
    -1.0, -1.0, 1.0,
    1.0,  -1.0, 1.0,
};

const position_attribute: c.WGPUVertexAttribute = .{
    .format = c.WGPUVertexFormat_Float32x3,
    .shaderLocation = bindings.VertexAttr.position,
};

const vertex_buffer_layouts = [_]c.WGPUVertexBufferLayout{.{
    .stepMode = c.WGPUVertexStepMode_Vertex,
    .arrayStride = 3 * @sizeOf(f32),
    .attributeCount = 1,
    .attributes = &position_attribute,
}};

pub const SkyboxFaces = struct {
    right: [:0]const u8,
    left: [:0]const u8,
    top: [:0]const u8,
    bottom: [:0]const u8,
    forward: [:0]const u8,
    back: [:0]const u8,
    /// redfish core's layout (bullets): +Z = back, -Z = forward, each face flipped
    /// horizontally. False: the standard order with `forward` at +Z and no flip, as
    /// examples/skybox's own loader.
    mirrored: bool = true,
};

/// A cube-map sky drawn at depth 1 behind everything. Owns its shader and pipeline
/// (`LessEqual` depth, no depth write, no culling), so apps just call `draw`.
pub const Skybox = struct {
    shader: *Shader,
    vertex_buffer: c.WGPUBuffer,
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    bind_group: c.WGPUBindGroup,

    const Self = @This();

    pub fn init(io: Io, allocator: Allocator, gpu: *GpuContext, faces: SkyboxFaces) !Self {
        const shader = try Shader.init(io, allocator, gpu, SHADER_PATH, .{
            .vertex_buffers = &vertex_buffer_layouts,
            .material = .cube_texture,
            .depth_compare = c.WGPUCompareFunction_LessEqual,
        });

        const vertex_buffer = c.wgpuDeviceCreateBuffer(gpu.device, &.{
            .label = stringView("skybox vertices"),
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(@TypeOf(SKYBOX_VERTICES)),
        });
        c.wgpuQueueWriteBuffer(gpu.queue, vertex_buffer, 0, &SKYBOX_VERTICES, @sizeOf(@TypeOf(SKYBOX_VERTICES)));

        const texture = try loadCubemap(io, allocator, gpu, faces);
        const view = c.wgpuTextureCreateView(texture, &.{
            .format = c.WGPUTextureFormat_RGBA8UnormSrgb,
            .dimension = c.WGPUTextureViewDimension_Cube,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 6,
            .aspect = c.WGPUTextureAspect_All,
        });

        const sampler = try gpu.samplers.get(gpu.device, texture_.SamplerKey.fromConfig(.{ .filter = .Linear, .wrap = .Clamp }));
        const entries = [_]c.WGPUBindGroupEntry{
            .{ .binding = 0, .textureView = view },
            .{ .binding = 1, .sampler = sampler },
        };

        return .{
            .shader = shader,
            .vertex_buffer = vertex_buffer,
            .texture = texture,
            .view = view,
            .bind_group = c.wgpuDeviceCreateBindGroup(gpu.device, &.{
                .label = stringView("skybox"),
                .layout = gpu.bindings.cube_texture_layout,
                .entryCount = entries.len,
                .entries = &entries,
            }),
        };
    }

    /// Uses the frame's camera; drop order doesn't matter (depth 1, `LessEqual`).
    pub fn draw(self: *const Self, frame: *const Frame) void {
        const gpu = frame.gpu;
        const pass = frame.pass;
        const draw_offset = gpu.uniform_ring.allocate(DrawUniforms, DrawUniforms.init(Mat4.Identity, math.vec4(1.0, 1.0, 1.0, 1.0)));

        c.wgpuRenderPassEncoderSetPipeline(pass, self.shader.getPipeline(.{ .double_sided = true, .no_depth_write = true }));
        c.wgpuRenderPassEncoderSetBindGroup(pass, BindGroup.material, self.bind_group, 0, null);
        c.wgpuRenderPassEncoderSetBindGroup(pass, BindGroup.object, gpu.bindings.object_bind_group, 1, &draw_offset);
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buffer, 0, c.WGPU_WHOLE_SIZE);
        c.wgpuRenderPassEncoderDraw(pass, SKYBOX_VERTICES.len / 3, 1, 0, 0);
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuTextureViewRelease(self.view);
        c.wgpuTextureRelease(self.texture);
        c.wgpuBufferRelease(self.vertex_buffer);
        self.shader.releaseGpuObjects();
    }
};

/// Six faces as layers of one texture, in cube order (+X, -X, +Y, -Y, +Z, -Z), laid out
/// as `faces.mirrored` says.
fn loadCubemap(io: Io, allocator: Allocator, gpu: *GpuContext, faces: SkyboxFaces) !c.WGPUTexture {
    zstbi.init(io, allocator);
    defer zstbi.deinit();

    const face_paths = if (faces.mirrored)
        [_][:0]const u8{ faces.right, faces.left, faces.top, faces.bottom, faces.back, faces.forward }
    else
        [_][:0]const u8{ faces.right, faces.left, faces.top, faces.bottom, faces.forward, faces.back };

    var texture: c.WGPUTexture = null;
    var face_size: [2]u32 = .{ 0, 0 };

    for (face_paths, 0..) |path, layer| {
        var image = try zstbi.Image.loadFromFile(path, 4);
        defer image.deinit();
        if (faces.mirrored) utils.flipImageHorizontal(&image);

        if (texture == null) {
            face_size = .{ image.width, image.height };
            texture = c.wgpuDeviceCreateTexture(gpu.device, &.{
                .label = stringView("skybox"),
                .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
                .dimension = c.WGPUTextureDimension_2D,
                .size = .{ .width = image.width, .height = image.height, .depthOrArrayLayers = 6 },
                .format = c.WGPUTextureFormat_RGBA8UnormSrgb,
                .mipLevelCount = 1,
                .sampleCount = 1,
            });
        } else if (image.width != face_size[0] or image.height != face_size[1]) {
            return error.SkyboxFaceSizeMismatch;
        }

        c.wgpuQueueWriteTexture(
            gpu.queue,
            &.{ .texture = texture, .mipLevel = 0, .origin = .{ .z = @intCast(layer) }, .aspect = c.WGPUTextureAspect_All },
            image.data.ptr,
            image.data.len,
            &.{ .bytesPerRow = image.width * 4, .rowsPerImage = image.height },
            &.{ .width = image.width, .height = image.height, .depthOrArrayLayers = 1 },
        );
    }
    return texture;
}
