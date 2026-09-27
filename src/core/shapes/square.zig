const std = @import("std");
const shape = @import("shape.zig");
const GpuContext = @import("../gpu_context.zig").GpuContext;

const Allocator = std.mem.Allocator;

pub const Square = struct {
    pub fn init(allocator: Allocator, gpu: *const GpuContext) !*shape.Shape {
        const positions = [_][3]f32{
            .{ -0.5, -0.5, 0.0 }, // 1
            .{ 0.5, -0.5, 0.0 }, // 2
            .{ 0.5, 0.5, 0.0 }, // 3
            .{ -0.5, 0.5, 0.0 }, // 4
        };

        const texcoords = [_][2]f32{
            .{ 0.0, 0.0 },
            .{ 1.0, 0.0 },
            .{ 1.0, 1.0 },
            .{ 0.0, 1.0 },
        };

        const normals = [_][3]f32{};

        // Counter-clockwise seen from +z, the side the default normal faces
        const indices = [_]u32{ 0, 1, 2, 2, 3, 0 };

        return shape.initGpuBuffers(
            allocator,
            gpu,
            .square,
            &positions,
            &texcoords,
            &normals,
            &.{},
            &indices,
        );
    }
};
