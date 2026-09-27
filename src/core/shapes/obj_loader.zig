const std = @import("std");
const containers = @import("containers");
const shape = @import("shape.zig");
const GpuContext = @import("../gpu_context.zig").GpuContext;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Shape = shape.Shape;
const ShapeBuilder = shape.ShapeBuilder;
const ManagedArrayList = containers.ManagedArrayList;

const default_color = [4]f32{ 0.5, 0.5, 0.5, 1.0 };

pub fn loadOBJ(io: Io, allocator: Allocator, gpu: *const GpuContext, filepath: []const u8) !*Shape {
    const file_data = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        filepath,
        allocator,
        .unlimited,
        .@"4",
        null,
    ) catch |err| std.debug.panic("Error reading file. error: '{any}'  file: '{s}'\n", .{ err, filepath });
    defer allocator.free(file_data);

    const dir_path = dirName(filepath);
    const materials = try parseMtlFromOBJ(io, allocator, file_data, dir_path);
    defer {
        var mats = materials;
        mats.deinit();
    }

    var builder = ShapeBuilder.init(allocator, .custom);
    defer builder.deinit();

    var positions = ManagedArrayList([3]f32).init(allocator);
    defer positions.deinit();
    var normals = ManagedArrayList([3]f32).init(allocator);
    defer normals.deinit();
    var texcoords = ManagedArrayList([2]f32).init(allocator);
    defer texcoords.deinit();

    var current_color = default_color;

    var lines_iter = std.mem.splitScalar(u8, file_data, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "v ")) {
            const pos = parseVec3(line[2..]) orelse continue;
            try positions.append(pos);
        } else if (std.mem.startsWith(u8, line, "vn ")) {
            const n = parseVec3(line[3..]) orelse continue;
            try normals.append(n);
        } else if (std.mem.startsWith(u8, line, "vt ")) {
            const tc = parseVec2(line[3..]) orelse continue;
            try texcoords.append(tc);
        } else if (std.mem.startsWith(u8, line, "usemtl ")) {
            const mat_name = std.mem.trim(u8, line[7..], " \t");
            if (materials.get(mat_name)) |kd| {
                current_color = .{ kd[0], kd[1], kd[2], 1.0 };
            } else {
                current_color = default_color;
            }
        } else if (std.mem.startsWith(u8, line, "f ")) {
            try parseFace(
                &builder,
                line[2..],
                positions.items(),
                normals.items(),
                texcoords.items(),
                current_color,
            );
        }
    }

    return try builder.build(gpu);
}

fn parseFace(
    builder: *ShapeBuilder,
    face_line: []const u8,
    positions: []const [3]f32,
    normals: []const [3]f32,
    texcoords: []const [2]f32,
    color: [4]f32,
) !void {
    var face_buf: [16]u32 = undefined;
    var face_count: usize = 0;

    var tokens = std.mem.tokenizeAny(u8, face_line, " \t");
    while (tokens.next()) |token| {
        if (face_count >= face_buf.len) break;
        const vert = parseFaceVertex(token, positions, normals, texcoords) orelse continue;
        const idx = try builder.addVertex(vert.pos, vert.normal, vert.tc);
        try builder.colors.append(color);
        face_buf[face_count] = idx;
        face_count += 1;
    }

    // Fan triangulation: (v0, v1, v2), (v0, v2, v3), ...
    const verts = face_buf[0..face_count];
    if (verts.len < 3) return;
    for (2..verts.len) |i| {
        try builder.addIndex(verts[0]);
        try builder.addIndex(verts[i - 1]);
        try builder.addIndex(verts[i]);
    }
}

const FaceVertex = struct {
    pos: [3]f32,
    normal: [3]f32,
    tc: [2]f32,
};

fn parseFaceVertex(
    token: []const u8,
    positions: []const [3]f32,
    normals: []const [3]f32,
    texcoords: []const [2]f32,
) ?FaceVertex {
    var parts = std.mem.splitScalar(u8, token, '/');
    const pos_str = parts.next() orelse return null;
    const tc_str = parts.next() orelse "";
    const norm_str = parts.next() orelse "";

    const pos_idx = parseObjIndex(pos_str) orelse return null;
    if (pos_idx >= positions.len) return null;

    var result = FaceVertex{
        .pos = positions[pos_idx],
        .normal = .{ 0.0, 1.0, 0.0 },
        .tc = .{ 0.0, 0.0 },
    };

    if (norm_str.len > 0) {
        const norm_idx = parseObjIndex(norm_str) orelse return null;
        if (norm_idx < normals.len) {
            result.normal = normals[norm_idx];
        }
    }

    if (tc_str.len > 0) {
        const tc_idx = parseObjIndex(tc_str) orelse return null;
        if (tc_idx < texcoords.len) {
            result.tc = texcoords[tc_idx];
        }
    }

    return result;
}

fn parseObjIndex(str: []const u8) ?usize {
    const val = std.fmt.parseInt(i32, str, 10) catch return null;
    if (val <= 0) return null;
    return @intCast(val - 1);
}

fn parseVec3(str: []const u8) ?[3]f32 {
    var tokens = std.mem.tokenizeAny(u8, str, " \t");
    const x = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null;
    const y = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null;
    const z = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null;
    return .{ x, y, z };
}

fn parseVec2(str: []const u8) ?[2]f32 {
    var tokens = std.mem.tokenizeAny(u8, str, " \t");
    const u = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null;
    const v = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null;
    return .{ u, v };
}

fn dirName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[0 .. idx + 1];
    }
    return "";
}

fn parseMtlFromOBJ(
    io: Io,
    allocator: Allocator,
    obj_data: []const u8,
    dir_path: []const u8,
) !std.StringHashMap([3]f32) {
    var materials = std.StringHashMap([3]f32).init(allocator);

    var lines_iter = std.mem.splitScalar(u8, obj_data, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "mtllib ")) {
            const mtl_name = std.mem.trim(u8, line[7..], " \t");
            const mtl_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_path, mtl_name });
            defer allocator.free(mtl_path);
            parseMtlFile(io, allocator, mtl_path, &materials) catch {
                std.debug.print("OBJ loader: could not load MTL file: {s}\n", .{mtl_path});
            };
        }
    }

    return materials;
}

fn parseMtlFile(
    io: Io,
    allocator: Allocator,
    filepath: []const u8,
    materials: *std.StringHashMap([3]f32),
) !void {
    const file_data = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        filepath,
        allocator,
        .unlimited,
        .@"4",
        null,
    ) catch |err| std.debug.panic("Error reading file. error: '{any}'  file: '{s}'\n", .{ err, filepath });
    defer allocator.free(file_data);

    var current_name: ?[]const u8 = null;

    var lines_iter = std.mem.splitScalar(u8, file_data, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "newmtl ")) {
            const name = std.mem.trim(u8, line[7..], " \t");
            current_name = try allocator.dupe(u8, name);
        } else if (std.mem.startsWith(u8, line, "Kd ")) {
            if (current_name) |name| {
                const kd = parseVec3(line[3..]) orelse continue;
                try materials.put(name, kd);
                current_name = null;
            }
        }
    }
}
