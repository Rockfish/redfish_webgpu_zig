const std = @import("std");
const glfw = @import("zglfw");
const zgui = @import("zgui");
const math = @import("math");

const EnumSet = std.EnumSet;
const Vec2 = math.Vec2;
const vec2 = math.vec2;

const log = std.log.scoped(.input);

/// Gamepad mappings newer than GLFW's built-in ones (see the file's header).
const gamepad_mappings = @embedFile("gamecontrollerdb_macos.txt");

const XY = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

pub var input: Input = .{};

/// The first connected gamepad, read each frame by `Input.update` through GLFW's gamepad
/// API (standard layout from SDL's GameControllerDB mappings, which GLFW includes: Xbox
/// names, so `.a` is the bottom face button, cross on a PlayStation pad).
pub const GamepadInput = struct {
    is_connected: bool = false,
    /// Shaped by the dead zone and response curve (`shapeStick`): length 0 to 1, +y up.
    left_stick: Vec2 = vec2(0.0, 0.0),
    right_stick: Vec2 = vec2(0.0, 0.0),
    /// 0 released to 1 fully pulled.
    left_trigger: f32 = 0.0,
    right_trigger: f32 = 0.0,
    buttons: EnumSet(GamepadButton) = EnumSet(GamepadButton).initEmpty(),
    /// Buttons `buttonPressedOnce` has seen, until they're released.
    buttons_processed: EnumSet(GamepadButton) = EnumSet(GamepadButton).initEmpty(),
    /// Set once a joystick without a gamepad mapping has been reported, so it's logged
    /// only once.
    has_reported_unmapped: bool = false,
};

pub const GamepadButton = glfw.Gamepad.Button;

