const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");

const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const vec2 = math.vec2;
const vec3 = math.vec3;

const log = std.log.scoped(.State);

const EnumSet = std.EnumSet;

const Player = @import("player.zig").Player;
const Enemy = @import("enemy.zig").Enemy;
const BurnMarks = @import("burn_marks.zig").BurnMarks;
const Capsule = @import("capsule.zig").Capsule;

const Camera = core.Camera;
const SoundEngine = core.SoundEngine;

// Player
pub const PLAYER_SPEED: f32 = 5.0;
//pub const FIRE_INTERVAL: f32 = 0.1;
pub const FIRE_INTERVAL: f32 = 0.5;
pub const PLAYER_COLLISION_RADIUS: f32 = 0.35;
pub const PLAYER_MODEL_SCALE: f32 = 0.0044;
pub const PLAYER_MODEL_GUN_HEIGHT: f32 = 110.0;
pub const PLAYER_MODEL_GUN_MUZZLE_OFFSET: f32 = 100.0;
pub const ANIM_TRANSITION_TIME: f32 = 0.2;

// Enemies
pub const MONSTER_Y: f32 = PLAYER_MODEL_SCALE * PLAYER_MODEL_GUN_HEIGHT;
pub const MONSTER_SPEED: f32 = 0.6;
pub const ENEMY_SPAWN_INTERVAL: f32 = 1.0; // seconds
pub const SPAWNS_PER_INTERVAL: i32 = 1;
pub const SPAWN_RADIUS: f32 = 10.0; // from player
pub const ENEMY_COLLIDER: Capsule = Capsule{ .length = 0.4, .radius = 0.08 };

// Bullets
pub const SPREAD_AMOUNT: i32 = 20; // bullet spread
// pub const SPREAD_AMOUNT: i32 = 1; // bullet spread
pub const BULLET_SCALE: f32 = 0.3;
// pub const BULLET_SCALE: f32 = 2.0;
pub const BULLET_LIFETIME: f32 = 10.0;
pub const BULLET_SPEED: f32 = 15.0;
// pub const BULLET_SPEED: f32 = 2.0;
pub const ROTATION_PER_BULLET: f32 = 3.0; // in degrees
pub const BURN_MARK_TIME: f32 = 5.0; // seconds
pub const BULLET_COLLIDER: Capsule = Capsule{ .length = 0.3, .radius = 0.03 };

pub const camera_follow_vec = vec3(0.0, 4.0, 4.0);

pub const CameraType = enum {
    Game,
    Floating,
    TopDown,
    Side,
};

pub const ClipName = enum {
    GunFire,
    Explosion,
};

pub const ClipData = struct {
    clip: ClipName,
    file: [:0]const u8,
};

pub const Input = struct {
    first_mouse: bool = false,
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    mouse_right_button: bool = false,
    mouse_left_button: bool = false,
    key_presses: EnumSet(glfw.Key),
    key_shift: bool = false,
    key_alt: bool = false,
};

pub const State = struct {
    viewport_width: f32,
    viewport_height: f32,
    scaled_width: f32,
    scaled_height: f32,
    window_scale: [2]f32,
    game_camera: *Camera,
    floating_camera: *Camera,
    ortho_camera: *Camera,
    active_camera: *Camera,
    player: *Player,
    burn_marks: *BurnMarks,
    enemies: containers.ManagedArrayList(?Enemy),
    sound_engine: SoundEngine(ClipName, ClipData),
    input: Input,
    light_postion: math.Vec3,
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    delta_time: f32,
    frame_time: f32,
    first_mouse: bool,
    last_x: f32,
    last_y: f32,
    run: bool,
};

var state: *State = undefined;

pub fn getMousePointAngle(view: *const Mat4, position: *Vec3) f32 {
    var point_angle: f32 = 0.0;
    var dx: f32 = 0.0;
    var dz: f32 = 0.0;

    const world_ray = math.getWorldRayFromMouse(
        state.scaled_width,
        state.scaled_height,
        &state.game_camera.getProjection(),
        view,
        state.mouse_x + 0.0001,
        state.mouse_y,
    );

    const xz_plane_point = vec3(0.0, 0.0, 0.0);
    const xz_plane_normal = vec3(0.0, 1.0, 0.0);

    const world_point = math.getRayPlaneIntersection(
        world_ray.origin,
        world_ray.direction,
        xz_plane_point,
        xz_plane_normal,
    );

    if (world_point) |point| {
        dx = point.x - position.x;
        dz = point.z - position.z;

        if (dz != 0.0) {
            point_angle = math.atan(dx / dz);
        }

        if (dz < 0.0) {
            point_angle = point_angle + math.pi;
        }

        if (@abs(state.mouse_x) < 0.005 and @abs(state.mouse_y) < 0.005) {
            point_angle = 0.0;
        }
    }
    return point_angle;
}

