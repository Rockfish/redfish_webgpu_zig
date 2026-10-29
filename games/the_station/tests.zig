//! The Station's tests: game logic that runs without a window or GPU. `zig build test`
//! runs them; app files aren't in a module the engine's tests see.

test {
    _ = @import("navigation.zig");
}
