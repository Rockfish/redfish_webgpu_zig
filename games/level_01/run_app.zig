const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");
const nodes = @import("nodes.zig");
const shapes = core.shapes;

const state_ = @import("state.zig");
const State = state_.State;

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Ray = core.Ray;
const AABB = core.AABB;

const EnumSet = std.EnumSet;

const Arenas = core.Arenas;
const DrawUniforms = core.DrawUniforms;
const Frame = core.Frame;
const GltfAsset = core.gltf_asset.GltfAsset;
const GpuContext = core.GpuContext;
const MeshPrimitive = core.MeshPrimitive;
const Shader = core.Shader;
const Shape = shapes.Shape;
const Texture = core.texture.Texture;
const TextureConfig = core.texture.TextureConfig;
const Camera = core.Camera;
const srgbToLinear = core.colors.srgbToLinear;

const SCR_WIDTH: f32 = 1000.0;
const SCR_HEIGHT: f32 = 1000.0;

/// redfish's GL clear color, converted so it looks the same on the sRGB surface.
const CLEAR_COLOR = [4]f64{ srgbToLinear(0.1), srgbToLinear(0.3), srgbToLinear(0.1), 1.0 };
const NO_HIT = vec4(0.0, 0.0, 0.0, 0.0);
/// Units per second the scene moves toward a clicked point.
const CLICK_MOVE_SPEED: f32 = 20.0;
const HIT = vec4(1.0, 0.0, 0.0, 0.0);

// Wrapper types for objects that implement the Node interface
const EmptyObject = struct {
    pub fn draw(self: *EmptyObject, frame: *const Frame, shader: *const Shader, draw_uniforms: DrawUniforms) void {
        _ = self;
        _ = frame;
        _ = shader;
        _ = draw_uniforms;
    }
};

const ShapeWithTexture = struct {
    shape: *Shape,
    texture: *Texture,

    pub fn draw(self: *ShapeWithTexture, frame: *const Frame, shader: *const Shader, draw_uniforms: DrawUniforms) void {
        self.texture.bind(frame);
        self.shape.draw(frame, shader, draw_uniforms);
    }

    pub fn getBoundingBox(self: *ShapeWithTexture) AABB {
        return self.shape.aabb;
    }
};

/// The model draws with its own PBR shader, not the node shader.
const ModelWrapper = struct {
    model: *core.Model,
    shader: *const Shader,

    pub fn draw(self: *ModelWrapper, frame: *const Frame, node_shader: *const Shader, draw_uniforms: DrawUniforms) void {
        _ = node_shader;
        self.model.draw(frame, self.shader, draw_uniforms.model);
    }

    pub fn updateAnimation(self: *ModelWrapper, delta_time: f32) !void {
        try self.model.updateAnimation(delta_time);
    }
};

