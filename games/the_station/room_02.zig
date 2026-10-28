//! Room 02 (plan 021, phases G and H), left of Room 01 through its door: the hatch room.
//! A locked door on the far left with a keypad, a ladder down through a hole in the floor
//! toward the back center (the robot walks around the hole's front), the deck's power
//! cabinet and lockers on the back wall.
//!
//! As Room 01, the shell (floor around the hole, walls, the locked door, the deck below)
//! is boxes drawn here, and the equipment (ladder, rim, keypad, cabinet, lockers, signs,
//! pipes) is the model `MODEL_PATH`, built by `the-station/blender/build_room_02.py`;
//! without it, or with the panel's "greybox room", the greybox equipment draws instead.
//! The hole's and the ladder's sizes here are the script's too.
//!
//! Same size and layout as Room 01 (`room_01.zig`), centered on `CENTER_X`; its right wall is
//! Room 01's left wall, with the doorway. Below the hole a shaft through the deck below
//! (solid, as Room 01's); the robot climbs down into it out of sight (the floor in front
//! of the hole hides it).

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room_01 = @import("room_01.zig");
const navigation = @import("navigation.zig");
const Hotspot = @import("interaction.zig").Hotspot;
const Ladder = @import("robot.zig").Ladder;
const HotspotKind = room_01.HotspotKind;
const Part = room_01.Part;
const PartBuilder = room_01.PartBuilder;
const bounds = room_01.bounds;
const box = room_01.box;
const cylinderModel = room_01.cylinderModel;
const grey = room_01.grey;
const vec3 = math.vec3;

const WIDTH = room_01.WIDTH;
const HEIGHT = room_01.HEIGHT;
const DEPTH = room_01.DEPTH;
const WALL = room_01.WALL;

pub const MODEL_PATH = "the-station/models/room_02/room_02.glb";

/// The room's middle on x: one room width and a wall left of Room 01's.
pub const CENTER_X: f32 = -(room_01.WIDTH + room_01.WALL);
const INNER_MIN_X = CENTER_X - WIDTH / 2.0;
const INNER_MAX_X = CENTER_X + WIDTH / 2.0;
const LEFT_WALL_X = INNER_MIN_X - WALL / 2.0;

/// The hole in the floor, and the shaft below it.
const HOLE_MIN_X = CENTER_X - 0.6;
const HOLE_MAX_X = CENTER_X + 0.6;
const HOLE_MIN_Z: f32 = -3.85;
const HOLE_MAX_Z: f32 = -2.85;
const SHAFT_DEPTH: f32 = WALL + room_01.BELOW_DEPTH;
/// The ladder stands against the hole's back edge and reaches above the floor, rungs to
/// its top.
const LADDER_Z = HOLE_MIN_Z + 0.06;
const RAIL_TOP: f32 = 1.2;
const RAIL_GAP: f32 = 0.5;

/// Standing on the top rung over the hole, facing the ladder; it steps on from the floor
/// right of the hole.
pub const ladder: Ladder = .{
    .top = vec3(CENTER_X, -0.05, -3.5),
    .depth = 1.9,
    .exit = vec3(HOLE_MAX_X + 0.35, 0.0, -3.5),
    .facing = room_01.FACE_BACK_WALL,
};

/// The keypad by the locked door, on the wall in front of the door.
const KEYPAD_Z = room_01.DOOR_CENTER_Z + room_01.DOOR_WIDTH / 2.0 + 0.35;

/// Where the robot stands by the door back to Room 01.
pub const DOOR_STAND_POINT = vec3(INNER_MAX_X - 0.7, 0.0, room_01.DOOR_CENTER_Z);

/// The floor the robot can walk on: in front of the hole, and either side of it. The
/// robot's center keeps 0.35 m from the hole and 0.4 m from the walls.
pub const walk_areas = [_]navigation.Area{
    .{ .min_x = INNER_MIN_X + 0.4, .max_x = INNER_MAX_X - 0.4, .min_z = HOLE_MAX_Z + 0.35, .max_z = -0.4 },
    .{ .min_x = INNER_MIN_X + 0.4, .max_x = HOLE_MIN_X - 0.35, .min_z = -3.5, .max_z = HOLE_MAX_Z + 0.35 },
    .{ .min_x = HOLE_MAX_X + 0.35, .max_x = INNER_MAX_X - 0.4, .min_z = -3.5, .max_z = HOLE_MAX_Z + 0.35 },
};

