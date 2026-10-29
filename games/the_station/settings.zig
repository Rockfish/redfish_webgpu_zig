//! The panel's settings, saved one at a time to `SETTINGS_PATH` (`core.SettingsFile`):
//! the file holds only the settings saved with a value other than their default in code.
//!
//! In the panel, a setting changed since it was saved is marked `*`, and so is its
//! section. Right-click a setting to save it, revert it to the saved value, or reset it
//! to its default; each section has the same three for all its settings. Reset and revert
//! change only the value shown; the file changes on save.

const std = @import("std");
const core = @import("core");
const zgui = @import("zgui");

const ink = @import("ink.zig");
const RoomCamera = @import("room_camera.zig").RoomCamera;

const log = std.log.scoped(.settings);

/// With the room's art, in the-station's repo.
pub const SETTINGS_PATH = "the-station/settings/the_station.zon";

/// Everything the panel tunes, one section per panel section.
pub const Settings = struct {
    camera: RoomCamera = .{},
    ink: ink.Style = .{},
    room: RoomSettings = .{},
    lights: LightSettings = .{},
    alarm: AlarmSettings = .{},
};

pub const RoomSettings = struct {
    show_grid: bool = false,
    /// A box around the hotspot under the mouse.
    show_hotspot_bounds: bool = false,
    /// Draw the box robot even when the Blender model is loaded.
    use_placeholder: bool = false,
    /// Draw the room's equipment as boxes even when the Blender model is loaded.
    use_greybox: bool = false,
    /// Frame a large room whole, not a window of it following the robot
    /// (`station.cameraFraming`).
    frame_whole_room: bool = false,
};

/// The deck's light: with the power off, and with the emergency lights on.
pub const LightSettings = struct {
    /// Ambient light with the lights off (the alarm and the glowing screen show too).
    dark: f32 = 0.05,
    /// The emergency lights' brightness: a yellowish light from each room's ceiling.
    emergency: f32 = 0.8,
};

pub const AlarmSettings = struct {
    /// Pulses per second.
    rate: f32 = 0.8,
    /// The alarm light's brightness at the top of a pulse.
    intensity: f32 = 4.0,
};

pub const File = core.SettingsFile(Settings);
const Section = File.Section;
const Field = File.Field;

/// Panel widgets for settings, each with its save / revert / reset menu.
pub const Panel = struct {
    file: *File,
    values: *Settings,

    const Self = @This();

    /// The section's heading (marked when anything in it is unsaved) and its buttons.
    pub fn section(self: Self, comptime which: Section, comptime label: [:0]const u8) void {
        const is_changed = self.file.isSectionChanged(self.values, which);
        zgui.separatorText(if (is_changed) label ++ " *" else label);

        zgui.pushStrIdZ(@tagName(which));
        defer zgui.popId();
        if (zgui.smallButton("save")) {
            self.file.saveSection(self.values, which) catch |err| reportSaveError(err);
        }
        zgui.sameLine(.{});
        if (zgui.smallButton("revert")) {
            self.file.applySection(self.values, which);
        }
        zgui.sameLine(.{});
        if (zgui.smallButton("defaults")) {
            File.resetSection(self.values, which);
        }
    }

    pub fn slider(self: Self, comptime which: Section, comptime field: Field(which), comptime label: [:0]const u8, min: f32, max: f32) void {
        _ = zgui.sliderFloat(label, .{ .v = self.valuePtr(which, field), .min = min, .max = max });
        self.settingMenu(which, field);
    }

    pub fn checkbox(self: Self, comptime which: Section, comptime field: Field(which), comptime label: [:0]const u8) void {
        _ = zgui.checkbox(label, .{ .v = self.valuePtr(which, field) });
        self.settingMenu(which, field);
    }

    pub fn combo(self: Self, comptime which: Section, comptime field: Field(which), comptime label: [:0]const u8) void {
        _ = zgui.comboFromEnum(label, self.valuePtr(which, field));
        self.settingMenu(which, field);
    }

    /// For the widget just drawn: a `*` after it when unsaved, and its right-click menu.
    fn settingMenu(self: Self, comptime which: Section, comptime field: Field(which)) void {
        if (zgui.beginPopupContextItem()) {
            if (zgui.menuItem("save", .{})) {
                self.file.save(self.values, which, field) catch |err| reportSaveError(err);
            }
            if (zgui.menuItem("revert to saved", .{})) {
                self.file.revert(self.values, which, field);
            }
            if (zgui.menuItem("reset to default", .{})) {
                File.reset(self.values, which, field);
            }
            zgui.endPopup();
        }
        if (self.file.isChanged(self.values, which, field)) {
            zgui.sameLine(.{});
            zgui.text("*", .{});
        }
    }

    fn valuePtr(self: Self, comptime which: Section, comptime field: Field(which)) *@FieldType(@FieldType(Settings, @tagName(which)), @tagName(field)) {
        return &@field(@field(self.values, @tagName(which)), @tagName(field));
    }
};

fn reportSaveError(err: anyerror) void {
    log.warn("{s}: not saved ({s})", .{ SETTINGS_PATH, @errorName(err) });
}
