//! The generator room (plan 022, phase E4), under Room 01, entered through an open
//! doorway from Room 04: the station's generator, a big machine along the back wall, and
//! its control panel standing beside it, where phase H's puzzle is. Greybox for now,
//! after John's reference photos (`the-station/images/generator_rooms/`): a diesel engine
//! and its alternator on a skid, exhaust stacks to the ceiling, pipe runs and a cable tray
//! along the back wall, switchgear with gauges and a gauge board left of the machine, a
//! crane beam under the ceiling.
//!
//! 6 x 2 cells at column 0, row -2 of the station (`station.zig`), in its own coordinates
//! as Room 01 (`room_01.zig`). Its left wall, with the doorway, is beside Rooms 04 and 03;
//! its ceiling is Room 01's floor. The camera shows a window of it that follows the robot
//! (`station.cameraFraming`).

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
const vec3 = math.vec3;

const DEPTH = room_kit.DEPTH;
const DOOR_CENTER_Z = room_kit.DOOR_CENTER_Z;
const DOOR_WIDTH = room_kit.DOOR_WIDTH;
const DOOR_HEIGHT = room_kit.DOOR_HEIGHT;

const CELLS_WIDE = 6;
const CELLS_HIGH = 2;
const WIDTH = room_kit.insideWidth(CELLS_WIDE);
const HEIGHT = room_kit.insideHeight(CELLS_HIGH);
const INNER_MIN_X = -WIDTH / 2.0;
const INNER_MAX_X = WIDTH / 2.0;

pub const room: station.Room = .{
    .name = "Generator room",
    .column = 0,
    .row = -2,
    .cells_wide = CELLS_WIDE,
    .cells_high = CELLS_HIGH,
    .model_path = null,
    .shell = shell,
    .walk_areas = &walk_areas,
    .hotspots = &hotspots,
    .ceiling_lights = &.{ -5.5, 0.0, 5.5 },
    // Hung over the machine, about as high as in a one-cell room is far from the floor
    .ceiling_light_drop = 2.0,
    .addGreybox = addGreybox,
};

/// An open doorway to Room 04 in the left wall, which runs up past Room 03 too; a solid
/// right wall; on the ceiling right of Room 01 (whose floor it is up to there), solid
/// station.
const shell: room_kit.Shell = .{
    .width = WIDTH,
    .height = HEIGHT,
    .left = .{ .doorway = .{ .door = .none, .is_framed_outside = true } },
    .right = .solid,
    .deck_above = .{ .min_x = ROOM_01_RIGHT_X, .max_x = INNER_MAX_X + room_kit.WALL },
};
/// Room 01's right wall's outer face: Room 01 is over the left half (3 of 6 cells).
const ROOM_01_RIGHT_X = INNER_MIN_X - room_kit.WALL / 2.0 + 3.0 * room_kit.CELL_WIDTH + room_kit.WALL / 2.0;

/// Where the robot stands by the doorway to Room 04.
pub const DOOR_STAND_POINT = vec3(INNER_MIN_X + 0.7, 0.0, DOOR_CENTER_Z);

/// The generator's skid, along the back wall; the panel right of it.
const SKID_MIN_X = -3.7;
const SKID_MAX_X = 4.7;
const SKID_MIN_Z = -3.7;
const SKID_MAX_Z = -1.8;
const PANEL_X = 6.3;
const PANEL_FRONT_Z = -2.25;

/// The floor the robot can walk on: the walkway in front of the machine, and either side
/// of it, to the switchgear and to the panel.
const walk_areas = [_]navigation.Area{
    .{ .min_x = INNER_MIN_X + 0.4, .max_x = INNER_MAX_X - 0.4, .min_z = SKID_MAX_Z + 0.3, .max_z = -0.4 },
    .{ .min_x = INNER_MIN_X + 0.4, .max_x = -4.8, .min_z = -3.1, .max_z = -0.4 },
    .{ .min_x = SKID_MAX_X + 0.4, .max_x = INNER_MAX_X - 0.4, .min_z = PANEL_FRONT_Z + 0.35, .max_z = -0.4 },
};

/// The room's own hotspots (`use`); the doorway to Room 04 is the station's.
pub const HotspotKind = enum { generator, generator_panel, switchgear };

