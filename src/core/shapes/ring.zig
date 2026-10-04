//! A flat ring (an annulus) on the x,z plane, facing up: a floor marker, e.g. where a
//! shell will land. Scaled uniformly in x and z, its width grows with its radius.

const std = @import("std");
const math = @import("math");
const shape = @import("shape.zig");
const GpuContext = @import("../gpu_context.zig").GpuContext;

const Allocator = std.mem.Allocator;

pub const Ring = struct {
    /// `inner_radius` and `outer_radius` are radii (not diameters), `sides` the segments
    /// around.
    pub fn init(allocator: Allocator, gpu: *const GpuContext, inner_radius: f32, outer_radius: f32, sides: u32) !*shape.Shape {
        var builder = shape.ShapeBuilder.init(allocator, .ring);
        defer builder.deinit();

        const up = [3]f32{ 0.0, 1.0, 0.0 };
        const texcoord_scale = 0.5 / outer_radius;
        for (0..sides + 1) |i| {
            const angle: f32 = math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sides));
            const cos = @cos(angle);
            const sin = @sin(angle);
            for ([_]f32{ inner_radius, outer_radius }) |radius| {
                const x = radius * cos;
                const z = radius * sin;
                _ = try builder.addVertex(.{ x, 0.0, z }, up, .{ 0.5 + x * texcoord_scale, 0.5 + z * texcoord_scale });
            }
        }

        // Each side is a quad: inner and outer at this angle and the next. The angle runs
        // +x toward +z, clockwise seen from above, so each triangle lists the next angle
        // first to wind counter-clockwise from above.
        for (0..sides) |side| {
            const inner: u32 = @intCast(side * 2);
            const outer = inner + 1;
            const next_inner = inner + 2;
            const next_outer = inner + 3;
            for ([_]u32{ inner, next_inner, outer, outer, next_inner, next_outer }) |index| {
                try builder.addIndex(index);
            }
        }

        return builder.build(gpu);
    }
};
