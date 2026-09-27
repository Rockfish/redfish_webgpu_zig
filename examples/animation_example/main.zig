const std = @import("std");
const glfw = @import("zglfw");
const zstbi = @import("zstbi");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");

const log = std.log.scoped(.main);

const BakedAnimation = core.BakedAnimation;
const BakedAnimator = core.BakedAnimator;
const ModelInstance = core.ModelInstance;

const ArenaAllocator = std.heap.ArenaAllocator;
const print = log.info;

const Context = core.Context;
const GpuContext = core.GpuContext;
const MeshPrimitive = core.MeshPrimitive;
const srgbToLinear = core.colors.srgbToLinear;
const Model = core.Model;
const GltfAsset = core.gltf_asset.GltfAsset;
const TextureConfig = core.texture.TextureConfig;
const animation = core.animation;
const Camera = core.Camera;
const Shader = core.Shader;
// const String = core.string.String;
const FrameCounter = core.FrameCounter;
const Input = core.Input;

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec2 = math.vec2;
const vec3 = math.vec3;
const Mat4 = math.Mat4;
const Quat = math.Quat;

const Texture = core.texture.Texture;
const Animator = animation.Animator;
const AnimationClip = animation.AnimationClip;
const AnimationRepeat = animation.AnimationRepeatMode;

const Window = glfw.Window;

const SCR_WIDTH: f32 = 800.0;
const SCR_HEIGHT: f32 = 800.0;

// Model selection for testing
const ModelChoice = enum {
    cesium_man,
    player,
    spacesuit,
    securitybot,
    interpolation_test,
};

// Report dumping configuration
const DUMP_REPORT: bool = true; // Set to true to generate model report
const REPORT_PATH: []const u8 = "model_report.md"; // Output file path

// Lighting
const LIGHT_FACTOR: f32 = 1.0;
const NON_BLUE: f32 = 0.9;

/// redfish's GL clear color, converted so it looks the same on the sRGB surface.
const CLEAR_COLOR = [4]f64{ srgbToLinear(0.05), srgbToLinear(0.1), srgbToLinear(0.05), 1.0 };

const FLOOR_LIGHT_FACTOR: f32 = 0.35;
const FLOOR_NON_BLUE: f32 = 0.7;

// Struct for passing state between the window loop and the event handler.
const State = struct {
    camera: *Camera,
    input: *Input,
    light_postion: Vec3,
    delta_time: f32,
    last_frame: f32,
    first_mouse: bool,
    last_x: f32,
    last_y: f32,
    scr_width: f32 = SCR_WIDTH,
    scr_height: f32 = SCR_HEIGHT,
    current_action: u8 = 0,
    model: *ModelInstance = undefined,
    animation_index: u32 = 4,
    run_animation: bool = true,
    baked: bool = true,
};

const content_dir = "assets";

var state: State = undefined;

const V4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn new(x: f32, y: f32, z: f32, w: f32) V4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
};

const TexConfigs = struct {
    mesh_name: []const u8,
    uniform_name: []const u8,
    texture_path: []const u8,
    config: TextureConfig,
};

const CameraPosition = struct {
    position: Vec3,
    target: Vec3,
};

const PlayerClip = struct {
    name: []const u8,
    clip: AnimationClip,
};

const fps: f32 = 30.0;

// Player animation clips from game_angrybot/player.zig
const player_clips = [_]PlayerClip{
    .{ .name = "idle", .clip = AnimationClip.init(0, 55.0 / fps, 130.0 / fps, AnimationRepeat.Forever) },
    .{ .name = "right", .clip = AnimationClip.init(0, 184.0 / fps, 204.0 / fps, AnimationRepeat.Forever) },
    .{ .name = "forward", .clip = AnimationClip.init(0, 134.0 / fps, 154.0 / fps, AnimationRepeat.Forever) },
    .{ .name = "back", .clip = AnimationClip.init(0, 159.0 / fps, 179.0 / fps, AnimationRepeat.Forever) },
    .{ .name = "left", .clip = AnimationClip.init(0, 209.0 / fps, 229.0 / fps, AnimationRepeat.Forever) },
    .{ .name = "dead", .clip = AnimationClip.init(0, 234.0 / fps, 293.0 / fps, AnimationRepeat.Once) },
};

const ModelConfig = struct {
    choice: ModelChoice,
    path: []const u8,
    name: []const u8,
    transform: Mat4,
    addTextures: []const TexConfigs,
    animationClip: ?AnimationClip = null,
    animationPlayAll: bool = false, // If true, play all animations in the model
    cameraPosition: ?CameraPosition = null,
};

