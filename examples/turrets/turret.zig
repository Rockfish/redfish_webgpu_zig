//! A two-axis turret built like the bullets example's `Cannon`: parts in a flat,
//! parent-first node array, yaw on the body, pitch on the head, recoil on the barrel. Its
//! behavior is in three parts (plan 008):
//!
//! - Aim: `motion.YawPitchAim` turns the body and head toward a point, each axis at its own
//!   speed.
//! - Pattern: what to aim at. `track` aims at the target, optionally leading it; `sweep`
//!   swings across an arc around the target's bearing or a fixed heading.
//! - Fire control: `core.FireControl` says when a shot goes out; the weapon's
//!   `ShotJitter` spreads the shots.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const Projectiles = @import("projectiles.zig").Projectiles;

const DrawUniforms = core.DrawUniforms;
const FireControl = core.FireControl;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Random = core.Random;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const ShotJitter = core.fire_control.ShotJitter;
const Transform = core.Transform;
const motion = core.motion;
const Quat = math.Quat;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

// Part sizes. Cubes are centered on their origin, cylinders start at their origin and
// extend along +Y, spheres are centered.
const BASE_SIZE = vec3(1.6, 0.4, 1.6);
const BODY_RADIUS: f32 = 0.6;
const BODY_HEIGHT: f32 = 0.5;
const HEAD_RADIUS: f32 = 0.45;
const BARREL_RADIUS: f32 = 0.1;
const BARREL_LENGTH: f32 = 1.4;
/// Tracer size: thin, stretched along its path.
const TRACER_SIZE = vec3(0.08, 0.08, 0.7);
/// How fast the barrel slides back after recoil, per second.
const RECOIL_RECOVERY: f32 = 8.0;

/// Turret parts, one node each, parent-first so one pass computes world transforms. The
/// enum value is the node index and the mesh index.
pub const Part = enum(u32) {
    base, // flat box on the ground
    body, // short cylinder, yaw pivot
    head, // sphere on the body, pitch pivot
    barrel, // long narrow cylinder with its origin at the breech, recoils

    pub const count = @typeInfo(Part).@"enum".fields.len;
};

/// A part's place in the hierarchy. The local transform is relative to the parent's
/// origin, so a pivot is where the parent places the child.
const Node = struct {
    parent: ?Part,
    local_transform: Transform,
    world_transform: Transform = Transform.identity(),
    color: Vec4,
};

/// What the projectiles look like and how they leave the barrel.
pub const Weapon = struct {
    /// Units per second.
    speed: f32,
    jitter: ShotJitter,
    /// How far the barrel kicks back per shot.
    recoil_distance: f32 = 0.25,
    tracer_color: Vec4,
};

/// What the turret aims at over time. Mortar comes in a later phase.
pub const Pattern = union(enum) {
    track: Track,
    sweep: Sweep,

    pub const Track = struct {
        /// Aim where the target will be when the shot gets there.
        lead: bool,
    };

    /// Swing back and forth across an arc, firing a fan of shots.
    pub const Sweep = struct {
        /// The swing: half-width and speed, and where it is now.
        swing: motion.Sweep,
        /// The arc's center: a fixed yaw in radians, or the target's bearing when null.
        center_yaw: ?f32 = null,
        /// A fixed pitch in radians, or the target's pitch when null.
        pitch: ?f32 = null,
    };
};

/// The target as the turrets see it.
pub const TargetState = struct {
    position: Vec3,
    /// Units per second.
    velocity: Vec3,
    radius: f32,
};

/// The meshes every turret draws with, created once.
pub const TurretShapes = struct {
    parts: [Part.count]*Shape,
    tracer: *Shape,

    pub fn init(context: core.Context, gpu: *const GpuContext) !TurretShapes {
        const alloc = context.alloc;
        var parts: [Part.count]*Shape = undefined;
        parts[@intFromEnum(Part.base)] = try core.shapes.createCube(alloc, gpu, .{ .width = BASE_SIZE.x, .height = BASE_SIZE.y, .depth = BASE_SIZE.z });
        parts[@intFromEnum(Part.body)] = try core.shapes.createCylinder(alloc, gpu, BODY_RADIUS, BODY_HEIGHT, 24);
        parts[@intFromEnum(Part.head)] = try core.shapes.createSphere(alloc, gpu, HEAD_RADIUS, 16, 16);
        parts[@intFromEnum(Part.barrel)] = try core.shapes.createCylinder(alloc, gpu, BARREL_RADIUS, BARREL_LENGTH, 12);
        return .{
            .parts = parts,
            .tracer = try core.shapes.createCube(alloc, gpu, .{ .width = TRACER_SIZE.x, .height = TRACER_SIZE.y, .depth = TRACER_SIZE.z }),
        };
    }

    pub fn releaseGpuObjects(self: *TurretShapes) void {
        for (self.parts) |part| {
            part.releaseGpuObjects();
        }
        self.tracer.releaseGpuObjects();
    }
};

