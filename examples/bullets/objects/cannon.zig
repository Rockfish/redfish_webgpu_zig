const std = @import("std");
const core = @import("core");
const math = @import("math");

const BulletSystem = @import("../projectiles/bullet_system.zig").BulletSystem;

const ResourceManager = core.ResourceManager;
const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Transform = core.Transform;
const Frame = core.Frame;
const PbrMaterial = core.material.PbrMaterial;

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Vec4 = math.Vec4;
const vec4 = math.vec4;
const Quat = math.Quat;

const X_AXIS = vec3(1.0, 0.0, 0.0);
const Y_AXIS = vec3(0.0, 1.0, 0.0);

/// Cannon parts, one node each, listed parent-first so a single pass over the
/// node array computes world transforms. The enum value is the node index.
pub const Part = enum(u32) {
    base, // wide flat box on the ground
    platform, // smaller box on the base
    turret_body, // short wide cylinder, yaw pivot
    turret_head, // sphere on the body, pitch pivot
    barrel, // long narrow cylinder with its origin at the breech

    pub const count = @typeInfo(Part).@"enum".fields.len;

    pub fn index(self: Part) u32 {
        return @intFromEnum(self);
    }
};

/// glTF-style node: flat array, children by index, optional mesh index. The
/// local transform is relative to the parent's origin, so pivots live where the
/// parent places the child.
pub const Node = struct {
    name: []const u8,
    parent: ?u32,
    children: []const u32,
    mesh: ?u32,
    local_transform: Transform,
    world_transform: Transform = Transform.identity(),
    color: Vec4,
};

// Part dimensions. Cubes are centered on their origin, cylinders start at their
// origin and extend along +Y, spheres are centered.
const base_size = vec3(4.0, 0.5, 4.0);
const platform_size = vec3(2.5, 0.5, 2.5);
const body_radius: f32 = 1.0;
const body_height: f32 = 0.8;
const head_radius: f32 = 0.7;
const barrel_radius: f32 = 0.2;
const barrel_length: f32 = 2.5;

const base_children = [_]u32{Part.platform.index()};
const platform_children = [_]u32{Part.turret_body.index()};
const body_children = [_]u32{Part.turret_head.index()};
const head_children = [_]u32{Part.barrel.index()};

