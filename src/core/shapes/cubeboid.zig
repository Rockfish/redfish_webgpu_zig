const std = @import("std");
const math = @import("math");

const shape = @import("shape.zig");
const GpuContext = @import("../gpu_context.zig").GpuContext;

const Allocator = std.mem.Allocator;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

pub const TextureMapping = enum {
    Repeating, // Default method - same texture repeated on all faces
    Cubemap3x2, // Six-panel texture layout 3 by 2 grid
    Cubemap2x3, // Six-panel texture layout 2 by 3 grid
};

pub const CubeConfig = struct {
    width: f32 = 1.0,
    height: f32 = 1.0,
    depth: f32 = 1.0,
    num_tiles_x: f32 = 1.0,
    num_tiles_y: f32 = 1.0,
    num_tiles_z: f32 = 1.0,
    texture_mapping: TextureMapping = .Repeating,
};

pub const Cubeboid = struct {
    pub fn init(allocator: Allocator, gpu: *const GpuContext, config: CubeConfig) !*shape.Shape {
        const max = vec3(config.width / 2.0, config.height / 2.0, config.depth / 2.0);
        const min = max.mulScalar(-1.0);

        const wraps_x: f32 = config.num_tiles_x;
        const wraps_y: f32 = config.num_tiles_y;
        const wraps_z: f32 = config.num_tiles_z;

        const positions = [_][3]f32{
            // Front
            .{ min.x, min.y, max.z },
            .{ max.x, min.y, max.z },
            .{ max.x, max.y, max.z },
            .{ min.x, max.y, max.z },
            // Back,
            .{ min.x, max.y, min.z },
            .{ max.x, max.y, min.z },
            .{ max.x, min.y, min.z },
            .{ min.x, min.y, min.z },
            // Right,
            .{ max.x, min.y, min.z },
            .{ max.x, max.y, min.z },
            .{ max.x, max.y, max.z },
            .{ max.x, min.y, max.z },
            // Left,
            .{ min.x, min.y, max.z },
            .{ min.x, max.y, max.z },
            .{ min.x, max.y, min.z },
            .{ min.x, min.y, min.z },
            // Top,
            .{ max.x, max.y, min.z },
            .{ min.x, max.y, min.z },
            .{ min.x, max.y, max.z },
            .{ max.x, max.y, max.z },
            // Bottom,
            .{ max.x, min.y, max.z },
            .{ min.x, min.y, max.z },
            .{ min.x, min.y, min.z },
            .{ max.x, min.y, min.z },
        };

        const texcoords = switch (config.texture_mapping) {
            .Repeating => [_][2]f32{
                // Front
                .{ 0.0, 0.0 },
                .{ wraps_x, 0.0 },
                .{ wraps_x, wraps_y },
                .{ 0.0, wraps_y },
                // Back
                .{ wraps_x, 0.0 },
                .{ 0.0, 0.0 },
                .{ 0.0, wraps_y },
                .{ wraps_x, wraps_y },
                // Right
                .{ 0.0, 0.0 },
                .{ wraps_y, 0.0 },
                .{ wraps_y, wraps_z },
                .{ 0.0, wraps_z },
                // Left
                .{ wraps_y, 0.0 },
                .{ 0.0, 0.0 },
                .{ 0.0, wraps_z },
                .{ wraps_y, wraps_z },
                // Top
                .{ wraps_x, 0.0 },
                .{ 0.0, 0.0 },
                .{ 0.0, wraps_z },
                .{ wraps_x, wraps_z },
                // Bottom
                .{ 0.0, 0.0 },
                .{ wraps_x, 0.0 },
                .{ wraps_x, wraps_z },
                .{ 0.0, wraps_z },
            },
            .Cubemap3x2 => blk: {
                // Godot cubemap layout: 3x2 grid
                // Top row:    [X+ Right] [X- Left] [Y+ Top]
                // Bottom row: [Y- Bottom] [Z+ Front] [Z- Back]
                const face_w = 1.0 / 3.0; // Each face is 1/3 of texture width
                const face_h = 1.0 / 2.0; // Each face is 1/2 of texture height

                break :blk [_][2]f32{
                    // Front (Z+)
                    .{ face_w, 1.0 },
                    .{ face_w * 2.0, 1.0 },
                    .{ face_w * 2.0, face_h },
                    .{ face_w, face_h },
                    // Back (Z-)
                    .{ 1.0, face_h },
                    .{ face_w * 2.0, face_h },
                    .{ face_w * 2.0, 1.0 },
                    .{ 1.0, 1.0 },
                    // Right (X+)
                    .{ face_w, face_h },
                    .{ face_w, 0.0 },
                    .{ 0.0, 0.0 },
                    .{ 0.0, face_h },
                    // Left (X-)
                    .{ face_w * 2.0, face_h },
                    .{ face_w * 2.0, 0.0 },
                    .{ face_w, 0.0 },
                    .{ face_w, face_h },
                    // Top (Y+)
                    .{ 1.0, 0.0 },
                    .{ face_w * 2.0, 0.0 },
                    .{ face_w * 2.0, face_h },
                    .{ 1.0, face_h },
                    // Bottom (Y-)
                    .{ face_w, face_h },
                    .{ 0.0, face_h },
                    .{ 0.0, 1.0 },
                    .{ face_w, 1.0 },
                };
            },
            .Cubemap2x3 => blk: {
                // 2x3 cubemap layout:
                // Top row:    [X+] [X-]
                // Middle row: [Y+] [Y-]
                // Bottom row: [Z+] [Z-]
                const face_w = 1.0 / 2.0; // Each face is 1/2 of texture width
                const face_h = 1.0 / 3.0; // Each face is 1/3 of texture height

                break :blk [_][2]f32{
                    // Front (Z+, bottom-left: x=0 to 0.5, y=2/3 to 1) - flipped vertically
                    .{ 0.0, 1.0 },
                    .{ face_w, 1.0 },
                    .{ face_w, face_h * 2.0 },
                    .{ 0.0, face_h * 2.0 },
                    // Back (Z-, bottom-right: x=0.5 to 1, y=2/3 to 1) - flipped horizontally
                    .{ 1.0, face_h * 2.0 },
                    .{ face_w, face_h * 2.0 },
                    .{ face_w, 1.0 },
                    .{ 1.0, 1.0 },
                    // Right (X+, top-left: x=0 to 0.5, y=0 to 1/3) - rotated 90° clockwise
                    .{ 0.0, face_h },
                    .{ 0.0, 0.0 },
                    .{ face_w, 0.0 },
                    .{ face_w, face_h },
                    // Left (X-, top-right: x=0.5 to 1, y=0 to 1/3) - rotated 90° clockwise
                    .{ face_w, face_h },
                    .{ face_w, 0.0 },
                    .{ 1.0, 0.0 },
                    .{ 1.0, face_h },
                    // Top (Y+ middle-left: x=0 to 0.5, y=1/3 to 2/3)
                    .{ face_w, face_h },
                    .{ 0.0, face_h },
                    .{ 0.0, face_h * 2.0 },
                    .{ face_w, face_h * 2.0 },
                    // Bottom (Y- middle-right: x=0.5 to 1, y=1/3 to 2/3)
                    .{ 1.0, face_h },
                    .{ face_w, face_h },
                    .{ face_w, face_h * 2.0 },
                    .{ 1.0, face_h * 2.0 },
                };
            },
        };

        const normals = [_][3]f32{
            // Front
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            .{ 0.0, 0.0, 1.0 },
            // Back
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, -1.0 },
            // Right
            .{ 1.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            // Left,
            .{ -1.0, 0.0, 0.0 },
            .{ -1.0, 0.0, 0.0 },
            .{ -1.0, 0.0, 0.0 },
            .{ -1.0, 0.0, 0.0 },
            // Top,
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            // Bottom,
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
            .{ 0.0, -1.0, 0.0 },
        };

        const indices = [_]u32{
            0, 1, 2, 2, 3, 0, // front
            4, 5, 6, 6, 7, 4, // back
            8, 9, 10, 10, 11, 8, // right
            12, 13, 14, 14, 15, 12, // left
            16, 17, 18, 18, 19, 16, // top
            20, 21, 22, 22, 23, 20, // bottom
        };

        return shape.initGpuBuffers(
            allocator,
            gpu,
            .cube,
            &positions,
            &texcoords,
            &normals,
            &.{},
            &indices,
        );
    }
};
