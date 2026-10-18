//! Point and click (plan 021, phase B): hotspots the robot can use, the floor it can walk
//! on, and what the mouse is over.
//!
//! The SCUMM model, with one click: a hotspot has a stand point where the robot stands to
//! use it, a facing it turns to there, and an action (the gesture). Clicking a hotspot
//! sends the robot to use it; clicking the floor sends it to the nearest point it can
//! walk to.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const AABB = core.AABB;
const LineSegment = core.shapes.LineSegment;
const Ray = core.Ray;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// The robot's gesture at a hotspot.
pub const Action = enum { push, look };

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
    };
}

/// A rectangle of floor the robot can walk on. One rectangle is enough for Room 01: any
/// two points in it can be walked between in a straight line.
pub const WalkArea = struct {
    min_x: f32,
    max_x: f32,
    min_z: f32,
    max_z: f32,

    pub fn nearestPoint(self: WalkArea, point: Vec3) Vec3 {
        return vec3(
            std.math.clamp(point.x, self.min_x, self.max_x),
            0.0,
            std.math.clamp(point.z, self.min_z, self.max_z),
        );
    }
};

/// What the mouse ray points at: a hotspot (its index), or a floor point to walk to.
pub const Target = union(enum) {
    hotspot: usize,
    floor: Vec3,
    nothing,
};

/// The nearest hotspot the ray hits, else where it meets the floor (moved into the walk
/// area), else nothing (the ray points up).
pub fn pick(hotspots: anytype, walk_area: WalkArea, ray: Ray) Target {
    var nearest: ?usize = null;
    var nearest_distance = std.math.inf(f32);
    for (hotspots, 0..) |hotspot, i| {
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

    const floor_point = math.getRayPlaneIntersection(ray.origin, ray.direction, vec3(0.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0));
    if (floor_point) |point| {
        return .{ .floor = walk_area.nearestPoint(point) };
    }
    return .nothing;
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
