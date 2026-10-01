//! A single-body turret: a ball on a pedestal that turns freely toward its target, with
//! `motion.dampLookAt` (a quick turn that settles), instead of the two-axis turret's
//! separate yaw and pitch. Right for a ball turret, a sensor head, or a camera: one
//! rotation, no per-axis speeds or limits.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const Explosions = @import("explosions.zig").Explosions;
const projectiles = @import("projectiles.zig");
const turret_module = @import("turret.zig");

const DrawUniforms = core.DrawUniforms;
const FireControl = core.FireControl;
const Frame = core.Frame;
const Random = core.Random;
const Shader = core.Shader;
const motion = core.motion;
const Projectiles = projectiles.Projectiles;
const TargetState = turret_module.TargetState;
const TurretShapes = turret_module.TurretShapes;
const Weapon = turret_module.Weapon;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

/// The ball's center above the turret's position: the base, then the pedestal.
const CENTER_HEIGHT = turret_module.BASE_SIZE.y + turret_module.PEDESTAL_HEIGHT;
/// Seconds a tracer flies before it's dropped.
const TRACER_LIFETIME: f32 = 3.0;

pub const BallTurret = struct {
    /// Where the base sits on the ground.
    position: Vec3,
    /// The ball's rotation; it looks down its -Z.
    rotation: Quat = Quat.Identity,
    /// How fast the ball turns toward its aim point, per second (`dampLookAt`).
    turn_rate: f32,
    lead: bool,
    fire_control: FireControl,
    weapon: Weapon,
    color: Vec4,
    tracers: Projectiles = .{},
    /// Where it aimed this frame (for the debug lines).
    aim_point: Vec3 = Vec3.Zero,

    const Self = @This();

    /// Turns toward the target (or its lead point), fires the shots that are due, and
    /// moves the shots in flight.
    pub fn update(self: *Self, dt: f32, target: TargetState, trigger: bool, random: *Random, explosions: *Explosions) void {
        const ball_center = self.center();
        self.aim_point = if (self.lead)
            core.ballistics.leadPoint(ball_center, target.position, target.velocity, self.weapon.speed)
        else
            target.position;
        self.rotation = motion.dampLookAt(self.rotation, ball_center, self.aim_point, Vec3.Y, self.turn_rate, dt);
        self.fire_control.update(dt, trigger, self.aimError());

        self.tracers.update(dt, .{ .position = target.position, .radius = target.radius }, explosions);
        while (self.fire_control.nextShot()) |age| {
            const shot = self.weapon.jitter.apply(random, self.rotation.forward(), self.weapon.speed);
            self.tracers.spawn(self.muzzle(), shot.direction.mulScalar(shot.speed), TRACER_LIFETIME, age);
        }
    }

    /// The ball's center, which it turns about.
    pub fn center(self: *const Self) Vec3 {
        return self.position.add(vec3(0.0, CENTER_HEIGHT, 0.0));
    }

    /// The center of the barrel's open end.
    pub fn muzzle(self: *const Self) Vec3 {
        return self.center().add(self.rotation.forward().mulScalar(turret_module.BARREL_LENGTH));
    }

    /// The angle in radians between where the ball looks and its aim point.
    pub fn aimError(self: *const Self) f32 {
        const toward = self.aim_point.sub(self.center()).toNormalized();
        return std.math.acos(std.math.clamp(self.rotation.forward().dot(toward), -1.0, 1.0));
    }

    /// Whether the aim is on target by the fire control's tolerance (or 2° for
    /// `while_turning`), for the debug lines.
    pub fn isOnTarget(self: *const Self) bool {
        const tolerance = switch (self.fire_control.policy) {
            .while_turning => std.math.degreesToRadians(2.0),
            .when_aligned => |when_aligned| when_aligned,
        };
        return self.aimError() <= tolerance;
    }

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, shapes: *const TurretShapes) void {
        const base_model = Mat4.fromTranslation(self.position.add(vec3(0.0, turret_module.BASE_SIZE.y * 0.5, 0.0)));
        const pedestal_model = Mat4.fromTranslation(self.position.add(vec3(0.0, turret_module.BASE_SIZE.y, 0.0)));
        const ball_model = Mat4.fromTranslation(self.center()).mulMat4(&Mat4.fromQuat(self.rotation));
        // The barrel cylinder is built along +Y; turned to the ball's -Z
        const barrel_model = ball_model.mulMat4(&Mat4.fromRotationX(-std.math.pi / 2.0));

        const parts = &shapes.parts;
        parts[@intFromEnum(turret_module.Part.base)].draw(frame, shader, DrawUniforms.init(base_model, vec4(0.32, 0.33, 0.36, 1.0)));
        shapes.pedestal.draw(frame, shader, DrawUniforms.init(pedestal_model, vec4(0.25, 0.26, 0.28, 1.0)));
        parts[@intFromEnum(turret_module.Part.head)].draw(frame, shader, DrawUniforms.init(ball_model, self.color));
        parts[@intFromEnum(turret_module.Part.barrel)].draw(frame, shader, DrawUniforms.init(barrel_model, vec4(0.18, 0.19, 0.21, 1.0)));
    }

    pub fn drawProjectiles(self: *const Self, frame: *const Frame, shader: *const Shader, shapes: *const TurretShapes) void {
        const parts = [_]projectiles.Part{.{ .shape = shapes.tracer, .model = Mat4.Identity, .color = self.weapon.tracer_color }};
        self.tracers.draw(frame, shader, &parts);
    }
};
