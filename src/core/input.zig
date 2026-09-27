const std = @import("std");
const glfw = @import("zglfw");

const EnumSet = std.EnumSet;

const XY = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

pub var input: Input = .{};

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
    scroll_xoffset: f32 = 0.0,
    scroll_yoffset: f32 = 0.0,
    key_presses: EnumSet(glfw.Key) = EnumSet(glfw.Key).initEmpty(),
    key_processed: EnumSet(glfw.Key) = EnumSet(glfw.Key).initEmpty(),
    key_shift: bool = false,
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

    pub fn update(self: *Self) void {
        const current_time: f32 = @floatCast(glfw.getTime());
        self.delta_time = current_time - self.total_time;
        self.total_time = current_time;
    }

    pub fn handleKey(self: *Self, key: glfw.Key, action: glfw.Action, mods: glfw.Mods) void {
        switch (action) {
            .press => self.key_presses.insert(key),
            .release => {
                self.key_presses.remove(key);
                self.key_processed.remove(key);
            },
            else => {},
        }

        self.key_shift = mods.shift;
        self.key_alt = mods.alt;
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
    _ = scancode;

    input.handleKey(key, action, mods);

    if (key == .escape) {
        window.setShouldClose(true);
    }
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

fn mouseHandler(window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    _ = window;
    _ = mods;

    input.mouse_left_button = action == .press and button == glfw.MouseButton.left;
    input.mouse_right_button = action == .press and button == glfw.MouseButton.right;
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
    input.scroll_xoffset = @floatCast(xoffset);
    input.scroll_yoffset = @floatCast(yoffset);
    input.update_tick +%= 1;
}