/// Keyboard, mouse, and window state from GLFW callbacks, read once per frame by an app's
/// update. Keys:
///
/// - `isDown(key)` while a key is held: movement, aiming.
/// - `pressedOnce(key)` once per press: toggles, firing, mode switches. It marks the key
///   processed, so a later handler in the same frame (or the same one next frame) sees it
///   as used; it resets when the key is released. Handlers that run first get the key:
///   an app runs its mode's handler before its global keys.
///
/// Escape doesn't close the window here; each app decides what Escape does.
///
/// With ImGui: call `Input.init` before `gui.init`, so ImGui's GLFW backend chains to these
/// callbacks. While ImGui wants the keyboard (a text field has focus) `isDown` and
/// `pressedOnce` see no keys; while it wants the mouse (the pointer is over a panel)
/// `isMouseDown` sees no buttons and the frame's scroll is zero.
pub const Input = struct {
    window_width: f32 = 0.0,
    window_height: f32 = 0.0,
    framebuffer_width: f32 = 0.0, // pixels (window * scale)
    framebuffer_height: f32 = 0.0, // pixels (window * scale)
    window_scale: [2]f32 = [_]f32{ 0.0, 0.0 },
    view_changed: bool = false,
    delta_time: f32 = 0.0,
    total_time: f32 = 0.0,
    start_time: f32 = 0.0,
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    mouse_right_button: bool = false,
    mouse_left_button: bool = false,
    /// This frame's scroll, set by `update`.
    scroll_xoffset: f32 = 0.0,
    scroll_yoffset: f32 = 0.0,
    /// Scroll since the last `update`, from the callback.
    pending_scroll: XY = .{},
    key_presses: EnumSet(glfw.Key) = EnumSet(glfw.Key).initEmpty(),
    key_processed: EnumSet(glfw.Key) = EnumSet(glfw.Key).initEmpty(),
    /// Either Shift key held.
    key_shift: bool = false,
    /// Either Alt key held.
    key_alt: bool = false,
    screen: bool = false,
    scroll: bool = false,
    scroll_xy: XY = .{},
    cursor: bool = false,
    cursor_xy: XY = .{},

    gamepad: GamepadInput = .{},
    /// Stick travel ignored around the center, as a fraction of full travel: worn sticks
    /// rest a little off center.
    stick_dead_zone: f32 = 0.15,
    /// Response curve past the dead zone: 1 is linear; higher gives finer control near the
    /// center.
    stick_exponent: f32 = 1.5,

    /// Set by `update` from ImGui, when there is an ImGui context.
    gui_has_keyboard: bool = false,
    gui_has_mouse: bool = false,

    /// Incremented on structural changes (resize, scroll) that consumers
    /// like cameras need to react to. Not incremented by mouse or key input.
    update_tick: u64 = 0,

    const Self = @This();

    pub fn init(window: *glfw.Window) *Input {
        const window_size = window.getSize();
        const window_scale = window.getContentScale();
        const window_width = @as(f32, @floatFromInt(window_size[0]));
        const window_height = @as(f32, @floatFromInt(window_size[1]));
        const framebuffer_width = window_width * window_scale[0];
        const framebuffer_height = window_height * window_scale[1];

        initWindowHandlers(window);
        if (!glfw.updateGamepadMappings(gamepad_mappings)) {
            log.warn("gamepad mappings not loaded; only GLFW's built-in ones apply", .{});
        }

        glfw.setTime(0.0);
        input.window_width = window_width;
        input.window_height = window_height;
        input.framebuffer_width = framebuffer_width;
        input.framebuffer_height = framebuffer_height;
        input.window_scale = window_scale;
        input.mouse_x = window_width * 0.5;
        input.mouse_y = window_height * 0.5;
        return &input;
    }

    /// Once per frame, after `glfw.pollEvents`: the frame's time, whether ImGui wants the
    /// keyboard or mouse, and the frame's scroll.
    pub fn update(self: *Self) void {
        const current_time: f32 = @floatCast(glfw.getTime());
        self.delta_time = current_time - self.total_time;
        self.total_time = current_time;

        const has_gui = zgui.getCurrentContext() != null;
        self.gui_has_keyboard = has_gui and zgui.io.getWantCaptureKeyboard();
        self.gui_has_mouse = has_gui and zgui.io.getWantCaptureMouse();

        const scroll = if (self.gui_has_mouse) XY{} else self.pending_scroll;
        self.scroll_xoffset = scroll.x;
        self.scroll_yoffset = scroll.y;
        self.pending_scroll = .{};

        self.pollGamepad();
    }

    /// True while `button` on the gamepad is held.
    pub fn isButtonDown(self: *const Self, button: GamepadButton) bool {
        return self.gamepad.buttons.contains(button);
    }

    /// True once per press of `button`, as `pressedOnce` for keys.
    pub fn buttonPressedOnce(self: *Self, button: GamepadButton) bool {
        if (!self.isButtonDown(button) or self.gamepad.buttons_processed.contains(button)) {
            return false;
        }
        self.gamepad.buttons_processed.insert(button);
        return true;
    }

    /// True while `key` is held (and ImGui doesn't want the keyboard).
    pub fn isDown(self: *const Self, key: glfw.Key) bool {
        return !self.gui_has_keyboard and self.key_presses.contains(key);
    }

    /// True once per press of `key`: the first time it's asked while the key is held. Marks
    /// the key processed until it's released. False while ImGui wants the keyboard.
    pub fn pressedOnce(self: *Self, key: glfw.Key) bool {
        if (!self.isDown(key) or self.key_processed.contains(key)) {
            return false;
        }
        self.key_processed.insert(key);
        return true;
    }

    /// True while `button` is held (and ImGui doesn't want the mouse).
    pub fn isMouseDown(self: *const Self, button: glfw.MouseButton) bool {
        if (self.gui_has_mouse) {
            return false;
        }
        return switch (button) {
            .left => self.mouse_left_button,
            .right => self.mouse_right_button,
            else => false,
        };
    }

    /// Reads the first joystick GLFW recognizes as a gamepad; none leaves everything at rest.
    fn pollGamepad(self: *Self) void {
        const pad = &self.gamepad;
        const state = firstGamepadState() orelse {
            const has_reported = pad.has_reported_unmapped or reportUnmappedJoystick();
            pad.* = .{ .has_reported_unmapped = has_reported };
            return;
        };

        const axes = state.axes;
        const Axis = glfw.Gamepad.Axis;
        // GLFW's stick y is +1 down; flip it so up is +y
        pad.left_stick = shapeStick(axes[@intFromEnum(Axis.left_x)], -axes[@intFromEnum(Axis.left_y)], self.stick_dead_zone, self.stick_exponent);
        pad.right_stick = shapeStick(axes[@intFromEnum(Axis.right_x)], -axes[@intFromEnum(Axis.right_y)], self.stick_dead_zone, self.stick_exponent);
        // Triggers go from -1 released to +1 pulled
        pad.left_trigger = (axes[@intFromEnum(Axis.left_trigger)] + 1.0) * 0.5;
        pad.right_trigger = (axes[@intFromEnum(Axis.right_trigger)] + 1.0) * 0.5;

        pad.is_connected = true;
        for (state.buttons, 0..) |action, i| {
            const button: GamepadButton = @enumFromInt(i);
            if (action == .press) {
                pad.buttons.insert(button);
            } else {
                pad.buttons.remove(button);
                pad.buttons_processed.remove(button);
            }
        }
    }

    pub fn handleKey(self: *Self, key: glfw.Key, action: glfw.Action) void {
        switch (action) {
            .press => self.key_presses.insert(key),
            .release => {
                self.key_presses.remove(key);
                self.key_processed.remove(key);
            },
            else => {},
        }

        // From the held keys: GLFW's mods on a key event can lag the modifier's own press
        const keys = self.key_presses;
        self.key_shift = keys.contains(.left_shift) or keys.contains(.right_shift);
        self.key_alt = keys.contains(.left_alt) or keys.contains(.right_alt);
    }
};

