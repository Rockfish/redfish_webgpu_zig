//! Room 01, the control room (plan 021), 3 x 1 cells at column 0, row 0 of the station
//! (`station.zig`), right of Room 02.
//!
//! The shell (floor, ceiling, walls, the doorway and its door, the alarm lamp, the
//! ceiling lights) is boxes and cylinders (`room_kit.zig`): its cut faces, the sliding
//! door, and the lamps change per draw. The equipment (a row of instrument cabinets under
//! a mimic board on the back wall, the console on the right wall, pipes) is the model
//! `MODEL_PATH`, built by `the-station/blender/build_room.py`; without it, or with the
//! panel's "greybox room", the greybox equipment draws instead.
//!
//! In the room's own coordinates: its inside spans x -WIDTH/2..WIDTH/2, y 0..HEIGHT,
//! z -DEPTH..0 (`room_kit.zig`). Left wall: a doorway to Room 02 with a door that slides into the
//! wall. Right wall: the control console. Back wall: the cabinets (among them the gauges,
//! the screen, and the breakers) and the alarm lamp above the middle. The things the
//! robot can use are `hotspots`.

const std = @import("std");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const station = @import("station.zig");
const navigation = @import("navigation.zig");
const Station = @import("state.zig").Station;
const Hotspot = station.Hotspot;
const Part = room_kit.Part;
const PartBuilder = room_kit.PartBuilder;
const bounds = room_kit.bounds;
const box = room_kit.box;
const cylinderModel = room_kit.cylinderModel;
const grey = room_kit.grey;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;

const DEPTH = room_kit.DEPTH;
const DOOR_CENTER_Z = room_kit.DOOR_CENTER_Z;
const DOOR_WIDTH = room_kit.DOOR_WIDTH;
const DOOR_HEIGHT = room_kit.DOOR_HEIGHT;
const FACE_LEFT_WALL = room_kit.FACE_LEFT_WALL;
const FACE_RIGHT_WALL = room_kit.FACE_RIGHT_WALL;
const FACE_BACK_WALL = room_kit.FACE_BACK_WALL;

pub const MODEL_PATH = "the-station/models/room_01/room_01.glb";

const CELLS_WIDE = 3;
const CELLS_HIGH = 1;
pub const WIDTH = room_kit.insideWidth(CELLS_WIDE);
pub const HEIGHT = room_kit.insideHeight(CELLS_HIGH);

pub const room: station.Room = .{
    .name = "Room 01",
    .column = 0,
    .row = 0,
    .cells_wide = CELLS_WIDE,
    .cells_high = CELLS_HIGH,
    .model_path = MODEL_PATH,
    .shell = shell,
    .walk_areas = &walk_areas,
    .hotspots = &hotspots,
    .addGreybox = addGreybox,
};

/// The shell: a doorway to Room 02 in the left wall, framed on both sides, its door drawn
/// on its own (it slides); a solid right wall.
const shell: room_kit.Shell = .{
    .width = WIDTH,
    .height = HEIGHT,
    .left = .{ .doorway = .{ .door = .separate, .is_framed_outside = true } },
    .right = .solid,
};

/// The left wall's center line; the door slides along it, inside the wall. Room 02's
/// right wall is this wall.
pub const LEFT_WALL_X: f32 = -(WIDTH + room_kit.WALL) / 2.0;

/// Where the alarm lamp is, on the back wall above the screen panel.
pub const ALARM_LAMP_POSITION = vec3(0.0, 2.7, -DEPTH + 0.12);
/// Where the alarm's light comes from: a little in front of the lamp, so the back wall
/// around it is lit too.
pub const ALARM_LIGHT_POSITION = vec3(0.0, 2.5, -DEPTH + 0.8);
const ALARM_RED = vec3(1.0, 0.04, 0.02);

/// The floor the robot can walk on: clear of the walls, the console, and the cabinets.
pub const WALK_MIN_X: f32 = -3.4;
const walk_areas = [_]navigation.Area{
    .{ .min_x = WALK_MIN_X, .max_x = 2.85, .min_z = -3.25, .max_z = -0.4 },
};

/// Where the robot starts.
pub const ROBOT_START = vec3(-0.8, 0.0, -1.6);

/// Where the robot stands to use the door, in this room.
pub const DOOR_STAND_POINT = vec3(-3.3, 0.0, DOOR_CENTER_Z);

/// The room's own hotspots (`use`); its door is the station's (`station.HotspotKind`).
/// The console's buttons: red silences the alarm, the middle one opens and closes the
/// door, the third switches on the emergency power.
pub const HotspotKind = enum {
    red_button,
    door_button,
    lights_button,
    lever,
    gauges,
    screen,
    breakers,
};

