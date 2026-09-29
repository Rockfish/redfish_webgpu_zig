//! Shadow map test bed (plan 017). A floor with cubes, spheres, and a cylinder, some
//! tilted so there are sloped receivers, lit by one directional light that casts shadows
//! through `core.ShadowMap`.
//!
//! Each frame has two passes: the shadow pass draws every shape from the light into the
//! shadow map (the depth-only caster pipeline of shadow_scene.wgsl), then the window pass
//! draws them again from the camera, sampling the map. The panel moves the light and shows
//! the map itself: as an overlay, or by drawing the scene from the light.
//!
//! Keys: arrows circle the camera around the scene (world up and right, so the horizon
//! stays level), W / S move it in and out, Escape quits.

const std = @import("std");
const core = @import("core");
const math = @import("math");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const Arenas = core.Arenas;
const Camera = core.Camera;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const FrameUniforms = core.bindings.FrameUniforms;
const GpuContext = core.GpuContext;
const SceneLights = core.SceneLights;
const Shader = core.Shader;
const ShadowMap = core.ShadowMap;
const Shape = core.shapes.Shape;
const gui = core.gui;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const CLEAR_COLOR = [4]f64{ 0.05, 0.06, 0.08, 1.0 };
const SHADOW_MAP_SIZE: u32 = 2048;
/// Where the light looks and the camera circles.
const SCENE_CENTER = vec3(0.0, 0.0, 0.0);

const DebugView = enum(i32) { off, overlay, light_view };

/// Everything the panel changes.
const Settings = struct {
    /// Light direction as angles, in degrees. Elevation stops short of 90, where the
    /// light's view would have no defined up.
    light_azimuth: f32 = 35.0,
    light_elevation: f32 = 50.0,
    animate_light: bool = false,
    /// Half-width of the light's orthographic box, and its near / far planes, measured
    /// from the light's position `light_distance` back from the scene center.
    light_extent: f32 = 12.0,
    light_near: f32 = 1.0,
    light_far: f32 = 50.0,
    light_distance: f32 = 25.0,
    /// The defaults are the combination that showed no acne (plan 017, phase 2 notes):
    /// slope-scaled bias on the casters for sloped surfaces, plus a small bias on the
    /// receivers for PCF, whose outer samples land on texels deeper along the slope.
    /// Turn each off to see what it fixes.
    ///
    /// Subtracted from a receiver's depth before the shadow comparison (in the shader).
    shadow_bias: f32 = 0.0005,
    /// Depth bias on the caster pipelines (see `core.pipeline.DepthBias`).
    pipeline_bias: bool = true,
    bias_constant: i32 = 2,
    bias_slope_scale: f32 = 2.0,
    filter: ShadowMap.Filter = .linear,
    /// Comparison samples around each lookup: 0 is one sample, 1 a 3x3 grid, 2 a 5x5.
    pcf_radius: i32 = 1,
    debug_view: DebugView = .off,
    /// The depth range the overlay shows black to white.
    overlay_depth_min: f32 = 0.0,
    overlay_depth_max: f32 = 1.0,
    /// Overlay height as a fraction of the window height.
    overlay_size: f32 = 0.4,
};

/// Panel edits that need GPU objects rebuilt, applied before the next frame.
const Rebuild = struct {
    caster_shader: bool = false,
    shadow_map: bool = false,
};

/// One shape in the scene, with its placement and color.
const SceneObject = struct {
    shape: *Shape,
    model: Mat4,
    color: Vec4,
};

/// The light's matrices for one frame, from the panel's settings.
const LightView = struct {
    /// Direction the light travels, toward the scene.
    dir: Vec3,
    position: Vec3,
    view: Mat4,
    projection: Mat4,
    /// projection x view, for `FrameUniforms.light_space`.
    light_space: Mat4,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const window = try zglfw.Window.create(1280, 800, "shadows", null, null);
    defer window.destroy();

    var gpu = try GpuContext.init(allocator, window);
    defer gpu.deinit();

    var arenas = try Arenas.init(allocator);
    defer arenas.deinit();

    try run(allocator, arenas.context(init.io), window, &gpu);
}

