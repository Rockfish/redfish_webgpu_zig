//! Room 01, the control room, as a greybox of boxes and cylinders (plan 021, phase A).
//!
//! World layout, 1 unit = 1 m: x runs left to right across the room, y up from the
//! floor, z out of the room toward the camera. The room's inside spans
//! x -WIDTH/2..WIDTH/2, y 0..HEIGHT, z -DEPTH..0; the front (z = 0) is open. The shell
//! (floor, ceiling, walls) is WALL thick, and its faces at z = 0 are the cut through the
//! station, drawn dark.
//!
//! Left wall: the door. Right wall: the control console. Back wall: three panels (gauges,
//! a screen, a breaker box) and the alarm lamp above the middle one.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const srgbToLinear = core.colors.srgbToLinear;
const Framing = @import("room_camera.zig").Framing;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

pub const WIDTH: f32 = 8.0;
pub const HEIGHT: f32 = 3.0;
pub const DEPTH: f32 = 4.0;
pub const WALL: f32 = 0.4;

/// Space shown around the shell's cut edges.
const FRAME_MARGIN: f32 = 0.3;

/// Where the alarm lamp is, on the back wall above the screen panel.
pub const ALARM_LAMP_POSITION = vec3(0.0, 2.7, -DEPTH + 0.12);
/// Where the alarm's light comes from: a little in front of the lamp, so the back wall
/// around it is lit too.
pub const ALARM_LIGHT_POSITION = vec3(0.0, 2.5, -DEPTH + 0.8);
const ALARM_RED = vec3(1.0, 0.04, 0.02);

/// One box or cylinder of the room.
const Part = struct {
    shape: *Shape,
    model: Mat4,
    color: Vec4,
    /// 0..1: how much the color shows unlit (lamps, screens).
    emissive: f32 = 0.0,
    /// A shell part: its faces toward the camera are the cut, drawn dark.
    is_cut: bool = false,
};

pub const Room = struct {
    cube: *Shape,
    cylinder: *Shape,
    parts: []Part,
    /// The alarm lamp, drawn after the parts with its glow.
    alarm_lamp: Part,

    const Self = @This();

    pub fn init(context: core.Context, gpu: *const GpuContext) !Self {
        const cube = try core.shapes.createCube(context.alloc, gpu, .{});
        const cylinder = try core.shapes.createCylinder(context.alloc, gpu, 0.5, 1.0, 24);

        var parts: std.ArrayList(Part) = .empty;
        const builder: PartBuilder = .{ .cube = cube, .cylinder = cylinder };
        try builder.addShell(context.alloc, &parts);
        try builder.addDoor(context.alloc, &parts);
        try builder.addConsole(context.alloc, &parts);
        try builder.addBackPanels(context.alloc, &parts);
        try builder.addPipes(context.alloc, &parts);
        try builder.addScaleFigure(context.alloc, &parts);

        return .{
            .cube = cube,
            .cylinder = cylinder,
            .parts = try parts.toOwnedSlice(context.alloc),
            .alarm_lamp = .{
                .shape = cylinder,
                .model = cylinderModel(ALARM_LAMP_POSITION.sub(vec3(0.0, 0.0, 0.1)), .z, 0.3, 0.2),
                .color = vec4(ALARM_RED.x, ALARM_RED.y, ALARM_RED.z, 1.0),
            },
        };
    }

    /// The opening and the cut edges around it, for the camera to frame.
    pub fn framing() Framing {
        return .{
            .center_x = 0.0,
            .center_y = HEIGHT / 2.0,
            .half_width = WIDTH / 2.0 + WALL + FRAME_MARGIN,
            .half_height = HEIGHT / 2.0 + WALL + FRAME_MARGIN,
        };
    }

    /// `alarm_glow` 0..1: how lit the lamp is (0 is a dark red lamp).
    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, alarm_glow: f32) void {
        for (self.parts) |part| {
            drawPart(frame, shader, part);
        }

        var lamp = self.alarm_lamp;
        lamp.emissive = alarm_glow;
        drawPart(frame, shader, lamp);
    }

    pub fn releaseGpuObjects(self: *const Self) void {
        self.cube.releaseGpuObjects();
        self.cylinder.releaseGpuObjects();
    }
};

/// Light falling on the room from the alarm, for point light `SceneLights.setPointLight`.
pub fn alarmLightColor(intensity: f32) Vec3 {
    return ALARM_RED.mulScalar(intensity);
}

fn drawPart(frame: *const Frame, shader: *const Shader, part: Part) void {
    var uniforms = DrawUniforms.init(part.model, part.color);
    uniforms.params = vec4(part.emissive, if (part.is_cut) 1.0 else 0.0, 0.0, 0.0);
    part.shape.draw(frame, shader, uniforms);
}

