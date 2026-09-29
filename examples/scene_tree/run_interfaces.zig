const std = @import("std");
const glfw = @import("zglfw");
const core = @import("core");
const math = @import("math");
const nodes_ = @import("nodes_interfaces.zig");

const State = @import("main.zig").State;
const main = @import("main.zig");
const shapes = core.shapes;

const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Ray = core.Ray;

const Arenas = core.Arenas;
const Context = core.Context;
const Frame = core.Frame;
const DrawUniforms = core.DrawUniforms;
const GltfAsset = core.gltf_asset.GltfAsset;
const Model = core.Model;
const MeshPrimitive = core.MeshPrimitive;
const GpuContext = core.GpuContext;
const Shader = core.Shader;
const Shape = shapes.Shape;
const Texture = core.texture.Texture;
const TextureConfig = core.texture.TextureConfig;
const TextureWrap = core.texture.TextureWrap;
const Node = nodes_.Node;
const Camera = core.Camera;
const srgbToLinear = core.colors.srgbToLinear;

/// redfish's GL clear color, converted so it looks the same on the sRGB surface.
const CLEAR_COLOR = [4]f64{ srgbToLinear(0.1), srgbToLinear(0.3), srgbToLinear(0.1), 1.0 };
const NO_HIT = vec4(0.0, 0.0, 0.0, 0.0);
const HIT = vec4(1.0, 0.0, 0.0, 0.0);

/// Scene nodes share scene_tree's unlit shader; the model node draws with PBR instead.
const ModelObj = struct {
    model: *Model,
    shader: *const Shader,

    pub fn draw(self: *ModelObj, frame: *const Frame, node_shader: *const Shader, draw_uniforms: DrawUniforms) void {
        _ = node_shader;
        self.model.draw(frame, self.shader, draw_uniforms.model);
    }

    pub fn updateAnimation(self: *ModelObj, delta_time: f32) !void {
        try self.model.updateAnimation(delta_time);
    }
};

