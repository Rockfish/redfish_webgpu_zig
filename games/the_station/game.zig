//! The game: the robot, the station's state (`state.zig`), and the clicks that drive the
//! robot (plan 021, phases B and G; plan 022, phase D). A room's own hotspot is used by
//! its room (`room_01.use`, `room_02.use`); the door and the ladder are crossed here.
//!
//! The game explores the room shown, or is in a transition to the next (`Mode`, plan
//! 022 phase E2): when the robot leaves the room shown, the camera pans to a room beside
//! it, or the screen fades to one above or below. A transition takes no input.
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
const vec3 = math.vec3;

/// Seconds the door takes to slide open.
const DOOR_OPEN_TIME: f32 = 1.2;
/// Seconds a message stays on screen.
const MESSAGE_TIME: f32 = 4.0;
/// How fast the hovered control's highlight eases in and out (`motion.dampAlpha` rate):
/// most of the way in about 0.15 s.
const HIGHLIGHT_RATE: f32 = 20.0;
/// Seconds to fade out, and again to fade in.
const FADE_TIME: f32 = 0.35;
/// The robot's middle above its feet: the room it is in is the room its middle is in,
/// so it changes floors about halfway through the floor on a ladder.
const ROBOT_MIDDLE: f32 = 0.7;

/// What a restart goes back to: the station's state and the robot, doing what it was
/// doing. The default is the start.
pub const Snapshot = struct {
    station: Station = .{},
    robot: Robot = .{ .position = station.place(.room_01, room_01.ROBOT_START) },
};

pub const Mode = union(enum) {
    /// Input drives the robot in the room shown.
    explore,
    transition: Transition,
};

/// From the room shown to room `to`: a pan for a room beside it, which ends as the robot
/// stops (through the doorway); a fade for another floor, out and in again, the room
/// changing between.
pub const Transition = struct {
    to: station.RoomId,
    kind: enum { pan, fade },
    /// Seconds since it started.
    time: f32 = 0.0,
};

