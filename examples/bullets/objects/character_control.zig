//! Analog control of a glTF character (the soldier, the spacesuit): it walks or runs
//! along a world direction from the move stick (`motion.cameraRelativeMove`). glTF
//! models face +Z, so the character's heading is the direction its +Z points.
//!
//! Two styles, switchable for play testing (`Style`): `direct` moves along the stick at
//! once; `wind_waker` moves the way the character faces and turns it toward the stick
//! (docs/reviews/2026-10-04-link-style-controller-review.md section 5.1).

const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");

const Input = core.Input;
const Transform = core.Transform;
const motion = core.motion;
const Quat = math.Quat;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const vec2 = math.vec2;

/// `direct`: stick travel (0 to 1) from which the character runs instead of walking.
const RUN_THRESHOLD: f32 = 0.75;
/// `direct`: how fast the character turns to face its move direction, per second
/// (`dampAngle`).
const TURN_RATE: f32 = 12.0;
/// Below this speed (meters per second) the character is standing.
const STANDING_SPEED: f32 = 0.01;

pub const Style = enum {
    /// Moves along the stick at once, at the walking or running speed, and turns the
    /// model after it.
    direct,
    /// Moves the way it faces; the facing turns toward the stick at a set rate (faster
    /// standing than running), so a hard stick change runs an arc. The stick's travel is
    /// the throttle, speed builds and falls off, sharp turns slow it, and a reversal at
    /// speed brakes to a stop before turning (a skid).
    wind_waker,
};

pub const Gait = enum { idle, walk, run };

/// A character's movement on the ground: its speed, and the tuning for both styles.
pub const Motor = struct {
    /// Meters per second.
    walk_speed: f32,
    run_speed: f32,
    /// Seconds from standing to a full run, and from a full run to standing.
    accel_time: f32 = 0.15,
    decel_time: f32 = 0.1,
    /// Turn rates in degrees per second, standing and at a full run.
    turn_rate_standing: f32 = 900.0,
    turn_rate_running: f32 = 540.0,
    /// A stick this many degrees from the facing, above `skid_min_speed` (a fraction of the
    /// run speed), brakes to a stop in `skid_time` before turning.
    skid_angle: f32 = 135.0,
    skid_min_speed: f32 = 0.6,
    skid_time: f32 = 0.15,
    /// Meters per second, now.
    speed: f32 = 0.0,
    skidding: bool = false,
    /// `strafe`'s direction of travel, kept while it slows down.
    strafe_direction: Vec3 = Vec3.Zero,

    const Self = @This();

    /// Moves `transform` along `move` (a direction on the ground, length 0 to 1) in the
    /// given style and says which gait that is, for the animation.
    pub fn update(self: *Self, style: Style, transform: *Transform, move: Vec3, dt: f32) Gait {
        switch (style) {
            .direct => self.updateDirect(transform, move, dt),
            .wind_waker => self.updateWindWaker(transform, move, dt),
        }
        return self.gait();
    }

    /// Moves along `move` (length 0 to 1, the throttle) while facing `heading` (about +Y
    /// from +Z): first person, where the view sets the facing. Speed builds and falls off
    /// as in the Wind Waker style.
    pub fn strafe(self: *Self, transform: *Transform, move: Vec3, facing: f32, dt: f32) Gait {
        const throttle = @min(move.length(), 1.0);
        const target_speed = throttle * self.run_speed;
        const seconds = if (target_speed > self.speed) self.accel_time else self.decel_time;
        self.speed = moveTowardScalar(self.speed, target_speed, self.run_speed / seconds * dt);
        self.skidding = false;

        // Coasting to a stop keeps the last direction
        if (throttle > 0.0) {
            self.strafe_direction = move.mulScalar(1.0 / move.length());
        }
        transform.rotation = Quat.fromAxisAngle(Vec3.Y, facing);
        transform.translation = transform.translation.add(self.strafe_direction.mulScalar(self.speed * dt));
        return self.gait();
    }

    /// Keeps going the way the character faces at its speed, without steering: a jump.
    pub fn coast(self: *const Self, transform: *Transform, dt: f32) void {
        const facing = heading(transform.rotation);
        transform.translation = transform.translation.add(headingDirection(facing).mulScalar(self.speed * dt));
    }

    /// Stands still at once: an action that plays in place.
    pub fn stop(self: *Self) void {
        self.speed = 0.0;
        self.skidding = false;
    }

    /// Walk below halfway between the walking and running speeds, run above.
    pub fn gait(self: *const Self) Gait {
        if (self.speed <= STANDING_SPEED) {
            return .idle;
        }
        return if (self.speed < 0.5 * (self.walk_speed + self.run_speed)) .walk else .run;
    }

    fn updateDirect(self: *Self, transform: *Transform, move: Vec3, dt: f32) void {
        const travel = move.length();
        if (travel == 0.0) {
            self.speed = 0.0;
            return;
        }

        const direction = move.mulScalar(1.0 / travel);
        const target_heading = std.math.atan2(direction.x, direction.z);
        const new_heading = motion.dampAngle(heading(transform.rotation), target_heading, TURN_RATE, dt);
        transform.rotation = Quat.fromAxisAngle(Vec3.Y, new_heading);

        self.speed = if (travel >= RUN_THRESHOLD) self.run_speed else self.walk_speed;
        transform.translation = transform.translation.add(direction.mulScalar(self.speed * dt));
    }

    fn updateWindWaker(self: *Self, transform: *Transform, move: Vec3, dt: f32) void {
        const throttle = @min(move.length(), 1.0);
        var facing = heading(transform.rotation);
        var target_speed: f32 = 0.0;

        if (throttle > 0.0) {
            const stick_heading = std.math.atan2(move.x, move.z);
            const off_by = @abs(motion.wrapAngle(stick_heading - facing));
            if (self.speed > self.skid_min_speed * self.run_speed and off_by > std.math.degreesToRadians(self.skid_angle)) {
                self.skidding = true;
            }

            if (!self.skidding) {
                const running = std.math.clamp(self.speed / self.run_speed, 0.0, 1.0);
                const turn_rate = std.math.lerp(self.turn_rate_standing, self.turn_rate_running, running);
                facing = motion.moveTowardAngle(facing, stick_heading, std.math.degreesToRadians(turn_rate), dt);

                // Slower the further it still has to turn; none past a right angle
                const still_off = motion.wrapAngle(stick_heading - facing);
                target_speed = throttle * self.run_speed * @max(@cos(still_off), 0.0);
            }
        }

        self.speed = moveTowardScalar(self.speed, target_speed, self.speedChangeRate(target_speed) * dt);
        if (self.skidding and self.speed <= STANDING_SPEED) {
            self.skidding = false;
        }

        transform.rotation = Quat.fromAxisAngle(Vec3.Y, facing);
        transform.translation = transform.translation.add(headingDirection(facing).mulScalar(self.speed * dt));
    }

    /// Meters per second per second toward `target_speed`.
    fn speedChangeRate(self: *const Self, target_speed: f32) f32 {
        if (self.skidding) {
            return self.run_speed / self.skid_time;
        }
        const seconds = if (target_speed > self.speed) self.accel_time else self.decel_time;
        return self.run_speed / seconds;
    }
};

