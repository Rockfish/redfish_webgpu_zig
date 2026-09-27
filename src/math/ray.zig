const std = @import("std");
const _vec = @import("vec.zig");

const Vec3 = _vec.Vec3;
const Vec4 = _vec.Vec4;

/// Möller–Trumbore ray-triangle intersection.
/// Returns the distance along `direction` to the hit, or null for no hit in front of
/// `origin`. The distance is in units of `direction`'s length; pass a normalized
/// direction to get world units.
pub fn getRayTriangleIntersection(origin: Vec3, direction: Vec3, vert0: Vec3, vert1: Vec3, vert2: Vec3) ?f32 {
    const epsilon = 1e-8;

    const edge1 = vert1.sub(vert0);
    const edge2 = vert2.sub(vert0);

    const h = direction.cross(edge2);
    const a = edge1.dot(h);

    // Ray is parallel to the triangle's plane
    if (@abs(a) < epsilon) {
        return null;
    }

    // Barycentric u, v; outside [0, 1] means the plane hit is outside the triangle
    const f = 1.0 / a;
    const s = origin.sub(vert0);
    const u = f * s.dot(h);
    if (u < 0.0 or u > 1.0) {
        return null;
    }

    const q = s.cross(edge1);
    const v = f * direction.dot(q);
    if (v < 0.0 or u + v > 1.0) {
        return null;
    }

    // Only hits in front of the origin count
    const t = f * edge2.dot(q);
    if (t > epsilon) {
        return t;
    }
    return null;
}

/// Ray-sphere intersection limited to the segment `t_min..t_max` along the ray.
/// `sphere` is `(center.x, center.y, center.z, radius)`.
///
/// Returns true when the ray enters or exits the sphere within the segment, or when the
/// whole segment lies inside the sphere. Distances are in units of `direction`'s length.
pub fn getRaySphereIntersection(origin: Vec3, direction: Vec3, sphere: Vec4, t_min: f32, t_max: f32) bool {
    const center = Vec3.init(sphere.x, sphere.y, sphere.z);
    const radius = sphere.w;

    // Quadratic a*t^2 + b*t + c = 0 for points on the ray at distance t from the center
    const oc = origin.sub(center);
    const a = direction.dot(direction);
    const b = 2.0 * oc.dot(direction);
    const c = oc.dot(oc) - radius * radius;

    const discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0.0) {
        return false;
    }

    const sqrt_discriminant = std.math.sqrt(discriminant);
    const t_near = (-b - sqrt_discriminant) / (2.0 * a);
    const t_far = (-b + sqrt_discriminant) / (2.0 * a);

    const near_in_segment = t_near >= t_min and t_near <= t_max;
    const far_in_segment = t_far >= t_min and t_far <= t_max;
    const segment_inside = t_near < t_min and t_far > t_max;
    return near_in_segment or far_in_segment or segment_inside;
}

test "ray triangle: hit, miss, parallel, behind" {
    const v0 = Vec3.init(-1.0, -1.0, 0.0);
    const v1 = Vec3.init(1.0, -1.0, 0.0);
    const v2 = Vec3.init(0.0, 1.0, 0.0);
    const toward = Vec3.init(0.0, 0.0, -1.0);

    // Straight down -Z from z = 5 hits the triangle's plane at distance 5
    const hit = getRayTriangleIntersection(Vec3.init(0.0, 0.0, 5.0), toward, v0, v1, v2);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), hit.?, 1e-5);

    // Plane is hit, but outside the triangle
    try std.testing.expectEqual(null, getRayTriangleIntersection(Vec3.init(3.0, 0.0, 5.0), toward, v0, v1, v2));

    // Parallel to the plane
    try std.testing.expectEqual(null, getRayTriangleIntersection(Vec3.init(0.0, 0.0, 5.0), Vec3.init(1.0, 0.0, 0.0), v0, v1, v2));

    // Triangle is behind the origin
    try std.testing.expectEqual(null, getRayTriangleIntersection(Vec3.init(0.0, 0.0, -5.0), toward, v0, v1, v2));
}

test "ray sphere: hit in segment, miss, inside, behind, out of range" {
    const sphere = Vec4.init(0.0, 0.0, -10.0, 1.0); // enters at t = 9, exits at t = 11
    const origin = Vec3.init(0.0, 0.0, 0.0);
    const toward = Vec3.init(0.0, 0.0, -1.0);

    try std.testing.expect(getRaySphereIntersection(origin, toward, sphere, 0.0, 100.0));
    try std.testing.expect(!getRaySphereIntersection(Vec3.init(5.0, 0.0, 0.0), toward, sphere, 0.0, 100.0));

    // Segment 9.5..10.5 lies entirely inside the sphere
    try std.testing.expect(getRaySphereIntersection(origin, toward, sphere, 9.5, 10.5));

    // Sphere behind the origin
    try std.testing.expect(!getRaySphereIntersection(origin, Vec3.init(0.0, 0.0, 1.0), sphere, 0.0, 100.0));

    // Segment ends before the sphere starts
    try std.testing.expect(!getRaySphereIntersection(origin, toward, sphere, 0.0, 5.0));
}
