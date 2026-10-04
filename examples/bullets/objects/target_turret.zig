//! A turret to shoot at on the range (docs/reviews/2026-10-04-link-style-controller-review.md
//! section 11.1): a `core.gameplay.Turret` with a size, health shown as its base's color
//! (green, yellow, red), and a reaction to hits (a tiny explosion where the shot struck,
//! a white flash, a knock that shakes it). At zero health it blows up and is gone.
//!
//! It fires back (plan 019 phase G): it watches the ground within its detection range,
//! picks someone there (the captain or a squad member) now and then, aims at them, and
//! fires; nobody inside, it holds fire. Its shots are tested against
//! everyone; what they strike, and every shell's blast, is reported as a `Strike` for the
//! scene to act on.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const gameplay = core.gameplay;
const projectiles = gameplay.projectiles;
const Explosions = gameplay.Explosions;
const Turret = gameplay.Turret;
const TurretShapes = gameplay.TurretShapes;
const TurretType = gameplay.turret.TurretType;
const TargetState = gameplay.turret.TargetState;
const Frame = core.Frame;
const Random = core.Random;
const Shader = core.Shader;
const Projectiles = projectiles.Projectiles;
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

/// A tracer's puff where it strikes someone or the floor, meters.
const PUFF_RADIUS: f32 = 0.1;
/// The most people a turret's shots are tested against.
const MAX_PEOPLE = 16;
/// The most strikes reported in a frame; more are dropped.
const MAX_STRIKES = 64;

const HEALTHY = vec4(0.15, 0.6, 0.2, 1.0);
const HURT = vec4(0.85, 0.75, 0.1, 1.0);
const CRITICAL = vec4(0.8, 0.12, 0.08, 1.0);
const FLASH_COLOR = vec4(1.0, 1.0, 1.0, 1.0);

pub const HitSphere = struct {
    center: Vec3,
    radius: f32,
};

/// How the turrets fire back; the range panel edits it live.
pub const FireBack = struct {
    enabled: bool = true,
    /// Times every turret's own detection range.
    detection_scale: f32 = 1.0,
    /// Once on someone, a turret keeps at them until they're this much past its range
    /// (a fraction), so someone at the edge isn't dropped and picked from frame to frame.
    detection_margin: f32 = 0.1,
    /// Seconds a turret stays on one person before picking again (at random within).
    retarget_min: f32 = 4.0,
    retarget_max: f32 = 9.0,
};

/// A turret's shot that ended this frame: a tracer on someone or the floor, or a shell's
/// blast.
pub const Strike = struct {
    position: Vec3,
    /// Who it struck directly (or the blast reached first), an index into the people;
    /// null for a tracer into the floor or a blast that reached nobody.
    person: ?usize,
    /// A shell's blast radius; zero for a tracer.
    blast_radius: f32,
    /// The turret that fired it, and its detection range: what a tracer's target runs
    /// from, and how far.
    source: Vec3,
    source_range: f32,
};

