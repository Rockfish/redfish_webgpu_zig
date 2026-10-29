//! The shaft from Room 02 down to Room 04 (plan 022, phase E3): the same hole in Room 02's
//! and Room 03's floors (Room 03's and Room 04's ceilings), and the ladder through it.
//! The rooms are in one column of cells, so it is at the same place in each room's own
//! coordinates.
//!
//! Each room draws the ladder and the pipe beside it inside its own space: from the
//! bottom of its floor (from its floor without a hole) up to its ceiling; Room 02's on up
//! above the floor (its model, `build_room_02.py`, or the greybox). The ladder's stops:
//! on the rung at Room 02's and Room 03's floors, over the hole, and at its foot in Room
//! 04.

const std = @import("std");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const LadderStop = @import("robot.zig").LadderStop;
const Part = room_kit.Part;
const PartBuilder = room_kit.PartBuilder;
const cylinderModel = room_kit.cylinderModel;
const grey = room_kit.grey;
const vec3 = math.vec3;

/// The hole in the floor, at the back center (the sizes are `build_room_02.py`'s too).
pub const HOLE: room_kit.Hole = .{ .min_x = -0.6, .max_x = 0.6, .min_z = -3.85, .max_z = -2.85 };
/// The ladder stands against the hole's back edge; in Room 02 it reaches above the floor.
pub const LADDER_Z = HOLE.min_z + 0.06;
pub const RAIL_TOP: f32 = 1.2;
const RAIL_GAP: f32 = 0.5;
const RUNG_SPACING: f32 = 0.3;

/// The floor right of the hole, where the robot steps on and off.
pub const LADDER_EXIT = vec3(HOLE.max_x + 0.35, 0.0, -3.5);
/// Standing on the rung just below the floor, over the hole.
pub const RUNG_STOP: LadderStop = .{ .position = vec3(0.0, -0.05, -3.5), .exit = LADDER_EXIT };
/// Standing at the ladder's foot, on the floor.
pub const FOOT_STOP: LadderStop = .{ .position = vec3(0.0, 0.0, -3.5), .exit = LADDER_EXIT };
/// Facing the ladder, on it.
pub const LADDER_FACING = room_kit.FACE_BACK_WALL;

/// The walk areas of a room with the hole: in front of it, and either side of it. The
/// robot's center keeps 0.35 m from the hole and 0.4 m from the walls of a room `width`
/// wide.
pub fn walkAreasAroundHole(comptime width: f32) [3]@import("navigation.zig").Area {
    const min_x = -width / 2.0 + 0.4;
    const max_x = width / 2.0 - 0.4;
    return .{
        .{ .min_x = min_x, .max_x = max_x, .min_z = HOLE.max_z + 0.35, .max_z = -0.4 },
        .{ .min_x = min_x, .max_x = HOLE.min_x - 0.35, .min_z = -3.5, .max_z = HOLE.max_z + 0.35 },
        .{ .min_x = HOLE.max_x + 0.35, .max_x = max_x, .min_z = -3.5, .max_z = HOLE.max_z + 0.35 },
    };
}

/// The ladder from `bottom` to `top`: two rails, and rungs every 0.3 m from the top down.
pub fn addLadder(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part), bottom: f32, top: f32) !void {
    const color = grey(0.4);
    for ([_]f32{ -RAIL_GAP / 2.0, RAIL_GAP / 2.0 }) |offset| {
        try parts.append(allocator, .{ .shape = builder.cylinder, .model = cylinderModel(vec3(offset, bottom, LADDER_Z), .y, 0.05, top - bottom), .color = color });
    }
    var y: f32 = top - 0.1;
    while (y > bottom) : (y -= RUNG_SPACING) {
        try parts.append(allocator, .{ .shape = builder.cylinder, .model = cylinderModel(vec3(-RAIL_GAP / 2.0, y, LADDER_Z), .x, 0.035, RAIL_GAP), .color = color });
    }
}

/// The pipe down the shaft beside the ladder, from Room 02's back wall
/// (`build_room_02.py`), from `bottom` to `top`.
pub fn addPipe(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part), bottom: f32, top: f32) !void {
    const base = vec3(HOLE.max_x - 0.12, bottom, -room_kit.DEPTH + 0.24);
    try parts.append(allocator, .{ .shape = builder.cylinder, .model = cylinderModel(base, .y, 0.12, top - bottom), .color = grey(0.4) });
}
