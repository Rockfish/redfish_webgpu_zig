const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");
const world = @import("state.zig");

const ArenaAllocator = std.heap.ArenaAllocator;

const ManagedArrayList = containers.ManagedArrayList;
const EnumSet = std.EnumSet;

const Vec3 = math.Vec3;
const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;

const Context = core.Context;
const DrawUniforms = core.DrawUniforms;
const GpuContext = core.GpuContext;
const MeshPrimitive = core.MeshPrimitive;
const OverrideConstant = core.pipeline.OverrideConstant;
const SceneLights = core.SceneLights;
const ShadowMap = core.ShadowMap;
const Shape = core.shapes.Shape;
const State = world.State;
const CameraType = world.CameraType;
const Player = @import("player.zig").Player;
const Enemy = @import("enemy.zig").Enemy;
const EnemySystem = @import("enemy.zig").EnemySystem;
const bullet_system_ = @import("bullet_system.zig");
const BulletSystem = bullet_system_.BulletSystem;
const BurnMarks = @import("burn_marks.zig").BurnMarks;
const MuzzleFlash = @import("muzzle_flash.zig").MuzzleFlash;
const Floor = @import("floor.zig").Floor;
const fb = @import("framebuffers.zig");
const quads = @import("quads.zig");

const Camera = core.Camera;
const Shader = core.Shader;
const SoundEngine = core.SoundEngine;

const log = std.log.scoped(.run_app);

const Window = glfw.Window;

const VIEW_PORT_WIDTH: f32 = 1500.0;
const VIEW_PORT_HEIGHT: f32 = 1000.0;

// Lighting
const LIGHT_FACTOR: f32 = 0.8;
const NON_BLUE: f32 = 0.9;

// angrybot shades in gamma space, as redfish's GL did (no sRGB textures or surface): its
// lighting, bloom, and composite constants were tuned for that. Textures load unconverted,
// the render targets hold gamma-space values, and the composite decodes them once, so the
// sRGB surface shows what GL showed. See docs/designs/009-angrybot.md.

/// redfish's clear colors, gamma space like the targets. The window is covered by the
/// composite, so only the scene target's shows.
const SCENE_CLEAR_COLOR = [4]f64{ 0.0, 0.02, 0.25, 1.0 };
const EMISSION_CLEAR_COLOR = [4]f64{ 0.0, 0.0, 0.0, 0.0 };
const WINDOW_CLEAR_COLOR = [4]f64{ 0.1, 0.1, 0.1, 1.0 };

const WHITE = vec4(1.0, 1.0, 1.0, 1.0);

var state: State = undefined;

