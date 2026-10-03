//! Shadow map test bed (plan 017). A floor with cubes, spheres, and a cylinder, some
//! tilted so there are sloped receivers, lit by two shadow-casting lights: a directional
//! light and a spotlight, each with a layer in one `core.ShadowMapArray`.
//!
//! Each frame has a shadow pass per light, drawing every shape from that light into its
//! layer (shadow_caster.wgsl), then the window pass draws them again from the camera,
//! sampling both layers (shadow_scene.wgsl). Each shadow pass binds its own light's
//! matrix at group 3; see `ShadowMapArray.init` for why that's a bind group per layer and
//! not one matrix rewritten between passes. The panel moves the lights and shows a layer
//! itself: as an overlay, or by drawing the scene from that light.
//!
//! The camera can also fly a closed path around the scene (`core.motion.PathFollow`, plan
//! 016): straight segments or a Catmull-Rom curve through the same waypoints, drawn as
//! lines so the two can be compared.
//!
//! Keys: arrows circle the camera around the scene (world up and right, so the horizon
//! stays level), W / S move it in and out, Escape quits. The keys do nothing while the
//! camera flies the path.

const std = @import("std");
const core = @import("core");
const math = @import("math");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const Arenas = core.Arenas;
const Input = core.Input;
const Camera = core.Camera;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const FrameUniforms = core.bindings.FrameUniforms;
const GpuContext = core.GpuContext;
const SceneLights = core.SceneLights;
const Shader = core.Shader;
const ShadowMapArray = core.ShadowMapArray;
const Shape = core.shapes.Shape;
const gui = core.gui;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const PathFollow = core.motion.PathFollow;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;

const CLEAR_COLOR = [4]f64{ 0.05, 0.06, 0.08, 1.0 };
const SHADOW_MAP_SIZE: u32 = 2048;
/// Where the lights look and the camera circles.
const SCENE_CENTER = vec3(0.0, 0.0, 0.0);
const SPOT_COLOR = vec3(1.0, 0.85, 0.6);

const DebugView = enum(i32) { off, overlay, light_view };

/// The shadow map layers, in the order shadow_scene.wgsl reads them.
/// The camera's flythrough: a closed loop around the scene, rising and dipping.
const camera_waypoints = [_]Vec3{
    vec3(13.0, 5.0, 0.0),
    vec3(8.0, 2.5, 10.0),
    vec3(-4.0, 2.0, 11.0),
    vec3(-12.0, 6.0, 3.0),
    vec3(-7.0, 3.5, -10.0),
    vec3(6.0, 2.0, -11.0),
};
/// Line segments drawn along the path.
const PATH_LINE_SEGMENTS = 240;

const CameraPath = enum(i32) { off, linear, catmull_rom };
const CameraLook = enum(i32) { center, ahead };

const Layer = enum(u32) {
    directional,
    spot,

    const count = @typeInfo(Layer).@"enum".fields.len;
};

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
    spot_enabled: bool = true,
    /// Spotlight position around the scene center: angle (degrees), height, and
    /// horizontal distance. It always aims at the center.
    spot_azimuth: f32 = 210.0,
    spot_height: f32 = 7.0,
    spot_radius: f32 = 8.0,
    /// Full cone angle in degrees: the field of view of its shadow map.
    spot_cone: f32 = 60.0,
    /// The spotlight's far plane; nothing past it is lit or shadowed by it.
    spot_range: f32 = 30.0,
    spot_intensity: f32 = 3.0,
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
    filter: ShadowMapArray.Filter = .linear,
    /// Comparison samples around each lookup: 0 is one sample, 1 a 3x3 grid, 2 a 5x5.
    pcf_radius: i32 = 1,
    debug_view: DebugView = .off,
    /// The layer the overlay and the light view show.
    debug_layer: Layer = .directional,
    camera_path: CameraPath = .off,
    /// Units per second along the path.
    path_speed: f32 = 3.0,
    /// Look at the scene center, or ahead along the path (`PathFollow.tangent`).
    camera_look: CameraLook = .center,
    show_path: bool = true,
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

