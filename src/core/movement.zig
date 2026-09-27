const std = @import("std");
const math = @import("math");

pub const Vec3 = math.Vec3;
pub const vec3 = math.vec3;
pub const Mat4 = math.Mat4;
pub const Quat = math.Quat;
pub const Transform = @import("transform.zig").Transform;

/// Discrete motion commands for `processMovement` / `applyMovement`.
///
/// | Family    | Position              | Orientation              | Target        |
/// |-----------|-----------------------|--------------------------|---------------|
/// | translate | along local axes      | unchanged                | unchanged     |
/// | turn      | unchanged             | yaw about world up       | optional sync |
/// | rotate    | unchanged             | free-look (local axes)   | optional sync |
/// | roll      | unchanged             | bank about forward       | unchanged     |
/// | orbit     | around target         | same quat as position    | unchanged     |
/// | circle    | around target         | same quat as position    | unchanged     |
/// | radius    | along line to target  | unchanged                | unchanged     |
///
/// "optional sync" means `target` is updated only when `sync_target_on_rotate` is true
/// (see `Movement`). Roll does not sync; forward is unchanged.
pub const MovementDirection = enum {
    // --- Translate: move position along local basis; orientation unchanged ---
    forward,
    backward,
    left,
    right,
    up,
    down,

    // --- Turn: yaw orientation about world up; position unchanged ---
    turn_right,
    turn_left,

    // --- Rotate: free-look; change orientation only (does not move target unless sync flag) ---
    rotate_right,
    rotate_left,
    rotate_up,
    rotate_down,
    // --- Roll: bank about local forward; does not move target ---
    roll_right,
    roll_left,

    // --- Orbit: move position around target using *local* up/right; apply same rotation to orientation ---
    orbit_left,
    orbit_right,
    orbit_up,
    orbit_down,

    // --- Circle: move position around target using *world* up / world-right; continuous orientation ---
    circle_left,
    circle_right,
    circle_up,
    circle_down,

    // --- Radius (dolly): move along the line between position and target ---
    radius_in,
    radius_out,
};

const world_up = Vec3.init(0.0, 1.0, 0.0);
const POSITION_EPSILON: f32 = 0.0001;
const AXIS_EPSILON: f32 = 1e-6;
/// sin² of angle between look dir and world_up below this ≈ near pole.
/// Cross product direction is unstable there (causes circle pitch jitter).
const POLE_SOFT_SIN_SQ: f32 = 0.04; // ~11.5° from pole
/// Max |elevation| from XZ plane when `constrain_pitch` is true (degrees).
const MAX_PITCH_DEGREES: f32 = 89.0;

