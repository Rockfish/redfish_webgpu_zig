//! glTF meshes on the GPU. Every attribute is converted on load to one canonical vertex
//! format (see docs/designs/004-gltf-pbr.md), so one vertex layout and one set of
//! pipelines serve every primitive. Missing attributes are filled with defaults.

const std = @import("std");
const math = @import("math");
const containers = @import("containers");
const wgpu = @import("wgpu");
const bindings = @import("bindings.zig");
const gltf_types = @import("gltf/gltf.zig");
const gpu_context = @import("gpu_context.zig");
const material_ = @import("material.zig");
const Shader = @import("shader.zig").Shader;
const GltfAsset = @import("gltf_asset.zig").GltfAsset;
const Texture = @import("texture.zig").Texture;
const SkinBinding = @import("skinning.zig").SkinBinding;

const c = wgpu.c;
const stringView = wgpu.stringView;
const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;
const Mat4 = math.Mat4;
const BindGroup = bindings.BindGroup;
const VertexAttr = bindings.VertexAttr;
const DrawUniforms = bindings.DrawUniforms;
const Frame = gpu_context.Frame;
const PbrMaterial = material_.PbrMaterial;
const TextureSlot = material_.TextureSlot;

const log = std.log.scoped(.mesh);

/// Canonical per-vertex attributes, in vertex buffer slot order.
const Attribute = enum {
    position,
    texcoord,
    normal,
    tangent,
    color,
    joints,
    weights,

    fn location(self: Attribute) u32 {
        return switch (self) {
            .position => VertexAttr.position,
            .texcoord => VertexAttr.texcoord,
            .normal => VertexAttr.normal,
            .tangent => VertexAttr.tangent,
            .color => VertexAttr.color,
            .joints => VertexAttr.joints,
            .weights => VertexAttr.weights,
        };
    }
};
const ATTRIBUTE_COUNT = @typeInfo(Attribute).@"enum".fields.len;

const vertex_attributes = blk: {
    var attributes: [ATTRIBUTE_COUNT]c.WGPUVertexAttribute = undefined;
    for (&attributes, 0..) |*attribute, i| {
        const kind: Attribute = @enumFromInt(i);
        attribute.* = .{
            .format = switch (kind) {
                .position, .normal => c.WGPUVertexFormat_Float32x3,
                .texcoord => c.WGPUVertexFormat_Float32x2,
                .tangent, .color, .weights => c.WGPUVertexFormat_Float32x4,
                .joints => c.WGPUVertexFormat_Uint32x4,
            },
            .shaderLocation = kind.location(),
        };
    }
    break :blk attributes;
};

pub const Mesh = struct {
    name: ?[]const u8,
    is_visible: bool = true,
    primitives: ManagedArrayList(*MeshPrimitive),

    const Self = @This();

    pub fn init(alloc: Allocator, gltf_asset: *GltfAsset, gltf_mesh: gltf_types.Mesh, mesh_index: usize) !*Mesh {
        const mesh = try alloc.create(Mesh);

        mesh.* = Mesh{
            .name = gltf_mesh.name,
            .primitives = ManagedArrayList(*MeshPrimitive).init(alloc),
        };

        for (gltf_mesh.primitives, 0..) |primitive, primitive_index| {
            const mesh_primitive = try MeshPrimitive.init(alloc, gltf_asset, primitive, mesh_index, primitive_index, gltf_mesh.name);
            try mesh.primitives.append(mesh_primitive);
        }

        return mesh;
    }

    /// The one draw path `Model`, `ModelInstance`, and `BakedAnimator` share. Unskinned
    /// primitives draw at `model_transform * node_matrix`; skinned ones (with `skin`) at
    /// `model_transform` with their joints, as glTF says the node transform doesn't apply.
    pub fn drawAt(
        self: *const Self,
        frame: *const Frame,
        shader: *const Shader,
        model_transform: Mat4,
        node_matrix: Mat4,
        skin: ?SkinBinding,
    ) void {
        if (!self.is_visible) return;
        const white = math.vec4(1.0, 1.0, 1.0, 1.0);
        const unskinned = DrawUniforms.init(model_transform.mulMat4(&node_matrix), white);
        const default_object = frame.gpu.bindings.object_bind_group;

        for (self.primitives.list.items) |primitive| {
            if (primitive.has_skin) {
                if (skin) |binding| {
                    var skinned = DrawUniforms.init(model_transform, white);
                    skinned.joint_offset = binding.joint_offset;
                    skinned.flags |= bindings.DrawFlags.skinned;
                    primitive.draw(frame, shader, skinned, binding.object_bind_group);
                    continue;
                }
            }
            primitive.draw(frame, shader, unskinned, default_object);
        }
    }

    pub fn cleanUp(self: *Self) void {
        for (self.primitives.items()) |primitive| {
            primitive.releaseGpuObjects();
        }
    }
};