pub const hotspots = [_]Hotspot(HotspotKind){
    .{
        .kind = .door,
        .name = "Door",
        .bounds = bounds(vec3(INNER_MAX_X - 0.2, 0.0, room_01.DOOR_CENTER_Z - room_01.DOOR_WIDTH / 2.0), vec3(INNER_MAX_X + 0.05, room_01.DOOR_HEIGHT, room_01.DOOR_CENTER_Z + room_01.DOOR_WIDTH / 2.0)),
        .stand_point = DOOR_STAND_POINT,
        .facing = room_01.FACE_RIGHT_WALL,
        .action = .look,
    },
    .{
        .kind = .locked_door,
        .name = "Door",
        .bounds = bounds(vec3(INNER_MIN_X - 0.05, 0.0, room_01.DOOR_CENTER_Z - room_01.DOOR_WIDTH / 2.0), vec3(INNER_MIN_X + 0.2, room_01.DOOR_HEIGHT, room_01.DOOR_CENTER_Z + room_01.DOOR_WIDTH / 2.0)),
        .stand_point = vec3(INNER_MIN_X + 0.5, 0.0, room_01.DOOR_CENTER_Z),
        .facing = room_01.FACE_LEFT_WALL,
        .action = .look,
    },
    // Beside the door's front edge (`addLockedDoor`); pressed from a step in front of it
    .{
        .kind = .keypad,
        .name = "Keypad",
        .bounds = bounds(vec3(INNER_MIN_X - 0.02, 1.07, KEYPAD_Z - 0.13), vec3(INNER_MIN_X + 0.13, 1.43, KEYPAD_Z + 0.13)),
        .stand_point = vec3(INNER_MIN_X + 0.6, 0.0, KEYPAD_Z),
        .facing = room_01.FACE_LEFT_WALL,
        .action = .push_high,
    },
    // The deck's power cabinet right of the hole (build_room_02.py), 0.25 m deep
    .{
        .kind = .power_cabinet,
        .name = "Power cabinet",
        .bounds = bounds(vec3(-7.1, 0.6, -DEPTH), vec3(-5.5, 2.0, -3.65)),
        .stand_point = vec3(-6.3, 0.0, -3.4),
        .facing = room_01.FACE_BACK_WALL,
        .action = .look,
    },
    // The ladder above the floor, and its lower part: the hole it goes down
    .{
        .kind = .ladder,
        .name = "Ladder",
        .bounds = bounds(vec3(CENTER_X - 0.32, 0.3, LADDER_Z - 0.06), vec3(CENTER_X + 0.32, RAIL_TOP + 0.05, LADDER_Z + 0.1)),
        .stand_point = ladder.exit,
        .facing = room_01.FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .ladder_hole,
        .name = "Ladder",
        .bounds = bounds(vec3(HOLE_MIN_X, -0.6, HOLE_MIN_Z), vec3(HOLE_MAX_X, 0.3, HOLE_MAX_Z)),
        .stand_point = ladder.exit,
        .facing = room_01.FACE_BACK_WALL,
        .action = .look,
    },
};

/// The shell: floor around the hole, ceiling, back wall, the left wall around the locked
/// door, and the deck below with the shaft through it.
pub fn addShell(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    try addRoomBox(builder, allocator, parts);
    try addLockedDoor(builder, allocator, parts);
    try addShaft(builder, allocator, parts);
}

/// The equipment as boxes, drawn without the model: the ladder, the keypad, and stand-ins
/// for the lockers and the power cabinet.
pub fn addGreybox(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    try addLadder(builder, allocator, parts);
    try addKeypad(builder, allocator, parts);
    try addBackWall(builder, allocator, parts);
}

