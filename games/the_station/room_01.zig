//! Room 01, the control room (plan 021), and the pieces every room is drawn with
//! (`Part`, `PartBuilder`, `box`, `grey`). The deck (`deck.zig`) puts it next to Room 02.
//!
//! The shell (floor, ceiling, walls, the doorway and its door, the alarm lamp, the
//! ceiling lights) is boxes and cylinders: its cut faces, the sliding door, and the
//! lamps change per draw. The equipment (a row of instrument cabinets under a mimic board
//! on the back wall, the console on the right wall, pipes) is the model `MODEL_PATH`,
//! built by `the-station/blender/build_room.py`; without it, or with the panel's
//! "greybox room", the greybox equipment draws instead.
//!
//! World layout, 1 unit = 1 m: x runs left to right across the room, y up from the
//! floor, z out of the room toward the camera. The room's inside spans
//! x -WIDTH/2..WIDTH/2, y 0..HEIGHT, z -DEPTH..0; the front (z = 0) is open. The shell
//! (floor, ceiling, walls) is WALL thick, and its faces at z = 0 are the cut through the
//! station, drawn dark.
//!
//! Left wall: a doorway to Room 02 with a door that slides into the wall. Right wall: the
//! control console. Back wall: the cabinets (among them the gauges, the screen, and the breakers)
//! and the alarm lamp above the middle. The things the robot can use are `hotspots`.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const AABB = core.AABB;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const srgbToLinear = core.colors.srgbToLinear;
const Hotspot = @import("interaction.zig").Hotspot;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

pub const MODEL_PATH = "the-station/models/room_01/room_01.glb";

pub const WIDTH: f32 = 8.0;
pub const HEIGHT: f32 = 3.0;
pub const DEPTH: f32 = 4.0;
pub const WALL: f32 = 0.4;
/// The deck below, not explored yet: solid under the floor, drawn as a cut.
pub const BELOW_DEPTH: f32 = 3.0;
pub const BELOW_COLOR_SRGB: f32 = 0.35;

/// The doorway in the left wall (and the doors of other rooms).
pub const DOOR_CENTER_Z: f32 = -2.2;
pub const DOOR_WIDTH: f32 = 1.2;
pub const DOOR_HEIGHT: f32 = 2.2;
/// The left wall's center line; the door slides along it, inside the wall. Room 02's
/// right wall is this wall.
pub const LEFT_WALL_X: f32 = -(WIDTH + WALL) / 2.0;

/// Where the alarm lamp is, on the back wall above the screen panel.
pub const ALARM_LAMP_POSITION = vec3(0.0, 2.7, -DEPTH + 0.12);
/// Where the alarm's light comes from: a little in front of the lamp, so the back wall
/// around it is lit too.
pub const ALARM_LIGHT_POSITION = vec3(0.0, 2.5, -DEPTH + 0.8);
const ALARM_RED = vec3(1.0, 0.04, 0.02);

/// The floor the robot can walk on: clear of the walls, the console, and the cabinets.
pub const WALK_MIN_X: f32 = -3.4;
pub const WALK_MAX_X: f32 = 2.85;
pub const WALK_MIN_Z: f32 = -3.25;
pub const WALK_MAX_Z: f32 = -0.4;

/// Where the robot starts.
pub const ROBOT_START = vec3(-0.8, 0.0, -1.6);

/// Where the robot stands to use the door, in this room.
pub const DOOR_STAND_POINT = vec3(-3.3, 0.0, DOOR_CENTER_Z);

/// What each hotspot on the deck is, for the game to decide what using it does. The
/// console's buttons: red stops the alarm, the middle one opens and closes the door, the
/// third turns on the lights. Room 02 (`room_02.zig`): its locked door and the keypad
/// beside it, the power cabinet, and the ladder, whose lower part (the hole) is a hotspot
/// of its own.
pub const HotspotKind = enum {
    door,
    red_button,
    door_button,
    lights_button,
    lever,
    gauges,
    screen,
    breakers,
    locked_door,
    keypad,
    power_cabinet,
    ladder,
    ladder_hole,
};

/// Facing directions for stand points: the robot's yaw, 0 toward the camera (+z).
pub const FACE_LEFT_WALL = -std.math.pi / 2.0;
pub const FACE_RIGHT_WALL = std.math.pi / 2.0;
pub const FACE_BACK_WALL = std.math.pi;

