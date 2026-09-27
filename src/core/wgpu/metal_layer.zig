//! macOS: attach a CAMetalLayer to a GLFW window's content view, for
//! `WGPUSurfaceSourceMetalLayer`. Plain Objective-C runtime calls, no Objective-C code.

/// Returns the new layer, owned by the view.
pub fn createForCocoaWindow(ns_window: *anyopaque) *anyopaque {
    const ns_view = msgSend(ns_window, "contentView", .{}, *anyopaque);
    msgSend(ns_view, "setWantsLayer:", .{true}, void);

    const layer = msgSend(objc.objc_getClass("CAMetalLayer"), "layer", .{}, ?*anyopaque) orelse
        @panic("failed to create CAMetalLayer");
    msgSend(ns_view, "setLayer:", .{layer}, void);

    // Match the window's backing scale so the drawable is full Retina resolution.
    const scale_factor = msgSend(ns_window, "backingScaleFactor", .{}, f64);
    msgSend(layer, "setContentsScale:", .{scale_factor}, void);

    return layer;
}

const objc = struct {
    const SEL = ?*opaque {};
    const Class = ?*opaque {};

    extern fn sel_getUid(name: [*:0]const u8) SEL;
    extern fn objc_getClass(name: [*:0]const u8) Class;
    extern fn objc_msgSend() void;
};

/// `[obj sel_name:args...]`, cast to the right C signature (up to 2 args).
fn msgSend(obj: anytype, sel_name: [:0]const u8, args: anytype, comptime ReturnType: type) ReturnType {
    const arg_fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const Obj = @TypeOf(obj);

    const FnType = switch (arg_fields.len) {
        0 => *const fn (Obj, objc.SEL) callconv(.c) ReturnType,
        1 => *const fn (Obj, objc.SEL, arg_fields[0].type) callconv(.c) ReturnType,
        2 => *const fn (Obj, objc.SEL, arg_fields[0].type, arg_fields[1].type) callconv(.c) ReturnType,
        else => @compileError("msgSend: unsupported number of args"),
    };

    const func: FnType = @ptrCast(&objc.objc_msgSend);
    const sel = objc.sel_getUid(sel_name.ptr);
    return @call(.never_inline, func, .{ obj, sel } ++ args);
}