/// As Room 01's: floor and ceiling run under and over the side walls. The floor is four
/// pieces around the hole; only the front one reaches the cut.
fn addRoomBox(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const left = INNER_MIN_X - WALL;
    const right = INNER_MAX_X;
    const width = right - left;
    const middle = (left + right) / 2.0;
    const floor_y = -WALL / 2.0;
    const floor_color = grey(0.46);
    const shell = grey(0.55);
    const cube = builder.cube;
    try parts.appendSlice(allocator, &.{
        .{ .shape = cube, .model = box(vec3(middle, floor_y, HOLE_MAX_Z / 2.0), vec3(width, WALL, -HOLE_MAX_Z)), .color = floor_color, .is_cut = true },
        .{ .shape = cube, .model = box(vec3(middle, floor_y, (-DEPTH + HOLE_MIN_Z) / 2.0), vec3(width, WALL, HOLE_MIN_Z + DEPTH)), .color = floor_color },
        .{ .shape = cube, .model = box(vec3((left + HOLE_MIN_X) / 2.0, floor_y, (HOLE_MIN_Z + HOLE_MAX_Z) / 2.0), vec3(HOLE_MIN_X - left, WALL, HOLE_MAX_Z - HOLE_MIN_Z)), .color = floor_color },
        .{ .shape = cube, .model = box(vec3((HOLE_MAX_X + right) / 2.0, floor_y, (HOLE_MIN_Z + HOLE_MAX_Z) / 2.0), vec3(right - HOLE_MAX_X, WALL, HOLE_MAX_Z - HOLE_MIN_Z)), .color = floor_color },

        .{ .shape = cube, .model = box(vec3(middle, HEIGHT + WALL / 2.0, -DEPTH / 2.0), vec3(width, WALL, DEPTH)), .color = shell, .is_cut = true },
        .{ .shape = cube, .model = box(vec3(middle, HEIGHT / 2.0, -DEPTH - WALL / 2.0), vec3(width, HEIGHT + 2.0 * WALL, WALL)), .color = grey(0.6) },
    });
}

/// The left wall in three pieces around the doorway, a frame, and the door shut in it.
fn addLockedDoor(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const door_z = room_01.DOOR_CENTER_Z;
    const back_edge = door_z - room_01.DOOR_WIDTH / 2.0;
    const front_edge = door_z + room_01.DOOR_WIDTH / 2.0;
    const behind_depth = DEPTH + back_edge;
    const door_height = room_01.DOOR_HEIGHT;
    const shell = grey(0.55);
    const frame_color = grey(0.3);
    const trim = 0.14;
    const cube = builder.cube;
    const inner_x = INNER_MIN_X;
    try parts.appendSlice(allocator, &.{
        .{ .shape = cube, .model = box(vec3(LEFT_WALL_X, HEIGHT / 2.0, -DEPTH + behind_depth / 2.0), vec3(WALL, HEIGHT, behind_depth)), .color = shell, .is_cut = true },
        .{ .shape = cube, .model = box(vec3(LEFT_WALL_X, HEIGHT / 2.0, front_edge / 2.0), vec3(WALL, HEIGHT, -front_edge)), .color = shell, .is_cut = true },
        .{ .shape = cube, .model = box(vec3(LEFT_WALL_X, (HEIGHT + door_height) / 2.0, door_z), vec3(WALL, HEIGHT - door_height, room_01.DOOR_WIDTH)), .color = shell },
        .{ .shape = cube, .model = box(vec3(LEFT_WALL_X, door_height / 2.0, door_z), vec3(0.08, door_height, room_01.DOOR_WIDTH)), .color = grey(0.4) },

        .{ .shape = cube, .model = box(vec3(inner_x + 0.06, door_height / 2.0, back_edge - trim / 2.0), vec3(0.12, door_height, trim)), .color = frame_color },
        .{ .shape = cube, .model = box(vec3(inner_x + 0.06, door_height / 2.0, front_edge + trim / 2.0), vec3(0.12, door_height, trim)), .color = frame_color },
        .{ .shape = cube, .model = box(vec3(inner_x + 0.06, door_height + trim / 2.0, door_z), vec3(0.12, trim, room_01.DOOR_WIDTH + 2.0 * trim)), .color = frame_color },
    });
}