/// A light's matrices for one frame, from the panel's settings.
const LightView = struct {
    /// Direction the light travels, toward the scene center.
    dir: Vec3,
    position: Vec3,
    view: Mat4,
    projection: Mat4,
    /// projection x view: the light's `ShadowMapArray` layer.
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

    // Lit and shadow-receiving, for the window pass. The shadow passes use
    // `createCasterShader`.
    const scene_shader = try Shader.init(context.io, context.alloc, gpu, "examples/shadows/shaders/shadow_scene.wgsl", .{
        .vertex_buffers = shape_layouts,
        .pass = .shadow_layers,
    });
    defer scene_shader.releaseGpuObjects();

    var settings: Settings = .{};

    var caster_shader = try createCasterShader(context, gpu, settings);
    defer caster_shader.releaseGpuObjects();

    const overlay_shader = try Shader.init(context.io, context.alloc, gpu, "examples/shadows/shaders/shadow_map_overlay.wgsl", .{
        .vertex_buffers = shape_layouts,
        .pass = .shadow_layers,
    });
    defer overlay_shader.releaseGpuObjects();

    var shadow_maps = createShadowMaps(gpu, settings);
    defer shadow_maps.releaseGpuObjects();

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

    const lines_shader = try Shader.init(context.io, context.alloc, gpu, "examples/shadows/shaders/lines.wgsl", .{
        .vertex_buffers = &Lines.vertex_buffer_layouts,
        .topology = .line_list,
    });
    defer lines_shader.releaseGpuObjects();
    var path_lines = try Lines.init(context.alloc, lines_shader, 1.0, 1.0, PATH_LINE_SEGMENTS);

    var camera_path: PathFollow = .{ .points = &camera_waypoints, .speed = 0.0, .repeat = .loop };

    // Before gui.init: ImGui's GLFW backend chains to Input's callbacks
    const input = Input.init(window);
    gui.init(allocator, window, gpu);
    defer gui.deinit();

    var rebuild: Rebuild = .{};

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        input.update();
        if (input.isDown(.escape)) {
            window.setShouldClose(true);
        }

        const time = input.total_time;
        const delta_time = input.delta_time;

        if (settings.camera_path == .off) {
            processKeys(input, camera, delta_time);
        } else {
            flyCamera(camera, &camera_path, settings, delta_time);
        }

        // Depth bias is pipeline state and filtering is sampler state, both fixed when
        // created, so a change in the panel means new ones. Between frames, not while the
        // old ones are in use by commands still being recorded.
        if (rebuild.caster_shader) {
            caster_shader.releaseGpuObjects();
            caster_shader = try createCasterShader(context, gpu, settings);
        }
        if (rebuild.shadow_map) {
            shadow_maps.releaseGpuObjects();
            shadow_maps = createShadowMaps(gpu, settings);
        }
        rebuild = .{};
        if (settings.animate_light) {
            settings.light_azimuth = @mod(settings.light_azimuth + 20.0 * delta_time, 360.0);
        }

        var frame = gpu.acquireFrame() orelse continue;

        camera.setScreenDimensions(@floatFromInt(gpu.width), @floatFromInt(gpu.height));
        gpu.writeFrameUniforms(frameUniforms(camera, settings, gpu, time));

        // Every layer's light before any pass is recorded: each has its own slot
        shadow_maps.setLightSpace(gpu, @intFromEnum(Layer.directional), lightView(.directional, settings, 1.0).light_space);
        shadow_maps.setLightSpace(gpu, @intFromEnum(Layer.spot), lightView(.spot, settings, 1.0).light_space);

        // A shadow pass per light: every shape from that light, depth only
        for (0..Layer.count) |i| {
            const layer: Layer = @enumFromInt(i);
            if (layer == .spot and !settings.spot_enabled) {
                continue;
            }
            frame.beginPass(shadow_maps.passTarget(@intFromEnum(layer)));
            shadow_maps.bindCaster(&frame, @intFromEnum(layer));
            drawObjects(&frame, caster_shader, &objects, settings);
            frame.endPass();
        }

        // Window pass: every shape from the camera (or a light), sampling both layers
        frame.beginSurfacePass(CLEAR_COLOR);
        shadow_maps.bind(&frame);
        drawObjects(&frame, scene_shader, &objects, settings);
        if (settings.camera_path != .off and settings.show_path) {
            drawPath(&frame, &path_lines, camera_path);
        }
        if (settings.debug_view == .overlay) {
            drawOverlay(&frame, overlay_shader, overlay_quad, settings, gpu);
        }

        gui.newFrame();
        rebuild = drawPanel(&settings);
        gui.draw(frame);

        gpu.endFrame(frame);
    }
}

/// The shadow passes' pipelines: shadow_caster.wgsl, depth only (no fragment stage), the
/// layer's light at group 3, with the panel's depth bias when it's on.
fn createCasterShader(context: core.Context, gpu: *GpuContext, settings: Settings) !*Shader {
    const depth_bias: core.pipeline.DepthBias = if (settings.pipeline_bias)
        .{ .constant = settings.bias_constant, .slope_scale = settings.bias_slope_scale }
    else
        .{};
    return Shader.init(context.io, context.alloc, gpu, "examples/shadows/shaders/shadow_caster.wgsl", .{
        .vertex_buffers = &Shape.vertex_buffer_layouts,
        .color_target = .none,
        .pass = .shadow_caster,
        .depth_bias = depth_bias,
    });
}

