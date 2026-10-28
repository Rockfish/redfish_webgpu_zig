//! Settings saved from a tuning panel to a ZON file, one setting at a time.
//!
//! `Values` is a struct of sections, each a struct of settings with defaults in code:
//!
//!     const Values = struct { camera: RoomCamera = .{}, ink: ink.Style = .{} };
//!
//! The file holds only the settings saved with a value other than their default, so a
//! default changed in code still applies to every setting not saved:
//!
//!     .{
//!         .camera = .{ .distance = 6.5 },
//!     }
//!
//! `save` writes a setting's current value to the file, `revert` puts it back to the saved
//! value, and `reset` to its default; reset touches only the value in memory, so the file
//! changes only on save (saving a default removes it from the file). Settings in the file
//! this program doesn't have (renamed or removed) are skipped, and dropped on the next
//! save. A file that isn't readable as these settings is reported and never written over.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.settings_file);

/// Larger than any settings file; a guard against reading the wrong file.
const MAX_FILE_SIZE = 1 << 20;

const HEADER =
    \\// Settings saved from the panel: only those that differ from the defaults in code.
    \\// Hand edits are read at startup; comments are lost on the next save.
    \\
;

pub fn SettingsFile(comptime Values: type) type {
    return struct {
        allocator: Allocator,
        io: Io,
        path: []const u8,
        /// A value for each saved setting, null for the rest.
        saved: Saved = .{},
        /// The file is there but couldn't be read as these settings: it isn't written over.
        is_unreadable: bool = false,

        const Self = @This();

        pub const Saved = SavedValues(Values);
        pub const Section = std.meta.FieldEnum(Values);

        pub fn Field(comptime section: Section) type {
            // Evaluated for every setting of every section
            @setEvalBranchQuota(10_000);
            return std.meta.FieldEnum(SectionType(section));
        }

        fn SectionType(comptime section: Section) type {
            return @FieldType(Values, @tagName(section));
        }

        fn FieldType(comptime section: Section, comptime field: Field(section)) type {
            return @FieldType(SectionType(section), @tagName(field));
        }

        const defaults: Values = .{};

        /// Reads the file at `path`; no file means nothing saved. `allocator` is kept for
        /// writing; `path` must outlive the result.
        pub fn load(allocator: Allocator, io: Io, path: []const u8) Self {
            var self: Self = .{ .allocator = allocator, .io = io, .path = path };
            const source = Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(MAX_FILE_SIZE), .of(u8), 0) catch |err| {
                if (err != error.FileNotFound) {
                    log.warn("{s}: not read ({s}); it won't be saved over", .{ path, @errorName(err) });
                    self.is_unreadable = true;
                }
                return self;
            };
            defer allocator.free(source);

            self.saved = parse(allocator, path, source) catch {
                self.is_unreadable = true;
                return self;
            };
            return self;
        }

        /// Puts each saved value into `values`.
        pub fn apply(self: *const Self, values: *Values) void {
            inline for (comptime std.enums.values(Section)) |section| {
                self.applySection(values, section);
            }
        }

        pub fn applySection(self: *const Self, values: *Values, comptime section: Section) void {
            inline for (comptime std.enums.values(Field(section))) |field| {
                self.revert(values, section, field);
            }
        }

        /// Whether the setting differs from what the file gives it (saved or default).
        pub fn isChanged(self: *const Self, values: *const Values, comptime section: Section, comptime field: Field(section)) bool {
            const current = valueOf(values, section, field).*;
            return !std.meta.eql(current, self.savedValue(section, field));
        }

        /// Whether any setting in the section differs from what the file gives it.
        pub fn isSectionChanged(self: *const Self, values: *const Values, comptime section: Section) bool {
            inline for (comptime std.enums.values(Field(section))) |field| {
                if (self.isChanged(values, section, field)) {
                    return true;
                }
            }
            return false;
        }

        /// Writes the setting's current value to the file.
        pub fn save(self: *Self, values: *const Values, comptime section: Section, comptime field: Field(section)) !void {
            self.setSaved(section, field, valueOf(values, section, field).*);
            try self.write();
        }

        pub fn saveSection(self: *Self, values: *const Values, comptime section: Section) !void {
            inline for (comptime std.enums.values(Field(section))) |field| {
                self.setSaved(section, field, valueOf(values, section, field).*);
            }
            try self.write();
        }

        /// Puts the setting back to its saved value, or its default if not saved.
        pub fn revert(self: *const Self, values: *Values, comptime section: Section, comptime field: Field(section)) void {
            valueOf(values, section, field).* = self.savedValue(section, field);
        }

        /// Puts the setting back to its default in code. The file is unchanged until a save.
        pub fn reset(values: *Values, comptime section: Section, comptime field: Field(section)) void {
            valueOf(values, section, field).* = defaultValue(section, field);
        }

        pub fn resetSection(values: *Values, comptime section: Section) void {
            @field(values, @tagName(section)) = @field(defaults, @tagName(section));
        }

        fn savedValue(self: *const Self, comptime section: Section, comptime field: Field(section)) FieldType(section, field) {
            return @field(@field(self.saved, @tagName(section)), @tagName(field)) orelse defaultValue(section, field);
        }

        /// Null for the default, so the file holds only what differs.
        fn setSaved(self: *Self, comptime section: Section, comptime field: Field(section), value: FieldType(section, field)) void {
            const is_default = std.meta.eql(value, defaultValue(section, field));
            @field(@field(self.saved, @tagName(section)), @tagName(field)) = if (is_default) null else value;
        }

        fn write(self: *const Self) !void {
            if (self.is_unreadable) {
                log.warn("{s}: not saved; the file couldn't be read, so it isn't written over", .{self.path});
                return error.UnreadableSettingsFile;
            }
            var out: Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            try serialize(self.saved, &out.writer);

            if (std.fs.path.dirname(self.path)) |dir| {
                try Io.Dir.cwd().createDirPath(self.io, dir);
            }
            try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = out.written() });
        }

        fn parse(allocator: Allocator, path: []const u8, source: [:0]const u8) !Saved {
            var diagnostics: std.zon.parse.Diagnostics = .{};
            defer diagnostics.deinit(allocator);
            return std.zon.parse.fromSlice(Saved, allocator, source, &diagnostics, .{ .ignore_unknown_fields = true }) catch |err| {
                if (err == error.ParseZon) {
                    log.warn("{s}: {f}; it won't be saved over", .{ path, diagnostics });
                }
                return err;
            };
        }

        /// One setting per line; sections with nothing saved and settings not saved
        /// (null) are left out.
        fn serialize(saved: Saved, writer: *Io.Writer) !void {
            try writer.writeAll(HEADER);
            var serializer: std.zon.Serializer = .{ .writer = writer };
            var file = try serializer.beginStruct(.{});
            inline for (comptime std.enums.values(Section)) |section| {
                const saved_section = @field(saved, @tagName(section));
                if (!std.meta.eql(saved_section, .{})) {
                    var fields = try file.beginStructField(@tagName(section), .{});
                    inline for (comptime std.enums.values(Field(section))) |field| {
                        if (@field(saved_section, @tagName(field))) |value| {
                            try fields.field(@tagName(field), value, .{});
                        }
                    }
                    try fields.end();
                }
            }
            try file.end();
            try writer.writeByte('\n');
        }

        fn valueOf(values: anytype, comptime section: Section, comptime field: Field(section)) switch (@TypeOf(values)) {
            *Values => *FieldType(section, field),
            else => *const FieldType(section, field),
        } {
            return &@field(@field(values, @tagName(section)), @tagName(field));
        }

        fn defaultValue(comptime section: Section, comptime field: Field(section)) FieldType(section, field) {
            return @field(@field(defaults, @tagName(section)), @tagName(field));
        }
    };
}