/// The keypad beside the locked door, dead.
fn addKeypad(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const inner_x = INNER_MIN_X;
    try parts.appendSlice(allocator, &.{
        .{ .shape = builder.cube, .model = box(vec3(inner_x + 0.04, 1.25, KEYPAD_Z), vec3(0.08, 0.26, 0.18)), .color = grey(0.25) },
        .{ .shape = builder.cylinder, .model = cylinderModel(vec3(inner_x + 0.08, 1.33, KEYPAD_Z), .x, 0.04, 0.02), .color = grey(0.15) },
    });
}

/// The deck below, solid as under Room 01, in four pieces around the shaft, and the
/// shaft's bottom. The pieces' faces around the hole are the shaft's walls.
fn addShaft(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const left = INNER_MIN_X - WALL;
    const right = INNER_MAX_X;
    const back = -DEPTH - WALL;
    const height = room_01.BELOW_DEPTH;
    const y = -WALL - height / 2.0;
    const below = grey(room_01.BELOW_COLOR_SRGB);
    const hole_middle_z = (HOLE_MIN_Z + HOLE_MAX_Z) / 2.0;
    const hole_depth = HOLE_MAX_Z - HOLE_MIN_Z;
    const cube = builder.cube;
    try parts.appendSlice(allocator, &.{
        .{ .shape = cube, .model = box(vec3((left + right) / 2.0, y, HOLE_MAX_Z / 2.0), vec3(right - left, height, -HOLE_MAX_Z)), .color = below, .is_cut = true },
        .{ .shape = cube, .model = box(vec3((left + right) / 2.0, y, (back + HOLE_MIN_Z) / 2.0), vec3(right - left, height, HOLE_MIN_Z - back)), .color = below },
        .{ .shape = cube, .model = box(vec3((left + HOLE_MIN_X) / 2.0, y, hole_middle_z), vec3(HOLE_MIN_X - left, height, hole_depth)), .color = below },
        .{ .shape = cube, .model = box(vec3((HOLE_MAX_X + right) / 2.0, y, hole_middle_z), vec3(right - HOLE_MAX_X, height, hole_depth)), .color = below },
        .{ .shape = cube, .model = box(vec3(CENTER_X, -SHAFT_DEPTH - 0.05, hole_middle_z), vec3(HOLE_MAX_X - HOLE_MIN_X, 0.1, hole_depth)), .color = grey(0.12) },
    });
}

/// Two rails from the shaft's bottom to above the floor, rungs every 0.3 m from the top
/// down. The robot stands on the one just below the floor (`ladder.top`).
fn addLadder(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const color = grey(0.4);
    for ([_]f32{ -RAIL_GAP / 2.0, RAIL_GAP / 2.0 }) |offset| {
        try parts.append(allocator, .{ .shape = builder.cylinder, .model = cylinderModel(vec3(CENTER_X + offset, -SHAFT_DEPTH, LADDER_Z), .y, 0.05, SHAFT_DEPTH + RAIL_TOP), .color = color });
    }
    var y: f32 = RAIL_TOP - 0.1;
    while (y > -SHAFT_DEPTH) : (y -= 0.3) {
        try parts.append(allocator, .{ .shape = builder.cylinder, .model = cylinderModel(vec3(CENTER_X - RAIL_GAP / 2.0, y, LADDER_Z), .x, 0.035, RAIL_GAP), .color = color });
    }
}

/// Flat stand-ins for the lockers (left of the hole) and the power cabinet (right).
fn addBackWall(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const wall_z = -DEPTH;
    const cube = builder.cube;
    try parts.appendSlice(allocator, &.{
        .{ .shape = cube, .model = box(vec3(-11.4, 0.98, wall_z + 0.12), vec3(1.4, 1.95, 0.24)), .color = grey(0.48) },
        .{ .shape = cube, .model = box(vec3(-6.3, 1.05, wall_z + 0.12), vec3(1.6, 1.9, 0.24)), .color = grey(0.48) },
    });
}
