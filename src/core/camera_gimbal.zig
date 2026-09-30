const std = @import("std");
const math = @import("math");

const Allocator = std.mem.Allocator;
const Movement = @import("movement.zig").Movement;
const MovementDirection = @import("movement.zig").MovementDirection;

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Transform = @import("transform.zig").Transform;
const RenderContext = @import("render_context.zig").RenderContext;

const MIN_FOV: f32 = 10.0;
const MAX_FOV: f32 = 120.0;

pub const ProjectionType = enum {
    Perspective,
    Orthographic,
};

/// Which camera the view shows. Each scenario picks what looks right in practice.
pub const ViewMode = enum {
    /// The base's transform only (like a fixed camera)
    base,
    /// The gimbal on a mount that follows the base's full orientation, pitch and tilt
    /// included: a satellite's camera tilts with the satellite's body.
    gimbal,
    /// The gimbal on a mount that keeps the base's heading but stays level with the
    /// horizontal plane: a vehicle's stabilized camera, whatever the vehicle's pitch or
    /// tilt. The gimbal's own aim still adds pitch.
    gimbal_level,
};

/// Dual Movement camera system with base and gimbal
///
/// This camera uses two Movement objects:
/// - base_movement: Handles position and movement (like a dolly, drone, or vehicle)
/// - gimbal_movement: Handles camera orientation relative to base (like a camera gimbal)
///
/// This eliminates gimbal lock issues and provides realistic camera rig behavior.
/// The base moves around the world, while the gimbal rotates the camera relative to the base.
pub const Camera = struct {
    allocator: Allocator,

    // Dual movement system
    base_movement: Movement,
    gimbal_movement: Movement,

    // View configuration
    view_mode: ViewMode,

    // Projection settings
    fov: f32,
    near: f32,
    far: f32,
    aspect: f32,
    ortho_scale: f32,
    projection_type: ProjectionType,

    // Caching
    cached_base_tick: u64,
    cached_gimbal_tick: u64,
    cached_view_mode: ViewMode,
    cached_view: Mat4,
    cached_projection: Mat4,
    view_cache_valid: bool,
    projection_cache_valid: bool,

    const Self = @This();

    const Config = struct {
        /// Base position (where the camera rig is located)
        base_position: Vec3,
        /// Base target (what the base/rig is oriented toward)
        base_target: Vec3,
        /// Gimbal position (relative to base, usually zero)
        gimbal_position: Vec3 = Vec3.init(0.0, 0.0, 0.0),
        /// Gimbal target (what the camera is looking at, relative to gimbal)
        gimbal_target: Vec3 = Vec3.init(0.0, 0.0, -1.0),
        /// Initial view mode
        view_mode: ViewMode = .gimbal,
        /// Screen dimensions
        scr_width: f32,
        scr_height: f32,
    };

    pub fn deinit(self: *const Self) void {
        self.allocator.destroy(self);
    }

    pub fn init(allocator: Allocator, config: Config) !*Camera {
        // Initialize base movement (handles spatial movement)
        var base_movement = Movement.init(config.base_position, config.base_target);
        base_movement.translate_speed = 20.0;
        base_movement.rotation_speed = 100.0;
        base_movement.orbit_speed = 200.0;

        // Initialize gimbal movement (handles camera orientation)
        // Gimbal starts at origin relative to base, looking forward
        var gimbal_movement = Movement.init(config.gimbal_position, config.gimbal_target);
        gimbal_movement.translate_speed = 0.0; // Gimbal doesn't translate
        gimbal_movement.rotation_speed = 120.0;
        gimbal_movement.orbit_speed = 120.0;

        const camera = try allocator.create(Camera);
        camera.* = Camera{
            .allocator = allocator,
            .base_movement = base_movement,
            .gimbal_movement = gimbal_movement,
            .view_mode = config.view_mode,
            .fov = 75.0,
            .aspect = config.scr_width / config.scr_height,
            .near = 0.01,
            .far = 2000.0,
            .ortho_scale = 30.0,
            .projection_type = .Perspective,
            .cached_base_tick = 0,
            .cached_gimbal_tick = 0,
            .cached_view_mode = config.view_mode,
            .cached_view = undefined,
            .cached_projection = undefined,
            .view_cache_valid = false,
            .projection_cache_valid = false,
        };

        return camera;
    }

    // Projection matrix methods
    pub fn getProjectionWithType(self: *const Camera, projection_type: ProjectionType) Mat4 {
        switch (projection_type) {
            .Perspective => {
                return Mat4.perspectiveRhZo(
                    math.degreesToRadians(self.fov),
                    self.aspect,
                    self.near,
                    self.far,
                );
            },
            .Orthographic => {
                const ortho_width = self.aspect * self.ortho_scale;
                const ortho_height = self.ortho_scale;
                return Mat4.orthographicRhZo(
                    -ortho_width,
                    ortho_width,
                    -ortho_height,
                    ortho_height,
                    self.near,
                    self.far,
                );
            },
        }
    }

    pub fn getProjection(self: *Self) Mat4 {
        if (!self.projection_cache_valid) {
            self.cached_projection = self.getProjectionWithType(self.projection_type);
            self.projection_cache_valid = true;
        }
        return self.cached_projection;
    }

    /// Get view matrix based on current view mode
    pub fn getView(self: *Self) Mat4 {
        const base_tick = self.base_movement.getUpdateTick();
        const gimbal_tick = self.gimbal_movement.getUpdateTick();

        if (!self.view_cache_valid or
            base_tick != self.cached_base_tick or
            gimbal_tick != self.cached_gimbal_tick or
            self.view_mode != self.cached_view_mode)
        {
            self.cached_view = self.getCameraTransform().toViewMatrix();

            self.cached_base_tick = base_tick;
            self.cached_gimbal_tick = gimbal_tick;
            self.cached_view_mode = self.view_mode;
            self.view_cache_valid = true;
        }
        return self.cached_view;
    }

    /// The camera's world transform in the current view mode: the base alone, or the
    /// gimbal's transform on top of its mount (the base, or the base leveled). The view is
    /// its inverse, and `getCameraPosition` / `getCameraForward` read it, so all three
    /// always describe the same camera.
    pub fn getCameraTransform(self: *const Self) Transform {
        const base = self.base_movement.getTransform().*;
        const gimbal = self.gimbal_movement.getTransform().*;
        return switch (self.view_mode) {
            .base => base,
            .gimbal => base.composeTransforms(gimbal),
            .gimbal_level => levelMount(base).composeTransforms(gimbal),
        };
    }

    /// `base` with its pitch and tilt removed: same position, heading along the base's
    /// forward flattened onto the horizontal plane, world up as up. Looking straight down
    /// (or up) the forward has no horizontal part; the base's up then gives the heading,
    /// since it points where the top of the view does.
    fn levelMount(base: Transform) Transform {
        const forward = base.forward();
        var heading = Vec3.init(forward.x, 0.0, forward.z);
        if (heading.lengthSquared() < 1e-6) {
            const up = base.up();
            heading = Vec3.init(up.x, 0.0, up.z);
        }
        var level = Transform.identity();
        level.translation = base.translation;
        level.lookTo(heading, Vec3.World_Up);
        return level;
    }

    pub fn getProjectionView(self: *Self) Mat4 {
        return self.getProjection().mulMat4(&self.getView());
    }

    pub fn getRenderContext(self: *Self, time: f32) RenderContext {
        const projection = self.getProjection();
        const view = self.getView();
        return .{
            .projection = projection,
            .projection_view = projection.mulMat4(&view),
            .view = view,
            .view_position = self.getCameraPosition(),
            .time = time,
        };
    }

    // View mode control
    pub fn setViewMode(self: *Self, view_mode: ViewMode) void {
        self.view_mode = view_mode;
        self.view_cache_valid = false;
    }

    pub fn getViewMode(self: *const Self) ViewMode {
        return self.view_mode;
    }

    // Base movement control (spatial movement - position, orbit, etc.)
    pub fn processBaseMovement(self: *Self, direction: MovementDirection, delta_time: f32) void {
        self.base_movement.processMovement(direction, delta_time);
    }

    // Gimbal movement control (camera orientation relative to base)
    pub fn processGimbalMovement(self: *Self, direction: MovementDirection, delta_time: f32) void {
        // Gimbal only handles rotation commands
        switch (direction) {
            .rotate_left, .rotate_right, .rotate_up, .rotate_down, .roll_left, .roll_right => {
                self.gimbal_movement.processMovement(direction, delta_time);
            },
            else => {},
        }
    }

    // Unified movement processing with automatic routing
    pub fn processMovement(self: *Self, direction: MovementDirection, delta_time: f32) void {
        switch (direction) {
            // Spatial movements go to base
            .forward, .backward, .left, .right, .up, .down => {
                self.processBaseMovement(direction, delta_time);
            },
            .turn_left, .turn_right => {
                self.processBaseMovement(direction, delta_time);
            },
            .orbit_left, .orbit_right, .orbit_up, .orbit_down => {
                self.processBaseMovement(direction, delta_time);
            },
            .circle_left, .circle_right, .circle_up, .circle_down => {
                self.processBaseMovement(direction, delta_time);
            },
            .radius_in, .radius_out => {
                self.processBaseMovement(direction, delta_time);
            },

            // Rotations go to gimbal for proper gimbal behavior
            .rotate_left, .rotate_right, .rotate_up, .rotate_down => {
                self.processGimbalMovement(direction, delta_time);
            },
            .roll_left, .roll_right => {
                self.processGimbalMovement(direction, delta_time);
            },
        }
    }

    // Convenience methods that pass pre-computed angles via applyMovement
    pub fn orbitTarget(self: *Self, yaw_delta: f32, pitch_delta: f32) void {
        if (yaw_delta != 0.0) {
            const direction: MovementDirection = if (yaw_delta > 0) .orbit_right else .orbit_left;
            self.base_movement.applyMovement(direction, 0, 0, @abs(yaw_delta));
        }
        if (pitch_delta != 0.0) {
            const direction: MovementDirection = if (pitch_delta > 0) .orbit_up else .orbit_down;
            self.base_movement.applyMovement(direction, 0, 0, @abs(pitch_delta));
        }
    }

    pub fn aimGimbal(self: *Self, yaw_delta: f32, pitch_delta: f32) void {
        if (yaw_delta != 0.0) {
            const direction: MovementDirection = if (yaw_delta > 0) .rotate_right else .rotate_left;
            self.gimbal_movement.applyMovement(direction, 0, @abs(yaw_delta), 0);
        }
        if (pitch_delta != 0.0) {
            const direction: MovementDirection = if (pitch_delta > 0) .rotate_up else .rotate_down;
            self.gimbal_movement.applyMovement(direction, 0, @abs(pitch_delta), 0);
        }
    }

    pub fn frameTarget(self: *Self, target: Vec3, distance: f32) void {
        const direction = target.sub(self.base_movement.getPosition()).toNormalized();
        const new_position = target.sub(direction.mulScalar(distance));

        self.base_movement.reset(new_position, target);
        // Reset gimbal to look forward relative to base
        self.gimbal_movement.reset(Vec3.init(0.0, 0.0, 0.0), Vec3.init(0.0, 0.0, -1.0));
    }

    // Target management
    pub fn setBaseTarget(self: *Self, target: Vec3) void {
        self.base_movement.setTarget(target);
    }

    pub fn getBaseTarget(self: *const Self) Vec3 {
        return self.base_movement.getTarget();
    }

    pub fn setGimbalTarget(self: *Self, target: Vec3) void {
        self.gimbal_movement.setTarget(target);
    }

    pub fn getGimbalTarget(self: *const Self) Vec3 {
        return self.gimbal_movement.getTarget();
    }

    // Projection settings
    pub fn setPerspective(self: *Self) void {
        self.projection_type = .Perspective;
        self.projection_cache_valid = false;
    }

    pub fn setOrthographic(self: *Self) void {
        self.projection_type = .Orthographic;
        self.projection_cache_valid = false;
    }

    pub fn setAspect(self: *Self, aspect_ratio: f32) void {
        self.aspect = aspect_ratio;
        self.projection_cache_valid = false;
    }

    pub fn setScreenDimensions(self: *Self, width: f32, height: f32) void {
        self.aspect = width / height;
        self.projection_cache_valid = false;
    }

    pub fn adjustFov(self: *Self, zoom_amount: f32) void {
        self.fov -= zoom_amount;
        self.fov = std.math.clamp(self.fov, MIN_FOV, MAX_FOV);
        self.projection_cache_valid = false;
    }

    // Getters
    pub fn getFov(self: *const Self) f32 {
        return self.fov;
    }

    pub fn getAspect(self: *const Self) f32 {
        return self.aspect;
    }

    pub fn getBasePosition(self: *const Self) Vec3 {
        return self.base_movement.getPosition();
    }

    pub fn getGimbalPosition(self: *const Self) Vec3 {
        return self.gimbal_movement.getPosition();
    }

    /// The view's eye in the current view mode (see `getCameraTransform`).
    pub fn getCameraPosition(self: *const Self) Vec3 {
        return self.getCameraTransform().translation;
    }

    pub fn getBaseForward(self: *const Self) Vec3 {
        return self.base_movement.getTransform().forward();
    }

    pub fn getGimbalForward(self: *const Self) Vec3 {
        return self.gimbal_movement.getTransform().forward();
    }

    /// The view's forward direction in the current view mode (see `getCameraTransform`).
    pub fn getCameraForward(self: *const Self) Vec3 {
        return self.getCameraTransform().forward();
    }

    // Reset
    pub fn reset(self: *Self, base_position: Vec3, base_target: Vec3) void {
        self.base_movement.reset(base_position, base_target);
        self.gimbal_movement.reset(Vec3.init(0.0, 0.0, 0.0), Vec3.init(0.0, 0.0, -1.0));
    }

    // Debug output
    pub fn asString(self: *const Camera, buf: []u8) []u8 {
        var base_pos: [100]u8 = undefined;
        var base_target: [100]u8 = undefined;
        var gimbal_pos: [100]u8 = undefined;
        var camera_forward: [100]u8 = undefined;

        const base_position = self.base_movement.getPosition();
        const base_tgt = self.base_movement.getTarget();
        const gimbal_position = self.gimbal_movement.getPosition();
        const cam_fwd = self.getCameraForward();

        return std.fmt.bufPrint(
            buf,
            "DualCamera:\n   view_mode: {any}\n   base_pos: {s}\n   base_target: {s}\n   gimbal_pos: {s}\n   camera_forward: {s}\n   fov: {d}°\n",
            .{
                self.view_mode,
                base_position.asString(&base_pos),
                base_tgt.asString(&base_target),
                gimbal_position.asString(&gimbal_pos),
                cam_fwd.asString(&camera_forward),
                self.fov,
            },
        ) catch |err| std.debug.panic("{any}", .{err});
    }
};

