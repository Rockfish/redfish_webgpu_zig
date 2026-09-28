const std = @import("std");
const core = @import("core");
const math = @import("math");

const ResourceManager = core.ResourceManager;
const Frame = core.Frame;
const Shader = core.Shader;
const Lines = core.shapes.Lines;
const LineSegment = core.shapes.LineSegment;
const vec3 = math.vec3;

const world_axis = [_]LineSegment{
    .{ .start = vec3(-10.0, 0.0, 0.0), .end = vec3(10.0, 0.0, 0.0), .color = .red },
    .{ .start = vec3(0.0, -10.0, 0.0), .end = vec3(0.0, 10.0, 0.0), .color = .green },
    .{ .start = vec3(0.0, 0.0, 10.0), .end = vec3(0.0, 0.0, -10.0), .color = .blue },
};

const WorldAxis = struct {
    lines: [3]LineSegment,
    is_visible: bool,
};

/// redfish also had a local axis (drawLocalAxis), never drawn and written against an old
/// math API; it is not ported.
pub const AxisLines = struct {
    world_axis: WorldAxis,
    lines: Lines,
    shader: *Shader,

    const Self = @This();

    pub fn init(rm: *ResourceManager) !Self {
        const shader = try rm.createShader("examples/bullets/shaders/lines.wgsl", .{
            .vertex_buffers = &Lines.vertex_buffer_layouts,
            .topology = .line_list,
        });

        return Self{
            .world_axis = .{
                .lines = world_axis,
                .is_visible = true,
            },
            .lines = try Lines.init(rm.context.alloc, shader, 10.0, 1.0, 3),
            .shader = shader,
        };
    }

    pub fn draw(self: *Self, frame: *const Frame) void {
        self.drawWorldAxis(frame);
    }

    pub fn drawWorldAxis(self: *Self, frame: *const Frame) void {
        if (!self.world_axis.is_visible) {
            return;
        }
        self.lines.draw(frame, &self.world_axis.lines);
    }
};