pub const MeshPrimitive = struct {
    id: usize,
    name: ?[]const u8 = null,
    material: PbrMaterial,
    vertex_buffers: [ATTRIBUTE_COUNT]c.WGPUBuffer,
    index_buffer: c.WGPUBuffer = null,
    index_format: c.WGPUIndexFormat = c.WGPUIndexFormat_Uint16,
    indices_count: u32 = 0,
    vertex_count: u32 = 0,
    has_skin: bool = false,
    has_normals: bool = false,
    has_vertex_colors: bool = false,

    const Self = @This();

    /// The vertex layout every glTF primitive uses; PBR shaders are created with this.
    pub const vertex_buffer_layouts = blk: {
        var layouts: [ATTRIBUTE_COUNT]c.WGPUVertexBufferLayout = undefined;
        for (&layouts, 0..) |*layout, i| {
            const kind: Attribute = @enumFromInt(i);
            layout.* = .{
                .stepMode = c.WGPUVertexStepMode_Vertex,
                .arrayStride = switch (kind) {
                    .position, .normal => 12,
                    .texcoord => 8,
                    .tangent, .color, .weights, .joints => 16,
                },
                .attributeCount = 1,
                .attributes = &vertex_attributes[i],
            };
        }
        break :blk layouts;
    };

    pub fn init(
        alloc: Allocator,
        gltf_asset: *GltfAsset,
        primitive: gltf_types.MeshPrimitive,
        mesh_index: usize,
        primitive_index: usize,
        mesh_name: ?[]const u8,
    ) !*MeshPrimitive {
        const gpu = gltf_asset.gpu;
        const temp = gltf_asset.context.temp_alloc;
        const attributes = primitive.attributes;

        if (primitive.mode != .triangles) {
            log.warn("mesh {s}: primitive mode {s} not supported, drawn as triangles", .{ mesh_name orelse "?", @tagName(primitive.mode) });
        }

        const position_accessor = attributes.position orelse return error.MissingPositions;
        const vertex_count = gltf_asset.gltf.accessors.?[position_accessor].count;

        var vertex_buffers: [ATTRIBUTE_COUNT]c.WGPUBuffer = undefined;
        const reader = AccessorReader{ .gltf_asset = gltf_asset };

        const positions = try reader.readFloats(temp, 3, position_accessor, vertex_count, .{ 0, 0, 0 });
        defer temp.free(positions);
        vertex_buffers[@intFromEnum(Attribute.position)] = createBuffer(gpu, "positions", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(positions));

        const texcoords = try reader.readFloatsOrDefault(temp, 2, attributes.tex_coord_0, vertex_count, .{ 0, 0 });
        defer temp.free(texcoords);
        vertex_buffers[@intFromEnum(Attribute.texcoord)] = createBuffer(gpu, "texcoords", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(texcoords));

        const normals = try readNormals(temp, gltf_asset, reader, attributes.normal, mesh_index, primitive_index, vertex_count);
        defer temp.free(normals.values);
        vertex_buffers[@intFromEnum(Attribute.normal)] = createBuffer(gpu, "normals", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(normals.values));

        const tangents = try reader.readFloatsOrDefault(temp, 4, attributes.tangent, vertex_count, .{ 1, 0, 0, 1 });
        defer temp.free(tangents);
        vertex_buffers[@intFromEnum(Attribute.tangent)] = createBuffer(gpu, "tangents", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(tangents));

        // vec3 colors get alpha 1 from the default's fourth component
        const colors = try reader.readFloatsOrDefault(temp, 4, attributes.color_0, vertex_count, .{ 1, 1, 1, 1 });
        defer temp.free(colors);
        vertex_buffers[@intFromEnum(Attribute.color)] = createBuffer(gpu, "colors", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(colors));

        const joints = try reader.readUintsOrDefault(temp, attributes.joints_0, vertex_count);
        defer temp.free(joints);
        vertex_buffers[@intFromEnum(Attribute.joints)] = createBuffer(gpu, "joints", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(joints));

        const weights = try reader.readFloatsOrDefault(temp, 4, attributes.weights_0, vertex_count, .{ 0, 0, 0, 0 });
        defer temp.free(weights);
        vertex_buffers[@intFromEnum(Attribute.weights)] = createBuffer(gpu, "weights", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(weights));

        const has_skin = attributes.joints_0 != null and attributes.weights_0 != null;
        const has_vertex_colors = attributes.color_0 != null;
        const material = if (primitive.material) |material_id| gltf_asset.gltf.materials.?[material_id] else material_.defaultMaterial();

        const mesh_primitive = try alloc.create(MeshPrimitive);
        mesh_primitive.* = MeshPrimitive{
            .id = primitive_index,
            .name = mesh_name,
            .vertex_buffers = vertex_buffers,
            .vertex_count = vertex_count,
            .has_skin = has_skin,
            .has_normals = normals.is_real,
            .has_vertex_colors = has_vertex_colors,
            .material = try PbrMaterial.init(gpu, material, try loadMaterialTextures(gltf_asset, material, mesh_name), .{
                .has_normals = normals.is_real,
                .has_vertex_colors = has_vertex_colors,
                .has_skin = has_skin,
            }),
        };

        if (primitive.indices) |accessor_id| try mesh_primitive.createIndexBuffer(reader, accessor_id);

        return mesh_primitive;
    }

    /// Sets the pipeline for the material's render state, binds material and per-draw
    /// data, and draws. `shader` must be a `MaterialKind.pbr` shader built with
    /// `vertex_buffer_layouts`. `object_bind_group` is group 2: the shared one, or a
    /// skinned instance's (ring plus its joints).
    pub fn draw(
        self: *const Self,
        frame: *const Frame,
        shader: *const Shader,
        draw_uniforms: DrawUniforms,
        object_bind_group: c.WGPUBindGroup,
    ) void {
        std.debug.assert(shader.material == .pbr);
        const gpu = frame.gpu;
        const pass = frame.pass;
        const draw_offset = gpu.uniform_ring.allocate(DrawUniforms, draw_uniforms);

        c.wgpuRenderPassEncoderSetPipeline(pass, shader.getPipeline(self.material.render_state));
        self.material.setBindGroup(frame);
        c.wgpuRenderPassEncoderSetBindGroup(pass, BindGroup.object, object_bind_group, 1, &draw_offset);

        for (self.vertex_buffers, 0..) |buffer, slot| {
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, @intCast(slot), buffer, 0, c.WGPU_WHOLE_SIZE);
        }

        if (self.index_buffer != null) {
            c.wgpuRenderPassEncoderSetIndexBuffer(pass, self.index_buffer, self.index_format, 0, c.WGPU_WHOLE_SIZE);
            c.wgpuRenderPassEncoderDrawIndexed(pass, self.indices_count, 1, 0, 0, 0);
        } else {
            c.wgpuRenderPassEncoderDraw(pass, self.vertex_count, 1, 0, 0);
        }
    }

    pub fn releaseGpuObjects(self: *Self) void {
        self.material.releaseGpuObjects();
        for (self.vertex_buffers) |buffer| c.wgpuBufferRelease(buffer);
        if (self.index_buffer != null) c.wgpuBufferRelease(self.index_buffer);
    }

    /// u8 indices widen to u16 (WebGPU has no 8-bit index format); u16 and u32 are kept.
    fn createIndexBuffer(self: *Self, reader: AccessorReader, accessor_id: u32) !void {
        const gltf_asset = reader.gltf_asset;
        const temp = gltf_asset.context.temp_alloc;
        const accessor = gltf_asset.gltf.accessors.?[accessor_id];
        self.indices_count = accessor.count;

        if (accessor.component_type == .unsigned_int) {
            const indices = try reader.readIndices(u32, temp, accessor_id);
            defer temp.free(indices);
            self.index_format = c.WGPUIndexFormat_Uint32;
            self.index_buffer = createBuffer(gltf_asset.gpu, "indices", c.WGPUBufferUsage_Index, std.mem.sliceAsBytes(indices));
        } else {
            const indices = try reader.readIndices(u16, temp, accessor_id);
            defer temp.free(indices);
            self.index_format = c.WGPUIndexFormat_Uint16;
            self.index_buffer = createBuffer(gltf_asset.gpu, "indices", c.WGPUBufferUsage_Index, std.mem.sliceAsBytes(indices));
        }
    }
};

