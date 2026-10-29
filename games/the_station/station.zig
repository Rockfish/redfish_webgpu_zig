//! The station (plan 022, phase C): its rooms on the room grid (`room_kit.zig`), each
//! described by its own file in its own coordinates (`room_01.room`, `room_02.room`), and
//! placed here at its origin. The connections between rooms (phase E: doorways, the
//! ladder), every hotspot, which room a point is in, how to frame each room for the
//! camera, and drawing the rooms the camera sees.
//!
//! Room 02 is left of Room 01 through Room 01's door; Rooms 03 and 04 are below Room 02,
//! down its ladder (`shaft.zig`); the generator room, under Room 01, is through Room
//! 04's right wall. The camera shows the robot's room and pans or fades to
//! the next (`game.zig`); a neighbor shows at the frame's edge.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const room_01 = @import("room_01.zig");
const room_02 = @import("room_02.zig");
const room_03 = @import("room_03.zig");
const room_04 = @import("room_04.zig");
const generator_room = @import("generator_room.zig");
const navigation = @import("navigation.zig");
const interaction = @import("interaction.zig");
const robot = @import("robot.zig");
const shaft = @import("shaft.zig");
const station_state = @import("state.zig");
const Ladder = robot.Ladder;
const LadderStop = robot.LadderStop;
const Framing = @import("room_camera.zig").Framing;
const AABB = core.AABB;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const MeshParams = core.MeshParams;
const ModelInstance = core.ModelInstance;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Hatching = room_kit.Hatching;
const Part = room_kit.Part;
const PartBuilder = room_kit.PartBuilder;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const log = std.log.scoped(.station);

/// Space shown around a room's cut edges.
const FRAME_MARGIN: f32 = 0.3;
/// The most of a room the camera shows: Room 01's size, so the robot is the same size on
/// screen in a larger room (`cameraFraming`).
const WINDOW_CELLS_WIDE = 3;
const WINDOW_CELLS_HIGH = 1;

/// The alarm lamp's lens when it isn't glowing: a dull red, so room light doesn't make
/// it look lit (linear).
const ALARM_LENS_DULL = vec4(0.1, 0.012, 0.01, 1.0);

/// The emergency lights glow yellowish.
pub const EMERGENCY_TINT = vec3(1.0, 0.72, 0.3);

/// What each hotspot on the station is: a connection, which the game crosses, or a
/// room's own, which its `use` handles (`room_01.use`, `room_02.use`). A doorway is a
/// hotspot in each of its rooms; the ladder is two in a room, its part above the floor
/// (climbs up) and its part below (climbs down).
pub const HotspotKind = union(enum) {
    doorway: DoorwayId,
    ladder,
    ladder_hole,
    room_01: room_01.HotspotKind,
    room_02: room_02.HotspotKind,
    generator_room: generator_room.HotspotKind,
};

pub const Hotspot = interaction.Hotspot(HotspotKind);

/// A room on the station: its place on the grid and what is in it, in its own
/// coordinates (`room_kit.zig`).
pub const Room = struct {
    name: []const u8,
    /// Its lower-left cell on the grid: Room 01 is at column 0, row 0; rows go up.
    column: i32,
    row: i32,
    /// Its size in cells.
    cells_wide: u32,
    cells_high: u32,
    /// Its equipment from Blender; null for a greybox room.
    model_path: ?[]const u8,
    shell: room_kit.Shell,
    walk_areas: []const navigation.Area,
    /// A hole in its floor (a ladder down), built in the ceiling of the room below.
    floor_hole: ?room_kit.Hole = null,
    hotspots: []const Hotspot,
    /// Where its ceiling tube lights are across it: two in a room 3 cells wide.
    ceiling_lights: []const f32 = &.{ -1.8, 1.8 },
    /// How far below the ceiling they hang, on rods (in a tall room).
    ceiling_light_drop: f32 = 0.0,
    /// Its equipment as boxes, drawn without the model.
    addGreybox: *const fn (PartBuilder, std.mem.Allocator, *std.ArrayList(Part)) std.mem.Allocator.Error!void,

    /// Where the room's own coordinates start on the station: its floor, at the middle of
    /// its opening.
    pub fn origin(self: Room) Vec3 {
        const column: f32 = @floatFromInt(self.column);
        const row: f32 = @floatFromInt(self.row);
        const cells_wide: f32 = @floatFromInt(self.cells_wide);
        return vec3((column + cells_wide / 2.0) * room_kit.CELL_WIDTH, row * room_kit.CELL_HEIGHT, 0.0);
    }

    pub fn width(self: Room) f32 {
        return room_kit.insideWidth(self.cells_wide);
    }

    pub fn height(self: Room) f32 {
        return room_kit.insideHeight(self.cells_high);
    }
};

