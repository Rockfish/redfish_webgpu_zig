//! Room 01's state, the clicks that drive the robot, and what using each hotspot does
//! (plan 021, phase B). The red button stops the alarm; the console's middle button opens
//! and closes the door.

const std = @import("std");
const core = @import("core");

const interaction = @import("interaction.zig");
const room = @import("room.zig");
const Robot = @import("robot.zig").Robot;
const Ray = core.Ray;
const Target = interaction.Target;

/// Seconds the door takes to slide open.
const DOOR_OPEN_TIME: f32 = 1.2;
/// Seconds a message stays on screen.
const MESSAGE_TIME: f32 = 4.0;

pub const Game = struct {
    robot: Robot = .{ .position = room.ROBOT_START, .doorway = room.doorway },
    is_alarm_on: bool = true,
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
    /// the frame the left button goes down.
    pub fn update(self: *Self, ray: ?Ray, clicked: bool, dt: f32) void {
        self.hovered = if (ray) |mouse_ray| interaction.pick(&room.hotspots, room.walk_area, mouse_ray) else .nothing;
        if (clicked) {
            self.sendRobot();
        }

        if (self.robot.update(dt)) |hotspot| {
            self.use(room.hotspots[hotspot].kind);
        }

        const door_target: f32 = if (self.is_door_open) 1.0 else 0.0;
        const door_step = dt / DOOR_OPEN_TIME;
        self.door_open = std.math.clamp(door_target, self.door_open - door_step, self.door_open + door_step);
        self.message_time = @max(self.message_time - dt, 0.0);
    }

    /// The name of the hotspot under the mouse, or "".
    pub fn hoveredName(self: *const Self) []const u8 {
        return switch (self.hovered) {
            .hotspot => |index| room.hotspots[index].name,
            .floor, .nothing => "",
        };
    }

    /// The robot's last remark while it lasts, or "".
    pub fn remark(self: *const Self) []const u8 {
        return if (self.message_time > 0.0) self.message else "";
    }

    fn sendRobot(self: *Self) void {
        switch (self.hovered) {
            .hotspot => |index| {
                const hotspot = room.hotspots[index];
                self.robot.useAt(hotspot.stand_point, .{ .hotspot = index, .facing = hotspot.facing, .action = hotspot.action });
            },
            .floor => |point| self.robot.walkTo(point),
            .nothing => {},
        }
    }

    fn use(self: *Self, kind: room.HotspotKind) void {
        switch (kind) {
            .red_button => {
                if (self.is_alarm_on) {
                    self.is_alarm_on = false;
                    self.say("Alarm off. Quiet at last.");
                } else {
                    self.say("Nothing more happens.");
                }
            },
            // The robot presses it at the console, so it is never in the doorway as the
            // door closes
            .door_button => {
                self.is_door_open = !self.is_door_open;
                self.say(if (self.is_door_open) "A lock clicks. The door slides open." else "The door slides shut.");
            },
            .door => {
                if (self.is_door_open) {
                    // Out of view beyond the doorway; any click in the room brings it back
                    self.robot.leave();
                } else {
                    self.say("Sealed tight.");
                }
            },
            .grey_button => self.say("Click. Nothing happens."),
            .lever => self.say("Stuck."),
            .gauges => self.say("Pressure in the reactor ring is falling."),
            .screen => self.say(if (self.is_alarm_on) "ALARM: COOLANT PUMP 2 OFFLINE" else "COOLANT PUMP 2 OFFLINE (acknowledged)"),
            .breakers => self.say("All breakers are on."),
        }
    }

    fn say(self: *Self, message: []const u8) void {
        self.message = message;
        self.message_time = MESSAGE_TIME;
    }
};
