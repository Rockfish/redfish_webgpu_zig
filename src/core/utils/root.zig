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

/// Generate a timestamp string in format: YYYY-MM-DD_HH.MM.SS.mmm (UTC)
pub fn generateTimestamp(io: std.Io) [23]u8 {
    // Wall clock; `.awake` counts from boot, which dated files in 1970.
    const millis_since_epoch: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = millis_since_epoch / 1000 };
    const millis = millis_since_epoch % 1000;

    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = @as(u32, month_day.day_index) + 1;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    var result: [23]u8 = undefined;
    _ = std.fmt.bufPrint(
        &result,
        "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}.{d:0>2}.{d:0>2}.{d:0>3}",
        .{ year, month, day, hour, minute, second, millis },
    ) catch @panic("Failed to generate timestamp string");

    return result;
}

test {
    std.testing.refAllDecls(@This());
}
