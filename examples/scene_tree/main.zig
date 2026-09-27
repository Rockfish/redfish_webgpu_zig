const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");
const nodes_ = @import("nodes_interfaces.zig");
const run_interfaces = @import("run_interfaces.zig").run;
const Component = @import("component.zig").Component;

const Input = core.Input;
const GpuContext = core.GpuContext;

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Ray = core.Ray;

const Allocator = std.mem.Allocator;
const EnumSet = std.EnumSet;

const Node = nodes_.Node;
const Transform = core.Transform;
const Camera = core.Camera;

const Window = glfw.Window;

const SCR_WIDTH: f32 = 1000.0;
const SCR_HEIGHT: f32 = 1000.0;

const SIZE_OF_FLOAT = @sizeOf(f32);
const SIZE_OF_VEC3 = @sizeOf(Vec3);
const SIZE_OF_VEC4 = @sizeOf(Vec4);
const SIZE_OF_QUAT = @sizeOf(Quat);

pub const State = struct {
    viewport_width: f32,
    viewport_height: f32,
    scaled_width: f32,
    scaled_height: f32,
    window_scale: [2]f32,
    input: *Input,
    camera: *Camera,
    projection_type: core.ProjectionType,
    projection: Mat4,
    light_postion: Vec3,
    delta_time: f32,
    total_time: f32,
    spin: bool = false,
    world_point: ?Vec3,
    current_position: Vec3,
    target_position: Vec3,
};

pub var state: State = undefined;

pub fn main(init: std.process.Init) !void {
    var point1 = vec3(0.0, 2.0, 3.0);
    var point2 = vec3(4.0, 5.0, 6.0);

    const component1 = Component.init(Vec3, "foo", &point1);
    const component2 = Component.init(Vec3, "foo", &point2);

    std.debug.print("Component: {any}\n", .{component1});
    std.debug.print("Component: {any}\n", .{component2});

    const p1 = component1.cast(Vec3);
    const p2 = component2.cast(Vec3);

    std.debug.print("Component point: {any}\n", .{p1});
    std.debug.print("Component point: {any}\n", .{p2});

    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.client_api, .no_api);
    const window = try glfw.Window.create(
        SCR_WIDTH,
        SCR_HEIGHT,
        "Scene Tree",
        null,
        null,
    );
    defer window.destroy();

    var gpu = try GpuContext.init(init.gpa, window);
    defer gpu.deinit();

    try run_interfaces(init, window, &gpu);
}

pub fn processKeys() void {
    const toggle = struct {
        var spin_is_set: bool = false;
    };

    var iterator = state.input.key_presses.iterator();
    while (iterator.next()) |k| {
        switch (k) {
            .t => std.debug.print("time: {d}\n", .{state.delta_time}),
            .w => {
                if (state.input.key_shift) {
                    state.camera.processMovement(.forward, state.delta_time);
                } else {
                    state.camera.processMovement(.radius_in, state.delta_time);
                }
            },
            .s => {
                if (state.input.key_shift) {
                    state.camera.processMovement(.backward, state.delta_time);
                } else {
                    state.camera.processMovement(.radius_out, state.delta_time);
                }
            },
            .a => {
                if (state.input.key_shift) {
                    state.camera.processMovement(.left, state.delta_time);
                } else {
                    state.camera.processMovement(.orbit_left, state.delta_time);
                }
            },
            .d => {
                if (state.input.key_shift) {
                    state.camera.processMovement(.right, state.delta_time);
                } else {
                    state.camera.processMovement(.orbit_right, state.delta_time);
                }
            },
            .up => {
                if (state.input.key_shift) {
                    state.camera.processMovement(.up, state.delta_time);
                } else {
                    state.camera.processMovement(.orbit_up, state.delta_time);
                }
            },
            .down => {
                if (state.input.key_shift) {
                    state.camera.processMovement(.down, state.delta_time);
                } else {
                    state.camera.processMovement(.orbit_down, state.delta_time);
                }
            },
            // .one => {
            //     state.view_type = .LookTo;
            // },
            // .two => {
            //     state.view_type = .LookAt;
            // },
            .three => {
                if (!toggle.spin_is_set) {
                    state.spin = !state.spin;
                }
            },
            .four => {
                state.projection_type = .Perspective;
                state.projection = state.camera.getProjectionWithType(.Perspective);
            },
            .five => {
                state.projection_type = .Orthographic;
                state.projection = state.camera.getProjectionWithType(.Orthographic);
            },
            else => {},
        }
    }
    toggle.spin_is_set = state.input.key_presses.contains(.three);
}
