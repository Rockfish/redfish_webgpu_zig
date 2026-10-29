//! What every room is built and drawn with (plan 022, phase B), as
//! `the-station/blender/room_kit.py` is for the rooms' Blender scripts: the room grid,
//! door sizes, parts (`Part`, `PartBuilder`, `box`, `grey`), and the shell of any room
//! (`Shell`: floor, ceiling, walls, doorways, a hole in the floor, the deck below).
//!
//! Room layout, 1 unit = 1 m: x runs left to right across a room, y up from the floor,
//! z out of the room toward the camera. A room's inside spans y 0..height and
//! z -DEPTH..0; the front (z = 0) is open. The shell is WALL thick, and its faces at
//! z = 0 are the cut through the station, drawn dark.
//!
//! The room grid: rooms are whole cells, 2.8 m wide and 3.4 m high wall center to wall
//! center, so a room `w` cells wide is `w * 2.8 - WALL` wide inside. Room 01 is 3 x 1.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const AABB = core.AABB;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const srgbToLinear = core.colors.srgbToLinear;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

/// A cell of the room grid, wall center to wall center.
pub const CELL_WIDTH = 2.8;
pub const CELL_HEIGHT = 3.4;
/// Every room's depth, from the back wall to the open front.
pub const DEPTH: f32 = 4.0;
pub const WALL: f32 = 0.4;

/// A doorway in a side wall: where it is along the wall, and its size.
pub const DOOR_CENTER_Z: f32 = -2.2;
pub const DOOR_WIDTH: f32 = 1.2;
pub const DOOR_HEIGHT: f32 = 2.2;

/// The deck below, not explored yet: solid under the floor, drawn as a cut.
pub const BELOW_DEPTH: f32 = 3.0;
pub const BELOW_COLOR_SRGB: f32 = 0.35;

/// Facing directions for stand points: the robot's yaw, 0 toward the camera (+z).
pub const FACE_LEFT_WALL = -std.math.pi / 2.0;
pub const FACE_RIGHT_WALL = std.math.pi / 2.0;
pub const FACE_BACK_WALL = std.math.pi;

/// The inside width of a room `cells` cells wide.
pub fn insideWidth(comptime cells: comptime_int) f32 {
    return cells * CELL_WIDTH - WALL;
}

/// The inside height of a room `cells` cells high.
pub fn insideHeight(comptime cells: comptime_int) f32 {
    return cells * CELL_HEIGHT - WALL;
}

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

pub fn drawPart(frame: *const Frame, shader: *const Shader, part: Part, hatching: Hatching) void {
    var uniforms = DrawUniforms.init(part.model, part.color);
    uniforms.params = vec4(part.emissive, if (part.is_cut) 1.0 else 0.0, hatching.strength, hatching.spacing);
    part.shape.draw(frame, shader, uniforms);
}

/// A room's shell, from which `PartBuilder.addShell` builds its parts.
pub const Shell = struct {
    /// The room's middle on x.
    center_x: f32,
    /// Inside width and height.
    width: f32,
    height: f32,
    left: Side,
    right: Side,
    /// A hole in the floor and a shaft below it through the deck below.
    hole: ?Hole = null,

    fn innerMinX(self: Shell) f32 {
        return self.center_x - self.width / 2.0;
    }

    fn innerMaxX(self: Shell) f32 {
        return self.center_x + self.width / 2.0;
    }
};

/// A side wall: built by the room (solid, or with a doorway), or by the room next to it.
pub const Side = union(enum) {
    solid,
    doorway: Doorway,
    /// The room next door builds the wall; the floor, ceiling, and back wall stop at it.
    neighbor,
};

pub const Doorway = struct {
    /// The door in it: none built with the wall (a door drawn on its own, as Room 01's
    /// sliding door), or shut for good.
    door: enum { separate, locked },
    /// A frame on the far side too, where a room is beyond.
    is_framed_outside: bool,
};

/// A hole in the floor, in world x and z.
pub const Hole = struct {
    min_x: f32,
    max_x: f32,
    min_z: f32,
    max_z: f32,
};