pub const RoomId = enum { room_01, room_02, room_03, room_04, generator_room };
pub const ROOM_COUNT = std.enums.values(RoomId).len;

/// By `RoomId`.
pub const rooms = [ROOM_COUNT]Room{ room_01.room, room_02.room, room_03.room, room_04.room, generator_room.room };

pub fn room(id: RoomId) Room {
    return rooms[@intFromEnum(id)];
}

/// `point` in room `id`'s coordinates, on the station.
pub fn place(id: RoomId, point: Vec3) Vec3 {
    return point.add(room(id).origin());
}

/// Every room's hotspots, on the station, and the room each is in.
pub const hotspots = placeHotspots();
const hotspot_rooms = hotspotRooms();

/// What must be so for the robot to go through a connection.
pub const Gate = union(enum) {
    always,
    /// The door is open.
    door: station_state.DoorId,

    pub fn isOpen(self: Gate, station: station_state.Station) bool {
        return switch (self) {
            .always => true,
            .door => |door| station.isDoorOpen(door),
        };
    }
};

/// A way through a side wall between two rooms: an end in each, where the robot stands,
/// and a straight walk between them.
pub const Doorway = struct {
    rooms: [2]RoomId,
    /// On the station, by `rooms`.
    ends: [2]Vec3,
    gate: Gate,

    /// The end in room `id`.
    pub fn end(self: Doorway, id: RoomId) Vec3 {
        return if (self.rooms[0] == id) self.ends[0] else self.ends[1];
    }

    /// The end in the room on the other side from room `id`.
    pub fn otherEnd(self: Doorway, id: RoomId) Vec3 {
        return if (self.rooms[0] == id) self.ends[1] else self.ends[0];
    }
};

pub const DoorwayId = enum { room_01_02, room_04_generator };

/// By `DoorwayId`.
const doorways = [_]Doorway{
    .{
        .rooms = .{ .room_01, .room_02 },
        .ends = .{ place(.room_01, room_01.DOOR_STAND_POINT), place(.room_02, room_02.DOOR_STAND_POINT) },
        .gate = .{ .door = .room_01_left },
    },
    .{
        .rooms = .{ .room_04, .generator_room },
        .ends = .{ place(.room_04, room_04.DOOR_STAND_POINT), place(.generator_room, generator_room.DOOR_STAND_POINT) },
        .gate = .always,
    },
};

pub fn doorway(id: DoorwayId) Doorway {
    return doorways[@intFromEnum(id)];
}

/// The ladder from Room 02 down to Room 04, on the station (`shaft.zig`).
pub const ladder: Ladder = .{ .stops = &ladder_stops, .facing = shaft.LADDER_FACING };
/// From the top down.
const ladder_stops = [_]LadderStop{
    placeStop(.room_02, room_02.ladder_stop),
    placeStop(.room_03, room_03.ladder_stop),
    placeStop(.room_04, room_04.ladder_stop),
};

/// The ladder's stop in room `id` (the first, from the top), or null.
pub fn ladderStopIn(id: RoomId) ?usize {
    for (ladder_stops, 0..) |stop, index| {
        if (roomAt(stop.position) == id) {
            return index;
        }
    }
    return null;
}