/// Cannon built from basic shapes arranged as a node hierarchy:
/// base -> platform -> turret_body (yaw) -> turret_head (pitch) -> barrel (recoil).
pub const Cannon = struct {
    nodes: [Part.count]Node,
    meshes: [Part.count]*Shape,
    shader: *Shader,
    /// No textures: basic_texture then colors each part with its draw color.
    material: *PbrMaterial,
    bullets: BulletSystem,
    /// Placement of the whole cannon in the world.
    transform: Transform = Transform.identity(),

    yaw: f32 = 0.0,
    pitch: f32 = 0.0,
    target_yaw: f32 = 0.0,
    target_pitch: f32 = 0.0,
    recoil: f32 = 0.0,

    aim_rate: f32 = 4.0,
    /// Degrees per second the aim targets move under key input.
    aim_speed: f32 = 60.0,
    min_pitch: f32 = -0.2,
    max_pitch: f32 = 1.2,
    recoil_distance: f32 = 0.4,
    recoil_recovery: f32 = 6.0,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !Self {
        const shader = try rm.createShader("examples/bullets/shaders/basic_texture.wgsl", .{
            .vertex_buffers = &Shape.vertex_buffer_layouts,
            .material = .pbr,
        });

        var meshes: [Part.count]*Shape = undefined;
        meshes[Part.base.index()] = try rm.createCube(.{ .width = base_size.x, .height = base_size.y, .depth = base_size.z });
        meshes[Part.platform.index()] = try rm.createCube(.{ .width = platform_size.x, .height = platform_size.y, .depth = platform_size.z });
        meshes[Part.turret_body.index()] = try rm.createCylinder(body_radius, body_height, 24);
        meshes[Part.turret_head.index()] = try rm.createSphere(head_radius, 16, 16);
        meshes[Part.barrel.index()] = try rm.createCylinder(barrel_radius, barrel_length, 12);

        var cannon = Self{
            .nodes = buildNodes(),
            .meshes = meshes,
            .shader = shader,
            .material = try rm.createMaterial(.{ null, null, null, null, null }),
            .bullets = try BulletSystem.init(rm),
        };
        cannon.updateWorldTransforms();
        return cannon;
    }

    /// Nodes in parent-first order. Translations are offsets from the parent's
    /// origin; the cylinder origins double as the yaw and recoil pivots.
    fn buildNodes() [Part.count]Node {
        var nodes: [Part.count]Node = undefined;

        // Base sits on the ground: its center is half its height up.
        nodes[Part.base.index()] = .{
            .name = "base",
            .parent = null,
            .children = &base_children,
            .mesh = Part.base.index(),
            .local_transform = Transform.fromTranslation(vec3(0.0, base_size.y * 0.5, 0.0)),
            .color = vec4(0.35, 0.35, 0.38, 1.0),
        };

        // Platform center is on top of the base: up by half of each height.
        nodes[Part.platform.index()] = .{
            .name = "platform",
            .parent = Part.base.index(),
            .children = &platform_children,
            .mesh = Part.platform.index(),
            .local_transform = Transform.fromTranslation(vec3(0.0, (base_size.y + platform_size.y) * 0.5, 0.0)),
            .color = vec4(0.45, 0.45, 0.5, 1.0),
        };

        // Turret body origin is its bottom center, resting on the platform top.
        nodes[Part.turret_body.index()] = .{
            .name = "turret_body",
            .parent = Part.platform.index(),
            .children = &body_children,
            .mesh = Part.turret_body.index(),
            .local_transform = Transform.fromTranslation(vec3(0.0, platform_size.y * 0.5, 0.0)),
            .color = vec4(0.3, 0.5, 0.3, 1.0),
        };

        // Head center sits on top of the body; pitch rotates about this point.
        nodes[Part.turret_head.index()] = .{
            .name = "turret_head",
            .parent = Part.turret_body.index(),
            .children = &head_children,
            .mesh = Part.turret_head.index(),
            .local_transform = Transform.fromTranslation(vec3(0.0, body_height, 0.0)),
            .color = vec4(0.35, 0.55, 0.35, 1.0),
        };

        // Barrel starts at the head center and points down -Z; the cylinder is
        // generated along +Y so it is rotated -90 degrees about X.
        nodes[Part.barrel.index()] = .{
            .name = "barrel",
            .parent = Part.turret_head.index(),
            .children = &.{},
            .mesh = Part.barrel.index(),
            .local_transform = barrelTransform(0.0),
            .color = vec4(0.2, 0.2, 0.22, 1.0),
        };

        return nodes;
    }

    /// Aim targets in radians. Yaw turns the turret body about Y, pitch tilts
    /// the head about X; positive pitch raises the muzzle.
    pub fn setAim(self: *Self, yaw: f32, pitch: f32) void {
        self.target_yaw = yaw;
        self.target_pitch = pitch;
    }

    /// Launches a bullet group from the muzzle and kicks the barrel back.
    pub fn fire(self: *Self) !void {
        try self.bullets.createBullets(self.muzzleTransform());
        self.recoil = self.recoil_distance;
    }

    /// World transform at the center of the barrel's exit, suitable as the
    /// aim transform for BulletSystem.createBullets. The rotation is the turret
    /// head's world rotation, so World_Forward (-Z) points down the barrel;
    /// the barrel node's own rotation only stands the +Y cylinder on its side.
    pub fn muzzleTransform(self: *const Self) Transform {
        const barrel = self.nodes[Part.barrel.index()].world_transform;
        return Transform{
            .translation = barrel.transformPoint(vec3(0.0, barrel_length, 0.0)),
            .rotation = self.nodes[Part.turret_head.index()].world_transform.rotation,
            .scale = Vec3.One,
        };
    }

    /// Arrow keys steer the aim targets, R fires once per press.
    pub fn processInput(self: *Self, input: *core.Input) !void {
        const step = math.degreesToRadians(self.aim_speed * input.delta_time);

        var iterator = input.key_presses.iterator();
        while (iterator.next()) |k| {
            switch (k) {
                .left => self.target_yaw += step,
                .right => self.target_yaw -= step,
                .up => self.target_pitch = @min(self.max_pitch, self.target_pitch + step),
                .down => self.target_pitch = @max(self.min_pitch, self.target_pitch - step),
                else => {},
            }

            if (input.key_processed.contains(k)) {
                continue;
            }

            switch (k) {
                .r => {
                    input.key_processed.insert(k);
                    try self.fire();
                },
                else => {},
            }
        }
    }

    /// Ease the aim toward its targets, recover from recoil, rebuild world
    /// transforms, and advance the bullets.
    pub fn update(self: *Self, delta_time: f32) void {
        const aim_step = @min(1.0, self.aim_rate * delta_time);
        self.yaw += (self.target_yaw - self.yaw) * aim_step;
        self.pitch += (self.target_pitch - self.pitch) * aim_step;

        const recoil_step = @min(1.0, self.recoil_recovery * delta_time);
        self.recoil -= self.recoil * recoil_step;

        self.nodes[Part.turret_body.index()].local_transform.rotation = Quat.fromAxisAngle(Y_AXIS, self.yaw);
        self.nodes[Part.turret_head.index()].local_transform.rotation = Quat.fromAxisAngle(X_AXIS, self.pitch);
        self.nodes[Part.barrel.index()].local_transform = barrelTransform(self.recoil);

        self.updateWorldTransforms();
        self.bullets.update(delta_time);
    }

    /// Single parent-first pass; the root composes with the cannon placement so
    /// every world transform is already in world space.
    pub fn updateWorldTransforms(self: *Self) void {
        for (&self.nodes) |*node| {
            const parent_transform = if (node.parent) |parent_index|
                self.nodes[parent_index].world_transform
            else
                self.transform;
            node.world_transform = parent_transform.composeTransforms(node.local_transform);
        }
    }

    /// Barrel local transform for a given recoil offset. Recoil pushes the
    /// barrel back along its firing axis, which is +Z in head space.
    fn barrelTransform(recoil: f32) Transform {
        return Transform{
            .translation = vec3(0.0, 0.0, recoil),
            .rotation = Quat.fromAxisAngle(X_AXIS, -std.math.pi / 2.0),
            .scale = Vec3.One,
        };
    }

    pub fn draw(self: *Self, frame: *const Frame) void {
        self.material.bind(frame);
        for (&self.nodes) |*node| {
            const mesh_index = node.mesh orelse continue;
            const draw_uniforms = core.DrawUniforms.init(node.world_transform.toMatrix(), linearColor(node.color));
            self.meshes[mesh_index].draw(frame, self.shader, draw_uniforms);
        }

        self.bullets.draw(frame);
    }
};

/// Part colors were chosen for GL, which displayed them as-is.
fn linearColor(color: Vec4) Vec4 {
    const srgbToLinear = core.colors.srgbToLinear;
    return vec4(srgbToLinear(color.x), srgbToLinear(color.y), srgbToLinear(color.z), color.w);
}
