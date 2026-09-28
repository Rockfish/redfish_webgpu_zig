const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const GpuContext = core.GpuContext;
const Shape = core.shapes.Shape;

/// -1..1 in x and y, texcoords 0..1 with (0, 0) at (-1, -1), as redfish. For sprites and
/// burn marks, whose file textures sample the same in GL and WebGPU.
const UNIT_SQUARE_POSITIONS = [_][3]f32{
    .{ -1.0, -1.0, 0.0 }, .{ 1.0, -1.0, 0.0 }, .{ 1.0, 1.0, 0.0 },
    .{ -1.0, -1.0, 0.0 }, .{ 1.0, 1.0, 0.0 },  .{ -1.0, 1.0, 0.0 },
};
const UNIT_SQUARE_TEXCOORDS = [_][2]f32{
    .{ 0.0, 0.0 }, .{ 1.0, 0.0 }, .{ 1.0, 1.0 },
    .{ 0.0, 0.0 }, .{ 1.0, 1.0 }, .{ 0.0, 1.0 },
};

/// The whole viewport in clip space, for the blur and composite passes (redfish's
/// `MORE_OBNOXIOUS_QUAD`). Texcoords put (0, 0) at the top left, where WebGPU's render
/// targets have their first row; redfish's GL quad had it at the bottom left. z is 0:
/// WebGPU clips outside 0..1, which redfish's z = -0.9 would be.
const FULLSCREEN_POSITIONS = [_][3]f32{
    .{ -1.0, -1.0, 0.0 }, .{ 1.0, -1.0, 0.0 }, .{ 1.0, 1.0, 0.0 },
    .{ -1.0, -1.0, 0.0 }, .{ 1.0, 1.0, 0.0 },  .{ -1.0, 1.0, 0.0 },
};
const FULLSCREEN_TEXCOORDS = [_][2]f32{
    .{ 0.0, 1.0 }, .{ 1.0, 1.0 }, .{ 1.0, 0.0 },
    .{ 0.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 0.0 },
};

const QUAD_INDICES = [_]u32{ 0, 1, 2, 3, 4, 5 };

/// Alpha blended, both sides, no depth writes: what redfish set around every draw of it
/// (muzzle flash, bullet impacts, burn marks).
pub fn createUnitSquare(allocator: Allocator, gpu: *const GpuContext) !*Shape {
    const shape = try core.shapes.initGpuBuffers(allocator, gpu, .custom, &UNIT_SQUARE_POSITIONS, &UNIT_SQUARE_TEXCOORDS, &.{}, &.{}, &QUAD_INDICES);
    shape.is_transparent = true;
    shape.is_double_sided = true;
    shape.is_depth_write = false;
    return shape;
}

pub fn createFullscreenQuad(allocator: Allocator, gpu: *const GpuContext) !*Shape {
    const shape = try core.shapes.initGpuBuffers(allocator, gpu, .custom, &FULLSCREEN_POSITIONS, &FULLSCREEN_TEXCOORDS, &.{}, &.{}, &QUAD_INDICES);
    shape.is_double_sided = true;
    return shape;
}
