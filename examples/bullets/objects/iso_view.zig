//! The isometric view of the range (plan 019 phase J): the camera looks down at the
//! captain from a fixed heading (45°) and pitch (about 35°), following him with a little
//! lag and a look ahead of where he's going. Orthographic by default (no perspective
//! shrink: the classic isometric look), or a narrow perspective from far away to compare.
//!
//! Views here are orbits (`Orbit`: a heading, a pitch, a distance back from a focus, and
//! a field of view), the same terms as the follow camera, so the range eases between the
//! two by easing each term, and the aim camera swings in from either.
//!
//! Switching to orthographic is a cut, so it happens only once the swing is over, and the
//! perspective during the swing is framed to match: a narrow lens from `ortho_distance`
//! away showing the same `size` at the captain, so the cut doesn't jump.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const motion = core.motion;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

const deg = std.math.degreesToRadians;

/// The view's focus above the captain's feet, meters.
const FOCUS_HEIGHT: f32 = 1.0;

pub const Projection = enum { orthographic, perspective };

/// A camera placed around a focus point, with `YawPitchAim`'s conventions (yaw 0 looks
/// down -Z, positive yaw turns left, negative pitch looks down).
pub const Orbit = struct {
    yaw: f32,
    pitch: f32,
    /// From the focus back to the camera, meters.
    distance: f32,
    focus: Vec3,
    /// Vertical field of view, degrees.
    fov: f32,

    pub fn fromFollow(follow: *const motion.FollowCamera, fov: f32) Orbit {
        return .{ .yaw = follow.yaw, .pitch = follow.pitch, .distance = follow.distance, .focus = follow.focus, .fov = fov };
    }

    /// Part way from `a` to `b`: each term eased on its own, the heading the short way
    /// round.
    pub fn lerp(a: Orbit, b: Orbit, t: f32) Orbit {
        return .{
            .yaw = motion.wrapAngle(a.yaw + motion.wrapAngle(b.yaw - a.yaw) * t),
            .pitch = std.math.lerp(a.pitch, b.pitch, t),
            .distance = std.math.lerp(a.distance, b.distance, t),
            .focus = a.focus.lerp(b.focus, t),
            .fov = std.math.lerp(a.fov, b.fov, t),
        };
    }

    pub fn position(self: Orbit) Vec3 {
        return self.focus.sub(motion.yawPitchDirection(self.yaw, self.pitch).mulScalar(self.distance));
    }

    /// A follow camera placed as this orbit, for the aim views to swing in from.
    pub fn toFollow(self: Orbit, follow: motion.FollowCamera) motion.FollowCamera {
        var placed = follow;
        placed.yaw = self.yaw;
        placed.pitch = self.pitch;
        placed.distance = self.distance;
        placed.focus = self.focus;
        placed.position = self.position();
        return placed;
    }
};

pub const IsoView = struct {
    /// Wanted this frame, and 0 (the follow camera) to 1 (isometric).
    active: bool = false,
    blend: f32 = 0.0,
    /// The damped point looked at, and the captain's smoothed velocity for the look
    /// ahead.
    focus: Vec3 = Vec3.Zero,
    velocity: Vec3 = Vec3.Zero,
    last_position: Vec3 = Vec3.Zero,

    /// Degrees: the fixed heading (45° looks diagonally across the floor's grid) and the
    /// pitch down (35.26° is true isometric, 30° the 2:1 pixel-art look).
    heading: f32 = 45.0,
    pitch: f32 = 35.26,
    /// Half the view's height at the captain, meters: the zoom.
    size: f32 = 12.0,
    projection: Projection = .orthographic,
    /// Orthographic: how far back the camera sits (only clipping cares; the swing in
    /// frames the same size from here).
    ortho_distance: f32 = 80.0,
    /// Perspective: the lens, degrees; the distance follows from it and `size`.
    perspective_fov: f32 = 30.0,
    /// How fast the focus catches up with the captain (`dampVec3` rate), and how far
    /// ahead it looks, in seconds of his travel.
    follow_rate: f32 = 5.0,
    look_ahead: f32 = 0.4,
    /// Seconds to swing between the follow camera and this view.
    switch_time: f32 = 0.9,

    const Self = @This();

    /// `wanted`: the isometric view is picked. Follows the captain at `captain_position`.
    pub fn update(self: *Self, wanted: bool, captain_position: Vec3, dt: f32) void {
        if (dt > 0.0) {
            const velocity = captain_position.sub(self.last_position).mulScalar(1.0 / dt);
            self.velocity = motion.dampVec3(self.velocity, velocity, 8.0, dt);
        }
        self.last_position = captain_position;

        // Coming in from the follow camera: start on the captain, no catching up
        if (wanted and self.blend == 0.0) {
            self.focus = captain_position.add(vec3(0.0, FOCUS_HEIGHT, 0.0));
        }
        self.active = wanted;
        const goal: f32 = if (wanted) 1.0 else 0.0;
        self.blend = std.math.clamp(self.blend + std.math.sign(goal - self.blend) * dt / self.switch_time, 0.0, 1.0);

        const ahead = vec3(self.velocity.x, 0.0, self.velocity.z).mulScalar(self.look_ahead);
        const target = captain_position.add(vec3(0.0, FOCUS_HEIGHT, 0.0)).add(ahead);
        self.focus = motion.dampVec3(self.focus, target, self.follow_rate, dt);
    }

    /// The view's heading (a camera yaw): what moving and aiming are relative to.
    pub fn yaw(self: *const Self) f32 {
        return deg(self.heading);
    }

    /// Where the camera is: orthographic from far back with a lens framing `size` at the
    /// focus (the projection becomes orthographic only once fully in; see
    /// `isOrthographic`), or perspective at the distance that frames `size`.
    pub fn orbit(self: *const Self) Orbit {
        const distance, const fov = switch (self.projection) {
            .orthographic => .{ self.ortho_distance, 2.0 * std.math.radiansToDegrees(std.math.atan(self.size / self.ortho_distance)) },
            .perspective => .{ self.size / @tan(deg(self.perspective_fov) * 0.5), self.perspective_fov },
        };
        return .{ .yaw = self.yaw(), .pitch = -deg(self.pitch), .distance = distance, .focus = self.focus, .fov = fov };
    }

    /// Fully in, orthographic picked: the camera switches to its orthographic projection
    /// with `size` as the half height.
    pub fn isOrthographic(self: *const Self) bool {
        return self.projection == .orthographic and self.blend == 1.0;
    }
};
