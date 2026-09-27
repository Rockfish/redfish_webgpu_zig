const std = @import("std");
const json = std.json;
const gltf_types = @import("gltf.zig");
const GLTF = gltf_types.GLTF;
const Allocator = std.mem.Allocator;
const math = @import("math");

const ParseError = error{
    OutOfMemory,
    MissingAsset,
    MissingVersion,
    InvalidJson,
    InvalidEnum,
    InvalidIndex,
};

pub fn parseGltfJson(alloc: Allocator, temp_alloc: Allocator, json_buffer: []const u8) !GLTF {
    var gltf_parsed = json.parseFromSlice(json.Value, temp_alloc, json_buffer, .{}) catch {
        return ParseError.InvalidJson;
    };
    defer gltf_parsed.deinit();

    const gltf_json = gltf_parsed.value;
    if (gltf_json != .object) {
        return ParseError.InvalidJson;
    }

    var gltf = GLTF{
        .asset = undefined,
        .scenes = null,
        .scene = null,
        .nodes = null,
        .meshes = null,
        .accessors = null,
        .buffer_views = null,
        .buffers = null,
        .materials = null,
        .samplers = null,
        .textures = null,
        .images = null,
        .animations = null,
        .skins = null,
        .cameras = null,
    };

    const asset_json = gltf_json.object.get("asset") orelse return ParseError.MissingAsset;
    gltf.asset = try parseAsset(alloc, asset_json);

    if (gltf_json.object.get("scene")) |scene_json| {
        if (scene_json == .integer) {
            gltf.scene = @intCast(scene_json.integer);
        }
    }

    if (gltf_json.object.get("scenes")) |scenes_json| {
        if (scenes_json == .array) {
            gltf.scenes = try parseScenes(alloc, scenes_json);
        }
    }

    if (gltf_json.object.get("nodes")) |nodes_json| {
        if (nodes_json == .array) {
            gltf.nodes = try parseNodes(alloc, nodes_json);
        }
    }

    if (gltf_json.object.get("meshes")) |meshes_json| {
        if (meshes_json == .array) {
            gltf.meshes = try parseMeshes(alloc, meshes_json);
        }
    }

    if (gltf_json.object.get("accessors")) |accessors_json| {
        if (accessors_json == .array) {
            gltf.accessors = try parseAccessors(alloc, accessors_json);
        }
    }

    if (gltf_json.object.get("bufferViews")) |buffer_views_json| {
        if (buffer_views_json == .array) {
            gltf.buffer_views = try parseBufferViews(alloc, buffer_views_json);
        }
    }

    if (gltf_json.object.get("buffers")) |buffers_json| {
        if (buffers_json == .array) {
            gltf.buffers = try parseBuffers(alloc, buffers_json);
        }
    }

    if (gltf_json.object.get("materials")) |materials_json| {
        if (materials_json == .array) {
            gltf.materials = try parseMaterials(alloc, materials_json);
        }
    }

    if (gltf_json.object.get("samplers")) |samplers_json| {
        if (samplers_json == .array) {
            gltf.samplers = try parseSamplers(alloc, samplers_json);
        }
    }

    if (gltf_json.object.get("textures")) |textures_json| {
        if (textures_json == .array) {
            gltf.textures = try parseTextures(alloc, textures_json);
        }
    }

    if (gltf_json.object.get("images")) |images_json| {
        if (images_json == .array) {
            gltf.images = try parseImages(alloc, images_json);
        }
    }

    if (gltf_json.object.get("animations")) |animations_json| {
        if (animations_json == .array) {
            gltf.animations = try parseAnimations(alloc, animations_json);
        }
    }

    if (gltf_json.object.get("skins")) |skins_json| {
        if (skins_json == .array) {
            gltf.skins = try parseSkins(alloc, skins_json);
        }
    }

    if (gltf_json.object.get("cameras")) |cameras_json| {
        if (cameras_json == .array) {
            gltf.cameras = try parseCameras(alloc, cameras_json);
        }
    }

    return gltf;
}

fn parseAsset(allocator: Allocator, asset_json: json.Value) !gltf_types.Asset {
    if (asset_json != .object) {
        return ParseError.InvalidJson;
    }

    const version_json = asset_json.object.get("version") orelse return ParseError.MissingVersion;
    if (version_json != .string) {
        return ParseError.MissingVersion;
    }
    const version_str = try allocator.dupe(u8, version_json.string);

    var generator_str: ?[]const u8 = null;
    if (asset_json.object.get("generator")) |generator_json| {
        if (generator_json == .string) {
            generator_str = try allocator.dupe(u8, generator_json.string);
        }
    }

    var copyright_str: ?[]const u8 = null;
    if (asset_json.object.get("copyright")) |copyright_json| {
        if (copyright_json == .string) {
            copyright_str = try allocator.dupe(u8, copyright_json.string);
        }
    }

    var min_version_str: ?[]const u8 = null;
    if (asset_json.object.get("minVersion")) |min_version_json| {
        if (min_version_json == .string) {
            min_version_str = try allocator.dupe(u8, min_version_json.string);
        }
    }

    return gltf_types.Asset{
        .version = version_str,
        .generator = generator_str,
        .copyright = copyright_str,
        .min_version = min_version_str,
    };
}

fn parseScenes(allocator: Allocator, scenes_json: json.Value) ![]gltf_types.Scene {
    const scenes = try allocator.alloc(gltf_types.Scene, scenes_json.array.items.len);

    for (scenes_json.array.items, 0..) |scene_json, index| {
        scenes[index] = try parseScene(allocator, scene_json);
    }

    return scenes;
}

