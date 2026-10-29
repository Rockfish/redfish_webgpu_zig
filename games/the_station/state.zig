//! The station's state (plan 022, phase D): what the robot has changed on the station, as
//! plain data with no pointers, so a snapshot is a copy. What shows on screen is derived
//! from it (`lights`, `isDoorPowered`, ...), never stored twice.
//!
//! The opening: main power is offline and the alarm sounds. The console in Room 01 can
//! silence the alarm and switch on the emergency power, which lights the rooms and runs
//! the door to Room 02. Room 02's own door is locked out. The generator (phase H) joins
//! `Power` as main power.

const std = @import("std");

pub const Alarm = enum { sounding, silenced };

pub const Switch = enum { off, on };

/// The station's power: only the emergency circuit until the generator runs.
pub const Power = struct {
    /// The emergency circuit: the emergency lights and the doors' motors.
    emergency: Switch = .off,
};

/// The doors that open and close, by the wall they are in.
pub const DoorId = enum {
    /// Between Rooms 01 and 02, opened from Room 01's console.
    room_01_left,
    /// Room 02's door out, locked out.
    room_02_left,
};

pub const DoorState = enum { closed, open, locked_out };

/// The rooms' lights: off at the start; the emergency lights are all the power there is.
pub const Lights = enum { off, emergency };

pub const Station = struct {
    power: Power = .{},
    alarm: Alarm = .sounding,
    doors: std.EnumArray(DoorId, DoorState) = .init(.{ .room_01_left = .closed, .room_02_left = .locked_out }),

    const Self = @This();

    pub fn lights(self: Self) Lights {
        return switch (self.power.emergency) {
            .off => .off,
            .on => .emergency,
        };
    }

    /// A door's motor runs on the emergency circuit.
    pub fn isDoorPowered(self: Self) bool {
        return self.power.emergency == .on;
    }

    pub fn isDoorOpen(self: Self, door: DoorId) bool {
        return self.doors.get(door) == .open;
    }

    pub fn isAlarmSounding(self: Self) bool {
        return self.alarm == .sounding;
    }

    /// Opens a closed door and closes an open one, if it has power; a locked-out door
    /// stays as it is. Returns whether it moved.
    pub fn toggleDoor(self: *Self, door: DoorId) bool {
        if (!self.isDoorPowered()) {
            return false;
        }
        const next: DoorState = switch (self.doors.get(door)) {
            .closed => .open,
            .open => .closed,
            .locked_out => return false,
        };
        self.doors.set(door, next);
        return true;
    }
};

const testing = std.testing;

test "the start: alarm sounding, no lights, doors shut" {
    const start: Station = .{};
    try testing.expect(start.isAlarmSounding());
    try testing.expectEqual(Lights.off, start.lights());
    try testing.expect(!start.isDoorOpen(.room_01_left));
    try testing.expectEqual(DoorState.locked_out, start.doors.get(.room_02_left));
}

test "power: a door moves only on the emergency circuit" {
    var station: Station = .{};
    try testing.expect(!station.toggleDoor(.room_01_left));
    try testing.expect(!station.isDoorOpen(.room_01_left));

    station.power.emergency = .on;
    try testing.expectEqual(Lights.emergency, station.lights());
    try testing.expect(station.toggleDoor(.room_01_left));
    try testing.expect(station.isDoorOpen(.room_01_left));
    try testing.expect(station.toggleDoor(.room_01_left));
    try testing.expect(!station.isDoorOpen(.room_01_left));
}

test "doors: a locked-out door stays locked out" {
    var station: Station = .{ .power = .{ .emergency = .on } };
    try testing.expect(!station.toggleDoor(.room_02_left));
    try testing.expectEqual(DoorState.locked_out, station.doors.get(.room_02_left));
}

test "a snapshot is a copy" {
    var station: Station = .{};
    const snapshot = station;
    station.power.emergency = .on;
    station.alarm = .silenced;
    try testing.expect(snapshot.isAlarmSounding());
    station = snapshot;
    try testing.expectEqual(Lights.off, station.lights());
}
