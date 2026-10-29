//! Room 03 (plan 022, phase E3), below Room 02 on the way down: the shaft passes through
//! it, the ladder coming down through its ceiling and on through its floor to Room 04
//! (`shaft.zig`). What the room is stays open; greybox, with stand-ins on the back wall.
//!
//! 3 x 1 cells at column -3, row -1 of the station (`station.zig`), in its own coordinates
//! as Room 01 (`room_01.zig`). Its ceiling, with the hole, is Room 02's floor; its floor
//! is Room 04's ceiling. Its right wall is the deck below Room 01 until the generator
//! room (phase E4).

const std = @import("std");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const station = @import("station.zig");
const shaft = @import("shaft.zig");
const Hotspot = station.Hotspot;
const Part = room_kit.Part;
const PartBuilder = room_kit.PartBuilder;
const bounds = room_kit.bounds;
const box = room_kit.box;
const grey = room_kit.grey;
const vec3 = math.vec3;

const CELLS_WIDE = 3;
const CELLS_HIGH = 1;
const WIDTH = room_kit.insideWidth(CELLS_WIDE);
const HEIGHT = room_kit.insideHeight(CELLS_HIGH);

pub const room: station.Room = .{
    .name = "Room 03",
    .column = -3,
    .row = -1,
    .cells_wide = CELLS_WIDE,
    .cells_high = CELLS_HIGH,
    .model_path = null,
    .shell = shell,
    .walk_areas = &walk_areas,
    .hotspots = &hotspots,
    .addGreybox = addGreybox,
};

const shell: room_kit.Shell = .{
    .width = WIDTH,
    .height = HEIGHT,
    .left = .solid,
    .right = .neighbor,
    .floor = .room_below,
    .ceiling_hole = shaft.HOLE,
};

/// The ladder's stop on this floor.
pub const ladder_stop = shaft.RUNG_STOP;

const walk_areas = shaft.walkAreasAroundHole(WIDTH);

/// The ladder above the floor (up to Room 02), and its lower part, the hole (down to
/// Room 04).
const hotspots = [_]Hotspot{
    .{
        .kind = .ladder,
        .name = "Ladder",
        .bounds = bounds(vec3(-0.32, 0.3, shaft.LADDER_Z - 0.06), vec3(0.32, HEIGHT, shaft.LADDER_Z + 0.1)),
        .stand_point = shaft.LADDER_EXIT,
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .ladder_hole,
        .name = "Ladder",
        .bounds = bounds(vec3(shaft.HOLE.min_x, -0.6, shaft.HOLE.min_z), vec3(shaft.HOLE.max_x, 0.3, shaft.HOLE.max_z)),
        .stand_point = shaft.LADDER_EXIT,
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
};

/// The ladder and the pipe from the bottom of the floor to the ceiling, and stand-ins on
/// the back wall either side of the shaft.
fn addGreybox(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) std.mem.Allocator.Error!void {
    try shaft.addLadder(builder, allocator, parts, -room_kit.WALL, HEIGHT);
    try shaft.addPipe(builder, allocator, parts, -room_kit.WALL, HEIGHT);
    const wall_z = -room_kit.DEPTH;
    try parts.appendSlice(allocator, &.{
        .{ .shape = builder.cube, .model = box(vec3(-2.6, 0.9, wall_z + 0.25), vec3(2.0, 1.8, 0.5)), .color = grey(0.45) },
        .{ .shape = builder.cube, .model = box(vec3(2.6, 0.6, wall_z + 0.3), vec3(1.6, 1.2, 0.6)), .color = grey(0.5) },
    });
}