const hotspots = [_]Hotspot{
    .{
        .kind = .door,
        .name = "Door",
        .bounds = bounds(vec3(-WIDTH / 2.0 - 0.05, 0.0, DOOR_CENTER_Z - DOOR_WIDTH / 2.0), vec3(-WIDTH / 2.0 + 0.15, DOOR_HEIGHT, DOOR_CENTER_Z + DOOR_WIDTH / 2.0)),
        .stand_point = DOOR_STAND_POINT,
        .facing = FACE_LEFT_WALL,
        .action = .look,
    },
    .{
        .kind = .{ .room_01 = .red_button },
        .name = "Red button",
        .bounds = bounds(vec3(3.33, 0.85, -1.62), vec3(3.57, 1.0, -1.38)),
        .stand_point = vec3(2.75, 0.0, -1.5),
        .facing = FACE_RIGHT_WALL,
        .action = .push,
        .mesh = "red_button",
    },
    .{
        .kind = .{ .room_01 = .door_button },
        .name = "Button",
        .bounds = bounds(vec3(3.33, 0.85, -2.12), vec3(3.57, 1.0, -1.88)),
        .stand_point = vec3(2.75, 0.0, -2.0),
        .facing = FACE_RIGHT_WALL,
        .action = .push,
        .mesh = "door_button",
    },
    .{
        .kind = .{ .room_01 = .lights_button },
        .name = "Button",
        .bounds = bounds(vec3(3.33, 0.85, -2.62), vec3(3.57, 1.0, -2.38)),
        .stand_point = vec3(2.75, 0.0, -2.5),
        .facing = FACE_RIGHT_WALL,
        .action = .push,
        .mesh = "lights_button",
    },
    .{
        .kind = .{ .room_01 = .lever },
        .name = "Lever",
        .bounds = bounds(vec3(3.6, 0.9, -1.35), vec3(3.8, 1.35, -1.15)),
        .stand_point = vec3(2.75, 0.0, -1.0),
        .facing = FACE_RIGHT_WALL,
        .action = .push,
        .mesh = "lever",
    },
    // The back wall's hotspots are two-bay cabinets in the row (build_room.py), each
    // the cabinet's fittings, standing out from its front at z -3.65
    .{
        .kind = .{ .room_01 = .gauges },
        .name = "Gauges",
        .bounds = bounds(vec3(-3.2, 0.62, -DEPTH), vec3(-1.6, 1.72, -3.55)),
        .stand_point = vec3(-2.4, 0.0, -3.2),
        .facing = FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .{ .room_01 = .screen },
        .name = "Screen",
        .bounds = bounds(vec3(-0.5, 0.95, -DEPTH), vec3(0.5, 1.7, -3.5)),
        .stand_point = vec3(0.0, 0.0, -3.2),
        .facing = FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .{ .room_01 = .breakers },
        .name = "Breakers",
        .bounds = bounds(vec3(1.6, 0.9, -DEPTH), vec3(3.2, 1.65, -3.5)),
        .stand_point = vec3(2.4, 0.0, -3.2),
        .facing = FACE_BACK_WALL,
        .action = .look,
    },
};

/// What using `kind` does to the station; returns the robot's remark.
pub fn use(state: *Station, kind: HotspotKind) []const u8 {
    return switch (kind) {
        .red_button => switch (state.alarm) {
            .sounding => {
                state.alarm = .silenced;
                return "Alarm off. Quiet at last.";
            },
            .silenced => "Nothing more happens.",
        },
        .lights_button => switch (state.power.emergency) {
            .off => {
                state.power.emergency = .on;
                return "Main power offline. Emergency lights only.";
            },
            .on => "Still only emergency power.",
        },
        // The robot presses it at the console, so it is never in the doorway as the
        // door closes
        .door_button => {
            if (!state.toggleDoor(.room_01_left)) {
                return "Click. No power to the door.";
            }
            return if (state.isDoorOpen(.room_01_left)) "A lock clicks. The door slides open." else "The door slides shut.";
        },
        .lever => "Stuck.",
        .gauges => "Pressure in the reactor ring is falling.",
        .screen => if (state.isAlarmSounding()) "ALARM: MAIN POWER LOST" else "MAIN POWER LOST (acknowledged)",
        .breakers => "All breakers are on. The fault is somewhere else.",
    };
}

/// Light falling on the room from the alarm, for point light `SceneLights.setPointLight`.
pub fn alarmLightColor(intensity: f32) Vec3 {
    return ALARM_RED.mulScalar(intensity);
}

