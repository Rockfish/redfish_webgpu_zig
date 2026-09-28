const std = @import("std");
const core = @import("core");

const ResourceManager = core.ResourceManager;
const Frame = core.Frame;

/// The skybox binds its own shader (redfish's draw ran with whatever shader was bound).
pub const SkyBoxDirections = struct {
    skybox: core.shapes.Skybox,
    is_visible: bool = true,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !Self {
        const skybox = try core.shapes.Skybox.init(rm.context.io, rm.context.alloc, rm.gpu, .{
            .right = "assets/textures/skybox_forward_negZ/right.png",
            .left = "assets/textures/skybox_forward_negZ/left.png",
            .top = "assets/textures/skybox_forward_negZ/top.png",
            .bottom = "assets/textures/skybox_forward_negZ/bottom.png",
            .forward = "assets/textures/skybox_forward_negZ/forward.png",
            .back = "assets/textures/skybox_forward_negZ/back.png",
        });

        return .{ .skybox = skybox };
    }

    pub fn draw(self: *Self, frame: *const Frame) void {
        if (!self.is_visible) {
            return;
        }
        self.skybox.draw(frame);
    }

    /// redfish never released the skybox.
    pub fn cleanUp(self: *Self) void {
        self.skybox.releaseGpuObjects();
    }
};
