//! Analog control of a glTF character (the soldier, the spacesuit): it walks or runs along
//! a world direction from the move stick (`motion.cameraRelativeMove`), turning to face
//! where it goes. glTF models face +Z, so the character's heading is the direction its +Z
//! points.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const Transform = core.Transform;
const motion = core.motion;
const Quat = math.Quat;
const Vec3 = math.Vec3;

/// Stick travel (0 to 1) from which the character runs instead of walking.
const RUN_THRESHOLD: f32 = 0.75;
/// How fast the character turns to face its move direction, per second (`dampAngle`).
const TURN_RATE: f32 = 12.0;

pub const Gait = enum { idle, walk, run };

/// Moves `transform` along `move` (a direction on the ground, length 0 to 1) at the
/// walking or running speed, turning it toward the direction, and says which gait that
/// is, for the animation.
pub fn drive(transform: *Transform, move: Vec3, walk_speed: f32, run_speed: f32, dt: f32) Gait {
    const travel = move.length();
    if (travel == 0.0) {
        return .idle;
    }

    const direction = move.mulScalar(1.0 / travel);
    const target_heading = std.math.atan2(direction.x, direction.z);
    const new_heading = motion.dampAngle(heading(transform.rotation), target_heading, TURN_RATE, dt);
    transform.rotation = Quat.fromAxisAngle(Vec3.Y, new_heading);

    const gait: Gait = if (travel >= RUN_THRESHOLD) .run else .walk;
    const speed = if (gait == .run) run_speed else walk_speed;
    transform.translation = transform.translation.add(direction.mulScalar(speed * dt));
    return gait;
}

/// The camera yaw (`YawPitchAim`'s) that looks the way the character faces: for putting a
/// follow camera behind it.
pub fn facingYaw(transform: Transform) f32 {
    return motion.yawPitchOf(transform.rotation.rotateVec(Vec3.Z)).yaw;
}

/// The angle about +Y from +Z to where the character's +Z points.
fn heading(rotation: Quat) f32 {
    const front = rotation.rotateVec(Vec3.Z);
    return std.math.atan2(front.x, front.z);
}