// Usage examples and tests
test "dual camera base movement" {
    const allocator = std.testing.allocator;

    const camera = try Camera.init(allocator, .{
        .base_position = Vec3.init(10.0, 0.0, 0.0),
        .base_target = Vec3.init(0.0, 0.0, 0.0),
        .view_mode = .base,
        .scr_width = 800,
        .scr_height = 600,
    });
    defer camera.deinit();

    const initial_pos = camera.getBasePosition();

    // Move base forward
    camera.processBaseMovement(.forward, 0.1);

    const final_pos = camera.getBasePosition();

    // Base should have moved
    const moved = !std.meta.eql(initial_pos, final_pos);
    try std.testing.expect(moved);
}

test "dual camera gimbal independence" {
    const allocator = std.testing.allocator;

    const camera = try Camera.init(allocator, .{
        .base_position = Vec3.init(10.0, 0.0, 0.0),
        .base_target = Vec3.init(0.0, 0.0, 0.0),
        .view_mode = .gimbal,
        .scr_width = 800,
        .scr_height = 600,
    });
    defer camera.deinit();

    const initial_base_pos = camera.getBasePosition();
    const initial_gimbal_forward = camera.getGimbalForward();

    // Rotate gimbal
    camera.processGimbalMovement(.rotate_right, 0.1);

    const final_base_pos = camera.getBasePosition();
    const final_gimbal_forward = camera.getGimbalForward();

    // Base position should be unchanged
    try std.testing.expect(std.meta.eql(initial_base_pos, final_base_pos));

    // Gimbal orientation should have changed
    const gimbal_moved = !std.meta.eql(initial_gimbal_forward, final_gimbal_forward);
    try std.testing.expect(gimbal_moved);
}

