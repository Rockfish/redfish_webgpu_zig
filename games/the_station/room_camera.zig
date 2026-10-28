//! The cutaway camera: looks into a room through its open front (the z = 0 plane) and
//! frames that opening on screen.
//!
//! Three views, to compare (plan 021, phase A):
//! - `shifted`: the camera looks straight down -z, level, and the framing is moved with a
//!   shifted lens (off-center frustum). Verticals stay vertical and the room's horizontal
//!   lines stay horizontal; only lines running into the room meet, at one vanishing point
//!   straight ahead of the eye. The look of the cutaway illustrations.
//! - `aimed`: an ordinary camera at the same eye, turned to look at the framing's center.
//!   When the eye is above or below that center, verticals lean in (three-point).
//! - `orthographic`: a front elevation; no perspective, so the side walls disappear.
//!
//! How much the side walls splay depends on the eye's distance to the opening: the framing
//! always fills the screen, so a closer eye means a wider field of view and more splay.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const RenderContext = core.RenderContext;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

pub const View = enum(i32) { shifted, aimed, orthographic };

/// The rectangle on the z = 0 plane to show, in world units.
pub const Framing = struct {
    center_x: f32,
    center_y: f32,
    half_width: f32,
    half_height: f32,
};

pub const RoomCamera = struct {
    view: View = .shifted,
    /// From the opening (z = 0) to the eye, along +z.
    distance: f32 = 6.0,
    /// The eye's height; the vanishing point is at this height.
    eye_height: f32 = 1.9,
    /// The eye's x from the framing's center; the vanishing point is at this x.
    eye_x: f32 = 0.0,
    near: f32 = 0.1,
    far: f32 = 100.0,

    const Self = @This();

    pub fn renderContext(self: Self, room_framing: Framing, aspect: f32, time: f32) RenderContext {
        const framing = fitToAspect(room_framing, aspect);
        const eye = self.eyePosition(framing);
        const view = switch (self.view) {
            .shifted, .orthographic => Mat4.lookToRhGl(eye, vec3(0.0, 0.0, -1.0), vec3(0.0, 1.0, 0.0)),
            .aimed => Mat4.lookAtRhGl(eye, vec3(framing.center_x, framing.center_y, 0.0), vec3(0.0, 1.0, 0.0)),
        };
        const projection = switch (self.view) {
            .shifted => self.shiftedProjection(framing),
            .aimed => Mat4.perspectiveRhZo(std.math.degreesToRadians(self.aimedFov(framing)), aspect, self.near, self.far),
            .orthographic => self.orthographicProjection(framing),
        };
        return .{
            .projection = projection,
            .projection_view = projection.mulMat4(&view),
            .view = view,
            .view_position = eye,
            .time = time,
        };
    }

    /// The eye, in front of `framing`'s center (the camera pans with the framing).
    pub fn eyePosition(self: Self, framing: Framing) Vec3 {
        return vec3(framing.center_x + self.eye_x, self.eye_height, self.distance);
    }

    /// `framing` grown to the screen's aspect, so all of it shows and it is centered.
    pub fn fitToAspect(framing: Framing, aspect: f32) Framing {
        var fitted = framing;
        if (framing.half_width / framing.half_height < aspect) {
            fitted.half_width = framing.half_height * aspect;
        } else {
            fitted.half_height = framing.half_width / aspect;
        }
        return fitted;
    }

    /// Vertical field of view, in degrees, that shows `framing` (already fitted) from the
    /// eye. For `shifted` it is the frustum's full vertical angle when it is centered.
    pub fn verticalFov(self: Self, framing: Framing) f32 {
        return std.math.radiansToDegrees(2.0 * std.math.atan(framing.half_height / self.distance));
    }

    /// The framing's edges, seen from the eye, scaled from the opening's distance back to
    /// the near plane.
    fn shiftedProjection(self: Self, framing: Framing) Mat4 {
        const to_near = self.near / self.distance;
        const left = (-framing.half_width - self.eye_x) * to_near;
        const right = (framing.half_width - self.eye_x) * to_near;
        const bottom = (framing.center_y - framing.half_height - self.eye_height) * to_near;
        const top = (framing.center_y + framing.half_height - self.eye_height) * to_near;
        return Mat4.frustumRhZo(left, right, bottom, top, self.near, self.far);
    }

    /// The field of view that shows the framing's height at the framing center's distance.
    /// The aimed camera looks at the framing at an angle, so the fit is close, not exact.
    fn aimedFov(self: Self, framing: Framing) f32 {
        const center = vec3(framing.center_x, framing.center_y, 0.0);
        const center_distance = center.sub(self.eyePosition(framing)).length();
        return std.math.radiansToDegrees(2.0 * std.math.atan(framing.half_height / center_distance));
    }

    fn orthographicProjection(self: Self, framing: Framing) Mat4 {
        return Mat4.orthographicRhZo(
            -framing.half_width - self.eye_x,
            framing.half_width - self.eye_x,
            framing.center_y - framing.half_height - self.eye_height,
            framing.center_y + framing.half_height - self.eye_height,
            self.near,
            self.far,
        );
    }
};
