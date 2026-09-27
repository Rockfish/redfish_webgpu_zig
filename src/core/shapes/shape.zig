const std = @import("std");
const math = @import("math");
const containers = @import("containers");
const wgpu = @import("wgpu");
const bindings = @import("../bindings.zig");
const gpu_context = @import("../gpu_context.zig");
const AABB = @import("../aabb.zig").AABB;
const Shader = @import("../shader.zig").Shader;
const RenderState = @import("../pipeline.zig").RenderState;

const c = wgpu.c;
const stringView = wgpu.stringView;
const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;
const BindGroup = bindings.BindGroup;
const VertexAttr = bindings.VertexAttr;
const DrawUniforms = bindings.DrawUniforms;
const GpuContext = gpu_context.GpuContext;
const Frame = gpu_context.Frame;

/// Filled in for shapes built without the attribute, so every shape has the same layout.
const DEFAULT_TEXCOORD = [2]f32{ 0.0, 0.0 };
const DEFAULT_NORMAL = [3]f32{ 0.0, 0.0, 1.0 };
const DEFAULT_COLOR = [4]f32{ 1.0, 1.0, 1.0, 1.0 };

const position_attribute: c.WGPUVertexAttribute = .{ .format = c.WGPUVertexFormat_Float32x3, .shaderLocation = VertexAttr.position };
const texcoord_attribute: c.WGPUVertexAttribute = .{ .format = c.WGPUVertexFormat_Float32x2, .shaderLocation = VertexAttr.texcoord };
const normal_attribute: c.WGPUVertexAttribute = .{ .format = c.WGPUVertexFormat_Float32x3, .shaderLocation = VertexAttr.normal };
const color_attribute: c.WGPUVertexAttribute = .{ .format = c.WGPUVertexFormat_Float32x4, .shaderLocation = VertexAttr.color };

