//! Room 04 (plan 022, phase E3), at the bottom of the shaft, two floors below Room 02:
//! the ladder comes down through its ceiling to its floor (`shaft.zig`). The generator
//! room is through the open doorway in its right wall, the generator room's wall. What
//! the room is stays open; greybox, with a stand-in on the back wall.
//!
//! 3 x 1 cells at column -3, row -2 of the station (`station.zig`), in its own coordinates
//! as Room 01 (`room_01.zig`). Its ceiling, with the hole, is Room 03's floor.

const std = @import("std");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const station = @import("station.zig");
const navigation = @import("navigation.zig");
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
    .name = "Room 04",
    .column = -3,
    .row = -2,
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
};

/// Where the robot stands by the doorway to the generator room.
pub const DOOR_STAND_POINT = vec3(WIDTH / 2.0 - 0.7, 0.0, room_kit.DOOR_CENTER_Z);

/// The ladder's stop on this floor: at its foot.
pub const ladder_stop = shaft.FOOT_STOP;

/// The whole floor, 0.4 m clear of the walls; the robot stands at the ladder's foot at
/// its back edge.
const walk_areas = [_]navigation.Area{
    .{ .min_x = -WIDTH / 2.0 + 0.4, .max_x = WIDTH / 2.0 - 0.4, .min_z = -3.5, .max_z = -0.4 },
};

/// The ladder, up to Room 03, and the doorway to the generator room.
const hotspots = [_]Hotspot{
    .{
        .kind = .{ .doorway = .room_04_generator },
        .name = "Doorway",
        .bounds = bounds(
            vec3(WIDTH / 2.0 - 0.2, 0.0, room_kit.DOOR_CENTER_Z - room_kit.DOOR_WIDTH / 2.0),
            vec3(WIDTH / 2.0 + 0.05, room_kit.DOOR_HEIGHT, room_kit.DOOR_CENTER_Z + room_kit.DOOR_WIDTH / 2.0),
        ),
        .stand_point = DOOR_STAND_POINT,
        .facing = room_kit.FACE_RIGHT_WALL,
        .action = .look,
    },
    .{
        .kind = .ladder,
        .name = "Ladder",
        .bounds = bounds(vec3(-0.32, 0.0, shaft.LADDER_Z - 0.06), vec3(0.32, HEIGHT, shaft.LADDER_Z + 0.1)),
        .stand_point = shaft.LADDER_EXIT,
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
};

/// The ladder and the pipe from the floor to the ceiling, and a stand-in on the back wall.
fn addGreybox(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) std.mem.Allocator.Error!void {
    try shaft.addLadder(builder, allocator, parts, 0.0, HEIGHT);
    try shaft.addPipe(builder, allocator, parts, 0.0, HEIGHT);
    try parts.append(allocator, .{ .shape = builder.cube, .model = box(vec3(-2.4, 1.0, -room_kit.DEPTH + 0.3), vec3(2.2, 2.0, 0.6)), .color = grey(0.45) });
}
