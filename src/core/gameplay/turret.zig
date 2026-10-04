//! A two-axis turret built like the bullets example's `Cannon`: parts in a flat,
//! parent-first node array, yaw on the body, pitch on the head, recoil on the barrel. Its
//! behavior is in three parts (plan 008):
//!
//! - Aim: `motion.YawPitchAim` turns the body and head toward a point, each axis at its own
//!   speed.
//! - Pattern: what to aim at. `track` aims at the target, optionally leading it; `sweep`
//!   swings across an arc around the target's bearing or a fixed heading; `mortar` lobs a
//!   shell that gets to the target in a fixed flight time.
//! - Fire control: `core.gameplay.FireControl` says when a shot goes out; the weapon's
//!   `ShotJitter` spreads the shots.
//!
//! Track and sweep fire tracers; the mortar fires finned rockets that explode. A `Program`
//! runs patterns one after another (sweep for 3 s, two mortar rounds, wait 1 s, repeat),
//! each step with its own fire settings if it needs them.

const std = @import("std");
const math = @import("math");

const Explosions = @import("explosions.zig").Explosions;
const bindings = @import("../bindings.zig");
const gpu_context = @import("../gpu_context.zig");
const shapes_module = @import("../shapes/root.zig");
const Context = @import("../context.zig").Context;
const projectiles = @import("projectiles.zig");

const DrawUniforms = bindings.DrawUniforms;
const Projectiles = projectiles.Projectiles;
const ProjectilePart = projectiles.Part;
const FireControl = @import("fire_control.zig").FireControl;
const Frame = gpu_context.Frame;
const GpuContext = gpu_context.GpuContext;
const Random = @import("../random.zig").Random;
const Shader = @import("../shader.zig").Shader;
const Shape = shapes_module.Shape;
const ShotJitter = @import("fire_control.zig").ShotJitter;
const Transform = @import("../transform.zig").Transform;
const ballistics = @import("ballistics.zig");
const motion = @import("../motion.zig");
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

// Part sizes. Cubes are centered on their origin, cylinders start at their origin and
// extend along +Y, spheres are centered.
pub const BASE_SIZE = vec3(1.6, 0.4, 1.6);
const BODY_RADIUS: f32 = 0.6;
const BODY_HEIGHT: f32 = 0.5;
const HEAD_RADIUS: f32 = 0.45;
const BARREL_RADIUS: f32 = 0.1;
pub const BARREL_LENGTH: f32 = 1.4;
/// The ball turret's pedestal, on a base like the others.
pub const PEDESTAL_RADIUS: f32 = 0.25;
pub const PEDESTAL_HEIGHT: f32 = 1.2;
/// Tracer size: thin, stretched along its path.
const TRACER_SIZE = vec3(0.08, 0.08, 0.7);
/// Seconds a tracer flies before it's dropped.
const TRACER_LIFETIME: f32 = 3.0;
// Rocket sizes: a body along -Z, a stretched sphere for a nose, two crossed fins at the
// tail.
const ROCKET_RADIUS: f32 = 0.1;
const ROCKET_LENGTH: f32 = 0.7;
const ROCKET_NOSE_STRETCH: f32 = 2.2;
const FIN_SIZE = vec3(0.5, 0.02, 0.2);
/// Down, units per second squared.
pub const GRAVITY = vec3(0.0, -9.8, 0.0);
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
    /// A mortar shell's blast.
    blast_radius: f32 = 2.0,
    /// A mortar shell's spin about its nose, radians per second.
    shell_spin: f32 = 0.0,
    shell_color: Vec4 = vec4(0.35, 0.38, 0.3, 1.0),
};

/// What the turret aims at over time.
pub const Pattern = union(enum) {
    track: Track,
    sweep: Sweep,
    mortar: Mortar,
    /// Hold the aim and fire nothing.
    wait,

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

    /// Lob a shell that gets to the target in `flight_time` seconds
    /// (`ballistics.launchVelocity`): every lob hangs in the air the same time; longer is
    /// a higher arc. The shell's fuse is the flight time, so it bursts at the target, in
    /// the air or on the ground.
    pub const Mortar = struct {
        flight_time: f32,
        /// Aim where the target will be after the flight time, following its curve.
        lead: bool,
    };
};

/// A kind of turret, as configuration (see turret_types.zig).
pub const TurretType = struct {
    name: [:0]const u8,
    /// The body and head's color.
    color: Vec4,
    /// Slew style and speeds, pitch and yaw limits.
    aim: motion.YawPitchAim,
    fire: FireSettings,
    weapon: Weapon,
    pattern: Pattern,
    /// Runs instead of `pattern` from the start, when set.
    program: ?[]const Step = null,
};