fn parseScene(allocator: Allocator, scene_json: json.Value) !gltf_types.Scene {
    if (scene_json != .object) {
        return ParseError.InvalidJson;
    }

    var nodes: ?[]u32 = null;
    if (scene_json.object.get("nodes")) |nodes_json| {
        if (nodes_json == .array) {
            nodes = try allocator.alloc(u32, nodes_json.array.items.len);
            for (nodes_json.array.items, 0..) |node_json, index| {
                if (node_json == .integer) {
                    nodes.?[index] = @intCast(node_json.integer);
                }
            }
        }
    }

    var name_str: ?[]const u8 = null;
    if (scene_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Scene{
        .nodes = nodes,
        .name = name_str,
    };
}

fn parseNodes(allocator: Allocator, nodes_json: json.Value) ![]gltf_types.Node {
    const nodes = try allocator.alloc(gltf_types.Node, nodes_json.array.items.len);

    for (nodes_json.array.items, 0..) |node_json, index| {
        nodes[index] = try parseNode(allocator, node_json);
    }

    return nodes;
}

fn parseNode(allocator: Allocator, node_json: json.Value) !gltf_types.Node {
    if (node_json != .object) {
        return ParseError.InvalidJson;
    }

    var children: ?[]u32 = null;
    if (node_json.object.get("children")) |children_json| {
        if (children_json == .array) {
            children = try allocator.alloc(u32, children_json.array.items.len);
            for (children_json.array.items, 0..) |child_json, index| {
                if (child_json == .integer) {
                    children.?[index] = @intCast(child_json.integer);
                }
            }
        }
    }

    var mesh_index: ?u32 = null;
    if (node_json.object.get("mesh")) |mesh_json| {
        if (mesh_json == .integer) {
            mesh_index = @intCast(mesh_json.integer);
        }
    }

    var skin_index: ?u32 = null;
    if (node_json.object.get("skin")) |skin_json| {
        if (skin_json == .integer) {
            skin_index = @intCast(skin_json.integer);
        }
    }

    var camera_index: ?u32 = null;
    if (node_json.object.get("camera")) |camera_json| {
        if (camera_json == .integer) {
            camera_index = @intCast(camera_json.integer);
        }
    }

    var matrix: ?math.Mat4 = null;
    if (node_json.object.get("matrix")) |matrix_json| {
        if (matrix_json == .array and matrix_json.array.items.len == 16) {
            var mat_data = [4][4]f32{
                [_]f32{0.0} ** 4,
                [_]f32{0.0} ** 4,
                [_]f32{0.0} ** 4,
                [_]f32{0.0} ** 4,
            };
            for (matrix_json.array.items, 0..) |value_json, index| {
                const col = index / 4;
                const row = index % 4;
                if (value_json == .float) {
                    mat_data[col][row] = @floatCast(value_json.float);
                } else if (value_json == .integer) {
                    mat_data[col][row] = @floatFromInt(value_json.integer);
                }
            }
            matrix = math.Mat4{ .data = mat_data };
        }
    }

    var translation: ?math.Vec3 = null;
    if (node_json.object.get("translation")) |translation_json| {
        if (translation_json == .array and translation_json.array.items.len == 3) {
            var vec_data = [_]f32{0.0} ** 3;
            for (translation_json.array.items, 0..) |value_json, index| {
                if (value_json == .float) {
                    vec_data[index] = @floatCast(value_json.float);
                } else if (value_json == .integer) {
                    vec_data[index] = @floatFromInt(value_json.integer);
                }
            }
            translation = math.Vec3{ .x = vec_data[0], .y = vec_data[1], .z = vec_data[2] };
        }
    }

    var rotation: ?math.Quat = null;
    if (node_json.object.get("rotation")) |rotation_json| {
        if (rotation_json == .array and rotation_json.array.items.len == 4) {
            var quat_data = [_]f32{0.0} ** 4;
            for (rotation_json.array.items, 0..) |value_json, index| {
                if (value_json == .float) {
                    quat_data[index] = @floatCast(value_json.float);
                } else if (value_json == .integer) {
                    quat_data[index] = @floatFromInt(value_json.integer);
                }
            }
            rotation = math.Quat.fromArray(quat_data);
        }
    }

    var scale: ?math.Vec3 = null;
    if (node_json.object.get("scale")) |scale_json| {
        if (scale_json == .array and scale_json.array.items.len == 3) {
            var vec_data = [_]f32{0.0} ** 3;
            for (scale_json.array.items, 0..) |value_json, index| {
                if (value_json == .float) {
                    vec_data[index] = @floatCast(value_json.float);
                } else if (value_json == .integer) {
                    vec_data[index] = @floatFromInt(value_json.integer);
                }
            }
            scale = math.Vec3{ .x = vec_data[0], .y = vec_data[1], .z = vec_data[2] };
        }
    }

    var name_str: ?[]const u8 = null;
    if (node_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Node{
        .children = children,
        .mesh = mesh_index,
        .skin = skin_index,
        .camera = camera_index,
        .matrix = matrix,
        .translation = translation,
        .rotation = rotation,
        .scale = scale,
        .name = name_str,
    };
}

fn parseComponentType(value: i64) !gltf_types.ComponentType {
    return switch (value) {
        5120 => gltf_types.ComponentType.byte,
        5121 => gltf_types.ComponentType.unsigned_byte,
        5122 => gltf_types.ComponentType.short,
        5123 => gltf_types.ComponentType.unsigned_short,
        5125 => gltf_types.ComponentType.unsigned_int,
        5126 => gltf_types.ComponentType.float,
        else => ParseError.InvalidEnum,
    };
}

fn parseAccessorType(type_str: []const u8) !gltf_types.AccessorType {
    if (std.mem.eql(u8, type_str, "SCALAR")) return gltf_types.AccessorType.scalar;
    if (std.mem.eql(u8, type_str, "VEC2")) return gltf_types.AccessorType.vec2;
    if (std.mem.eql(u8, type_str, "VEC3")) return gltf_types.AccessorType.vec3;
    if (std.mem.eql(u8, type_str, "VEC4")) return gltf_types.AccessorType.vec4;
    if (std.mem.eql(u8, type_str, "MAT2")) return gltf_types.AccessorType.mat2;
    if (std.mem.eql(u8, type_str, "MAT3")) return gltf_types.AccessorType.mat3;
    if (std.mem.eql(u8, type_str, "MAT4")) return gltf_types.AccessorType.mat4;
    return ParseError.InvalidEnum;
}

fn parseMode(value: i64) gltf_types.Mode {
    return switch (value) {
        0 => gltf_types.Mode.points,
        1 => gltf_types.Mode.lines,
        2 => gltf_types.Mode.line_loop,
        3 => gltf_types.Mode.line_strip,
        4 => gltf_types.Mode.triangles,
        5 => gltf_types.Mode.triangle_strip,
        6 => gltf_types.Mode.triangle_fan,
        else => gltf_types.Mode.triangles,
    };
}

fn parseTarget(value: i64) !gltf_types.Target {
    return switch (value) {
        34962 => gltf_types.Target.array_buffer,
        34963 => gltf_types.Target.element_array_buffer,
        else => ParseError.InvalidEnum,
    };
}

fn parseAlphaMode(alpha_str: []const u8) gltf_types.AlphaMode {
    if (std.mem.eql(u8, alpha_str, "OPAQUE")) return gltf_types.AlphaMode.opaque_mode;
    if (std.mem.eql(u8, alpha_str, "MASK")) return gltf_types.AlphaMode.mask;
    if (std.mem.eql(u8, alpha_str, "BLEND")) return gltf_types.AlphaMode.blend;
    return gltf_types.AlphaMode.opaque_mode;
}

fn parseMeshes(allocator: Allocator, meshes_json: json.Value) ![]gltf_types.Mesh {
    const meshes = try allocator.alloc(gltf_types.Mesh, meshes_json.array.items.len);

    for (meshes_json.array.items, 0..) |mesh_json, index| {
        meshes[index] = try parseMesh(allocator, mesh_json);
    }

    return meshes;
}

fn parseMesh(allocator: Allocator, mesh_json: json.Value) !gltf_types.Mesh {
    if (mesh_json != .object) {
        return ParseError.InvalidJson;
    }

    const primitives_json = mesh_json.object.get("primitives") orelse return ParseError.InvalidJson;
    if (primitives_json != .array) {
        return ParseError.InvalidJson;
    }

    const primitives = try allocator.alloc(gltf_types.MeshPrimitive, primitives_json.array.items.len);

    for (primitives_json.array.items, 0..) |primitive_json, index| {
        primitives[index] = try parseMeshPrimitive(allocator, primitive_json);
    }

    var weights: ?[]f32 = null;
    if (mesh_json.object.get("weights")) |weights_json| {
        if (weights_json == .array) {
            weights = try allocator.alloc(f32, weights_json.array.items.len);
            for (weights_json.array.items, 0..) |weight_json, index| {
                if (weight_json == .float) {
                    weights.?[index] = @floatCast(weight_json.float);
                } else if (weight_json == .integer) {
                    weights.?[index] = @floatFromInt(weight_json.integer);
                }
            }
        }
    }

    var name_str: ?[]const u8 = null;
    if (mesh_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Mesh{
        .primitives = primitives,
        .weights = weights,
        .name = name_str,
    };
}

fn parseMeshPrimitive(allocator: Allocator, primitive_json: json.Value) !gltf_types.MeshPrimitive {
    if (primitive_json != .object) {
        return ParseError.InvalidJson;
    }

    const attributes_json = primitive_json.object.get("attributes") orelse return ParseError.InvalidJson;
    const attributes = try parseAttributes(attributes_json);

    var indices: ?u32 = null;
    if (primitive_json.object.get("indices")) |indices_json| {
        if (indices_json == .integer) {
            indices = @intCast(indices_json.integer);
        }
    }

    var material_index: ?u32 = null;
    if (primitive_json.object.get("material")) |material_json| {
        if (material_json == .integer) {
            material_index = @intCast(material_json.integer);
        }
    }

    var mode = gltf_types.Mode.triangles;
    if (primitive_json.object.get("mode")) |mode_json| {
        if (mode_json == .integer) {
            mode = parseMode(mode_json.integer);
        }
    }

    var targets: ?[]gltf_types.MorphTarget = null;
    if (primitive_json.object.get("targets")) |targets_json| {
        if (targets_json == .array) {
            targets = try allocator.alloc(gltf_types.MorphTarget, targets_json.array.items.len);
            for (targets_json.array.items, 0..) |target_json, index| {
                targets.?[index] = try parseMorphTarget(target_json);
            }
        }
    }

    return gltf_types.MeshPrimitive{
        .attributes = attributes,
        .indices = indices,
        .material = material_index,
        .mode = mode,
        .targets = targets,
    };
}

fn parseAttributes(attributes_json: json.Value) !gltf_types.Attributes {
    if (attributes_json != .object) {
        return ParseError.InvalidJson;
    }

    var attributes = gltf_types.Attributes{
        .position = null,
        .normal = null,
        .tangent = null,
        .tex_coord_0 = null,
        .tex_coord_1 = null,
        .color_0 = null,
        .joints_0 = null,
        .weights_0 = null,
    };

    if (attributes_json.object.get("POSITION")) |pos_json| {
        if (pos_json == .integer) {
            attributes.position = @intCast(pos_json.integer);
        }
    }

    if (attributes_json.object.get("NORMAL")) |normal_json| {
        if (normal_json == .integer) {
            attributes.normal = @intCast(normal_json.integer);
        }
    }

    if (attributes_json.object.get("TANGENT")) |tangent_json| {
        if (tangent_json == .integer) {
            attributes.tangent = @intCast(tangent_json.integer);
        }
    }

    if (attributes_json.object.get("TEXCOORD_0")) |texcoord_json| {
        if (texcoord_json == .integer) {
            attributes.tex_coord_0 = @intCast(texcoord_json.integer);
        }
    }

    if (attributes_json.object.get("TEXCOORD_1")) |texcoord_json| {
        if (texcoord_json == .integer) {
            attributes.tex_coord_1 = @intCast(texcoord_json.integer);
        }
    }

    if (attributes_json.object.get("COLOR_0")) |color_json| {
        if (color_json == .integer) {
            attributes.color_0 = @intCast(color_json.integer);
        }
    }

    if (attributes_json.object.get("JOINTS_0")) |joints_json| {
        if (joints_json == .integer) {
            attributes.joints_0 = @intCast(joints_json.integer);
        }
    }

    if (attributes_json.object.get("WEIGHTS_0")) |weights_json| {
        if (weights_json == .integer) {
            attributes.weights_0 = @intCast(weights_json.integer);
        }
    }

    return attributes;
}

fn parseMorphTarget(target_json: json.Value) !gltf_types.MorphTarget {
    if (target_json != .object) {
        return ParseError.InvalidJson;
    }

    var target = gltf_types.MorphTarget{
        .position = null,
        .normal = null,
        .tangent = null,
    };

    if (target_json.object.get("POSITION")) |pos_json| {
        if (pos_json == .integer) {
            target.position = @intCast(pos_json.integer);
        }
    }

    if (target_json.object.get("NORMAL")) |normal_json| {
        if (normal_json == .integer) {
            target.normal = @intCast(normal_json.integer);
        }
    }

    if (target_json.object.get("TANGENT")) |tangent_json| {
        if (tangent_json == .integer) {
            target.tangent = @intCast(tangent_json.integer);
        }
    }

    return target;
}

fn parseAccessors(allocator: Allocator, accessors_json: json.Value) ![]gltf_types.Accessor {
    const accessors = try allocator.alloc(gltf_types.Accessor, accessors_json.array.items.len);

    for (accessors_json.array.items, 0..) |accessor_json, index| {
        accessors[index] = try parseAccessor(allocator, accessor_json);
    }

    return accessors;
}

fn parseAccessor(allocator: Allocator, accessor_json: json.Value) !gltf_types.Accessor {
    if (accessor_json != .object) {
        return ParseError.InvalidJson;
    }

    var buffer_view: ?u32 = null;
    if (accessor_json.object.get("bufferView")) |buffer_view_json| {
        if (buffer_view_json == .integer) {
            buffer_view = @intCast(buffer_view_json.integer);
        }
    }

    var byte_offset: u32 = 0;
    if (accessor_json.object.get("byteOffset")) |byte_offset_json| {
        if (byte_offset_json == .integer) {
            byte_offset = @intCast(byte_offset_json.integer);
        }
    }

    const component_type_json = accessor_json.object.get("componentType") orelse return ParseError.InvalidJson;
    if (component_type_json != .integer) {
        return ParseError.InvalidJson;
    }
    const component_type = try parseComponentType(component_type_json.integer);

    var normalized = false;
    if (accessor_json.object.get("normalized")) |normalized_json| {
        if (normalized_json == .bool) {
            normalized = normalized_json.bool;
        }
    }

    const count_json = accessor_json.object.get("count") orelse return ParseError.InvalidJson;
    if (count_json != .integer) {
        return ParseError.InvalidJson;
    }
    const count: u32 = @intCast(count_json.integer);

    const type_json = accessor_json.object.get("type") orelse return ParseError.InvalidJson;
    if (type_json != .string) {
        return ParseError.InvalidJson;
    }
    const accessor_type = try parseAccessorType(type_json.string);

    var max: ?[]f32 = null;
    if (accessor_json.object.get("max")) |max_json| {
        if (max_json == .array) {
            max = try allocator.alloc(f32, max_json.array.items.len);
            for (max_json.array.items, 0..) |value_json, index| {
                if (value_json == .float) {
                    max.?[index] = @floatCast(value_json.float);
                } else if (value_json == .integer) {
                    max.?[index] = @floatFromInt(value_json.integer);
                }
            }
        }
    }

    var min: ?[]f32 = null;
    if (accessor_json.object.get("min")) |min_json| {
        if (min_json == .array) {
            min = try allocator.alloc(f32, min_json.array.items.len);
            for (min_json.array.items, 0..) |value_json, index| {
                if (value_json == .float) {
                    min.?[index] = @floatCast(value_json.float);
                } else if (value_json == .integer) {
                    min.?[index] = @floatFromInt(value_json.integer);
                }
            }
        }
    }

    var name_str: ?[]const u8 = null;
    if (accessor_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Accessor{
        .buffer_view = buffer_view,
        .byte_offset = byte_offset,
        .component_type = component_type,
        .normalized = normalized,
        .count = count,
        .accessor_type = accessor_type,
        .max = max,
        .min = min,
        .sparse = null,
        .name = name_str,
    };
}

fn parseBufferViews(allocator: Allocator, buffer_views_json: json.Value) ![]gltf_types.BufferView {
    const buffer_views = try allocator.alloc(gltf_types.BufferView, buffer_views_json.array.items.len);

    for (buffer_views_json.array.items, 0..) |buffer_view_json, index| {
        buffer_views[index] = try parseBufferView(allocator, buffer_view_json);
    }

    return buffer_views;
}

fn parseBufferView(allocator: Allocator, buffer_view_json: json.Value) !gltf_types.BufferView {
    if (buffer_view_json != .object) {
        return ParseError.InvalidJson;
    }

    const buffer_json = buffer_view_json.object.get("buffer") orelse return ParseError.InvalidJson;
    if (buffer_json != .integer) {
        return ParseError.InvalidJson;
    }
    const buffer_index: u32 = @intCast(buffer_json.integer);

    var byte_offset: u32 = 0;
    if (buffer_view_json.object.get("byteOffset")) |byte_offset_json| {
        if (byte_offset_json == .integer) {
            byte_offset = @intCast(byte_offset_json.integer);
        }
    }

    const byte_length_json = buffer_view_json.object.get("byteLength") orelse return ParseError.InvalidJson;
    if (byte_length_json != .integer) {
        return ParseError.InvalidJson;
    }
    const byte_length: u32 = @intCast(byte_length_json.integer);

    var byte_stride: ?u32 = null;
    if (buffer_view_json.object.get("byteStride")) |byte_stride_json| {
        if (byte_stride_json == .integer) {
            byte_stride = @intCast(byte_stride_json.integer);
        }
    }

    var target: ?gltf_types.Target = null;
    if (buffer_view_json.object.get("target")) |target_json| {
        if (target_json == .integer) {
            target = try parseTarget(target_json.integer);
        }
    }

    var name_str: ?[]const u8 = null;
    if (buffer_view_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.BufferView{
        .buffer = buffer_index,
        .byte_offset = byte_offset,
        .byte_length = byte_length,
        .byte_stride = byte_stride,
        .target = target,
        .name = name_str,
    };
}

fn parseBuffers(allocator: Allocator, buffers_json: json.Value) ![]gltf_types.Buffer {
    const buffers = try allocator.alloc(gltf_types.Buffer, buffers_json.array.items.len);

    for (buffers_json.array.items, 0..) |buffer_json, index| {
        buffers[index] = try parseBuffer(allocator, buffer_json);
    }

    return buffers;
}

fn parseBuffer(allocator: Allocator, buffer_json: json.Value) !gltf_types.Buffer {
    if (buffer_json != .object) {
        return ParseError.InvalidJson;
    }

    var uri_str: ?[]const u8 = null;
    if (buffer_json.object.get("uri")) |uri_json| {
        if (uri_json == .string) {
            uri_str = try allocator.dupe(u8, uri_json.string);
        }
    }

    const byte_length_json = buffer_json.object.get("byteLength") orelse return ParseError.InvalidJson;
    if (byte_length_json != .integer) {
        return ParseError.InvalidJson;
    }
    const byte_length: u32 = @intCast(byte_length_json.integer);

    var name_str: ?[]const u8 = null;
    if (buffer_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Buffer{
        .uri = uri_str,
        .byte_length = byte_length,
        .name = name_str,
        .data = null,
    };
}

fn parseMaterials(allocator: Allocator, materials_json: json.Value) ![]gltf_types.Material {
    const materials = try allocator.alloc(gltf_types.Material, materials_json.array.items.len);

    for (materials_json.array.items, 0..) |material_json, index| {
        materials[index] = try parseMaterial(allocator, material_json);
    }

    return materials;
}

fn parseMaterial(allocator: Allocator, material_json: json.Value) !gltf_types.Material {
    if (material_json != .object) {
        return ParseError.InvalidJson;
    }

    var pbr: ?gltf_types.PBRMetallicRoughness = null;
    if (material_json.object.get("pbrMetallicRoughness")) |pbr_json| {
        pbr = try parsePBRMetallicRoughness(allocator, pbr_json);
    }

    var normal_texture: ?gltf_types.TextureInfo = null;
    if (material_json.object.get("normalTexture")) |normal_json| {
        normal_texture = try parseTextureInfo(normal_json);
    }

    var occlusion_texture: ?gltf_types.TextureInfo = null;
    if (material_json.object.get("occlusionTexture")) |occlusion_json| {
        occlusion_texture = try parseTextureInfo(occlusion_json);
    }

    var emissive_texture: ?gltf_types.TextureInfo = null;
    if (material_json.object.get("emissiveTexture")) |emissive_json| {
        emissive_texture = try parseTextureInfo(emissive_json);
    }

    var emissive_factor = math.vec3(0.0, 0.0, 0.0);
    if (material_json.object.get("emissiveFactor")) |emissive_json| {
        if (emissive_json == .array and emissive_json.array.items.len == 3) {
            var vec_data = [_]f32{0.0} ** 3;
            for (emissive_json.array.items, 0..) |value_json, index| {
                if (value_json == .float) {
                    vec_data[index] = @floatCast(value_json.float);
                } else if (value_json == .integer) {
                    vec_data[index] = @floatFromInt(value_json.integer);
                }
            }
            emissive_factor = math.Vec3{ .x = vec_data[0], .y = vec_data[1], .z = vec_data[2] };
        }
    }

    var alpha_mode = gltf_types.AlphaMode.opaque_mode;
    if (material_json.object.get("alphaMode")) |alpha_json| {
        if (alpha_json == .string) {
            alpha_mode = parseAlphaMode(alpha_json.string);
        }
    }

    var alpha_cutoff: f32 = 0.5;
    if (material_json.object.get("alphaCutoff")) |cutoff_json| {
        if (cutoff_json == .float) {
            alpha_cutoff = @floatCast(cutoff_json.float);
        } else if (cutoff_json == .integer) {
            alpha_cutoff = @floatFromInt(cutoff_json.integer);
        }
    }

    var double_sided = false;
    if (material_json.object.get("doubleSided")) |double_json| {
        if (double_json == .bool) {
            double_sided = double_json.bool;
        }
    }

    var name_str: ?[]const u8 = null;
    if (material_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Material{
        .pbr_metallic_roughness = pbr,
        .normal_texture = normal_texture,
        .occlusion_texture = occlusion_texture,
        .emissive_texture = emissive_texture,
        .emissive_factor = emissive_factor,
        .alpha_mode = alpha_mode,
        .alpha_cutoff = alpha_cutoff,
        .double_sided = double_sided,
        .name = name_str,
    };
}

fn parsePBRMetallicRoughness(_: Allocator, pbr_json: json.Value) !gltf_types.PBRMetallicRoughness {
    if (pbr_json != .object) {
        return ParseError.InvalidJson;
    }

    var base_color_factor = math.vec4(1.0, 1.0, 1.0, 1.0);
    if (pbr_json.object.get("baseColorFactor")) |color_json| {
        if (color_json == .array and color_json.array.items.len == 4) {
            var vec_data = [_]f32{1.0} ** 4;
            for (color_json.array.items, 0..) |value_json, index| {
                if (value_json == .float) {
                    vec_data[index] = @floatCast(value_json.float);
                } else if (value_json == .integer) {
                    vec_data[index] = @floatFromInt(value_json.integer);
                }
            }
            base_color_factor = math.Vec4{ .x = vec_data[0], .y = vec_data[1], .z = vec_data[2], .w = vec_data[3] };
        }
    }

    var base_color_texture: ?gltf_types.TextureInfo = null;
    if (pbr_json.object.get("baseColorTexture")) |texture_json| {
        base_color_texture = try parseTextureInfo(texture_json);
    }

    var metallic_factor: f32 = 1.0;
    if (pbr_json.object.get("metallicFactor")) |metallic_json| {
        if (metallic_json == .float) {
            metallic_factor = @floatCast(metallic_json.float);
        } else if (metallic_json == .integer) {
            metallic_factor = @floatFromInt(metallic_json.integer);
        }
    }

    var roughness_factor: f32 = 1.0;
    if (pbr_json.object.get("roughnessFactor")) |roughness_json| {
        if (roughness_json == .float) {
            roughness_factor = @floatCast(roughness_json.float);
        } else if (roughness_json == .integer) {
            roughness_factor = @floatFromInt(roughness_json.integer);
        }
    }

    var metallic_roughness_texture: ?gltf_types.TextureInfo = null;
    if (pbr_json.object.get("metallicRoughnessTexture")) |texture_json| {
        metallic_roughness_texture = try parseTextureInfo(texture_json);
    }

    return gltf_types.PBRMetallicRoughness{
        .base_color_factor = base_color_factor,
        .base_color_texture = base_color_texture,
        .metallic_factor = metallic_factor,
        .roughness_factor = roughness_factor,
        .metallic_roughness_texture = metallic_roughness_texture,
    };
}

fn parseTextureInfo(texture_json: json.Value) !gltf_types.TextureInfo {
    if (texture_json != .object) {
        return ParseError.InvalidJson;
    }

    const index_json = texture_json.object.get("index") orelse return ParseError.InvalidJson;
    if (index_json != .integer) {
        return ParseError.InvalidJson;
    }
    const index: u32 = @intCast(index_json.integer);

    var tex_coord: u32 = 0;
    if (texture_json.object.get("texCoord")) |tex_coord_json| {
        if (tex_coord_json == .integer) {
            tex_coord = @intCast(tex_coord_json.integer);
        }
    }

    return gltf_types.TextureInfo{
        .index = index,
        .tex_coord = tex_coord,
    };
}

fn parseSamplers(allocator: Allocator, samplers_json: json.Value) ![]gltf_types.Sampler {
    const samplers = try allocator.alloc(gltf_types.Sampler, samplers_json.array.items.len);

    for (samplers_json.array.items, 0..) |sampler_json, index| {
        samplers[index] = try parseSampler(allocator, sampler_json);
    }

    return samplers;
}

fn parseSampler(allocator: Allocator, sampler_json: json.Value) !gltf_types.Sampler {
    if (sampler_json != .object) {
        return ParseError.InvalidJson;
    }

    var mag_filter: ?gltf_types.MagFilter = null;
    if (sampler_json.object.get("magFilter")) |mag_json| {
        if (mag_json == .integer) {
            mag_filter = switch (mag_json.integer) {
                9728 => gltf_types.MagFilter.nearest,
                9729 => gltf_types.MagFilter.linear,
                else => null,
            };
        }
    }

    var min_filter: ?gltf_types.MinFilter = null;
    if (sampler_json.object.get("minFilter")) |min_json| {
        if (min_json == .integer) {
            min_filter = switch (min_json.integer) {
                9728 => gltf_types.MinFilter.nearest,
                9729 => gltf_types.MinFilter.linear,
                9984 => gltf_types.MinFilter.nearest_mipmap_nearest,
                9985 => gltf_types.MinFilter.linear_mipmap_nearest,
                9986 => gltf_types.MinFilter.nearest_mipmap_linear,
                9987 => gltf_types.MinFilter.linear_mipmap_linear,
                else => null,
            };
        }
    }

    var wrap_s = gltf_types.WrapMode.repeat;
    if (sampler_json.object.get("wrapS")) |wrap_json| {
        if (wrap_json == .integer) {
            wrap_s = switch (wrap_json.integer) {
                10497 => gltf_types.WrapMode.repeat,
                33071 => gltf_types.WrapMode.clamp_to_edge,
                33648 => gltf_types.WrapMode.mirrored_repeat,
                else => gltf_types.WrapMode.repeat,
            };
        }
    }

    var wrap_t = gltf_types.WrapMode.repeat;
    if (sampler_json.object.get("wrapT")) |wrap_json| {
        if (wrap_json == .integer) {
            wrap_t = switch (wrap_json.integer) {
                10497 => gltf_types.WrapMode.repeat,
                33071 => gltf_types.WrapMode.clamp_to_edge,
                33648 => gltf_types.WrapMode.mirrored_repeat,
                else => gltf_types.WrapMode.repeat,
            };
        }
    }

    var name_str: ?[]const u8 = null;
    if (sampler_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Sampler{
        .mag_filter = mag_filter,
        .min_filter = min_filter,
        .wrap_s = wrap_s,
        .wrap_t = wrap_t,
        .name = name_str,
    };
}

fn parseTextures(allocator: Allocator, textures_json: json.Value) ![]gltf_types.Texture {
    const textures = try allocator.alloc(gltf_types.Texture, textures_json.array.items.len);

    for (textures_json.array.items, 0..) |texture_json, index| {
        textures[index] = try parseTexture(allocator, texture_json);
    }

    return textures;
}

fn parseTexture(allocator: Allocator, texture_json: json.Value) !gltf_types.Texture {
    if (texture_json != .object) {
        return ParseError.InvalidJson;
    }

    var sampler_index: ?u32 = null;
    if (texture_json.object.get("sampler")) |sampler_json| {
        if (sampler_json == .integer) {
            sampler_index = @intCast(sampler_json.integer);
        }
    }

    var source_index: ?u32 = null;
    if (texture_json.object.get("source")) |source_json| {
        if (source_json == .integer) {
            source_index = @intCast(source_json.integer);
        }
    }

    var name_str: ?[]const u8 = null;
    if (texture_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Texture{
        .sampler = sampler_index,
        .source = source_index,
        .name = name_str,
    };
}

fn parseImages(allocator: Allocator, images_json: json.Value) ![]gltf_types.Image {
    const images = try allocator.alloc(gltf_types.Image, images_json.array.items.len);

    for (images_json.array.items, 0..) |image_json, index| {
        images[index] = try parseImage(allocator, image_json);
    }

    return images;
}

fn parseImage(allocator: Allocator, image_json: json.Value) !gltf_types.Image {
    if (image_json != .object) {
        return ParseError.InvalidJson;
    }

    var uri_str: ?[]const u8 = null;
    if (image_json.object.get("uri")) |uri_json| {
        if (uri_json == .string) {
            uri_str = try allocator.dupe(u8, uri_json.string);
        }
    }

    var mime_type_str: ?[]const u8 = null;
    if (image_json.object.get("mimeType")) |mime_json| {
        if (mime_json == .string) {
            mime_type_str = try allocator.dupe(u8, mime_json.string);
        }
    }

    var buffer_view_index: ?u32 = null;
    if (image_json.object.get("bufferView")) |buffer_view_json| {
        if (buffer_view_json == .integer) {
            buffer_view_index = @intCast(buffer_view_json.integer);
        }
    }

    var name_str: ?[]const u8 = null;
    if (image_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Image{
        .uri = uri_str,
        .mime_type = mime_type_str,
        .buffer_view = buffer_view_index,
        .name = name_str,
    };
}

fn parseAnimations(allocator: Allocator, animations_json: json.Value) ![]gltf_types.Animation {
    const animations = try allocator.alloc(gltf_types.Animation, animations_json.array.items.len);

    for (animations_json.array.items, 0..) |animation_json, index| {
        animations[index] = try parseAnimation(allocator, animation_json);
    }

    return animations;
}

fn parseAnimation(allocator: Allocator, animation_json: json.Value) !gltf_types.Animation {
    if (animation_json != .object) {
        return ParseError.InvalidJson;
    }

    const channels_json = animation_json.object.get("channels") orelse return ParseError.InvalidJson;
    if (channels_json != .array) {
        return ParseError.InvalidJson;
    }

    const channels = try allocator.alloc(gltf_types.AnimationChannel, channels_json.array.items.len);

    for (channels_json.array.items, 0..) |channel_json, index| {
        channels[index] = try parseAnimationChannel(channel_json);
    }

    const samplers_json = animation_json.object.get("samplers") orelse return ParseError.InvalidJson;
    if (samplers_json != .array) {
        return ParseError.InvalidJson;
    }

    const samplers = try allocator.alloc(gltf_types.AnimationSampler, samplers_json.array.items.len);

    for (samplers_json.array.items, 0..) |sampler_json, index| {
        samplers[index] = try parseAnimationSampler(sampler_json);
    }

    var name_str: ?[]const u8 = null;
    if (animation_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Animation{
        .channels = channels,
        .samplers = samplers,
        .name = name_str,
    };
}

fn parseAnimationChannel(channel_json: json.Value) !gltf_types.AnimationChannel {
    if (channel_json != .object) {
        return ParseError.InvalidJson;
    }

    const sampler_json = channel_json.object.get("sampler") orelse return ParseError.InvalidJson;
    if (sampler_json != .integer) {
        return ParseError.InvalidJson;
    }
    const sampler_index: u32 = @intCast(sampler_json.integer);

    const target_json = channel_json.object.get("target") orelse return ParseError.InvalidJson;
    const target = try parseAnimationChannelTarget(target_json);

    return gltf_types.AnimationChannel{
        .sampler = sampler_index,
        .target = target,
    };
}

fn parseAnimationChannelTarget(target_json: json.Value) !gltf_types.AnimationChannelTarget {
    if (target_json != .object) {
        return ParseError.InvalidJson;
    }

    var node_index: ?u32 = null;
    if (target_json.object.get("node")) |node_json| {
        if (node_json == .integer) {
            node_index = @intCast(node_json.integer);
        }
    }

    const path_json = target_json.object.get("path") orelse return ParseError.InvalidJson;
    if (path_json != .string) {
        return ParseError.InvalidJson;
    }

    const path = parseTargetProperty(path_json.string);

    return gltf_types.AnimationChannelTarget{
        .node = node_index,
        .path = path,
    };
}

fn parseTargetProperty(path_str: []const u8) gltf_types.TargetProperty {
    if (std.mem.eql(u8, path_str, "translation")) return gltf_types.TargetProperty.translation;
    if (std.mem.eql(u8, path_str, "rotation")) return gltf_types.TargetProperty.rotation;
    if (std.mem.eql(u8, path_str, "scale")) return gltf_types.TargetProperty.scale;
    if (std.mem.eql(u8, path_str, "weights")) return gltf_types.TargetProperty.weights;
    return gltf_types.TargetProperty.translation;
}

fn parseAnimationSampler(sampler_json: json.Value) !gltf_types.AnimationSampler {
    if (sampler_json != .object) {
        return ParseError.InvalidJson;
    }

    const input_json = sampler_json.object.get("input") orelse return ParseError.InvalidJson;
    if (input_json != .integer) {
        return ParseError.InvalidJson;
    }
    const input: u32 = @intCast(input_json.integer);

    const output_json = sampler_json.object.get("output") orelse return ParseError.InvalidJson;
    if (output_json != .integer) {
        return ParseError.InvalidJson;
    }
    const output: u32 = @intCast(output_json.integer);

    var interpolation = gltf_types.Interpolation.linear;
    if (sampler_json.object.get("interpolation")) |interp_json| {
        if (interp_json == .string) {
            interpolation = parseInterpolation(interp_json.string);
        }
    }

    return gltf_types.AnimationSampler{
        .input = input,
        .output = output,
        .interpolation = interpolation,
    };
}

fn parseInterpolation(interp_str: []const u8) gltf_types.Interpolation {
    if (std.mem.eql(u8, interp_str, "LINEAR")) return gltf_types.Interpolation.linear;
    if (std.mem.eql(u8, interp_str, "STEP")) return gltf_types.Interpolation.step;
    if (std.mem.eql(u8, interp_str, "CUBICSPLINE")) return gltf_types.Interpolation.cubic_spline;
    return gltf_types.Interpolation.linear;
}

fn parseSkins(allocator: Allocator, skins_json: json.Value) ![]gltf_types.Skin {
    const skins = try allocator.alloc(gltf_types.Skin, skins_json.array.items.len);

    for (skins_json.array.items, 0..) |skin_json, index| {
        skins[index] = try parseSkin(allocator, skin_json);
    }

    return skins;
}

fn parseSkin(allocator: Allocator, skin_json: json.Value) !gltf_types.Skin {
    if (skin_json != .object) {
        return ParseError.InvalidJson;
    }

    var inverse_bind_matrices: ?u32 = null;
    if (skin_json.object.get("inverseBindMatrices")) |matrices_json| {
        if (matrices_json == .integer) {
            inverse_bind_matrices = @intCast(matrices_json.integer);
        }
    }

    var skeleton: ?u32 = null;
    if (skin_json.object.get("skeleton")) |skeleton_json| {
        if (skeleton_json == .integer) {
            skeleton = @intCast(skeleton_json.integer);
        }
    }

    const joints_json = skin_json.object.get("joints") orelse return ParseError.InvalidJson;
    if (joints_json != .array) {
        return ParseError.InvalidJson;
    }

    const joints = try allocator.alloc(u32, joints_json.array.items.len);

    for (joints_json.array.items, 0..) |joint_json, index| {
        if (joint_json == .integer) {
            joints[index] = @intCast(joint_json.integer);
        }
    }

    var name_str: ?[]const u8 = null;
    if (skin_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Skin{
        .inverse_bind_matrices = inverse_bind_matrices,
        .skeleton = skeleton,
        .joints = joints,
        .name = name_str,
    };
}

fn parseCameras(allocator: Allocator, cameras_json: json.Value) ![]gltf_types.Camera {
    const cameras = try allocator.alloc(gltf_types.Camera, cameras_json.array.items.len);

    for (cameras_json.array.items, 0..) |camera_json, index| {
        cameras[index] = try parseCamera(allocator, camera_json);
    }

    return cameras;
}

fn parseCamera(allocator: Allocator, camera_json: json.Value) !gltf_types.Camera {
    if (camera_json != .object) {
        return ParseError.InvalidJson;
    }

    var orthographic: ?gltf_types.CameraOrthographic = null;
    if (camera_json.object.get("orthographic")) |ortho_json| {
        orthographic = try parseCameraOrthographic(ortho_json);
    }

    var perspective: ?gltf_types.CameraPerspective = null;
    if (camera_json.object.get("perspective")) |persp_json| {
        perspective = try parseCameraPerspective(persp_json);
    }

    var name_str: ?[]const u8 = null;
    if (camera_json.object.get("name")) |name_json| {
        if (name_json == .string) {
            name_str = try allocator.dupe(u8, name_json.string);
        }
    }

    return gltf_types.Camera{
        .orthographic = orthographic,
        .perspective = perspective,
        .name = name_str,
    };
}

fn parseCameraOrthographic(ortho_json: json.Value) !gltf_types.CameraOrthographic {
    if (ortho_json != .object) {
        return ParseError.InvalidJson;
    }

    const xmag_json = ortho_json.object.get("xmag") orelse return ParseError.InvalidJson;
    const xmag = if (xmag_json == .float) @as(f32, @floatCast(xmag_json.float)) else if (xmag_json == .integer) @as(f32, @floatFromInt(xmag_json.integer)) else return ParseError.InvalidJson;

    const ymag_json = ortho_json.object.get("ymag") orelse return ParseError.InvalidJson;
    const ymag = if (ymag_json == .float) @as(f32, @floatCast(ymag_json.float)) else if (ymag_json == .integer) @as(f32, @floatFromInt(ymag_json.integer)) else return ParseError.InvalidJson;

    const zfar_json = ortho_json.object.get("zfar") orelse return ParseError.InvalidJson;
    const zfar = if (zfar_json == .float) @as(f32, @floatCast(zfar_json.float)) else if (zfar_json == .integer) @as(f32, @floatFromInt(zfar_json.integer)) else return ParseError.InvalidJson;

    const znear_json = ortho_json.object.get("znear") orelse return ParseError.InvalidJson;
    const znear = if (znear_json == .float) @as(f32, @floatCast(znear_json.float)) else if (znear_json == .integer) @as(f32, @floatFromInt(znear_json.integer)) else return ParseError.InvalidJson;

    return gltf_types.CameraOrthographic{
        .xmag = xmag,
        .ymag = ymag,
        .zfar = zfar,
        .znear = znear,
    };
}

fn parseCameraPerspective(persp_json: json.Value) !gltf_types.CameraPerspective {
    if (persp_json != .object) {
        return ParseError.InvalidJson;
    }

    const yfov_json = persp_json.object.get("yfov") orelse return ParseError.InvalidJson;
    const yfov = if (yfov_json == .float) @as(f32, @floatCast(yfov_json.float)) else if (yfov_json == .integer) @as(f32, @floatFromInt(yfov_json.integer)) else return ParseError.InvalidJson;

    var zfar: ?f32 = null;
    if (persp_json.object.get("zfar")) |zfar_json| {
        zfar = if (zfar_json == .float) @as(f32, @floatCast(zfar_json.float)) else if (zfar_json == .integer) @as(f32, @floatFromInt(zfar_json.integer)) else null;
    }

    const znear_json = persp_json.object.get("znear") orelse return ParseError.InvalidJson;
    const znear = if (znear_json == .float) @as(f32, @floatCast(znear_json.float)) else if (znear_json == .integer) @as(f32, @floatFromInt(znear_json.integer)) else return ParseError.InvalidJson;

    var aspect_ratio: ?f32 = null;
    if (persp_json.object.get("aspectRatio")) |aspect_json| {
        aspect_ratio = if (aspect_json == .float) @as(f32, @floatCast(aspect_json.float)) else if (aspect_json == .integer) @as(f32, @floatFromInt(aspect_json.integer)) else null;
    }

    return gltf_types.CameraPerspective{
        .yfov = yfov,
        .zfar = zfar,
        .znear = znear,
        .aspect_ratio = aspect_ratio,
    };
}