/// The equipment as boxes, drawn without the model: the console, the back wall's panels,
/// and pipes.
fn addGreybox(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) std.mem.Allocator.Error!void {
    try addConsole(builder, allocator, parts);
    try addBackPanels(builder, allocator, parts);
    try addPipes(builder, allocator, parts);
}

/// The control console against the right wall: a desk, an upright panel on the wall,
/// three buttons (the red one stops the alarm), and a lever.
fn addConsole(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const wall_x = WIDTH / 2.0;
    const center_z = -2.0;
    const desk_height = 0.9;
    const button = vec3(0.14, 0.06, 0.14);
    const button_x = wall_x - 0.55;
    try parts.appendSlice(allocator, &.{
        .{ .shape = builder.cube, .model = box(vec3(wall_x - 0.4, desk_height / 2.0, center_z), vec3(0.8, desk_height, 1.8)), .color = grey(0.5) },
        .{ .shape = builder.cube, .model = box(vec3(wall_x - 0.08, 1.55, center_z), vec3(0.16, 1.1, 1.8)), .color = grey(0.42) },
        .{ .shape = builder.cube, .model = box(vec3(wall_x - 0.17, 1.6, center_z), vec3(0.02, 0.6, 1.2)), .color = grey(0.75), .emissive = 0.25 },
        .{ .shape = builder.cube, .model = box(vec3(button_x, desk_height, center_z - 0.5), button), .color = grey(0.75) },
        .{ .shape = builder.cube, .model = box(vec3(button_x, desk_height, center_z), button), .color = grey(0.75) },
        .{ .shape = builder.cube, .model = box(vec3(button_x, desk_height, center_z + 0.5), button), .color = vec4(0.6, 0.02, 0.02, 1.0) },
        .{ .shape = builder.cylinder, .model = cylinderModel(vec3(wall_x - 0.3, desk_height, center_z + 0.75), .y, 0.05, 0.4), .color = grey(0.25) },
    });
}

/// Gauges on the left, a screen in the middle, a breaker box on the right, where the
/// model's two-bay cabinets for them are.
fn addBackPanels(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const wall_z = -DEPTH;
    const panel_size = vec3(1.4, 1.5, 0.12);
    const panel_y = 1.45;
    const panel_color = grey(0.48);
    const detail_color = grey(0.3);
    const front_z = wall_z + panel_size.z;
    try parts.appendSlice(allocator, &.{
        .{ .shape = builder.cube, .model = box(vec3(-2.4, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },
        .{ .shape = builder.cube, .model = box(vec3(0.0, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },
        .{ .shape = builder.cube, .model = box(vec3(2.4, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },

        .{ .shape = builder.cylinder, .model = cylinderModel(vec3(-2.75, 1.75, front_z), .z, 0.45, 0.05), .color = grey(0.8) },
        .{ .shape = builder.cylinder, .model = cylinderModel(vec3(-2.05, 1.75, front_z), .z, 0.45, 0.05), .color = grey(0.8) },
        .{ .shape = builder.cylinder, .model = cylinderModel(vec3(-2.4, 1.1, front_z), .z, 0.55, 0.05), .color = grey(0.8) },

        .{ .shape = builder.cube, .model = box(vec3(0.0, 1.55, front_z + 0.01), vec3(1.1, 0.8, 0.02)), .color = grey(0.7), .emissive = 0.3 },
        .{ .shape = builder.cube, .model = box(vec3(0.0, 0.95, front_z + 0.02), vec3(0.9, 0.12, 0.04)), .color = detail_color },

        .{ .shape = builder.cube, .model = box(vec3(2.4, panel_y, front_z + 0.02), vec3(1.1, 1.2, 0.04)), .color = grey(0.4) },
        .{ .shape = builder.cube, .model = box(vec3(2.85, panel_y, front_z + 0.06), vec3(0.06, 0.25, 0.06)), .color = detail_color },
    });
}

/// Two pipes along the back wall under the ceiling.
fn addPipes(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const start_x = -WIDTH / 2.0;
    try parts.appendSlice(allocator, &.{
        .{ .shape = builder.cylinder, .model = cylinderModel(vec3(start_x, 2.75, -DEPTH + 0.5), .x, 0.18, WIDTH), .color = grey(0.4) },
        .{ .shape = builder.cylinder, .model = cylinderModel(vec3(start_x, 2.5, -DEPTH + 0.3), .x, 0.12, WIDTH), .color = grey(0.35) },
    });
}