/// When a fire control's policy and cadence change together: per turret type, or per
/// program step.
pub const FireSettings = struct {
    policy: FireControl.Policy,
    cadence: FireControl.Cadence,
};

/// One step of a `Program`: a pattern, until a time is up or a number of shots is fired.
pub const Step = struct {
    pattern: Pattern,
    /// The step's fire settings; null keeps the turret's.
    fire: ?FireSettings = null,
    until: Until,

    pub const Until = union(enum) {
        seconds: f32,
        shots: u32,
    };
};

/// Patterns one after another, repeating. The steps belong to the caller (usually a
/// constant in a turret type); each starts from its own pattern as written, so a sweep
/// starts at its center every time.
pub const Program = struct {
    steps: []const Step,
    /// The step running now.
    index: usize = 0,
    /// Seconds into this step.
    elapsed: f32 = 0.0,
    /// Shots fired in this step.
    shots: u32 = 0,

    /// True when the step running now is done.
    fn isStepDone(self: *const Program) bool {
        return switch (self.steps[self.index].until) {
            .seconds => |seconds| self.elapsed >= seconds,
            .shots => |shots| self.shots >= shots,
        };
    }
};

/// The target as the turrets see it.
pub const TargetState = struct {
    position: Vec3,
    /// Units per second.
    velocity: Vec3,
    /// Units per second squared: how the velocity turns along a curved route.
    acceleration: Vec3,
    radius: f32,
};

/// The meshes every turret draws with, created once.
pub const TurretShapes = struct {
    parts: [Part.count]*Shape,
    tracer: *Shape,
    rocket_body: *Shape,
    rocket_nose: *Shape,
    rocket_fin: *Shape,
    pedestal: *Shape,

    pub fn init(context: Context, gpu: *const GpuContext) !TurretShapes {
        const alloc = context.alloc;
        var parts: [Part.count]*Shape = undefined;
        parts[@intFromEnum(Part.base)] = try shapes_module.createCube(alloc, gpu, .{ .width = BASE_SIZE.x, .height = BASE_SIZE.y, .depth = BASE_SIZE.z });
        parts[@intFromEnum(Part.body)] = try shapes_module.createCylinder(alloc, gpu, BODY_RADIUS, BODY_HEIGHT, 24);
        parts[@intFromEnum(Part.head)] = try shapes_module.createSphere(alloc, gpu, HEAD_RADIUS, 16, 16);
        parts[@intFromEnum(Part.barrel)] = try shapes_module.createCylinder(alloc, gpu, BARREL_RADIUS, BARREL_LENGTH, 12);
        return .{
            .parts = parts,
            .tracer = try shapes_module.createCube(alloc, gpu, .{ .width = TRACER_SIZE.x, .height = TRACER_SIZE.y, .depth = TRACER_SIZE.z }),
            .rocket_body = try shapes_module.createCylinder(alloc, gpu, ROCKET_RADIUS, ROCKET_LENGTH, 12),
            .rocket_nose = try shapes_module.createSphere(alloc, gpu, ROCKET_RADIUS, 12, 12),
            .rocket_fin = try shapes_module.createCube(alloc, gpu, .{ .width = FIN_SIZE.x, .height = FIN_SIZE.y, .depth = FIN_SIZE.z }),
            .pedestal = try shapes_module.createCylinder(alloc, gpu, PEDESTAL_RADIUS, PEDESTAL_HEIGHT, 16),
        };
    }

    /// A finned rocket in its own space, nose down -Z, centered on its middle.
    fn rocketParts(self: *const TurretShapes, color: Vec4) [4]ProjectilePart {
        const half_length = ROCKET_LENGTH * 0.5;
        const fin_offset = Mat4.fromTranslation(vec3(0.0, 0.0, half_length - FIN_SIZE.z * 0.5));
        const fin_color = color.lerp(vec4(0.6, 0.1, 0.08, 1.0), 0.6);
        return .{
            // The cylinder is built along +Y from its base: turned to -Z, from the tail
            .{
                .shape = self.rocket_body,
                .model = Mat4.fromTranslation(vec3(0.0, 0.0, half_length)).mulMat4(&Mat4.fromRotationX(-std.math.pi / 2.0)),
                .color = color,
            },
            .{
                .shape = self.rocket_nose,
                .model = Mat4.fromTranslation(vec3(0.0, 0.0, -half_length)).mulMat4(&Mat4.fromScale(vec3(1.0, 1.0, ROCKET_NOSE_STRETCH))),
                .color = color,
            },
            .{ .shape = self.rocket_fin, .model = fin_offset, .color = fin_color },
            .{ .shape = self.rocket_fin, .model = fin_offset.mulMat4(&Mat4.fromRotationZ(std.math.pi / 2.0)), .color = fin_color },
        };
    }

    pub fn releaseGpuObjects(self: *TurretShapes) void {
        for (self.parts) |part| {
            part.releaseGpuObjects();
        }
        self.tracer.releaseGpuObjects();
        self.rocket_body.releaseGpuObjects();
        self.rocket_nose.releaseGpuObjects();
        self.rocket_fin.releaseGpuObjects();
        self.pedestal.releaseGpuObjects();
    }
};