pub fn run(init: std.process.Init, window: *glfw.Window, gpu: *GpuContext) !void {
    var arenas = try Arenas.init(init.gpa);
    defer arenas.deinit();

    const context = arenas.context(init.io);

    state_.initWindowHandlers(window);

    const window_scale = window.getContentScale();

    const viewport_width = SCR_WIDTH * window_scale[0];
    const viewport_height = SCR_HEIGHT * window_scale[1];
    const scaled_width = viewport_width / window_scale[0];
    const scaled_height = viewport_height / window_scale[1];

    const camera = try Camera.init(
        context.alloc,
        .{
            .position = vec3(0.0, 4.0, 20.0),
            .target = vec3(0.0, 2.0, 0.0),
            .scr_width = scaled_width,
            .scr_height = scaled_height,
        },
    );
    defer camera.deinit();

    state_.state = state_.State{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .scaled_width = scaled_width,
        .scaled_height = scaled_height,
        .window_scale = window_scale,
        .camera = camera,
        .light_postion = vec3(1.2, 1.0, 2.0),
        .delta_time = 0.0,
        .total_time = 0.0,
        .world_point = null,
        .current_position = vec3(0.0, 0.0, 0.0),
        .target_position = vec3(0.0, 0.0, 0.0),
        .input = .{
            .first_mouse = true,
            .mouse_x = scaled_width / 2.0,
            .mouse_y = scaled_height / 2.0,
            .key_presses = EnumSet(glfw.Key).initEmpty(),
        },
    };

    const state = &state_.state;

    var node_manager = try nodes.NodeManager.init(context.alloc);

    const basic_shader = try Shader.init(
        init.io,
        context.alloc,
        gpu,
        "games/level_01/shaders/basic_model.wgsl",
        .{ .vertex_buffers = &Shape.vertex_buffer_layouts, .material = .texture },
    );
    defer basic_shader.releaseGpuObjects();

    // redfish's animated_pbr is the core PBR shader.
    const model_shader = try Shader.init(
        init.io,
        context.alloc,
        gpu,
        "src/core/shaders/pbr.wgsl",
        .{ .vertex_buffers = &MeshPrimitive.vertex_buffer_layouts, .material = .pbr, .alpha_to_coverage = true },
    );
    defer model_shader.releaseGpuObjects();

    const cubeboid = try shapes.createCube(
        context.alloc,
        gpu,
        .{
            .width = 1.0,
            .height = 1.0,
            .depth = 2.0,
        },
    );
    defer cubeboid.releaseGpuObjects();

    const floor = try shapes.createCube(
        context.alloc,
        gpu,
        .{
            .width = 100.0,
            .height = 2.0,
            .depth = 100.0,
            .num_tiles_x = 50.0,
            .num_tiles_y = 1.0,
            .num_tiles_z = 50.0,
        },
    );
    defer floor.releaseGpuObjects();

    const cylinder = try shapes.createCylinder(
        context.alloc,
        gpu,
        1.0,
        4.0,
        20,
    );
    defer cylinder.releaseGpuObjects();

    const sphere = try shapes.createSphere(context.alloc, gpu, 1.0, 20, 20);
    defer sphere.releaseGpuObjects();

    const texture_config = TextureConfig{
        .filter = .Linear,
        .flip_v = false,
        .is_srgb = true,
        .wrap = .Repeat,
    };

    const cube_texture = try Texture.initFromFile(
        context,
        gpu,
        "assets/textures/container.jpg",
        texture_config,
    );
    defer cube_texture.releaseGpuObjects();

    const surface_texture = try Texture.initFromFile(
        context,
        gpu,
        "assets/textures/Floor/Floor D.png",
        texture_config,
    );
    defer surface_texture.releaseGpuObjects();

    const model_path = "assets/modular_characters/Individual Characters/glTF/Spacesuit.gltf";
    std.debug.print("Loading model: {s}\n", .{model_path});
    var gltf_asset = try GltfAsset.init(context, gpu, "alien", model_path);
    try gltf_asset.load();
    var model = try gltf_asset.buildModel();
    defer model.cleanUp();

    var empty_obj = EmptyObject{};

    var cube_obj = ShapeWithTexture{ .shape = cubeboid, .texture = cube_texture };
    var cylinder_obj = ShapeWithTexture{ .shape = cylinder, .texture = cube_texture };
    var sphere_obj = ShapeWithTexture{ .shape = sphere, .texture = cube_texture };
    var model_obj = ModelWrapper{ .model = model, .shader = model_shader };

    const root_node = try node_manager.create("root_node", &empty_obj);

    const model_node = try nodes.Node.init(context.alloc, "robot", &model_obj);

    try model.animator.playAnimationById(23); // 23 is wave, 4 is idle
    model_node.setTranslation(vec3(5.0, 0.0, 5.0));
    model_node.setScale(vec3(2.0, 2.0, 2.0));

    const node_cylinder = try node_manager.create("shape_cylinder", &cylinder_obj);
    const node_sphere = try node_manager.create("shpere_shape", &sphere_obj);

    node_sphere.setTranslation(vec3(-3.0, 1.0, 3.0));

    try root_node.addChild(node_cylinder);

    const cube_positions = [_]Vec3{
        vec3(3.0, 0.5, 0.0),
        vec3(1.5, 0.5, 0.0),
        vec3(0.0, 0.5, 0.0),
        vec3(-1.5, 0.5, 0.0),
        vec3(-3.0, 0.5, 0.0),
    };

    for (cube_positions) |position| {
        const cube = try node_manager.create("cube_shape", &cube_obj);
        cube.setTranslation(position);
        try root_node.addChild(cube);

        const fix_cube = try node_manager.create("cube_shape", &cube_obj);
        fix_cube.setTranslation(position);
    }

    const node_cube_spin = try node_manager.create("spin_cube", &cube_obj);

    node_cube_spin.setTranslation(vec3(0.0, 6.0, 0.0));
    try node_cylinder.addChild(node_cube_spin);

    const xz_plane_point = vec3(0.0, 0.0, 0.0);
    const xz_plane_normal = vec3(0.0, 1.0, 0.0);

    const barrel = try shapes.loadOBJ(
        init.io,
        context.alloc,
        gpu,
        "assets/modular_ruins/OBJ/Barrel.obj",
    );
    defer barrel.releaseGpuObjects();

    // draw loop
    // -----------
    while (!window.shouldClose()) {
        glfw.pollEvents();

        const current_time: f32 = @floatCast(glfw.getTime());
        state.delta_time = current_time - state.total_time;
        state.total_time = current_time;

        state_.processKeys();

        const world_ray = math.getWorldRayFromMouse(
            state.scaled_width,
            state.scaled_height,
            &state.camera.getProjection(),
            &state.camera.getView(),
            state.input.mouse_x,
            state.input.mouse_y,
        );

        state.world_point = math.getRayPlaneIntersection(
            world_ray.origin,
            world_ray.direction,
            xz_plane_point,
            xz_plane_normal,
        );

        const ray = Ray{
            .origin = world_ray.origin,
            .direction = world_ray.direction,
        };

        if (state.input.mouse_left_button and state.world_point != null) {
            state.target_position = state.world_point.?;
        }

        // Glide to the clicked point; stays put once there
        state.current_position = core.motion.moveToward(
            state.current_position,
            state.target_position,
            CLICK_MOVE_SPEED,
            state.delta_time,
        );

        model_node.updateAnimation(state.delta_time);

        root_node.setTranslation(state.current_position);

        updateSpin(node_cylinder, state);
        root_node.updateTransforms(null);

        const picked_id = pickNode(node_manager, ray);

        const frame = gpu.beginFrame(CLEAR_COLOR) orelse continue;
        gpu.writeFrameUniforms(frameUniforms(state));

        model_node.draw(&frame, basic_shader, NO_HIT);

        for (node_manager.node_list.list.items, 0..) |n, id| {
            const is_hit = picked_id != null and picked_id.? == id;
            n.draw(&frame, basic_shader, if (is_hit) HIT else NO_HIT);
        }

        const floor_transform = Mat4.fromTranslation(vec3(0.0, -1.0, 0.0));
        surface_texture.bind(&frame);
        floor.draw(&frame, basic_shader, DrawUniforms.init(floor_transform, NO_HIT));

        if (state.spin) {
            state.camera.movement.processMovement(.circle_right, state.delta_time * 1.0);
        }

        // redfish drew the barrel with its vertex colors (hasTexture off).
        const barrel_transform = Mat4.fromTranslation(vec3(-4.0, 1.0, 5.0));
        var barrel_uniforms = DrawUniforms.init(barrel_transform, NO_HIT);
        barrel_uniforms.flags |= core.bindings.DrawFlags.vertex_color;
        barrel.draw(&frame, basic_shader, barrel_uniforms);

        gpu.endFrame(frame);
    }
}