fn createShadowMaps(gpu: *const GpuContext, settings: Settings) ShadowMapArray {
    return ShadowMapArray.init(gpu, .{ .size = SHADOW_MAP_SIZE, .layers = Layer.count, .filter = settings.filter });
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

/// Moves the camera along the path: the path's shape and speed from the panel, looking at
/// the scene center or ahead along the direction of travel.
fn flyCamera(camera: *Camera, path: *PathFollow, settings: Settings, delta_time: f32) void {
    path.shape = if (settings.camera_path == .catmull_rom) .catmull_rom else .linear;
    path.speed = settings.path_speed;
    const position = path.update(delta_time);
    const target = switch (settings.camera_look) {
        .center => SCENE_CENTER,
        .ahead => position.add(path.tangent()),
    };
    camera.movement.reset(position, target);
}

/// The path's current shape, sampled along its length. A copy of the path, so the
/// camera's position on it is untouched.
fn drawPath(frame: *const Frame, lines: *Lines, path: PathFollow) void {
    var sampler = path;
    const length = sampler.length();
    var segments: [PATH_LINE_SEGMENTS]LineSegment = undefined;
    var previous = sampler.points[0];
    for (&segments, 1..) |*segment, i| {
        sampler.distance = length * @as(f32, @floatFromInt(i)) / PATH_LINE_SEGMENTS;
        const point = sampler.position();
        segment.* = .{ .start = previous, .end = point, .color = .gold };
        previous = point;
    }
    lines.draw(frame, &segments);
}

fn processKeys(input: *const Input, camera: *Camera, delta_time: f32) void {
    const bindings = [_]struct { key: zglfw.Key, direction: core.MovementDirection }{
        .{ .key = .left, .direction = .circle_left },
        .{ .key = .right, .direction = .circle_right },
        .{ .key = .up, .direction = .circle_up },
        .{ .key = .down, .direction = .circle_down },
        .{ .key = .w, .direction = .radius_in },
        .{ .key = .s, .direction = .radius_out },
    };
    for (bindings) |binding| {
        if (input.isDown(binding.key)) {
            camera.processMovement(binding.direction, delta_time);
        }
    }
}

/// `layer`'s light, aimed at the scene center. `aspect` is 1 for the square shadow map;
/// the light view passes the window's, which widens the view instead of stretching it
/// (the shadow map covers the middle square). Both projections have zero-to-one depth,
/// as the shadow map stores it.
fn lightView(layer: Layer, settings: Settings, aspect: f32) LightView {
    const position = switch (layer) {
        .directional => blk: {
            const azimuth = std.math.degreesToRadians(settings.light_azimuth);
            const elevation = std.math.degreesToRadians(settings.light_elevation);
            const toward_light = vec3(
                @cos(elevation) * @cos(azimuth),
                @sin(elevation),
                @cos(elevation) * @sin(azimuth),
            );
            break :blk SCENE_CENTER.add(toward_light.mulScalar(settings.light_distance));
        },
        .spot => blk: {
            const azimuth = std.math.degreesToRadians(settings.spot_azimuth);
            break :blk vec3(settings.spot_radius * @cos(azimuth), settings.spot_height, settings.spot_radius * @sin(azimuth));
        },
    };
    const view = Mat4.lookAtRhGl(position, SCENE_CENTER, Vec3.World_Up);

    const projection = switch (layer) {
        // Parallel rays: an orthographic box around the scene
        .directional => blk: {
            const e = settings.light_extent;
            break :blk Mat4.orthographicRhZo(-e * aspect, e * aspect, -e, e, settings.light_near, settings.light_far);
        },
        // Rays from a point: a perspective frustum whose field of view is the cone
        .spot => Mat4.perspectiveRhZo(std.math.degreesToRadians(settings.spot_cone), aspect, 0.5, settings.spot_range),
    };

    return .{
        .dir = SCENE_CENTER.sub(position).toNormalized(),
        .position = position,
        .view = view,
        .projection = projection,
        .light_space = projection.mulMat4(&view),
    };
}

/// The frame's camera and lights. In the light view the scene is drawn from the debug
/// layer's light.
fn frameUniforms(camera: *Camera, settings: Settings, gpu: *const GpuContext, time: f32) FrameUniforms {
    var lights = SceneLights.init();
    lights.ambient = vec3(0.15, 0.15, 0.18);
    lights.direction_light = .{ .dir = lightView(.directional, settings, 1.0).dir, .color = vec3(1.0, 0.97, 0.9) };
    if (settings.spot_enabled) {
        // Point light 0 is the spotlight; shadow_scene.wgsl adds the cone and shadow
        lights.setPointLight(0, .{
            .world_pos = lightView(.spot, settings, 1.0).position,
            .color = SPOT_COLOR.mulScalar(settings.spot_intensity),
            .constant = 1.0,
            .linear = 0.05,
            .quadratic = 0.01,
            .enabled = true,
        });
    }

    var uniforms = camera.getRenderContext(time).frameUniforms();
    if (settings.debug_view == .light_view) {
        const aspect = @as(f32, @floatFromInt(gpu.width)) / @as(f32, @floatFromInt(gpu.height));
        const light = lightView(settings.debug_layer, settings, aspect);
        uniforms.projection = light.projection;
        uniforms.view = light.view;
        uniforms.projection_view = light.light_space;
        uniforms.view_position = light.position;
    }
    uniforms.lights = lights.uniforms();
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

/// A shadow map layer as a square in the window's bottom-left corner. The unit square is
/// scaled and moved in clip space (-1..1), so its model matrix is the whole transform.
fn drawOverlay(frame: *const Frame, shader: *const Shader, quad: *const Shape, settings: Settings, gpu: *const GpuContext) void {
    const aspect = @as(f32, @floatFromInt(gpu.width)) / @as(f32, @floatFromInt(gpu.height));
    const height = 2.0 * settings.overlay_size;
    const width = height / aspect;
    const margin = 0.04;
    const center = vec3(-1.0 + margin + width / 2.0, -1.0 + margin * aspect + height / 2.0, 0.0);
    const model = Mat4.fromTranslation(center).mulMat4(&Mat4.fromScale(vec3(width, height, 1.0)));

    var draw_uniforms = DrawUniforms.init(model, vec4(1.0, 1.0, 1.0, 1.0));
    const layer: f32 = @floatFromInt(@intFromEnum(settings.debug_layer));
    draw_uniforms.params = vec4(settings.overlay_depth_min, settings.overlay_depth_max, layer, 0.0);
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
        zgui.text("shadow maps: {d} layers, {d} x {d}", .{ Layer.count, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE });

        zgui.separatorText("Directional light");
        _ = zgui.sliderFloat("azimuth", .{ .v = &settings.light_azimuth, .min = 0.0, .max = 360.0 });
        _ = zgui.sliderFloat("elevation", .{ .v = &settings.light_elevation, .min = 5.0, .max = 89.0 });
        _ = zgui.checkbox("animate azimuth", .{ .v = &settings.animate_light });
        _ = zgui.sliderFloat("extent", .{ .v = &settings.light_extent, .min = 2.0, .max = 30.0 });
        _ = zgui.sliderFloat("distance", .{ .v = &settings.light_distance, .min = 5.0, .max = 60.0 });
        _ = zgui.sliderFloat("near", .{ .v = &settings.light_near, .min = 0.1, .max = 20.0 });
        _ = zgui.sliderFloat("far", .{ .v = &settings.light_far, .min = 10.0, .max = 100.0 });

        zgui.separatorText("Spotlight");
        _ = zgui.checkbox("spotlight", .{ .v = &settings.spot_enabled });
        if (settings.spot_enabled) {
            _ = zgui.sliderFloat("spot azimuth", .{ .v = &settings.spot_azimuth, .min = 0.0, .max = 360.0 });
            _ = zgui.sliderFloat("spot height", .{ .v = &settings.spot_height, .min = 1.0, .max = 20.0 });
            _ = zgui.sliderFloat("spot distance", .{ .v = &settings.spot_radius, .min = 1.0, .max = 20.0 });
            _ = zgui.sliderFloat("cone", .{ .v = &settings.spot_cone, .min = 10.0, .max = 120.0 });
            _ = zgui.sliderFloat("range", .{ .v = &settings.spot_range, .min = 5.0, .max = 60.0 });
            _ = zgui.sliderFloat("intensity", .{ .v = &settings.spot_intensity, .min = 0.0, .max = 10.0 });
        }

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

        zgui.separatorText("Camera path");
        _ = zgui.comboFromEnum("path", &settings.camera_path);
        if (settings.camera_path != .off) {
            _ = zgui.sliderFloat("speed", .{ .v = &settings.path_speed, .min = 0.0, .max = 15.0 });
            _ = zgui.comboFromEnum("look", &settings.camera_look);
            _ = zgui.checkbox("show path", .{ .v = &settings.show_path });
        }

        zgui.separatorText("Debug view");
        _ = zgui.comboFromEnum("view", &settings.debug_view);
        if (settings.debug_view != .off) {
            _ = zgui.comboFromEnum("layer", &settings.debug_layer);
        }
        if (settings.debug_view == .overlay) {
            _ = zgui.sliderFloat("depth min", .{ .v = &settings.overlay_depth_min, .min = 0.0, .max = 1.0 });
            _ = zgui.sliderFloat("depth max", .{ .v = &settings.overlay_depth_max, .min = 0.0, .max = 1.0 });
            _ = zgui.sliderFloat("size", .{ .v = &settings.overlay_size, .min = 0.1, .max = 0.9 });
        }
    }
    zgui.end();
    return rebuild;
}
