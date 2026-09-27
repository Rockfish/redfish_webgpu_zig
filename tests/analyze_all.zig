//! Forces semantic analysis of every public declaration in math, containers, and core.
//! Zig only analyzes what is referenced, so without this a function no app calls yet
//! could be broken and still "build".

const std = @import("std");
const core = @import("core");
const math = @import("math");
const containers = @import("containers");

test "analyze all public declarations" {
    refAllDeclsRecursive(math, 8);
    refAllDeclsRecursive(containers, 8);
    refAllDeclsRecursive(core, 8);
}

/// Like `std.testing.refAllDecls`, but also descends into public struct, enum, and union
/// declarations. `depth` stops re-export cycles.
fn refAllDeclsRecursive(comptime T: type, comptime depth: u32) void {
    if (depth == 0) return;

    inline for (comptime std.meta.declarations(T)) |decl| {
        // Taking the address is what forces a function body to be analyzed.
        _ = &@field(T, decl.name);

        const value = @field(T, decl.name);
        if (@TypeOf(value) == type) {
            switch (@typeInfo(value)) {
                .@"struct", .@"enum", .@"union" => refAllDeclsRecursive(value, depth - 1),
                else => {},
            }
        }
    }
}