/// Movement controller: a `Transform` (position + orientation) plus a focus `target`.
///
/// ## Coordinate convention
/// Right-handed, OpenGL / Godot / Bevy style: **+X right, +Y up, local forward = −Z**.
/// Basis helpers come from `Transform` / `Quat` (`forward`, `up`, `right`).
///
///
/// ## Focus target
/// `target` is used by **orbit**, **circle**, and **radius**. Typical roles:
/// - **Camera on a stick** — client updates `target` as the character moves
/// - **Focus orbit/circle** — `target` is the planet or object of interest
/// - **Free camera** — translate/rotate may ignore `target`; it remains available
///   so you can switch into orbit/circle/radius without rebuilding the controller
///
/// Target ownership (hybrid):
/// - `sync_target_on_rotate == false` (default): client owns `setTarget` / stick updates
/// - `sync_target_on_rotate == true`: turn/rotate free-look places `target` along
///   forward (see `syncTargetFromForward`)
/// - Call `syncTargetFromForward()` explicitly on mode switches when the flag is off
///
/// ## Orbit vs circle (same orientation math; different axes)
///
/// Both move on a sphere about `target` and apply the **same** rotation quaternion
/// to position and orientation (continuous; no per-step lookAt).
///
/// | | Orbit | Circle |
/// |---|--------|--------|
/// | Axes | *local* up / right | *world* up / world-right (`getWorldRight`) |
/// | Orientation | same quat as position | same quat as position |
/// | Feel | view-relative tumble | world turntable / lat-long |
/// | Poles | local axes usually fine | world-right soft-band near poles |
///
/// After orbit (or free-look) the basis can leave “upright.” Re-level is **explicit**:
/// `levelTowardTarget` / `levelUpright` — not baked into circle.
///
/// ## Speeds (`processMovement`)
/// - `translate_speed` — world units per second
/// - `rotation_speed` — degrees per second (turn / rotate / roll)
/// - `orbit_speed` — degrees per second (orbit / circle)
///
/// Prefer `applyMovement` when you already have distances/angles (scripted motion,
/// mouse deltas passed as radians via camera helpers).
///
/// ## Sign conventions (`applyMovement` angle > 0)
/// Angle magnitudes are always positive; the direction enum picks the signed axis angle.
/// Some “right” / “up” cases use a **negative** rotation about the axis — that is
/// intentional so keyboard/mouse in bullets and level_01 feel correct (do not “fix”
/// signs for RHS purity without re-checking product feel).
///
/// | Direction              | Axis          | Signed angle |
/// |------------------------|---------------|--------------|
/// | turn_right / turn_left | world up      |   − / +      |
/// | rotate_right / left    | local up      |   − / +      |
/// | rotate_up / down       | local right   |   + / −      |
/// | roll_right / left      | local forward |   + / −      |
/// | orbit_right / left     | local up      |   + / −      |
/// | orbit_up / down        | local right   |   − / +      |
/// | circle_right / left    | world up      |   + / −      |
/// | circle_up / down       | world-right   |   − / +      |
///
/// Mouse: positive x → rotate_right; positive y (after screen-Y invert) → rotate_up.
pub const Movement = struct {
    /// Position and orientation (quat-based; −Z forward)
    transform: Transform,

    /// Focus point for orbit, circle, and radius
    target: Vec3,

    /// World up for turn, circle left/right, pitch-axis construction, and `levelUpright` (default +Y)
    world_up: Vec3 = world_up,
    /// World units per second for translate and radius
    translate_speed: f32 = 10,
    /// Degrees per second for turn, rotate, and roll
    rotation_speed: f32 = 50,
    /// Degrees per second for orbit and circle
    orbit_speed: f32 = 50,
    /// Degrees per pixel for `processMouseMovement` (LearnOpenGL-style default).
    mouse_sensitivity: f32 = 0.1,

    /// When true, turn/rotate free-look repositions `target` along forward at the
    /// current focus distance. Default false: client owns target.
    sync_target_on_rotate: bool = false,

    /// Fallback distance for `syncTargetFromForward` when position ≈ target
    default_focus_distance: f32 = 10.0,

    /// Last applied direction (informational)
    direction: MovementDirection = .forward,
    /// Bumped once per public state-changing call (dirty flag for Camera view cache).
    /// Helpers (`rotatePosition`, internal target sync) must not bump this.
    update_tick: u64 = 0,

    const Self = @This();

    fn bumpTick(self: *Self) void {
        self.update_tick +%= 1;
    }

    /// Create a controller at `position` looking at `target`.
    /// Uses the default `world_up` field (same as `reset`).
    pub fn init(position: Vec3, target: Vec3) Movement {
        var self = Movement{
            .transform = Transform.fromTranslation(position),
            .target = target,
        };
        self.transform.lookAt(target, self.world_up);
        return self;
    }

    /// Reposition and re-look at `target` using `self.world_up`.
    pub fn reset(self: *Self, position: Vec3, target: Vec3) void {
        self.transform.translation = position;
        self.transform.lookAt(target, self.world_up);
        self.target = target;
        self.bumpTick();
    }

    pub fn getPosition(self: *const Self) Vec3 {
        return self.transform.translation;
    }

    pub fn setPosition(self: *Self, position: Vec3) void {
        self.transform.translation = position;
        self.bumpTick();
    }

    pub fn getTarget(self: *const Self) Vec3 {
        return self.target;
    }

    pub fn getUpdateTick(self: *const Self) u64 {
        return self.update_tick;
    }

    pub fn getTransform(self: *const Self) *const Transform {
        return &self.transform;
    }

    /// Local-to-world matrix from the current transform (right, up, back, translation).
    /// Useful for orienting projectiles or gizmos with the controller.
    pub fn getTransformMatrix(self: *const Self) Mat4 {
        return self.transform.toMatrix();
    }

    /// Set focus point for orbit, circle, and radius.
    pub fn setTarget(self: *Self, target: Vec3) void {
        self.target = target;
        self.bumpTick();
    }

    /// Place `target` along current forward, preserving distance to the old target
    /// when possible. Use on mode switches, or enable `sync_target_on_rotate` for
    /// automatic updates after free-look turn/rotate.
    pub fn syncTargetFromForward(self: *Self) void {
        self.syncTargetFromForwardNoTick();
        self.bumpTick();
    }

    fn syncTargetFromForwardNoTick(self: *Self) void {
        const position = self.transform.translation;
        var distance = self.target.sub(position).length();
        if (distance < POSITION_EPSILON) {
            distance = self.default_focus_distance;
        }
        self.target = position.add(self.transform.forward().mulScalar(distance));
    }

    /// Called from within `applyMovement` after free-look; does not bump tick.
    fn maybeSyncTargetAfterLookChange(self: *Self) void {
        if (self.sync_target_on_rotate) {
            self.syncTargetFromForwardNoTick();
        }
    }

    /// Add a world-space offset to position (does not change orientation or target).
    pub fn translate(self: *Self, offset: Vec3) void {
        self.transform.translation = self.transform.translation.add(offset);
        self.bumpTick();
    }

    /// Pitch axis for circle up/down: horizontal axis ⟂ look direction.
    ///
    /// Far from poles: `normalize(to_target × world_up)`.
    /// Near poles that cross product is tiny and its *direction* flips with float
    /// noise — that is the circle-at-pole jitter (not the zero-axis early-out).
    /// Near poles we use camera right projected off the look axis (continuous
    /// under continuous orientation). Sign is always aligned with camera right
    /// so the axis does not flip frame-to-frame.
    pub fn getWorldRight(self: *const Self) Vec3 {
        const to_target = self.target.sub(self.transform.translation).toNormalized();

        // Preferred continuous reference: camera right ⟂ look
        var preferred = self.transform.right();
        preferred = preferred.sub(to_target.mulScalar(preferred.dot(to_target)));
        if (preferred.lengthSquared() < AXIS_EPSILON * AXIS_EPSILON) {
            const arbitrary = if (@abs(to_target.x) < 0.9)
                Vec3.init(1.0, 0.0, 0.0)
            else
                Vec3.init(0.0, 0.0, 1.0);
            preferred = to_target.cross(arbitrary);
        }
        preferred = preferred.toNormalized();

        var axis = to_target.cross(self.world_up);
        const sin_sq = axis.lengthSquared(); // |a×b|² = sin²θ for unit vectors

        if (sin_sq < POLE_SOFT_SIN_SQ) {
            // Ill-conditioned world cross — stay on continuous camera axis
            axis = preferred;
        } else {
            axis = axis.toNormalized();
            // Same hemisphere as camera right (prevents discrete flip each frame)
            if (axis.dot(preferred) < 0.0) {
                axis = axis.mulScalar(-1.0);
            }
        }
        return axis;
    }

    /// Reorient so forward faces `target`. Position is unchanged.
    ///
    /// - `up == null`: forward toward target, right leveled to the XZ plane when
    ///   possible; bank/hemisphere follows the current orientation (can stay inverted).
    /// - `up != null` (e.g. `self.world_up`): `lookAt(target, up)` — forces that up
    ///   hint. Using `world_up` snaps upright and may flip if previously inverted.
    pub fn levelTowardTarget(self: *Self, up: ?Vec3) void {
        if (up) |up_dir| {
            self.transform.lookAt(self.target, up_dir);
        } else {
            self.levelTowardTargetPreserveBank();
        }
        self.bumpTick();
    }

    /// Convenience: `levelTowardTarget(self.world_up)`.
    pub fn levelUpright(self: *Self) void {
        self.levelTowardTarget(self.world_up);
    }

    /// Forward → target, right ∥ XZ; keep current bank hemisphere.
    ///
    /// Horizontal right orthogonal to forward is (-fz, 0, fx) (always ⟂ forward).
    /// Projecting current right onto XZ then subtracting forward re-introduces Y
    /// when forward is not horizontal — so we build horizontal right directly.
    fn levelTowardTargetPreserveBank(self: *Self) void {
        const position = self.transform.translation;
        const to_target = self.target.sub(position);
        if (to_target.lengthSquared() < POSITION_EPSILON * POSITION_EPSILON) {
            return;
        }
        const forward = to_target.toNormalized();
        const back = forward.mulScalar(-1.0);

        // Horizontal and ⟂ forward: (-fz, 0, fx) · (fx, fy, fz) = 0
        var right = Vec3.init(-forward.z, 0.0, forward.x);
        if (right.lengthSquared() < AXIS_EPSILON * AXIS_EPSILON) {
            // Looking along ±Y: any XZ right; prefer current horizontal right
            right = self.transform.right();
            right.y = 0.0;
            if (right.lengthSquared() < AXIS_EPSILON * AXIS_EPSILON) {
                right = Vec3.init(1.0, 0.0, 0.0);
            }
        }
        right = right.toNormalized();

        // Prefer continuity with current right's horizontal sense
        var current_right_h = self.transform.right();
        current_right_h.y = 0.0;
        if (current_right_h.lengthSquared() > AXIS_EPSILON * AXIS_EPSILON) {
            if (right.dot(current_right_h) < 0.0) {
                right = right.mulScalar(-1.0);
            }
        }

        var cam_up = back.cross(right);
        if (cam_up.lengthSquared() < AXIS_EPSILON * AXIS_EPSILON) {
            return;
        }
        cam_up = cam_up.toNormalized();

        // Preserve hemisphere: stay inverted if already inverted
        if (self.transform.up().dot(cam_up) < 0.0) {
            right = right.mulScalar(-1.0);
            cam_up = cam_up.mulScalar(-1.0);
        }

        const rotation_matrix = Mat4{ .data = .{
            .{ right.x, right.y, right.z, 0.0 },
            .{ cam_up.x, cam_up.y, cam_up.z, 0.0 },
            .{ back.x, back.y, back.z, 0.0 },
            .{ 0.0, 0.0, 0.0, 1.0 },
        } };
        self.transform.rotation = rotation_matrix.toQuat();
    }

    /// Shared sphere step: rotate position about `axis`, then apply the same quat to orientation.
    /// Used by both orbit (local axes) and circle (world axes).
    fn rotateAboutAxisContinuous(self: *Self, axis: Vec3, angle_radians: f32) void {
        if (axis.lengthSquared() < AXIS_EPSILON * AXIS_EPSILON) {
            return;
        }
        const rot = Quat.fromAxisAngle(axis, angle_radians);
        self.rotatePosition(rot);
        self.transform.rotate(rot);
    }

    /// Circle: world-axis sphere pan (see module doc “Orbit vs circle”).
    fn circleAxis(self: *Self, axis: Vec3, angle_radians: f32) void {
        self.rotateAboutAxisContinuous(axis, angle_radians);
    }

    /// Orbit: local-axis sphere tumble (see module doc “Orbit vs circle”).
    fn orbitAxis(self: *Self, axis: Vec3, angle_radians: f32) void {
        self.rotateAboutAxisContinuous(axis, angle_radians);
    }

    /// Rotate position around target, preserving radius length. Does not bump tick.
    fn rotatePosition(self: *Self, rotation: Quat) void {
        const radius_vec = self.transform.translation.sub(self.target);
        const target_radius = radius_vec.length();
        const rotated_position = rotation.rotateVec(radius_vec).toNormalized();
        self.transform.translation = self.target.add(rotated_position.mulScalar(target_radius));
    }

    /// Frame-rate friendly entry: speeds × `delta_time` → `applyMovement`.
    pub fn processMovement(
        self: *Self,
        direction: MovementDirection,
        delta_time: f32,
    ) void {
        const translation_velocity = self.translate_speed * delta_time;
        const rot_angle = math.degreesToRadians(self.rotation_speed * delta_time);
        const orbit_angle = math.degreesToRadians(self.orbit_speed * delta_time);
        self.applyMovement(direction, translation_velocity, rot_angle, orbit_angle);
    }

    /// Apply pre-computed translation distance and angles (radians).
    /// Prefer this for scripted motion or when the caller already converted input.
    /// Bumps `update_tick` once (helpers must not bump again).
    pub fn applyMovement(
        self: *Self,
        direction: MovementDirection,
        translation_velocity: f32,
        rot_angle: f32,
        orbit_angle: f32,
    ) void {
        self.bumpTick();
        self.direction = direction;

        switch (direction) {
            .forward => {
                const fwd = self.transform.forward();
                self.transform.translation = self.transform.translation.add(fwd.mulScalar(translation_velocity));
            },
            .backward => {
                const fwd = self.transform.forward();
                self.transform.translation = self.transform.translation.sub(fwd.mulScalar(translation_velocity));
            },
            .left => {
                const right_vec = self.transform.right();
                self.transform.translation = self.transform.translation.sub(right_vec.mulScalar(translation_velocity));
            },
            .right => {
                const right_vec = self.transform.right();
                self.transform.translation = self.transform.translation.add(right_vec.mulScalar(translation_velocity));
            },
            .up => {
                const up_vec = self.transform.up();
                self.transform.translation = self.transform.translation.add(up_vec.mulScalar(translation_velocity));
            },
            .down => {
                const up_vec = self.transform.up();
                self.transform.translation = self.transform.translation.sub(up_vec.mulScalar(translation_velocity));
            },
            .turn_right => {
                self.transform.rotateAxis(self.world_up, -rot_angle);
                self.maybeSyncTargetAfterLookChange();
            },
            .turn_left => {
                self.transform.rotateAxis(self.world_up, rot_angle);
                self.maybeSyncTargetAfterLookChange();
            },
            .rotate_right => {
                self.transform.rotateAxis(self.transform.up(), -rot_angle);
                self.maybeSyncTargetAfterLookChange();
            },
            .rotate_left => {
                self.transform.rotateAxis(self.transform.up(), rot_angle);
                self.maybeSyncTargetAfterLookChange();
            },
            .rotate_up => {
                self.transform.rotateAxis(self.transform.right(), rot_angle);
                self.maybeSyncTargetAfterLookChange();
            },
            .rotate_down => {
                self.transform.rotateAxis(self.transform.right(), -rot_angle);
                self.maybeSyncTargetAfterLookChange();
            },
            // Roll changes bank only; forward (and thus a forward-synced target) is unchanged.
            .roll_right => self.transform.rotateAxis(self.transform.forward(), rot_angle),
            .roll_left => self.transform.rotateAxis(self.transform.forward(), -rot_angle),
            .radius_in => {
                const to_target = self.target.sub(self.transform.translation);
                const dist = to_target.length();
                if (dist > POSITION_EPSILON) {
                    const max_step = dist - POSITION_EPSILON;
                    const step = @min(translation_velocity, max_step);
                    if (step > 0.0) {
                        const dir = to_target.mulScalar(1.0 / dist);
                        self.transform.translation = self.transform.translation.add(dir.mulScalar(step));
                    }
                }
            },
            .radius_out => {
                const to_target = self.target.sub(self.transform.translation);
                const dist = to_target.length();
                // On top of the target the radial direction is undefined; dolly
                // out along -forward so the target ends up in front of the camera.
                const dir = if (dist > POSITION_EPSILON)
                    to_target.mulScalar(1.0 / dist)
                else
                    self.transform.forward();
                self.transform.translation = self.transform.translation.sub(dir.mulScalar(translation_velocity));
            },
            .orbit_right => {
                self.orbitAxis(self.transform.up(), orbit_angle);
            },
            .orbit_left => {
                self.orbitAxis(self.transform.up(), -orbit_angle);
            },
            .orbit_up => {
                self.orbitAxis(self.transform.right(), -orbit_angle);
            },
            .orbit_down => {
                self.orbitAxis(self.transform.right(), orbit_angle);
            },
            .circle_right => {
                self.circleAxis(self.world_up, orbit_angle);
            },
            .circle_left => {
                self.circleAxis(self.world_up, -orbit_angle);
            },
            .circle_up => {
                const rotation_axis = self.getWorldRight();
                self.circleAxis(rotation_axis, -orbit_angle);
            },
            .circle_down => {
                const rotation_axis = self.getWorldRight();
                self.circleAxis(rotation_axis, orbit_angle);
            },
        }
    }

    /// Free-look from mouse deltas (pixels). Uses `mouse_sensitivity` (degrees/pixel).
    ///
    /// Callers typically reverse Y so positive `yoffset` means look up (screen Y
    /// down). Maps to rotate left/right/up/down (same as keyboard free-look).
    ///
    /// When `constrain_pitch` is true, elevation is clamped to ±89° from the XZ
    /// plane so the camera cannot flip over the poles via mouse pitch.
    ///
    /// Bumps `update_tick` once for the whole mouse event (not once per axis).
    pub fn processMouseMovement(self: *Self, xoffset: f32, yoffset: f32, constrain_pitch: bool) void {
        const yaw = math.degreesToRadians(xoffset * self.mouse_sensitivity);
        var pitch = math.degreesToRadians(yoffset * self.mouse_sensitivity);

        if (constrain_pitch) {
            pitch = self.clampPitchDelta(pitch);
        }

        if (yaw == 0.0 and pitch == 0.0) {
            return;
        }

        // Yaw first, then pitch about updated right. Signs match rotate_* handlers.
        if (yaw != 0.0) {
            self.transform.rotateAxis(self.transform.up(), -yaw);
            self.direction = if (yaw > 0.0) .rotate_right else .rotate_left;
        }
        if (pitch != 0.0) {
            self.transform.rotateAxis(self.transform.right(), pitch);
            self.direction = if (pitch > 0.0) .rotate_up else .rotate_down;
        }

        self.maybeSyncTargetAfterLookChange();
        self.bumpTick();
    }

    /// Clamp a proposed pitch delta (radians, + = look up) so elevation stays in ±MAX_PITCH.
    fn clampPitchDelta(self: *const Self, pitch_delta: f32) f32 {
        const fwd = self.transform.forward();
        const elev = math.asin(math.clamp(fwd.y, -1.0, 1.0));
        const max_elev = math.degreesToRadians(MAX_PITCH_DEGREES);
        const new_elev = math.clamp(elev + pitch_delta, -max_elev, max_elev);
        return new_elev - elev;
    }

    /// Debug dump of position, target, and local basis.
    pub fn printState(self: *Self) void {
        var position_buf: [100]u8 = undefined;
        var target_buf: [100]u8 = undefined;
        var forward_buf: [100]u8 = undefined;
        var up_buf: [100]u8 = undefined;
        var right_buf: [100]u8 = undefined;
        const fwd = self.transform.forward();
        const up_vec = self.transform.up();
        const right_vec = self.transform.right();
        std.debug.print("Position: {s}\n", .{self.transform.translation.asString(&position_buf)});
        std.debug.print("Target: {s}\n", .{self.target.asString(&target_buf)});
        std.debug.print("Forward: {s}\n", .{fwd.asString(&forward_buf)});
        std.debug.print("Up: {s}\n", .{up_vec.asString(&up_buf)});
        std.debug.print("Right: {s}\n", .{right_vec.asString(&right_buf)});
    }
};