pub fn run(init: std.process.Init, window: *glfw.Window, gpu: *GpuContext) !void {
    var alloc_arena = ArenaAllocator.init(init.gpa);
    var temp_alloc_arena = ArenaAllocator.init(init.gpa);

    // note: defer occurs in reverse order so these should be the last to run
    defer {
        log.debug("Deinitializing game arenas", .{});
        alloc_arena.deinit();
        temp_alloc_arena.deinit();
    }

    const context = Context{
        .alloc = alloc_arena.allocator(),
        .temp_alloc = temp_alloc_arena.allocator(),
        .io = init.io,
    };

    const cwd = try std.process.currentPathAlloc(init.io, context.alloc);
    log.info("Running game. exe_dir = {s} ", .{cwd});

    world.initStateHandlers(window, &state);

    // Shaders. redfish drew the shadow and emission passes with the lit shaders and
    // uniform switches; here those are pipelines of the same file with override
    // constants (see player_shader.wgsl). Everything before the composite draws into
    // rgba16float render targets.
    const render_target: core.pipeline.ColorTarget = .{ .format = core.texture.hdr_format };
    const mesh_layouts = &MeshPrimitive.vertex_buffer_layouts;
    const shape_layouts = &Shape.vertex_buffer_layouts;

    const player_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/player_shader.wgsl", .{
        .vertex_buffers = mesh_layouts,
        .material = .pbr,
        .pass = .shadow,
        .color_target = render_target,
        .constants = &.{ enabled("USE_EMISSIVE"), enabled("USE_POINT_LIGHT") },
    });
    // Its fragment stage references the shadow map, so it binds group 3 too.
    const player_emissive_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/player_shader.wgsl", .{
        .vertex_buffers = mesh_layouts,
        .material = .pbr,
        .pass = .shadow,
        .color_target = render_target,
        .constants = &.{enabled("EMISSIVE_ONLY")},
    });
    const player_shadow_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/player_shader.wgsl", .{
        .vertex_buffers = mesh_layouts,
        .material = .pbr,
        .color_target = .none,
        .constants = &.{enabled("DEPTH_MODE")},
    });

    const enemy_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/player_shader.wgsl", .{
        .vertex_buffers = mesh_layouts,
        .material = .pbr,
        .pass = .shadow,
        .color_target = render_target,
        .constants = &.{enabled("WIGGLE")},
    });
    const enemy_shadow_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/player_shader.wgsl", .{
        .vertex_buffers = mesh_layouts,
        .material = .pbr,
        .color_target = .none,
        .constants = &.{ enabled("WIGGLE"), enabled("DEPTH_MODE") },
    });

    const floor_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/floor_shader.wgsl", .{
        .vertex_buffers = shape_layouts,
        .material = .pbr,
        .pass = .shadow,
        .color_target = render_target,
    });

    // The floor as a depth-only occluder in the emission pass (the original's glColorMask off)
    const floor_depth_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/floor_shader.wgsl", .{
        .vertex_buffers = shape_layouts,
        .material = .pbr,
        .pass = .shadow,
        .color_target = render_target,
        .color_writes = false,
    });

    // bullets - instanced quaternion rotations and positions
    const instanced_matrix_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/instanced_quat.wgsl", .{
        .vertex_buffers = &bullet_system_.vertex_buffer_layouts,
        .material = .texture,
        .color_target = render_target,
    });
    // muzzle flash, bullet impacts
    const sprite_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/sprite_shader.wgsl", .{
        .vertex_buffers = shape_layouts,
        .material = .texture,
        .color_target = render_target,
    });
    // burn marks
    const basic_texture_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/basic_texture_shader.wgsl", .{
        .vertex_buffers = shape_layouts,
        .material = .texture,
        .color_target = render_target,
    });

    // blur and scene
    const blur_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/blur_shader.wgsl", .{
        .vertex_buffers = shape_layouts,
        .material = .texture,
        .color_target = render_target,
        .depth = false,
    });
    const scene_draw_shader = try Shader.init(context.io, context.alloc, gpu, "games/angrybot/shaders/texture_merge_shader.wgsl", .{
        .vertex_buffers = shape_layouts,
        .material = .pbr,
        .depth = false,
    });

    defer player_shader.releaseGpuObjects();
    defer player_emissive_shader.releaseGpuObjects();
    defer player_shadow_shader.releaseGpuObjects();
    defer enemy_shader.releaseGpuObjects();
    defer enemy_shadow_shader.releaseGpuObjects();
    defer floor_shader.releaseGpuObjects();
    defer floor_depth_shader.releaseGpuObjects();
    defer instanced_matrix_shader.releaseGpuObjects();
    defer sprite_shader.releaseGpuObjects();
    defer basic_texture_shader.releaseGpuObjects();
    defer blur_shader.releaseGpuObjects();
    defer scene_draw_shader.releaseGpuObjects();

    log.info("games/angrybot/shaders loaded", .{});

    // --- Lighting ---
    const player_light_dir = vec3(-1.0, -1.0, -1.0).toNormalized();
    const muzzle_point_light_color = vec3(1.0, 0.2, 0.0);

    const light_color = vec3(NON_BLUE * 0.406, NON_BLUE * 0.723, 1.0).mulScalar(LIGHT_FACTOR * 1.0);
    const ambient_color = vec3(NON_BLUE * 0.7, NON_BLUE * 0.7, 0.7).mulScalar(LIGHT_FACTOR * 0.10);
    // The floor's light (floor_light_dir / _color, floor_ambient_color) is in floor_shader.wgsl.

    const window_scale = window.getContentScale();

    const viewport_width = VIEW_PORT_WIDTH * window_scale[0];
    const viewport_height = VIEW_PORT_HEIGHT * window_scale[1];
    const scaled_width = viewport_width / window_scale[0];
    const scaled_height = viewport_height / window_scale[1];

    // -- Framebuffers ---

    var shadow_map = ShadowMap.init(gpu, fb.SHADOW_SIZE);
    defer shadow_map.releaseGpuObjects();

    var frame_buffers = try fb.FrameBuffers.init(context.alloc, gpu);
    defer frame_buffers.releaseGpuObjects();

    log.info("framebuffers loaded", .{});
    // --- quads ---

    const unit_square = try quads.createUnitSquare(context.alloc, gpu);
    defer unit_square.releaseGpuObjects();
    const fullscreen_quad = try quads.createFullscreenQuad(context.alloc, gpu);
    defer fullscreen_quad.releaseGpuObjects();

    log.info("quads loaded", .{});

    // --- Cameras ---

    const camera_follow_vec = vec3(2.0, 4.3, 4.0);

    const game_camera = try Camera.init(
        context.alloc,
        .{
            .position = camera_follow_vec,
            .target = vec3(0.0, 0.0, 0.0),
            .scr_width = VIEW_PORT_WIDTH,
            .scr_height = VIEW_PORT_HEIGHT,
        },
    );

    // Side camera
    const floating_camera = try Camera.init(
        context.alloc,
        .{
            .position = vec3(0.0, 0.5, 5.0),
            .target = vec3(0.0, 0.0, 0.0),
            .scr_width = VIEW_PORT_WIDTH,
            .scr_height = VIEW_PORT_HEIGHT,
        },
    );

    // top camera
    const ortho_camera = try Camera.init(
        context.alloc,
        .{
            .position = vec3(0.0, 5.0, 0.0),
            .target = vec3(0.0, 0.0, 0.0),
            .scr_width = VIEW_PORT_WIDTH,
            .scr_height = VIEW_PORT_HEIGHT,
        },
    );

    log.info("camers loaded", .{});

    // Models and systems
    var player = try Player.init(context, gpu);
    defer player.cleanUp();
    var enemy_system = try EnemySystem.init(context, gpu);
    defer enemy_system.cleanUp();
    var muzzle_flash = try MuzzleFlash.init(context, gpu, unit_square);
    defer muzzle_flash.releaseGpuObjects();
    var bullet_system = try BulletSystem.init(context, gpu, unit_square);
    defer bullet_system.releaseGpuObjects();
    var floor = try Floor.init(context, gpu);
    defer floor.releaseGpuObjects();
    const burn_marks = try BurnMarks.init(context, gpu, unit_square);
    defer burn_marks.releaseGpuObjects();

    log.info("models loaded", .{});

    const clips = [2]world.ClipData{
        .{ .clip = .Explosion, .file = "assets/angrybots_assets/Audio/Enemy_SFX/enemy_Spider_DestroyedExplosion.wav" },
        .{ .clip = .GunFire, .file = "assets/angrybots_assets/Audio/Player_SFX/player_shooting_one.wav" },
    };

    var sound_engine = try SoundEngine(world.ClipName, world.ClipData).init(
        context.alloc,
        &clips,
    );
    defer {
        log.debug("Deinitializing sound engine", .{});
        sound_engine.deinit();
    }

    // Initialize the world state
    state = State{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .scaled_width = scaled_width,
        .scaled_height = scaled_height,
        .window_scale = window_scale,
        .game_camera = game_camera,
        .floating_camera = floating_camera,
        .ortho_camera = ortho_camera,
        .active_camera = game_camera,
        .player = player,
        .enemies = ManagedArrayList(?Enemy).init(context.alloc),
        .light_postion = vec3(1.2, 1.0, 2.0),
        .delta_time = 0.0,
        .frame_time = 0.0,
        .first_mouse = true,
        .last_x = VIEW_PORT_WIDTH / 2.0,
        .last_y = VIEW_PORT_HEIGHT / 2.0,
        .mouse_x = VIEW_PORT_WIDTH / 2.0,
        .mouse_y = VIEW_PORT_HEIGHT / 2.0,
        .burn_marks = burn_marks,
        .sound_engine = sound_engine,
        .run = true,
        .input = .{
            .first_mouse = true,
            .mouse_x = scaled_width / 2.0,
            .mouse_y = scaled_height / 2.0,
            .key_presses = EnumSet(glfw.Key).initEmpty(),
        },
    };

    log.info("state.viewport_width: {d}", .{state.viewport_width});
    log.info("state.viewport_height: {d}", .{state.viewport_height});
    log.info("state.mouse_x: {d}", .{state.mouse_x});
    log.info("state.mouse_y: {d}", .{state.mouse_y});

    var aim_angle: f32 = 0.0;

    // --- event loop
    state.frame_time = @floatCast(glfw.getTime());
    var frame_counter = core.FrameCounter.init(init.io);

    log.info("Starting game loop!", .{});

    while (!window.shouldClose()) {
        glfw.pollEvents();

        frame_counter.update();

        const currentFrame: f32 = @floatCast(glfw.getTime());
        if (state.run) {
            state.delta_time = currentFrame - state.frame_time;
        } else {
            state.delta_time = 0.0;
        }
        state.frame_time = currentFrame;

        world.processInput();

        const p = state.player.position;
        state.game_camera.reset(
            state.player.position.add(camera_follow_vec),
            state.player.position,
        );
        state.floating_camera.reset(
            vec3(p.x, 0.5, p.z + 4.0),
            state.player.position,
        );
        state.ortho_camera.reset(
            vec3(p.x, 4.0, p.z),
            state.player.position,
        );

        if (player.is_alive) {
            aim_angle = world.getMousePointAngle(&state.game_camera.getView(), &state.player.position);
        }

        const aim_rotation_matrix = Mat4.fromAxisAngle(vec3(0.0, 1.0, 0.0), aim_angle);

        const player_scale = Vec3.splat(world.PLAYER_MODEL_SCALE);
        var scale_mat4 = Mat4.fromScale(player_scale);

        var player_transform = Mat4.fromTranslation(player.position);
        player_transform = player_transform.mulMat4(&scale_mat4);

        if (player.is_alive) {
            player_transform = player_transform.mulMat4(&aim_rotation_matrix);
        }

        const projectile_spawn_point = player.getMuzzlePosition(&player_transform);

        if (player.is_alive and player.is_trying_to_fire and (player.last_fire_time + world.FIRE_INTERVAL) < state.frame_time) {
            player.last_fire_time = state.frame_time;
            if (try bullet_system.createBullets(aim_angle, projectile_spawn_point)) {
                try muzzle_flash.addFlash();
                state.sound_engine.playSound(.GunFire);
            }
        }

        muzzle_flash.update(state.delta_time);

        try bullet_system.updateBullets(&state);

        if (player.is_alive) {
            try enemy_system.update(&state);
            enemy_system.chasePlayer(&state);
        }

        try player.update(&state, aim_angle);

        // The flash and its light follow the animated gun (after player.update)
        var use_point_light = false;
        var muzzle_transform = Mat4.Identity;
        var muzzle_world_position = Vec3.Zero;

        if (muzzle_flash.muzzle_flash_sprites_age.list.items.len != 0) {
            muzzle_transform = player.getMuzzleTransform(&player_transform);
            muzzle_world_position = muzzle_transform.mulVec4(vec4(0.0, 0.0, 0.0, 1.0)).xyz();
            const min_age = muzzle_flash.getMinAge();
            use_point_light = min_age < 0.03;
        }

        const near_plane: f32 = 1.0;
        const far_plane: f32 = 50.0;
        const ortho_size: f32 = 10.0;

        // Zero-to-one depth, as the shadow map stores it
        const light_projection = Mat4.orthographicRhZo(-ortho_size, ortho_size, -ortho_size, ortho_size, near_plane, far_plane);
        const light_view = Mat4.lookAtRhGl(player.position.sub(player_light_dir.mulScalar(20)), player.position, Vec3.World_Up);
        const light_space_matrix = light_projection.mulMat4(&light_view);

        // The player's and enemies' lights (redfish set them as shader uniforms); the
        // muzzle light also lights the floor
        var lights = SceneLights.init();
        lights.direction_light = .{ .dir = player_light_dir, .color = light_color };
        lights.ambient = ambient_color;
        if (use_point_light) {
            lights.setPointLight(0, .{ .world_pos = muzzle_world_position, .color = muzzle_point_light_color, .enabled = true });
        }

        // Render after the game update, as redfish; skip the drawing while the window is hidden
        var frame = gpu.acquireFrame() orelse continue;
        try frame_buffers.update(gpu);

        const ctx = state.active_camera.getRenderContext(state.frame_time);
        var frame_uniforms = ctx.frameUniforms();
        frame_uniforms.lights = lights.uniforms();
        frame_uniforms.light_space = light_space_matrix;
        gpu.writeFrameUniforms(frame_uniforms);

        //
        // shadows - write to the shadow map
        //
        frame.beginPass(shadow_map.passTarget());
        player.draw(&frame, player_shadow_shader, player_transform);
        enemy_system.drawEnemies(&frame, enemy_shadow_shader, &state);
        frame.endPass();

        //
        // emission - the bright parts that bloom
        //
        frame.beginPass(fb.FrameBuffers.passTarget(gpu, frame_buffers.emission, "emission pass", EMISSION_CLEAR_COLOR, true));
        shadow_map.bind(&frame);
        player.draw(&frame, player_emissive_shader, player_transform);
        // Depth only: bullets that dipped below the floor don't glow through it
        floor.draw(&frame, floor_depth_shader);
        bullet_system.drawBullets(&frame, instanced_matrix_shader);
        frame.endPass();

        //
        // scene - reads the shadow map
        //
        frame.beginPass(fb.FrameBuffers.passTarget(gpu, frame_buffers.scene, "scene pass", SCENE_CLEAR_COLOR, true));
        shadow_map.bind(&frame);

        floor.draw(&frame, floor_shader);
        player.draw(&frame, player_shader, player_transform);
        muzzle_flash.draw(&frame, sprite_shader, muzzle_transform, aim_angle);
        enemy_system.drawEnemies(&frame, enemy_shader, &state);
        state.burn_marks.drawMarks(&frame, basic_texture_shader, state.delta_time);
        bullet_system.drawBulletImpacts(&frame, sprite_shader);
        frame.endPass();

        //
        // blur the emission at half size, then combine it with the scene in the window
        //
        frame.beginPass(fb.FrameBuffers.passTarget(gpu, frame_buffers.horizontal_blur, "horizontal blur pass", EMISSION_CLEAR_COLOR, false));
        frame_buffers.emission.bind(&frame);
        fullscreen_quad.draw(&frame, blur_shader, blurUniforms(true));
        frame.endPass();

        frame.beginPass(fb.FrameBuffers.passTarget(gpu, frame_buffers.vertical_blur, "vertical blur pass", EMISSION_CLEAR_COLOR, false));
        frame_buffers.horizontal_blur.bind(&frame);
        fullscreen_quad.draw(&frame, blur_shader, blurUniforms(false));
        frame.endPass();

        frame.beginPass(.{ .label = "composite pass", .color = frame.color_view, .clear_color = WINDOW_CLEAR_COLOR });
        frame_buffers.composite.bind(&frame);
        fullscreen_quad.draw(&frame, scene_draw_shader, DrawUniforms.init(Mat4.Identity, WHITE));

        gpu.endFrame(frame);
    }

    log.info("Run completed.", .{});
}

fn enabled(comptime key: []const u8) OverrideConstant {
    return .{ .key = key, .value = 1.0 };
}

/// blur_shader's direction: params.x is 1 for horizontal.
fn blurUniforms(horizontal: bool) DrawUniforms {
    var draw_uniforms = DrawUniforms.init(Mat4.Identity, WHITE);
    draw_uniforms.params = vec4(if (horizontal) 1.0 else 0.0, 0.0, 0.0, 0.0);
    return draw_uniforms;
}