/// Loads (or reuses) each texture the material references; custom textures added for
/// this mesh name override their slot. With `skipModelTextures`, only custom textures
/// are used and the other slots bind the defaults.
fn loadMaterialTextures(gltf_asset: *GltfAsset, material: gltf_types.Material, mesh_name: ?[]const u8) ![bindings.PBR_TEXTURE_COUNT]?*const Texture {
    var textures: [bindings.PBR_TEXTURE_COUNT]?*const Texture = @splat(null);

    for (&textures, 0..) |*texture, i| {
        const slot: TextureSlot = @enumFromInt(i);
        if (mesh_name) |name| {
            if (gltf_asset.getCustomTexture(name, slot)) |custom| {
                texture.* = custom;
                continue;
            }
        }
        if (!gltf_asset.load_textures) continue;
        if (material_.textureIndex(material, slot)) |texture_index| {
            texture.* = try gltf_asset.loadTextureFromGltf(texture_index, slot.isSrgb());
        }
    }
    return textures;
}

const Normals = struct {
    values: [][3]f32,
    /// False when neither the file nor normal generation provided them.
    is_real: bool,
};

fn readNormals(
    temp: Allocator,
    gltf_asset: *GltfAsset,
    reader: AccessorReader,
    accessor_id: ?u32,
    mesh_index: usize,
    primitive_index: usize,
    vertex_count: u32,
) !Normals {
    if (accessor_id) |id| {
        return .{ .values = try reader.readFloats(temp, 3, id, vertex_count, .{ 0, 1, 0 }), .is_real = true };
    }

    const values = try temp.alloc([3]f32, vertex_count);
    if (gltf_asset.getGeneratedNormals(@intCast(mesh_index), @intCast(primitive_index))) |generated| {
        for (values, generated) |*value, normal| value.* = .{ normal.x, normal.y, normal.z };
        return .{ .values = values, .is_real = true };
    }
    @memset(values, .{ 0, 1, 0 });
    return .{ .values = values, .is_real = false };
}

