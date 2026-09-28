const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");
const assets_list = @import("assets_list.zig");

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const EnumSet = std.EnumSet;

const Window = glfw.Window;
const Camera = core.Camera;

pub const MotionType = enum {
    /// Direct movement along camera's local axes (Left, Right, Up, Down)
    Translate,
    /// Rotation around target point (OrbitLeft, OrbitRight, OrbitUp, OrbitDown)
    Orbit,
    /// Movement around target maintaining height (CircleLeft, CircleRight)
    Circle,
    /// In-place rotation (RotateLeft, RotateRight, RotateUp, RotateDown)
    Rotate,
};

pub const Input = struct {
    first_mouse: bool = false,
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    mouse_right_button: bool = false,
    mouse_left_button: bool = false,
    key_presses: EnumSet(glfw.Key),
    key_processed: EnumSet(glfw.Key),
    key_shift: bool = false,
    key_alt: bool = false,
};

pub const State = struct {
    viewport_width: f32,
    viewport_height: f32,
    scaled_width: f32,
    scaled_height: f32,
    window_scale: [2]f32,
    delta_time: f32,
    total_time: f32,
    input: Input,
    camera: *Camera,
    light_position: Vec3,
    spin: bool = false,
    world_point: ?Vec3,
    camera_initial_position: Vec3,
    camera_initial_target: Vec3,
    single_mesh_id: i32 = -1,
    animation_id: i32 = -1,
    motion_type: MotionType = .Circle,
    current_model_index: i32 = 0,
    model_reload_requested: bool = false,
    model_index_increment: i32 = 1,
    camera_reposition_requested: bool = false,
    output_position_requested: bool = false,
    ui_help_visible: bool = false,
    ui_camera_info_visible: bool = true,
    /// E: SceneLights.fade_grazing_specular (stylistic; off is physically based)
    fade_grazing_specular: bool = false,
    animation_reset_requested: bool = false,
    animation_next_requested: bool = false,
    animation_prev_requested: bool = false,
    shader_debug_enabled: bool = false,
    shader_debug_dump_requested: bool = false,
    screenshot_requested: bool = false,
    run_animation: bool = true,

    const Self = @This();
};

pub var state: State = undefined;

pub fn initWindowHandlers(window: *glfw.Window) void {
    _ = window.setKeyCallback(keyHandler);
    _ = window.setFramebufferSizeCallback(framebufferSizeHandler);
    _ = window.setCursorPosCallback(cursorPositionHandler);
    _ = window.setScrollCallback(scrollHandler);
    _ = window.setMouseButtonCallback(mouseHandler);
}

pub fn keyHandler(window: *glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    _ = scancode;

    switch (action) {
        .press => state.input.key_presses.insert(key),
        .release => {
            state.input.key_presses.remove(key);
            state.input.key_processed.remove(key);
        },
        else => {},
    }

    state.input.key_shift = mods.shift;
    state.input.key_alt = mods.alt;

    if (key == .escape) {
        window.setShouldClose(true);
    }
}

