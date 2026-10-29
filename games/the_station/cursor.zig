//! The game's cursors (plan 022, phase B3), drawn by the game over the frame
//! (`overlay.zig`) in place of the OS cursor: sharp at any size, in the ink look, and
//! saying what a click will do (`Game.cursor`).
//!
//! The sheet is `the-station/ui/cursors.png`, from `ui/build_cursors.py`: one row of
//! 64 px cells, 2x for a 32-unit cursor, in `Cursor`'s order. Without it the OS cursor
//! shows, as before.

const std = @import("std");
const core = @import("core");
const math = @import("math");

const overlay = @import("overlay.zig");
const Frame = core.Frame;
const GpuContext = core.GpuContext;
const Texture = core.texture.Texture;
const Overlay = overlay.Overlay;
const vec4 = math.vec4;

const log = std.log.scoped(.cursor);

pub const SHEET_PATH = "the-station/ui/cursors.png";
/// A cursor's size on screen, in window units.
const SIZE: f32 = 32.0;

/// What a click does, in the sheet's order.
pub const Cursor = enum {
    /// Walk there (the floor), or nothing in particular.
    walk,
    /// Push it (a control).
    use,
    /// Look at it.
    look,
    /// Through the open door to the room on the left, or on the right.
    exit_left,
    exit_right,
    /// Step onto the ladder.
    climb,
    /// Climb down the ladder, or up it.
    climb_down,
    climb_up,

    /// The point that clicks, 0..1 from the cursor's top-left: the arrow's tip; the
    /// others' middle.
    fn hotPoint(self: Cursor) [2]f32 {
        return switch (self) {
            .walk => .{ 6.0 / 64.0, 4.0 / 64.0 },
            .use => .{ 22.0 / 64.0, 4.0 / 64.0 },
            .look, .exit_left, .exit_right, .climb, .climb_down, .climb_up => .{ 0.5, 0.5 },
        };
    }
};

pub const CursorSheet = struct {
    texture: *Texture,

    const Self = @This();

    /// Null, with a warning, without the sheet (no the-station checkout): the OS cursor
    /// shows instead.
    pub fn load(context: core.Context, gpu: *GpuContext) ?Self {
        const texture = Texture.initFromFile(context, gpu, SHEET_PATH, .{ .flip_v = false }) catch |err| {
            log.warn("{s} not loaded ({s}); using the OS cursor", .{ SHEET_PATH, @errorName(err) });
            return null;
        };
        return .{ .texture = texture };
    }

    /// `cursor` with its click point at the mouse (`mouse_x`, `mouse_y`, window units).
    pub fn draw(
        self: *const Self,
        frame: *const Frame,
        sprites: *const Overlay,
        cursor: Cursor,
        mouse_x: f32,
        mouse_y: f32,
        window_width: f32,
        window_height: f32,
    ) void {
        const count: f32 = @floatFromInt(std.enums.values(Cursor).len);
        const index: f32 = @floatFromInt(@intFromEnum(cursor));
        const sprite: overlay.Rect = .{ .x = index / count, .y = 0.0, .width = 1.0 / count, .height = 1.0 };

        // Whole window units, so the 2x sheet lands on whole pixels
        const hot = cursor.hotPoint();
        const place: overlay.Rect = .{
            .x = @round(mouse_x - hot[0] * SIZE),
            .y = @round(mouse_y - hot[1] * SIZE),
            .width = SIZE,
            .height = SIZE,
        };
        sprites.draw(frame, self.texture, sprite, place, window_width, window_height, vec4(1.0, 1.0, 1.0, 1.0));
    }

    pub fn releaseGpuObjects(self: *const Self) void {
        self.texture.releaseGpuObjects();
    }
};
