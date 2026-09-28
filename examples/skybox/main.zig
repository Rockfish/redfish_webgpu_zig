const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;

const ArenaAllocator = std.heap.ArenaAllocator;

const Context = core.Context;
const DrawUniforms = core.DrawUniforms;
const GpuContext = core.GpuContext;
const Input = core.Input;
const Camera = core.Camera;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Skybox = core.shapes.Skybox;
const Texture = core.texture.Texture;
const srgbToLinear = core.colors.srgbToLinear;

const Window = glfw.Window;

const SCR_WIDTH: f32 = 1000.0;
const SCR_HEIGHT: f32 = 1000.0;

/// redfish's GL clear color, converted so it looks the same on the sRGB surface.
const CLEAR_COLOR = [4]f64{ srgbToLinear(0.1), srgbToLinear(0.1), srgbToLinear(0.1), 1.0 };

const State = struct {
    camera: *Camera,
    input: *Input,
    delta_time: f32,
    last_frame: f32,
};

var state: State = undefined;

pub fn main(init: std.process.Init) !void {
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.client_api, .no_api);
    const window = try glfw.Window.create(
        SCR_WIDTH,
        SCR_HEIGHT,
        "Skybox",
        null,
        null,
    );
    defer window.destroy();

    var gpu = try GpuContext.init(init.gpa, window);
    defer gpu.deinit();

    try run(init, window, &gpu);
}

/// redfish installed its own key, cursor, and scroll callbacks here, but `Input.init`
/// replaced them, so only Input's (keys, escape) ever ran; the port keeps just those.
pub fn run(init: std.process.Init, window: *glfw.Window, gpu: *GpuContext) !void {
    var alloc_arena = ArenaAllocator.init(init.gpa);
    var temp_alloc_arena = ArenaAllocator.init(init.gpa);
    defer alloc_arena.deinit();
    defer temp_alloc_arena.deinit();

    const context = Context{
        .alloc = alloc_arena.allocator(),
        .temp_alloc = temp_alloc_arena.allocator(),
        .io = init.io,
    };

    const window_size = window.getSize();
    const scaled_width: f32 = @floatFromInt(window_size[0]);
    const scaled_height: f32 = @floatFromInt(window_size[1]);

    const camera = try Camera.init(
        context.alloc,
        .{
            .position = vec3(0.0, 0.0, 3.0),
            .target = vec3(0.0, 0.0, 0.0),
            .scr_width = scaled_width,
            .scr_height = scaled_height,
        },
    );
    defer camera.deinit();

    state = State{
        .camera = camera,
        .input = Input.init(window),
        .delta_time = 0.0,
        .last_frame = 0.0,
    };

    const basic_shader = try Shader.init(
        context.io,
        context.alloc,
        gpu,
        "examples/skybox/shaders/basic.wgsl",
        .{ .vertex_buffers = &Shape.vertex_buffer_layouts, .material = .texture },
    );
    defer basic_shader.releaseGpuObjects();

    const cubemap_texture = try Texture.initFromFile(
        context,
        gpu,
        "assets/Textures/cubemap_template_2x3.png",
        .{
            .flip_v = false,
            .filter = .Linear,
            .wrap = .Clamp,
        },
    );
    defer cubemap_texture.releaseGpuObjects();

    const cube = try core.shapes.createCube(context.alloc, gpu, .{
        .width = 1.0,
        .height = 1.0,
        .depth = 1.0,
        .num_tiles_x = 1.0,
        .num_tiles_y = 1.0,
        .num_tiles_z = 1.0,
        .texture_mapping = .Cubemap2x3,
    });
    defer cube.releaseGpuObjects();

    var skybox = try Skybox.init(context.io, context.alloc, gpu, .{
        .right = "assets/textures/skybox/right.jpg",
        .left = "assets/textures/skybox/left.jpg",
        .top = "assets/textures/skybox/top.jpg",
        .bottom = "assets/textures/skybox/bottom.jpg",
        .forward = "assets/textures/skybox/front.jpg",
        .back = "assets/textures/skybox/back.jpg",
        .mirrored = false, // this example's own loader: standard order, no flip
    });
    defer skybox.releaseGpuObjects();

    // draw loop
    // -----------
    while (!window.shouldClose()) {
        glfw.pollEvents();

        const currentFrame: f32 = @floatCast(glfw.getTime());
        state.delta_time = currentFrame - state.last_frame;
        state.last_frame = currentFrame;

        processKeys();

        const frame = gpu.beginFrame(CLEAR_COLOR) orelse continue;
        gpu.writeFrameUniforms(camera.getRenderContext(currentFrame).frameUniforms());

        cubemap_texture.bind(&frame);
        cube.draw(&frame, basic_shader, DrawUniforms.init(Mat4.Identity, vec4(1.0, 1.0, 1.0, 1.0)));

        skybox.draw(&frame);

        gpu.endFrame(frame);
    }
}

pub fn processKeys() void {
    var iterator = state.input.key_presses.iterator();
    while (iterator.next()) |k| {
        switch (k) {
            .t => std.debug.print("time: {d}\n", .{state.delta_time}),
            .w => state.camera.movement.processMovement(.forward, state.delta_time),
            .s => state.camera.movement.processMovement(.backward, state.delta_time),
            .a => state.camera.movement.processMovement(.left, state.delta_time),
            .d => state.camera.movement.processMovement(.right, state.delta_time),
            .up => state.camera.movement.processMovement(.circle_up, state.delta_time),
            .down => state.camera.movement.processMovement(.circle_down, state.delta_time),
            .left => state.camera.movement.processMovement(.circle_left, state.delta_time),
            .right => state.camera.movement.processMovement(.circle_right, state.delta_time),
            else => {},
        }
    }
}