// ---------------------------------------------------------------------------
// Movement invariant tests (executable reference for motion families)
// ---------------------------------------------------------------------------

/// Apply an exact rotate/orbit/circle step of `angle` radians via `applyMovement`
/// (no speed/delta-time coupling). Production code should use `processMovement`.
fn stepAngle(movement: *Movement, angle: f32, direction: MovementDirection) void {
    movement.applyMovement(direction, 0.0, angle, angle);
}

fn expectVec3ApproxEq(a: Vec3, b: Vec3, eps: f32) !void {
    try std.testing.expectApproxEqAbs(a.x, b.x, eps);
    try std.testing.expectApproxEqAbs(a.y, b.y, eps);
    try std.testing.expectApproxEqAbs(a.z, b.z, eps);
}

test "orbit right full circle return" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    const radius: f32 = 10.0;
    const position = Vec3.init(radius, 0.0, 0.0);
    var movement = Movement.init(position, target);
    const start_pos = position.clone();
    const steps = 72;
    const step_angle = math.degreesToRadians(5.0);
    const epsilon = 0.001;
    for (0..steps) |_| {
        stepAngle(&movement, step_angle, .orbit_right);
        const current_radius = movement.transform.translation.sub(target).length();
        try std.testing.expectApproxEqAbs(current_radius, radius, epsilon);
        // Stays in horizontal plane when starting on equator with upright camera
        const radial = movement.transform.translation.sub(target).toNormalized();
        try std.testing.expectApproxEqAbs(radial.dot(movement.transform.up()), 0.0, epsilon);
    }
    try expectVec3ApproxEq(movement.transform.translation, start_pos, epsilon);
}

