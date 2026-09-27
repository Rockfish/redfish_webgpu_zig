//! Per-draw data check for the uniform ring (port Step 3a). Draws one shape many times
//! per frame, each with its own model matrix and color. Colors run red along X and blue
//! along Z, so a smooth gradient means every draw saw its own `DrawUniforms`; one color
//! or one position everywhere means a write-between-draws bug. The shape selector covers
//! every generator, so winding and normals get checked with culling on.

const std = @import("std");
const core = @import("core");
const math = @import("math");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const Arenas = core.Arenas;
const Camera = core.Camera;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const gui = core.gui;
const Mat4 = math.Mat4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const log = std.log.scoped(.draw_test);

const CLEAR_COLOR = [4]f64{ 0.1, 0.1, 0.12, 1.0 };
const SPACING: f32 = 1.6;

const ShapeKind = enum(i32) { cube, sphere, cylinder, square, plane, barrel_obj };

const Settings = struct {
    shape: ShapeKind = .cube,
    grid_size: i32 = 20,
    spin: bool = true,
    transparent: bool = false,
    double_sided: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const window = try zglfw.Window.create(1280, 800, "draw_test", null, null);
    defer window.destroy();

    var gpu = try GpuContext.init(allocator, window);
    defer gpu.deinit();

    const shader = try Shader.init(init.io, allocator, &gpu, "examples/draw_test/shaders/basic_shape.wgsl", &Shape.vertex_buffer_layouts, .none);
    defer {
        shader.releaseGpuObjects();
        allocator.destroy(shader);
    }

    var arenas = try Arenas.init(allocator);
    defer arenas.deinit();
    const context = arenas.context(init.io);

    var shapes = try createShapes(context, &gpu);
    defer for (&shapes) |shape| shape.releaseGpuObjects();

    const camera = try Camera.init(allocator, .{
        .position = vec3(0.0, 30.0, 45.0),
        .scr_width = @floatFromInt(gpu.width),
        .scr_height = @floatFromInt(gpu.height),
    });
    defer camera.deinit();

    gui.init(allocator, window, &gpu);
    defer gui.deinit();

    var settings: Settings = .{ .shape = try shapeFromArgs(init) };

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        if (window.getKey(.escape) == .press) window.setShouldClose(true);

        const frame = gpu.beginFrame(CLEAR_COLOR) orelse continue;
        const time: f32 = @floatCast(zglfw.getTime());

        camera.setScreenDimensions(@floatFromInt(gpu.width), @floatFromInt(gpu.height));
        gpu.writeFrameUniforms(camera.getRenderContext(time).frameUniforms());

        const shape = shapes[@intCast(@intFromEnum(settings.shape))];
        shape.is_transparent = settings.transparent;
        shape.is_depth_write = !settings.transparent;
        shape.is_double_sided = settings.double_sided;
        drawGrid(&frame, shader, shape, settings, time);

        gui.newFrame();
        drawPanel(&gpu, &settings);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

/// Optional first argument picks the starting shape: `zig build draw_test-run -- sphere`.
fn shapeFromArgs(init: std.process.Init) !ShapeKind {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return .cube;
    return std.meta.stringToEnum(ShapeKind, args[1]) orelse {
        log.err("unknown shape '{s}'", .{args[1]});
        return error.UnknownShape;
    };
}

/// One of each generator, indexed by `ShapeKind`.
fn createShapes(context: core.Context, gpu: *GpuContext) ![@typeInfo(ShapeKind).@"enum".fields.len]*Shape {
    const plane = try core.shapes.Plane.init(context, gpu, .{ .plane_size = 1.2 });
    return .{
        try core.shapes.createCube(context.alloc, gpu, .{}),
        try core.shapes.createSphere(context.alloc, gpu, 0.6, 20, 20),
        try core.shapes.createCylinder(context.alloc, gpu, 1.2, 1.2, 20),
        try core.shapes.createSquare(context.alloc, gpu),
        plane.shape,
        try core.shapes.loadOBJ(context.io, context.alloc, gpu, "assets/modular_ruins/OBJ/Barrel.obj"),
    };
}

fn drawGrid(frame: *const Frame, shader: *const Shader, shape: *const Shape, settings: Settings, time: f32) void {
    const n: usize = @intCast(settings.grid_size);
    const extent = shape.aabb.max.sub(shape.aabb.min);
    const fit_scale = 1.2 / @max(extent.x, extent.y, extent.z);
    const half_extent = @as(f32, @floatFromInt(n - 1)) * SPACING / 2.0;
    const alpha: f32 = if (settings.transparent) 0.5 else 1.0;

    for (0..n) |ix| {
        for (0..n) |iz| {
            const fx: f32 = @floatFromInt(ix);
            const fz: f32 = @floatFromInt(iz);
            const u = if (n > 1) fx / @as(f32, @floatFromInt(n - 1)) else 0.5;
            const v = if (n > 1) fz / @as(f32, @floatFromInt(n - 1)) else 0.5;

            const position = vec3(fx * SPACING - half_extent, 0.0, fz * SPACING - half_extent);
            const angle = if (settings.spin) time * (0.5 + u + v) else 0.0;
            const rotation = Mat4.fromAxisAngle(vec3(u, 1.0, v).toNormalized(), angle);
            const model = Mat4.fromTranslation(position).mulMat4(&rotation).mulMat4(&Mat4.fromScale(vec3(fit_scale, fit_scale, fit_scale)));

            var draw_uniforms = DrawUniforms.init(model, vec4(u, 0.35, v, alpha));
            if (shape.has_vertex_colors) draw_uniforms.flags |= core.bindings.DrawFlags.vertex_color;
            shape.draw(frame, shader, draw_uniforms);
        }
    }
}

fn drawPanel(gpu: *const GpuContext, settings: *Settings) void {
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    if (zgui.begin("draw_test", .{})) {
        const draws = settings.grid_size * settings.grid_size;
        zgui.text("draws: {d}  ring: {d} KiB", .{ draws, gpu.uniform_ring.used / 1024 });
        zgui.text("frame time: {d:.2} ms", .{1000.0 / zgui.io.getFramerate()});
        _ = zgui.comboFromEnum("shape", &settings.shape);
        _ = zgui.sliderInt("grid size", .{ .v = &settings.grid_size, .min = 1, .max = 100 });
        _ = zgui.checkbox("spin", .{ .v = &settings.spin });
        _ = zgui.checkbox("transparent", .{ .v = &settings.transparent });
        _ = zgui.checkbox("double sided", .{ .v = &settings.double_sided });
    }
    zgui.end();
}