// Define texture configuration (same settings as ASSIMP version)
const texture_config = TextureConfig{
    .filter = .Linear,
    .flip_v = true,
    .wrap = .Clamp,
};

// Model configurations - consolidated from all switch statements
const model_configs = [_]ModelConfig{
    // CesiumMan configuration
    .{
        .choice = .cesium_man,
        .path = "BrainStem_converted.gltf",
        .name = "CesiumMan",
        .transform = blk: {
            var transform = Mat4.Identity;
            transform.translate(vec3(0.0, 0.0, -1.0));
            transform.scale(vec3(1.0, 1.0, 1.0));
            break :blk transform;
        },
        .addTextures = &[_]TexConfigs{
            .{ .mesh_name = "Cesium_Man", .uniform_name = "texture_diffuse", .texture_path = "CesiumMan_img0.jpg", .config = texture_config },
        },
        .animationClip = AnimationClip.init(0, 0.042, 2.0, AnimationRepeat.Forever),
        .cameraPosition = null,
    },
    // Player configuration
    .{
        .choice = .player,
        .path = "assets/angrybots_assets/Models/Player/Player.gltf",
        .name = "Player",
        .transform = blk: {
            var transform = Mat4.Identity;
            transform.scale(vec3(0.1, 0.1, 0.1));
            break :blk transform;
        },
        .addTextures = &[_]TexConfigs{
            .{ .mesh_name = "Player", .uniform_name = "texture_diffuse", .texture_path = "Textures/Player_D.tga", .config = texture_config },
            .{ .mesh_name = "Player", .uniform_name = "texture_specular", .texture_path = "Textures/Player_M.tga", .config = texture_config },
            .{ .mesh_name = "Player", .uniform_name = "texture_emissive", .texture_path = "Textures/Player_E.tga", .config = texture_config },
            .{ .mesh_name = "Player", .uniform_name = "texture_normal", .texture_path = "Textures/Player_NRM.tga", .config = texture_config },
            .{ .mesh_name = "Gun", .uniform_name = "texture_diffuse", .texture_path = "Textures/Gun_D.tga", .config = texture_config },
            .{ .mesh_name = "Gun", .uniform_name = "texture_specular", .texture_path = "Textures/Gun_M.tga", .config = texture_config },
            .{ .mesh_name = "Gun", .uniform_name = "texture_emissive", .texture_path = "Textures/Gun_E.tga", .config = texture_config },
            .{ .mesh_name = "Gun", .uniform_name = "texture_normal", .texture_path = "Textures/Gun_NRM.tga", .config = texture_config },
        },
        // .addTextures = &[_]TexConfigs{
        //     .{ .mesh_name = "Player", .uniform_name = "baseColorTexture", .texture_path = "Textures/Player_D.tga", .config = texture_config },
        //     .{ .mesh_name = "Player", .uniform_name = "metallicRoughnessTexture", .texture_path = "Textures/Player_M.tga", .config = texture_config },
        //     .{ .mesh_name = "Player", .uniform_name = "emissiveTexture", .texture_path = "Textures/Player_E.tga", .config = texture_config },
        //     .{ .mesh_name = "Player", .uniform_name = "normalTexture", .texture_path = "Textures/Player_NRM.tga", .config = texture_config },
        //     .{ .mesh_name = "Gun", .uniform_name = "baseColorTexture", .texture_path = "Textures/Gun_D.tga", .config = texture_config },
        //     .{ .mesh_name = "Gun", .uniform_name = "metallicRoughnessTexture", .texture_path = "Textures/Gun_M.tga", .config = texture_config },
        //     .{ .mesh_name = "Gun", .uniform_name = "emissiveTexture", .texture_path = "Textures/Gun_E.tga", .config = texture_config },
        //     .{ .mesh_name = "Gun", .uniform_name = "normalTexture", .texture_path = "Textures/Gun_NRM.tga", .config = texture_config },
        // },
        .animationClip = AnimationClip.init(0, 0.0, 294.0 / 30.0, AnimationRepeat.Forever),
        .cameraPosition = CameraPosition{ .position = vec3(0.0, 10.0, 30.0), .target = vec3(0.0, 10.0, 0.0) },
    },
    // Spacesuit configuration
    .{
        .choice = .spacesuit,
        // .path = "assets/models/Spacesuit/Spacesuit_converted.gltf",
        .path = "assets/modular_characters/Individual Characters/glTF/Spacesuit.gltf",
        .name = "Spacesuit",
        .transform = blk: {
            var transform = Mat4.Identity;
            transform.scale(vec3(10, 10, 10));
            break :blk transform;
        },
        .addTextures = &[_]TexConfigs{},
        .animationClip = AnimationClip.init(13, 0.0, 32.0 / 30.0, AnimationRepeat.Forever),
        .cameraPosition = CameraPosition{ .position = vec3(0.0, 20.0, 80.0), .target = vec3(0.0, 10.0, 0.0) },
    },
    // Security Bot configuration
    .{
        .choice = .securitybot,
        .path = "assets/models/Security_bot_7/scene.gltf",
        .name = "Security_Bot",
        .transform = Mat4.Identity,
        .addTextures = &[_]TexConfigs{},
        .animationClip = null,
        .cameraPosition = null,
    },
    // InterpolationTest configuration
    .{
        .choice = .interpolation_test,
        .path = "assets/glTF-Sample-Models/InterpolationTest/glTF/InterpolationTest.gltf",
        .name = "InterpolationTest",
        .transform = Mat4.Identity,
        .addTextures = &[_]TexConfigs{},
        .animationClip = AnimationClip.init(0, 0.0, 5.0, AnimationRepeat.Forever),
        .animationPlayAll = true,
        .cameraPosition = null,
    },
};

