const std = @import("std");
const core = @import("core");
const zstbi = @import("zstbi");

const Frame = core.Frame;
const GpuContext = core.GpuContext;
const ScreenCapture = core.ScreenCapture;
const UniformDebug = core.UniformDebug;

/// F12: the scene (without the UI) as a PNG, plus the frame's uniforms as JSON, both
/// named by one timestamp under `temp/`. The scene is drawn a second time into a
/// capture frame, so the window never shows a missing frame.
pub const ScreenshotManager = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    capture: ScreenCapture,
    temp_dir: []const u8,

    const Self = @This();

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
        return Self{
            .io = io,
            .allocator = allocator,
            .capture = .{},
            .temp_dir = "temp",
        };
    }

    pub fn deinit(self: *Self) void {
        self.capture.releaseGpuObjects();
    }

    /// Draw the scene into the returned frame, then call `takeScreenshot` with it.
    /// Enable `gpu.uniform_debug` before drawing to capture the uniforms.
    pub fn beginCapture(self: *Self, gpu: *GpuContext, clear_color: [4]f64) Frame {
        return self.capture.beginFrame(gpu, clear_color);
    }

    pub fn takeScreenshot(self: *Self, frame: Frame, shader_path: []const u8) !void {
        // Generate timestamp for synchronized filenames
        const timestamp_str = core.utils.generateTimestamp(self.io);

        std.debug.print("Taking screenshot with timestamp: {s}\n", .{timestamp_str});

        var image = try self.capture.endFrame(self.allocator, frame);
        defer image.deinit(self.allocator);

        // Ensure temp directory exists
        std.Io.Dir.cwd().createDir(self.io, self.temp_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Generate filenames with timestamp
        var uniform_filename_buf: [256]u8 = undefined;
        const uniform_filename = try std.fmt.bufPrint(&uniform_filename_buf, "{s}/{s}_pbr_uniforms.json", .{ self.temp_dir, timestamp_str });

        frame.gpu.uniform_debug.saveJson(self.io, uniform_filename, &timestamp_str, shader_path) catch |err| {
            std.debug.print("Failed to save uniforms: {any}\n", .{err});
        };

        var screenshot_filename_buf: [256]u8 = undefined;
        const screenshot_filename = try std.fmt.bufPrintZ(&screenshot_filename_buf, "{s}/{s}_screenshot.png", .{ self.temp_dir, timestamp_str });

        self.savePng(image, screenshot_filename) catch |err| {
            std.debug.print("Failed to save screenshot: {any}\n", .{err});
        };

        std.debug.print("Screenshot and uniform dump complete!\n", .{});
    }

    /// RGB, as redfish wrote: the window is opaque whatever alpha the shaders output.
    fn savePng(self: *Self, image: core.screen_capture.CapturedImage, filename: [:0]const u8) !void {
        const pixel_count = @as(usize, image.width) * image.height;
        const rgb_data = try self.allocator.alloc(u8, pixel_count * 3);
        defer self.allocator.free(rgb_data);
        for (0..pixel_count) |i| {
            @memcpy(rgb_data[i * 3 ..][0..3], image.pixels[i * 4 ..][0..3]);
        }

        zstbi.init(self.io, self.allocator);
        defer zstbi.deinit();

        const png = zstbi.Image{
            .data = rgb_data,
            .width = image.width,
            .height = image.height,
            .num_components = 3, // RGB
            .bytes_per_component = 1,
            .bytes_per_row = image.width * 3,
            .is_hdr = false,
        };
        try png.writeToFile(filename, .png);

        std.debug.print("Screenshot saved: {s}\n", .{filename});
    }
};
