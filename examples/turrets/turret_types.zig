//! Turret types as configuration: slew style and speeds, pitch limits, fire settings,
//! weapon, and default pattern (or program). A game places turrets by type; the test bed's
//! panel starts from these values.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const turret_module = @import("turret.zig");

const motion = core.motion;
const Step = turret_module.Step;
const TurretType = turret_module.TurretType;
const vec4 = math.vec4;

const deg = std.math.degreesToRadians;

/// A steady stream that follows the target as it turns; no lead, so it trails a moving
/// target.
pub const gatling: TurretType = .{
    .name = "gatling",
    .color = vec4(0.55, 0.42, 0.18, 1.0),
    .aim = limits(.{ .rate_limited = .{ .yaw_speed = deg(90.0), .pitch_speed = deg(60.0) } }),
    .fire = .{ .policy = .while_turning, .cadence = .{ .rate = 10.0 } },
    .weapon = .{
        .speed = 30.0,
        .jitter = .{ .aim = deg(1.5), .speed = 0.05 },
        .tracer_color = vec4(1.0, 0.75, 0.3, 1.0),
    },
    .pattern = .{ .track = .{ .lead = false } },
};

/// Snaps onto the target and fires bursts once aligned, with lead. A damped aim trails a
/// moving target by about its angular speed / rate, so fast rates and a few degrees of
/// tolerance keep it firing.
pub const cannon: TurretType = .{
    .name = "cannon",
    .color = vec4(0.2, 0.42, 0.5, 1.0),
    .aim = limits(.{ .damped = .{ .yaw_rate = 8.0, .pitch_rate = 8.0 } }),
    .fire = .{
        .policy = .{ .when_aligned = deg(4.0) },
        .cadence = .{ .bursts = .{ .count = 3, .interval = 0.12, .pause = 1.0 } },
    },
    .weapon = .{
        .speed = 40.0,
        .jitter = .{ .aim = deg(0.5), .speed = 0.03 },
        .tracer_color = vec4(0.4, 0.9, 1.0, 1.0),
    },
    .pattern = .{ .track = .{ .lead = true } },
};

/// Sweeps a fan of fire 20° either side of the target's bearing.
pub const sweeper: TurretType = .{
    .name = "sweeper",
    .color = vec4(0.25, 0.45, 0.25, 1.0),
    .aim = limits(.{ .rate_limited = .{ .yaw_speed = deg(180.0), .pitch_speed = deg(90.0) } }),
    .fire = .{ .policy = .while_turning, .cadence = .{ .rate = 15.0 } },
    .weapon = .{
        .speed = 35.0,
        .jitter = .{ .aim = deg(1.0), .speed = 0.05 },
        .tracer_color = vec4(0.6, 1.0, 0.5, 1.0),
    },
    .pattern = .{ .sweep = .{ .swing = .{ .half_width = deg(20.0), .speed = deg(40.0) } } },
};

/// Lobs finned rockets that get to where the target will be in 1.6 s.
pub const mortar: TurretType = .{
    .name = "mortar",
    .color = vec4(0.45, 0.3, 0.45, 1.0),
    .aim = limits(.{ .rate_limited = .{ .yaw_speed = deg(60.0), .pitch_speed = deg(45.0) } }),
    .fire = .{ .policy = .{ .when_aligned = deg(3.0) }, .cadence = .{ .rate = 0.7 } },
    .weapon = .{
        .speed = 30.0,
        .jitter = .{ .aim = deg(1.5), .speed = 0.04 },
        .tracer_color = vec4(1.0, 0.6, 0.9, 1.0),
        .blast_radius = 2.0,
        .shell_spin = deg(180.0),
    },
    .pattern = .{ .mortar = .{ .flight_time = 1.6, .lead = true } },
};

/// A program: sweep for 3 s, two mortar rounds, a 1 s pause, repeat.
pub const battery: TurretType = .{
    .name = "battery",
    .color = vec4(0.55, 0.25, 0.2, 1.0),
    .aim = limits(.{ .rate_limited = .{ .yaw_speed = deg(120.0), .pitch_speed = deg(60.0) } }),
    .fire = battery_steps[0].fire.?,
    .weapon = .{
        .speed = 32.0,
        .jitter = .{ .aim = deg(1.2), .speed = 0.05 },
        .tracer_color = vec4(1.0, 0.5, 0.4, 1.0),
        .blast_radius = 1.6,
        .shell_spin = deg(180.0),
    },
    .pattern = battery_steps[0].pattern,
    .program = &battery_steps,
};

const battery_steps = [_]Step{
    .{
        .pattern = .{ .sweep = .{ .swing = .{ .half_width = deg(15.0), .speed = deg(50.0) } } },
        .fire = .{ .policy = .while_turning, .cadence = .{ .rate = 12.0 } },
        .until = .{ .seconds = 3.0 },
    },
    .{
        .pattern = .{ .mortar = .{ .flight_time = 1.6, .lead = true } },
        .fire = .{ .policy = .{ .when_aligned = deg(3.0) }, .cadence = .{ .rate = 1.5 } },
        .until = .{ .shots = 2 },
    },
    .{ .pattern = .wait, .until = .{ .seconds = 1.0 } },
};

/// `slew` with the pitch limits every type here shares: a little below level up to nearly
/// straight up, for high lobs.
fn limits(slew: motion.YawPitchAim.Slew) motion.YawPitchAim {
    return .{ .slew = slew, .min_pitch = deg(-10.0), .max_pitch = deg(85.0) };
}
