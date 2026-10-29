//! Room 02 (plan 021, phases G and H), left of Room 01 through its door: the hatch room.
//! A locked door on the far left with a keypad, a ladder down through a hole in the floor
//! toward the back center (the robot walks around the hole's front), the deck's power
//! cabinet and lockers on the back wall.
//!
//! As Room 01, the shell (floor around the hole, walls, the locked door, the deck below)
//! is boxes (`shell`, built by `room_kit.zig`), and the equipment (ladder, rim, keypad,
//! cabinet, lockers, signs, pipes) is the model `MODEL_PATH`, built by
//! `the-station/blender/build_room_02.py`; without it, or with the panel's "greybox room",
//! the greybox equipment draws instead. The hole's and the ladder's sizes here are the
//! script's too.
//!
//! 3 x 1 cells at column -3, row 0 of the station (`station.zig`), in its own coordinates
//! as Room 01 (`room_01.zig`); its right wall is Room 01's left wall, with the doorway.
//! Below the hole a shaft through the deck below (solid, as Room 01's); the robot climbs
//! down into it out of sight (the floor in front of the hole hides it).

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const station = @import("station.zig");
const navigation = @import("navigation.zig");
const Ladder = @import("robot.zig").Ladder;
const Hotspot = station.Hotspot;
const Part = room_kit.Part;
const PartBuilder = room_kit.PartBuilder;
const bounds = room_kit.bounds;
const box = room_kit.box;
const cylinderModel = room_kit.cylinderModel;
const grey = room_kit.grey;
const vec3 = math.vec3;

const DEPTH = room_kit.DEPTH;
const WALL = room_kit.WALL;
const DOOR_CENTER_Z = room_kit.DOOR_CENTER_Z;
const DOOR_WIDTH = room_kit.DOOR_WIDTH;
const DOOR_HEIGHT = room_kit.DOOR_HEIGHT;

pub const MODEL_PATH = "the-station/models/room_02/room_02.glb";

const CELLS_WIDE = 3;
const CELLS_HIGH = 1;
const WIDTH = room_kit.insideWidth(CELLS_WIDE);
const HEIGHT = room_kit.insideHeight(CELLS_HIGH);
const INNER_MIN_X = -WIDTH / 2.0;
const INNER_MAX_X = WIDTH / 2.0;

pub const room: station.Room = .{
    .name = "Room 02",
    .column = -3,
    .row = 0,
    .cells_wide = CELLS_WIDE,
    .cells_high = CELLS_HIGH,
    .model_path = MODEL_PATH,
    .shell = shell,
    .walk_areas = &walk_areas,
    .hotspots = &hotspots,
    .addGreybox = addGreybox,
};

/// The hole in the floor, and the shaft below it.
const HOLE_MIN_X = -0.6;
const HOLE_MAX_X = 0.6;
const HOLE_MIN_Z: f32 = -3.85;
const HOLE_MAX_Z: f32 = -2.85;
const SHAFT_DEPTH: f32 = WALL + room_kit.BELOW_DEPTH;
/// The ladder stands against the hole's back edge and reaches above the floor, rungs to
/// its top.
const LADDER_Z = HOLE_MIN_Z + 0.06;
const RAIL_TOP: f32 = 1.2;
const RAIL_GAP: f32 = 0.5;

/// Standing on the top rung over the hole, facing the ladder; it steps on from the floor
/// right of the hole.
pub const ladder: Ladder = .{
    .top = vec3(0.0, -0.05, -3.5),
    .depth = 1.9,
    .exit = vec3(HOLE_MAX_X + 0.35, 0.0, -3.5),
    .facing = room_kit.FACE_BACK_WALL,
};

/// The shell: a locked door in the left wall; the right wall is Room 01's, with the
/// doorway; the hole in the floor and its shaft.
const shell: room_kit.Shell = .{
    .width = WIDTH,
    .height = HEIGHT,
    .left = .{ .doorway = .{ .door = .locked, .is_framed_outside = false } },
    .right = .neighbor,
    .hole = .{ .min_x = HOLE_MIN_X, .max_x = HOLE_MAX_X, .min_z = HOLE_MIN_Z, .max_z = HOLE_MAX_Z },
};

/// The keypad by the locked door, on the wall in front of the door.
const KEYPAD_Z = DOOR_CENTER_Z + DOOR_WIDTH / 2.0 + 0.35;

/// Where the robot stands by the door back to Room 01.
pub const DOOR_STAND_POINT = vec3(INNER_MAX_X - 0.7, 0.0, DOOR_CENTER_Z);

/// The floor the robot can walk on: in front of the hole, and either side of it. The
/// robot's center keeps 0.35 m from the hole and 0.4 m from the walls.
const walk_areas = [_]navigation.Area{
    .{ .min_x = INNER_MIN_X + 0.4, .max_x = INNER_MAX_X - 0.4, .min_z = HOLE_MAX_Z + 0.35, .max_z = -0.4 },
    .{ .min_x = INNER_MIN_X + 0.4, .max_x = HOLE_MIN_X - 0.35, .min_z = -3.5, .max_z = HOLE_MAX_Z + 0.35 },
    .{ .min_x = HOLE_MAX_X + 0.35, .max_x = INNER_MAX_X - 0.4, .min_z = -3.5, .max_z = HOLE_MAX_Z + 0.35 },
};

