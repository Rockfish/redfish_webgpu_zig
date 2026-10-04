//! When a weapon fires, and how much each shot strays (plan 008). A turret's aim decides
//! where the barrel points (`motion.YawPitchAim`); `FireControl` decides when a shot goes
//! out; `ShotJitter` turns each shot's direction and speed a little at random, so streams
//! of fire look natural instead of laser-straight.
//!
//! Each frame:
//!
//! ```
//! fire_control.update(dt, trigger, aim.aimError());
//! while (fire_control.nextShot()) |age| {
//!     // spawn a shot, moved on by `age` seconds
//! }
//! ```

const std = @import("std");
const math = @import("math");
const Random = @import("../random.zig").Random;

const Vec3 = math.Vec3;

/// The shortest time between shots, so a zero rate or interval can't loop forever.
const MIN_INTERVAL: f32 = 0.001;

/// Decides when shots go out: a policy (fire while turning, or only once on target) and a
/// cadence (a steady rate, or bursts). Frame-rate independent: the shot timer carries over
/// its remainder, so 10 shots per second is 10 shots in a second at 30 or 144 fps, and
/// several shots in one frame each get their own age.
pub const FireControl = struct {
    policy: Policy = .while_turning,
    cadence: Cadence = .{ .rate = 5.0 },
    /// Seconds until the next shot; at or below zero the gun is ready. While the gun holds
    /// fire it stops at zero, so held shots don't pile up into a volley.
    cooldown: f32 = 0.0,
    /// Shots fired in the current burst. A burst cut short by holding fire goes on where it
    /// left off.
    burst_shot: u32 = 0,
    /// Set by `update`: whether shots may go out this frame.
    is_firing: bool = false,

    const Self = @This();

    pub const Policy = union(enum) {
        /// Fire at the cadence wherever the barrel points: suppression, sweeps.
        while_turning,
        /// Hold fire until the aim is within this many radians of its target: snipers,
        /// mortars.
        when_aligned: f32,
    };

    pub const Cadence = union(enum) {
        /// Shots per second.
        rate: f32,
        bursts: Bursts,
    };

    pub const Bursts = struct {
        /// Shots per burst.
        count: u32,
        /// Seconds between shots in a burst.
        interval: f32,
        /// Seconds from a burst's last shot to the next burst's first.
        pause: f32,
    };

    /// Advances the shot timer. `trigger` is whether the turret wants to fire at all (a
    /// target in range); `aim_error` is how far, in radians, the aim is from its target.
    pub fn update(self: *Self, dt: f32, trigger: bool, aim_error: f32) void {
        self.is_firing = trigger and switch (self.policy) {
            .while_turning => true,
            .when_aligned => |tolerance| aim_error <= tolerance,
        };

        self.cooldown -= dt;
        if (!self.is_firing) {
            self.cooldown = @max(self.cooldown, 0.0);
        }
    }

    /// The next shot due this frame, as its age: the seconds since it should have gone out,
    /// at most this frame's `dt`. Moving each shot on by its age keeps a stream evenly
    /// spaced whatever the frame rate. Null when no more shots are due.
    pub fn nextShot(self: *Self) ?f32 {
        if (!self.is_firing or self.cooldown > 0.0) {
            return null;
        }
        const age = -self.cooldown;
        self.cooldown += self.nextInterval();
        return age;
    }

    /// Time from this shot to the next: a burst's interval, or the pause after its last shot.
    fn nextInterval(self: *Self) f32 {
        switch (self.cadence) {
            .rate => |rate| return @max(1.0 / rate, MIN_INTERVAL),
            .bursts => |bursts| {
                self.burst_shot += 1;
                if (self.burst_shot < bursts.count) {
                    return @max(bursts.interval, MIN_INTERVAL);
                }
                self.burst_shot = 0;
                return @max(bursts.pause, MIN_INTERVAL);
            },
        }
    }
};

/// Random spread per shot: the direction turned by up to `aim` radians in any direction (a
/// cone around the aim), the speed scaled by up to ±`speed` (0.05 is ±5%).
pub const ShotJitter = struct {
    aim: f32 = 0.0,
    speed: f32 = 0.0,

    const Self = @This();

    pub const Shot = struct {
        /// Unit vector.
        direction: Vec3,
        speed: f32,
    };

    /// `direction` (a unit vector) and `speed` with this shot's jitter. Points fill the
    /// cone's disk evenly (the angle grows with the square root of a uniform number), so
    /// shots don't bunch at the center.
    pub fn apply(self: Self, random: *Random, direction: Vec3, speed: f32) Shot {
        const angle = self.aim * @sqrt(random.randFloat());
        const around = 2.0 * std.math.pi * random.randFloat();
        const axes = perpendicularAxes(direction);
        const sideways = axes[0].mulScalar(@cos(around)).add(axes[1].mulScalar(@sin(around)));
        return .{
            .direction = direction.mulScalar(@cos(angle)).add(sideways.mulScalar(@sin(angle))),
            .speed = speed * (1.0 + self.speed * random.randClamped()),
        };
    }
};

