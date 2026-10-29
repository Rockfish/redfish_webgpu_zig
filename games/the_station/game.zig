//! The game: the robot, the station's state (`state.zig`), and the clicks that drive the
//! robot (plan 021, phases B and G; plan 022, phase D). A room's own hotspot is used by
//! its room (`room_01.use`, `room_02.use`); the door and the ladder are crossed here.
//!
//! The opening: main power is offline and the alarm sounds (`state.zig`). Through Room
//! 01's door, Room 02 and its ladder down.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const interaction = @import("interaction.zig");
const Cursor = @import("cursor.zig").Cursor;
const navigation = @import("navigation.zig");
const station = @import("station.zig");
const room_01 = @import("room_01.zig");
const room_02 = @import("room_02.zig");
const Station = @import("state.zig").Station;
const robot_module = @import("robot.zig");
const Robot = robot_module.Robot;
const Ray = core.Ray;
const motion = core.motion;
const Target = interaction.Target;
const Vec3 = math.Vec3;

/// Seconds the door takes to slide open.
const DOOR_OPEN_TIME: f32 = 1.2;
/// Seconds a message stays on screen.
const MESSAGE_TIME: f32 = 4.0;
/// How fast the hovered control's highlight eases in and out (`motion.dampAlpha` rate):
/// most of the way in about 0.15 s.
const HIGHLIGHT_RATE: f32 = 20.0;

/// What a restart goes back to: the station's state and where the robot stood. The
/// default is the start.
pub const Snapshot = struct {
    station: Station = .{},
    robot_position: Vec3 = station.place(.room_01, room_01.ROBOT_START),
    robot_yaw: f32 = 0.0,
};