/// The room `position` is in: inside its walls (a shared wall's middle divides two
/// rooms), from the bottom of its floor to its ceiling. Outside every room (in the deck
/// below a room), the nearest.
pub fn roomAt(position: Vec3) RoomId {
    var nearest: RoomId = .room_01;
    var nearest_distance = std.math.inf(f32);
    for (std.enums.values(RoomId)) |id| {
        const space = roomSpace(id);
        if (position.x >= space.min.x and position.x < space.max.x and position.y >= space.min.y and position.y < space.max.y) {
            return id;
        }
        const nearest_point = vec3(
            std.math.clamp(position.x, space.min.x, space.max.x),
            std.math.clamp(position.y, space.min.y, space.max.y),
            position.z,
        );
        const distance = nearest_point.sub(position).length();
        if (distance < nearest_distance) {
            nearest = id;
            nearest_distance = distance;
        }
    }
    return nearest;
}

/// Whether rooms `a` and `b` share a row of cells: beside each other, not on other
/// floors.
pub fn areSideBySide(a: RoomId, b: RoomId) bool {
    const first = room(a);
    const second = room(b);
    const first_top = first.row + @as(i32, @intCast(first.cells_high));
    const second_top = second.row + @as(i32, @intCast(second.cells_high));
    return first.row < second_top and second.row < first_top;
}

/// What the camera shows of room `id`: all of a room up to `WINDOW_CELLS_WIDE` x
/// `WINDOW_CELLS_HIGH` cells (`framing`); of a larger one a window that size around
/// `focus` (the robot), kept inside the room's framing, with the eye above the window's
/// floor. `is_whole_room` frames every room whole (the panel's option).
pub fn cameraFraming(id: RoomId, focus: Vec3, is_whole_room: bool) Framing {
    const whole = framing(id);
    const shown = room(id);
    if (is_whole_room or (shown.cells_wide <= WINDOW_CELLS_WIDE and shown.cells_high <= WINDOW_CELLS_HIGH)) {
        return whole;
    }
    const half_width = room_kit.insideWidth(WINDOW_CELLS_WIDE) / 2.0 + room_kit.WALL + FRAME_MARGIN;
    const inside_height = room_kit.insideHeight(WINDOW_CELLS_HIGH);
    const half_height = inside_height / 2.0 + room_kit.WALL + FRAME_MARGIN;
    const center_x = std.math.clamp(focus.x, whole.center_x - whole.half_width + half_width, whole.center_x + whole.half_width - half_width);
    const center_y = std.math.clamp(focus.y + inside_height / 2.0, whole.center_y - whole.half_height + half_height, whole.center_y + whole.half_height - half_height);
    return .{
        .center_x = center_x,
        .center_y = center_y,
        .half_width = half_width,
        .half_height = half_height,
        .floor_y = center_y - inside_height / 2.0,
    };
}

/// A room's opening and the cut edges around it, on the opening's plane (z = 0).
pub fn framing(id: RoomId) Framing {
    const shown = room(id);
    const origin = shown.origin();
    return .{
        .center_x = origin.x,
        .center_y = origin.y + shown.height() / 2.0,
        .half_width = shown.width() / 2.0 + room_kit.WALL + FRAME_MARGIN,
        .half_height = shown.height() / 2.0 + room_kit.WALL + FRAME_MARGIN,
        .floor_y = origin.y,
    };
}

/// A room's inside, from the floor to the ceiling and the back wall to the open front.
pub fn interior(id: RoomId) AABB {
    const inside = room(id);
    return .{
        .min = place(id, vec3(-inside.width() / 2.0, 0.0, -room_kit.DEPTH)),
        .max = place(id, vec3(inside.width() / 2.0, inside.height(), 0.0)),
    };
}

/// Whether hotspot `index` is in room `id`, so only the shown room's are picked.
pub fn isHotspotIn(index: usize, id: RoomId) bool {
    return hotspot_rooms[index] == id;
}