/// Two unit vectors perpendicular to `direction` and to each other.
fn perpendicularAxes(direction: Vec3) [2]Vec3 {
    // Any axis not parallel to the direction will do; Y unless the direction is vertical
    const helper = if (@abs(direction.y) < 0.9) Vec3.Y else Vec3.X;
    const first = direction.cross(helper).toNormalized();
    return .{ first, direction.cross(first) };
}

test "FireControl: when_aligned fires nothing until the aim is within tolerance" {
    var fire_control: FireControl = .{ .policy = .{ .when_aligned = 0.05 }, .cadence = .{ .rate = 20.0 } };
    const dt: f32 = 1.0 / 60.0;

    // Two seconds off target: nothing
    for (0..120) |_| {
        fire_control.update(dt, true, 0.2);
        try std.testing.expectEqual(@as(?f32, null), fire_control.nextShot());
    }

    // On target: a shot at once, not a held-up volley
    fire_control.update(dt, true, 0.01);
    try std.testing.expect(fire_control.nextShot() != null);
    try std.testing.expectEqual(@as(?f32, null), fire_control.nextShot());
}

test "FireControl: no trigger, no shots, and no volley when it's pulled" {
    var fire_control: FireControl = .{ .cadence = .{ .rate = 10.0 } };
    for (0..60) |_| {
        fire_control.update(1.0 / 60.0, false, 0.0);
        try std.testing.expectEqual(@as(?f32, null), fire_control.nextShot());
    }

    fire_control.update(1.0 / 60.0, true, 0.0);
    try std.testing.expectEqual(@as(u32, 1), countShots(&fire_control));
}

test "FireControl: the same number of shots at 10, 30, and 144 fps" {
    // 7 shots per second for 1.5 s: shots at k/7 s, k = 0..10. No shot time is near a
    // frame boundary at any of these rates.
    const rate: FireControl.Cadence = .{ .rate = 7.0 };
    try std.testing.expectEqual(@as(u32, 11), shotsOver(rate, 1.5, 10));
    try std.testing.expectEqual(@as(u32, 11), shotsOver(rate, 1.5, 30));
    try std.testing.expectEqual(@as(u32, 11), shotsOver(rate, 1.5, 144));

    // Bursts of 3, 0.1 s apart, 0.5 s pause: shots at 0, 0.1, 0.2, 0.7, 0.8, 0.9 in 1 s
    const bursts: FireControl.Cadence = .{ .bursts = .{ .count = 3, .interval = 0.1, .pause = 0.5 } };
    try std.testing.expectEqual(@as(u32, 6), shotsOver(bursts, 1.0, 10));
    try std.testing.expectEqual(@as(u32, 6), shotsOver(bursts, 1.0, 30));
    try std.testing.expectEqual(@as(u32, 6), shotsOver(bursts, 1.0, 144));
}

test "FireControl: shots in one frame are a frame's time old at most, an interval apart" {
    // 25 shots per second at 10 fps: two or three shots a frame
    var fire_control: FireControl = .{ .cadence = .{ .rate = 25.0 } };
    const dt: f32 = 0.1;
    for (0..10) |_| {
        fire_control.update(dt, true, 0.0);
        var previous: ?f32 = null;
        while (fire_control.nextShot()) |age| {
            try std.testing.expect(age >= 0.0 and age <= dt + 1e-5);
            if (previous) |previous_age| {
                try std.testing.expectApproxEqAbs(@as(f32, 0.04), previous_age - age, 1e-4);
            }
            previous = age;
        }
    }
}

test "ShotJitter: shots stay within the cone and the speed range, and spread" {
    var random = Random.init();
    const jitter: ShotJitter = .{ .aim = 0.05, .speed = 0.1 };
    const directions = [_]Vec3{ Vec3.init(0.0, 0.0, -1.0), Vec3.init(0.6, 0.0, 0.8), Vec3.init(0.0, 1.0, 0.0) };

    for (directions) |direction| {
        var widest: f32 = 0.0;
        for (0..1000) |_| {
            const shot = jitter.apply(&random, direction, 20.0);
            const angle = std.math.acos(std.math.clamp(shot.direction.dot(direction), -1.0, 1.0));
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), shot.direction.length(), 1e-4);
            try std.testing.expect(angle <= 0.05 + 1e-3);
            try std.testing.expect(shot.speed >= 18.0 and shot.speed <= 22.0);
            widest = @max(widest, angle);
        }
        try std.testing.expect(widest > 0.04);
    }
}

fn shotsOver(cadence: FireControl.Cadence, seconds: f32, fps: u32) u32 {
    var fire_control: FireControl = .{ .cadence = cadence };
    const frames: u32 = @intFromFloat(@round(seconds * @as(f32, @floatFromInt(fps))));
    var shots: u32 = 0;
    for (0..frames) |_| {
        fire_control.update(1.0 / @as(f32, @floatFromInt(fps)), true, 0.0);
        shots += countShots(&fire_control);
    }
    return shots;
}

fn countShots(fire_control: *FireControl) u32 {
    var shots: u32 = 0;
    while (fire_control.nextShot()) |_| {
        shots += 1;
    }
    return shots;
}
