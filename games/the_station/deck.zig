//! The deck: Room 01 (`room_01.zig`) and Room 02 (`room_02.zig`) side by side, joined by
//! Room 01's door (plan 021, phase G). Where the robot can walk on it, every hotspot,
//! which room a point is in, and how to frame each room for the camera, which pans to the
//! robot's room.
//!
//! Both rooms are always drawn; the camera shows one, and the other while it pans.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const room_kit = @import("room_kit.zig");
const room_01 = @import("room_01.zig");
const room_02 = @import("room_02.zig");
const navigation = @import("navigation.zig");
const Hotspot = @import("interaction.zig").Hotspot;
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
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const log = std.log.scoped(.deck);

/// Space shown around a room's cut edges.
const FRAME_MARGIN: f32 = 0.3;

/// The alarm lamp's lens when it isn't glowing: a dull red, so room light doesn't make
/// it look lit (linear).
const ALARM_LENS_DULL = vec4(0.1, 0.012, 0.01, 1.0);

/// The light on the deck: emergency light glows yellowish.
pub const EMERGENCY_TINT = vec3(1.0, 0.72, 0.3);

pub const RoomId = enum { room_01, room_02 };

pub const hotspots = room_01.hotspots ++ room_02.hotspots;

/// Room 01's floor, the doorway (with the door open), and Room 02's floor.
pub const walk_areas = [_]navigation.Area{
    .{ .min_x = room_01.WALK_MIN_X, .max_x = room_01.WALK_MAX_X, .min_z = room_01.WALK_MIN_Z, .max_z = room_01.WALK_MAX_Z },
    .{ .min_x = room_02.DOOR_STAND_POINT.x + 0.25, .max_x = room_01.WALK_MIN_X + 0.05, .min_z = room_kit.DOOR_CENTER_Z - 0.25, .max_z = room_kit.DOOR_CENTER_Z + 0.25, .needs_open_door = true },
} ++ room_02.walk_areas;

/// The room `x` is in: the shared wall's middle divides them.
pub fn roomAt(x: f32) RoomId {
    return if (x < room_01.LEFT_WALL_X) .room_02 else .room_01;
}

pub fn roomCenterX(id: RoomId) f32 {
    return switch (id) {
        .room_01 => 0.0,
        .room_02 => room_02.CENTER_X,
    };
}

/// A room's opening and the cut edges around it, centered on `center_x` (a room's
/// center, or between two while panning).
pub fn framing(center_x: f32) Framing {
    return .{
        .center_x = center_x,
        .center_y = room_01.HEIGHT / 2.0,
        .half_width = room_01.WIDTH / 2.0 + room_kit.WALL + FRAME_MARGIN,
        .half_height = room_01.HEIGHT / 2.0 + room_kit.WALL + FRAME_MARGIN,
    };
}

/// A room's inside, from the floor to the ceiling and the back wall to the open front.
pub fn interior(id: RoomId) AABB {
    const center_x = roomCenterX(id);
    return .{
        .min = vec3(center_x - room_01.WIDTH / 2.0, 0.0, -room_kit.DEPTH),
        .max = vec3(center_x + room_01.WIDTH / 2.0, room_01.HEIGHT, 0.0),
    };
}

/// Whether hotspot `index` is in room `id`, so only the shown room's are picked.
pub fn isHotspotIn(index: usize, id: RoomId) bool {
    return hotspotRoom(index) == id;
}

pub fn hotspotRoom(index: usize) RoomId {
    const bounds = hotspots[index].bounds;
    return roomAt((bounds.min.x + bounds.max.x) / 2.0);
}

