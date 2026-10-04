//! A turret to shoot at on the range (docs/reviews/2026-10-04-link-style-controller-review.md
//! section 11.1): a `core.gameplay.Turret` with a size, health shown as its base's color
//! (green, yellow, red), and a reaction to hits (a tiny explosion where the shot struck,
//! a white flash, a knock that shakes it). At zero health it blows up and is gone.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const gameplay = core.gameplay;
const Explosions = gameplay.Explosions;
const Turret = gameplay.Turret;
const TurretShapes = gameplay.TurretShapes;
const TurretType = gameplay.turret.TurretType;
const TargetState = gameplay.turret.TargetState;
const Frame = core.Frame;
const Random = core.Random;
const Shader = core.Shader;
const motion = core.motion;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

/// Health per unit of size: a size-2 turret takes twice the hits.
const HEALTH_PER_SIZE: f32 = 10.0;
/// The hit volume: a sphere this far up and this big, times the size.
const HIT_CENTER_HEIGHT: f32 = 0.65;
const HIT_RADIUS: f32 = 0.9;
/// A strike's explosion radius, meters (not scaled).
const STRIKE_RADIUS: f32 = 0.15;
/// The final blast's radius, times the size.
const BLAST_RADIUS: f32 = 1.5;
/// How fast a hit's flash and knock wear off, per second (`dampAlpha`).
const FLASH_FADE: f32 = 8.0;
const KNOCK_FADE: f32 = 10.0;
/// How far a hit shakes the turret, meters times the size.
const KNOCK_DISTANCE: f32 = 0.06;

const HEALTHY = vec4(0.15, 0.6, 0.2, 1.0);
const HURT = vec4(0.85, 0.75, 0.1, 1.0);
const CRITICAL = vec4(0.8, 0.12, 0.08, 1.0);
const FLASH_COLOR = vec4(1.0, 1.0, 1.0, 1.0);

pub const HitSphere = struct {
    center: Vec3,
    radius: f32,
};

pub const TargetTurret = struct {
    turret: Turret,
    /// Where it stands when it isn't shaking.
    home: Vec3,
    max_health: f32,
    health: f32,
    /// 1 on a hit, wearing off: how white the base is.
    flash: f32 = 0.0,
    /// 1 on a hit, wearing off: how hard it shakes.
    knock: f32 = 0.0,
    destroyed: bool = false,

    const Self = @This();

    pub fn init(turret_type: TurretType, position: Vec3, size: f32) Self {
        var self: Self = .{
            .turret = .init(turret_type, position, size),
            .home = position,
            .max_health = HEALTH_PER_SIZE * size,
            .health = HEALTH_PER_SIZE * size,
        };
        self.showHealth();
        return self;
    }

    /// Aims at `target` (holding fire), and settles the hit's flash and shake.
    pub fn update(self: *Self, dt: f32, target: TargetState, random: *Random, explosions: *Explosions) void {
        if (self.destroyed) {
            return;
        }
        self.flash -= self.flash * motion.dampAlpha(FLASH_FADE, dt);
        self.knock -= self.knock * motion.dampAlpha(KNOCK_FADE, dt);

        const shake = randomDirection(random).mulScalar(KNOCK_DISTANCE * self.turret.size * self.knock);
        self.turret.position = self.home.add(shake);
        self.turret.update(dt, target, false, random, explosions);
        self.showHealth();
    }

    /// A shot struck at `point` for `damage`: a tiny explosion there, a flash and a knock;
    /// at zero health a blast, and the turret is gone.
    pub fn hit(self: *Self, point: Vec3, damage: f32, explosions: *Explosions) void {
        if (self.destroyed) {
            return;
        }
        explosions.add(point, STRIKE_RADIUS);
        self.flash = 1.0;
        self.knock = 1.0;
        self.health = @max(self.health - damage, 0.0);
        if (self.health == 0.0) {
            const sphere = self.hitSphere();
            explosions.add(sphere.center, BLAST_RADIUS * self.turret.size);
            self.destroyed = true;
        }
    }

    /// Back to full health where it started.
    pub fn reset(self: *Self) void {
        self.health = self.max_health;
        self.destroyed = false;
        self.flash = 0.0;
        self.knock = 0.0;
        self.turret.position = self.home;
        self.showHealth();
    }

    pub fn hitSphere(self: *const Self) HitSphere {
        const size = self.turret.size;
        return .{
            .center = self.home.add(vec3(0.0, HIT_CENTER_HEIGHT * size, 0.0)),
            .radius = HIT_RADIUS * size,
        };
    }

    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, shapes: *const TurretShapes) void {
        if (!self.destroyed) {
            self.turret.draw(frame, shader, shapes);
        }
    }

    /// The base's color: green above two thirds of full health, yellow above a third, red
    /// below; white for a moment after a hit.
    fn showHealth(self: *Self) void {
        const fraction = self.health / self.max_health;
        const health_color: Vec4 = if (fraction > 2.0 / 3.0) HEALTHY else if (fraction > 1.0 / 3.0) HURT else CRITICAL;
        self.turret.setPartColor(.base, health_color.lerp(FLASH_COLOR, self.flash));
    }
};

/// A random direction (not quite even over the sphere; fine for a shake).
fn randomDirection(random: *Random) Vec3 {
    const direction = vec3(random.randClamped(), random.randClamped(), random.randClamped());
    const length = direction.length();
    return if (length > 0.0) direction.mulScalar(1.0 / length) else Vec3.Zero;
}
