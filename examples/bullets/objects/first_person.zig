//! The captain's first-person view (docs/reviews/2026-10-04-link-style-controller-review.md
//! section 5.5): while it's held, the camera eases from the follow camera to the eye and
//! the aim stick turns the view; letting go eases back. The captain faces where the view
//! looks.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const motion = core.motion;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

/// The eye above the captain's feet, meters (the toon soldier's head is large: its eyes
/// sit at about 1.5 m of its 1.8).
const EYE_HEIGHT: f32 = 1.5;
/// Past this much of the way to the eye the model is hidden, so the camera never sees
/// the inside of the head.
const HIDE_MODEL_FROM: f32 = 0.6;
/// How far ahead of the eye the view's focus is, meters.
const FOCUS_DISTANCE: f32 = 10.0;

pub const View = struct {
    position: Vec3,
    focus: Vec3,
};

pub const FirstPerson = struct {
    /// The aim, with `YawPitchAim`'s conventions (the follow camera's yaw).
    yaw: f32 = 0.0,
    pitch: f32 = 0.0,
    /// Radians per second at full stick.
    yaw_speed: f32 = 2.0,
    pitch_speed: f32 = 1.5,
    /// Degrees up and down.
    pitch_limit: f32 = 80.0,
    /// Seconds to ease in or out.
    transition_time: f32 = 0.2,
    /// 0 at the follow camera, 1 at the eye.
    blend: f32 = 0.0,
    active: bool = false,

    const Self = @This();

    /// `held`: first person wanted this frame. On entering, the aim starts level along
    /// `facing_yaw` (the captain's facing as a camera yaw). `turn` is the aim stick, each
    /// axis -1 to 1.
    pub fn update(self: *Self, held: bool, turn: Vec2, facing_yaw: f32, dt: f32) void {
        if (held and !self.active) {
            self.yaw = facing_yaw;
            self.pitch = 0.0;
        }
        self.active = held;

        const goal: f32 = if (held) 1.0 else 0.0;
        self.blend = std.math.clamp(self.blend + std.math.sign(goal - self.blend) * dt / self.transition_time, 0.0, 1.0);

        if (held) {
            const limit = std.math.degreesToRadians(self.pitch_limit);
            self.yaw = motion.wrapAngle(self.yaw - turn.x * self.yaw_speed * dt);
            self.pitch = std.math.clamp(self.pitch + turn.y * self.pitch_speed * dt, -limit, limit);
        }
    }

    /// Where the aim points.
    pub fn direction(self: *const Self) Vec3 {
        return motion.yawPitchDirection(self.yaw, self.pitch);
    }

    pub fn eye(captain_position: Vec3) Vec3 {
        return captain_position.add(vec3(0.0, EYE_HEIGHT, 0.0));
    }

    /// The camera this frame: the follow camera's view eased toward the eye's.
    pub fn view(self: *const Self, follow_position: Vec3, follow_focus: Vec3, captain_position: Vec3) View {
        const eye_position = eye(captain_position);
        const eye_focus = eye_position.add(self.direction().mulScalar(FOCUS_DISTANCE));
        const t = smoothStep(self.blend);
        return .{
            .position = follow_position.lerp(eye_position, t),
            .focus = follow_focus.lerp(eye_focus, t),
        };
    }

    /// Whether the camera is close enough to the eye to hide the captain's model.
    pub fn hidesModel(self: *const Self) bool {
        return self.blend > HIDE_MODEL_FROM;
    }
};

/// Eases in and out: 0 and 1 with zero slope at both ends.
fn smoothStep(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}