test "rotate 90 degrees about up changes forward" {
    // Looking -Z from origin-facing setup at (0,0,10)
    var movement = Movement.init(Vec3.init(0.0, 0.0, 10.0), Vec3.init(0.0, 0.0, 0.0));
    const pos0 = movement.transform.translation;
    const target0 = movement.target;

    // 90° free-look about local up (use applyMovement with exact radians)
    movement.applyMovement(.rotate_right, 0.0, math.degreesToRadians(90.0), 0.0);

    const eps = 0.02;
    // Position and target unchanged when sync is off
    try expectVec3ApproxEq(movement.transform.translation, pos0, eps);
    try expectVec3ApproxEq(movement.target, target0, eps);

    // Was looking -Z; after 90° about up, forward is approximately ±X
    const fwd = movement.transform.forward();
    try std.testing.expectApproxEqAbs(fwd.y, 0.0, eps);
    try std.testing.expectApproxEqAbs(@abs(fwd.x), 1.0, eps);
    try std.testing.expectApproxEqAbs(fwd.z, 0.0, eps);
}

test "rotate keeps target when sync disabled" {
    const position = Vec3.init(10.0, 0.0, 0.0);
    const target = Vec3.init(0.0, 0.0, 0.0);
    var movement = Movement.init(position, target);
    const start_target = target.clone();
    const step_angle = math.degreesToRadians(30.0);
    const epsilon = 0.001;
    for (0..12) |_| {
        stepAngle(&movement, step_angle, .rotate_right);
    }
    try expectVec3ApproxEq(movement.target, start_target, epsilon);
    try expectVec3ApproxEq(movement.transform.translation, position, epsilon);
}