/// Whether room `id` draws anything the camera sees (`drawnSpace`), so it is drawn.
/// What the camera shows: `view` on the opening's plane (fitted to the screen), seen
/// from `eye`; `back_scale` is how much smaller the back of a room looks than its
/// opening (`RoomCamera.depthScale`; 1 without perspective).
pub fn isVisible(id: RoomId, view: Framing, eye: Vec3, back_scale: f32) bool {
    const space = drawnSpace(id);
    // Its back, seen from the eye, falls closer to the eye's line than its opening
    const back_min_x = eye.x + (space.min.x - eye.x) * back_scale;
    const back_max_x = eye.x + (space.max.x - eye.x) * back_scale;
    const back_min_y = eye.y + (space.min.y - eye.y) * back_scale;
    const back_max_y = eye.y + (space.max.y - eye.y) * back_scale;
    const min_x = @min(space.min.x, back_min_x);
    const max_x = @max(space.max.x, back_max_x);
    const min_y = @min(space.min.y, back_min_y);
    const max_y = @max(space.max.y, back_max_y);
    return min_x < view.center_x + view.half_width and max_x > view.center_x - view.half_width and
        min_y < view.center_y + view.half_height and max_y > view.center_y - view.half_height;
}

/// The hole in room `id`'s ceiling, in its coordinates: the floor hole of a room right
/// above it.
pub fn ceilingHole(id: RoomId) ?room_kit.Hole {
    const below = room(id);
    for (rooms) |above| {
        const hole = above.floor_hole orelse continue;
        if (above.row != below.row + @as(i32, @intCast(below.cells_high))) {
            continue;
        }
        const shift = above.origin().x - below.origin().x;
        const moved: room_kit.Hole = .{ .min_x = hole.min_x + shift, .max_x = hole.max_x + shift, .min_z = hole.min_z, .max_z = hole.max_z };
        if (moved.min_x >= -below.width() / 2.0 and moved.max_x <= below.width() / 2.0) {
            return moved;
        }
    }
    return null;
}

/// Room `id`'s emergency light at the fitting at `x` (`Room.ceiling_lights`): just
/// under its tube.
pub fn emergencyLightPosition(id: RoomId, x: f32) Vec3 {
    const fitting_y = room(id).height() - room(id).ceiling_light_drop;
    return place(id, vec3(x, fitting_y - 0.3, room_kit.CEILING_LIGHT_Z));
}

/// What a light in room `id` reaches: its inside, a little past its floor and walls (to
/// light their faces), up to just under the ceiling (the fittings' housings shade it).
pub fn lightBounds(id: RoomId) AABB {
    const inside = interior(id);
    const margin = vec3(0.05, 0.05, 0.05);
    return .{
        .min = inside.min.sub(margin),
        .max = vec3(inside.max.x + margin.x, inside.max.y - 0.12, inside.max.z + margin.z),
    };
}

