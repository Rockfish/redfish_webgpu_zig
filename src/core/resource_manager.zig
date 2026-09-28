const std = @import("std");
const containers = @import("containers");

const Context = @import("context.zig").Context;
const GpuContext = @import("gpu_context.zig").GpuContext;
const texture_mod = @import("texture.zig");
const shapes = @import("shapes/root.zig");
const shader_mod = @import("shader.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;

const Texture = texture_mod.Texture;
const TextureConfig = texture_mod.TextureConfig;
const Shader = shader_mod.Shader;
const ShaderConfig = shader_mod.ShaderConfig;
const ModelInstance = @import("model_instance.zig").ModelInstance;
const Shape = shapes.Shape;
const PbrMaterial = @import("material.zig").PbrMaterial;
const PBR_TEXTURE_COUNT = @import("bindings.zig").PBR_TEXTURE_COUNT;

/// Tracks the GPU resources a scene creates so `cleanUp` can release them all before the
/// scene's arena resets.
pub const ResourceManager = struct {
    context: Context,
    gpu: *GpuContext,

    shaders: ManagedArrayList(*Shader),
    textures: ManagedArrayList(*Texture),
    model_instances: ManagedArrayList(*ModelInstance),
    obj_shapes: ManagedArrayList(*Shape),
    materials: ManagedArrayList(*PbrMaterial),

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext) !*Self {
        const rm = try context.alloc.create(Self);
        rm.* = .{
            .context = context,
            .gpu = gpu,
            .shaders = ManagedArrayList(*Shader).init(context.alloc),
            .textures = ManagedArrayList(*Texture).init(context.alloc),
            .model_instances = ManagedArrayList(*ModelInstance).init(context.alloc),
            .obj_shapes = ManagedArrayList(*Shape).init(context.alloc),
            .materials = ManagedArrayList(*PbrMaterial).init(context.alloc),
        };
        return rm;
    }

    /// WGSL shader; see `ShaderConfig` for the vertex layout, material, and topology.
    pub fn createShader(self: *Self, path: []const u8, config: ShaderConfig) !*Shader {
        const shader = try Shader.init(self.context.io, self.context.alloc, self.gpu, path, config);
        try self.shaders.append(shader);
        return shader;
    }

    pub fn createTexture(self: *Self, path: [:0]const u8, config: TextureConfig) !*Texture {
        const tex = try Texture.initFromFile(self.context, self.gpu, path, config);
        try self.textures.append(tex);
        return tex;
    }

    /// A `.pbr`-layout material from textures (slots: base color, metallic-roughness,
    /// normal, occlusion, emissive; null binds the default), for shapes.
    pub fn createMaterial(self: *Self, textures: [PBR_TEXTURE_COUNT]?*const Texture) !*PbrMaterial {
        const material = try self.context.alloc.create(PbrMaterial);
        material.* = try PbrMaterial.initWithTextures(self.gpu, textures);
        try self.materials.append(material);
        return material;
    }

    pub fn loadModel(self: *Self, name: []const u8, path: []const u8) !*ModelInstance {
        const model = try ModelInstance.initWithConfig(self.context, self.gpu, .{
            .name = name,
            .file_path = path,
            .animator_type = .live_animator,
        });
        try self.model_instances.append(model);
        return model;
    }

    pub fn loadOBJ(self: *Self, filepath: []const u8) !*Shape {
        const shape = try shapes.loadOBJ(self.context.io, self.context.alloc, self.gpu, filepath);
        try self.obj_shapes.append(shape);
        return shape;
    }

    pub fn createCube(self: *Self, config: shapes.CubeConfig) !*Shape {
        const shape = try shapes.createCube(self.context.alloc, self.gpu, config);
        try self.obj_shapes.append(shape);
        return shape;
    }

    pub fn createSphere(self: *Self, radius: f32, poly_count_x: u32, poly_count_y: u32) !*Shape {
        const shape = try shapes.createSphere(self.context.alloc, self.gpu, radius, poly_count_x, poly_count_y);
        try self.obj_shapes.append(shape);
        return shape;
    }

    pub fn createCylinder(self: *Self, radius: f32, height: f32, sides: u32) !*Shape {
        const shape = try shapes.createCylinder(self.context.alloc, self.gpu, radius, height, sides);
        try self.obj_shapes.append(shape);
        return shape;
    }

    /// Releases everything created through this manager. Before the owning arena resets.
    pub fn cleanUp(self: *Self) void {
        for (self.model_instances.items()) |model| {
            model.cleanUp();
        }

        for (self.obj_shapes.items()) |shape| {
            shape.releaseGpuObjects();
        }

        for (self.materials.items()) |material| {
            material.releaseGpuObjects();
        }

        for (self.textures.items()) |tex| {
            tex.releaseGpuObjects();
        }

        for (self.shaders.items()) |shader| {
            shader.releaseGpuObjects();
        }
    }
};