// glTF-Sample-Models/InterpolationTest/glTF/InterpolationTest.gltf

// Select model based on enum
// const SELECTED_MODEL: ModelChoice = .spacesuit;
const SELECTED_MODEL: ModelChoice = .player;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const cwd = try std.process.currentPathAlloc(init.io, allocator);
    log.info("Running sample_animation. cwd = {s}", .{cwd});

    var args = init.minimal.args.iterate();
    _ = args.skip(); // Skip program name
    //
    var runtime_duration: ?f32 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--duration") or std.mem.eql(u8, arg, "-d")) {
            if (args.next()) |duration_str| {
                runtime_duration = std.fmt.parseFloat(f32, duration_str) catch |err| {
                    log.info("Invalid duration: {s}, error: {}", .{ duration_str, err });
                    std.process.exit(1);
                };
                log.info("Runtime duration set to: {d} seconds", .{runtime_duration.?});
            } else {
                log.info("Error: --duration requires a value", .{});
                std.process.exit(1);
            }
        }
    }

    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.client_api, .no_api);

    const window = try glfw.Window.create(
        600,
        600,
        "Animation Tester",
        null,
        null,
    );
    defer window.destroy();

    var gpu = try GpuContext.init(init.gpa, window);
    defer gpu.deinit();

    try run(init, window, &gpu, runtime_duration);
}

const camera_position = vec3(0.0, 12.0, 40.0);
const camera_target = vec3(0.0, 12.0, 0.0);

