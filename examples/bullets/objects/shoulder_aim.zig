//! Third-person aim over the captain's right shoulder (plan 019 phase H): while it's held,
//! the camera eases from the follow camera to low behind the captain, offset to his
//! right, looking along the aim; the aim stick moves the aim, and the captain faces it.
//! Letting go swings back the same way, to where the camera was around the captain
//! before (`returnYaw`), at the follow camera's height and distance.
//!
//! The swing goes around the captain, not straight across: heading, pitch, distance, and
//! the point looked past are each eased. The heading has its own swing, easing in and
//! out, between the follow camera's heading and the aim camera's, so a camera off to the
//! side turns smoothly around behind him and back.
//!
//! The camera keeps its heading and pitch while the aim stays inside a zone around them;
//! past the zone's edge it follows the aim with lag. Small corrections move the aim on
//! screen; bigger turns bring the camera around.
//!
//! Close to `FirstPerson`'s shape (`update`, `direction`, `view`), so the range switches
//! between them.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const View = @import("first_person.zig").View;

const motion = core.motion;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const vec3 = math.vec3;

const deg = std.math.degreesToRadians;

/// How far ahead of the camera's pivot its focus is, meters.
const FOCUS_DISTANCE: f32 = 10.0;

pub const ShoulderAim = struct {
    /// The aim, with `YawPitchAim`'s conventions (the follow camera's yaw).
    yaw: f32 = 0.0,
    pitch: f32 = 0.0,
    /// Where the aim camera looks; it trails the aim past the zone.
    camera_yaw: f32 = 0.0,
    camera_pitch: f32 = 0.0,
    /// 0 at the follow camera, 1 at the aim camera: pitch, distance, and pivot.
    blend: f32 = 0.0,
    /// The heading's own swing: 0 at the follow camera's heading, 1 at the aim camera's.
    yaw_blend: f32 = 0.0,
    /// Where the follow camera was around the captain when aiming started: its heading
    /// from his facing.
    entry_offset: f32 = 0.0,
    active: bool = false,

    /// The aim camera's place: meters right of the captain (0 centered), above his feet,
    /// and behind the pivot that makes.
    side: f32 = 0.0,
    height: f32 = 2.0,
    distance: f32 = 6.0,
    /// Seconds to swing in or out: pitch, distance, and pivot; and the heading.
    swing_time: f32 = 0.9,
    turn_swing_time: f32 = 0.9,
    /// Degrees either side of the camera's heading and pitch the aim moves freely; past
    /// that the camera follows at `follow_rate` (`dampAngle`).
    zone_yaw: f32 = 15.0,
    zone_pitch: f32 = 10.0,
    follow_rate: f32 = 6.0,
    /// Radians per second at full stick.
    yaw_speed: f32 = 2.0,
    pitch_speed: f32 = 1.5,
    /// Degrees up and down for the aim, and for the camera's pitch (less: the camera
    /// tilts less than the aim).
    pitch_limit: f32 = 60.0,
    camera_pitch_limit: f32 = 30.0,

    const Self = @This();

    /// `held`: aiming wanted this frame. On entering, the aim and the camera start level
    /// along `facing_yaw` (the captain's facing as a camera yaw); the follow camera's
    /// heading `follow_yaw` is remembered relative to it. `turn` is the aim stick, each
    /// axis -1 to 1.
    pub fn update(self: *Self, held: bool, turn: Vec2, facing_yaw: f32, follow_yaw: f32, dt: f32) void {
        if (held and !self.active) {
            self.yaw = facing_yaw;
            self.pitch = 0.0;
            self.camera_yaw = facing_yaw;
            self.camera_pitch = 0.0;
            self.entry_offset = motion.wrapAngle(follow_yaw - facing_yaw);
        }
        self.active = held;

        // Partway out still, the swings go on from where they are
        const goal: f32 = if (held) 1.0 else 0.0;
        const blend_sign = std.math.sign(goal - self.blend);
        self.blend = std.math.clamp(self.blend + blend_sign * dt / self.swing_time, 0.0, 1.0);
        const yaw_sign = std.math.sign(goal - self.yaw_blend);
        self.yaw_blend = std.math.clamp(self.yaw_blend + yaw_sign * dt / self.turn_swing_time, 0.0, 1.0);

        if (held) {
            const limit = deg(self.pitch_limit);
            self.yaw = motion.wrapAngle(self.yaw - turn.x * self.yaw_speed * dt);
            self.pitch = std.math.clamp(self.pitch + turn.y * self.pitch_speed * dt, -limit, limit);
            self.followAim(dt);
        }
    }

    /// The follow camera's heading to swing back to when aiming ends: where it was around
    /// the captain before, turned with the camera as he turned while aiming.
    pub fn returnYaw(self: *const Self) f32 {
        return motion.wrapAngle(self.camera_yaw + self.entry_offset);
    }

    /// Where the aim points.
    pub fn direction(self: *const Self) Vec3 {
        return motion.yawPitchDirection(self.yaw, self.pitch);
    }

    /// The camera this frame: `follow`'s view eased toward the aim camera's, around the
    /// captain at `captain_position`. While aiming, the follow camera keeps its heading;
    /// when aiming ends, it's put at `returnYaw`, so the heading swings back there.
    pub fn view(self: *const Self, follow: *const motion.FollowCamera, captain_position: Vec3) View {
        const t = smoothStep(self.blend);
        const yaw = lerpAngle(follow.yaw, self.camera_yaw, smoothStep(self.yaw_blend));
        const pitch = std.math.lerp(follow.pitch, self.camera_pitch, t);
        const distance = std.math.lerp(follow.distance, self.distance, t);

        const right = vec3(@cos(yaw), 0.0, -@sin(yaw));
        const aim_pivot = captain_position.add(vec3(0.0, self.height, 0.0)).add(right.mulScalar(self.side));
        const pivot = follow.focus.lerp(aim_pivot, t);
        const look = motion.yawPitchDirection(yaw, pitch);
        return .{
            .position = pivot.sub(look.mulScalar(distance)),
            .focus = pivot.add(look.mulScalar(FOCUS_DISTANCE)),
        };
    }

    /// The camera turns only as far as keeps the aim inside the zone, with lag.
    fn followAim(self: *Self, dt: f32) void {
        const yaw_off = motion.wrapAngle(self.yaw - self.camera_yaw);
        const zone_yaw = deg(self.zone_yaw);
        if (@abs(yaw_off) > zone_yaw) {
            const goal = self.yaw - std.math.sign(yaw_off) * zone_yaw;
            self.camera_yaw = motion.dampAngle(self.camera_yaw, goal, self.follow_rate, dt);
        }

        const pitch_off = self.pitch - self.camera_pitch;
        const zone_pitch = deg(self.zone_pitch);
        if (@abs(pitch_off) > zone_pitch) {
            const camera_limit = deg(self.camera_pitch_limit);
            const goal = std.math.clamp(self.pitch - std.math.sign(pitch_off) * zone_pitch, -camera_limit, camera_limit);
            self.camera_pitch += (goal - self.camera_pitch) * motion.dampAlpha(self.follow_rate, dt);
        }
    }
};

/// Part way from `from` to `to`, the short way round.
fn lerpAngle(from: f32, to: f32, t: f32) f32 {
    return motion.wrapAngle(from + motion.wrapAngle(to - from) * t);
}

/// Eases in and out: 0 and 1 with zero slope at both ends.
fn smoothStep(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}