/// `allocator` is for ImGui, which frees in any order; an arena would only reclaim its
/// last allocation, so the rest of ImGui's frees would never return memory.
fn run(allocator: std.mem.Allocator, context: core.Context, window: *zglfw.Window, gpu: *GpuContext) !void {
    const shape_layouts = &Shape.vertex_buffer_layouts;

    // Lit and shadow-receiving, for the window pass. The same file is also the shadow
    // pass's caster (`createCasterShader`).
    const scene_shader = try Shader.init(context.io, context.alloc, gpu, "examples/shadows/shaders/shadow_scene.wgsl", .{
        .vertex_buffers = shape_layouts,
        .pass = .shadow,
    });
    defer scene_shader.releaseGpuObjects();

    var settings: Settings = .{};

    var caster_shader = try createCasterShader(context, gpu, settings);
    defer caster_shader.releaseGpuObjects();

    const overlay_shader = try Shader.init(context.io, context.alloc, gpu, "examples/shadows/shaders/shadow_map_overlay.wgsl", .{
        .vertex_buffers = shape_layouts,
        .pass = .shadow,
    });
    defer overlay_shader.releaseGpuObjects();

    var shadow_map = ShadowMap.init(gpu, .{ .size = SHADOW_MAP_SIZE, .filter = settings.filter });
    defer shadow_map.releaseGpuObjects();

    // Drawn on top of everything, from either side
    const overlay_quad = try core.shapes.createSquare(context.alloc, gpu);
    defer overlay_quad.releaseGpuObjects();
    overlay_quad.is_double_sided = true;
    overlay_quad.is_depth_test = false;
    overlay_quad.is_depth_write = false;

    var shapes: SceneShapes = try .init(context, gpu);
    defer shapes.releaseGpuObjects();
    const objects = shapes.sceneObjects();

    const camera = try Camera.init(context.alloc, .{
        .position = vec3(14.0, 11.0, 16.0),
        .target = SCENE_CENTER,
        .scr_width = @floatFromInt(gpu.width),
        .scr_height = @floatFromInt(gpu.height),
    });

    gui.init(allocator, window, gpu);
    defer gui.deinit();

    var rebuild: Rebuild = .{};
    var last_time: f32 = @floatCast(zglfw.getTime());

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        if (window.getKey(.escape) == .press) {
            window.setShouldClose(true);
        }

        const time: f32 = @floatCast(zglfw.getTime());
        const delta_time = time - last_time;
        last_time = time;

        processKeys(window, camera, delta_time);

        // Depth bias is pipeline state and filtering is sampler state, both fixed when
        // created, so a change in the panel means new ones. Between frames, not while the
        // old ones are in use by commands still being recorded.
        if (rebuild.caster_shader) {
            caster_shader.releaseGpuObjects();
            caster_shader = try createCasterShader(context, gpu, settings);
        }
        if (rebuild.shadow_map) {
            shadow_map.releaseGpuObjects();
            shadow_map = ShadowMap.init(gpu, .{ .size = SHADOW_MAP_SIZE, .filter = settings.filter });
        }
        rebuild = .{};
        if (settings.animate_light) {
            settings.light_azimuth = @mod(settings.light_azimuth + 20.0 * delta_time, 360.0);
        }

        var frame = gpu.acquireFrame() orelse continue;

        camera.setScreenDimensions(@floatFromInt(gpu.width), @floatFromInt(gpu.height));
        const light = lightView(settings);
        gpu.writeFrameUniforms(frameUniforms(camera, light, settings, gpu, time));

        // Shadow pass: every shape from the light, depth only
        frame.beginPass(shadow_map.passTarget());
        drawObjects(&frame, caster_shader, &objects, settings);
        frame.endPass();

        // Window pass: every shape from the camera (or the light), sampling the map
        frame.beginSurfacePass(CLEAR_COLOR);
        shadow_map.bind(&frame);
        drawObjects(&frame, scene_shader, &objects, settings);
        if (settings.debug_view == .overlay) {
            drawOverlay(&frame, overlay_shader, overlay_quad, settings, gpu);
        }

        gui.newFrame();
        rebuild = drawPanel(&settings);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

/// The shadow pass's pipelines: shadow_scene.wgsl with `DEPTH_MODE`, depth only (no
/// fragment stage, no group 3), with the panel's depth bias when it's on.
fn createCasterShader(context: core.Context, gpu: *GpuContext, settings: Settings) !*Shader {
    const depth_bias: core.pipeline.DepthBias = if (settings.pipeline_bias)
        .{ .constant = settings.bias_constant, .slope_scale = settings.bias_slope_scale }
    else
        .{};
    return Shader.init(context.io, context.alloc, gpu, "examples/shadows/shaders/shadow_scene.wgsl", .{
        .vertex_buffers = &Shape.vertex_buffer_layouts,
        .color_target = .none,
        .constants = &.{.{ .key = "DEPTH_MODE", .value = 1.0 }},
        .depth_bias = depth_bias,
    });
}

/// The shapes, created once, and where each one goes.
const SceneShapes = struct {
    floor: *Shape,
    cube: *Shape,
    sphere: *Shape,
    cylinder: *Shape,

    fn init(context: core.Context, gpu: *const GpuContext) !SceneShapes {
        return .{
            .floor = try core.shapes.createCube(context.alloc, gpu, .{ .width = 24.0, .height = 0.2, .depth = 24.0 }),
            .cube = try core.shapes.createCube(context.alloc, gpu, .{}),
            .sphere = try core.shapes.createSphere(context.alloc, gpu, 1.0, 32, 32),
            .cylinder = try core.shapes.createCylinder(context.alloc, gpu, 1.0, 1.0, 32),
        };
    }

    /// Flat and sloped receivers, tall and small casters, a caster resting on another.
    fn sceneObjects(self: *const SceneShapes) [9]SceneObject {
        const floor_color = vec4(0.55, 0.55, 0.52, 1.0);
        const red = vec4(0.7, 0.2, 0.15, 1.0);
        const green = vec4(0.2, 0.55, 0.25, 1.0);
        const blue = vec4(0.2, 0.3, 0.7, 1.0);
        const gold = vec4(0.75, 0.6, 0.2, 1.0);
        const gray = vec4(0.6, 0.6, 0.65, 1.0);

        return .{
            .{ .shape = self.floor, .model = Mat4.fromTranslation(vec3(0.0, -0.1, 0.0)), .color = floor_color },
            .{ .shape = self.cube, .model = place(vec3(-3.0, 1.0, -2.0), vec3(2.0, 2.0, 2.0), vec3(0.0, 1.0, 0.0), 20.0), .color = red },
            .{ .shape = self.cube, .model = place(vec3(4.0, 3.0, -4.0), vec3(1.0, 6.0, 1.0), vec3(0.0, 1.0, 0.0), 0.0), .color = gray },
            // A slab tilted 30 degrees: a sloped receiver
            .{ .shape = self.cube, .model = place(vec3(3.5, 1.2, 3.0), vec3(5.0, 0.3, 3.0), vec3(0.0, 0.0, 1.0), 30.0), .color = gold },
            .{ .shape = self.cube, .model = place(vec3(-3.0, 2.5, -2.0), vec3(0.8, 0.8, 0.8), vec3(1.0, 1.0, 0.0), 45.0), .color = blue },
            .{ .shape = self.sphere, .model = place(vec3(0.0, 1.5, 2.0), vec3(1.5, 1.5, 1.5), vec3(0.0, 1.0, 0.0), 0.0), .color = green },
            .{ .shape = self.sphere, .model = place(vec3(-5.0, 0.6, 4.0), vec3(0.6, 0.6, 0.6), vec3(0.0, 1.0, 0.0), 0.0), .color = blue },
            .{ .shape = self.sphere, .model = place(vec3(3.5, 2.6, 3.0), vec3(0.5, 0.5, 0.5), vec3(0.0, 1.0, 0.0), 0.0), .color = red },
            .{ .shape = self.cylinder, .model = place(vec3(-6.0, 1.5, -5.0), vec3(1.0, 3.0, 1.0), vec3(0.0, 1.0, 0.0), 0.0), .color = gold },
        };
    }

    fn releaseGpuObjects(self: *SceneShapes) void {
        self.floor.releaseGpuObjects();
        self.cube.releaseGpuObjects();
        self.sphere.releaseGpuObjects();
        self.cylinder.releaseGpuObjects();
    }
};

/// Translation x rotation (degrees about `axis`) x scale.
fn place(position: Vec3, scale: Vec3, axis: Vec3, degrees: f32) Mat4 {
    const rotation = Mat4.fromAxisAngle(axis.toNormalized(), std.math.degreesToRadians(degrees));
    return Mat4.fromTranslation(position).mulMat4(&rotation).mulMat4(&Mat4.fromScale(scale));
}

fn processKeys(window: *zglfw.Window, camera: *Camera, delta_time: f32) void {
    if (zgui.io.getWantCaptureKeyboard()) {
        return;
    }
    const bindings = [_]struct { key: zglfw.Key, direction: core.MovementDirection }{
        .{ .key = .left, .direction = .circle_left },
        .{ .key = .right, .direction = .circle_right },
        .{ .key = .up, .direction = .circle_up },
        .{ .key = .down, .direction = .circle_down },
        .{ .key = .w, .direction = .radius_in },
        .{ .key = .s, .direction = .radius_out },
    };
    for (bindings) |binding| {
        if (window.getKey(binding.key) == .press) {
            camera.processMovement(binding.direction, delta_time);
        }
    }
}

fn lightView(settings: Settings) LightView {
    const azimuth = std.math.degreesToRadians(settings.light_azimuth);
    const elevation = std.math.degreesToRadians(settings.light_elevation);
    const toward_light = vec3(
        @cos(elevation) * @cos(azimuth),
        @sin(elevation),
        @cos(elevation) * @sin(azimuth),
    );
    const position = SCENE_CENTER.add(toward_light.mulScalar(settings.light_distance));
    const view = Mat4.lookAtRhGl(position, SCENE_CENTER, Vec3.World_Up);

    // Zero-to-one depth, as the shadow map stores it
    const e = settings.light_extent;
    const projection = Mat4.orthographicRhZo(-e, e, -e, e, settings.light_near, settings.light_far);

    return .{
        .dir = toward_light.mulScalar(-1.0),
        .position = position,
        .view = view,
        .projection = projection,
        .light_space = projection.mulMat4(&view),
    };
}

/// The frame's camera, light, and shadow matrix. In the light view the scene is drawn
/// from the light's position and direction, widened to the window's aspect so it isn't
/// stretched: the shadow map covers the middle square.
fn frameUniforms(camera: *Camera, light: LightView, settings: Settings, gpu: *const GpuContext, time: f32) FrameUniforms {
    var lights = SceneLights.init();
    lights.ambient = vec3(0.15, 0.15, 0.18);
    lights.direction_light = .{ .dir = light.dir, .color = vec3(1.0, 0.97, 0.9) };

    var uniforms = camera.getRenderContext(time).frameUniforms();
    if (settings.debug_view == .light_view) {
        const aspect = @as(f32, @floatFromInt(gpu.width)) / @as(f32, @floatFromInt(gpu.height));
        const e = settings.light_extent;
        const projection = Mat4.orthographicRhZo(-e * aspect, e * aspect, -e, e, settings.light_near, settings.light_far);
        uniforms.projection = projection;
        uniforms.view = light.view;
        uniforms.projection_view = projection.mulMat4(&light.view);
        uniforms.view_position = light.position;
    }
    uniforms.lights = lights.uniforms();
    uniforms.light_space = light.light_space;
    return uniforms;
}

fn drawObjects(frame: *const Frame, shader: *const Shader, objects: []const SceneObject, settings: Settings) void {
    const pcf_radius: f32 = @floatFromInt(settings.pcf_radius);
    for (objects) |object| {
        var draw_uniforms = DrawUniforms.init(object.model, object.color);
        draw_uniforms.params = vec4(settings.shadow_bias, pcf_radius, 0.0, 0.0);
        object.shape.draw(frame, shader, draw_uniforms);
    }
}

/// The shadow map as a square in the window's bottom-left corner. The unit square is
/// scaled and moved in clip space (-1..1), so its model matrix is the whole transform.
fn drawOverlay(frame: *const Frame, shader: *const Shader, quad: *const Shape, settings: Settings, gpu: *const GpuContext) void {
    const aspect = @as(f32, @floatFromInt(gpu.width)) / @as(f32, @floatFromInt(gpu.height));
    const height = 2.0 * settings.overlay_size;
    const width = height / aspect;
    const margin = 0.04;
    const center = vec3(-1.0 + margin + width / 2.0, -1.0 + margin * aspect + height / 2.0, 0.0);
    const model = Mat4.fromTranslation(center).mulMat4(&Mat4.fromScale(vec3(width, height, 1.0)));

    var draw_uniforms = DrawUniforms.init(model, vec4(1.0, 1.0, 1.0, 1.0));
    draw_uniforms.params = vec4(settings.overlay_depth_min, settings.overlay_depth_max, 0.0, 0.0);
    quad.draw(frame, shader, draw_uniforms);
}

/// Returns the GPU objects the edits made this frame need rebuilt. Sliders that change
/// pipeline state ask for the rebuild when the drag ends, not on every step of it.
fn drawPanel(settings: *Settings) Rebuild {
    var rebuild: Rebuild = .{};
    zgui.setNextWindowPos(.{ .x = 20, .y = 20, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 300, .h = 0, .cond = .first_use_ever });
    if (zgui.begin("shadows", .{})) {
        zgui.text("frame time: {d:.2} ms", .{1000.0 / zgui.io.getFramerate()});
        zgui.text("shadow map: {d} x {d}", .{ SHADOW_MAP_SIZE, SHADOW_MAP_SIZE });

        zgui.separatorText("Light");
        _ = zgui.sliderFloat("azimuth", .{ .v = &settings.light_azimuth, .min = 0.0, .max = 360.0 });
        _ = zgui.sliderFloat("elevation", .{ .v = &settings.light_elevation, .min = 5.0, .max = 89.0 });
        _ = zgui.checkbox("animate azimuth", .{ .v = &settings.animate_light });
        _ = zgui.sliderFloat("extent", .{ .v = &settings.light_extent, .min = 2.0, .max = 30.0 });
        _ = zgui.sliderFloat("distance", .{ .v = &settings.light_distance, .min = 5.0, .max = 60.0 });
        _ = zgui.sliderFloat("near", .{ .v = &settings.light_near, .min = 0.1, .max = 20.0 });
        _ = zgui.sliderFloat("far", .{ .v = &settings.light_far, .min = 10.0, .max = 100.0 });

        zgui.separatorText("Shadows");
        _ = zgui.sliderFloat("shader bias", .{ .v = &settings.shadow_bias, .min = 0.0, .max = 0.02, .cfmt = "%.4f" });
        if (zgui.checkbox("pipeline bias", .{ .v = &settings.pipeline_bias })) {
            rebuild.caster_shader = true;
        }
        if (settings.pipeline_bias) {
            _ = zgui.sliderInt("constant", .{ .v = &settings.bias_constant, .min = 0, .max = 1000 });
            rebuild.caster_shader = rebuild.caster_shader or zgui.isItemDeactivatedAfterEdit();
            _ = zgui.sliderFloat("slope scale", .{ .v = &settings.bias_slope_scale, .min = 0.0, .max = 10.0 });
            rebuild.caster_shader = rebuild.caster_shader or zgui.isItemDeactivatedAfterEdit();
        }
        if (zgui.comboFromEnum("filter", &settings.filter)) {
            rebuild.shadow_map = true;
        }
        _ = zgui.sliderInt("PCF radius", .{ .v = &settings.pcf_radius, .min = 0, .max = 2 });

        zgui.separatorText("Debug view");
        _ = zgui.comboFromEnum("view", &settings.debug_view);
        if (settings.debug_view == .overlay) {
            _ = zgui.sliderFloat("depth min", .{ .v = &settings.overlay_depth_min, .min = 0.0, .max = 1.0 });
            _ = zgui.sliderFloat("depth max", .{ .v = &settings.overlay_depth_max, .min = 0.0, .max = 1.0 });
            _ = zgui.sliderFloat("size", .{ .v = &settings.overlay_size, .min = 0.1, .max = 0.9 });
        }
    }
    zgui.end();
    return rebuild;
}
