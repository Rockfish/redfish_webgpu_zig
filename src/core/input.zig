const std = @import("std");
const glfw = @import("zglfw");

const EnumSet = std.EnumSet;

const XY = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

pub var input: Input = .{};

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

    /// Once per frame, after `glfw.pollEvents`: the frame's time and scroll.
    pub fn update(self: *Self) void {
        const current_time: f32 = @floatCast(glfw.getTime());
        self.delta_time = current_time - self.total_time;
        self.total_time = current_time;

        self.scroll_xoffset = self.pending_scroll.x;
        self.scroll_yoffset = self.pending_scroll.y;
        self.pending_scroll = .{};
    }

    /// True while `key` is held.
    pub fn isDown(self: *const Self, key: glfw.Key) bool {
        return self.key_presses.contains(key);
    }

    /// True once per press of `key`: the first time it's asked while the key is held. Marks
    /// the key processed until it's released.
    pub fn pressedOnce(self: *Self, key: glfw.Key) bool {
        if (!self.key_presses.contains(key) or self.key_processed.contains(key)) {
            return false;
        }
        self.key_processed.insert(key);
        return true;
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
        self.key_shift = self.isDown(.left_shift) or self.isDown(.right_shift);
        self.key_alt = self.isDown(.left_alt) or self.isDown(.right_alt);
    }
};

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