pub const Game = struct {
    robot: Robot = .{ .position = station.place(.room_01, room_01.ROBOT_START) },
    station: Station = .{},
    /// The robot's room, and the game as the robot entered it, for going back there.
    room: station.RoomId = .room_01,
    room_entry: Snapshot = .{},
    /// 0..1: how far Room 01's door has slid into the wall.
    door_open: f32 = 0.0,
    /// What the mouse is over this frame.
    hovered: Target = .nothing,
    /// The hotspot last under the mouse, and how lit its highlight is (0..1): it fades
    /// out after the mouse leaves.
    highlighted: ?usize = null,
    highlight: f32 = 0.0,
    /// The robot's last remark, shown for `message_time` more seconds.
    message: []const u8 = "",
    message_time: f32 = 0.0,

    const Self = @This();

    /// `ray` is the mouse ray, null while the mouse is over a panel; `clicked` is true on
    /// the frame the left button goes down. Only the robot's room's hotspots are picked:
    /// the camera shows that room.
    pub fn update(self: *Self, ray: ?Ray, clicked: bool, dt: f32) void {
        const shown = self.robotRoom();
        const filter: RoomFilter = .{ .room = shown };
        self.hovered = if (ray) |mouse_ray| interaction.pick(&station.hotspots, filter, mouse_ray, station.interior(shown)) else .nothing;
        if (clicked) {
            self.sendRobot();
        }
        self.updateHighlight(dt);

        if (self.robot.update(dt)) |hotspot| {
            self.use(station.hotspots[hotspot].kind);
        }
        const room = self.robotRoom();
        if (room != self.room) {
            self.room = room;
            self.room_entry = self.snapshot();
        }

        const door_target: f32 = if (self.station.isDoorOpen(.room_01_left)) 1.0 else 0.0;
        const door_step = dt / DOOR_OPEN_TIME;
        self.door_open = std.math.clamp(door_target, self.door_open - door_step, self.door_open + door_step);
        self.message_time = @max(self.message_time - dt, 0.0);
    }

    /// The room the robot is in, which the camera shows.
    pub fn robotRoom(self: *const Self) station.RoomId {
        return station.roomAt(self.robot.position);
    }

    /// The name of the hotspot under the mouse, or "".
    pub fn hoveredName(self: *const Self) []const u8 {
        return switch (self.hovered) {
            .hotspot => |index| station.hotspots[index].name,
            .floor, .nothing => "",
        };
    }

    /// What a click would do where the mouse is.
    pub fn cursor(self: *const Self) Cursor {
        return switch (self.hovered) {
            .hotspot => |index| self.hotspotCursor(index),
            .floor, .nothing => .walk,
        };
    }

    /// The robot's last remark while it lasts, or "".
    pub fn remark(self: *const Self) []const u8 {
        return if (self.message_time > 0.0) self.message else "";
    }

    pub fn snapshot(self: *const Self) Snapshot {
        return .{ .station = self.station, .robot_position = self.robot.position, .robot_yaw = self.robot.yaw };
    }

    /// The game as it was at `saved`, the robot standing still; `.{}` restarts it.
    pub fn restore(self: *Self, saved: Snapshot) void {
        self.* = .{
            .robot = .{ .position = saved.robot_position, .yaw = saved.robot_yaw },
            .station = saved.station,
            .room = station.roomAt(saved.robot_position),
            .room_entry = saved,
            .door_open = if (saved.station.isDoorOpen(.room_01_left)) 1.0 else 0.0,
        };
    }

    /// Eases the highlight in on the hovered hotspot, and out after the mouse leaves it.
    /// Another hotspot under the mouse starts from unlit.
    fn updateHighlight(self: *Self, dt: f32) void {
        const hovered: ?usize = switch (self.hovered) {
            .hotspot => |index| index,
            .floor, .nothing => null,
        };
        if (hovered) |index| {
            if (self.highlighted != index) {
                self.highlighted = index;
                self.highlight = 0.0;
            }
        }
        const target: f32 = if (hovered != null) 1.0 else 0.0;
        self.highlight = std.math.lerp(self.highlight, target, motion.dampAlpha(HIGHLIGHT_RATE, dt));
    }

    /// An open door shows the way to the next room, the ladder what a click on it does
    /// (`useLadder`), anything else its action. The ladder's upper part does nothing
    /// while the robot stands at its top.
    fn hotspotCursor(self: *const Self, index: usize) Cursor {
        const hotspot = station.hotspots[index];
        return switch (hotspot.kind) {
            .door => if (self.station.isDoorOpen(.room_01_left)) self.exitCursor() else actionCursor(hotspot.action),
            .ladder => switch (self.robot.ladderPlace()) {
                .off => .climb,
                .top => .walk,
                .below => .climb_up,
            },
            .ladder_hole => switch (self.robot.ladderPlace()) {
                .off => .climb,
                .top => .climb_down,
                .below => .climb_up,
            },
            .room_01, .room_02 => actionCursor(hotspot.action),
        };
    }

    /// Room 02 is left of Room 01.
    fn exitCursor(self: *const Self) Cursor {
        return switch (self.robotRoom()) {
            .room_01 => .exit_left,
            .room_02 => .exit_right,
        };
    }

    fn sendRobot(self: *Self) void {
        switch (self.hovered) {
            .hotspot => |index| self.sendToHotspot(index),
            .floor => |point| self.walkTo(point, .stand),
            .nothing => {},
        }
    }

    /// Walks to the hotspot and uses it; through the open door to the other room; or on
    /// the ladder (`useLadder`).
    fn sendToHotspot(self: *Self, index: usize) void {
        const hotspot = station.hotspots[index];
        switch (hotspot.kind) {
            .ladder => return self.useLadder(false),
            .ladder_hole => return self.useLadder(true),
            .door => if (self.station.isDoorOpen(.room_01_left)) {
                return self.walkTo(self.otherSideOfDoor(), .stand);
            },
            .room_01, .room_02 => {},
        }
        self.walkTo(hotspot.stand_point, .{ .use = .{ .hotspot = index, .facing = hotspot.facing, .action = hotspot.action } });
    }

    /// From the floor, onto the ladder; at the top, its lower part climbs down; below,
    /// any part of it climbs back up.
    fn useLadder(self: *Self, is_lower_part: bool) void {
        switch (self.robot.ladderPlace()) {
            .off => self.walkTo(station.ladder.exit, .{ .mount = station.ladder }),
            .top => if (is_lower_part) self.robot.climb(true),
            .below => self.robot.climb(false),
        }
    }

    /// A walk to the nearest point to `point` the robot can reach (the doorway only with
    /// the door open).
    fn walkTo(self: *Self, point: Vec3, then: robot_module.Arrival) void {
        const path = navigation.findPath(&station.walk_areas, self.station.isDoorOpen(.room_01_left), self.robot.walkStart(), point);
        self.robot.walk(path, then);
    }

    fn otherSideOfDoor(self: *const Self) Vec3 {
        return switch (self.robotRoom()) {
            .room_01 => station.place(.room_02, room_02.DOOR_STAND_POINT),
            .room_02 => station.place(.room_01, room_01.DOOR_STAND_POINT),
        };
    }

    /// A room's own hotspot goes to its room; the door is crossed if it is open.
    fn use(self: *Self, kind: station.HotspotKind) void {
        switch (kind) {
            .door => {
                if (self.station.isDoorOpen(.room_01_left)) {
                    // Opened while the robot was on its way to look
                    self.walkTo(self.otherSideOfDoor(), .stand);
                } else {
                    self.say("Sealed tight.");
                }
            },
            // Climbed, not used (`useLadder`)
            .ladder, .ladder_hole => {},
            .room_01 => |room_kind| self.say(room_01.use(&self.station, room_kind)),
            .room_02 => |room_kind| self.say(room_02.use(&self.station, room_kind)),
        }
    }

    fn say(self: *Self, message: []const u8) void {
        self.message = message;
        self.message_time = MESSAGE_TIME;
    }
};

