const std = @import("std");
const core = @import("core");
const math = @import("math");
const SceneCamera = @import("../scene_camera.zig").SceneCamera;

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const quat = math.quat;
const Input = core.Input;

const Allocator = std.mem.Allocator;

pub const FreeCamera = struct {
    camera: *core.Camera,
    rotation_speed: f32 = 8.0,
    translate_speed: f32 = 5.0,
    input_tick: u64 = 0,

    const Self = @This();

    pub fn init(allocator: Allocator, scr_width: f32, scr_height: f32) !*SceneCamera {
        const camera = try core.Camera.init(
            allocator,
            .{
                .position = vec3(0.0, 5.0, 15.0),
                .target = vec3(0.0, 1.0, 0.0),
                .scr_width = scr_width,
                .scr_height = scr_height,
            },
        );

        const free_camera = try allocator.create(FreeCamera);
        free_camera.* = FreeCamera{
            .camera = camera,
        };

        return SceneCamera.init(allocator, "free_camera", free_camera);
    }

    pub fn update(self: *Self, input: *core.Input) !void {
        if (input.update_tick != self.input_tick) {
            self.camera.adjustFov(@floatCast(input.scroll_yoffset));
            self.camera.setScreenDimensions(input.framebuffer_width, input.framebuffer_height);
            self.input_tick = input.update_tick;
        }
    }

    pub fn processInput(self: *Self, input: *core.Input) !void {
        const dt = input.delta_time;

        var iterator = input.key_presses.iterator();
        while (iterator.next()) |k| {
            switch (k) {
                .up => {
                    if (input.key_shift) {
                        self.camera.processMovement(.up, dt);
                    } else {
                        self.camera.processMovement(.rotate_up, dt);
                    }
                },
                .down => {
                    if (input.key_shift) {
                        self.camera.processMovement(.down, dt);
                    } else {
                        self.camera.processMovement(.rotate_down, dt);
                    }
                },
                .left => self.camera.processMovement(.turn_left, dt),
                .right => self.camera.processMovement(.turn_right, dt),
                .w => self.camera.processMovement(.forward, dt),
                .s => self.camera.processMovement(.backward, dt),
                .a => self.camera.processMovement(.left, dt),
                .d => self.camera.processMovement(.right, dt),
                else => {},
            }
            // One-shot keys: fire once per press
            if (input.key_processed.contains(k)) {
                continue;
            }
        }
    }
};
