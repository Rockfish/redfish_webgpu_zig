//! Point and click (plan 021, phase B): hotspots the robot can use, the floor it can walk
//! on, and what the mouse is over.
//!
//! The SCUMM model, with one click: a hotspot has a stand point where the robot stands to
//! use it, a facing it turns to there, and an action (the gesture). Clicking a hotspot
//! sends the robot to use it; clicking the floor sends it to the nearest point it can
//! walk to (`navigation.zig`).

const std = @import("std");
const core = @import("core");
const math = @import("math");

const AABB = core.AABB;
const LineSegment = core.shapes.LineSegment;
const Ray = core.Ray;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// The robot's gesture at a hotspot: a push straight out (buttons at about waist to
/// shoulder height), a push up (controls above the shoulders: a wall keypad, a high
/// panel), or a look.
pub const Action = enum { push, push_high, look };

/// Something the robot can use. `Kind` is the room's list of what its hotspots are.
pub fn Hotspot(comptime Kind: type) type {
    return struct {
        kind: Kind,
        /// Shown while the mouse is over it.
        name: []const u8,
        /// What the mouse ray is tested against.
        bounds: AABB,
        /// Where the robot stands to use it, on the floor (y = 0).
        stand_point: Vec3,
        /// The robot's yaw at the stand point, 0 toward the camera (+z).
        facing: f32,
        action: Action,
        /// The mesh in the room's model that lights up while the mouse is over it (a
        /// control); null for things that don't (doors, the ladder, cabinets looked at).
        mesh: ?[]const u8 = null,
    };
}

/// What the mouse ray points at: a hotspot (its index), or a floor point under what it
/// meets in the room.
pub const Target = union(enum) {
    hotspot: usize,
    floor: Vec3,
    nothing,
};

/// The nearest hotspot the ray hits among those `filter.allows(index)`, else the floor
/// under where it meets the room's inside (`room`: floor, walls, ceiling; the ray comes
/// in through the open front): a click on a wall walks to the foot of the wall, not to
/// the floor beyond it. The floor point is at the room's floor (`room.min.y`). Nothing
/// when the ray misses the room.
pub fn pick(hotspots: anytype, filter: anytype, ray: Ray, room: AABB) Target {
    var nearest: ?usize = null;
    var nearest_distance = std.math.inf(f32);
    for (hotspots, 0..) |hotspot, i| {
        if (!filter.allows(i)) {
            continue;
        }
        if (hotspot.bounds.rayIntersects(ray)) |distance| {
            if (distance < nearest_distance) {
                nearest = i;
                nearest_distance = distance;
            }
        }
    }
    if (nearest) |index| {
        return .{ .hotspot = index };
    }

    if (exitPoint(room, ray)) |point| {
        return .{ .floor = vec3(point.x, room.min.y, point.z) };
    }
    return .nothing;
}

/// Where the ray leaves `box`, if it passes through it ahead of its origin.
fn exitPoint(box: AABB, ray: Ray) ?Vec3 {
    var t_near = -std.math.inf(f32);
    var t_far = std.math.inf(f32);
    const origins = [3]f32{ ray.origin.x, ray.origin.y, ray.origin.z };
    const directions = [3]f32{ ray.direction.x, ray.direction.y, ray.direction.z };
    const mins = [3]f32{ box.min.x, box.min.y, box.min.z };
    const maxs = [3]f32{ box.max.x, box.max.y, box.max.z };
    for (origins, directions, mins, maxs) |origin, direction, min, max| {
        if (direction == 0.0) {
            if (origin < min or origin > max) {
                return null;
            }
            continue;
        }
        const t1 = (min - origin) / direction;
        const t2 = (max - origin) / direction;
        t_near = @max(t_near, @min(t1, t2));
        t_far = @min(t_far, @max(t1, t2));
    }
    if (t_near > t_far or t_far <= 0.0) {
        return null;
    }
    return ray.origin.add(ray.direction.mulScalar(t_far));
}

/// The 12 edges of `bounds`, for a hover outline.
pub fn outline(bounds: AABB) [12]LineSegment {
    const lo = bounds.min;
    const hi = bounds.max;
    const corners = [8]Vec3{
        vec3(lo.x, lo.y, lo.z), vec3(hi.x, lo.y, lo.z), vec3(hi.x, lo.y, hi.z), vec3(lo.x, lo.y, hi.z),
        vec3(lo.x, hi.y, lo.z), vec3(hi.x, hi.y, lo.z), vec3(hi.x, hi.y, hi.z), vec3(lo.x, hi.y, hi.z),
    };
    // Bottom ring, top ring, then the four uprights
    const edges = [12][2]usize{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 },
        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 },
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
    };
    var segments: [12]LineSegment = undefined;
    for (edges, &segments) |edge, *segment| {
        segment.* = .{ .start = corners[edge[0]], .end = corners[edge[1]], .color = .white };
    }
    return segments;
}