const hotspots = [_]Hotspot{
    .{
        .kind = .{ .doorway = .room_04_generator },
        .name = "Doorway",
        .bounds = bounds(vec3(INNER_MIN_X - 0.05, 0.0, DOOR_CENTER_Z - DOOR_WIDTH / 2.0), vec3(INNER_MIN_X + 0.2, DOOR_HEIGHT, DOOR_CENTER_Z + DOOR_WIDTH / 2.0)),
        .stand_point = DOOR_STAND_POINT,
        .facing = room_kit.FACE_LEFT_WALL,
        .action = .look,
    },
    .{
        .kind = .{ .generator_room = .generator },
        .name = "Generator",
        .bounds = bounds(vec3(-4.4, 0.3, SKID_MIN_Z), vec3(SKID_MAX_X - 0.4, 2.5, SKID_MAX_Z)),
        .stand_point = vec3(0.0, 0.0, -1.5),
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .{ .generator_room = .generator_panel },
        .name = "Generator panel",
        .bounds = bounds(vec3(PANEL_X - 0.8, 0.9, PANEL_FRONT_Z - 0.5), vec3(PANEL_X + 0.8, 2.0, PANEL_FRONT_Z + 0.05)),
        .stand_point = vec3(PANEL_X, 0.0, PANEL_FRONT_Z + 0.35),
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .{ .generator_room = .switchgear },
        .name = "Switchgear",
        .bounds = bounds(vec3(-7.8, 0.4, -DEPTH), vec3(-5.4, 2.2, -3.5)),
        .stand_point = vec3(-6.6, 0.0, -3.1),
        .facing = room_kit.FACE_BACK_WALL,
        .action = .look,
    },
};

/// What using `kind` does to the station; returns the robot's remark. Phase H makes the
/// panel a puzzle.
pub fn use(state: *Station, kind: HotspotKind) []const u8 {
    // Nothing here changes the station yet
    _ = state;
    return switch (kind) {
        .generator => "The generator. Cold and silent.",
        .generator_panel => "The generator's panel. Every lamp is dark.",
        .switchgear => "Fuel, oil, coolant: every needle at zero.",
    };
}

/// The machine, the back wall's pipes and panels, the panel beside the machine, and the
/// crane beam.
fn addGreybox(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) std.mem.Allocator.Error!void {
    try addGenerator(builder, allocator, parts);
    try addBackWall(builder, allocator, parts);
    try addPanel(builder, allocator, parts);
    // Below the ceiling lights
    try parts.append(allocator, .{ .shape = builder.cube, .model = box(vec3(0.0, HEIGHT - 0.9, -2.0), vec3(WIDTH, 0.35, 0.25)), .color = grey(0.35) });
}

/// The skid; the engine with its row of cylinder heads, intake manifold, and two
/// turbochargers at its left end, exhausts rising from them to the ceiling; the
/// alternator drum, its end bell, and the terminal box on top.
fn addGenerator(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const cube = builder.cube;
    const cylinder = builder.cylinder;
    const center_z = (SKID_MIN_Z + SKID_MAX_Z) / 2.0;
    const engine = grey(0.45);
    try parts.appendSlice(allocator, &.{
        .{ .shape = cube, .model = box(vec3((SKID_MIN_X + SKID_MAX_X) / 2.0, 0.15, center_z), vec3(SKID_MAX_X - SKID_MIN_X, 0.3, SKID_MAX_Z - SKID_MIN_Z)), .color = grey(0.3) },
        .{ .shape = cube, .model = box(vec3(-1.2, 1.0, center_z), vec3(5.0, 1.4, 1.4)), .color = engine },
        .{ .shape = cylinder, .model = cylinderModel(vec3(-3.6, 2.15, center_z), .x, 0.25, 4.8), .color = grey(0.4) },
        .{ .shape = cylinder, .model = cylinderModel(vec3(-4.1, 1.6, center_z - 0.7), .z, 0.6, 0.6), .color = grey(0.55) },
        .{ .shape = cylinder, .model = cylinderModel(vec3(-4.1, 1.6, center_z + 0.1), .z, 0.6, 0.6), .color = grey(0.55) },
        .{ .shape = cylinder, .model = cylinderModel(vec3(-4.1, 1.9, center_z - 0.4), .y, 0.35, HEIGHT - 1.9), .color = grey(0.6) },
        .{ .shape = cylinder, .model = cylinderModel(vec3(-4.1, 1.9, center_z + 0.4), .y, 0.35, HEIGHT - 1.9), .color = grey(0.6) },
        .{ .shape = cylinder, .model = cylinderModel(vec3(1.4, 1.25, center_z), .x, 2.0, 2.6), .color = grey(0.42) },
        .{ .shape = cylinder, .model = cylinderModel(vec3(4.0, 1.25, center_z), .x, 1.6, 0.5), .color = grey(0.38) },
        .{ .shape = cube, .model = box(vec3(2.6, 2.45, center_z), vec3(0.9, 0.5, 0.8)), .color = grey(0.5) },
    });
    for (0..8) |i| {
        const x = -3.3 + @as(f32, @floatFromInt(i)) * 0.6;
        try parts.append(allocator, .{ .shape = cube, .model = box(vec3(x, 1.85, center_z), vec3(0.45, 0.3, 1.1)), .color = grey(0.5) });
    }
}