pub const hotspots = [_]Hotspot(HotspotKind){
    .{
        .kind = .door,
        .name = "Door",
        .bounds = bounds(vec3(-WIDTH / 2.0 - 0.05, 0.0, DOOR_CENTER_Z - DOOR_WIDTH / 2.0), vec3(-WIDTH / 2.0 + 0.15, DOOR_HEIGHT, DOOR_CENTER_Z + DOOR_WIDTH / 2.0)),
        .stand_point = DOOR_STAND_POINT,
        .facing = FACE_LEFT_WALL,
        .action = .look,
    },
    .{
        .kind = .red_button,
        .name = "Red button",
        .bounds = bounds(vec3(3.33, 0.85, -1.62), vec3(3.57, 1.0, -1.38)),
        .stand_point = vec3(2.75, 0.0, -1.5),
        .facing = FACE_RIGHT_WALL,
        .action = .push,
    },
    .{
        .kind = .door_button,
        .name = "Button",
        .bounds = bounds(vec3(3.33, 0.85, -2.12), vec3(3.57, 1.0, -1.88)),
        .stand_point = vec3(2.75, 0.0, -2.0),
        .facing = FACE_RIGHT_WALL,
        .action = .push,
    },
    .{
        .kind = .lights_button,
        .name = "Button",
        .bounds = bounds(vec3(3.33, 0.85, -2.62), vec3(3.57, 1.0, -2.38)),
        .stand_point = vec3(2.75, 0.0, -2.5),
        .facing = FACE_RIGHT_WALL,
        .action = .push,
    },
    .{
        .kind = .lever,
        .name = "Lever",
        .bounds = bounds(vec3(3.6, 0.9, -1.35), vec3(3.8, 1.35, -1.15)),
        .stand_point = vec3(2.75, 0.0, -1.0),
        .facing = FACE_RIGHT_WALL,
        .action = .push,
    },
    // The back wall's hotspots are two-bay cabinets in the row (build_room.py), each
    // the cabinet's fittings, standing out from its front at z -3.65
    .{
        .kind = .gauges,
        .name = "Gauges",
        .bounds = bounds(vec3(-3.2, 0.62, -DEPTH), vec3(-1.6, 1.72, -3.55)),
        .stand_point = vec3(-2.4, 0.0, -3.2),
        .facing = FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .screen,
        .name = "Screen",
        .bounds = bounds(vec3(-0.5, 0.95, -DEPTH), vec3(0.5, 1.7, -3.5)),
        .stand_point = vec3(0.0, 0.0, -3.2),
        .facing = FACE_BACK_WALL,
        .action = .look,
    },
    .{
        .kind = .breakers,
        .name = "Breakers",
        .bounds = bounds(vec3(1.6, 0.9, -DEPTH), vec3(3.2, 1.65, -3.5)),
        .stand_point = vec3(2.4, 0.0, -3.2),
        .facing = FACE_BACK_WALL,
        .action = .look,
    },
};

/// Ink hatching for a draw (`room.wgsl` params z and w); see `ink.Style`.
pub const Hatching = struct {
    /// 0..1; 0 is none.
    strength: f32,
    /// Meters between lines.
    spacing: f32,
};

/// One box or cylinder, drawn with `room.wgsl`.
pub const Part = struct {
    shape: *Shape,
    model: Mat4,
    color: Vec4,
    /// 0..1: how much the color shows unlit (lamps, screens).
    emissive: f32 = 0.0,
    /// A shell part: its faces toward the camera are the cut, drawn dark.
    is_cut: bool = false,
};

/// Light falling on the room from the alarm, for point light `SceneLights.setPointLight`.
pub fn alarmLightColor(intensity: f32) Vec3 {
    return ALARM_RED.mulScalar(intensity);
}

pub fn drawPart(frame: *const Frame, shader: *const Shader, part: Part, hatching: Hatching) void {
    var uniforms = DrawUniforms.init(part.model, part.color);
    uniforms.params = vec4(part.emissive, if (part.is_cut) 1.0 else 0.0, hatching.strength, hatching.spacing);
    part.shape.draw(frame, shader, uniforms);
}

