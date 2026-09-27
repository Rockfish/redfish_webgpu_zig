const math = @import("math");

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

/// Per-frame rendering context computed once from the camera and passed to all draw calls.
///
/// Replaces the pattern of passing separate projection and view matrices to every object.
/// Objects that need the view matrix separately (skybox, billboard, fog) can access it directly.
/// Projection is kept for core engine APIs (Lines, Plane, Skybox) that still use separate matrices.
pub const RenderContext = struct {
    projection: Mat4,
    projection_view: Mat4,
    view: Mat4,
    view_position: Vec3,
    time: f32 = 0.0,
};
