//! Device error / lost callbacks and adapter reporting. Replaces redfish's gl_debug.zig.

const std = @import("std");
const wgpu = @import("wgpu");

const c = wgpu.c;
const sliceFromView = wgpu.sliceFromView;

const log = std.log.scoped(.gpu);

/// Callback infos for `WGPUDeviceDescriptor`: log every uncaptured validation error and
/// any device loss other than the one we cause at shutdown.
pub fn uncapturedErrorCallbackInfo() c.WGPUUncapturedErrorCallbackInfo {
    return .{ .callback = onUncapturedError };
}

pub fn deviceLostCallbackInfo() c.WGPUDeviceLostCallbackInfo {
    return .{ .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = onDeviceLost };
}

pub fn logAdapterInfo(adapter: c.WGPUAdapter) void {
    var info: c.WGPUAdapterInfo = .{};
    if (c.wgpuAdapterGetInfo(adapter, &info) != c.WGPUStatus_Success) {
        log.warn("wgpuAdapterGetInfo failed", .{});
        return;
    }
    defer c.wgpuAdapterInfoFreeMembers(info);

    log.info("adapter: {s}", .{sliceFromView(info.device)});
    log.info("  vendor: {s} (0x{x}), device id 0x{x}", .{ sliceFromView(info.vendor), info.vendorID, info.deviceID });
    log.info("  architecture: {s}", .{sliceFromView(info.architecture)});
    log.info("  description: {s}", .{sliceFromView(info.description)});
    log.info("  backend: {s}, type: {s}", .{ backendName(info.backendType), adapterTypeName(info.adapterType) });
}

pub fn logAdapterLimits(adapter: c.WGPUAdapter) void {
    var limits: c.WGPULimits = .{};
    if (c.wgpuAdapterGetLimits(adapter, &limits) != c.WGPUStatus_Success) {
        log.warn("wgpuAdapterGetLimits failed", .{});
        return;
    }

    log.info("limits:", .{});
    inline for (@typeInfo(c.WGPULimits).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "nextInChain")) continue;
        log.info("  {s}: {d}", .{ field.name, @field(limits, field.name) });
    }
}

fn onUncapturedError(
    _: [*c]const c.WGPUDevice,
    error_type: c.WGPUErrorType,
    message: c.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    log.err("uncaptured error ({d}): {s}", .{ error_type, sliceFromView(message) });
}

fn onDeviceLost(
    _: [*c]const c.WGPUDevice,
    reason: c.WGPUDeviceLostReason,
    message: c.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    if (reason == c.WGPUDeviceLostReason_Destroyed or reason == c.WGPUDeviceLostReason_CallbackCancelled) return;
    log.err("device lost ({d}): {s}", .{ reason, sliceFromView(message) });
}

fn backendName(backend: c.WGPUBackendType) []const u8 {
    return switch (backend) {
        c.WGPUBackendType_Metal => "Metal",
        c.WGPUBackendType_Vulkan => "Vulkan",
        c.WGPUBackendType_D3D12 => "D3D12",
        c.WGPUBackendType_D3D11 => "D3D11",
        c.WGPUBackendType_OpenGL => "OpenGL",
        c.WGPUBackendType_OpenGLES => "OpenGLES",
        else => "other",
    };
}

fn adapterTypeName(adapter_type: c.WGPUAdapterType) []const u8 {
    return switch (adapter_type) {
        c.WGPUAdapterType_DiscreteGPU => "discrete",
        c.WGPUAdapterType_IntegratedGPU => "integrated",
        c.WGPUAdapterType_CPU => "cpu",
        else => "unknown",
    };
}