const hotspots = [_]Hotspot{
    .{
        .kind = .door,
        .name = "Door",
        .bounds = bounds(vec3(INNER_MAX_X - 0.2, 0.0, DOOR_CENTER_Z - DOOR_WIDTH / 2.0), vec3(INNER_MAX_X + 0.05, DOOR_HEIGHT, DOOR_CENTER_Z + DOOR_WIDTH / 2.0)),
        .stand_point = DOOR_STAND_POINT,
        .facing = room_kit.FACE_RIGHT_WALL,
        .action = .look,
    },
    .{
        .kind = .locked_door,
        .name = "Door",
        .bounds = bounds(vec3(INNER_MIN_X - 0.05, 0.0, DOOR_CENTER_Z - DOOR_WIDTH / 2.0), vec3(INNER_MIN_X + 0.2, DOOR_HEIGHT, DOOR_CENTER_Z + DOOR_WIDTH / 2.0)),
        .stand_point = vec3(INNER_MIN_X + 0.5, 0.0, DOOR_CENTER_Z),
        .facing = room_kit.FACE_LEFT_WALL,
        .action = .look,
    },
    // Beside the locked door's front edge; pressed from a step in front of it
    .{
        .kind = .keypad,
        .name = "Keypad",
        .bounds = bounds(vec3(INNER_MIN_X - 0.02, 1.07, KEYPAD_Z - 0.13), vec3(INNER_MIN_X + 0.13, 1.43, KEYPAD_Z + 0.13)),
        .stand_point = vec3(INNER_MIN_X + 0.6, 0.0, KEYPAD_Z),
        .facing = room_kit.FACE_LEFT_WALL,
        .action = .push_high,
        .mesh = "keypad",
    },
    // The deck's power cabinet right of the hole (build_room_02.py), 0.25 m deep
    .{
        .kind = .power_cabinet,
        .name = "Power cabinet",
        .bounds = bounds(vec3(1.3, 0.6, -DEPTH), vec3(2.9, 2.0, -3.65)),
        .stand_point = vec3(2.1, 0.0, -3.4),
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
    // The ladder above the floor, and its lower part: the hole it goes down
    .{
        .kind = .ladder,
        .name = "Ladder",
        .bounds = bounds(vec3(-0.32, 0.3, LADDER_Z - 0.06), vec3(0.32, RAIL_TOP + 0.05, LADDER_Z + 0.1)),
        .stand_point = ladder.exit,
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .ladder_hole,
        .name = "Ladder",
        .bounds = bounds(vec3(HOLE_MIN_X, -0.6, HOLE_MIN_Z), vec3(HOLE_MAX_X, 0.3, HOLE_MAX_Z)),
        .stand_point = ladder.exit,
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
};

/// The equipment as boxes, drawn without the model: the ladder, the keypad, and stand-ins
/// for the lockers and the power cabinet.
fn addGreybox(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) std.mem.Allocator.Error!void {
    try addLadder(builder, allocator, parts);
    try addKeypad(builder, allocator, parts);
    try addBackWall(builder, allocator, parts);
}

/// Two rails from the shaft's bottom to above the floor, rungs every 0.3 m from the top
/// down. The robot stands on the one just below the floor (`ladder.top`).
fn addLadder(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const color = grey(0.4);
    for ([_]f32{ -RAIL_GAP / 2.0, RAIL_GAP / 2.0 }) |offset| {
        try parts.append(allocator, .{ .shape = builder.cylinder, .model = cylinderModel(vec3(offset, -SHAFT_DEPTH, LADDER_Z), .y, 0.05, SHAFT_DEPTH + RAIL_TOP), .color = color });
    }
    var y: f32 = RAIL_TOP - 0.1;
    while (y > -SHAFT_DEPTH) : (y -= 0.3) {
        try parts.append(allocator, .{ .shape = builder.cylinder, .model = cylinderModel(vec3(-RAIL_GAP / 2.0, y, LADDER_Z), .x, 0.035, RAIL_GAP), .color = color });
    }
}

/// The keypad beside the locked door, dead.
fn addKeypad(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const inner_x = INNER_MIN_X;
    try parts.appendSlice(allocator, &.{
        .{ .shape = builder.cube, .model = box(vec3(inner_x + 0.04, 1.25, KEYPAD_Z), vec3(0.08, 0.26, 0.18)), .color = grey(0.25) },
        .{ .shape = builder.cylinder, .model = cylinderModel(vec3(inner_x + 0.08, 1.33, KEYPAD_Z), .x, 0.04, 0.02), .color = grey(0.15) },
    });
}

/// Flat stand-ins for the lockers (left of the hole) and the power cabinet (right).
fn addBackWall(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const wall_z = -DEPTH;
    const cube = builder.cube;
    try parts.appendSlice(allocator, &.{
        .{ .shape = cube, .model = box(vec3(-3.0, 0.98, wall_z + 0.12), vec3(1.4, 1.95, 0.24)), .color = grey(0.48) },
        .{ .shape = cube, .model = box(vec3(2.1, 1.05, wall_z + 0.12), vec3(1.6, 1.9, 0.24)), .color = grey(0.48) },
    });
}