/// The rooms' parts and models, drawn from the station's state (`DrawState`).
pub const Scenery = struct {
    cube: *Shape,
    cylinder: *Shape,
    /// Each room's parts and equipment, by `RoomId`.
    rooms: [ROOM_COUNT]RoomParts,
    /// Room 01's alarm lamp, drawn with its glow.
    alarm_lamp: Part,
    /// Room 01's door, drawn where it has slid to.
    door: Part,
    /// Each hotspot's mesh in its room's model (`Hotspot.mesh`), found at init; null
    /// without one, or without the model.
    highlight_meshes: [hotspots.len]?usize,

    const Self = @This();

    pub fn init(context: core.Context, gpu: *GpuContext) !Self {
        const cube = try core.shapes.createCube(context.alloc, gpu, .{});
        const cylinder = try core.shapes.createCylinder(context.alloc, gpu, 0.5, 1.0, 24);
        const builder: PartBuilder = .{ .cube = cube, .cylinder = cylinder };

        var room_parts: [ROOM_COUNT]RoomParts = undefined;
        for (std.enums.values(RoomId), &room_parts) |id, *parts| {
            parts.* = try RoomParts.init(context, gpu, builder, id);
        }

        const red = room_01.alarmLightColor(1.0);
        const lamp_position = place(.room_01, room_01.ALARM_LAMP_POSITION.sub(vec3(0.0, 0.0, 0.1)));
        return .{
            .cube = cube,
            .cylinder = cylinder,
            .rooms = room_parts,
            .alarm_lamp = .{
                .shape = cylinder,
                .model = room_kit.cylinderModel(lamp_position, .z, 0.3, 0.2),
                .color = vec4(red.x, red.y, red.z, 1.0),
            },
            .door = .{ .shape = cube, .model = Mat4.Identity, .color = room_kit.grey(0.4) },
            .highlight_meshes = findHighlightMeshes(room_parts),
        };
    }

    /// The rooms in `state.visible`. `shader` draws the shapes, `model_shader` the
    /// equipment models.
    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, model_shader: *const Shader, hatching: Hatching, state: DrawState) void {
        for (std.enums.values(RoomId), self.rooms) |id, parts| {
            if (!state.visible.contains(id)) {
                continue;
            }
            const override = self.highlightOverride(id, hatching, state.highlight);
            const overrides: []const MeshParams = if (override) |*params| params[0..1] else &.{};
            parts.draw(frame, shader, model_shader, hatching, state, overrides);
        }
        if (state.visible.contains(.room_01)) {
            self.drawRoom01(frame, shader, hatching, state);
        }
    }

    pub fn cleanUp(self: *const Self) void {
        self.cube.releaseGpuObjects();
        self.cylinder.releaseGpuObjects();
        for (self.rooms) |parts| {
            if (parts.equipment.model) |model| {
                model.cleanUp();
            }
        }
    }

    /// The highlighted control's params, if it is a mesh in room `id`'s model.
    fn highlightOverride(self: *const Self, id: RoomId, hatching: Hatching, highlight: ?Highlight) ?MeshParams {
        const lit = highlight orelse return null;
        const mesh = self.highlight_meshes[lit.hotspot] orelse return null;
        if (hotspot_rooms[lit.hotspot] != id) {
            return null;
        }
        return .{ .mesh = mesh, .params = vec4(lit.amount, 0.0, hatching.strength, hatching.spacing) };
    }

    /// What changes in Room 01 from frame to frame: the alarm lamp and the door.
    fn drawRoom01(self: *const Self, frame: *const Frame, shader: *const Shader, hatching: Hatching, state: DrawState) void {
        // From the dull red of an unlit lens to the alarm's red as it glows
        var lamp = self.alarm_lamp;
        lamp.color = ALARM_LENS_DULL.lerp(lamp.color, state.alarm_glow);
        lamp.emissive = state.alarm_glow;
        room_kit.drawPart(frame, shader, lamp, hatching);

        var door = self.door;
        const door_z = room_kit.DOOR_CENTER_Z - room_kit.DOOR_WIDTH * state.door_open;
        const door_center = place(.room_01, vec3(room_01.LEFT_WALL_X, room_kit.DOOR_HEIGHT / 2.0, door_z));
        door.model = room_kit.box(door_center, vec3(0.08, room_kit.DOOR_HEIGHT, room_kit.DOOR_WIDTH));
        room_kit.drawPart(frame, shader, door, hatching);
    }
};

/// One room's shell, ceiling lights, and equipment, placed on the station.
const RoomParts = struct {
    shell: []Part,
    /// The ceiling lights' tubes, lit per draw.
    tubes: []Part,
    equipment: Equipment,

    fn init(context: core.Context, gpu: *GpuContext, builder: PartBuilder, id: RoomId) !RoomParts {
        const built = room(id);
        const origin = built.origin();

        var shell: std.ArrayList(Part) = .empty;
        var tubes: std.ArrayList(Part) = .empty;
        try builder.addShell(context.alloc, &shell, built.shell, ceilingHole(id));
        const fitting_y = built.height() - built.ceiling_light_drop;
        try builder.addCeilingLights(context.alloc, &shell, &tubes, built.ceiling_lights, fitting_y, built.height());
        var greybox: std.ArrayList(Part) = .empty;
        try built.addGreybox(builder, context.alloc, &greybox);

        const parts: RoomParts = .{
            .shell = try shell.toOwnedSlice(context.alloc),
            .tubes = try tubes.toOwnedSlice(context.alloc),
            .equipment = .{
                .greybox = try greybox.toOwnedSlice(context.alloc),
                .model = if (built.model_path) |path| loadModel(context, gpu, built.name, path) else null,
                .origin = origin,
            },
        };
        room_kit.placeParts(parts.shell, origin);
        room_kit.placeParts(parts.tubes, origin);
        room_kit.placeParts(parts.equipment.greybox, origin);
        return parts;
    }

    fn draw(
        self: RoomParts,
        frame: *const Frame,
        shader: *const Shader,
        model_shader: *const Shader,
        hatching: Hatching,
        state: DrawState,
        overrides: []const MeshParams,
    ) void {
        for (self.shell) |part| {
            room_kit.drawPart(frame, shader, part, hatching);
        }
        self.equipment.draw(frame, shader, model_shader, hatching, state.use_greybox, overrides);
        for (self.tubes) |tube| {
            var lit = tube;
            if (state.light_glow > 0.0) {
                lit.color = vec4(EMERGENCY_TINT.x, EMERGENCY_TINT.y, EMERGENCY_TINT.z, 1.0);
                lit.emissive = state.light_glow;
            }
            room_kit.drawPart(frame, shader, lit, hatching);
        }
    }
};