/// This frame's strikes from every turret.
pub const Strikes = struct {
    items: [MAX_STRIKES]Strike = undefined,
    count: usize = 0,

    pub fn add(self: *Strikes, strike: Strike) void {
        if (self.count < MAX_STRIKES) {
            self.items[self.count] = strike;
            self.count += 1;
        }
    }

    pub fn slice(self: *const Strikes) []const Strike {
        return self.items[0..self.count];
    }
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
    /// Meters around its home it watches; someone inside is fired on.
    detection_range: f32,
    /// Who it aims at, an index into the people (null: nobody in range), and the seconds
    /// until it picks again.
    person: ?usize = null,
    last_person: usize = 0,
    retarget_timer: f32 = 0.0,

    const Self = @This();

    pub fn init(turret_type: TurretType, position: Vec3, size: f32, detection_range: f32) Self {
        var self: Self = .{
            .detection_range = detection_range,
            .turret = .init(turret_type, position, size),
            .home = position,
            .max_health = HEALTH_PER_SIZE * size,
            .health = HEALTH_PER_SIZE * size,
        };
        self.showHealth();
        return self;
    }

    /// Settles the hit's flash and shake, aims at its person among `people`, fires when
    /// they're in range, and moves its shots on against everyone: what they strike goes
    /// into `strikes`. Shots in flight fly on after the turret is destroyed.
    pub fn update(
        self: *Self,
        dt: f32,
        people: []const TargetState,
        fire_back: FireBack,
        random: *Random,
        explosions: *Explosions,
        strikes: *Strikes,
    ) void {
        if (!self.destroyed) {
            self.settleHit(dt, random);
            self.pickPerson(people, fire_back, random, dt);
            // Nobody in range: holds fire, still pointed at the last one it saw
            const target = people[self.person orelse self.last_person];
            self.turret.updateAim(dt, target, fire_back.enabled and self.person != null);
        }

        // Shots in flight move first: a new shot is placed by its own age
        self.moveShots(dt, people, self.detectionRange(fire_back), explosions, strikes);
        if (!self.destroyed) {
            self.turret.fireDueShots(random);
            self.showHealth();
        }
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
        self.person = null;
        self.turret.tracers.count = 0;
        self.turret.shells.count = 0;
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

    /// Its tracers unlit with `tracer_shader`, its shells shaded with `rocket_shader`.
    pub fn drawProjectiles(self: *const Self, frame: *const Frame, tracer_shader: *const Shader, rocket_shader: *const Shader, shapes: *const TurretShapes) void {
        self.turret.drawProjectiles(frame, tracer_shader, rocket_shader, shapes);
    }

    /// A hit's flash and knock wear off; the knock shakes the turret about its home.
    fn settleHit(self: *Self, dt: f32, random: *Random) void {
        self.flash -= self.flash * motion.dampAlpha(FLASH_FADE, dt);
        self.knock -= self.knock * motion.dampAlpha(KNOCK_FADE, dt);
        const shake = randomDirection(random).mulScalar(KNOCK_DISTANCE * self.turret.size * self.knock);
        self.turret.position = self.home.add(shake);
    }

    /// The detection range with the panel's scale, meters.
    pub fn detectionRange(self: *const Self, fire_back: FireBack) f32 {
        return self.detection_range * fire_back.detection_scale;
    }

    /// Keeps on its person while they stay in range (with the margin); now and then, or
    /// when they leave, picks someone at random from those in range, or nobody.
    fn pickPerson(self: *Self, people: []const TargetState, fire_back: FireBack, random: *Random, dt: f32) void {
        const range = self.detectionRange(fire_back);
        self.retarget_timer -= dt;
        if (self.person) |person| {
            const is_gone = self.groundDistance(people[person].position) > range * (1.0 + fire_back.detection_margin);
            if (!is_gone and self.retarget_timer > 0.0) {
                return;
            }
        }

        var in_range: [MAX_PEOPLE]usize = undefined;
        var count: usize = 0;
        for (people[0..@min(people.len, MAX_PEOPLE)], 0..) |person, index| {
            if (self.groundDistance(person.position) < range) {
                in_range[count] = index;
                count += 1;
            }
        }
        if (count == 0) {
            self.person = null;
            return;
        }
        const pick: usize = @intFromFloat(random.randFloat() * @as(f32, @floatFromInt(count)));
        self.person = in_range[@min(pick, count - 1)];
        self.last_person = self.person.?;
        self.retarget_timer = random.randFloatInRange(fire_back.retarget_min, fire_back.retarget_max);
    }

    fn groundDistance(self: *const Self, point: Vec3) f32 {
        return vec3(point.x - self.home.x, 0.0, point.z - self.home.z).length();
    }

    /// Tracers and shells on against `people`. A tracer that strikes someone or the floor
    /// puffs and is reported; so is every shell's blast, whoever it reached. `range` is
    /// the detection range reported with them.
    fn moveShots(self: *Self, dt: f32, people: []const TargetState, range: f32, explosions: *Explosions, strikes: *Strikes) void {
        var targets: [MAX_PEOPLE]projectiles.Target = undefined;
        const count = @min(people.len, MAX_PEOPLE);
        for (people[0..count], targets[0..count]) |person, *target| {
            target.* = .{ .position = person.position, .radius = person.radius };
        }

        var endings: [projectiles.MAX_PROJECTILES]projectiles.Ending = undefined;
        for (self.turret.tracers.updateTargets(dt, targets[0..count], explosions, &endings)) |ending| {
            if (ending.target != null or ending.grounded) {
                explosions.add(ending.position, PUFF_RADIUS);
                strikes.add(.{ .position = ending.position, .person = ending.target, .blast_radius = 0.0, .source = self.home, .source_range = range });
            }
        }
        const shells: *Projectiles = &self.turret.shells;
        for (shells.updateTargets(dt, targets[0..count], explosions, &endings)) |ending| {
            strikes.add(.{ .position = ending.position, .person = ending.target, .blast_radius = shells.blast_radius, .source = self.home, .source_range = range });
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