/// Adds a room's parts, one group per function: Room 01's here, Room 02's in
/// `room_02.zig`.
pub const PartBuilder = struct {
    cube: *Shape,
    cylinder: *Shape,

    /// Floor, ceiling, back wall, and the right wall. Floor and ceiling run under and over
    /// the side walls, so the cut reads as one frame. The left wall has the doorway, so it
    /// is built around it (`addDoorway`). Under the floor, the deck below as a solid cut.
    pub fn addShell(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const outer_width = WIDTH + 2.0 * WALL;
        const shell = grey(0.55);
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(0.0, -WALL / 2.0, -DEPTH / 2.0), vec3(outer_width, WALL, DEPTH)), .color = grey(0.46), .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(0.0, HEIGHT + WALL / 2.0, -DEPTH / 2.0), vec3(outer_width, WALL, DEPTH)), .color = shell, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(0.0, HEIGHT / 2.0, -DEPTH - WALL / 2.0), vec3(outer_width, HEIGHT + 2.0 * WALL, WALL)), .color = grey(0.6) },
            .{ .shape = self.cube, .model = box(vec3(-LEFT_WALL_X, HEIGHT / 2.0, -DEPTH / 2.0), vec3(WALL, HEIGHT, DEPTH)), .color = shell, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(0.0, -WALL - BELOW_DEPTH / 2.0, -(DEPTH + WALL) / 2.0), vec3(outer_width, BELOW_DEPTH, DEPTH + WALL)), .color = grey(BELOW_COLOR_SRGB), .is_cut = true },
        });
    }

    /// The left wall in three pieces around the doorway (behind it, in front of it, above
    /// it), and a frame of two posts and a lintel on each side: Room 02 is beyond it. The
    /// door slides into the piece behind the doorway.
    pub fn addDoorway(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const shell = grey(0.55);
        const back_edge = DOOR_CENTER_Z - DOOR_WIDTH / 2.0;
        const front_edge = DOOR_CENTER_Z + DOOR_WIDTH / 2.0;
        const behind_depth = DEPTH + back_edge;
        const inner_x = -WIDTH / 2.0;
        const outer_x = -WIDTH / 2.0 - WALL;
        const trim = 0.14;
        const frame_color = grey(0.3);
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(LEFT_WALL_X, HEIGHT / 2.0, -DEPTH + behind_depth / 2.0), vec3(WALL, HEIGHT, behind_depth)), .color = shell, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(LEFT_WALL_X, HEIGHT / 2.0, front_edge / 2.0), vec3(WALL, HEIGHT, -front_edge)), .color = shell, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(LEFT_WALL_X, (HEIGHT + DOOR_HEIGHT) / 2.0, DOOR_CENTER_Z), vec3(WALL, HEIGHT - DOOR_HEIGHT, DOOR_WIDTH)), .color = shell },

            .{ .shape = self.cube, .model = box(vec3(inner_x + 0.06, DOOR_HEIGHT / 2.0, back_edge - trim / 2.0), vec3(0.12, DOOR_HEIGHT, trim)), .color = frame_color },
            .{ .shape = self.cube, .model = box(vec3(inner_x + 0.06, DOOR_HEIGHT / 2.0, front_edge + trim / 2.0), vec3(0.12, DOOR_HEIGHT, trim)), .color = frame_color },
            .{ .shape = self.cube, .model = box(vec3(inner_x + 0.06, DOOR_HEIGHT + trim / 2.0, DOOR_CENTER_Z), vec3(0.12, trim, DOOR_WIDTH + 2.0 * trim)), .color = frame_color },

            .{ .shape = self.cube, .model = box(vec3(outer_x - 0.06, DOOR_HEIGHT / 2.0, back_edge - trim / 2.0), vec3(0.12, DOOR_HEIGHT, trim)), .color = frame_color },
            .{ .shape = self.cube, .model = box(vec3(outer_x - 0.06, DOOR_HEIGHT / 2.0, front_edge + trim / 2.0), vec3(0.12, DOOR_HEIGHT, trim)), .color = frame_color },
            .{ .shape = self.cube, .model = box(vec3(outer_x - 0.06, DOOR_HEIGHT + trim / 2.0, DOOR_CENTER_Z), vec3(0.12, trim, DOOR_WIDTH + 2.0 * trim)), .color = frame_color },
        });
    }

    /// Two ceiling tube fittings in the room centered on `center_x`, running front to
    /// back: each a housing (into `housings`) and its tube (into `tubes`, lit per draw).
    pub fn addCeilingLights(self: PartBuilder, allocator: std.mem.Allocator, housings: *std.ArrayList(Part), tubes: *std.ArrayList(Part), center_x: f32) !void {
        const length = 2.6;
        const back_z = -3.4;
        for ([_]f32{ -1.8, 1.8 }) |offset| {
            const x = center_x + offset;
            try housings.append(allocator, .{ .shape = self.cube, .model = box(vec3(x, HEIGHT - 0.03, back_z + length / 2.0), vec3(0.22, 0.06, length + 0.1)), .color = grey(0.45) });
            try tubes.append(allocator, .{ .shape = self.cylinder, .model = cylinderModel(vec3(x, HEIGHT - 0.1, back_z), .z, 0.07, length), .color = grey(0.7) });
        }
    }

    /// The control console against the right wall: a desk, an upright panel on the wall,
    /// three buttons (the red one stops the alarm), and a lever.
    pub fn addConsole(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const wall_x = WIDTH / 2.0;
        const center_z = -2.0;
        const desk_height = 0.9;
        const button = vec3(0.14, 0.06, 0.14);
        const button_x = wall_x - 0.55;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(wall_x - 0.4, desk_height / 2.0, center_z), vec3(0.8, desk_height, 1.8)), .color = grey(0.5) },
            .{ .shape = self.cube, .model = box(vec3(wall_x - 0.08, 1.55, center_z), vec3(0.16, 1.1, 1.8)), .color = grey(0.42) },
            .{ .shape = self.cube, .model = box(vec3(wall_x - 0.17, 1.6, center_z), vec3(0.02, 0.6, 1.2)), .color = grey(0.75), .emissive = 0.25 },
            .{ .shape = self.cube, .model = box(vec3(button_x, desk_height, center_z - 0.5), button), .color = grey(0.75) },
            .{ .shape = self.cube, .model = box(vec3(button_x, desk_height, center_z), button), .color = grey(0.75) },
            .{ .shape = self.cube, .model = box(vec3(button_x, desk_height, center_z + 0.5), button), .color = vec4(0.6, 0.02, 0.02, 1.0) },
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(wall_x - 0.3, desk_height, center_z + 0.75), .y, 0.05, 0.4), .color = grey(0.25) },
        });
    }

    /// Gauges on the left, a screen in the middle, a breaker box on the right, where the
    /// model's two-bay cabinets for them are.
    pub fn addBackPanels(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const wall_z = -DEPTH;
        const panel_size = vec3(1.4, 1.5, 0.12);
        const panel_y = 1.45;
        const panel_color = grey(0.48);
        const detail_color = grey(0.3);
        const front_z = wall_z + panel_size.z;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(-2.4, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },
            .{ .shape = self.cube, .model = box(vec3(0.0, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },
            .{ .shape = self.cube, .model = box(vec3(2.4, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },

            .{ .shape = self.cylinder, .model = cylinderModel(vec3(-2.75, 1.75, front_z), .z, 0.45, 0.05), .color = grey(0.8) },
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(-2.05, 1.75, front_z), .z, 0.45, 0.05), .color = grey(0.8) },
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(-2.4, 1.1, front_z), .z, 0.55, 0.05), .color = grey(0.8) },

            .{ .shape = self.cube, .model = box(vec3(0.0, 1.55, front_z + 0.01), vec3(1.1, 0.8, 0.02)), .color = grey(0.7), .emissive = 0.3 },
            .{ .shape = self.cube, .model = box(vec3(0.0, 0.95, front_z + 0.02), vec3(0.9, 0.12, 0.04)), .color = detail_color },

            .{ .shape = self.cube, .model = box(vec3(2.4, panel_y, front_z + 0.02), vec3(1.1, 1.2, 0.04)), .color = grey(0.4) },
            .{ .shape = self.cube, .model = box(vec3(2.85, panel_y, front_z + 0.06), vec3(0.06, 0.25, 0.06)), .color = detail_color },
        });
    }

    /// Two pipes along the back wall under the ceiling.
    pub fn addPipes(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const start_x = -WIDTH / 2.0;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(start_x, 2.75, -DEPTH + 0.5), .x, 0.18, WIDTH), .color = grey(0.4) },
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(start_x, 2.5, -DEPTH + 0.3), .x, 0.12, WIDTH), .color = grey(0.35) },
        });
    }
};

pub fn bounds(min: Vec3, max: Vec3) AABB {
    return .{ .min = min, .max = max };
}

/// A unit cube scaled to `size`, centered at `center`.
pub fn box(center: Vec3, size: Vec3) Mat4 {
    return Mat4.fromTranslation(center).mulMat4(&Mat4.fromScale(size));
}

pub const Axis = enum { x, y, z };

/// The unit cylinder (radius 0.5, y 0..1) as one of `diameter` and `length`, running
/// from `base` along +`axis`.
pub fn cylinderModel(base: Vec3, axis: Axis, diameter: f32, length: f32) Mat4 {
    const quarter_turn = std.math.pi / 2.0;
    const rotation = switch (axis) {
        .x => Mat4.fromRotationZ(-quarter_turn),
        .y => Mat4.Identity,
        .z => Mat4.fromRotationX(quarter_turn),
    };
    const scale = Mat4.fromScale(vec3(diameter, length, diameter));
    return Mat4.fromTranslation(base).mulMat4(&rotation).mulMat4(&scale);
}

/// An opaque grey given in sRGB, as a linear color for the shader.
pub fn grey(srgb: f32) Vec4 {
    const linear = srgbToLinear(srgb);
    return vec4(linear, linear, linear, 1.0);
}