pub fn processInput() void {
    state.player.direction = vec2(0, 0);
    var direction_vec = Vec3.splat(0.0);

    var iterator = state.input.key_presses.iterator();
    while (iterator.next()) |key| {
        if (state.input.key_shift) {
            switch (key) {
                .w => state.game_camera.movement.processMovement(.forward, state.delta_time),
                .s => state.game_camera.movement.processMovement(.backward, state.delta_time),
                .a => state.game_camera.movement.processMovement(.left, state.delta_time),
                .d => state.game_camera.movement.processMovement(.right, state.delta_time),
                else => {},
            }
        } else if (state.input.key_alt) {
            switch (key) {
                .w => state.game_camera.movement.processMovement(.circle_up, state.delta_time),
                .s => state.game_camera.movement.processMovement(.circle_down, state.delta_time),
                .a => state.game_camera.movement.processMovement(.circle_left, state.delta_time),
                .d => state.game_camera.movement.processMovement(.circle_right, state.delta_time),
                else => {},
            }
        } else {
            switch (key) {
                .a => direction_vec.addTo(vec3(-1.0, 0.0, 0.0)),
                .d => direction_vec.addTo(vec3(1.0, 0.0, 0.0)),
                .s => direction_vec.addTo(vec3(0.0, 0.0, 1.0)),
                .w => direction_vec.addTo(vec3(0.0, 0.0, -1.0)),
                .one => state.active_camera = state.game_camera,
                .two => state.active_camera = state.floating_camera,
                .three => state.active_camera = state.ortho_camera,
                .four => state.active_camera = state.active_camera, // should be side camera
                else => {},
            }
        }
    }

    if (direction_vec.lengthSquared() > 0.1 and state.player.is_alive) {
        state.player.position.addTo(direction_vec.toNormalized().mulScalar(state.player.speed * state.delta_time));
        state.player.direction = vec2(direction_vec.x, direction_vec.z);
    }
}

pub fn initStateHandlers(window: *glfw.Window, state_instance: *State) void {
    _ = window.setKeyCallback(keyHandler);
    _ = window.setFramebufferSizeCallback(framebufferSizeHandler);
    _ = window.setCursorPosCallback(cursorPositionHandler);
    _ = window.setScrollCallback(scrollHandler);
    _ = window.setMouseButtonCallback(mouseHandler);

    state = state_instance;
}

fn keyHandler(window: *glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    _ = scancode;

    switch (action) {
        .release => state.input.key_presses.remove(key),
        .press => state.input.key_presses.insert(key),
        else => {},
    }

    state.input.key_shift = mods.shift;
    state.input.key_alt = mods.control;

    // Handle keys that fire on press only
    switch (key) {
        .escape => {
            window.setShouldClose(true);
        },
        .t => if (action == glfw.Action.press) {
            log.info("time: {d}", .{state.delta_time});
        },
        .space => if (action == glfw.Action.press) {
            state.run = !state.run;
        },
        else => {},
    }
}

fn framebufferSizeHandler(window: *glfw.Window, width: i32, height: i32) callconv(.c) void {
    _ = window;
    // GpuContext resizes the surface itself; run_app recreates the render targets.
    setViewPort(width, height);
}

fn setViewPort(w: i32, h: i32) void {
    const width: f32 = @floatFromInt(w);
    const height: f32 = @floatFromInt(h);

    state.viewport_width = width;
    state.viewport_height = height;
    state.scaled_width = width / state.window_scale[0];
    state.scaled_height = height / state.window_scale[1];

    state.game_camera.setScreenDimensions(state.viewport_width, state.viewport_height);
    state.floating_camera.setScreenDimensions(state.viewport_width, state.viewport_height);
    state.ortho_camera.setScreenDimensions(state.viewport_width, state.viewport_height);
}

fn cursorPositionHandler(window: *glfw.Window, xposIn: f64, yposIn: f64) callconv(.c) void {
    _ = window;
    state.mouse_x = math.clamp(@as(f32, @floatCast(xposIn)), 0, state.viewport_width);
    state.mouse_y = math.clamp(@as(f32, @floatCast(yposIn)), 0, state.viewport_height);
}

fn mouseHandler(window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    _ = window;
    _ = mods;
    switch (button) {
        .left => {
            // log.info("left mouse button action = {any}", .{action});
            switch (action) {
                .press => state.player.is_trying_to_fire = true,
                .release => state.player.is_trying_to_fire = false,
                else => {},
            }
        },
        else => {},
    }
}

fn scrollHandler(window: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = window;
    _ = xoffset;
    state.game_camera.adjustFov(@floatCast(yoffset));
    state.floating_camera.adjustFov(@floatCast(yoffset));
    state.ortho_camera.adjustFov(@floatCast(yoffset));
}