/// Adds the room's parts, one group per function.
const PartBuilder = struct {
    cube: *Shape,
    cylinder: *Shape,

    /// Floor, ceiling, and walls. Floor and ceiling run under and over the side walls, so
    /// the cut reads as one frame.
    fn addShell(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const outer_width = WIDTH + 2.0 * WALL;
        const shell = grey(0.55);
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(0.0, -WALL / 2.0, -DEPTH / 2.0), vec3(outer_width, WALL, DEPTH)), .color = grey(0.46), .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(0.0, HEIGHT + WALL / 2.0, -DEPTH / 2.0), vec3(outer_width, WALL, DEPTH)), .color = shell, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(0.0, HEIGHT / 2.0, -DEPTH - WALL / 2.0), vec3(outer_width, HEIGHT + 2.0 * WALL, WALL)), .color = grey(0.6) },
            .{ .shape = self.cube, .model = box(vec3(-(WIDTH + WALL) / 2.0, HEIGHT / 2.0, -DEPTH / 2.0), vec3(WALL, HEIGHT, DEPTH)), .color = shell, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3((WIDTH + WALL) / 2.0, HEIGHT / 2.0, -DEPTH / 2.0), vec3(WALL, HEIGHT, DEPTH)), .color = shell, .is_cut = true },
        });
    }

    /// A closed door in the left wall: a frame of two posts and a lintel around the leaf.
    fn addDoor(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const wall_x = -WIDTH / 2.0;
        const center_z = -2.2;
        const door_width = 1.2;
        const door_height = 2.2;
        const trim = 0.14;
        const frame_color = grey(0.3);
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(wall_x + 0.03, door_height / 2.0, center_z), vec3(0.06, door_height, door_width)), .color = grey(0.4) },
            .{ .shape = self.cube, .model = box(vec3(wall_x + 0.06, door_height / 2.0, center_z - (door_width + trim) / 2.0), vec3(0.12, door_height, trim)), .color = frame_color },
            .{ .shape = self.cube, .model = box(vec3(wall_x + 0.06, door_height / 2.0, center_z + (door_width + trim) / 2.0), vec3(0.12, door_height, trim)), .color = frame_color },
            .{ .shape = self.cube, .model = box(vec3(wall_x + 0.06, door_height + trim / 2.0, center_z), vec3(0.12, trim, door_width + 2.0 * trim)), .color = frame_color },
        });
    }

    /// The control console against the right wall: a desk, an upright panel on the wall,
    /// three buttons (the red one stops the alarm), and a lever.
    fn addConsole(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
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

    /// Gauges on the left, a screen in the middle, a breaker box on the right.
    fn addBackPanels(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const wall_z = -DEPTH;
        const panel_size = vec3(1.4, 1.5, 0.12);
        const panel_y = 1.45;
        const panel_color = grey(0.48);
        const detail_color = grey(0.3);
        const front_z = wall_z + panel_size.z;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(-2.3, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },
            .{ .shape = self.cube, .model = box(vec3(0.0, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },
            .{ .shape = self.cube, .model = box(vec3(2.3, panel_y, wall_z + panel_size.z / 2.0), panel_size), .color = panel_color },

            .{ .shape = self.cylinder, .model = cylinderModel(vec3(-2.65, 1.75, front_z), .z, 0.45, 0.05), .color = grey(0.8) },
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(-1.95, 1.75, front_z), .z, 0.45, 0.05), .color = grey(0.8) },
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(-2.3, 1.1, front_z), .z, 0.55, 0.05), .color = grey(0.8) },

            .{ .shape = self.cube, .model = box(vec3(0.0, 1.55, front_z + 0.01), vec3(1.1, 0.8, 0.02)), .color = grey(0.7), .emissive = 0.3 },
            .{ .shape = self.cube, .model = box(vec3(0.0, 0.95, front_z + 0.02), vec3(0.9, 0.12, 0.04)), .color = detail_color },

            .{ .shape = self.cube, .model = box(vec3(2.3, panel_y, front_z + 0.02), vec3(1.1, 1.2, 0.04)), .color = grey(0.4) },
            .{ .shape = self.cube, .model = box(vec3(2.75, panel_y, front_z + 0.06), vec3(0.06, 0.25, 0.06)), .color = detail_color },
        });
    }

    /// Two pipes along the back wall under the ceiling.
    fn addPipes(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const start_x = -WIDTH / 2.0;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(start_x, 2.75, -DEPTH + 0.5), .x, 0.18, WIDTH), .color = grey(0.4) },
            .{ .shape = self.cylinder, .model = cylinderModel(vec3(start_x, 2.5, -DEPTH + 0.3), .x, 0.12, WIDTH), .color = grey(0.35) },
        });
    }

    /// A 1.2 m stand-in for the robot (head, body, legs), to judge scale; replaced by the
    /// placeholder robot in phase B.
    fn addScaleFigure(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part)) !void {
        const position = vec3(-0.8, 0.0, -1.6);
        const color = grey(0.72);
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(position.add(vec3(-0.12, 0.3, 0.0)), vec3(0.08, 0.6, 0.08)), .color = grey(0.35) },
            .{ .shape = self.cube, .model = box(position.add(vec3(0.12, 0.3, 0.0)), vec3(0.08, 0.6, 0.08)), .color = grey(0.35) },
            .{ .shape = self.cube, .model = box(position.add(vec3(0.0, 0.82, 0.0)), vec3(0.5, 0.45, 0.38)), .color = color },
            .{ .shape = self.cube, .model = box(position.add(vec3(0.0, 1.06, 0.0)), vec3(0.08, 0.06, 0.08)), .color = grey(0.35) },
            .{ .shape = self.cube, .model = box(position.add(vec3(0.0, 1.2, 0.0)), vec3(0.46, 0.3, 0.34)), .color = color },
        });
    }
};

/// A unit cube scaled to `size`, centered at `center`.
fn box(center: Vec3, size: Vec3) Mat4 {
    return Mat4.fromTranslation(center).mulMat4(&Mat4.fromScale(size));
}

const Axis = enum { x, y, z };

/// The unit cylinder (radius 0.5, y 0..1) as one of `diameter` and `length`, running
/// from `base` along +`axis`.
fn cylinderModel(base: Vec3, axis: Axis, diameter: f32, length: f32) Mat4 {
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
fn grey(srgb: f32) Vec4 {
    const linear = srgbToLinear(srgb);
    return vec4(linear, linear, linear, 1.0);
}
