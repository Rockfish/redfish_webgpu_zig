const std = @import("std");

const file = @import("file.zig");
const retain_ = @import("retain.zig");
const remove_ = @import("remove.zig");
const image_utils_ = @import("image_utils.zig");

pub const readFileToEnd = file.readFileToEnd;
pub const readFileToEndZ = file.readFileToEndZ;

pub const retain = retain_.retain;
pub const removeRange = remove_.removeRange;
pub const flipImageHorizontal = image_utils_.flipImageHorizontal;

/// Create a c_str using a local buffer avoiding allocation
pub fn bufCopyZ(buf: []u8, source: []const u8) [:0]const u8 {
    std.mem.copyForwards(u8, buf, source);
    buf[source.len] = 0;
    return buf[0..source.len :0];
}

// Cheap string hash
pub fn stringHash(str: []const u8, seed: u32) u32 {
    var hash: u32 = seed;
    if (str.len == 0) return hash;

    for (str) |char| {
        hash = ((hash << 5) - hash) + @as(u32, @intCast(char));
    }
    return hash;
}

pub fn strchr(str: []const u8, c: u8) ?usize {
    for (str, 0..) |char, i| {
        if (char == c) {
            return i;
        }
    }
    return null;
}

/// Generate a timestamp string in format: YYYY-MM-DD_HH.MM.SS.mmm, local time
pub fn generateTimestamp(io: std.Io) [23]u8 {
    // Wall clock; `.awake` counts from boot, which dated files in 1970.
    const millis_since_epoch = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const epoch_seconds: c_long = @intCast(@divFloor(millis_since_epoch, 1000));
    const millis: u32 = @intCast(@mod(millis_since_epoch, 1000));

    // Zig's std has no time zones; libc applies the system's, daylight saving included.
    var local: Tm = undefined;
    if (localtime_r(&epoch_seconds, &local) == null) @panic("localtime_r failed");

    const year: u32 = @intCast(local.tm_year + 1900);
    const month: u32 = @intCast(local.tm_mon + 1);
    const day: u32 = @intCast(local.tm_mday);
    const hour: u32 = @intCast(local.tm_hour);
    const minute: u32 = @intCast(local.tm_min);
    const second: u32 = @intCast(local.tm_sec);

    var result: [23]u8 = undefined;
    _ = std.fmt.bufPrint(
        &result,
        "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}.{d:0>2}.{d:0>2}.{d:0>3}",
        .{ year, month, day, hour, minute, second, millis },
    ) catch @panic("Failed to generate timestamp string");

    return result;
}

/// libc's `struct tm` (macOS and glibc layout).
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;

test {
    std.testing.refAllDecls(@This());
}

test "generateTimestamp is local wall-clock time" {
    const timestamp = generateTimestamp(std.testing.io);
    try std.testing.expectEqual('-', timestamp[4]);
    try std.testing.expectEqual('_', timestamp[10]);

    const year = try std.fmt.parseInt(u32, timestamp[0..4], 10);
    try std.testing.expect(year >= 2025);
}