/// A stick's raw position (each axis -1 to 1) shaped for control: nothing inside the
/// dead zone, then the remaining travel stretched to 0..1 and bent by `exponent`, the
/// direction kept (a radial dead zone, so diagonals aren't clipped). Length at most 1.
pub fn shapeStick(x: f32, y: f32, dead_zone: f32, exponent: f32) Vec2 {
    const length = @sqrt(x * x + y * y);
    if (length <= dead_zone) {
        return vec2(0.0, 0.0);
    }
    const travel = @min((length - dead_zone) / (1.0 - dead_zone), 1.0);
    const scale = std.math.pow(f32, travel, exponent) / length;
    return vec2(x * scale, y * scale);
}

fn firstGamepadState() ?glfw.Gamepad.State {
    for (0..glfw.Joystick.maximum_supported) |id| {
        const joystick: glfw.Joystick = @enumFromInt(id);
        const gamepad = joystick.asGamepad() orelse continue;
        return gamepad.getState() catch continue;
    }
    return null;
}

/// Logs the first joystick that isn't a gamepad (GLFW has no mapping for it): it's
/// connected but `Input` can't read it. True if there was one.
fn reportUnmappedJoystick() bool {
    for (0..glfw.Joystick.maximum_supported) |id| {
        const joystick: glfw.Joystick = @enumFromInt(id);
        if (!joystick.isPresent()) {
            continue;
        }
        const guid: []const u8 = joystick.getGuid() catch "?";
        log.warn("joystick {d} (GUID {s}) has no gamepad mapping; add its SDL_GameControllerDB line to gamecontrollerdb_macos.txt", .{ id, guid });
        return true;
    }
    return false;
}

fn initWindowHandlers(window: *glfw.Window) void {
    _ = window.setKeyCallback(keyHandler);
    _ = window.setFramebufferSizeCallback(framebufferSizeHandler);
    _ = window.setCursorPosCallback(cursorPositionHandler);
    _ = window.setScrollCallback(scrollHandler);
    _ = window.setMouseButtonCallback(mouseHandler);
}

fn keyHandler(window: *glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    _ = window;
    _ = scancode;
    _ = mods;
    input.handleKey(key, action);
}

/// The surface and depth texture follow the size in `GpuContext.beginFrame`; this only
/// keeps the sizes here current for apps and cameras.
fn framebufferSizeHandler(window: *glfw.Window, width: i32, height: i32) callconv(.c) void {
    _ = window;
    setViewPort(width, height);
}

fn setViewPort(w: i32, h: i32) void {
    const width: f32 = @floatFromInt(w);
    const height: f32 = @floatFromInt(h);

    input.framebuffer_width = width;
    input.framebuffer_height = height;
    input.window_width = width / input.window_scale[0];
    input.window_height = height / input.window_scale[1];
    input.update_tick +%= 1;
}

