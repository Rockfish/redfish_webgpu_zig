const std = @import("std");

pub const FrameCounter = struct {
    io: std.Io,
    last_time: i64,
    frame_count: f32,
    fps: f32,
    frame_time: f32,

    const Self = @This();

    pub fn init(io: std.Io) Self {
        return .{
            .io = io,
            .last_time = std.Io.Timestamp.now(io, .awake).toMilliseconds(),
            .frame_count = 0.0,
            .frame_time = 0.0,
            .fps = 0.0,
        };
    }

    pub fn update(self: *Self) void {
        self.frame_count += 1.0;

        const current_time = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        const diff: f32 = @floatFromInt(current_time - self.last_time);
        const elapsed_secs = diff / 1000.0;

        if (elapsed_secs > 1.0) {
            const elapsed_ms = elapsed_secs * 1000.0;
            self.frame_time = elapsed_ms / self.frame_count;
            self.fps = self.frame_count / elapsed_secs;

            self.last_time = current_time;
            self.frame_count = 0.0;
        }
    }

    // Optional debug printing method
    pub fn printStats(self: *const Self) void {
        if (self.fps > 0.0) {
            std.debug.print("FPS: {d:.1}  Frame time {d:.1}ms\n", .{ self.fps, self.frame_time });
        }
    }
};