/// Reads accessor elements into canonical arrays, handling component type,
/// normalization, and buffer view stride (so interleaved data needs no special case).
const AccessorReader = struct {
    gltf_asset: *GltfAsset,

    const Self = @This();

    fn readFloatsOrDefault(self: Self, allocator: Allocator, comptime N: usize, accessor_id: ?u32, count: u32, default: [N]f32) ![][N]f32 {
        if (accessor_id) |id| return self.readFloats(allocator, N, id, count, default);
        const values = try allocator.alloc([N]f32, count);
        @memset(values, default);
        return values;
    }

    /// Components beyond the accessor's type size come from `default`.
    fn readFloats(self: Self, allocator: Allocator, comptime N: usize, accessor_id: u32, count: u32, default: [N]f32) ![][N]f32 {
        const view = try self.elementView(accessor_id);
        if (view.accessor.count != count) return error.AccessorCountMismatch;

        const values = try allocator.alloc([N]f32, count);
        const components = @min(N, typeSize(view.accessor.accessor_type));
        for (values, 0..) |*value, i| {
            value.* = default;
            const element = view.element(i);
            for (0..components) |k| {
                value[k] = readComponentFloat(element, view.accessor.component_type, k, view.accessor.normalized);
            }
        }
        return values;
    }

    /// Joint indices as u32x4, or zeros when the primitive has none.
    fn readUintsOrDefault(self: Self, allocator: Allocator, accessor_id: ?u32, count: u32) ![][4]u32 {
        const values = try allocator.alloc([4]u32, count);
        @memset(values, .{ 0, 0, 0, 0 });
        const id = accessor_id orelse return values;

        const view = try self.elementView(id);
        if (view.accessor.count != count) return error.AccessorCountMismatch;
        const components = @min(4, typeSize(view.accessor.accessor_type));
        for (values, 0..) |*value, i| {
            const element = view.element(i);
            for (0..components) |k| value[k] = readComponentUint(element, view.accessor.component_type, k);
        }
        return values;
    }

    /// Index data as `T`; the result's byte size is padded to a multiple of 4.
    fn readIndices(self: Self, comptime T: type, allocator: Allocator, accessor_id: u32) ![]T {
        const view = try self.elementView(accessor_id);
        const count = view.accessor.count;
        const padded_count = std.mem.alignForward(usize, count * @sizeOf(T), 4) / @sizeOf(T);

        const indices = try allocator.alloc(T, padded_count);
        @memset(indices, 0);
        for (indices[0..count], 0..) |*index, i| {
            index.* = @intCast(readComponentUint(view.element(i), view.accessor.component_type, 0));
        }
        return indices;
    }

    fn elementView(self: Self, accessor_id: u32) !ElementView {
        const gltf = self.gltf_asset.gltf;
        const accessor = gltf.accessors.?[accessor_id];
        if (accessor.sparse != null) log.warn("sparse accessor {d} not supported; using base values", .{accessor_id});

        const buffer_view_id = accessor.buffer_view orelse return error.AccessorWithoutBufferView;
        const buffer_view = gltf.buffer_views.?[buffer_view_id];
        const buffer = self.gltf_asset.buffer_data.list.items[buffer_view.buffer];

        const element_size = componentSize(accessor.component_type) * typeSize(accessor.accessor_type);
        const stride = buffer_view.byte_stride orelse @as(u32, @intCast(element_size));
        const start = buffer_view.byte_offset + accessor.byte_offset;
        const end = start + stride * (accessor.count -| 1) + element_size;
        if (accessor.count > 0 and end > buffer.len) return error.AccessorOutOfBounds;

        return .{ .accessor = accessor, .data = buffer[start..@max(start, end)], .stride = stride, .element_size = element_size };
    }
};