/// The two shapes every part is drawn with, and the shell and fittings any room has.
pub const PartBuilder = struct {
    cube: *Shape,
    cylinder: *Shape,

    /// Floor, ceiling, back wall, the side walls the room builds, and the deck below as a
    /// solid cut. Floor, ceiling, and back wall run under, over, and behind the side walls,
    /// so the cut reads as one frame. With a hole, the floor and the deck below are four
    /// pieces around it and the shaft has a dark bottom.
    pub fn addShell(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part), shell: Shell) !void {
        const left = if (shell.left == .neighbor) shell.innerMinX() else shell.innerMinX() - WALL;
        const right = if (shell.right == .neighbor) shell.innerMaxX() else shell.innerMaxX() + WALL;
        const width = right - left;
        const middle = (left + right) / 2.0;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(middle, shell.height + WALL / 2.0, -DEPTH / 2.0), vec3(width, WALL, DEPTH)), .color = grey(0.55), .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(middle, shell.height / 2.0, -DEPTH - WALL / 2.0), vec3(width, shell.height + 2.0 * WALL, WALL)), .color = grey(0.6) },
        });
        try self.addSide(allocator, parts, shell, shell.left, shell.innerMinX(), 1.0);
        try self.addSide(allocator, parts, shell, shell.right, shell.innerMaxX(), -1.0);

        const floor_y = -WALL / 2.0;
        const floor_color = grey(0.46);
        const below_y = -WALL - BELOW_DEPTH / 2.0;
        const below_color = grey(BELOW_COLOR_SRGB);
        const hole = shell.hole orelse {
            try parts.appendSlice(allocator, &.{
                .{ .shape = self.cube, .model = box(vec3(middle, floor_y, -DEPTH / 2.0), vec3(width, WALL, DEPTH)), .color = floor_color, .is_cut = true },
                .{ .shape = self.cube, .model = box(vec3(middle, below_y, -(DEPTH + WALL) / 2.0), vec3(width, BELOW_DEPTH, DEPTH + WALL)), .color = below_color, .is_cut = true },
            });
            return;
        };
        try self.addAroundHole(allocator, parts, left, right, -DEPTH, floor_y, WALL, floor_color, hole);
        try self.addAroundHole(allocator, parts, left, right, -DEPTH - WALL, below_y, BELOW_DEPTH, below_color, hole);

        const shaft_bottom_y = -WALL - BELOW_DEPTH - 0.05;
        const hole_center = vec3((hole.min_x + hole.max_x) / 2.0, shaft_bottom_y, (hole.min_z + hole.max_z) / 2.0);
        try parts.append(allocator, .{ .shape = self.cube, .model = box(hole_center, vec3(hole.max_x - hole.min_x, 0.1, hole.max_z - hole.min_z)), .color = grey(0.12) });
    }

    /// Two ceiling tube fittings in the room centered on `center_x`, running front to
    /// back: each a housing (into `housings`) and its tube (into `tubes`, lit per draw).
    pub fn addCeilingLights(
        self: PartBuilder,
        allocator: std.mem.Allocator,
        housings: *std.ArrayList(Part),
        tubes: *std.ArrayList(Part),
        center_x: f32,
        height: f32,
    ) !void {
        const length = 2.6;
        const back_z = -3.4;
        for ([_]f32{ -1.8, 1.8 }) |offset| {
            const x = center_x + offset;
            try housings.append(allocator, .{ .shape = self.cube, .model = box(vec3(x, height - 0.03, back_z + length / 2.0), vec3(0.22, 0.06, length + 0.1)), .color = grey(0.45) });
            try tubes.append(allocator, .{ .shape = self.cylinder, .model = cylinderModel(vec3(x, height - 0.1, back_z), .z, 0.07, length), .color = grey(0.7) });
        }
    }

    /// A side wall whose inside face is at `inner_x`; `inward` is +1 for the left wall
    /// (the room is toward +x), -1 for the right.
    fn addSide(
        self: PartBuilder,
        allocator: std.mem.Allocator,
        parts: *std.ArrayList(Part),
        shell: Shell,
        side: Side,
        inner_x: f32,
        inward: f32,
    ) !void {
        const wall_x = inner_x - inward * WALL / 2.0;
        switch (side) {
            .neighbor => {},
            .solid => try parts.append(allocator, .{ .shape = self.cube, .model = box(vec3(wall_x, shell.height / 2.0, -DEPTH / 2.0), vec3(WALL, shell.height, DEPTH)), .color = grey(0.55), .is_cut = true }),
            .doorway => |doorway| try self.addDoorway(allocator, parts, shell.height, doorway, inner_x, inward),
        }
    }

    /// The wall in three pieces around the doorway (behind it, in front of it, above it),
    /// a frame of two posts and a lintel inside, and outside too if framed there.
    fn addDoorway(
        self: PartBuilder,
        allocator: std.mem.Allocator,
        parts: *std.ArrayList(Part),
        height: f32,
        doorway: Doorway,
        inner_x: f32,
        inward: f32,
    ) !void {
        const wall_x = inner_x - inward * WALL / 2.0;
        const shell = grey(0.55);
        const back_edge = DOOR_CENTER_Z - DOOR_WIDTH / 2.0;
        const front_edge = DOOR_CENTER_Z + DOOR_WIDTH / 2.0;
        const behind_depth = DEPTH + back_edge;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(wall_x, height / 2.0, -DEPTH + behind_depth / 2.0), vec3(WALL, height, behind_depth)), .color = shell, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(wall_x, height / 2.0, front_edge / 2.0), vec3(WALL, height, -front_edge)), .color = shell, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3(wall_x, (height + DOOR_HEIGHT) / 2.0, DOOR_CENTER_Z), vec3(WALL, height - DOOR_HEIGHT, DOOR_WIDTH)), .color = shell },
        });
        switch (doorway.door) {
            .separate => {},
            .locked => try parts.append(allocator, .{ .shape = self.cube, .model = box(vec3(wall_x, DOOR_HEIGHT / 2.0, DOOR_CENTER_Z), vec3(0.08, DOOR_HEIGHT, DOOR_WIDTH)), .color = grey(0.4) }),
        }

        try self.addDoorFrame(allocator, parts, inner_x + inward * 0.06);
        if (doorway.is_framed_outside) {
            try self.addDoorFrame(allocator, parts, inner_x - inward * (WALL + 0.06));
        }
    }

    /// Two posts and a lintel around the doorway, centered on `x`.
    fn addDoorFrame(self: PartBuilder, allocator: std.mem.Allocator, parts: *std.ArrayList(Part), x: f32) !void {
        const trim = 0.14;
        const color = grey(0.3);
        const back_edge = DOOR_CENTER_Z - DOOR_WIDTH / 2.0;
        const front_edge = DOOR_CENTER_Z + DOOR_WIDTH / 2.0;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3(x, DOOR_HEIGHT / 2.0, back_edge - trim / 2.0), vec3(0.12, DOOR_HEIGHT, trim)), .color = color },
            .{ .shape = self.cube, .model = box(vec3(x, DOOR_HEIGHT / 2.0, front_edge + trim / 2.0), vec3(0.12, DOOR_HEIGHT, trim)), .color = color },
            .{ .shape = self.cube, .model = box(vec3(x, DOOR_HEIGHT + trim / 2.0, DOOR_CENTER_Z), vec3(0.12, trim, DOOR_WIDTH + 2.0 * trim)), .color = color },
        });
    }

    /// A slab from `left` to `right` and from `back` to the open front, `thickness` thick
    /// and centered on `y`, in four pieces around the hole; only the front one reaches
    /// the cut.
    fn addAroundHole(
        self: PartBuilder,
        allocator: std.mem.Allocator,
        parts: *std.ArrayList(Part),
        left: f32,
        right: f32,
        back: f32,
        y: f32,
        thickness: f32,
        color: Vec4,
        hole: Hole,
    ) !void {
        const hole_middle_z = (hole.min_z + hole.max_z) / 2.0;
        const hole_depth = hole.max_z - hole.min_z;
        try parts.appendSlice(allocator, &.{
            .{ .shape = self.cube, .model = box(vec3((left + right) / 2.0, y, hole.max_z / 2.0), vec3(right - left, thickness, -hole.max_z)), .color = color, .is_cut = true },
            .{ .shape = self.cube, .model = box(vec3((left + right) / 2.0, y, (back + hole.min_z) / 2.0), vec3(right - left, thickness, hole.min_z - back)), .color = color },
            .{ .shape = self.cube, .model = box(vec3((left + hole.min_x) / 2.0, y, hole_middle_z), vec3(hole.min_x - left, thickness, hole_depth)), .color = color },
            .{ .shape = self.cube, .model = box(vec3((hole.max_x + right) / 2.0, y, hole_middle_z), vec3(right - hole.max_x, thickness, hole_depth)), .color = color },
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

test "room grid: Room 01's 3 x 1 cells are its 8 x 3 m inside" {
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), insideWidth(3), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), insideHeight(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 16.4), insideWidth(6), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.4), insideHeight(2), 1e-5);
}
