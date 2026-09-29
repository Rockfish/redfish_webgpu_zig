const std = @import("std");
const core = @import("core");
const math = @import("math");

const Vec2 = math.Vec2;
const vec2 = math.vec2;
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const quat = math.quat;

const Allocator = std.mem.Allocator;
const ResourceManager = core.ResourceManager;

const Shader = core.Shader;
const Shape = core.shapes.Shape;
const Texture = core.texture.Texture;
const Frame = core.Frame;
const MeshPrimitive = core.MeshPrimitive;
const Input = core.Input;
const AnimationRepeatMode = core.AnimationRepeatMode;

const ToonStateMachine = core.AnimationStateMachine(ToonAnimation);

const path_soldier = "assets/toon_shooter_kit/Characters/glTF/Character_Soldier.gltf";
const path_enemy = "assets/toon_shooter_kit/Characters/glTF/Character_Enemy.gltf";
const path_hazmat = "assets/toon_shooter_kit/Characters/glTF/Character_Hazmat.gltf";

const ToonAnimation = enum(u32) {
    death,
    duck,
    hit_react,
    idle,
    idle_shoot,
    jump,
    jump_idle,
    jump_land,
    no,
    punch,
    run,
    run_gun,
    run_shoot,
    walk,
    walk_shoot,
    wave,
    yes,
};

const Weapon = enum {
    AK,
    GrenadeLauncher,
    Knife_1,
    Knife_2,
    Pistol,
    Revolver,
    Revolver_Small,
    RocketLauncher,
    ShortCannon,
    Shotgun,
    Shovel,
    SMG,
    Sniper,
    Sniper_2,
};

pub const ToonSoldier = struct {
    model: *core.ModelInstance,
    shader: *core.Shader,
    position: Vec3 = vec3(0.0, 0.0, 3.0),
    direction: Vec2 = vec2(0.0, 0.0),
    scale: Vec3 = vec3(1.0, 1.0, 1.0),
    transform: core.Transform = core.Transform.identity(),
    rotation_speed: f32 = 2.0,
    /// Units per second (negative: the model faces -forward). redfish moved a fixed step per
    /// frame with vsync off, so the speed depended on frame rate.
    walk_speed: f32 = -1.5,
    run_speed: f32 = -7.5,
    state_machine: ToonStateMachine,
    current_weapon: Weapon = .ShortCannon,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !*ToonSoldier {
        const allocator = rm.context.alloc;

        // level_01's animated_pbr is the same shader as core pbr
        const shader = try rm.createShader("src/core/shaders/pbr.wgsl", .{
            .vertex_buffers = &MeshPrimitive.vertex_buffer_layouts,
            .material = .pbr,
            .alpha_to_coverage = true,
        });

        const model = try rm.loadModel("toon_soldier", path_enemy);

        const configs = buildStateConfigs();
        var fsm = ToonStateMachine.init(configs, .idle, model);
        fsm.debug = true;

        const soldier = try allocator.create(ToonSoldier);
        soldier.* = .{
            .model = model,
            .shader = shader,
            .state_machine = fsm,
        };

        soldier.transform.translation = soldier.position;
        soldier.transform.scale = soldier.scale;
        soldier.equipWeapon(soldier.current_weapon);

        return soldier;
    }

    pub fn equipWeapon(self: *Self, weapon: Weapon) void {
        // Hide all weapons
        inline for (std.meta.fields(Weapon)) |field| {
            self.model.gltf_asset.setNodeVisibility(field.name, false);
        }
        // Show the selected weapon
        self.model.gltf_asset.setNodeVisibility(@tagName(weapon), true);
        self.current_weapon = weapon;
    }

    pub fn update(self: *Self, input: *Input) !void {
        try self.state_machine.update(self.model, input.total_time, input.delta_time);
    }

    /// Lit by the frame's SceneLights (redfish's PBR light uniforms were never set here).
    pub fn draw(self: *Self, frame: *const Frame) void {
        self.model.draw(frame, self.shader, self.transform.toMatrix());
    }

    pub fn processInput(self: *Self, input: *core.Input) !void {
        const dt = input.delta_time;

        // One-shot actions (highest priority, checked with key_processed for single-fire)
        self.processOneShotKeys(input);

        // Rotation (A/D)
        if (input.key_presses.contains(.a)) {
            self.transform.rotateAxis(vec3(0.0, 1.0, 0.0), self.rotation_speed * dt);
        }
        if (input.key_presses.contains(.d)) {
            self.transform.rotateAxis(vec3(0.0, 1.0, 0.0), -self.rotation_speed * dt);
        }

        // Locomotion
        if (input.key_presses.contains(.w)) {
            const is_running = input.key_shift;
            const speed = if (is_running) self.run_speed else self.walk_speed;
            const fwd = self.transform.forward();
            self.transform.translation = self.transform.translation.add(fwd.mulScalar(speed * dt));

            if (is_running) {
                _ = self.state_machine.requestState(.run_shoot);
            } else {
                _ = self.state_machine.requestState(.walk);
            }
        } else if (input.key_presses.contains(.s)) {
            const fwd = self.transform.forward();
            self.transform.translation = self.transform.translation.sub(fwd.mulScalar(self.walk_speed * dt));
            _ = self.state_machine.requestState(.walk);
        } else {
            _ = self.state_machine.requestState(.idle);
        }
    }

    fn processOneShotKeys(self: *Self, input: *core.Input) void {
        const one_shot_keys = .{
            .{ .key = .space, .anim = ToonAnimation.jump },
            .{ .key = .one, .anim = ToonAnimation.punch },
            .{ .key = .two, .anim = ToonAnimation.duck },
            .{ .key = .three, .anim = ToonAnimation.wave },
            .{ .key = .four, .anim = ToonAnimation.yes },
            .{ .key = .five, .anim = ToonAnimation.no },
            .{ .key = .six, .anim = ToonAnimation.walk_shoot },
            .{ .key = .seven, .anim = ToonAnimation.run_shoot },
        };

        inline for (one_shot_keys) |entry| {
            if (input.key_presses.contains(entry.key) and !input.key_processed.contains(entry.key)) {
                _ = self.state_machine.requestState(entry.anim);
            }
        }
    }
};

