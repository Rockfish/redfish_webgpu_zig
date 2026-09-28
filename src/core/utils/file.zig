const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn readFileToEnd(io: Io, allocator: Allocator, file_path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const file_size = try file.length(io);
    const buf = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buf);

    const n = try file.readPositionalAll(io, buf, 0);
    if (n != buf.len) {
        return error.UnexpectedEndOfFile;
    }
    return buf;
}

pub fn readFileToEndZ(io: Io, allocator: Allocator, file_path: []const u8) ![:0]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const file_size = try file.length(io);
    const buf = try allocator.allocSentinel(u8, file_size, 0);
    errdefer allocator.free(buf);

    const n = try file.readPositionalAll(io, buf, 0);
    if (n != buf.len) {
        return error.UnexpectedEndOfFile;
    }
    return buf;
}