/// Each event changes only its own button, so releasing one leaves another held.
fn mouseHandler(window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    _ = window;
    _ = mods;

    const is_pressed = action == .press;
    switch (button) {
        .left => input.mouse_left_button = is_pressed,
        .right => input.mouse_right_button = is_pressed,
        else => {},
    }
}

fn cursorPositionHandler(window: *glfw.Window, xposIn: f64, yposIn: f64) callconv(.c) void {
    _ = window;
    var xpos: f32 = @floatCast(xposIn);
    var ypos: f32 = @floatCast(yposIn);

    xpos = if (xpos < 0) 0 else if (xpos < input.window_width) xpos else input.window_width;
    ypos = if (ypos < 0) 0 else if (ypos < input.window_height) ypos else input.window_height;

    input.mouse_x = xpos;
    input.mouse_y = ypos;
}

fn scrollHandler(window: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = window;
    // Several scroll events in one frame add up; `update` hands them out
    input.pending_scroll.x += @floatCast(xoffset);
    input.pending_scroll.y += @floatCast(yoffset);
    input.update_tick +%= 1;
}

test "pressedOnce: once per press, again after a release; isDown while held" {
    var state: Input = .{};
    state.handleKey(.r, .press);
    try std.testing.expect(state.isDown(.r));
    try std.testing.expect(state.pressedOnce(.r));
    // Held: still down, but already used
    try std.testing.expect(state.isDown(.r));
    try std.testing.expect(!state.pressedOnce(.r));

    state.handleKey(.r, .release);
    try std.testing.expect(!state.isDown(.r));
    try std.testing.expect(!state.pressedOnce(.r));

    state.handleKey(.r, .press);
    try std.testing.expect(state.pressedOnce(.r));
}

test "handleKey: Shift and Alt follow either side's key" {
    var state: Input = .{};
    state.handleKey(.right_shift, .press);
    try std.testing.expect(state.key_shift and !state.key_alt);
    state.handleKey(.left_alt, .press);
    state.handleKey(.right_shift, .release);
    try std.testing.expect(!state.key_shift and state.key_alt);
}

test "mouse buttons: releasing one leaves the other held" {
    const saved = input;
    defer input = saved;
    input = .{};

    const window: *glfw.Window = undefined;
    mouseHandler(window, .left, .press, .{});
    mouseHandler(window, .right, .press, .{});
    mouseHandler(window, .right, .release, .{});
    try std.testing.expect(input.mouse_left_button and !input.mouse_right_button);
}

test "while ImGui wants the keyboard, keys are neither down nor pressed" {
    var state: Input = .{};
    state.handleKey(.space, .press);
    state.gui_has_keyboard = true;
    try std.testing.expect(!state.isDown(.space));
    try std.testing.expect(!state.pressedOnce(.space));

    // Still held when ImGui lets go: the press counts then
    state.gui_has_keyboard = false;
    try std.testing.expect(state.pressedOnce(.space));
}

test "shapeStick: still in the dead zone, full at the edge, direction kept" {
    const dead_zone: f32 = 0.15;
    const at_rest = shapeStick(0.1, -0.05, dead_zone, 1.5);
    try std.testing.expectEqual(@as(f32, 0.0), at_rest.x);
    try std.testing.expectEqual(@as(f32, 0.0), at_rest.y);

    const full = shapeStick(0.0, 1.0, dead_zone, 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), full.y, 1e-5);

    // A corner past full travel is clamped to length 1, still diagonal
    const corner = shapeStick(1.0, 1.0, dead_zone, 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(corner.lengthSquared()), 1e-5);
    try std.testing.expectApproxEqAbs(corner.x, corner.y, 1e-6);

    // Halfway out of the dead zone gives less than half (the curve), more than nothing
    const half = shapeStick(dead_zone + (1.0 - dead_zone) * 0.5, 0.0, dead_zone, 1.5);
    try std.testing.expect(half.x > 0.2 and half.x < 0.5);
}

test "buttonPressedOnce: once per press, as keys" {
    var state: Input = .{};
    state.gamepad.buttons.insert(.a);
    try std.testing.expect(state.isButtonDown(.a));
    try std.testing.expect(state.buttonPressedOnce(.a));
    try std.testing.expect(!state.buttonPressedOnce(.a));
}