pub const Turret = struct {
    /// Where the base sits on the ground. Turrets aren't rotated: the turret's own space is
    /// world space moved to the pivot.
    position: Vec3,
    aim: motion.YawPitchAim,
    fire_control: FireControl,
    weapon: Weapon,
    pattern: Pattern,
    nodes: [Part.count]Node,
    projectiles: Projectiles = .{},
    recoil: f32 = 0.0,
    /// Where the pattern aimed this frame (for the debug lines).
    aim_point: Vec3 = Vec3.Zero,
    /// A sweep's arc this frame, its two ends as points as far out as the target (for the
    /// debug lines); null for other patterns.
    sweep_ends: ?[2]Vec3 = null,

    const Self = @This();

    pub const Config = struct {
        position: Vec3,
        aim: motion.YawPitchAim,
        fire_control: FireControl,
        weapon: Weapon,
        pattern: Pattern,
        /// The body and head's color.
        color: Vec4,
    };

    pub fn init(config: Config) Self {
        var self: Self = .{
            .position = config.position,
            .aim = config.aim,
            .fire_control = config.fire_control,
            .weapon = config.weapon,
            .pattern = config.pattern,
            .nodes = buildNodes(config.color),
        };
        self.updateWorldTransforms();
        return self;
    }

    /// Aims, fires the shots that are due, and moves the shots in flight. `trigger`: the
    /// turret may fire at all.
    pub fn update(self: *Self, dt: f32, target: TargetState, trigger: bool, random: *Random) void {
        self.aim_point = self.patternPoint(target, dt);
        self.aim.aimAt(self.aim_point.sub(self.pivot()));
        self.aim.update(dt);
        self.fire_control.update(dt, trigger, self.aim.aimError());

        self.recoil -= self.recoil * motion.dampAlpha(RECOIL_RECOVERY, dt);
        self.pose();

        // Shots in flight move first: a new shot is placed by its own age
        self.projectiles.update(dt, .{ .position = target.position, .radius = target.radius });
        self.fireDueShots(random);
    }

    /// The head's center: the pitch pivot, and the point the aim is measured from.
    pub fn pivot(self: *const Self) Vec3 {
        return self.nodes[@intFromEnum(Part.head)].world_transform.translation;
    }

    /// The center of the barrel's open end.
    pub fn muzzle(self: *const Self) Vec3 {
        return self.nodes[@intFromEnum(Part.barrel)].world_transform.transformPoint(vec3(0.0, BARREL_LENGTH, 0.0));
    }

    /// Whether the aim is on target by the fire control's tolerance (or a default one,
    /// for `while_turning`), for the debug lines.
    pub fn isOnTarget(self: *const Self) bool {
        const tolerance = switch (self.fire_control.policy) {
            .while_turning => std.math.degreesToRadians(2.0),
            .when_aligned => |when_aligned| when_aligned,
        };
        return self.aim.isAligned(tolerance);
    }

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, shapes: *const TurretShapes) void {
        for (self.nodes, shapes.parts) |node, shape| {
            shape.draw(frame, shader, DrawUniforms.init(node.world_transform.toMatrix(), node.color));
        }
    }

    pub fn drawProjectiles(self: *const Self, frame: *const Frame, shader: *const Shader, shapes: *const TurretShapes) void {
        self.projectiles.draw(frame, shader, shapes.tracer, self.weapon.tracer_color);
    }

    /// Where the pattern aims this frame.
    fn patternPoint(self: *Self, target: TargetState, dt: f32) Vec3 {
        self.sweep_ends = null;
        switch (self.pattern) {
            .track => |track| {
                if (!track.lead) {
                    return target.position;
                }
                return core.ballistics.leadPoint(self.muzzle(), target.position, target.velocity, self.weapon.speed);
            },
            .sweep => |*sweep| return self.sweepPoint(sweep, target, dt),
        }
    }

    /// The sweep's point this frame: the swing's offset from the arc's center, as far out
    /// as the target. Also records the arc's ends.
    fn sweepPoint(self: *Self, sweep: *Pattern.Sweep, target: TargetState, dt: f32) Vec3 {
        const pivot_point = self.pivot();
        const to_target = target.position.sub(pivot_point);
        const bearing = motion.yawPitchOf(to_target);
        const center = sweep.center_yaw orelse bearing.yaw;
        const pitch = sweep.pitch orelse bearing.pitch;
        const reach = to_target.length();

        const offset = sweep.swing.update(dt);
        const half_width = sweep.swing.half_width;
        self.sweep_ends = .{
            pivot_point.add(motion.yawPitchDirection(center - half_width, pitch).mulScalar(reach)),
            pivot_point.add(motion.yawPitchDirection(center + half_width, pitch).mulScalar(reach)),
        };
        return pivot_point.add(motion.yawPitchDirection(center + offset, pitch).mulScalar(reach));
    }

    /// Yaw on the body, pitch on the head, recoil on the barrel; then world transforms.
    fn pose(self: *Self) void {
        self.nodes[@intFromEnum(Part.body)].local_transform.rotation = Quat.fromAxisAngle(Vec3.Y, self.aim.yaw);
        self.nodes[@intFromEnum(Part.head)].local_transform.rotation = Quat.fromAxisAngle(Vec3.X, self.aim.pitch);
        self.nodes[@intFromEnum(Part.barrel)].local_transform = barrelTransform(self.recoil);
        self.updateWorldTransforms();
    }

    /// One parent-first pass; the base composes with the turret's position.
    fn updateWorldTransforms(self: *Self) void {
        const placement = Transform.fromTranslation(self.position);
        for (&self.nodes) |*node| {
            const parent_transform = if (node.parent) |parent| self.nodes[@intFromEnum(parent)].world_transform else placement;
            node.world_transform = parent_transform.composeTransforms(node.local_transform);
        }
    }

    /// Each due shot leaves the muzzle along the aim, spread by the weapon's jitter, and
    /// kicks the barrel back.
    fn fireDueShots(self: *Self, random: *Random) void {
        while (self.fire_control.nextShot()) |age| {
            const shot = self.weapon.jitter.apply(random, self.aim.direction(), self.weapon.speed);
            self.projectiles.spawn(self.muzzle(), shot.direction.mulScalar(shot.speed), age);
            self.recoil = self.weapon.recoil_distance;
        }
    }
};

