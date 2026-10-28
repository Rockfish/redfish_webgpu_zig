//! The deck's state, the clicks that drive the robot, and what using each hotspot does
//! (plan 021, phases B and G).
//!
//! The opening: main power is offline and the alarm is on. The red button stops the
//! alarm; the console's third button turns on the lights, which give only the emergency
//! light; the middle button opens and closes the door once there is that power. Through
//! the door, Room 02 and its ladder down.

const std = @import("std");
const core = @import("core");

const interaction = @import("interaction.zig");
const navigation = @import("navigation.zig");
const deck = @import("deck.zig");
const room_01 = @import("room_01.zig");
const room_02 = @import("room_02.zig");
const robot_module = @import("robot.zig");
const Robot = robot_module.Robot;
const Ray = core.Ray;
const Vec3 = @import("math").Vec3;
const Target = interaction.Target;

/// Seconds the door takes to slide open.
const DOOR_OPEN_TIME: f32 = 1.2;
/// Seconds a message stays on screen.
const MESSAGE_TIME: f32 = 4.0;

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
    /// The robot's last remark, shown for `message_time` more seconds.
    message: []const u8 = "",
    message_time: f32 = 0.0,

    const Self = @This();

    /// `ray` is the mouse ray, null while the mouse is over a panel; `clicked` is true on
    /// the frame the left button goes down. Only the robot's room's hotspots are picked:
    /// the camera shows that room_01.
    pub fn update(self: *Self, ray: ?Ray, clicked: bool, dt: f32) void {
        const shown = self.robotRoom();
        const filter: RoomFilter = .{ .room = shown };
        self.hovered = if (ray) |mouse_ray| interaction.pick(&deck.hotspots, filter, mouse_ray, deck.interior(shown)) else .nothing;
        if (clicked) {
            self.sendRobot();
        }

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

    /// The robot's last remark while it lasts, or "".
    pub fn remark(self: *const Self) []const u8 {
        return if (self.message_time > 0.0) self.message else "";
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
            else => {},
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

/// Picks only the hotspots in one room_01.
const RoomFilter = struct {
    room: deck.RoomId,

    pub fn allows(self: RoomFilter, index: usize) bool {
        return deck.isHotspotIn(index, self.room);
    }
};