pub fn run(init: std.process.Init, window: *glfw.Window, gpu: *GpuContext) !void {
    var common_arenas = try Arenas.init(init.gpa);
    defer common_arenas.deinit();

    const context = common_arenas.context(init.io);

    const window_scale = window.getContentScale();
    const window_size = window.getSize();
    const scaled_width: f32 = @floatFromInt(window_size[0]);
    const scaled_height: f32 = @floatFromInt(window_size[1]);

    const camera = try Camera.init(
        context.alloc,
        .{
            .position = vec3(0.0, 2.0, 14.0),
            .target = vec3(0.0, 2.0, 0.0),
            .scr_width = scaled_width,
            .scr_height = scaled_height,
        },
    );
    defer camera.deinit();

    // Input installs GLFW callbacks; gui.init chains to them, so it comes after.
    main.state = State{
        .viewport_width = scaled_width * window_scale[0],
        .viewport_height = scaled_height * window_scale[1],
        .scaled_width = scaled_width,
        .scaled_height = scaled_height,
        .window_scale = window_scale,
        .camera = camera,
        .projection = camera.getProjectionWithType(.Perspective),
        .projection_type = .Perspective,
        .light_postion = vec3(1.2, 1.0, 2.0),
        .delta_time = 0.0,
        .total_time = 0.0,
        .world_point = null,
        .current_position = vec3(0.0, 0.0, 0.0),
        .target_position = vec3(0.0, 0.0, 0.0),
        .input = core.Input.init(window),
    };

    const basic_model_shader = try Shader.init(
        init.io,
        context.alloc,
        gpu,
        "examples/scene_tree/shaders/basic_model.wgsl",
        .{ .vertex_buffers = &Shape.vertex_buffer_layouts, .material = .texture },
    );
    defer basic_model_shader.releaseGpuObjects();

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

    const plane = try shapes.createCube(
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
    defer plane.releaseGpuObjects();

    const cylinder = try shapes.createCylinder(
        context.alloc,
        gpu,
        1.0,
        4.0,
        20,
    );
    defer cylinder.releaseGpuObjects();

    const texture_diffuse = TextureConfig{
        .filter = .Linear,
        .flip_v = false,
        .is_srgb = true,
        .wrap = TextureWrap.Repeat,
    };

    const cube_texture = try Texture.initFromFile(
        context,
        gpu,
        "assets/textures/container.jpg",
        texture_diffuse,
    );
    defer cube_texture.releaseGpuObjects();

    const surface_texture = try Texture.initFromFile(
        context,
        gpu,
        "assets/textures/Floor/Floor D.png",
        texture_diffuse,
    );
    defer surface_texture.releaseGpuObjects();

    const pbr_shader = try Shader.init(
        init.io,
        context.alloc,
        gpu,
        "src/core/shaders/pbr.wgsl",
        .{ .vertex_buffers = &MeshPrimitive.vertex_buffer_layouts, .material = .pbr, .alpha_to_coverage = true },
    );
    defer pbr_shader.releaseGpuObjects();

    const model_path = "assets/models/CesiumMan/CesiumMan_converted.gltf";
    var gltf_asset = try GltfAsset.init(context, gpu, "alien", model_path);
    try gltf_asset.load();

    const model = try gltf_asset.buildModel();
    defer model.cleanUp();
    // redfish never animated this node; playing its walk exercises Model's skinning path.
    try model.playAnimations(&.{0});
    var model_obj = ModelObj{ .model = model, .shader = pbr_shader };

    // Simple placeholder object for root node (no update or draw methods)
    const RootPlaceholder = struct {};
    var root_placeholder = RootPlaceholder{};

    const root_node = try Node.init(context.alloc, "root_node", &root_placeholder, &main.state);

    const node_model = try Node.init(context.alloc, "node_model", &model_obj, &main.state);

    // CesiumMan_converted's Z_UP root node rotates +90° about X (the original asset: -90°),
    // so the model stands on its head; 180° about X sets it upright. redfish rotated
    // -90°, which laid it down, but never showed it (its Node.draw set a uniform the
    // shader didn't have). See Known Issues in the port plan.
    node_model.transform.translation = vec3(0.0, 0.0, 2.0);
    node_model.transform.rotation = Quat.fromAxisAngle(vec3(1.0, 0.0, 0.0), math.degreesToRadians(180.0));

    const node_cylinder = try Node.init(context.alloc, "shape_cylinder", cylinder, &main.state);

    root_node.addChild(node_model);
    root_node.addChild(node_cylinder);

    const cube_positions = [_]Vec3{
        vec3(3.0, 0.5, 0.0),
        vec3(1.5, 0.5, 0.0),
        vec3(0.0, 0.5, 0.0),
        vec3(-1.5, 0.5, 0.0),
        vec3(-3.0, 0.5, 0.0),
    };

    for (cube_positions) |position| {
        const cube = try Node.init(
            context.alloc,
            "shape_cubeboid",
            cubeboid,
            &main.state,
        );
        cube.transform.translation = position;
        root_node.addChild(cube);
    }

    const node_cube_spin = try Node.init(
        context.alloc,
        "shape_cubeboid",
        cubeboid,
        &main.state,
    );
    node_cube_spin.transform.translation = vec3(0.0, 4.0, 0.0);

    node_cylinder.addChild(node_cube_spin);

    const node_cube = try Node.init(
        context.alloc,
        "shape_cubeboid",
        cubeboid,
        &main.state,
    );

    const cube_transforms = [_]Mat4{
        Mat4.fromTranslation(vec3(3.0, 0.5, 0.0)),
        Mat4.fromTranslation(vec3(1.5, 0.5, 0.0)),
        Mat4.fromTranslation(vec3(0.0, 0.5, 0.0)),
        Mat4.fromTranslation(vec3(-1.5, 0.5, 0.0)),
        Mat4.fromTranslation(vec3(-3.0, 0.5, 0.0)),
    };

    const xz_plane_point = vec3(0.0, 0.0, 0.0);
    const xz_plane_normal = vec3(0.0, 1.0, 0.0);

    // draw loop
    // -----------
    while (!window.shouldClose()) {
        glfw.pollEvents();

        const current_time: f32 = @floatCast(glfw.getTime());
        main.state.delta_time = current_time - main.state.total_time;
        main.state.total_time = current_time;

        main.processKeys();
        updateViewSize(&main.state);

        const world_ray = math.getWorldRayFromMouse(
            main.state.scaled_width,
            main.state.scaled_height,
            &main.state.projection,
            &main.state.camera.getView(),
            main.state.input.mouse_x,
            main.state.input.mouse_y,
        );

        main.state.world_point = math.getRayPlaneIntersection(
            world_ray.origin,
            world_ray.direction,
            xz_plane_point,
            xz_plane_normal,
        );

        const ray = Ray{
            .origin = world_ray.origin,
            .direction = world_ray.direction,
        };

        const picked_id = pickCube(cubeboid, &cube_transforms, ray);

        const frame = gpu.beginFrame(CLEAR_COLOR) orelse continue;
        gpu.writeFrameUniforms(frameUniforms(&main.state));

        cube_texture.bind(&frame);

        for (cube_positions, 0..) |t, i| {
            const is_hit = picked_id != null and picked_id.? == i;
            node_cube.transform.translation = t;
            node_cube.updateTransform(null);
            node_cube.draw(&frame, basic_model_shader, if (is_hit) HIT else NO_HIT);
        }

        if (main.state.input.mouse_left_button and main.state.world_point != null) {
            main.state.target_position = main.state.world_point.?;
        }

        updateSpin(node_cylinder, &main.state);
        try node_model.update(&main.state);

        root_node.transform.translation = main.state.target_position;
        root_node.updateTransform(null);
        root_node.draw(&frame, basic_model_shader, NO_HIT);

        const plane_transform = Mat4.fromTranslation(vec3(0.0, -1.0, 0.0));
        surface_texture.bind(&frame);
        plane.draw(&frame, basic_model_shader, core.DrawUniforms.init(plane_transform, NO_HIT));

        if (main.state.spin) {
            main.state.camera.movement.processMovement(.orbit_right, main.state.delta_time * 1.0);
        }

        gpu.endFrame(frame);
    }
}

/// Index of the nearest cube the mouse ray hits.
fn pickCube(cubeboid: *const Shape, cube_transforms: []const Mat4, ray: Ray) ?usize {
    var picked_id: ?usize = null;
    var picked_distance: f32 = std.math.inf(f32);

    for (cube_transforms, 0..) |t, id| {
        const aabb = cubeboid.aabb.transform(&t);
        if (aabb.rayIntersects(ray)) |distance| {
            if (distance < picked_distance) {
                picked_id = id;
                picked_distance = distance;
            }
        }
    }
    return picked_id;
}

/// Keep the camera aspect and mouse-ray size in step with the window.
fn updateViewSize(st: *State) void {
    const width = st.input.window_width;
    const height = st.input.window_height;
    if (width == st.scaled_width and height == st.scaled_height) {
        return;
    }
    if (width == 0 or height == 0) {
        return;
    }

    st.scaled_width = width;
    st.scaled_height = height;
    st.camera.setScreenDimensions(width, height);
    st.projection = st.camera.getProjectionWithType(st.projection_type);
}

/// Camera frame uniforms, using the state's projection so keys 4 / 5 switch it.
fn frameUniforms(st: *State) core.bindings.FrameUniforms {
    var render_context = st.camera.getRenderContext(st.total_time);
    render_context.projection = st.projection;
    render_context.projection_view = st.projection.mulMat4(&render_context.view);
    var uniforms = render_context.frameUniforms();
    uniforms.lights = modelLights().uniforms();
    return uniforms;
}

/// For the PBR model node (demo_app's light); redfish's basic shader is unlit.
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

pub fn updateSpin(node: *Node, st: *State) void {
    const up = vec3(0.0, 1.0, 0.0);
    const velocity: f32 = 5.0 * st.delta_time;
    const angle = math.degreesToRadians(velocity);
    const turn_rotation = Quat.fromAxisAngle(up, angle);
    node.transform.rotation = node.transform.rotation.mulQuat(turn_rotation);
}