/// Index in the node list of the nearest node the mouse ray hits.
fn pickNode(node_manager: *const nodes.NodeManager, ray: Ray) ?usize {
    var picked_id: ?usize = null;
    var picked_distance: f32 = std.math.inf(f32);

    for (node_manager.node_list.list.items, 0..) |n, id| {
        if (n.getBoundingBox()) |aabb| {
            const box = aabb.transform(&n.global_transform.toMatrix());
            if (box.rayIntersects(ray)) |distance| {
                if (distance < picked_distance) {
                    picked_id = id;
                    picked_distance = distance;
                }
            }
        }
    }
    return picked_id;
}

fn frameUniforms(st: *State) core.bindings.FrameUniforms {
    var uniforms = st.camera.getRenderContext(st.total_time).frameUniforms();
    uniforms.lights = modelLights().uniforms();
    return uniforms;
}

/// For the PBR model (demo_app's light). redfish set a light color and direction the
/// PBR shader didn't read, and never set its light position or intensity, so the
/// model got only the shader's fixed 0.15 ambient. The basic shader is unlit.
fn modelLights() core.SceneLights {
    var lights = core.SceneLights.init();
    lights.ambient = vec3(0.15, 0.15, 0.15);
    lights.direction_light.color = vec3(0.0, 0.0, 0.0);
    lights.setPointLight(0, .{
        .world_pos = vec3(50.0, 50.0, 50.0),
        .color = vec3(100.0, 100.0, 100.0),
        .constant = 1.0,
        .linear = 0.01,
        .quadratic = 0.001,
        .enabled = true,
    });
    return lights;
}

pub fn updateSpin(node: *nodes.Node, st: *const State) void {
    const up = vec3(0.0, 1.0, 0.0);
    const velocity: f32 = 5.0 * st.delta_time;
    const angle = math.degreesToRadians(velocity);
    const turn_rotation = Quat.fromAxisAngle(up, angle);
    node.transform.rotation = node.transform.rotation.mulQuat(turn_rotation);
}