test "rotate with sync_target_on_rotate keeps target along forward" {
    const position = Vec3.init(0.0, 0.0, 10.0);
    const target = Vec3.init(0.0, 0.0, 0.0);
    var movement = Movement.init(position, target);
    movement.sync_target_on_rotate = true;

    const start_distance = target.sub(position).length();
    stepAngle(&movement, math.degreesToRadians(30.0), .rotate_right);

    const to_target = movement.target.sub(movement.transform.translation);
    const eps = 0.001;
    try std.testing.expectApproxEqAbs(to_target.length(), start_distance, eps);
    try expectVec3ApproxEq(to_target.toNormalized(), movement.transform.forward(), eps);
}

test "translate does not reorient" {
    var movement = Movement.init(Vec3.init(0.0, 0.0, 10.0), Vec3.init(0.0, 0.0, 0.0));
    const fwd0 = movement.transform.forward();
    const up0 = movement.transform.up();
    const right0 = movement.transform.right();
    const pos0 = movement.transform.translation;

    // Sideways move: would break look-at if we reoriented toward target
    movement.processMovement(.left, 0.5);

    const eps = 0.0001;
    try expectVec3ApproxEq(movement.transform.forward(), fwd0, eps);
    try expectVec3ApproxEq(movement.transform.up(), up0, eps);
    try expectVec3ApproxEq(movement.transform.right(), right0, eps);
    try std.testing.expect(movement.transform.translation.sub(pos0).length() > 0.01);
}

