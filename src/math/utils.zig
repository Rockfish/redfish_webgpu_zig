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

/// World-space direction of the ray through a mouse position, for a perspective camera.
/// Mouse coordinates are window pixels with a top-left origin; NDC y is up, as in WebGPU
/// and GL alike. Unprojected x and y don't depend on NDC z, so the ray is the same for any
/// depth convention. Not valid for orthographic projections, where every ray has the
/// camera's forward direction and only the origin moves.
pub fn getWorldRayFromMouse(
    viewport_width: f32,
    viewport_height: f32,
    projection: *const Mat4,
    view_matrix: *const Mat4,
    mouse_x: f32,
    mouse_y: f32,
) Vec3 {

    // normalize device coordinates
    const ndc_x = (2.0 * mouse_x) / viewport_width - 1.0;
    const ndc_y = 1.0 - (2.0 * mouse_y) / viewport_height;
    const ndc_z = 0.0; // near plane in WebGPU's 0..1 depth
    const ndc = Vec4.init(ndc_x, ndc_y, ndc_z, 1.0);

    const projection_inverse = projection.getInverse();
    const view_inverse = view_matrix.getInverse();

    // eye space
    var ray_eye = projection_inverse.mulVec4(ndc);
    ray_eye = vec4(ray_eye.x, ray_eye.y, -1.0, 0.0);

    // world space
    const ray_world = (view_inverse.mulVec4(ray_eye)).xyz();

    // ray from camera
    const ray_normalized = ray_world.toNormalized();

    return ray_normalized;
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

test "getWorldRayFromMouse: center is forward, corners follow the field of view" {
    const width = 1600.0;
    const height = 900.0;
    const aspect = width / height;
    const fov = std.math.pi / 2.0; // tan(fov / 2) = 1

    const eye = vec3(3.0, 2.0, 5.0);
    const target = vec3(3.0, 2.0, 0.0); // looking down -Z, up +Y
    const view = Mat4.lookAtRhGl(eye, target, vec3(0.0, 1.0, 0.0));
    const projection = Mat4.perspectiveRhZo(fov, aspect, 0.1, 100.0);

    const center = getWorldRayFromMouse(width, height, &projection, &view, width / 2.0, height / 2.0);
    try expectVec3ApproxEq(vec3(0.0, 0.0, -1.0), center);

    // Top-left pixel: left (-x) and up (+y) at the edges of the view frustum
    const top_left = getWorldRayFromMouse(width, height, &projection, &view, 0.0, 0.0);
    try expectVec3ApproxEq(vec3(-aspect, 1.0, -1.0).toNormalized(), top_left);

    const bottom_right = getWorldRayFromMouse(width, height, &projection, &view, width, height);
    try expectVec3ApproxEq(vec3(aspect, -1.0, -1.0).toNormalized(), bottom_right);
}

fn expectVec3ApproxEq(expected: Vec3, actual: Vec3) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 1e-5);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 1e-5);
    try std.testing.expectApproxEqAbs(expected.z, actual.z, 1e-5);
}