fn actionCursor(action: interaction.Action) Cursor {
    return switch (action) {
        .push, .push_high => .use,
        .look => .look,
    };
}

/// Picks only the hotspots in one room.
const RoomFilter = struct {
    room: station.RoomId,

    pub fn allows(self: RoomFilter, index: usize) bool {
        return station.isHotspotIn(index, self.room);
    }
};

fn hotspotIndex(kind: station.HotspotKind) usize {
    for (station.hotspots, 0..) |hotspot, index| {
        if (std.meta.eql(hotspot.kind, kind)) {
            return index;
        }
    }
    unreachable;
}

test "cursor: what a click does" {
    var game: Game = .{};
    try std.testing.expectEqual(Cursor.walk, game.cursor());

    game.hovered = .{ .floor = room_01.ROBOT_START };
    try std.testing.expectEqual(Cursor.walk, game.cursor());

    game.hovered = .{ .hotspot = hotspotIndex(.{ .room_01 = .red_button }) };
    try std.testing.expectEqual(Cursor.use, game.cursor());

    game.hovered = .{ .hotspot = hotspotIndex(.{ .room_01 = .screen }) };
    try std.testing.expectEqual(Cursor.look, game.cursor());
}

test "cursor: an open door points to the next room" {
    var game: Game = .{};
    game.hovered = .{ .hotspot = hotspotIndex(.door) };
    try std.testing.expectEqual(Cursor.look, game.cursor());

    game.station.doors.set(.room_01_left, .open);
    try std.testing.expectEqual(Cursor.exit_left, game.cursor());
}

test "cursor: the ladder from the floor" {
    var game: Game = .{};
    game.hovered = .{ .hotspot = hotspotIndex(.ladder_hole) };
    try std.testing.expectEqual(Cursor.climb, game.cursor());
}

test "use: a room's hotspot changes the station through its room" {
    var game: Game = .{};
    game.use(.{ .room_01 = .door_button });
    try std.testing.expectEqualStrings("Click. No power to the door.", game.remark());

    game.use(.{ .room_01 = .lights_button });
    game.use(.{ .room_01 = .door_button });
    try std.testing.expect(game.station.isDoorOpen(.room_01_left));

    game.use(.{ .room_01 = .red_button });
    game.use(.{ .room_01 = .screen });
    try std.testing.expectEqualStrings("MAIN POWER LOST (acknowledged)", game.remark());
}

test "restore: back to a snapshot, and to the start" {
    var game: Game = .{};
    game.use(.{ .room_01 = .lights_button });
    const saved = game.snapshot();
    game.use(.{ .room_01 = .red_button });
    game.robot.position = station.place(.room_02, room_02.DOOR_STAND_POINT);

    game.restore(saved);
    try std.testing.expect(game.station.isAlarmSounding());
    try std.testing.expect(game.station.isDoorPowered());
    try std.testing.expectEqual(station.RoomId.room_01, game.robotRoom());

    game.restore(.{});
    try std.testing.expect(!game.station.isDoorPowered());
    try std.testing.expectEqualStrings("", game.remark());
}

test "room entry: the game as the robot came in" {
    var game: Game = .{};
    game.use(.{ .room_01 = .lights_button });
    game.robot.position = station.place(.room_02, room_02.DOOR_STAND_POINT);
    game.update(null, false, 0.0);
    try std.testing.expectEqual(station.RoomId.room_02, game.room);

    game.use(.{ .room_01 = .red_button });
    game.restore(game.room_entry);
    try std.testing.expect(game.station.isAlarmSounding());
    try std.testing.expectEqual(station.RoomId.room_02, game.robotRoom());
}