/// A room's equipment: the Blender model, or boxes without it.
const Equipment = struct {
    /// Drawn without the model, or with the panel's "greybox room".
    greybox: []Part,
    /// From Blender, in the room's coordinates; null without the-station's model.
    model: ?*ModelInstance,
    /// Where the model is placed.
    origin: Vec3,

    /// `overrides` light up a control in the model; the greybox has none.
    fn draw(
        self: Equipment,
        frame: *const Frame,
        shader: *const Shader,
        model_shader: *const Shader,
        hatching: Hatching,
        use_greybox: bool,
        overrides: []const MeshParams,
    ) void {
        if (self.model) |model| {
            if (!use_greybox) {
                const params = vec4(0.0, 0.0, hatching.strength, hatching.spacing);
                model.drawWithMeshParams(frame, model_shader, Mat4.fromTranslation(self.origin), params, overrides);
                return;
            }
        }
        for (self.greybox) |part| {
            room_kit.drawPart(frame, shader, part, hatching);
        }
    }
};

/// The hovered control lit up, `amount` 0..1.
pub const Highlight = struct {
    hotspot: usize,
    amount: f32,
};

/// What changes from frame to frame in how the station looks.
pub const DrawState = struct {
    /// The rooms the camera sees (`isVisible`); only they are drawn.
    visible: std.EnumSet(RoomId),
    /// 0..1: how lit the alarm lamp is (0 is off, a dull red lens).
    alarm_glow: f32,
    /// 0..1: how much the ceiling lights' tubes glow (0 is off).
    light_glow: f32,
    /// 0..1: how far the door has slid into the wall.
    door_open: f32,
    /// The rooms' equipment as boxes, not the models.
    use_greybox: bool,
    highlight: ?Highlight = null,
};

/// A room's space on the station, its cells: inside its walls (to their middles), from
/// the bottom of its floor to its ceiling, where the room above starts.
fn roomSpace(id: RoomId) AABB {
    const inside = room(id);
    const half_width = inside.width() / 2.0 + room_kit.WALL / 2.0;
    return .{
        .min = place(id, vec3(-half_width, -room_kit.WALL, -room_kit.DEPTH - room_kit.WALL)),
        .max = place(id, vec3(half_width, inside.height(), 0.0)),
    };
}

/// What a room's parts cover: its space, the deck below it (`Shell.floor`), and solid
/// station above it (`Shell.deck_above`).
fn drawnSpace(id: RoomId) AABB {
    var space = roomSpace(id);
    switch (room(id).shell.floor) {
        .deck => space.min.y -= room_kit.BELOW_DEPTH,
        .room_below => {},
    }
    if (room(id).shell.deck_above != null) {
        space.max.y += room_kit.WALL + room_kit.CELL_HEIGHT;
    }
    return space;
}

fn hotspotCount() usize {
    var count: usize = 0;
    for (rooms) |each| {
        count += each.hotspots.len;
    }
    return count;
}

fn placeHotspots() [hotspotCount()]Hotspot {
    var placed: [hotspotCount()]Hotspot = undefined;
    var index: usize = 0;
    for (rooms) |each| {
        const origin = each.origin();
        for (each.hotspots) |hotspot| {
            placed[index] = hotspot;
            placed[index].bounds = .{ .min = hotspot.bounds.min.add(origin), .max = hotspot.bounds.max.add(origin) };
            placed[index].stand_point = hotspot.stand_point.add(origin);
            index += 1;
        }
    }
    return placed;
}