/// `Values` with each section's settings optional and null.
fn SavedValues(comptime Values: type) type {
    const sections = @typeInfo(Values).@"struct".fields;
    var names: [sections.len][]const u8 = undefined;
    var types: [sections.len]type = undefined;
    var attributes: [sections.len]std.builtin.Type.StructField.Attributes = undefined;
    for (sections, &names, &types, &attributes) |section, *name, *Type, *attribute| {
        name.* = section.name;
        Type.* = Optionals(section.type);
        attribute.* = .{ .default_value_ptr = emptyValue(Type.*) };
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

/// `T` with every field optional and null.
fn Optionals(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attributes: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, &names, &types, &attributes) |field, *name, *Type, *attribute| {
        name.* = field.name;
        Type.* = ?field.type;
        attribute.* = .{ .default_value_ptr = emptyValue(Type.*) };
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

/// A pointer to `T`'s empty value (`.{}`, or null for an optional), for a field default.
fn emptyValue(comptime T: type) *const anyopaque {
    const Empty = struct {
        const value: T = if (@typeInfo(T) == .optional) null else .{};
    };
    return &Empty.value;
}

const TestCamera = struct {
    distance: f32 = 6.0,
    view: enum { shifted, aimed } = .shifted,
};
const TestInk = struct {
    show_outlines: bool = true,
    spacing: f32 = 0.14,
};
const TestValues = struct {
    camera: TestCamera = .{},
    ink: TestInk = .{},
};
const TestFile = SettingsFile(TestValues);

fn testFile() TestFile {
    return .{ .allocator = std.testing.allocator, .io = std.testing.io, .path = "unused.zon" };
}

test "SettingsFile: saving a setting keeps it; saving its default drops it" {
    var file = testFile();
    var values: TestValues = .{};

    values.camera.distance = 8.0;
    try std.testing.expect(file.isChanged(&values, .camera, .distance));
    file.setSaved(.camera, .distance, values.camera.distance);
    try std.testing.expect(!file.isChanged(&values, .camera, .distance));
    try std.testing.expectEqual(@as(?f32, 8.0), file.saved.camera.distance);

    file.setSaved(.camera, .distance, 6.0);
    try std.testing.expectEqual(@as(?f32, null), file.saved.camera.distance);
}

test "SettingsFile: revert goes to the saved value, reset to the default" {
    var file = testFile();
    var values: TestValues = .{};
    file.setSaved(.ink, .spacing, 0.2);

    values.ink.spacing = 0.05;
    file.revert(&values, .ink, .spacing);
    try std.testing.expectEqual(@as(f32, 0.2), values.ink.spacing);

    TestFile.reset(&values, .ink, .spacing);
    try std.testing.expectEqual(@as(f32, 0.14), values.ink.spacing);
    try std.testing.expect(file.isSectionChanged(&values, .ink));
    try std.testing.expect(!file.isSectionChanged(&values, .camera));
}

test "SettingsFile: writes only saved settings and reads them back" {
    var file = testFile();
    file.setSaved(.camera, .view, .aimed);
    file.setSaved(.ink, .show_outlines, false);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try TestFile.serialize(file.saved, &out.writer);
    const text = try std.testing.allocator.dupeZ(u8, out.written());
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "distance") == null);

    var values: TestValues = .{};
    file.saved = try TestFile.parse(std.testing.allocator, "test", text);
    file.apply(&values);
    try std.testing.expectEqual(.aimed, values.camera.view);
    try std.testing.expectEqual(false, values.ink.show_outlines);
    try std.testing.expectEqual(@as(f32, 6.0), values.camera.distance);
}

test "SettingsFile: settings the file has and the program doesn't are skipped" {
    const text = ".{ .camera = .{ .distance = 7.5, .zoom = 2.0 }, .sound = .{} }";
    const saved = try TestFile.parse(std.testing.allocator, "test", text);
    try std.testing.expectEqual(@as(?f32, 7.5), saved.camera.distance);
}