fn buildStateConfigs() [ToonStateMachine.count]ToonStateMachine.StateConfig {
    const Forever = AnimationRepeatMode.Forever;
    const Once = AnimationRepeatMode.Once;

    var configs: [ToonStateMachine.count]ToonStateMachine.StateConfig = undefined;

    // Locomotion (looping, interruptible)
    configs[@intFromEnum(ToonAnimation.idle)] = .{ .animation_id = 3, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.walk)] = .{ .animation_id = 13, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.run)] = .{ .animation_id = 10, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.run_gun)] = .{ .animation_id = 11, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.run_shoot)] = .{ .animation_id = 12, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.walk_shoot)] = .{ .animation_id = 14, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };

    // Idle variants (looping, interruptible)
    configs[@intFromEnum(ToonAnimation.idle_shoot)] = .{ .animation_id = 4, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };
    configs[@intFromEnum(ToonAnimation.jump_idle)] = .{ .animation_id = 6, .repeat = Forever, .crossfade_in = 0.15, .interruptible = true, .return_state = null };

    // One-shot actions (play once, return to idle, not interruptible)
    configs[@intFromEnum(ToonAnimation.punch)] = .{ .animation_id = 9, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.jump)] = .{ .animation_id = 5, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.jump_land)] = .{ .animation_id = 7, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.duck)] = .{ .animation_id = 1, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.wave)] = .{ .animation_id = 15, .repeat = Once, .crossfade_in = 0.15, .interruptible = true, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.yes)] = .{ .animation_id = 16, .repeat = Once, .crossfade_in = 0.15, .interruptible = true, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.no)] = .{ .animation_id = 8, .repeat = Once, .crossfade_in = 0.15, .interruptible = true, .return_state = .idle };

    // Reactions (play once, not interruptible)
    configs[@intFromEnum(ToonAnimation.hit_react)] = .{ .animation_id = 2, .repeat = Once, .crossfade_in = 0.10, .interruptible = false, .return_state = .idle };
    configs[@intFromEnum(ToonAnimation.death)] = .{ .animation_id = 0, .repeat = Once, .crossfade_in = 0.20, .interruptible = false, .return_state = null };

    return configs;
}