/// One frame of control for `character` (the soldier or the spacesuit: `drive` and
/// `processInput`) from the gamepad's move stick, relative to the camera's yaw. In the
/// direct style the keyboard turns and moves it (A / D turn, W / S move) while the stick
/// is centered; in the Wind Waker style W / A / S / D are a stick too (Shift runs), and the
/// character is driven every frame so it slows down after the stick is let go.
pub fn control(character: anytype, style: Style, camera_yaw: f32, input: *Input) !void {
    switch (style) {
        .direct => {
            const move = motion.cameraRelativeMove(input.gamepad.left_stick, camera_yaw);
            if (move.lengthSquared() > 0.0) {
                character.drive(move, .direct, input);
            } else {
                try character.processInput(input);
            }
        },
        .wind_waker => character.drive(motion.cameraRelativeMove(moveStick(input), camera_yaw), .wind_waker, input),
    }
}

/// The follow camera trails the character at `transform`; the right stick or the arrow
/// keys turn it; `recenter` swings it behind the character.
pub fn followCharacter(follow: *motion.FollowCamera, transform: Transform, recenter: bool, input: *const Input) void {
    const recenter_yaw: ?f32 = if (recenter) facingYaw(transform) else null;
    follow.update(transform.translation, cameraTurn(input), recenter_yaw, input.delta_time);
}

/// The other style.
pub fn nextStyle(style: Style) Style {
    return switch (style) {
        .direct => .wind_waker,
        .wind_waker => .direct,
    };
}

/// The camera yaw (`YawPitchAim`'s) that looks the way the character faces: for putting a
/// follow camera behind it.
pub fn facingYaw(transform: Transform) f32 {
    return motion.yawPitchOf(transform.rotation.rotateVec(Vec3.Z)).yaw;
}

/// The heading (about +Y from +Z, as the character's) that looks along a camera `yaw`.
pub fn headingOfYaw(yaw: f32) f32 {
    const direction = motion.yawPitchDirection(yaw, 0.0);
    return std.math.atan2(direction.x, direction.z);
}

/// The angle about +Y from +Z to where the character's +Z points.
pub fn heading(rotation: Quat) f32 {
    const front = rotation.rotateVec(Vec3.Z);
    return std.math.atan2(front.x, front.z);
}

/// The direction on the ground at `angle` about +Y from +Z.
pub fn headingDirection(angle: f32) Vec3 {
    return Vec3.init(@sin(angle), 0.0, @cos(angle));
}

/// The move stick: the gamepad's left stick while it's pushed, else W / A / S / D.
pub fn moveStick(input: *const Input) Vec2 {
    const pad = input.gamepad.left_stick;
    return if (pad.lengthSquared() > 0.0) pad else keyboardStick(input);
}

/// The camera (or aim) turn this frame: the gamepad's right stick plus the arrow keys,
/// each axis -1 to 1.
pub fn cameraTurn(input: *const Input) Vec2 {
    const stick = input.gamepad.right_stick;
    const keys_x = axisFromKeys(input, .left, .right);
    const keys_y = axisFromKeys(input, .down, .up);
    return vec2(std.math.clamp(stick.x + keys_x, -1.0, 1.0), std.math.clamp(stick.y + keys_y, -1.0, 1.0));
}

/// W / A / S / D as a move stick: half travel walks, Shift makes it full travel (a run).
fn keyboardStick(input: *const Input) Vec2 {
    const keys = vec2(axisFromKeys(input, .a, .d), axisFromKeys(input, .s, .w));
    const length = @sqrt(keys.lengthSquared());
    if (length == 0.0) {
        return keys;
    }
    const travel: f32 = if (input.key_shift) 1.0 else 0.5;
    return vec2(keys.x * travel / length, keys.y * travel / length);
}

fn axisFromKeys(input: *const Input, negative: glfw.Key, positive: glfw.Key) f32 {
    const low: f32 = if (input.isDown(negative)) 1.0 else 0.0;
    const high: f32 = if (input.isDown(positive)) 1.0 else 0.0;
    return high - low;
}

/// `current` stepped toward `target` by at most `max_step`, without overshooting.
fn moveTowardScalar(current: f32, target: f32, max_step: f32) f32 {
    return current + std.math.clamp(target - current, -max_step, max_step);
}
