const std = @import("std");
const GpuContext = @import("../gpu_context.zig").GpuContext;

pub const cubeboid = @import("cubeboid.zig");

pub const Shape = @import("shape.zig").Shape;
pub const ShapeBuilder = @import("shape.zig").ShapeBuilder;

pub const CubeConfig = cubeboid.CubeConfig;
pub fn createCube(allocator: std.mem.Allocator, gpu: *const GpuContext, config: cubeboid.CubeConfig) !*Shape {
    return try cubeboid.Cubeboid.init(allocator, gpu, config);
}
