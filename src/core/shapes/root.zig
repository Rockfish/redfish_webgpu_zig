const std = @import("std");
const GpuContext = @import("../gpu_context.zig").GpuContext;

pub const cubeboid = @import("cubeboid.zig");
pub const Cylinder = @import("cylinder.zig").Cylinder;
pub const Sphere = @import("sphere.zig").Sphere;
pub const Square = @import("square.zig").Square;
pub const Plane = @import("plane.zig").Plane;
pub const Skybox = @import("skybox.zig").Skybox;
pub const SkyboxFaces = @import("skybox.zig").SkyboxFaces;
pub const Lines = @import("lines.zig").Lines;
pub const LineSegment = @import("lines.zig").LineSegment;
pub const PlaneConfig = @import("plane.zig").PlaneConfig;

pub const Shape = @import("shape.zig").Shape;
pub const ShapeBuilder = @import("shape.zig").ShapeBuilder;
pub const InstanceAttribute = @import("shape.zig").InstanceAttribute;
pub const InstancedLayouts = @import("shape.zig").InstancedLayouts;
pub const obj_loader = @import("obj_loader.zig");

pub fn loadOBJ(io: std.Io, allocator: std.mem.Allocator, gpu: *const GpuContext, filepath: []const u8) !*Shape {
    return obj_loader.loadOBJ(io, allocator, gpu, filepath);
}

pub fn createSquare(allocator: std.mem.Allocator, gpu: *const GpuContext) !*Shape {
    return try Square.init(allocator, gpu);
}

pub const CubeConfig = cubeboid.CubeConfig;
pub fn createCube(allocator: std.mem.Allocator, gpu: *const GpuContext, config: cubeboid.CubeConfig) !*Shape {
    return try cubeboid.Cubeboid.init(allocator, gpu, config);
}

pub fn createCylinder(allocator: std.mem.Allocator, gpu: *const GpuContext, radius: f32, height: f32, sides: u32) !*Shape {
    return try Cylinder.init(allocator, gpu, radius, height, sides);
}

pub fn createSphere(allocator: std.mem.Allocator, gpu: *const GpuContext, radius: f32, poly_countX: u32, poly_countY: u32) !*Shape {
    return try Sphere.init(allocator, gpu, radius, poly_countX, poly_countY);
}
