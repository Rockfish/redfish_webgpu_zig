//! Game building blocks on top of the engine: ballistics, fire control, explosions,
//! projectiles, turrets and their types, and steering for squads. Code here may use the rest of core; nothing else in
//! core imports it.

const std = @import("std");

pub const ballistics = @import("ballistics.zig");
pub const fire_control = @import("fire_control.zig");
pub const FireControl = fire_control.FireControl;
pub const ShotJitter = fire_control.ShotJitter;
pub const explosions = @import("explosions.zig");
pub const Explosions = explosions.Explosions;
pub const ExplosionShapes = explosions.ExplosionShapes;
pub const projectiles = @import("projectiles.zig");
pub const turret = @import("turret.zig");
pub const Turret = turret.Turret;
pub const TurretShapes = turret.TurretShapes;
pub const turret_types = @import("turret_types.zig");
pub const steering = @import("steering.zig");

test {
    std.testing.refAllDecls(@This());
}