pub const ShapeBuilder = struct {
    allocator: Allocator,
    shape_type: ShapeType,
    positions: ManagedArrayList([3]f32),
    texcoords: ManagedArrayList([2]f32),
    normals: ManagedArrayList([3]f32),
    colors: ManagedArrayList([4]f32),
    indices: ManagedArrayList(u32),
    aabb: AABB,

    const Self = @This();

    pub fn init(allocator: Allocator, shape_type: ShapeType) ShapeBuilder {
        return .{
            .allocator = allocator,
            .shape_type = shape_type,
            .positions = ManagedArrayList([3]f32).init(allocator),
            .texcoords = ManagedArrayList([2]f32).init(allocator),
            .normals = ManagedArrayList([3]f32).init(allocator),
            .colors = ManagedArrayList([4]f32).init(allocator),
            .indices = ManagedArrayList(u32).init(allocator),
            .aabb = AABB.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.positions.deinit();
        self.texcoords.deinit();
        self.normals.deinit();
        self.colors.deinit();
        self.indices.deinit();
    }

    pub fn addVertex(self: *Self, position: [3]f32, normal: [3]f32, texCoord: [2]f32) !u32 {
        const index = @as(u32, @intCast(self.positions.items().len));
        try self.positions.append(position);
        try self.normals.append(normal);
        try self.texcoords.append(texCoord);
        self.aabb.expandWithArray(position);
        return index;
    }

    pub fn addIndex(self: *Self, index: u32) !void {
        try self.indices.append(index);
    }

    /// Sizes positions, texcoords, and normals for direct writes. Colors stay optional:
    /// resizing them without filling would upload garbage instead of the default.
    pub fn resize(self: *Self, size: u32) !void {
        try self.positions.resize(size);
        try self.texcoords.resize(size);
        try self.normals.resize(size);
    }

    pub fn build(self: *Self, gpu: *const GpuContext) !*Shape {
        return initGpuBuffers(
            self.allocator,
            gpu,
            self.shape_type,
            self.positions.list.items,
            self.texcoords.list.items,
            self.normals.list.items,
            self.colors.list.items,
            self.indices.list.items,
        );
    }
};

/// Uploads one vertex buffer per attribute plus the index buffer. Empty `texcoords`,
/// `normals`, or `colors` are filled with defaults.
pub fn initGpuBuffers(
    allocator: Allocator,
    gpu: *const GpuContext,
    shape_type: ShapeType,
    positions: []const [3]f32,
    texcoords: []const [2]f32,
    normals: []const [3]f32,
    colors: []const [4]f32,
    indices: []const u32,
) !*Shape {
    const vertex_count = positions.len;

    const texcoords_full = try orDefault([2]f32, allocator, texcoords, vertex_count, DEFAULT_TEXCOORD);
    defer if (texcoords_full.ptr != texcoords.ptr) allocator.free(texcoords_full);
    const normals_full = try orDefault([3]f32, allocator, normals, vertex_count, DEFAULT_NORMAL);
    defer if (normals_full.ptr != normals.ptr) allocator.free(normals_full);
    const colors_full = try orDefault([4]f32, allocator, colors, vertex_count, DEFAULT_COLOR);
    defer if (colors_full.ptr != colors.ptr) allocator.free(colors_full);

    const s = try allocator.create(Shape);
    s.* = .{
        .shape_type = shape_type,
        .position_buffer = createBuffer(gpu, "shape positions", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(positions)),
        .texcoord_buffer = createBuffer(gpu, "shape texcoords", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(texcoords_full)),
        .normal_buffer = createBuffer(gpu, "shape normals", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(normals_full)),
        .color_buffer = createBuffer(gpu, "shape colors", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(colors_full)),
        .index_buffer = createBuffer(gpu, "shape indices", c.WGPUBufferUsage_Index, std.mem.sliceAsBytes(indices)),
        .num_indices = @intCast(indices.len),
        .has_vertex_colors = colors.len > 0,
        .aabb = AABB.initWithPositions(positions),
    };
    return s;
}

pub const ShapeType = enum {
    square,
    plane,
    cube,
    cylinder,
    sphere,
    skybox,
    custom,
};

pub const Shape = struct {
    shape_type: ShapeType,
    position_buffer: c.WGPUBuffer,
    texcoord_buffer: c.WGPUBuffer,
    normal_buffer: c.WGPUBuffer,
    color_buffer: c.WGPUBuffer,
    index_buffer: c.WGPUBuffer,
    num_indices: u32,
    has_vertex_colors: bool = false,
    aabb: AABB,

    /// Skip rendering entirely. Use for temporarily hiding objects.
    is_visible: bool = true,

    /// Enable alpha blending. Set true for glass, particles, transparent materials.
    /// Note: Typically pair with is_depth_write = false for proper transparency.
    is_transparent: bool = false,

    /// Disable face culling to draw both sides. Use for planes, foliage, cloth.
    is_double_sided: bool = false,

    /// Write to depth buffer. Set false for transparent objects that shouldn't occlude.
    /// Default true for normal opaque rendering.
    is_depth_write: bool = true,

    /// Test against depth buffer. Set false for skyboxes, UI overlays, debug gizmos.
    /// Default true for normal 3D objects.
    is_depth_test: bool = true,

    const Self = @This();

    /// The vertex layout every shape uses: one buffer per attribute, at redfish's locations.
    /// Shaders that draw shapes are created with this.
    pub const vertex_buffer_layouts = [_]c.WGPUVertexBufferLayout{
        vertexBufferLayout(&position_attribute, @sizeOf([3]f32)),
        vertexBufferLayout(&texcoord_attribute, @sizeOf([2]f32)),
        vertexBufferLayout(&normal_attribute, @sizeOf([3]f32)),
        vertexBufferLayout(&color_attribute, @sizeOf([4]f32)),
    };

    /// Per-draw values go in `draw_uniforms`, copied into this frame's uniform ring,
    /// so any number of draws in a frame each see their own. A `.texture` shader draws
    /// with whatever texture was last bound (`texture.bind(frame)`).
    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, draw_uniforms: DrawUniforms) void {
        if (!self.is_visible) return;

        const gpu = frame.gpu;
        const pass = frame.pass;
        const draw_offset = gpu.uniform_ring.allocate(DrawUniforms, draw_uniforms);

        c.wgpuRenderPassEncoderSetPipeline(pass, shader.getPipeline(self.renderState()));
        if (shader.material == .none) {
            c.wgpuRenderPassEncoderSetBindGroup(pass, BindGroup.material, gpu.bindings.empty_bind_group, 0, null);
        }
        c.wgpuRenderPassEncoderSetBindGroup(pass, BindGroup.object, gpu.bindings.object_bind_group, 1, &draw_offset);

        const buffers = [_]c.WGPUBuffer{ self.position_buffer, self.texcoord_buffer, self.normal_buffer, self.color_buffer };
        for (buffers, 0..) |buffer, slot| {
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, @intCast(slot), buffer, 0, c.WGPU_WHOLE_SIZE);
        }
        c.wgpuRenderPassEncoderSetIndexBuffer(pass, self.index_buffer, c.WGPUIndexFormat_Uint32, 0, c.WGPU_WHOLE_SIZE);
        c.wgpuRenderPassEncoderDrawIndexed(pass, self.num_indices, 1, 0, 0, 0);
    }

    pub fn renderState(self: *const Self) RenderState {
        return .{
            .transparent = self.is_transparent,
            .double_sided = self.is_double_sided,
            .no_depth_write = !self.is_depth_write,
            .no_depth_test = !self.is_depth_test,
        };
    }

    pub fn releaseGpuObjects(self: *Self) void {
        c.wgpuBufferRelease(self.position_buffer);
        c.wgpuBufferRelease(self.texcoord_buffer);
        c.wgpuBufferRelease(self.normal_buffer);
        c.wgpuBufferRelease(self.color_buffer);
        c.wgpuBufferRelease(self.index_buffer);
    }
};

fn vertexBufferLayout(attribute: *const c.WGPUVertexAttribute, stride: u64) c.WGPUVertexBufferLayout {
    return .{
        .stepMode = c.WGPUVertexStepMode_Vertex,
        .arrayStride = stride,
        .attributeCount = 1,
        .attributes = attribute,
    };
}

/// `values` if it has one entry per vertex; otherwise a new slice of `default`.
fn orDefault(comptime T: type, allocator: Allocator, values: []const T, vertex_count: usize, default: T) ![]const T {
    if (values.len == vertex_count) return values;
    std.debug.assert(values.len == 0);

    const filled = try allocator.alloc(T, vertex_count);
    @memset(filled, default);
    return filled;
}

fn createBuffer(gpu: *const GpuContext, label: []const u8, usage: c.WGPUBufferUsage, data: []const u8) c.WGPUBuffer {
    const buffer = c.wgpuDeviceCreateBuffer(gpu.device, &.{
        .label = stringView(label),
        .usage = usage | c.WGPUBufferUsage_CopyDst,
        .size = data.len,
    });
    c.wgpuQueueWriteBuffer(gpu.queue, buffer, 0, data.ptr, data.len);
    return buffer;
}