pub fn processKeys() void {
    var iterator = state.input.key_presses.iterator();
    while (iterator.next()) |k| {
        switch (k) {
            .t => std.debug.print("time: {d}\n", .{state.delta_time}),
            .w => {
                switch (state.motion_type) {
                    .Translate => {
                        state.camera.movement.processMovement(.forward, state.delta_time);
                    },
                    .Orbit => {
                        state.camera.movement.processMovement(.orbit_up, state.delta_time);
                    },
                    .Circle => {
                        // No circle movement for W key
                        state.camera.movement.processMovement(.orbit_up, state.delta_time);
                    },
                    .Rotate => {
                        state.camera.movement.processMovement(.rotate_up, state.delta_time);
                    },
                }
            },
            .s => {
                switch (state.motion_type) {
                    .Translate => {
                        state.camera.movement.processMovement(.backward, state.delta_time);
                    },
                    .Orbit => {
                        state.camera.movement.processMovement(.orbit_down, state.delta_time);
                    },
                    .Circle => {
                        // No circle movement for S key
                        state.camera.movement.processMovement(.orbit_down, state.delta_time);
                    },
                    .Rotate => {
                        state.camera.movement.processMovement(.rotate_down, state.delta_time);
                    },
                }
            },
            .a => {
                switch (state.motion_type) {
                    .Translate => {
                        state.camera.movement.processMovement(.left, state.delta_time);
                    },
                    .Orbit => {
                        state.camera.movement.processMovement(.orbit_left, state.delta_time);
                    },
                    .Circle => {
                        state.camera.movement.processMovement(.circle_left, state.delta_time);
                    },
                    .Rotate => {
                        state.camera.movement.processMovement(.rotate_left, state.delta_time);
                    },
                }
            },
            .d => {
                switch (state.motion_type) {
                    .Translate => {
                        state.camera.movement.processMovement(.right, state.delta_time);
                    },
                    .Orbit => {
                        state.camera.movement.processMovement(.orbit_right, state.delta_time);
                    },
                    .Circle => {
                        state.camera.movement.processMovement(.circle_right, state.delta_time);
                    },
                    .Rotate => {
                        state.camera.movement.processMovement(.rotate_right, state.delta_time);
                    },
                }
            },
            .up => {
                switch (state.motion_type) {
                    .Translate => {
                        state.camera.movement.processMovement(.up, state.delta_time);
                    },
                    .Orbit => {
                        state.camera.movement.processMovement(.orbit_up, state.delta_time);
                    },
                    .Circle => {
                        // No circle movement for Up key
                        state.camera.movement.processMovement(.circle_up, state.delta_time);
                    },
                    .Rotate => {
                        state.camera.movement.processMovement(.rotate_up, state.delta_time);
                    },
                }
            },
            .down => {
                switch (state.motion_type) {
                    .Translate => {
                        state.camera.movement.processMovement(.down, state.delta_time);
                    },
                    .Orbit => {
                        state.camera.movement.processMovement(.orbit_down, state.delta_time);
                    },
                    .Circle => {
                        // No circle movement for Down key
                        state.camera.movement.processMovement(.circle_down, state.delta_time);
                    },
                    .Rotate => {
                        state.camera.movement.processMovement(.rotate_down, state.delta_time);
                    },
                }
            },
            .right => {
                switch (state.motion_type) {
                    .Translate => {
                        state.camera.movement.processMovement(.right, state.delta_time);
                    },
                    .Orbit => {
                        state.camera.movement.processMovement(.orbit_right, state.delta_time);
                    },
                    .Circle => {
                        state.camera.movement.processMovement(.circle_right, state.delta_time);
                    },
                    .Rotate => {
                        state.camera.movement.processMovement(.rotate_right, state.delta_time);
                    },
                }
            },
            .left => {
                switch (state.motion_type) {
                    .Translate => {
                        state.camera.movement.processMovement(.left, state.delta_time);
                    },
                    .Orbit => {
                        state.camera.movement.processMovement(.orbit_left, state.delta_time);
                    },
                    .Circle => {
                        state.camera.movement.processMovement(.circle_left, state.delta_time);
                    },
                    .Rotate => {
                        state.camera.movement.processMovement(.rotate_left, state.delta_time);
                    },
                }
            },
            .r => {
                if (!state.input.key_processed.contains(.r)) {
                    state.camera.reset(state.camera_initial_position, state.camera_initial_target);
                }
            },
            .one => {
                if (!state.input.key_processed.contains(.one)) {
                    // state.camera.setLookTo();
                    std.debug.print("Look To\n", .{});
                }
            },
            .two => {
                if (!state.input.key_processed.contains(.two)) {
                    // state.camera.setLookAt();
                    std.debug.print("Look At\n", .{});
                }
            },
            .three => {
                if (!state.input.key_processed.contains(.three)) {
                    state.spin = !state.spin;
                }
            },
            .four => {
                if (!state.input.key_processed.contains(.four)) {
                    state.camera.setPerspective();
                    // state.projection = state.camera.getProjectionMatrix();
                }
            },
            .five => {
                if (!state.input.key_processed.contains(.five)) {
                    state.camera.setOrthographic();
                    // state.projection = state.camera.getProjectionMatrix();
                }
            },
            .zero => {
                if (!state.input.key_processed.contains(.zero)) {
                    state.animation_reset_requested = true;
                }
            },
            .equal => {
                if (!state.input.key_processed.contains(.equal)) {
                    state.animation_next_requested = true;
                }
            },
            .minus => {
                if (!state.input.key_processed.contains(.minus)) {
                    state.animation_prev_requested = true;
                }
            },
            .six => {
                if (!state.input.key_processed.contains(.six)) {
                    state.motion_type = .Translate;
                    std.debug.print("Motion Type: Translate\n", .{});
                }
            },
            .seven => {
                if (!state.input.key_processed.contains(.seven)) {
                    state.motion_type = .Orbit;
                    std.debug.print("Motion Type: Orbit\n", .{});
                }
            },
            .eight => {
                if (!state.input.key_processed.contains(.eight)) {
                    state.motion_type = .Circle;
                    std.debug.print("Motion Type: Circle\n", .{});
                }
            },
            .nine => {
                if (!state.input.key_processed.contains(.nine)) {
                    state.motion_type = .Rotate;
                    std.debug.print("Motion Type: Rotate\n", .{});
                }
            },
            .n => {
                if (!state.input.key_processed.contains(.n)) {
                    state.model_reload_requested = true;
                    state.model_index_increment = 1;
                }
            },
            .b => {
                if (!state.input.key_processed.contains(.b)) {
                    state.model_reload_requested = true;
                    state.model_index_increment = -1;
                }
            },
            .f => {
                if (!state.input.key_processed.contains(.f)) {
                    frameToFit();
                }
            },
            .p => {
                if (!state.input.key_processed.contains(.p)) {
                    state.output_position_requested = true;
                }
            },
            .h => {
                if (!state.input.key_processed.contains(.h)) {
                    state.ui_help_visible = !state.ui_help_visible;
                    std.debug.print("Help display: {}\n", .{state.ui_help_visible});
                }
            },
            .c => {
                if (!state.input.key_processed.contains(.c)) {
                    state.ui_camera_info_visible = !state.ui_camera_info_visible;
                    std.debug.print("Camera info display: {}\n", .{state.ui_camera_info_visible});
                }
            },
            .e => {
                if (!state.input.key_processed.contains(.e)) {
                    state.fade_grazing_specular = !state.fade_grazing_specular;
                    std.debug.print("Fade grazing specular: {}\n", .{state.fade_grazing_specular});
                }
            },
            .g => {
                if (!state.input.key_processed.contains(.g)) {
                    state.shader_debug_enabled = !state.shader_debug_enabled;
                    std.debug.print("Shader debug: {}\n", .{state.shader_debug_enabled});
                }
            },
            .u => {
                if (!state.input.key_processed.contains(.u)) {
                    state.shader_debug_dump_requested = true;
                }
            },
            .F12 => {
                if (!state.input.key_processed.contains(.F12)) {
                    state.screenshot_requested = true;
                    std.debug.print("Screenshot requested (F12)\n", .{});
                }
            },
            .space => {
                if (!state.input.key_processed.contains(.space)) {
                    state.run_animation = !state.run_animation;
                    std.debug.print("Camera reposition requested\n", .{});
                }
            },
            else => {},
        }

        // Mark this key as processed for this frame
        state.input.key_processed.insert(k);
    }
}

