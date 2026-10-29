//! The Station's tests: game logic that runs without a window or GPU. `zig build test`
//! runs them; app files aren't in a module the engine's tests see.

const std = @import("std");

test {
    _ = @import("navigation.zig");
    _ = @import("room_kit.zig");
    // Analyzes every declaration, called by the game yet or not
    std.testing.refAllDecls(@import("room_kit.zig"));
}