fn hotspotRooms() [hotspotCount()]RoomId {
    var placed: [hotspotCount()]RoomId = undefined;
    var index: usize = 0;
    for (rooms, 0..) |each, room_index| {
        for (each.hotspots) |_| {
            placed[index] = @enumFromInt(room_index);
            index += 1;
        }
    }
    return placed;
}

fn placeStop(id: RoomId, stop: LadderStop) LadderStop {
    return .{ .position = place(id, stop.position), .exit = place(id, stop.exit) };
}

/// Each hotspot's mesh in its room's model, warning about a name the model doesn't have.
fn findHighlightMeshes(room_parts: [ROOM_COUNT]RoomParts) [hotspots.len]?usize {
    var meshes: [hotspots.len]?usize = @splat(null);
    for (hotspots, &meshes, hotspot_rooms) |hotspot, *mesh, id| {
        const name = hotspot.mesh orelse continue;
        const model = room_parts[@intFromEnum(id)].equipment.model orelse continue;
        mesh.* = model.findMesh(name);
        if (mesh.* == null) {
            log.warn("{s}: no mesh named {s} for its highlight", .{ hotspot.name, name });
        }
    }
    return meshes;
}

/// Null, with a warning, when the model can't be loaded (no the-station checkout).
fn loadModel(context: core.Context, gpu: *GpuContext, name: []const u8, path: []const u8) ?*ModelInstance {
    return ModelInstance.initWithConfig(context, gpu, .{ .name = name, .file_path = path }) catch |err| {
        log.warn("{s} not loaded ({s}); drawing the greybox room", .{ path, @errorName(err) });
        return null;
    };
}

const testing = std.testing;

fn expectPoint(expected: Vec3, actual: Vec3) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, 1e-5);
    try testing.expectApproxEqAbs(expected.y, actual.y, 1e-5);
    try testing.expectApproxEqAbs(expected.z, actual.z, 1e-5);
}

test "rooms on the grid: Room 01 right of Room 02, one wall between them" {
    try expectPoint(vec3(4.2, 0.0, 0.0), room(.room_01).origin());
    try expectPoint(vec3(-4.2, 0.0, 0.0), room(.room_02).origin());
    try testing.expectApproxEqAbs(@as(f32, 8.0), room(.room_01).width(), 1e-6);
}

test "roomAt: the shared wall's middle divides the rooms; the ladder's bottom is Room 02's" {
    try testing.expectEqual(RoomId.room_01, roomAt(vec3(4.2, 0.0, -2.0)));
    try testing.expectEqual(RoomId.room_01, roomAt(vec3(0.1, 0.0, -2.0)));
    try testing.expectEqual(RoomId.room_02, roomAt(vec3(-0.1, 0.0, -2.0)));
    try testing.expectEqual(RoomId.room_04, roomAt(ladder.stops[ladder.stops.len - 1].position));
}

test "hotspots, doorways, and the ladder are placed by their room's origin" {
    for (hotspots, hotspot_rooms) |hotspot, id| {
        try testing.expect(roomAt(hotspot.stand_point) == id);
    }
    for (doorways) |each| {
        for (each.rooms, each.ends) |id, end| {
            try testing.expect(roomAt(end) == id);
        }
    }
    try testing.expectEqual(@as(?usize, 0), ladderStopIn(.room_02));
    try testing.expectEqual(@as(?usize, 1), ladderStopIn(.room_03));
    try testing.expectEqual(@as(?usize, 2), ladderStopIn(.room_04));
    try testing.expectEqual(@as(?usize, null), ladderStopIn(.room_01));
}

test "areSideBySide: Rooms 01 and 02 share row 0; Rooms 02, 03, and 04 are floors apart" {
    try testing.expect(areSideBySide(.room_01, .room_02));
    try testing.expect(areSideBySide(.room_02, .room_02));
    try testing.expect(!areSideBySide(.room_02, .room_03));
    try testing.expect(!areSideBySide(.room_03, .room_04));
    try testing.expect(areSideBySide(.room_04, .generator_room));
    try testing.expect(!areSideBySide(.room_01, .generator_room));
}

