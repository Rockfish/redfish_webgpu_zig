const std = @import("std");
const math = @import("math");
const shape = @import("shape.zig");

const Context = @import("../context.zig").Context;
const GpuContext = @import("../gpu_context.zig").GpuContext;
const Texture = @import("../texture.zig").Texture;
const TextureConfig = @import("../texture.zig").TextureConfig;
const TextureWrap = @import("../texture.zig").TextureWrap;
const TextureFilter = @import("../texture.zig").TextureFilter;
const Shape = shape.Shape;

pub const PlaneConfig = struct {
    plane_size: f32 = 100.0,
    tile_size: f32 = 1.0,
    diffuse_texture: ?[:0]const u8 = null,
    normal_texture: ?[:0]const u8 = null,
    specular_texture: ?[:0]const u8 = null,
};

/// A tiled XZ plane facing +Y, with optional diffuse / normal / specular textures for
/// the app's shader to bind.
pub const Plane = struct {
    shape: *Shape,
    texture_diffuse: ?*Texture = null,
    texture_normal: ?*Texture = null,
    texture_spec: ?*Texture = null,

    const Self = @This();

    pub fn init(context: Context, gpu: *GpuContext, config: PlaneConfig) !Self {
        const half_size = config.plane_size / 2.0;
        const positions = [_][3]f32{
            .{ -half_size, 0.0, -half_size },
            .{ half_size, 0.0, -half_size },
            .{ half_size, 0.0, half_size },
            .{ -half_size, 0.0, half_size },
        };

        const num_tile_wraps: f32 = config.plane_size / config.tile_size;
        const texcoords = [_][2]f32{
            .{ 0.0, 0.0 },
            .{ num_tile_wraps, 0.0 },
            .{ num_tile_wraps, num_tile_wraps },
            .{ 0.0, num_tile_wraps },
        };

        const up = [3]f32{ 0.0, 1.0, 0.0 };
        const normals = [_][3]f32{ up, up, up, up };

        // Counter-clockwise seen from above
        const indices = [_]u32{ 0, 2, 1, 0, 3, 2 };

        var self: Self = .{
            .shape = try shape.initGpuBuffers(context.alloc, gpu, .plane, &positions, &texcoords, &normals, &.{}, &indices),
        };
        try self.loadTextures(context, gpu, config);
        return self;
    }

    pub fn cleanUp(self: *Self) void {
        self.shape.releaseGpuObjects();
        if (self.texture_diffuse) |texture| {
            texture.releaseGpuObjects();
        }
        if (self.texture_normal) |texture| {
            texture.releaseGpuObjects();
        }
        if (self.texture_spec) |texture| {
            texture.releaseGpuObjects();
        }
    }

    fn loadTextures(self: *Self, context: Context, gpu: *GpuContext, config: PlaneConfig) !void {
        const color_config = TextureConfig{
            .flip_v = false,
            .is_srgb = true,
            .filter = TextureFilter.Linear,
            .wrap = TextureWrap.Repeat,
        };
        var data_config = color_config;
        data_config.is_srgb = false;

        if (config.diffuse_texture) |texture_path| {
            self.texture_diffuse = try Texture.initFromFile(context, gpu, texture_path, color_config);
        }
        if (config.normal_texture) |texture_path| {
            self.texture_normal = try Texture.initFromFile(context, gpu, texture_path, data_config);
        }
        if (config.specular_texture) |texture_path| {
            self.texture_spec = try Texture.initFromFile(context, gpu, texture_path, data_config);
        }
    }
};