pub fn frameToFit() void {
    state.camera_reposition_requested = true;
    std.debug.print("Frame to fit requested\n", .{});
}

pub fn getCurrentModelInfo() assets_list.ModelInfo {
    return assets_list.model_infos[@intCast(state.current_model_index)];
}

/// The surface follows the framebuffer size in `GpuContext.beginFrame`; this keeps the
/// camera aspect and mouse bounds current.
pub fn framebufferSizeHandler(window: *glfw.Window, width: i32, height: i32) callconv(.c) void {
    _ = window;
    setViewPort(width, height);
}

pub fn setViewPort(w: i32, h: i32) void {
    const width: f32 = @floatFromInt(w);
    const height: f32 = @floatFromInt(h);

    state.viewport_width = width;
    state.viewport_height = height;
    state.scaled_width = width / state.window_scale[0];
    state.scaled_height = height / state.window_scale[1];

    state.camera.setScreenDimensions(state.scaled_width, state.scaled_height);
}

pub fn mouseHandler(window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    _ = window;
    _ = mods;

    state.input.mouse_left_button = action == .press and button == glfw.MouseButton.left;
    state.input.mouse_right_button = action == .press and button == glfw.MouseButton.right;
}

pub fn cursorPositionHandler(window: *glfw.Window, xposIn: f64, yposIn: f64) callconv(.c) void {
    _ = window;
    var xpos: f32 = @floatCast(xposIn);
    var ypos: f32 = @floatCast(yposIn);

    xpos = if (xpos < 0) 0 else if (xpos < state.scaled_width) xpos else state.scaled_width;
    ypos = if (ypos < 0) 0 else if (ypos < state.scaled_height) ypos else state.scaled_height;

    if (state.input.first_mouse) {
        state.input.mouse_x = xpos;
        state.input.mouse_y = ypos;
        state.input.first_mouse = false;
    }

    const xoffset = xpos - state.input.mouse_x;
    const yoffset = state.input.mouse_y - ypos; // reversed since y-coordinates go from bottom to top

    state.input.mouse_x = xpos;
    state.input.mouse_y = ypos;

    _ = xoffset;
    _ = yoffset;
}

pub fn scrollHandler(window: *Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = window;
    _ = xoffset;
    state.camera.adjustFov(@floatCast(yoffset));
}