test "rooms on rows: Room 03 under Room 02, Room 04 under Room 03; the floors between" {
    try expectPoint(vec3(-4.2, -3.4, 0.0), room(.room_03).origin());
    try expectPoint(vec3(-4.2, -6.8, 0.0), room(.room_04).origin());
    // Room 02's floor slab is Room 02's; just under it, Room 03's ceiling space
    try testing.expectEqual(RoomId.room_02, roomAt(vec3(-4.2, -0.3, -2.0)));
    try testing.expectEqual(RoomId.room_03, roomAt(vec3(-4.2, -0.5, -2.0)));
    // The generator room beside Rooms 03 and 04, under Room 01
    try testing.expectEqual(RoomId.generator_room, roomAt(vec3(0.5, -2.0, -2.0)));
    try testing.expectEqual(RoomId.generator_room, roomAt(vec3(0.5, -6.8, -2.0)));
}

test "cameraFraming: a window of the generator room follows the robot, inside the room" {
    const whole = framing(.generator_room);
    const left = cameraFraming(.generator_room, place(.generator_room, vec3(-8.0, 0.0, -1.0)), false);
    try testing.expectApproxEqAbs(framing(.room_01).half_width, left.half_width, 1e-5);
    try testing.expectApproxEqAbs(whole.center_x - whole.half_width, left.center_x - left.half_width, 1e-5);
    try testing.expectApproxEqAbs(room(.generator_room).origin().y, left.floor_y, 1e-5);
    const middle = cameraFraming(.generator_room, place(.generator_room, vec3(1.0, 0.0, -1.0)), false);
    try testing.expectApproxEqAbs(place(.generator_room, vec3(1.0, 0.0, 0.0)).x, middle.center_x, 1e-5);
    try testing.expectEqual(whole, cameraFraming(.generator_room, Vec3.Zero, true));
    try testing.expectEqual(framing(.room_01), cameraFraming(.room_01, Vec3.Zero, false));
}

test "ceilingHole: Rooms 03 and 04 have the shaft's hole, from the floor above" {
    try testing.expectEqual(shaft.HOLE, ceilingHole(.room_03).?);
    try testing.expectEqual(shaft.HOLE, ceilingHole(.room_04).?);
    try testing.expectEqual(@as(?room_kit.Hole, null), ceilingHole(.room_02));
    try testing.expectEqual(@as(?room_kit.Hole, null), ceilingHole(.generator_room));
}

test "a doorway's gate: the door between Rooms 01 and 02 opens it" {
    const between = doorway(.room_01_02);
    var station: station_state.Station = .{};
    try testing.expect(!between.gate.isOpen(station));
    station.doors.set(.room_01_left, .open);
    try testing.expect(between.gate.isOpen(station));
    try expectPoint(place(.room_02, room_02.DOOR_STAND_POINT), between.otherEnd(.room_01));
}

test "isVisible: a room's neighbor shows at the edge; a far view shows neither" {
    const RoomCamera = @import("room_camera.zig").RoomCamera;
    const view = RoomCamera.fitToAspect(framing(.room_01), 16.0 / 9.0);
    const eye = vec3(view.center_x, 1.9, 6.0);
    const back_scale = 6.0 / (6.0 + room_kit.DEPTH + room_kit.WALL);
    try testing.expect(!isVisible(.room_04, view, eye, back_scale));

    // From Room 04, the generator room beside it
    const below = RoomCamera.fitToAspect(framing(.room_04), 16.0 / 9.0);
    const below_eye = vec3(below.center_x, below.floor_y + 1.9, 6.0);
    try testing.expect(isVisible(.generator_room, below, below_eye, back_scale));
    try testing.expect(isVisible(.room_01, view, eye, back_scale));
    try testing.expect(isVisible(.room_02, view, eye, back_scale));

    var far = view;
    far.center_x += 40.0;
    const far_eye = vec3(far.center_x, 1.9, 6.0);
    try testing.expect(!isVisible(.room_01, far, far_eye, back_scale));
    try testing.expect(!isVisible(.room_02, far, far_eye, back_scale));
}
