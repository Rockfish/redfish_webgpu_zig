// Simple bullet system for testing patterns
const std = @import("std");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");

const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;
const ResourceManager = core.ResourceManager;

const BulletSystem = @import("bullet_system.zig").BulletSystem;

const Transform = core.Transform;
const Shader = core.Shader;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const Frame = core.Frame;

const Color = core.Color;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;

pub const Turret = struct {
    bullets: BulletSystem,
    aim_transform: Transform = Transform.identity(),
    rotation_speed: f32 = 10.0,
    lines: Lines,
    line_shader: *Shader,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !*Self {
        const allocator = rm.context.alloc;

        const line_shader = try rm.createShader("examples/bullets/shaders/lines.wgsl", .{
            .vertex_buffers = &Lines.vertex_buffer_layouts,
            .topology = .line_list,
        });

        const lines = try Lines.init(allocator, line_shader, 10.0, 1.0, 144);

        var aim_transform = Transform.identity();
        const up_rot = Quat.fromAxisAngle(Vec3.World_Up, math.degreesToRadians(0.0));
        const right_rot = Quat.fromAxisAngle(Vec3.World_Right, math.degreesToRadians(0.0));
        const aim_rot = up_rot.mulQuat(right_rot);
        aim_transform.rotation = aim_transform.rotation.mulQuat(aim_rot);

        var bullets = try BulletSystem.init(rm);
        try bullets.createBullets(aim_transform);

        const self = try allocator.create(Self);
        self.* = .{
            .bullets = bullets,
            .lines = lines,
            .line_shader = line_shader,
            .aim_transform = aim_transform,
        };
        return self;
    }

    pub fn fire(self: *Self) !void {
        try self.bullets.createBullets(self.aim_transform);
    }

    pub fn update(self: *Self, input: *core.Input) !void {
        self.bullets.update(input.delta_time);
    }

    pub fn draw(self: *Self, frame: *const Frame) void {
        self.drawLines(frame);
        self.bullets.draw(frame);
    }

    pub fn drawLines(self: *Self, frame: *const Frame) void {
        var transformed: [1]LineSegment = undefined;
        const line_dir = self.aim_transform.rotation.rotateVec(Vec3.World_Forward);

        transformed[0] = .{
            .start = Vec3.Zero,
            .end = line_dir.mulScalar(10.0),
            .color = Color.yellow,
        };

        self.lines.draw(frame, &transformed);
    }

    pub fn processInput(self: *Self, input: *core.Input) !void {
        const rot_angle = math.degreesToRadians(self.rotation_speed * input.delta_time);

        var iterator = input.key_presses.iterator();
        while (iterator.next()) |k| {
            switch (k) {
                .up => {
                    const right_vec = self.aim_transform.right();
                    self.aim_transform.rotateAxis(right_vec, rot_angle);
                },
                .down => {
                    const right_vec = self.aim_transform.right();
                    self.aim_transform.rotateAxis(right_vec, -rot_angle);
                },
                .right => {
                    self.aim_transform.rotateAxis(Vec3.World_Up, -rot_angle);
                },
                .left => {
                    self.aim_transform.rotateAxis(Vec3.World_Up, rot_angle);
                },
                else => {},
            }

            if (input.key_processed.contains(k)) {
                continue;
            }

            switch (k) {
                .r => {
                    try self.fire();
                },
                else => {},
            }
        }
    }
};
