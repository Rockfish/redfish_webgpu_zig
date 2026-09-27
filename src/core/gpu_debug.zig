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

/// The first error caught by an error scope, copied out of the callback.
pub const ScopeError = struct {
    error_type: c.WGPUErrorType,
    buffer: [2048]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const ScopeError) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Start catching validation errors from the calls that follow. Pair with `popValidationScope`.
pub fn pushValidationScope(device: c.WGPUDevice) void {
    c.wgpuDevicePushErrorScope(device, c.WGPUErrorFilter_Validation);
}

/// Waits for the scope's result. Returns the error, or null if the calls were valid.
pub fn popValidationScope(instance: c.WGPUInstance, device: c.WGPUDevice) ?ScopeError {
    var result: PopResult = .{};
    _ = c.wgpuDevicePopErrorScope(device, .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = onPopErrorScope,
        .userdata1 = &result,
    });
    while (!result.done) c.wgpuInstanceProcessEvents(instance);
    return result.scope_error;
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

const PopResult = struct {
    done: bool = false,
    scope_error: ?ScopeError = null,
};

fn onPopErrorScope(
    status: c.WGPUPopErrorScopeStatus,
    error_type: c.WGPUErrorType,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const result: *PopResult = @ptrCast(@alignCast(userdata1));
    result.done = true;
    if (status != c.WGPUPopErrorScopeStatus_Success) {
        log.err("popErrorScope failed ({d}): {s}", .{ status, sliceFromView(message) });
        return;
    }
    if (error_type == c.WGPUErrorType_NoError) return;

    var scope_error: ScopeError = .{ .error_type = error_type };
    const text = sliceFromView(message);
    scope_error.len = @min(text.len, scope_error.buffer.len);
    @memcpy(scope_error.buffer[0..scope_error.len], text[0..scope_error.len]);
    result.scope_error = scope_error;
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