const ElementView = struct {
    accessor: gltf_types.Accessor,
    data: []const u8,
    stride: usize,
    element_size: usize,

    fn element(self: ElementView, index: usize) []const u8 {
        const offset = index * self.stride;
        return self.data[offset .. offset + self.element_size];
    }
};

/// glTF normalized integers map to 0..1 (unsigned) or -1..1 (signed).
fn readComponentFloat(element: []const u8, component_type: gltf_types.ComponentType, k: usize, normalized: bool) f32 {
    return switch (component_type) {
        .float => @bitCast(std.mem.readInt(u32, element[k * 4 ..][0..4], .little)),
        .unsigned_byte => normalize(u8, element[k], normalized),
        .byte => normalize(i8, @bitCast(element[k]), normalized),
        .unsigned_short => normalize(u16, std.mem.readInt(u16, element[k * 2 ..][0..2], .little), normalized),
        .short => normalize(i16, std.mem.readInt(i16, element[k * 2 ..][0..2], .little), normalized),
        .unsigned_int => @floatFromInt(std.mem.readInt(u32, element[k * 4 ..][0..4], .little)),
    };
}

fn readComponentUint(element: []const u8, component_type: gltf_types.ComponentType, k: usize) u32 {
    return switch (component_type) {
        .unsigned_byte => element[k],
        .unsigned_short => std.mem.readInt(u16, element[k * 2 ..][0..2], .little),
        .unsigned_int => std.mem.readInt(u32, element[k * 4 ..][0..4], .little),
        else => 0,
    };
}

fn normalize(comptime T: type, value: T, normalized: bool) f32 {
    const f: f32 = @floatFromInt(value);
    if (!normalized) return f;
    const max: f32 = @floatFromInt(std.math.maxInt(T));
    return @max(f / max, -1.0);
}

fn componentSize(component_type: gltf_types.ComponentType) usize {
    return switch (component_type) {
        .byte, .unsigned_byte => 1,
        .short, .unsigned_short => 2,
        .unsigned_int, .float => 4,
    };
}

fn typeSize(accessor_type: gltf_types.AccessorType) usize {
    return switch (accessor_type) {
        .scalar => 1,
        .vec2 => 2,
        .vec3 => 3,
        .vec4 => 4,
        .mat2 => 4,
        .mat3 => 9,
        .mat4 => 16,
    };
}

fn createBuffer(gpu: *gpu_context.GpuContext, label: []const u8, usage: c.WGPUBufferUsage, data: []const u8) c.WGPUBuffer {
    std.debug.assert(data.len % 4 == 0);
    const buffer = c.wgpuDeviceCreateBuffer(gpu.device, &.{
        .label = stringView(label),
        .usage = usage | c.WGPUBufferUsage_CopyDst,
        .size = @max(data.len, 4),
    });
    if (data.len > 0) c.wgpuQueueWriteBuffer(gpu.queue, buffer, 0, data.ptr, data.len);
    return buffer;
}

test "normalize maps integer ranges to unit floats" {
    try std.testing.expectEqual(@as(f32, 1.0), normalize(u8, 255, true));
    try std.testing.expectEqual(@as(f32, 0.0), normalize(u16, 0, true));
    try std.testing.expectEqual(@as(f32, -1.0), normalize(i8, -128, true));
    try std.testing.expectEqual(@as(f32, 7.0), normalize(u8, 7, false));
}

test "ElementView steps by stride for interleaved data" {
    // Two elements of 2 bytes each, interleaved with 2 bytes of other data
    const data = [_]u8{ 1, 2, 9, 9, 3, 4 };
    const view: ElementView = .{ .accessor = undefined, .data = &data, .stride = 4, .element_size = 2 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, view.element(0));
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, view.element(1));
}