test "radius in clamps near target" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    var movement = Movement.init(Vec3.init(2.0, 0.0, 0.0), target);

    movement.processMovement(.radius_in, 10.0);

    const dist = movement.transform.translation.sub(target).length();
    const tol: f32 = 1e-4;
    try std.testing.expect(dist <= POSITION_EPSILON + tol);
    try std.testing.expect(dist >= 0.0);

    const fwd = movement.transform.forward();
    try std.testing.expect(!std.math.isNan(fwd.x) and !std.math.isNan(fwd.y) and !std.math.isNan(fwd.z));
}

test "radius out then in restores distance" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    const start = Vec3.init(5.0, 0.0, 0.0);
    var movement = Movement.init(start, target);
    const start_dist = start.sub(target).length();

    // Dolly out then in by the same duration
    const dt: f32 = 0.2;
    movement.processMovement(.radius_out, dt);
    const mid_dist = movement.transform.translation.sub(target).length();
    try std.testing.expect(mid_dist > start_dist + 0.01);

    movement.processMovement(.radius_in, dt);
    const end_dist = movement.transform.translation.sub(target).length();
    try std.testing.expectApproxEqAbs(end_dist, start_dist, 0.05);
}

test "radius out at target falls back to forward" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    var movement = Movement.init(Vec3.init(0.0, 0.0, 10.0), target);
    // Degenerate: sitting exactly on the focus point
    movement.transform.translation = target;

    movement.processMovement(.radius_out, 0.1);

    const pos = movement.transform.translation;
    try std.testing.expect(!std.math.isNan(pos.x) and !std.math.isNan(pos.y) and !std.math.isNan(pos.z));
    try std.testing.expect(pos.sub(target).length() > 0.01);

    // Dolly out went along -forward, so the target sits in front of the camera
    const to_target = target.sub(pos).toNormalized();
    try std.testing.expectApproxEqAbs(to_target.dot(movement.transform.forward()), 1.0, 0.001);
}