pub fn run(init: std.process.Init, window: *glfw.Window, gpu: *GpuContext, max_duration: ?f32) !void {
    _ = window.setKeyCallback(keyHandler);
    _ = window.setFramebufferSizeCallback(framebufferSizeHandler);
    _ = window.setCursorPosCallback(cursorPositionHandler);
    _ = window.setScrollCallback(scrollHandler);

    var alloc_arena = ArenaAllocator.init(init.gpa);
    var temp_alloc_arena = ArenaAllocator.init(init.gpa);

    const context = Context{
        .alloc = alloc_arena.allocator(),
        .temp_alloc = temp_alloc_arena.allocator(),
        .io = init.io,
    };

    const camera = try Camera.init(
        context.alloc,
        .{
            .position = vec3(0.0, 0.0, 5.0),
            .target = vec3(0.0, 0.0, 0.0),
            .scr_width = SCR_WIDTH,
            .scr_height = SCR_HEIGHT,
        },
    );

    state = State{
        .camera = camera,
        .input = Input.init(window),
        .light_postion = vec3(1.2, 1.0, 2.0),
        .delta_time = 0.0,
        .last_frame = 0.0,
        .first_mouse = true,
        .last_x = SCR_WIDTH / 2.0,
        .last_y = SCR_HEIGHT / 2.0,
    };

    // Live and baked animation share these shaders (joints from group 2).
    const shader_path = if (SELECTED_MODEL == .player)
        "examples/animation_example/shaders/player.wgsl"
    else
        "src/core/shaders/pbr.wgsl";
    const shader = try Shader.init(init.io, context.alloc, gpu, shader_path, &MeshPrimitive.vertex_buffer_layouts, .pbr);

    const model_config = blk: {
        for (model_configs) |config| {
            if (config.choice == SELECTED_MODEL) {
                break :blk config;
            }
        }
        @panic("No configuration found for selected model");
    };

    const model_path = model_config.path;
    const model_name = model_config.name;

    log.info("Main: loading model: {s}", .{model_path});

    var gltf_asset = try GltfAsset.init(context, gpu, model_name, model_path);

    log.info("Main: adding custom textures", .{});

    for (model_config.addTextures) |texture_config_item| {
        try gltf_asset.addCustomTexture(
            texture_config_item.mesh_name,
            texture_config_item.uniform_name,
            texture_config_item.texture_path,
            texture_config_item.config,
        );
    }

    gltf_asset.normal_generation_mode = .accurate;

    try gltf_asset.load();

    log.info("gltf_asset.directory: {s}", .{gltf_asset.directory});

    // Apply camera position if specified
    if (model_config.cameraPosition) |cam_pos| {
        state.camera.movement.reset(cam_pos.position, cam_pos.target);
    }

    log.info("Main: loaded gltf asset: {s}", .{model_path});

    // Generate report if enabled
    if (DUMP_REPORT) {
        log.info("Generating glTF report to: {s}", .{REPORT_PATH});
        const GltfReport = core.gltf_report.GltfReport;
        try GltfReport.writeDetailedReportToFile(
            context.io,
            context.alloc,
            gltf_asset,
            REPORT_PATH,
            5,
            5,
        );
        log.info("Report generated successfully", .{});
    }

    log.info("Main: configuring animation", .{});

    const animator = try Animator.init(context, gltf_asset);

    log.info(
        "animation state: active_animations={d}",
        .{animator.active_animations.list.items.len},
    );

    // --- event loop
    state.last_frame = @floatCast(glfw.getTime());
    var frame_counter = FrameCounter.init(init.io);

    const start_time = state.last_frame;

    const clips = &[_]AnimationClip{
        player_clips[0].clip,
        player_clips[1].clip,
        player_clips[2].clip,
        player_clips[3].clip,
        player_clips[4].clip,
    };

    _ = clips;

    const baked_animator = try BakedAnimator.init(
        context,
        gpu,
        animator,
        .{
            .frame_rate = 30.0,
            .capture = .all,
        },
    );

    var model = try ModelInstance.init(
        context.alloc,
        model_name,
        .{ .baked_animator = baked_animator },
        gltf_asset,
    );
    state.model = model;

    try model.playAnimationById(state.animation_index);

    const x_size: usize = 4;
    const y_size: usize = 4;
    const x_offset = @as(f32, @floatFromInt(x_size)) * 12.0 * 0.5;
    const y_offset = @as(f32, @floatFromInt(y_size)) * 12.0 * 0.5;
    // redfish drew these as GL instances (matrices in a buffer texture indexed by
    // gl_InstanceID). Here each placement is its own draw with its own DrawUniforms;
    // instancing comes with port Step 6.
    const instance_count: usize = x_size * y_size;

    const model_transforms = try context.alloc.alloc(Mat4, instance_count);
    var count: usize = 0;
    for (0..x_size) |x| {
        for (0..y_size) |y| {
            const i: f32 = @floatFromInt(x);
            const j: f32 = @floatFromInt(y);
            const translation_matrix = Mat4.fromTranslation(vec3(i * 12.0 - x_offset, 0.0, j * 12.0 - y_offset));
            const mat_model = translation_matrix.mulMat4(&model_config.transform);
            model_transforms[count] = mat_model;
            count += 1;
        }
    }

    log.info("Run starting---", .{});

    while (!window.shouldClose()) {
        glfw.pollEvents();

        _ = temp_alloc_arena.reset(.retain_capacity);

        const currentFrame: f32 = @floatCast(glfw.getTime());
        state.delta_time = currentFrame - state.last_frame;
        state.last_frame = currentFrame;

        if (max_duration) |duration| {
            if (currentFrame - start_time >= duration) {
                log.info("Reached maximum duration of {d} seconds, exiting\n", .{duration});
                break;
            }
        }

        frame_counter.update();
        processKeys();

        if (state.run_animation) {
            try model.updateAnimation(state.delta_time);
        }

        const frame = gpu.beginFrame(CLEAR_COLOR) orelse continue;

        var frame_uniforms = state.camera.getRenderContext(currentFrame).frameUniforms();
        frame_uniforms.light_position = vec3(0.0, 200.0, 0.0);
        frame_uniforms.light_color = vec3(1.0, 1.0, 1.0);
        frame_uniforms.light_intensity = 100.0;
        gpu.writeFrameUniforms(frame_uniforms);

        for (model_transforms) |model_transform| {
            model.draw(&frame, shader, model_transform);
        }

        gpu.endFrame(frame);
    }

    log.info("\nRun completed.\n\n", .{});

    shader.releaseGpuObjects();
    model.cleanUp();
    alloc_arena.deinit();
    temp_alloc_arena.deinit();
}

