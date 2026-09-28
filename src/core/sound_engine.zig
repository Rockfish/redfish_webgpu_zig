//! Short sound effects by name, on zaudio (miniaudio). redfish's API, which used its own
//! vendored miniaudio module.

const std = @import("std");
const zaudio = @import("zaudio");

const Allocator = std.mem.Allocator;
const EnumMap = std.EnumMap;

const log = std.log.scoped(.SoundEngine);

///    // Example set up
///
///    pub const ClipName = enum {
///        GunFire,
///        Explosion,
///    };
///
///    const ClipData = struct {
///        clip: ClipName,
///        file: [:0]const u8,
///    };
///
///    const clips: [2]ClipData = .{
///        .{ .clip = .Explosion, .file = "angrybots_assets/Audio/Enemy_SFX/enemy_Spider_DestroyedExplosion.wav" },
///        .{ .clip = .GunFire, .file = "angrybots_assets/Audio/Player_SFX/player_shooting.wav" },
///    };
///
///    var sound_engine = try SoundEngine(ClipName, ClipData).init(allocator, &clips);
///    defer sound_engine.deinit();
///
///    sound_engine.playSound(.GunFire);
///    sound_engine.playSound(.Explosion);
///
/// One engine at a time: zaudio's allocator is global.
pub fn SoundEngine(comptime clipNameType: type, comptime clipDataType: type) type {
    return struct {
        engine: *zaudio.Engine,
        clipsData: EnumMap(clipNameType, *zaudio.Sound),

        const Self = @This();

        pub fn init(allocator: Allocator, data: []const clipDataType) !Self {
            zaudio.init(allocator);
            errdefer zaudio.deinit();

            const engine = zaudio.Engine.create(null) catch |err| {
                log.info("error.AudioInitError: {any}", .{err});
                return error.AudioInitError;
            };

            var soundEngine: Self = .{
                .engine = engine,
                .clipsData = EnumMap(clipNameType, *zaudio.Sound).init(.{}),
            };
            errdefer soundEngine.destroySounds();

            for (data) |item| {
                const sound = engine.createSoundFromFile(item.file, .{
                    .flags = .{ .async_load = true, .no_pitch = true, .no_spatialization = true, .stream = true },
                }) catch |err| {
                    log.warn("Could not load sound '{s}': {any}", .{ item.file, err });
                    return error.AudioInitError;
                };
                soundEngine.clipsData.put(item.clip, sound);
            }
            return soundEngine;
        }

        pub fn deinit(self: *Self) void {
            self.destroySounds();
            zaudio.deinit();
        }

        /// Restarts the clip if it's still playing.
        pub fn playSound(self: *const Self, clip: clipNameType) void {
            const sound = self.clipsData.get(clip) orelse return;

            sound.setVolume(2.0);

            if (sound.isPlaying()) {
                sound.stop() catch {};
                sound.seekToPcmFrame(0) catch {};
            }

            sound.start() catch |err| log.info("Could not start sound: {any}", .{err});
        }

        fn destroySounds(self: *Self) void {
            var iter = self.clipsData.iterator();
            while (iter.next()) |item| {
                item.value.*.destroy();
            }
            self.clipsData = EnumMap(clipNameType, *zaudio.Sound).init(.{});
            self.engine.stop() catch {};
            self.engine.destroy();
        }
    };
}