test "dual camera orbit with independent aim" {
    const allocator = std.testing.allocator;

    const camera = try Camera.init(allocator, .{
        .base_position = Vec3.init(10.0, 0.0, 0.0),
        .base_target = Vec3.init(0.0, 0.0, 0.0),
        .view_mode = .gimbal,
        .scr_width = 800,
        .scr_height = 600,
    });
    defer camera.deinit();

    // Orbit base around target
    camera.processBaseMovement(.orbit_right, 0.1);
    const orbital_pos = camera.getBasePosition();

    // Aim gimbal independently
    camera.processGimbalMovement(.rotate_left, 0.1);

    // Base position should be same as after orbit
    const final_base_pos = camera.getBasePosition();
    const epsilon = 0.001;
    try std.testing.expectApproxEqAbs(orbital_pos.x, final_base_pos.x, epsilon);
    try std.testing.expectApproxEqAbs(orbital_pos.y, final_base_pos.y, epsilon);
    try std.testing.expectApproxEqAbs(orbital_pos.z, final_base_pos.z, epsilon);

    // But camera should be looking in a different direction due to gimbal
    const base_forward = camera.getBaseForward();
    const camera_forward = camera.getCameraForward();

    // These should be different due to gimbal rotation
    const dot_product = base_forward.dot(camera_forward);
    try std.testing.expect(dot_product < 0.99); // Significantly different
}