/// Pipe runs and a cable tray along the back wall above the machine; switchgear with a
/// gauge each left of it, and a gauge board above them.
fn addBackWall(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const cube = builder.cube;
    const cylinder = builder.cylinder;
    try parts.appendSlice(allocator, &.{
        .{ .shape = cylinder, .model = cylinderModel(vec3(INNER_MIN_X, 3.4, -3.75), .x, 0.3, WIDTH), .color = grey(0.4) },
        .{ .shape = cylinder, .model = cylinderModel(vec3(INNER_MIN_X, 3.9, -3.6), .x, 0.2, WIDTH), .color = grey(0.5) },
        .{ .shape = cylinder, .model = cylinderModel(vec3(INNER_MIN_X, 4.6, -3.75), .x, 0.35, WIDTH), .color = grey(0.35) },
        .{ .shape = cube, .model = box(vec3(0.0, 3.0, -3.85), vec3(WIDTH, 0.08, 0.3)), .color = grey(0.3) },
        .{ .shape = cube, .model = box(vec3(-6.6, 4.2, -DEPTH + 0.05), vec3(2.6, 1.4, 0.1)), .color = grey(0.5) },
    });
    for ([_]f32{ -7.4, -6.6, -5.8 }) |x| {
        try parts.appendSlice(allocator, &.{
            .{ .shape = cube, .model = box(vec3(x, 1.1, -3.75), vec3(0.75, 2.2, 0.5)), .color = grey(0.5) },
            .{ .shape = cylinder, .model = cylinderModel(vec3(x, 1.7, -3.5), .z, 0.3, 0.03), .color = grey(0.8) },
            .{ .shape = cylinder, .model = cylinderModel(vec3(x, 4.3, -DEPTH + 0.1), .z, 0.45, 0.03), .color = grey(0.8) },
        });
    }
}

/// The generator's control panel, standing right of the machine: a cabinet, a desk in
/// front of it, three gauges and a row of lamps on its face.
fn addPanel(builder: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
    const cube = builder.cube;
    const cylinder = builder.cylinder;
    const face_z = PANEL_FRONT_Z - 0.4;
    try parts.appendSlice(allocator, &.{
        .{ .shape = cube, .model = box(vec3(PANEL_X, 1.0, face_z - 0.4), vec3(1.6, 2.0, 0.8)), .color = grey(0.48) },
        .{ .shape = cube, .model = box(vec3(PANEL_X, 1.45, face_z + 0.02), vec3(1.3, 0.9, 0.04)), .color = grey(0.7) },
        .{ .shape = cube, .model = box(vec3(PANEL_X, 0.95, PANEL_FRONT_Z - 0.2), vec3(1.6, 0.1, 0.45)), .color = grey(0.4) },
    });
    for ([_]f32{ -0.4, 0.0, 0.4 }) |offset| {
        try parts.appendSlice(allocator, &.{
            .{ .shape = cylinder, .model = cylinderModel(vec3(PANEL_X + offset, 1.7, face_z + 0.04), .z, 0.28, 0.03), .color = grey(0.85) },
            .{ .shape = cylinder, .model = cylinderModel(vec3(PANEL_X + offset, 1.2, face_z + 0.04), .z, 0.1, 0.03), .color = grey(0.25) },
        });
    }
}