fn keyHandler(
    window: *glfw.Window,
    key: glfw.Key,
    scancode: i32,
    action: glfw.Action,
    mods: glfw.Mods,
) callconv(.c) void {
    _ = scancode;
    state.input.handleKey(key, action, mods);
    if (key == .escape) {
        window.setShouldClose(true);
    }
}

pub fn processKeys() void {
    var iterator = state.input.key_presses.iterator();
    while (iterator.next()) |k| {
        switch (k) {
            .t => log.info("time: {d}\n", .{state.delta_time}),
            .w => {
                state.camera.movement.processMovement(.forward, state.delta_time);
            },
            .s => {
                state.camera.movement.processMovement(.backward, state.delta_time);
            },
            .a => {
                state.camera.movement.processMovement(.circle_left, state.delta_time);
            },
            .d => {
                state.camera.movement.processMovement(.circle_right, state.delta_time);
            },
            else => {},
        }

        // One-shot keys: fire once per press
        if (state.input.key_processed.contains(k)) {
            continue;
        }
        state.input.key_processed.insert(k);

        switch (k) {
            .n => {
                // if (!state.input.key_processed.contains(.n)) {
                if (state.baked) {
                    switch (state.model.animator_impl) {
                        .baked_animator => |baked| {
                            state.animation_index += 1;
                            if (state.animation_index >= baked.headers.len) {
                                state.animation_index = 0;
                            }
                            baked.playAnimationById(state.animation_index);
                            log.info("animation: {d}", .{state.animation_index});
                        },
                        else => {},
                    }
                }
                // else if (SELECTED_MODEL == .player) {
                // state.animation_index = (state.animation_index + 1) % player_clips.len;
                // const current_clip = player_clips[state.animation_index];
                // log.info("Switching to animation clip: {s} (start: {d:.3}, end: {d:.3})\n", .{ current_clip.name, current_clip.clip.start_time, current_clip.clip.end_time });
                // state.model.playClip(current_clip.clip) catch |err| {
                // log.info("Failed to play animation clip: {}\n", .{err});
                // };
                // }
                // }
            },
            .space => {
                state.run_animation = !state.run_animation;
                log.debug("run_animation: {any}", .{state.run_animation});
            },
            else => {},
        }
        state.input.key_processed.insert(k);
    }
}

/// The surface follows the framebuffer size in `GpuContext.beginFrame`; keep the camera
/// aspect in step.
fn framebufferSizeHandler(window: *glfw.Window, width: i32, height: i32) callconv(.c) void {
    _ = window;
    if (width == 0 or height == 0) return;
    state.camera.setScreenDimensions(@floatFromInt(width), @floatFromInt(height));
}

fn mouseHander(
    window: *glfw.Window,
    button: glfw.MouseButton,
    action: glfw.Action,
    mods: glfw.Mods,
) callconv(.c) void {
    _ = window;
    _ = button;
    _ = action;
    _ = mods;
}

fn cursorPositionHandler(window: *glfw.Window, xposIn: f64, yposIn: f64) callconv(.c) void {
    _ = window;
    var xpos: f32 = @floatCast(xposIn);
    var ypos: f32 = @floatCast(yposIn);

    xpos = if (xpos < 0) 0 else if (xpos < state.scr_width) xpos else state.scr_width;
    ypos = if (ypos < 0) 0 else if (ypos < state.scr_height) ypos else state.scr_height;

    if (state.first_mouse) {
        state.last_x = xpos;
        state.last_y = ypos;
        state.first_mouse = false;
    }

    // const xoffset = xpos - state.last_x;
    // const yoffset = state.last_y - ypos; // reversed since y-coordinates go from bottom to top

    state.last_x = xpos;
    state.last_y = ypos;

    // Mouse movement disabled for now
}

fn scrollHandler(window: *Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = window;
    _ = xoffset;
    state.camera.adjustFov(@floatCast(yoffset));
}
