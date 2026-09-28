// Simple bullet system for testing patterns
const std = @import("std");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");

const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;
const ResourceManager = core.ResourceManager;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Transform = core.Transform;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const Color = core.Color;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Frame = core.Frame;
const Texture = core.texture.Texture;

/// Instance attributes: rotation quaternion at location 8, position at 9 (as redfish).
const BulletLayouts = core.shapes.InstancedLayouts(&.{
    .{ .format = .float32x4, .location = 8 },
    .{ .format = .float32x3, .location = 9 },
});

pub const BULLET_SCALE: f32 = 2.0;
pub const BULLET_LIFETIME: f32 = 10.0;
pub const Bullet_Speed: f32 = 2.0;

pub const Bullets_Per_Side: i32 = 3;
pub const Spread_Degrees: f32 = 10.0;

pub const BulletShaderData = struct {
    rotation: Quat,
    position: Vec3,
    pad: f32,
};

pub const BulletCalcData = struct {
    direction: Vec3,
    velocity: Vec3,
    right_vec: Vec3,
};

var buf: [500]u8 = undefined;
pub const BulletSystem = struct {
    allocator: Allocator,
    shader: *Shader,
    texture: *Texture,
    gravity: f32 = 0.0,
    x_rotations: ManagedArrayList(Quat),
    y_rotations: ManagedArrayList(Quat),
    bullet_positions: ManagedArrayList(Vec3), // instance attribute
    bullet_rotations: ManagedArrayList(Quat), // instance attribute
    bullet_directions: ManagedArrayList(Vec3),
    bullet_velocities: ManagedArrayList(Vec3),
    bullet_right_vectors: ManagedArrayList(Vec3),
    bullet_rotations_initial: ManagedArrayList(Quat), // used only for drawing initial path lines
    aim_origin: Vec3 = Vec3.Zero, // start of the initial path lines
    bullet_cube: *core.shapes.Shape,
    line_shader: *Shader,
    lines: Lines,
    is_lines_visible: bool = false,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !Self {
        const allocator = rm.context.alloc;

        const instanced_shader = try rm.createShader("examples/bullets/shaders/bullets.wgsl", .{
            .vertex_buffers = &BulletLayouts.layouts,
            .material = .texture,
        });

        const cubemap_texture = try rm.createTexture(
            "assets/textures/cubemap_template_2x3.png",
            .{
                .flip_v = false,
                .filter = .Linear,
                .wrap = .Clamp,
            },
        );

        var x_rotations = ManagedArrayList(Quat).init(allocator);
        var y_rotations = ManagedArrayList(Quat).init(allocator);

        const radians_per_bullet: f32 = math.degreesToRadians(Spread_Degrees);
        const num_bullets_per_side: f32 = @floatFromInt(Bullets_Per_Side);
        const spread_centering = (num_bullets_per_side - 1.0) * radians_per_bullet * 0.5;

        for (0..Bullets_Per_Side) |i| {
            const angle: f32 = radians_per_bullet * @as(f32, @floatFromInt(i)) - spread_centering;
            const y_rot = Quat.fromAxisAngle(vec3(0.0, 1.0, 0.0), angle);
            const x_rot = Quat.fromAxisAngle(vec3(1.0, 0.0, 0.0), angle);
            try x_rotations.append(x_rot);
            try y_rotations.append(y_rot);
        }

        const cube_config: core.shapes.CubeConfig = .{
            .width = 1.0,
            .height = 1.0,
            .depth = 1.0,
            .num_tiles_x = 1.0,
            .num_tiles_y = 1.0,
            .num_tiles_z = 1.0,
            .texture_mapping = .Cubemap2x3,
        };

        const bullet_cube = try rm.createCube(cube_config);

        const lines_shader = try rm.createShader("examples/bullets/shaders/lines.wgsl", .{
            .vertex_buffers = &Lines.vertex_buffer_layouts,
            .topology = .line_list,
        });

        const lines = try Lines.init(allocator, lines_shader, 10.0, 1.0, 144);

        return .{
            .allocator = allocator,
            .shader = instanced_shader,
            .texture = cubemap_texture,
            .x_rotations = x_rotations,
            .y_rotations = y_rotations,
            .bullet_positions = ManagedArrayList(Vec3).init(allocator),
            .bullet_rotations = ManagedArrayList(Quat).init(allocator),
            .bullet_rotations_initial = ManagedArrayList(Quat).init(allocator),
            .bullet_directions = ManagedArrayList(Vec3).init(allocator),
            .bullet_velocities = ManagedArrayList(Vec3).init(allocator),
            .bullet_right_vectors = ManagedArrayList(Vec3).init(allocator),
            .bullet_cube = bullet_cube,
            .line_shader = lines_shader,
            .lines = lines,
        };
    }

    pub fn createBullets(self: *Self, aim_transform: Transform) !void {
        const start_index = 0;
        const bullet_group_size = Bullets_Per_Side * Bullets_Per_Side;

        try self.bullet_positions.resize(start_index + bullet_group_size);
        try self.bullet_rotations.resize(start_index + bullet_group_size);
        try self.bullet_rotations_initial.resize(start_index + bullet_group_size);
        try self.bullet_directions.resize(start_index + bullet_group_size);
        try self.bullet_velocities.resize(start_index + bullet_group_size);
        try self.bullet_right_vectors.resize(start_index + bullet_group_size);

        const start: usize = start_index;
        const end = start + bullet_group_size;

        self.aim_origin = aim_transform.translation;

        for (start..end) |index| {
            const count = index - start;
            const i = @divTrunc(count, Bullets_Per_Side);
            const j = @mod(count, Bullets_Per_Side);

            const y_rot = self.y_rotations.items()[i];
            const x_rot = self.x_rotations.items()[j];
            const x_y_rot = x_rot.mulQuat(y_rot);

            const rotation = aim_transform.rotation.mulQuat(x_y_rot);
            const direction = rotation.rotateVec(Vec3.World_Forward);

            self.bullet_positions.items()[index] = aim_transform.translation;
            self.bullet_rotations.items()[index] = rotation;
            self.bullet_rotations_initial.items()[index] = rotation;
            self.bullet_directions.items()[index] = direction;

            const velocity = direction.mulScalar(Bullet_Speed);
            self.bullet_velocities.items()[index] = velocity;

            // const down = vec3(0.0, -1.0, 0.0);
            // const right = blk: {
            // const r = direction.cross(down).toNormalized();
            // Handle edge case: firing straight up or down
            // if (r.lengthSquared() < 0.001) {
            // break :blk vec3(1.0, 0.0, 0.0); // Arbitrary right for vertical shots
            // }
            // break :blk r;
            // };
            // _ = right;
            self.bullet_right_vectors.items()[index] = self.bullet_rotations.items()[index].right();
        }
    }

    pub fn resetBullets(self: *Self, aim_transform: Transform) !void {
        try self.createBullets(aim_transform);
    }

    pub fn update_x(self: *Self, delta_time: f32) void {
        const delta = delta_time * Bullet_Speed;

        const start: usize = 0;
        const end = self.bullet_positions.items().len;

        for (start..end) |bullet_index| {
            const position = self.bullet_positions.items()[bullet_index];
            const direction = self.bullet_directions.items()[bullet_index];

            const change = direction.mulScalar(delta);
            self.bullet_positions.items()[bullet_index] = position.add(change);
        }
    }

    pub fn update(self: *Self, delta_time: f32) void {
        const gravity_vec = vec3(0.0, -self.gravity, 0.0);
        const gravity_delta = gravity_vec.mulScalar(delta_time);

        for (0..self.bullet_positions.items().len) |i| {
            var velocity = self.bullet_velocities.items()[i];
            const position = self.bullet_positions.items()[i];

            velocity = velocity.add(gravity_delta);

            self.bullet_velocities.items()[i] = velocity;
            self.bullet_positions.items()[i] = position.add(velocity.mulScalar(delta_time));

            const forward = velocity.toNormalized();

            if (forward.lengthSquared() > 0.001) {
                const right = self.bullet_right_vectors.items()[i];
                self.bullet_rotations.items()[i] = Quat.fromDirectionWithRight(forward, right);
            }
        }
    }

    pub fn drawLines(self: *Self, frame: *const Frame) void {
        var transformed: [Bullets_Per_Side * Bullets_Per_Side]LineSegment = undefined;
        const start: usize = 0;
        const end: usize = self.bullet_rotations_initial.items().len;

        for (start..end) |i| {
            const rotation = self.bullet_rotations_initial.items()[i];
            const line_dir = rotation.rotateVec(Vec3.World_Forward);
            transformed[i] = .{
                .start = self.aim_origin,
                .end = self.aim_origin.add(line_dir.mulScalar(10.0)),
                .color = Color.yellow,
            };
        }

        self.lines.draw(frame, transformed[start..end]);
    }

    /// One instanced draw; rotations and positions go to the frame's vertex ring as
    /// instance attributes (redfish re-filled two VBOs, never freed).
    pub fn drawBullets(self: *Self, frame: *const Frame) void {
        const count = self.bullet_positions.items().len;
        if (count == 0) {
            return;
        }

        self.texture.bind(frame);
        const instance_data = [_][]const u8{
            std.mem.sliceAsBytes(self.bullet_rotations.items()),
            std.mem.sliceAsBytes(self.bullet_positions.items()),
        };
        const draw_uniforms = core.DrawUniforms.init(Mat4.Identity, vec4(1.0, 1.0, 1.0, 1.0));
        self.bullet_cube.drawInstanced(frame, self.shader, draw_uniforms, &instance_data, @intCast(count));
    }

    pub fn draw(self: *Self, frame: *const Frame) void {
        if (self.is_lines_visible) {
            self.drawLines(frame);
        }
        self.drawBullets(frame);
    }
};
