const std = @import("std");
const math = @import("math");
const shape = @import("shape.zig");
const GpuContext = @import("../gpu_context.zig").GpuContext;

const Vec2 = math.Vec2;
const vec2 = math.vec2;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

const Allocator = std.mem.Allocator;

/// A closed cylinder standing on the x,z plane: its base centered on the origin, `radius`
/// wide, `height` up +Y.
pub const Cylinder = struct {
    pub fn init(allocator: Allocator, gpu: *const GpuContext, radius: f32, height: f32, sides: u32) !*shape.Shape {
        var builder = shape.ShapeBuilder.init(allocator, .cylinder);
        defer builder.deinit();

        // Top of cylinder
        try addDiskMesh(
            &builder,
            vec3(0.0, height, 0.0),
            radius,
            sides,
            .up,
        );

        // Bottom of cylinder
        try addDiskMesh(
            &builder,
            vec3(0.0, 0.0, 0.0),
            radius,
            sides,
            .down,
        );

        // Tube - cylinder wall
        try addTubeMesh(
            &builder,
            vec3(0.0, 0.0, 0.0),
            height,
            radius,
            sides,
        );

        return builder.build(gpu);
    }

    const Facing = enum { up, down };

    fn addDiskMesh(builder: *shape.ShapeBuilder, position: Vec3, radius: f32, sides: u32, facing: Facing) !void {
        const intial_count: u32 = @intCast(builder.positions.list.items.len);
        const normal: [3]f32 = if (facing == .up) .{ 0.0, 1.0, 0.0 } else .{ 0.0, -1.0, 0.0 };

        // Start with adding the center vertex in the center of the disk.
        try builder.positions.append(.{ position.x, position.y, position.z });
        try builder.normals.append(normal);
        try builder.texcoords.append(.{ 0.5, 0.5 });

        // Add vertices on the edge of the face. The disk is on the x,z plane. Y is up.
        for (0..sides) |i| {
            const angle: f32 = math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sides));
            const sin = math.sin(angle);
            const cos = math.cos(angle);
            // uv's are in percentages of the texture
            const u = 0.5 + 0.5 * cos;
            const v = 0.5 + 0.5 * sin;
            try builder.positions.append(.{ position.x + radius * cos, position.y, position.z + radius * sin });
            try builder.normals.append(normal);
            try builder.texcoords.append(.{ u, v });
        }

        // Fan of triangles from the center. Edge vertices run +x toward +z, which is
        // clockwise seen from above, so the order flips for the upward-facing disk.
        const num_vertices: u32 = @as(u32, @intCast(builder.positions.list.items.len));

        for ((intial_count + 1)..num_vertices - 1) |i| {
            try addTriangle(builder, facing, intial_count, @intCast(i), @intCast(i + 1));
        }
        try addTriangle(builder, facing, intial_count, num_vertices - 1, intial_count + 1);
    }

    /// `a, b, c` wound for a downward-facing disk; reversed for `.up`.
    fn addTriangle(builder: *shape.ShapeBuilder, facing: Facing, a: u32, b: u32, c: u32) !void {
        try builder.indices.append(a);
        if (facing == .up) {
            try builder.indices.append(c);
            try builder.indices.append(b);
        } else {
            try builder.indices.append(b);
            try builder.indices.append(c);
        }
    }

    pub fn addTubeMesh(builder: *shape.ShapeBuilder, position: Vec3, height: f32, radius: f32, sides: u32) !void {
        const intial_count: u32 = @intCast(builder.positions.list.items.len);
        //        const initial_indice_count: u32 = @intCast(builder.indices.items.len);

        // Set uv's to wrap texture around the tube
        for (0..sides + 1) |i| {
            const angle: f32 = @as(f32, @floatFromInt(i)) * math.tau / @as(f32, @floatFromInt(sides));
            const sin = math.sin(angle);
            const cos = math.cos(angle);
            // uv's are percentages of the texture size
            const u: f32 = 1.0 - 1.0 / @as(f32, @floatFromInt(sides)) * @as(f32, @floatFromInt(i));
            try builder.positions.append(.{ position.x + radius * cos, position.y, position.z + radius * sin });
            try builder.normals.append(.{ cos, 0.0, sin });
            try builder.texcoords.append(.{ u, 1.0 });
        }

        // Bottom ring of vertices
        for (0..sides + 1) |i| {
            const angle: f32 = @as(f32, @floatFromInt(i)) * math.tau / @as(f32, @floatFromInt(sides));
            const sin = math.sin(angle);
            const cos = math.cos(angle);
            // uv's are percentages of the texture size
            const u: f32 = 1.0 - 1.0 / @as(f32, @floatFromInt(sides)) * @as(f32, @floatFromInt(i));
            try builder.positions.append(.{ position.x + radius * cos, position.y + height, position.z + radius * sin });
            try builder.normals.append(.{ cos, 0.0, sin });
            try builder.texcoords.append(.{ u, 0.0 });
        }

        // Each side is a quad which is two triangles, counter-clockwise seen from outside
        for (intial_count..(intial_count + sides)) |c| {
            const i: u32 = @intCast(c);

            try builder.indices.append(i + sides + 1);
            try builder.indices.append(i + 1);
            try builder.indices.append(i);

            try builder.indices.append(i + 1);
            try builder.indices.append(i + sides + 1);
            try builder.indices.append(i + sides + 2);
        }
    }
};
