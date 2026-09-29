//! zgui on WebGPU: zgui's GLFW platform backend plus imgui's WebGPU renderer backend,
//! which the build compiles against wgpu-native (zgui's own `glfw_wgpu` targets Dawn).
//! zgui draws inside the frame's main render pass, after the scene, so its pipeline has
//! the window pass's sample count.

const std = @import("std");
const zglfw = @import("zglfw");
const zgui = @import("zgui");
const wgpu = @import("wgpu");
const gpu_context = @import("gpu_context.zig");

const c = wgpu.c;
const GpuContext = gpu_context.GpuContext;
const Frame = gpu_context.Frame;

/// Install zgui's GLFW callbacks after any app callbacks; zgui chains to them.
pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window, gpu: *const GpuContext) void {
    zgui.init(allocator);
    zgui.backend.init(window);

    var info: ImGuiWgpuInitInfo = .{
        .device = gpu.device,
        .render_target_format = gpu.surface_format,
        .depth_stencil_format = gpu_context.depth_format,
        .pipeline_multisample_state = .{ .count = gpu_context.window_sample_count, .mask = 0xFFFF_FFFF },
    };
    if (!ImGui_ImplWGPU_Init(&info)) {
        @panic("ImGui_ImplWGPU_Init failed");
    }
}

pub fn newFrame() void {
    ImGui_ImplWGPU_NewFrame();
    zgui.backend.newFrame();
    zgui.newFrame();
}

pub fn draw(frame: Frame) void {
    zgui.render();
    ImGui_ImplWGPU_RenderDrawData(zgui.getDrawData(), frame.pass);
}

pub fn deinit() void {
    ImGui_ImplWGPU_Shutdown();
    zgui.backend.deinit();
    zgui.deinit();
}

/// Mirrors `ImGui_ImplWGPU_InitInfo` in imgui_impl_wgpu.h.
const ImGuiWgpuInitInfo = extern struct {
    device: c.WGPUDevice,
    num_frames_in_flight: c_int = 3,
    render_target_format: c.WGPUTextureFormat,
    depth_stencil_format: c.WGPUTextureFormat,
    pipeline_multisample_state: c.WGPUMultisampleState = .{ .count = 1, .mask = 0xFFFF_FFFF },
};

extern fn ImGui_ImplWGPU_Init(info: *ImGuiWgpuInitInfo) bool;
extern fn ImGui_ImplWGPU_NewFrame() void;
extern fn ImGui_ImplWGPU_RenderDrawData(draw_data: zgui.DrawData, pass: c.WGPURenderPassEncoder) void;
extern fn ImGui_ImplWGPU_Shutdown() void;
