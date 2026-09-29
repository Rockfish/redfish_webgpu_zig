const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");
const assets_list = @import("assets_list.zig");
const ui_display = @import("ui_display.zig");
const screenshot = @import("screenshot.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Arenas = core.Arenas;
const Context = core.Context;
const Camera = core.Camera;
const asset_loader = core.gltf_asset;
const GpuContext = core.GpuContext;
const MeshPrimitive = core.MeshPrimitive;

const ModelInstance = core.ModelInstance;
const AnimatorImpl = core.AnimatorImpl;

const Frame = core.Frame;
const Shader = core.Shader;
const srgbToLinear = core.colors.srgbToLinear;

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Mat4 = math.Mat4;

/// Every model is centered on the origin and scaled so its largest bounding box
/// extent equals this, so lighting, camera speeds, and clip planes are tuned once
/// instead of per model (the raw assets range from ~2 to ~300 units).
const TARGET_MODEL_SIZE: f32 = 20.0;

/// Clip planes for the normalized model size. See Camera.setNearFar for the
/// rules of thumb; the ratio here is 1:10,000.
const CAMERA_NEAR: f32 = 0.1;
const CAMERA_FAR: f32 = 1000.0;

const state_ = @import("state.zig");

/// redfish's GL clear gray, converted so it looks the same on the sRGB surface.
const CLEAR_COLOR = [4]f64{ srgbToLinear(0.5), srgbToLinear(0.5), srgbToLinear(0.5), 1.0 };

const SHADER_PATH = "src/core/shaders/pbr.wgsl";

// Uniform debug dump buffer (U key)
var debug_dump_buffer: [32 * 1024]u8 = undefined;

var buf1: [1024]u8 = undefined;
var buf2: [1024]u8 = undefined;

const ModelScope = struct {
    allocator: Allocator,
    arenas: *Arenas,
    context: Context,
    model: ?*ModelInstance = null,
    /// Normalizing model matrix (see normalizedModelTransform), sent as matModel.
    model_transform: Mat4 = Mat4.Identity,
    model_scale: f32 = 1.0,

    pub fn init(gpa: Allocator, io: std.Io) !*ModelScope {
        const arenas = try Arenas.init(gpa);
        const context = arenas.context(io);
        const model_scope = try gpa.create(ModelScope);
        model_scope.* = ModelScope{
            .allocator = gpa,
            .arenas = arenas,
            .context = context,
            .model = null,
        };
        return model_scope;
    }

    pub fn setModel(self: *ModelScope, model: *ModelInstance) void {
        self.model = model;
        self.model_scale = normalizedModelScale(model);
        self.model_transform = normalizedModelTransform(model, self.model_scale);
    }

    pub fn getModel(self: *ModelScope) *ModelInstance {
        if (self.model) |m| {
            return m;
        }
        std.debug.panic("Model not initialized", .{});
    }

    /// GPU objects first, then the arena that holds them.
    pub fn cleanUp(self: *ModelScope) void {
        if (self.model) |m| {
            m.cleanUp();
        }
        self.model = null;
        self.model_transform = Mat4.Identity;
        self.model_scale = 1.0;
        self.arenas.resetAll();
    }

    pub fn deinit(self: *ModelScope) void {
        self.arenas.deinit();
        self.allocator.destroy(self);
    }
};

/// Uniform scale that brings the model's largest rest-pose extent to TARGET_MODEL_SIZE.
fn normalizedModelScale(model: *ModelInstance) f32 {
    const bbox = model.gltf_asset.calculateBoundingBox(0);
    const size = bbox.max.sub(bbox.min);
    const max_extent = @max(@max(size.x, size.y), size.z);
    if (max_extent <= 0.0) {
        return 1.0;
    }
    return TARGET_MODEL_SIZE / max_extent;
}

/// Model matrix that moves the rest-pose bounding box center to the origin and
/// then applies the uniform scale: M = S * T(-center). Uniform scale is safe for
/// skinned meshes because the vertex shader applies matModel after skinning.
fn normalizedModelTransform(model: *ModelInstance, scale: f32) Mat4 {
    const bbox = model.gltf_asset.calculateBoundingBox(0);
    const center = bbox.min.add(bbox.max).mulScalar(0.5);

    var transform = Mat4.fromScale(vec3(scale, scale, scale));
    transform.translate(center.mulScalar(-1.0));
    return transform;
}

fn swapScope(current: **ModelScope, next: **ModelScope) void {
    std.mem.swap(*ModelScope, current, next);
    next.*.cleanUp();
}

// Model loading helper function
fn loadModel(context: Context, gpu: *GpuContext, model_info: assets_list.ModelInfo, state: *state_.State) !*ModelInstance {
    const path = model_info.path;

    std.debug.print("\nLoading model: {s} ({s}) - {s}\n", .{ model_info.name, model_info.format, model_info.description });
    std.debug.print("Path: {s}\n", .{path});

    var gltf_asset = try asset_loader.GltfAsset.init(context, gpu, model_info.name, path);
    gltf_asset.setNormalGenerationMode(.accurate);
    try gltf_asset.load();

    const animator = try core.Animator.init(context, gltf_asset);
    var animator_impl: AnimatorImpl = .{ .live_animator = animator };

    if (BAKE_ANIMATION) {
        const baked_animator = try core.BakedAnimator.init(
            context,
            gpu,
            animator,
            .{
                .frame_rate = 30.0,
                .capture = .all,
            },
        );
        animator_impl = .{ .baked_animator = baked_animator };
    }

    const model = try ModelInstance.init(context.alloc, model_info.name, animator_impl, gltf_asset);
    errdefer gltf_asset.cleanUp();

    // Check if model has animations and start appropriate animation(s)
    if (gltf_asset.gltf.animations) |animations| {
        if (animations.len > 0) {
            // Check if this model should play all animations simultaneously
            if (model_info.play_all_animations) {
                std.debug.print("Model configured for multi-animation - playing all {d} animations simultaneously\n", .{animations.len});
                try model.playAllAnimations();
                state.animation_id = -1; // Use -1 to indicate "all animations" mode
            } else {
                std.debug.print("Model has {d} animations, playing first animation\n", .{animations.len});
                try model.playAnimationById(0);
                state.animation_id = 0;
            }
        } else {
            std.debug.print("Model has no animations\n", .{});
            state.animation_id = -1;
        }
    } else {
        std.debug.print("Model has no animations\n", .{});
        state.animation_id = -1;
    }

    return model;
}

// Camera positioning helper function
fn positionCameraForModel(scope: *ModelScope, camera: *Camera) void {
    // Models are normalized to TARGET_MODEL_SIZE and centered on the origin, so
    // the framing is the same for every model. The factor leaves slack for
    // animations that swing outside the rest-pose bounds.
    const distance = TARGET_MODEL_SIZE * 2.5;
    const camera_pos = vec3(0.0, TARGET_MODEL_SIZE * 0.3, distance);

    camera.movement.reset(camera_pos, Vec3.Zero);

    outputPositions(scope, camera);
}

fn outputPositions(scope: *ModelScope, camera: *Camera) void {
    const bbox = scope.getModel().gltf_asset.calculateBoundingBox(0);
    std.debug.print("Model bounds - min: {s}  max: {s}  normalized scale: {d:.4}\n", .{
        bbox.min.asString(&buf1),
        bbox.max.asString(&buf2),
        scope.model_scale,
    });
    std.debug.print("Camera positioned at: {s}  looking at: {s}\n", .{
        camera.movement.transform.translation.asString(&buf1),
        camera.movement.target.asString(&buf2),
    });
}

fn switchModel(gpu: *GpuContext, state: *state_.State, current_scope: **ModelScope, next_scope: **ModelScope) !void {
    const initial_model_index = state.current_model_index;
    var next_model_index = @mod((state.current_model_index + state.model_index_increment), @as(i32, assets_list.model_infos.len));

    while (next_model_index != initial_model_index) {
        const model_info = assets_list.model_infos[@intCast(next_model_index)];

        const next_model: ?*ModelInstance = loadModel(next_scope.*.context, gpu, model_info, state) catch null;
        if (next_model) |model| {
            next_scope.*.setModel(model);
            swapScope(current_scope, next_scope);
            state.current_model_index = next_model_index;
            state.camera_reposition_requested = true;
            break;
        } else {
            std.debug.print("Failed to load model: {s}\n", .{model_info.path});
            next_scope.*.cleanUp();
            next_model_index = @mod((next_model_index + state.model_index_increment), @as(i32, assets_list.model_infos.len));
        }
    } else {
        std.debug.print("No valid model found.\n", .{});
    }
    state.model_reload_requested = false;
}

const camera_position = vec3(0.0, 12.0, 40.0);
const camera_target = vec3(0.0, 12.0, 0.0);

/// A key light at (50, 50, 50) with pbr.frag's falloff, a dim fill from the opposite side,
/// and 0.15 ambient. redfish's key light alone was intensity 100 (about 10x radiance at the
/// model), which blew backlit edges out to white; now 50 plus the fill.
pub fn demoLights() core.SceneLights {
    var lights = core.SceneLights.init();
    lights.ambient = vec3(0.15, 0.15, 0.15);
    lights.direction_light = .{
        .dir = vec3(1.0, -0.5, 1.0).toNormalized(),
        .color = vec3(0.5, 0.5, 0.55),
    };
    lights.setPointLight(0, .{
        .world_pos = vec3(50.0, 50.0, 50.0),
        .color = vec3(50.0, 50.0, 50.0),
        .constant = 1.0,
        .linear = 0.01,
        .quadratic = 0.001,
        .enabled = true,
    });
    return lights;
}

/// Baked and live animation draw with the same shader (pbr.wgsl).
const BAKE_ANIMATION: bool = true;

pub fn run(init: std.process.Init, window: *glfw.Window, gpu: *GpuContext, initial_model_index: i32, max_duration: ?f32) !void {
    std.debug.print("running app\n", .{});

    var common_arenas = try Arenas.init(init.gpa);
    const context = common_arenas.context(init.io);

    var model_scope_a = try ModelScope.init(init.gpa, init.io);
    var model_scope_b = try ModelScope.init(init.gpa, init.io);

    var current_scope = model_scope_a;
    var next_scope = model_scope_b;

    core.string.init(context.alloc);

    const window_size = window.getSize();
    const window_scale = window.getContentScale();
    const viewport_width = @as(f32, @floatFromInt(window_size[0])) * window_scale[0];
    const viewport_height = @as(f32, @floatFromInt(window_size[1])) * window_scale[1];
    const scaled_width = viewport_width / window_scale[0];
    const scaled_height = viewport_height / window_scale[1];

    const camera = try Camera.init(
        context.alloc,
        .{
            .position = camera_position,
            .target = camera_target,
            .scr_width = scaled_width,
            .scr_height = scaled_height,
        },
    );
    camera.setNearFar(CAMERA_NEAR, CAMERA_FAR);

    state_.state = state_.State{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .scaled_width = scaled_width,
        .scaled_height = scaled_height,
        .window_scale = window_scale,
        .camera = camera,
        .light_position = vec3(10.0, 10.0, -30.0),
        .delta_time = 0.0,
        .total_time = 0.0,
        .world_point = null,
        .camera_initial_position = camera_position,
        .camera_initial_target = camera_target,
        .input = .{
            .first_mouse = true,
            .mouse_x = scaled_width / 2.0,
            .mouse_y = scaled_height / 2.0,
            .key_presses = std.EnumSet(glfw.Key).initEmpty(),
            .key_processed = std.EnumSet(glfw.Key).initEmpty(),
        },
        .animation_id = 0,
        .current_model_index = initial_model_index,
    };

    const state = &state_.state;
    state_.initWindowHandlers(window);

    // Initialize UI system (after initWindowHandlers: zgui chains to those callbacks)
    var ui_state = ui_display.UIState.init(context.io, context.alloc, window, gpu);

    // Initialize screenshot system
    var screenshot_mgr = screenshot.ScreenshotManager.init(context.io, context.alloc);

    const shader = try Shader.init(
        context.io,
        context.alloc,
        gpu,
        SHADER_PATH,
        .{ .vertex_buffers = &MeshPrimitive.vertex_buffer_layouts, .material = .pbr, .alpha_to_coverage = true },
    );

    std.debug.print("\n--- Build gltf model ----------------------\n\n", .{});

    // Load initial model from demo list
    const initial_model = try loadModel(
        current_scope.context,
        gpu,
        state_.getCurrentModelInfo(),
        state,
    );
    current_scope.setModel(initial_model);

    // Position camera for initial model
    positionCameraForModel(current_scope, camera);

    std.debug.print("\n----------------------\n", .{});

    const scene_lights = demoLights();

    // --- event loop
    const start_time: f32 = @floatCast(glfw.getTime());
    state.total_time = start_time;
    // var frame_counter = FrameCounter.new();

    var buf: [1024]u8 = undefined;
    std.debug.print("{s}\n", .{camera.asString(&buf)});

    while (!window.shouldClose()) {
        const current_time: f32 = @floatCast(glfw.getTime());
        state.delta_time = current_time - state.total_time;
        state.total_time = current_time;

        // Check if we've exceeded the maximum duration
        if (max_duration) |duration| {
            if (current_time - start_time >= duration) {
                std.debug.print("Reached maximum duration of {d} seconds, exiting\n", .{duration});
                break;
            }
        }

        state_.processKeys();

        // Check if model reload is requested
        if (state.model_reload_requested) {
            std.debug.print("Loading next model...\n", .{});
            try switchModel(gpu, state, &current_scope, &next_scope);
            state.model_reload_requested = false;
        }

        // Check if camera repositioning is requested
        if (state.camera_reposition_requested) {
            std.debug.print("Repositioning camera for current model...\n", .{});
            positionCameraForModel(current_scope, camera);
            state.camera_reposition_requested = false;
        }

        if (state.output_position_requested) {
            outputPositions(current_scope, state.camera);
            state.output_position_requested = false;
        }

        // Handle animation control requests
        if (state.animation_reset_requested) {
            if (state.animation_id >= 0) {
                try current_scope.getModel().playAnimationById(@intCast(state.animation_id));
                std.debug.print("Reset animation to {d}\n", .{state.animation_id});
            }
            state.animation_reset_requested = false;
        }

        if (state.animation_next_requested) {
            if (current_scope.getModel().gltf_asset.gltf.animations) |animations| {
                if (animations.len > 0) {
                    state.animation_id = @mod(state.animation_id + 1, @as(i32, @intCast(animations.len)));
                    try current_scope.getModel().playAnimationById(@intCast(state.animation_id));
                    std.debug.print("Next animation: {d}/{d}\n", .{ state.animation_id + 1, animations.len });
                }
            }
            state.animation_next_requested = false;
        }

        if (state.animation_prev_requested) {
            if (current_scope.getModel().gltf_asset.gltf.animations) |animations| {
                if (animations.len > 0) {
                    state.animation_id -= 1;
                    if (state.animation_id < 0) {
                        state.animation_id = @as(i32, @intCast(animations.len)) - 1;
                    }
                    try current_scope.getModel().playAnimationById(@intCast(state.animation_id));
                    std.debug.print("Previous animation: {d}/{d}\n", .{ state.animation_id + 1, animations.len });
                }
            }
            state.animation_prev_requested = false;
        }

        // Update animation
        if (state.run_animation) {
            try current_scope.getModel().updateAnimation(state.delta_time);
        }

        glfw.pollEvents();

        const uniform_debug = &gpu.uniform_debug;

        // One-shot screenshot: its own frame, drawn and read back before the window's.
        // Uniforms are captured for it whether or not shader debug (G) is on.
        if (state.screenshot_requested) {
            uniform_debug.enable();
            uniform_debug.clear();

            const capture_frame = screenshot_mgr.beginCapture(gpu, CLEAR_COLOR);
            drawScene(&capture_frame, state, shader, current_scope, scene_lights);
            screenshot_mgr.takeScreenshot(capture_frame, SHADER_PATH) catch |err| {
                std.debug.print("Screenshot failed: {any}\n", .{err});
            };

            state.screenshot_requested = false;
            std.debug.print("Screenshot completed!\n", .{});
        }

        // Handle regular shader debug state (separate from screenshot)
        if (state.shader_debug_enabled) {
            uniform_debug.enable();
            uniform_debug.clear();
        } else {
            uniform_debug.disable();
        }

        // Before the UI frame starts, so a skipped frame never leaves one open
        const frame = gpu.beginFrame(CLEAR_COLOR) orelse continue;
        ui_state.update(window);

        drawScene(&frame, state, shader, current_scope, scene_lights);

        // Handle debug dump request
        if (state.shader_debug_dump_requested) {
            printUniformDump(uniform_debug);
            state.shader_debug_dump_requested = false;
        }

        // Draw UI overlay
        ui_state.draw(&frame, current_scope.getModel());

        gpu.endFrame(frame);
    }

    std.debug.print("\nRun completed.\n\n", .{});

    screenshot_mgr.deinit();
    shader.releaseGpuObjects();
    ui_state.deinit();
    current_scope.cleanUp();
    next_scope.cleanUp();
    common_arenas.deinit();
    model_scope_a.deinit();
    model_scope_b.deinit();
}

/// The scene without the UI: the window's frame and the screenshot frame both draw it.
fn drawScene(frame: *const Frame, state: *state_.State, shader: *const Shader, scope: *ModelScope, scene_lights: core.SceneLights) void {
    const gpu = frame.gpu;
    const ctx = state.camera.getRenderContext(state.total_time);
    var frame_uniforms = ctx.frameUniforms();
    var lights = scene_lights;
    lights.fade_grazing_specular = state.fade_grazing_specular;
    frame_uniforms.lights = lights.uniforms();
    gpu.writeFrameUniforms(frame_uniforms);

    addDebugValues(&gpu.uniform_debug, state);

    scope.getModel().draw(frame, shader, scope.model_transform);
}

/// App values dumped with the uniforms, as redfish added them.
fn addDebugValues(uniform_debug: *core.UniformDebug, state: *state_.State) void {
    if (!uniform_debug.enabled) {
        return;
    }

    var buf: [128]u8 = undefined;
    uniform_debug.addValue("camera_position", state.camera.getPosition().asString(&buf));
    uniform_debug.addValue("camera_target", state.camera.getTarget().asString(&buf));
    uniform_debug.addValue("light_position", state.light_position.asString(&buf));
    uniform_debug.addValue("frame_time", std.fmt.bufPrint(&buf, "{d:.6}s", .{state.delta_time}) catch "error");
}

fn printUniformDump(uniform_debug: *core.UniformDebug) void {
    if (!uniform_debug.enabled) {
        std.debug.print("Debug not enabled (G toggles it)\n", .{});
        return;
    }
    var writer = std.Io.Writer.fixed(&debug_dump_buffer);
    uniform_debug.dump(&writer) catch {
        std.debug.print("(uniform dump truncated)\n", .{});
    };
    std.debug.print("\n{s}\n", .{writer.buffered()});
}