test "orbit and circle diverge when pitched" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    const start = Vec3.init(10.0, 0.0, 0.0);
    const step = math.degreesToRadians(20.0);

    var orbit_m = Movement.init(start, target);
    // Pitch local frame first so orbit axes leave the world-horizontal plane
    stepAngle(&orbit_m, math.degreesToRadians(35.0), .orbit_up);
    const pitched_pos = orbit_m.transform.translation;
    const pitched_rot = orbit_m.transform.rotation;

    var circle_m = Movement.init(start, target);
    circle_m.transform.translation = pitched_pos;
    circle_m.transform.rotation = pitched_rot;
    circle_m.target = target;

    stepAngle(&orbit_m, step, .orbit_right);
    stepAngle(&circle_m, step, .circle_right);

    const pos_diff = orbit_m.transform.translation.sub(circle_m.transform.translation).length();
    // Same start attitude; world-axis circle vs local-axis orbit should separate
    try std.testing.expect(pos_diff > 0.05);
}

test "circle right full circle about world up returns" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    const radius: f32 = 8.0;
    // Elevated so path is a parallel of latitude (not equator-only special case)
    const start = Vec3.init(radius, 3.0, 0.0).toNormalized().mulScalar(radius);
    var movement = Movement.init(start, target);
    const start_pos = movement.transform.translation;

    const steps = 72;
    const step_angle = math.degreesToRadians(5.0);
    const eps = 0.02;
    for (0..steps) |_| {
        stepAngle(&movement, step_angle, .circle_right);
        try std.testing.expectApproxEqAbs(movement.transform.translation.sub(target).length(), radius, eps);
        // Constant height about world-up axis
        try std.testing.expectApproxEqAbs(movement.transform.translation.y, start_pos.y, eps);
    }
    try expectVec3ApproxEq(movement.transform.translation, start_pos, eps);
}

test "circle up/down works near pole" {
    const radius: f32 = 5.0;
    const target = Vec3.init(0.0, 0.0, 0.0);
    const near_south = Vec3.init(0.1, -radius, 0.0).toNormalized().mulScalar(radius);
    var movement = Movement.init(near_south, target);

    const start_pos_up = movement.transform.translation.clone();
    const step_angle = math.degreesToRadians(15.0);
    stepAngle(&movement, step_angle, .circle_up);

    // Should have moved and stayed on the same radius
    const new_radius_up = movement.transform.translation.sub(target).length();
    const eps = 1e-3;
    try std.testing.expect(new_radius_up > 0.0);
    try std.testing.expect(new_radius_up <= radius + eps and new_radius_up >= radius - eps);
    try std.testing.expect(!(movement.transform.translation.x == start_pos_up.x and movement.transform.translation.y == start_pos_up.y and movement.transform.translation.z == start_pos_up.z));
    try std.testing.expect(!std.math.isNan(movement.transform.translation.x) and !std.math.isNan(movement.transform.translation.y) and !std.math.isNan(movement.transform.translation.z));

    // Near the north pole
    const near_north = Vec3.init(0.1, radius, 0.0).toNormalized().mulScalar(radius);
    movement.reset(near_north, target);
    const start_pos_down = movement.transform.translation.clone();
    stepAngle(&movement, step_angle, .circle_down);
    const new_radius_down = movement.transform.translation.sub(target).length();
    try std.testing.expect(new_radius_down > 0.0);
    try std.testing.expect(new_radius_down <= radius + eps and new_radius_down >= radius - eps);
    try std.testing.expect(!(movement.transform.translation.x == start_pos_down.x and movement.transform.translation.y == start_pos_down.y and movement.transform.translation.z == start_pos_down.z));
    try std.testing.expect(!std.math.isNan(movement.transform.translation.x) and !std.math.isNan(movement.transform.translation.y) and !std.math.isNan(movement.transform.translation.z));
}

test "circle travels over pole with continuous orientation" {
    const radius: f32 = 5.0;
    const target = Vec3.init(0.0, 0.0, 0.0);
    // Start on +X equator; circle_up should climb toward +Y and beyond
    var movement = Movement.init(Vec3.init(radius, 0.0, 0.0), target);
    const step_angle = math.degreesToRadians(10.0);
    const eps = 1e-2;

    var max_y: f32 = movement.transform.translation.y;
    for (0..36) |_| {
        stepAngle(&movement, step_angle, .circle_up);
        const pos = movement.transform.translation;
        try std.testing.expectApproxEqAbs(pos.sub(target).length(), radius, eps);
        try std.testing.expect(!std.math.isNan(pos.x) and !std.math.isNan(pos.y) and !std.math.isNan(pos.z));
        const fwd = movement.transform.forward();
        try std.testing.expect(!std.math.isNan(fwd.x) and !std.math.isNan(fwd.y) and !std.math.isNan(fwd.z));
        if (pos.y > max_y) {
            max_y = pos.y;
        }
    }
    // Should have climbed well above the equator (through polar region)
    try std.testing.expect(max_y > radius * 0.5);
}