/// Parts in parent-first order. Translations are offsets from the parent's origin.
fn buildNodes(color: Vec4) [Part.count]Node {
    const dark = vec4(0.18, 0.19, 0.21, 1.0);
    var nodes: [Part.count]Node = undefined;

    // The base's center is half its height up, so it sits on the ground
    nodes[@intFromEnum(Part.base)] = .{
        .parent = null,
        .local_transform = Transform.fromTranslation(vec3(0.0, BASE_SIZE.y * 0.5, 0.0)),
        .color = vec4(0.32, 0.33, 0.36, 1.0),
    };
    // The body's origin is its bottom center, on top of the base; it yaws about it
    nodes[@intFromEnum(Part.body)] = .{
        .parent = .base,
        .local_transform = Transform.fromTranslation(vec3(0.0, BASE_SIZE.y * 0.5, 0.0)),
        .color = color,
    };
    // The head's center is on top of the body; it pitches about it
    nodes[@intFromEnum(Part.head)] = .{
        .parent = .body,
        .local_transform = Transform.fromTranslation(vec3(0.0, BODY_HEIGHT, 0.0)),
        .color = color,
    };
    nodes[@intFromEnum(Part.barrel)] = .{
        .parent = .head,
        .local_transform = barrelTransform(0.0),
        .color = dark,
    };
    return nodes;
}

/// The barrel starts at the head's center and points down -Z (the cylinder is built along
/// +Y, so it's turned -90° about X). Recoil pushes it back along +Z.
fn barrelTransform(recoil: f32) Transform {
    return .{
        .translation = vec3(0.0, 0.0, recoil),
        .rotation = Quat.fromAxisAngle(Vec3.X, -std.math.pi / 2.0),
        .scale = Vec3.One,
    };
}