pub const Turret = struct {
    /// Where the base sits on the ground. Turrets aren't rotated: the turret's own space is
    /// world space moved to the pivot.
    position: Vec3,
    /// Scale of the whole turret (1: a 1.6 m wide base); its shots keep their speed.
    size: f32,
    aim: motion.YawPitchAim,
    fire_control: FireControl,
    weapon: Weapon,
    pattern: Pattern,
    nodes: [Part.count]Node,
    tracers: Projectiles = .{},
    shells: Projectiles = .{ .gravity = GRAVITY },
    recoil: f32 = 0.0,
    /// Where the pattern aimed this frame (for the debug lines).
    aim_point: Vec3 = Vec3.Zero,
    /// A mortar's launch velocity this frame (for firing and the predicted arc); null for
    /// other patterns.
    launch_velocity: ?Vec3 = null,
    /// When set, the program picks the pattern (and fire settings) step by step.
    program: ?Program = null,
    /// A sweep's arc this frame, its two ends as points as far out as the target (for the
    /// debug lines); null for other patterns.
    sweep_ends: ?[2]Vec3 = null,

    const Self = @This();

    /// A turret of `turret_type` and `size` standing at `position`; it starts its program
    /// if the type has one.
    pub fn init(turret_type: TurretType, position: Vec3, size: f32) Self {
        var self: Self = .{
            .position = position,
            .size = size,
            .aim = turret_type.aim,
            .fire_control = .{ .policy = turret_type.fire.policy, .cadence = turret_type.fire.cadence },
            .weapon = turret_type.weapon,
            .pattern = turret_type.pattern,
            .nodes = buildNodes(turret_type.color),
        };
        self.updateWorldTransforms();
        if (turret_type.program) |steps| {
            self.runProgram(.{ .steps = steps });
        }
        return self;
    }

    /// Aims, fires the shots that are due, and moves the shots in flight; shells that end
    /// go into `explosions`. `trigger`: the turret may fire at all.
    pub fn update(self: *Self, dt: f32, target: TargetState, trigger: bool, random: *Random, explosions: *Explosions) void {
        self.advanceProgram(dt);
        self.aim.aimAt(self.patternAim(target, dt));
        self.aim.update(dt);
        self.fire_control.update(dt, trigger and self.pattern != .wait, self.aim.aimError());

        self.recoil -= self.recoil * motion.dampAlpha(RECOIL_RECOVERY, dt);
        self.pose();

        // Shots in flight move first: a new shot is placed by its own age
        const hit_target: projectiles.Target = .{ .position = target.position, .radius = target.radius };
        self.shells.blast_radius = self.weapon.blast_radius;
        self.shells.spin = self.weapon.shell_spin;
        self.tracers.update(dt, hit_target, explosions);
        self.shells.update(dt, hit_target, explosions);
        self.fireDueShots(random);
    }

    /// Runs `program` from its first step (null stops it; the pattern stays as it is).
    pub fn runProgram(self: *Self, program: ?Program) void {
        self.program = program;
        if (program != null) {
            self.startStep();
        }
    }

    /// Tracers and shells that reached the target.
    pub fn hits(self: *const Self) u32 {
        return self.tracers.hits + self.shells.hits;
    }

    /// Tracers and shells in flight.
    pub fn inFlight(self: *const Self) usize {
        return self.tracers.count + self.shells.count;
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

    /// Recolors a part, e.g. the base to show health.
    pub fn setPartColor(self: *Self, part: Part, color: Vec4) void {
        self.nodes[@intFromEnum(part)].color = color;
    }

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, shapes: *const TurretShapes) void {
        for (self.nodes, shapes.parts) |node, shape| {
            shape.draw(frame, shader, DrawUniforms.init(node.world_transform.toMatrix(), node.color));
        }
    }

    /// Tracers unlit with `tracer_shader`, rockets shaded with `rocket_shader`.
    pub fn drawProjectiles(
        self: *const Self,
        frame: *const Frame,
        tracer_shader: *const Shader,
        rocket_shader: *const Shader,
        shapes: *const TurretShapes,
    ) void {
        const tracer_parts = [_]ProjectilePart{.{ .shape = shapes.tracer, .model = Mat4.Identity, .color = self.weapon.tracer_color }};
        self.tracers.draw(frame, tracer_shader, &tracer_parts);
        self.shells.draw(frame, rocket_shader, &shapes.rocketParts(self.weapon.shell_color));
    }

    /// Moves the program on to its next step when this one is done (the first again after
    /// the last).
    fn advanceProgram(self: *Self, dt: f32) void {
        if (self.program) |*program| {
            program.elapsed += dt;
            if (program.isStepDone()) {
                program.index = (program.index + 1) % program.steps.len;
                self.startStep();
            }
        }
    }

    /// Takes the program's current step's pattern and fire settings.
    fn startStep(self: *Self) void {
        const program = if (self.program) |*program| program else return;
        program.elapsed = 0.0;
        program.shots = 0;
        const step = program.steps[program.index];
        self.pattern = step.pattern;
        if (step.fire) |fire| {
            self.fire_control.policy = fire.policy;
            self.fire_control.cadence = fire.cadence;
            self.fire_control.burst_shot = 0;
        }
    }

    /// The direction to aim this frame, from the pivot. Also records where the shots are
    /// meant to go (`aim_point`) and the pattern's extras for the debug lines.
    fn patternAim(self: *Self, target: TargetState, dt: f32) Vec3 {
        self.sweep_ends = null;
        self.launch_velocity = null;
        switch (self.pattern) {
            .track => |track| {
                self.aim_point = if (track.lead)
                    ballistics.leadPoint(self.muzzle(), target.position, target.velocity, self.weapon.speed)
                else
                    target.position;
            },
            .sweep => |*sweep| self.aim_point = self.sweepPoint(sweep, target, dt),
            .mortar => |mortar| {
                // A lob points along its launch velocity, not at the target. Over a lob's
                // flight time a target on a curve turns a lot, so the lead follows the
                // curve too: p + v·T + ½·a·T², gravity's formula with the target's
                // acceleration.
                self.aim_point = if (mortar.lead)
                    ballistics.positionAt(target.position, target.velocity, target.acceleration, mortar.flight_time)
                else
                    target.position;
                // A dip in the route can extrapolate below the floor, where no target goes
                self.aim_point.y = @max(self.aim_point.y, 0.0);
                const launch_velocity = ballistics.launchVelocity(self.muzzle(), self.aim_point, mortar.flight_time, GRAVITY);
                self.launch_velocity = launch_velocity;
                return launch_velocity;
            },
            .wait => return self.aim.direction(),
        }
        return self.aim_point.sub(self.pivot());
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

    /// One parent-first pass; the base composes with the turret's position and size.
    fn updateWorldTransforms(self: *Self) void {
        const placement: Transform = .{
            .translation = self.position,
            .rotation = Quat.Identity,
            .scale = vec3(self.size, self.size, self.size),
        };
        for (&self.nodes) |*node| {
            const parent_transform = if (node.parent) |parent| self.nodes[@intFromEnum(parent)].world_transform else placement;
            node.world_transform = parent_transform.composeTransforms(node.local_transform);
        }
    }

    /// Each due shot leaves the muzzle along the aim, spread by the weapon's jitter, and
    /// kicks the barrel back. A mortar shell goes at its launch speed, along the barrel.
    fn fireDueShots(self: *Self, random: *Random) void {
        while (self.fire_control.nextShot()) |age| {
            switch (self.pattern) {
                .wait => continue,
                .track, .sweep => {
                    const shot = self.weapon.jitter.apply(random, self.aim.direction(), self.weapon.speed);
                    self.tracers.spawn(self.muzzle(), shot.direction.mulScalar(shot.speed), TRACER_LIFETIME, age);
                },
                .mortar => |mortar| {
                    const speed = (self.launch_velocity orelse continue).length();
                    const shot = self.weapon.jitter.apply(random, self.aim.direction(), speed);
                    self.shells.spawn(self.muzzle(), shot.direction.mulScalar(shot.speed), mortar.flight_time, age);
                },
            }
            self.recoil = self.weapon.recoil_distance;
            if (self.program) |*program| {
                program.shots += 1;
            }
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