test "levelTowardTarget with world_up snaps upright" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    var movement = Movement.init(Vec3.init(0.0, 0.0, 10.0), target);

    // Tilt with orbit then free-look so basis is messy
    stepAngle(&movement, math.degreesToRadians(40.0), .orbit_up);
    stepAngle(&movement, math.degreesToRadians(25.0), .rotate_right);

    movement.levelTowardTarget(movement.world_up);

    const eps = 0.02;
    const pos = movement.transform.translation;
    const expected_fwd = target.sub(pos).toNormalized();
    const fwd = movement.transform.forward();
    try std.testing.expectApproxEqAbs(fwd.x, expected_fwd.x, eps);
    try std.testing.expectApproxEqAbs(fwd.y, expected_fwd.y, eps);
    try std.testing.expectApproxEqAbs(fwd.z, expected_fwd.z, eps);

    // Right should be approximately horizontal
    try std.testing.expectApproxEqAbs(movement.transform.right().y, 0.0, eps);
}

test "levelTowardTarget null levels right to XZ" {
    const target = Vec3.init(0.0, 0.0, 0.0);
    var movement = Movement.init(Vec3.init(10.0, 0.0, 0.0), target);
    stepAngle(&movement, math.degreesToRadians(30.0), .orbit_up);
    stepAngle(&movement, math.degreesToRadians(20.0), .rotate_left);

    movement.levelTowardTarget(null);

    const eps = 0.05;
    const pos = movement.transform.translation;
    const expected_fwd = target.sub(pos).toNormalized();
    const fwd = movement.transform.forward();
    try std.testing.expectApproxEqAbs(fwd.x, expected_fwd.x, eps);
    try std.testing.expectApproxEqAbs(fwd.y, expected_fwd.y, eps);
    try std.testing.expectApproxEqAbs(fwd.z, expected_fwd.z, eps);
    try std.testing.expectApproxEqAbs(movement.transform.right().y, 0.0, eps);
}

test "processMouseMovement rotates free-look" {
    var movement = Movement.init(Vec3.init(0.0, 0.0, 10.0), Vec3.init(0.0, 0.0, 0.0));
    const fwd0 = movement.transform.forward();

    // Positive x → look right; should change forward in XZ
    movement.processMouseMovement(50.0, 0.0, true);
    const fwd1 = movement.transform.forward();
    try std.testing.expect(@abs(fwd1.x - fwd0.x) > 0.01 or @abs(fwd1.z - fwd0.z) > 0.01);

    // Positive y → look up (with typical inverted screen Y)
    const elev0 = math.asin(math.clamp(fwd1.y, -1.0, 1.0));
    movement.processMouseMovement(0.0, 80.0, true);
    const elev1 = math.asin(math.clamp(movement.transform.forward().y, -1.0, 1.0));
    try std.testing.expect(elev1 > elev0);
}

test "processMouseMovement constrains pitch" {
    var movement = Movement.init(Vec3.init(0.0, 0.0, 10.0), Vec3.init(0.0, 0.0, 0.0));
    // Huge upward mouse motion should not go past ~89°
    movement.processMouseMovement(0.0, 10000.0, true);
    const elev = math.asin(math.clamp(movement.transform.forward().y, -1.0, 1.0));
    const max_elev = math.degreesToRadians(MAX_PITCH_DEGREES);
    try std.testing.expect(elev <= max_elev + 0.001);
    try std.testing.expect(elev >= max_elev - 0.05);
}

test "orbit bumps update_tick once" {
    var movement = Movement.init(Vec3.init(10.0, 0.0, 0.0), Vec3.init(0.0, 0.0, 0.0));
    const t0 = movement.getUpdateTick();
    movement.processMovement(.orbit_right, 0.1);
    try std.testing.expectEqual(t0 + 1, movement.getUpdateTick());
    movement.processMovement(.circle_up, 0.1);
    try std.testing.expectEqual(t0 + 2, movement.getUpdateTick());
}

test "processMouseMovement bumps update_tick once" {
    var movement = Movement.init(Vec3.init(0.0, 0.0, 10.0), Vec3.init(0.0, 0.0, 0.0));
    const t0 = movement.getUpdateTick();
    // Both axes non-zero — still a single public call
    movement.processMouseMovement(10.0, 10.0, true);
    try std.testing.expectEqual(t0 + 1, movement.getUpdateTick());
}

test "circle up near pole does not oscillate position" {
    const radius: f32 = 5.0;
    const target = Vec3.init(0.0, 0.0, 0.0);
    // Start just below the soft pole band so successive circle_up steps enter it
    const start = Vec3.init(0.5, radius - 0.15, 0.0).toNormalized().mulScalar(radius);
    var movement = Movement.init(start, target);

    const step_angle = math.degreesToRadians(2.0);
    var prev_y = movement.transform.translation.y;
    var direction_changes: u32 = 0;
    var prev_dy: f32 = 0.0;

    for (0..80) |_| {
        stepAngle(&movement, step_angle, .circle_up);
        const y = movement.transform.translation.y;
        const dy = y - prev_y;
        // Count sign flips of dy (oscillation); allow one flip when cresting the pole
        if (prev_dy != 0.0 and dy * prev_dy < 0.0) {
            direction_changes += 1;
        }
        if (dy != 0.0) {
            prev_dy = dy;
        }
        prev_y = y;
        try std.testing.expectApproxEqAbs(movement.transform.translation.sub(target).length(), radius, 0.02);
        try std.testing.expect(!std.math.isNan(y));
    }
    // Jitter would flip dy almost every frame; smooth pole pass has at most a few crests
    try std.testing.expect(direction_changes <= 4);
}
