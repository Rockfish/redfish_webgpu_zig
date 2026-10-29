//! The deck's state, the clicks that drive the robot, and what using each hotspot does
//! (plan 021, phases B and G).
//!
//! The opening: main power is offline and the alarm is on. The red button stops the
//! alarm; the console's third button turns on the lights, which give only the emergency
//! light; the middle button opens and closes the door once there is that power. Through
//! the door, Room 02 and its ladder down.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const interaction = @import("interaction.zig");
const Cursor = @import("cursor.zig").Cursor;
const navigation = @import("navigation.zig");
const deck = @import("deck.zig");
const room_01 = @import("room_01.zig");
const room_02 = @import("room_02.zig");
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

/// The deck's lights: off at the start; the emergency lights are all the power there is.
pub const Lights = enum { off, emergency };

pub const Game = struct {
    robot: Robot = .{ .position = room_01.ROBOT_START },
    is_alarm_on: bool = true,
    lights: Lights = .off,
    is_door_open: bool = false,
    /// 0..1: how far the door has slid into the wall.
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
        self.hovered = if (ray) |mouse_ray| interaction.pick(&deck.hotspots, filter, mouse_ray, deck.interior(shown)) else .nothing;
        if (clicked) {
            self.sendRobot();
        }
        self.updateHighlight(dt);

        if (self.robot.update(dt)) |hotspot| {
            self.use(deck.hotspots[hotspot].kind);
        }

        const door_target: f32 = if (self.is_door_open) 1.0 else 0.0;
        const door_step = dt / DOOR_OPEN_TIME;
        self.door_open = std.math.clamp(door_target, self.door_open - door_step, self.door_open + door_step);
        self.message_time = @max(self.message_time - dt, 0.0);
    }

    /// The room the robot is in, which the camera shows.
    pub fn robotRoom(self: *const Self) deck.RoomId {
        return deck.roomAt(self.robot.position.x);
    }

    /// The name of the hotspot under the mouse, or "".
    pub fn hoveredName(self: *const Self) []const u8 {
        return switch (self.hovered) {
            .hotspot => |index| deck.hotspots[index].name,
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
        const hotspot = deck.hotspots[index];
        return switch (hotspot.kind) {
            .door => if (self.is_door_open) self.exitCursor() else actionCursor(hotspot.action),
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
            .red_button, .door_button, .lights_button, .lever, .gauges, .screen, .breakers, .locked_door, .keypad, .power_cabinet => actionCursor(hotspot.action),
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
        const hotspot = deck.hotspots[index];
        switch (hotspot.kind) {
            .ladder => return self.useLadder(false),
            .ladder_hole => return self.useLadder(true),
            .door => if (self.is_door_open) {
                return self.walkTo(self.otherSideOfDoor(), .stand);
            },
            .red_button, .door_button, .lights_button, .lever, .gauges, .screen, .breakers, .locked_door, .keypad, .power_cabinet => {},
        }
        self.walkTo(hotspot.stand_point, .{ .use = .{ .hotspot = index, .facing = hotspot.facing, .action = hotspot.action } });
    }

    /// From the floor, onto the ladder; at the top, its lower part climbs down; below,
    /// any part of it climbs back up.
    fn useLadder(self: *Self, is_lower_part: bool) void {
        switch (self.robot.ladderPlace()) {
            .off => self.walkTo(room_02.ladder.exit, .{ .mount = room_02.ladder }),
            .top => if (is_lower_part) self.robot.climb(true),
            .below => self.robot.climb(false),
        }
    }

    /// A walk to the nearest point to `point` the robot can reach (the doorway only with
    /// the door open).
    fn walkTo(self: *Self, point: Vec3, then: robot_module.Arrival) void {
        const path = navigation.findPath(&deck.walk_areas, self.is_door_open, self.robot.walkStart(), point);
        self.robot.walk(path, then);
    }

    fn otherSideOfDoor(self: *const Self) Vec3 {
        return switch (self.robotRoom()) {
            .room_01 => room_02.DOOR_STAND_POINT,
            .room_02 => room_01.DOOR_STAND_POINT,
        };
    }

    fn use(self: *Self, kind: room_01.HotspotKind) void {
        switch (kind) {
            .red_button => {
                if (self.is_alarm_on) {
                    self.is_alarm_on = false;
                    self.say("Alarm off. Quiet at last.");
                } else {
                    self.say("Nothing more happens.");
                }
            },
            .lights_button => {
                if (self.lights == .off) {
                    self.lights = .emergency;
                    self.say("Main power offline. Emergency lights only.");
                } else {
                    self.say("Still only emergency power.");
                }
            },
            .door_button => {
                if (self.lights == .off) {
                    self.say("Click. No power to the door.");
                    return;
                }
                // The robot presses it at the console, so it is never in the doorway as
                // the door closes
                self.is_door_open = !self.is_door_open;
                self.say(if (self.is_door_open) "A lock clicks. The door slides open." else "The door slides shut.");
            },
            .door => {
                if (self.is_door_open) {
                    // Opened while the robot was on its way to look
                    self.walkTo(self.otherSideOfDoor(), .stand);
                } else {
                    self.say("Sealed tight.");
                }
            },
            .locked_door => self.say("Locked."),
            .keypad => self.say("DOOR LOCKED OUT. The keypad doesn't respond."),
            .power_cabinet => self.say("No voltage on any phase. The feed comes up the shaft."),
            .lever => self.say("Stuck."),
            .gauges => self.say("Pressure in the reactor ring is falling."),
            .screen => self.say(if (self.is_alarm_on) "ALARM: MAIN POWER LOST" else "MAIN POWER LOST (acknowledged)"),
            .breakers => self.say("All breakers are on. The fault is somewhere else."),
            // Climbed, not used (`useLadder`)
            .ladder, .ladder_hole => {},
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
    room: deck.RoomId,

    pub fn allows(self: RoomFilter, index: usize) bool {
        return deck.isHotspotIn(index, self.room);
    }
};

fn hotspotIndex(kind: room_01.HotspotKind) usize {
    for (deck.hotspots, 0..) |hotspot, index| {
        if (hotspot.kind == kind) {
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

    game.hovered = .{ .hotspot = hotspotIndex(.red_button) };
    try std.testing.expectEqual(Cursor.use, game.cursor());

    game.hovered = .{ .hotspot = hotspotIndex(.screen) };
    try std.testing.expectEqual(Cursor.look, game.cursor());
}

test "cursor: an open door points to the next room" {
    var game: Game = .{};
    game.hovered = .{ .hotspot = hotspotIndex(.door) };
    try std.testing.expectEqual(Cursor.look, game.cursor());

    game.is_door_open = true;
    try std.testing.expectEqual(Cursor.exit_left, game.cursor());
}

test "cursor: the ladder from the floor" {
    var game: Game = .{};
    game.hovered = .{ .hotspot = hotspotIndex(.ladder_hole) };
    try std.testing.expectEqual(Cursor.climb, game.cursor());
}