test "dual camera: position and forward are the view's in every mode" {
    const allocator = std.testing.allocator;

    // The base above its target, looking down at it and tilted; the gimbal mounted off
    // center and turned
    const camera = try Camera.init(allocator, .{
        .base_position = Vec3.init(0.0, 6.0, 8.0),
        .base_target = Vec3.init(0.0, 0.0, 0.0),
        .gimbal_position = Vec3.init(0.5, 0.2, 0.0),
        .scr_width = 800,
        .scr_height = 600,
    });
    defer camera.deinit();
    camera.base_movement.applyMovement(.roll_right, 0.0, std.math.degreesToRadians(20.0), 0.0);
    camera.processGimbalMovement(.rotate_right, 0.2);
    camera.processGimbalMovement(.rotate_up, 0.1);

    for ([_]ViewMode{ .base, .gimbal, .gimbal_level }) |mode| {
        camera.setViewMode(mode);
        const view_camera = viewCamera(camera.getView());
        try expectVec3ApproxEq(view_camera.eye, camera.getCameraPosition(), 1e-4);
        try expectVec3ApproxEq(view_camera.forward, camera.getCameraForward(), 1e-4);
    }
}

test "dual camera: the gimbal tilts with the base, or stays level with gimbal_level" {
    const allocator = std.testing.allocator;

    // A satellite-like base, pitched down at its target and banked 30 degrees
    const camera = try Camera.init(allocator, .{
        .base_position = Vec3.init(0.0, 4.0, 10.0),
        .base_target = Vec3.init(0.0, 0.0, 0.0),
        .view_mode = .gimbal,
        .scr_width = 800,
        .scr_height = 600,
    });
    defer camera.deinit();
    camera.base_movement.applyMovement(.roll_right, 0.0, std.math.degreesToRadians(30.0), 0.0);

    // .gimbal, centered: the view's up is the base's tilted up
    const tilted = viewCamera(camera.getView());
    try expectVec3ApproxEq(camera.base_movement.getTransform().up(), tilted.up, 1e-4);
    try std.testing.expect(tilted.up.y < 0.9);

    // .gimbal_level, centered: world up, level forward, the base's heading
    camera.setViewMode(.gimbal_level);
    const level = viewCamera(camera.getView());
    try expectVec3ApproxEq(Vec3.init(0.0, 1.0, 0.0), level.up, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), level.forward.y, 1e-4);
    const base_forward = camera.getBaseForward();
    const heading = Vec3.init(base_forward.x, 0.0, base_forward.z).toNormalized();
    try expectVec3ApproxEq(heading, level.forward, 1e-4);
}

/// Eye, forward, and up of the camera a view matrix belongs to: the view's inverse is
/// the camera's world transform, whose columns are right, up, back, and position.
fn viewCamera(view: Mat4) struct { eye: Vec3, forward: Vec3, up: Vec3 } {
    const world = view.getInverse();
    return .{
        .eye = Vec3.init(world.data[3][0], world.data[3][1], world.data[3][2]),
        .forward = Vec3.init(-world.data[2][0], -world.data[2][1], -world.data[2][2]),
        .up = Vec3.init(world.data[1][0], world.data[1][1], world.data[1][2]),
    };
}

fn expectVec3ApproxEq(expected: Vec3, actual: Vec3, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}