pub const Game = struct {
    robot: Robot = .{ .position = station.place(.room_01, room_01.ROBOT_START) },
    station: Station = .{},
    mode: Mode = .explore,
    /// The room shown, and the game as the robot entered it, for going back there.
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
    /// the frame the left button goes down. Only the room shown's hotspots are picked,
    /// and none during a transition.
    pub fn update(self: *Self, ray: ?Ray, clicked: bool, dt: f32) void {
        switch (self.mode) {
            .explore => {
                const filter: RoomFilter = .{ .room = self.room };
                self.hovered = if (ray) |mouse_ray| interaction.pick(&station.hotspots, filter, mouse_ray, station.interior(self.room)) else .nothing;
                if (clicked) {
                    self.sendRobot();
                }
            },
            .transition => self.hovered = .nothing,
        }
        self.updateHighlight(dt);

        if (self.robot.update(dt)) |hotspot| {
            self.use(station.hotspots[hotspot].kind);
        }
        self.updateMode(dt);

        const door_target: f32 = if (self.station.isDoorOpen(.room_01_left)) 1.0 else 0.0;
        const door_step = dt / DOOR_OPEN_TIME;
        self.door_open = std.math.clamp(door_target, self.door_open - door_step, self.door_open + door_step);
        self.message_time = @max(self.message_time - dt, 0.0);
    }

    /// The room the robot is in: the room shown, but during a transition.
    pub fn robotRoom(self: *const Self) station.RoomId {
        return station.roomAt(self.robot.position.add(vec3(0.0, ROBOT_MIDDLE, 0.0)));
    }

    /// 0..1, how far the screen has faded to black.
    pub fn fade(self: *const Self) f32 {
        const transition = switch (self.mode) {
            .transition => |transition| transition,
            .explore => return 0.0,
        };
        return switch (transition.kind) {
            .pan => 0.0,
            .fade => 1.0 - @abs(transition.time - FADE_TIME) / FADE_TIME,
        };
    }

    /// Whether the camera cuts to the room shown rather than panning: while fading.
    pub fn isCut(self: *const Self) bool {
        return switch (self.mode) {
            .transition => |transition| transition.kind == .fade,
            .explore => false,
        };
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
        return .{ .station = self.station, .robot = self.robot };
    }

    /// The game as it was at `saved`; `.{}` restarts it.
    pub fn restore(self: *Self, saved: Snapshot) void {
        self.* = .{
            .robot = saved.robot,
            .station = saved.station,
            .room_entry = saved,
            .door_open = if (saved.station.isDoorOpen(.room_01_left)) 1.0 else 0.0,
        };
        self.room = self.robotRoom();
    }

    /// A transition starts as the robot leaves the room shown; a pan shows its room at
    /// once and ends as the robot stops, a fade changes the room when the screen is
    /// black.
    fn updateMode(self: *Self, dt: f32) void {
        switch (self.mode) {
            .explore => {
                const room = self.robotRoom();
                if (room == self.room) {
                    return;
                }
                const is_beside = station.areSideBySide(self.room, room);
                self.mode = .{ .transition = .{ .to = room, .kind = if (is_beside) .pan else .fade } };
                if (is_beside) {
                    self.enterRoom(room);
                }
            },
            .transition => |transition| {
                var next = transition;
                next.time += dt;
                const is_over = switch (transition.kind) {
                    .pan => self.robot.task == .idle,
                    .fade => next.time >= 2.0 * FADE_TIME,
                };
                if (transition.kind == .fade and transition.time < FADE_TIME and next.time >= FADE_TIME) {
                    self.enterRoom(transition.to);
                }
                self.mode = if (is_over) .explore else .{ .transition = next };
            },
        }
    }

    /// Shows room `id`, and remembers the game as the robot entered it.
    fn enterRoom(self: *Self, id: station.RoomId) void {
        self.room = id;
        self.room_entry = self.snapshot();
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

    /// An open doorway shows the way to the next room, the ladder what a click on it does
    /// (`useLadder`), anything else its action.
    fn hotspotCursor(self: *const Self, index: usize) Cursor {
        const hotspot = station.hotspots[index];
        return switch (hotspot.kind) {
            .doorway => |id| if (station.doorway(id).gate.isOpen(self.station)) self.exitCursor(id) else actionCursor(hotspot.action),
            .ladder => self.ladderCursor(.up),
            .ladder_hole => self.ladderCursor(.down),
            .room_01, .room_02 => actionCursor(hotspot.action),
        };
    }

    /// Toward the doorway's other end.
    fn exitCursor(self: *const Self, id: station.DoorwayId) Cursor {
        const between = station.doorway(id);
        const room = self.robotRoom();
        return if (between.otherEnd(room).x < between.end(room).x) .exit_left else .exit_right;
    }

    /// From the floor, onto the ladder; on it, climbing on toward `direction`, or nothing
    /// at the ladder's end.
    fn ladderCursor(self: *const Self, direction: robot_module.Direction) Cursor {
        if (self.robot.currentLadder() == null) {
            return .climb;
        }
        if (self.robot.nextStop(direction) == null) {
            return .walk;
        }
        return switch (direction) {
            .up => .climb_up,
            .down => .climb_down,
        };
    }

    fn sendRobot(self: *Self) void {
        switch (self.hovered) {
            .hotspot => |index| self.sendToHotspot(index),
            .floor => |point| self.walkTo(point, .stand),
            .nothing => {},
        }
    }

    /// Walks to the hotspot and uses it; through an open doorway to the other room; or
    /// on the ladder (`useLadder`).
    fn sendToHotspot(self: *Self, index: usize) void {
        const hotspot = station.hotspots[index];
        switch (hotspot.kind) {
            .ladder => return self.useLadder(.up),
            .ladder_hole => return self.useLadder(.down),
            .doorway => |id| if (station.doorway(id).gate.isOpen(self.station)) {
                return self.walkThrough(id);
            },
            .room_01, .room_02 => {},
        }
        self.walkTo(hotspot.stand_point, .{ .use = .{ .hotspot = index, .facing = hotspot.facing, .action = hotspot.action } });
    }

    /// From the floor, onto the ladder at this room's stop; on it, on to the next stop
    /// toward `direction`.
    fn useLadder(self: *Self, direction: robot_module.Direction) void {
        if (self.robot.currentLadder() != null) {
            return self.robot.climb(direction);
        }
        const stop = station.ladderStopIn(self.robotRoom()) orelse return;
        self.walkTo(station.ladder.stops[stop].exit, .{ .mount = .{ .ladder = station.ladder, .stop = stop } });
    }

    /// To the doorway's end in this room, then straight through to the other end.
    fn walkThrough(self: *Self, id: station.DoorwayId) void {
        const between = station.doorway(id);
        const room = self.robotRoom();
        var path = self.findPath(between.end(room));
        path.append(between.otherEnd(room));
        self.robot.walk(path, .stand);
    }

    /// A walk to the nearest point to `point` the robot can reach in its room.
    fn walkTo(self: *Self, point: Vec3, then: robot_module.Arrival) void {
        self.robot.walk(self.findPath(point), then);
    }

    /// The path to `point` on the robot's room's floor, on the station. On the ladder,
    /// it climbs to this room's stop first and the path starts at the stop's exit.
    fn findPath(self: *Self, point: Vec3) navigation.Path {
        const id = self.robotRoom();
        if (station.ladderStopIn(id)) |stop| {
            self.robot.climbTo(stop);
        }
        const origin = station.room(id).origin();
        var path = navigation.findPath(station.room(id).walk_areas, self.robot.walkStart().sub(origin), point.sub(origin));
        for (path.points[0..path.len]) |*each| {
            each.* = each.add(origin);
        }
        return path;
    }

    /// A room's own hotspot goes to its room; a doorway is gone through if it is open.
    fn use(self: *Self, kind: station.HotspotKind) void {
        switch (kind) {
            .doorway => |id| {
                if (station.doorway(id).gate.isOpen(self.station)) {
                    // Opened while the robot was on its way to look
                    self.walkThrough(id);
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
    game.hovered = .{ .hotspot = hotspotIndex(.{ .doorway = .room_01_02 }) };
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
    try std.testing.expect(game.mode == .transition);

    game.use(.{ .room_01 = .red_button });
    game.restore(game.room_entry);
    try std.testing.expect(game.station.isAlarmSounding());
    try std.testing.expectEqual(station.RoomId.room_02, game.robotRoom());
}

/// Runs the game `seconds` with no mouse, at 60 frames a second.
fn runFor(game: *Game, seconds: f32) void {
    const dt = 1.0 / 60.0;
    var time: f32 = 0.0;
    while (time < seconds) : (time += dt) {
        game.update(null, false, dt);
    }
}

test "doorway: shut, the robot looks at the door; open, it walks through" {
    var game: Game = .{};
    game.sendToHotspot(hotspotIndex(.{ .doorway = .room_01_02 }));
    runFor(&game, 10.0);
    try std.testing.expectEqualStrings("Sealed tight.", game.message);
    try std.testing.expectEqual(station.RoomId.room_01, game.robotRoom());

    game.station.doors.set(.room_01_left, .open);
    game.sendToHotspot(hotspotIndex(.{ .doorway = .room_01_02 }));
    runFor(&game, 10.0);
    try std.testing.expectEqual(station.RoomId.room_02, game.robotRoom());
    try std.testing.expect(game.robot.position.sub(station.place(.room_02, room_02.DOOR_STAND_POINT)).length() < 1e-3);
}

test "ladder: on at Room 02's stop, down to the next, back up and off to a walk" {
    var game: Game = .{};
    game.robot.position = station.place(.room_02, room_02.DOOR_STAND_POINT);
    game.sendToHotspot(hotspotIndex(.ladder_hole));
    runFor(&game, 10.0);
    try std.testing.expectEqual(@as(?usize, 1), game.robot.nextStop(.down));
    try std.testing.expectEqual(Cursor.walk, game.ladderCursor(.up));

    game.useLadder(.down);
    runFor(&game, 10.0);
    try std.testing.expectEqual(station.ladder.stops[1].position.y, game.robot.position.y);
    try std.testing.expectEqual(Cursor.climb_up, game.ladderCursor(.up));

    const target = station.place(.room_02, vec3(2.0, 0.0, -1.0));
    game.walkTo(target, .stand);
    runFor(&game, 20.0);
    try std.testing.expect(game.robot.currentLadder() == null);
    try std.testing.expect(game.robot.position.sub(target).length() < 1e-3);
}

test "transition: through the doorway, a pan to Room 02 with no input until the robot stops" {
    var game: Game = .{};
    game.station.doors.set(.room_01_left, .open);
    game.sendToHotspot(hotspotIndex(.{ .doorway = .room_01_02 }));
    var frames: usize = 0;
    while (game.mode == .explore and frames < 1000) : (frames += 1) {
        game.update(null, false, 1.0 / 60.0);
    }
    try std.testing.expectEqual(station.RoomId.room_02, game.mode.transition.to);
    try std.testing.expectEqual(station.RoomId.room_02, game.room);
    try std.testing.expectEqual(@as(f32, 0.0), game.fade());

    runFor(&game, 5.0);
    try std.testing.expect(game.mode == .explore);
}

test "transition: a fade is black halfway, where the room shown changes" {
    var game: Game = .{};
    game.mode = .{ .transition = .{ .to = .room_02, .kind = .fade, .time = FADE_TIME - 0.01 } };
    try std.testing.expect(game.isCut());
    try std.testing.expect(game.fade() > 0.9);
    game.update(null, false, 0.02);
    try std.testing.expectEqual(station.RoomId.room_02, game.room);
    game.update(null, false, FADE_TIME);
    try std.testing.expect(game.mode == .explore);
}
