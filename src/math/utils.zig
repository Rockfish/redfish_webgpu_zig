const std = @import("std");
const vec = @import("vec.zig");
const mat4_ = @import("mat4.zig");
const quat_ = @import("quat.zig");

pub const Vec2 = vec.Vec2;
pub const Vec3 = vec.Vec3;
pub const Vec4 = vec.Vec4;

pub const vec2 = vec.vec2;
pub const vec3 = vec.vec3;
pub const vec4 = vec.vec4;

pub const Mat4 = mat4_.Mat4;
pub const Quat = quat_.Quat;

pub const epsilon: f32 = 1.19209290e-07;

/// A world-space ray through a mouse position.
pub const MouseRay = struct {
    /// On the near plane under the mouse.
    origin: Vec3,
    /// Normalized, away from the camera.
    direction: Vec3,
};

/// The ray under a mouse position, for perspective and orthographic projections alike:
/// the mouse unprojected onto the near (NDC z = 0) and far (z = 1) planes, WebGPU's 0..1
/// depth. Perspective rays fan out from the eye; orthographic rays are parallel to the view
/// and their origin moves with the mouse (redfish returned only a perspective direction and
/// used the camera position as origin, so ortho picking hit the wrong place). Mouse
/// coordinates are window pixels with a top-left origin; NDC y is up.
pub fn getWorldRayFromMouse(
    viewport_width: f32,
    viewport_height: f32,
    projection: *const Mat4,
    view_matrix: *const Mat4,
    mouse_x: f32,
    mouse_y: f32,
) MouseRay {
    const ndc_x = (2.0 * mouse_x) / viewport_width - 1.0;
    const ndc_y = 1.0 - (2.0 * mouse_y) / viewport_height;

    const inverse = projection.mulMat4(view_matrix).getInverse();
    const near = unproject(&inverse, Vec4.init(ndc_x, ndc_y, 0.0, 1.0));
    const far = unproject(&inverse, Vec4.init(ndc_x, ndc_y, 1.0, 1.0));

    return .{ .origin = near, .direction = far.sub(near).toNormalized() };
}

fn unproject(inverse_projection_view: *const Mat4, ndc: Vec4) Vec3 {
    const world = inverse_projection_view.mulVec4(ndc);
    return world.xyz().divScalar(world.w);
}

pub fn getRayPlaneIntersection(
    ray_origin: Vec3,
    ray_direction: Vec3,
    plane_point: Vec3,
    plane_normal: Vec3,
) ?Vec3 {
    const denom = plane_normal.dot(ray_direction);
    if (@abs(denom) > epsilon) {
        const p0l0 = plane_point.sub(ray_origin);
        const t = p0l0.dot(plane_normal) / denom;
        if (t >= 0.0) {
            return ray_origin.add(ray_direction.mulScalar(t));
        }
    }
    return null;
}

test "getWorldRayFromMouse: perspective rays start near the eye and follow the field of view" {
    const width = 1600.0;
    const height = 900.0;
    const aspect = width / height;
    const fov = std.math.pi / 2.0; // tan(fov / 2) = 1

    const eye = vec3(3.0, 2.0, 5.0);
    const target = vec3(3.0, 2.0, 0.0); // looking down -Z, up +Y
    const view = Mat4.lookAtRhGl(eye, target, vec3(0.0, 1.0, 0.0));
    const projection = Mat4.perspectiveRhZo(fov, aspect, 0.1, 100.0);

    const center = getWorldRayFromMouse(width, height, &projection, &view, width / 2.0, height / 2.0);
    try expectVec3ApproxEq(vec3(0.0, 0.0, -1.0), center.direction);
    try expectVec3ApproxEq(vec3(3.0, 2.0, 4.9), center.origin); // on the near plane

    // Top-left pixel: left (-x) and up (+y) at the edges of the view frustum
    const top_left = getWorldRayFromMouse(width, height, &projection, &view, 0.0, 0.0);
    try expectVec3ApproxEq(vec3(-aspect, 1.0, -1.0).toNormalized(), top_left.direction);

    const bottom_right = getWorldRayFromMouse(width, height, &projection, &view, width, height);
    try expectVec3ApproxEq(vec3(aspect, -1.0, -1.0).toNormalized(), bottom_right.direction);
}

test "getWorldRayFromMouse: orthographic rays are parallel and their origin follows the mouse" {
    const width = 800.0;
    const height = 400.0;

    const eye = vec3(3.0, 2.0, 5.0);
    const target = vec3(3.0, 2.0, 0.0);
    const view = Mat4.lookAtRhGl(eye, target, vec3(0.0, 1.0, 0.0));
    const projection = Mat4.orthographicRhZo(-4.0, 4.0, -2.0, 2.0, 0.1, 100.0);

    const center = getWorldRayFromMouse(width, height, &projection, &view, width / 2.0, height / 2.0);
    try expectVec3ApproxEq(vec3(0.0, 0.0, -1.0), center.direction);
    try expectVec3ApproxEq(vec3(3.0, 2.0, 4.9), center.origin);

    // Top-left pixel: same direction, origin at the view volume's top-left edge
    const top_left = getWorldRayFromMouse(width, height, &projection, &view, 0.0, 0.0);
    try expectVec3ApproxEq(vec3(0.0, 0.0, -1.0), top_left.direction);
    try expectVec3ApproxEq(vec3(3.0 - 4.0, 2.0 + 2.0, 4.9), top_left.origin);
}

fn expectVec3ApproxEq(expected: Vec3, actual: Vec3) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 1e-5);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 1e-5);
    try std.testing.expectApproxEqAbs(expected.z, actual.z, 1e-5);
}
