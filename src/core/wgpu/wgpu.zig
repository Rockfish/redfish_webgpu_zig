//! WebGPU through wgpu-native.
//!
//! `c` is webgpu.h + wgpu.h translated by the build (see webgpu.h in this directory).
//! Every translated struct field has a zero default, so descriptors are built with
//! `.{ ... }` naming only the fields that matter. The C `*_INIT` macros don't
//! translate; where a zero default is wrong, set the field explicitly.
//!
//! The helpers here cover the two C API shapes that are awkward from Zig:
//! string views and callback infos.

const std = @import("std");

pub const c = @import("webgpu_c");

pub const metal_layer = @import("metal_layer.zig");

/// A Zig string as a `WGPUStringView` (for labels, shader entry points, WGSL source).
pub fn stringView(text: []const u8) c.WGPUStringView {
    return .{ .data = text.ptr, .length = text.len };
}

/// A `WGPUStringView` from the API as a Zig slice. Handles null data and the
/// `WGPU_STRLEN` "null-terminated" length.
pub fn sliceFromView(view: c.WGPUStringView) []const u8 {
    const data = view.data orelse return "";
    if (view.length == c.WGPU_STRLEN) {
        return std.mem.span(@as([*:0]const u8, @ptrCast(data)));
    }
    return data[0..view.length];
}
