//! The range's turret types (plan 019 phase G): the core types
//! (`core.gameplay.turret_types`) slowed down so their fire is readable. Gun turrets
//! traverse slowly and fire while they turn, without lead, so a stream walks toward its
//! target and the player can see it coming and run; mortars lob shells that hang in the
//! air for seconds, with a warning ring where they'll land.

const std = @import("std");
const core = @import("core");

const gameplay = core.gameplay;
const turret_types = gameplay.turret_types;
const Step = gameplay.turret.Step;
const TurretType = gameplay.turret.TurretType;

const deg = std.math.degreesToRadians;

/// A shell's seconds in the air: long enough to see the warning and get out.
const MORTAR_FLIGHT_TIME: f32 = 3.5;

/// Bursts of six, swinging round at 25°/s, spraying 3°.
pub const gatling: TurretType = blk: {
    var t = turret_types.gatling;
    t.aim.slew = .{ .rate_limited = .{ .yaw_speed = deg(25.0), .pitch_speed = deg(20.0) } };
    t.fire = .{ .policy = .while_turning, .cadence = .{ .bursts = .{ .count = 6, .interval = 0.1, .pause = 1.2 } } };
    t.weapon.jitter.aim = deg(3.0);
    break :blk t;
};

/// Slow, heavy bursts of three, no lead.
pub const cannon: TurretType = blk: {
    var t = turret_types.cannon;
    t.aim.slew = .{ .rate_limited = .{ .yaw_speed = deg(18.0), .pitch_speed = deg(15.0) } };
    t.fire = .{ .policy = .while_turning, .cadence = .{ .bursts = .{ .count = 3, .interval = 0.2, .pause = 1.6 } } };
    t.weapon.speed = 35.0;
    t.weapon.jitter.aim = deg(2.0);
    t.pattern = .{ .track = .{ .lead = false } };
    break :blk t;
};

/// A slow fan, 15° either side of the target's bearing.
pub const sweeper: TurretType = blk: {
    var t = turret_types.sweeper;
    t.aim.slew = .{ .rate_limited = .{ .yaw_speed = deg(30.0), .pitch_speed = deg(20.0) } };
    t.fire = .{ .policy = .while_turning, .cadence = .{ .rate = 8.0 } };
    t.weapon.jitter.aim = deg(3.0);
    t.pattern = .{ .sweep = .{ .swing = .{ .half_width = deg(15.0), .speed = deg(12.0) } } };
    break :blk t;
};

/// A shell every four seconds, aimed where the target is now.
pub const mortar: TurretType = blk: {
    var t = turret_types.mortar;
    t.aim.slew = .{ .rate_limited = .{ .yaw_speed = deg(40.0), .pitch_speed = deg(30.0) } };
    t.fire = .{ .policy = .{ .when_aligned = deg(3.0) }, .cadence = .{ .rate = 0.25 } };
    t.weapon.blast_radius = 2.5;
    t.pattern = .{ .mortar = .{ .flight_time = MORTAR_FLIGHT_TIME, .lead = false } };
    break :blk t;
};

/// Sweeps for 4 s, lobs two shells, waits 2 s, repeats.
pub const battery: TurretType = blk: {
    var t = turret_types.battery;
    t.aim.slew = .{ .rate_limited = .{ .yaw_speed = deg(25.0), .pitch_speed = deg(20.0) } };
    t.fire = battery_steps[0].fire.?;
    t.pattern = battery_steps[0].pattern;
    t.program = &battery_steps;
    break :blk t;
};

const battery_steps = [_]Step{
    .{
        .pattern = .{ .sweep = .{ .swing = .{ .half_width = deg(15.0), .speed = deg(15.0) } } },
        .fire = .{ .policy = .while_turning, .cadence = .{ .rate = 8.0 } },
        .until = .{ .seconds = 4.0 },
    },
    .{
        .pattern = .{ .mortar = .{ .flight_time = MORTAR_FLIGHT_TIME, .lead = false } },
        .fire = .{ .policy = .{ .when_aligned = deg(3.0) }, .cadence = .{ .rate = 0.5 } },
        .until = .{ .shots = 2 },
    },
    .{ .pattern = .wait, .until = .{ .seconds = 2.0 } },
};