pub const Deck = struct {
    cube: *Shape,
    cylinder: *Shape,
    /// Both rooms' shells.
    parts: []Part,
    /// Each room's equipment, by `RoomId`.
    equipment: [2]Equipment,
    /// The alarm lamp, drawn with its glow.
    alarm_lamp: Part,
    /// Room 01's door, drawn where it has slid to.
    door: Part,
    /// The ceiling lights' tubes, lit per draw.
    tubes: []Part,
    /// Each hotspot's mesh in its room's model (`Hotspot.mesh`), found at init; null
    /// without one, or without the model.
    highlight_meshes: [hotspots.len]?usize,

    const Self = @This();

    pub fn init(context: core.Context, gpu: *GpuContext) !Self {
        const cube = try core.shapes.createCube(context.alloc, gpu, .{});
        const cylinder = try core.shapes.createCylinder(context.alloc, gpu, 0.5, 1.0, 24);
        const builder: room_kit.PartBuilder = .{ .cube = cube, .cylinder = cylinder };

        var parts: std.ArrayList(Part) = .empty;
        var tubes: std.ArrayList(Part) = .empty;
        try builder.addShell(context.alloc, &parts, room_01.shell);
        try builder.addShell(context.alloc, &parts, room_02.shell);
        try builder.addCeilingLights(context.alloc, &parts, &tubes, 0.0, room_01.HEIGHT);
        try builder.addCeilingLights(context.alloc, &parts, &tubes, room_02.CENTER_X, room_02.HEIGHT);

        var greybox_01: std.ArrayList(Part) = .empty;
        try room_01.addGreybox(builder, context.alloc, &greybox_01);
        var greybox_02: std.ArrayList(Part) = .empty;
        try room_02.addGreybox(builder, context.alloc, &greybox_02);

        const equipment: [2]Equipment = .{
            .{ .greybox = try greybox_01.toOwnedSlice(context.alloc), .model = loadModel(context, gpu, "room_01", room_01.MODEL_PATH) },
            .{ .greybox = try greybox_02.toOwnedSlice(context.alloc), .model = loadModel(context, gpu, "room_02", room_02.MODEL_PATH) },
        };
        const red = room_01.alarmLightColor(1.0);
        return .{
            .cube = cube,
            .cylinder = cylinder,
            .parts = try parts.toOwnedSlice(context.alloc),
            .equipment = equipment,
            .alarm_lamp = .{
                .shape = cylinder,
                .model = room_kit.cylinderModel(room_01.ALARM_LAMP_POSITION.sub(vec3(0.0, 0.0, 0.1)), .z, 0.3, 0.2),
                .color = vec4(red.x, red.y, red.z, 1.0),
            },
            .door = .{ .shape = cube, .model = Mat4.Identity, .color = room_kit.grey(0.4) },
            .tubes = try tubes.toOwnedSlice(context.alloc),
            .highlight_meshes = findHighlightMeshes(equipment),
        };
    }

    /// `shader` draws the shapes, `model_shader` the equipment models.
    pub fn draw(self: *const Self, frame: *const Frame, shader: *const Shader, model_shader: *const Shader, hatching: Hatching, state: DrawState) void {
        for (self.parts) |part| {
            room_kit.drawPart(frame, shader, part, hatching);
        }
        for (self.equipment, 0..) |equipment, room| {
            const override = self.highlightOverride(@enumFromInt(room), hatching, state.highlight);
            const overrides: []const MeshParams = if (override) |*params| params[0..1] else &.{};
            equipment.draw(frame, shader, model_shader, hatching, state.use_greybox, overrides);
        }

        // From the dull red of an unlit lens to the alarm's red as it glows
        var lamp = self.alarm_lamp;
        lamp.color = ALARM_LENS_DULL.lerp(lamp.color, state.alarm_glow);
        lamp.emissive = state.alarm_glow;
        room_kit.drawPart(frame, shader, lamp, hatching);

        for (self.tubes) |tube| {
            var lit = tube;
            if (state.light_glow > 0.0) {
                lit.color = vec4(EMERGENCY_TINT.x, EMERGENCY_TINT.y, EMERGENCY_TINT.z, 1.0);
                lit.emissive = state.light_glow;
            }
            room_kit.drawPart(frame, shader, lit, hatching);
        }

        var door = self.door;
        const door_z = room_kit.DOOR_CENTER_Z - room_kit.DOOR_WIDTH * state.door_open;
        door.model = room_kit.box(vec3(room_01.LEFT_WALL_X, room_kit.DOOR_HEIGHT / 2.0, door_z), vec3(0.08, room_kit.DOOR_HEIGHT, room_kit.DOOR_WIDTH));
        room_kit.drawPart(frame, shader, door, hatching);
    }

    /// The highlighted control's params, if it is a mesh in room `room`'s model.
    fn highlightOverride(self: *const Self, room: RoomId, hatching: Hatching, highlight: ?Highlight) ?MeshParams {
        const lit = highlight orelse return null;
        const mesh = self.highlight_meshes[lit.hotspot] orelse return null;
        if (hotspotRoom(lit.hotspot) != room) {
            return null;
        }
        return .{ .mesh = mesh, .params = vec4(lit.amount, 0.0, hatching.strength, hatching.spacing) };
    }

    pub fn cleanUp(self: *const Self) void {
        self.cube.releaseGpuObjects();
        self.cylinder.releaseGpuObjects();
        for (self.equipment) |equipment| {
            if (equipment.model) |model| {
                model.cleanUp();
            }
        }
    }
};

/// A room's equipment: the Blender model, or boxes without it.
const Equipment = struct {
    /// Drawn without the model, or with the panel's "greybox room".
    greybox: []Part,
    /// From Blender; null without the-station's model.
    model: ?*ModelInstance,

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
                model.drawWithMeshParams(frame, model_shader, Mat4.Identity, params, overrides);
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

/// What changes from frame to frame in how the deck looks.
pub const DrawState = struct {
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

/// Each hotspot's mesh in its room's model, warning about a name the model doesn't have.
fn findHighlightMeshes(equipment: [2]Equipment) [hotspots.len]?usize {
    var meshes: [hotspots.len]?usize = @splat(null);
    for (hotspots, &meshes, 0..) |hotspot, *mesh, index| {
        const name = hotspot.mesh orelse continue;
        const model = equipment[@intFromEnum(hotspotRoom(index))].model orelse continue;
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
