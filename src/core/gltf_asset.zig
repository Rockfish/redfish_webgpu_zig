const std = @import("std");
const math = @import("math");
const containers = @import("containers");
const gltf_types = @import("gltf/gltf.zig");
const parser = @import("gltf/parser.zig");
const texture = @import("texture.zig");
const utils = @import("utils/root.zig");
const Model = @import("model.zig").Model;
const Mesh = @import("mesh.zig").Mesh;
const Animator = @import("animator.zig").Animator;
const Context = @import("context.zig").Context;
const GpuContext = @import("gpu_context.zig").GpuContext;
const TextureSlot = @import("material.zig").TextureSlot;
const AABB = @import("aabb.zig").AABB;
const Transform = @import("transform.zig").Transform;

const log = std.log.scoped(.asset_loader);

const Vec3 = math.Vec3;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Mat4 = math.Mat4;

// Normal generation options for asset loading
pub const NormalGenerationMode = enum {
    skip, // Don't generate normals, use shader fallback
    simple, // Generate simple upward-facing normals
    accurate, // Calculate normals from triangle geometry
};

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ManagedArrayList = containers.ManagedArrayList;
const Path = std.fs.path;

const GLTF = gltf_types.GLTF;

/// A texture file assigned to a material slot of the meshes with a given name, for
/// models whose materials don't reference their textures.
const CustomTexture = struct {
    mesh_name: []const u8,
    slot: TextureSlot,
    texture_path: []const u8,
    config: texture.TextureConfig,
    texture: ?*texture.Texture = null, // Loaded in `load`
};

/// redfish bound custom textures by GL uniform name; these are the names apps pass,
/// mapped to the material slot a shader reads them from.
fn slotForUniformName(uniform_name: []const u8) ?TextureSlot {
    const names = [_]struct { []const u8, TextureSlot }{
        .{ "texture_diffuse", .base_color },
        .{ "texture_specular", .metallic_roughness },
        .{ "texture_normal", .normal },
        .{ "texture_normals", .normal },
        .{ "texture_emissive", .emissive },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, entry[0], uniform_name)) {
            return entry[1];
        }
    }
    return null;
}

// GLB Format Constants
const GLB_MAGIC: u32 = 0x46546C67; // "glTF" in little-endian
const GLB_VERSION: u32 = 2;
const GLB_JSON_CHUNK_TYPE: u32 = 0x4E4F534A; // "JSON"
const GLB_BIN_CHUNK_TYPE: u32 = 0x004E4942; // "BIN\0"

// GLB Structures
const GlbHeader = struct {
    magic: u32,
    version: u32,
    length: u32,
};

const GlbChunkHeader = struct {
    length: u32,
    chunk_type: u32,
};

// GLB Errors
const GlbError = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidChunkType,
    TruncatedFile,
    MissingJsonChunk,
};

const GltAssetError = error{
    TextureNotLoaded,
};

pub const GltfAsset = struct {
    context: Context,
    gpu: *GpuContext,

    // Pure GLTF specification data
    gltf: GLTF,

    // Runtime support data
    meshes: []*Mesh,
    buffer_data: ManagedArrayList([]align(4) const u8),
    loaded_textures: std.AutoHashMap(u32, *texture.Texture),
    generated_normals: std.AutoHashMap(u64, []Vec3), // Key: mesh_index << 32 | primitive_index
    custom_textures: ManagedArrayList(CustomTexture), // Manual texture assignments
    directory: []const u8,
    name: []const u8,
    filepath: [:0]const u8,
    is_loaded: bool = false,

    // Configuration
    load_textures: bool,
    /// Base color and emissive maps as sRGB (decoded to linear when sampled). False for
    /// apps that light in gamma space, as redfish's GL did (angrybot).
    srgb_color_textures: bool = true,
    normal_generation_mode: NormalGenerationMode,

    const Self = @This();

    /// GPU objects (textures, mesh buffers) are created in `load`, so the device must exist.
    pub fn init(context: Context, gpu: *GpuContext, name: []const u8, path: []const u8) !*Self {
        const asset: *GltfAsset = try context.alloc.create(Self);
        asset.* = GltfAsset{
            .context = context,
            .gpu = gpu,
            .name = try context.alloc.dupe(u8, name),
            .gltf = undefined,
            .meshes = &[_]*Mesh{},
            .buffer_data = ManagedArrayList([]align(4) const u8).init(context.alloc),
            .loaded_textures = std.AutoHashMap(u32, *texture.Texture).init(context.alloc),
            .generated_normals = std.AutoHashMap(u64, []Vec3).init(context.alloc),
            .custom_textures = ManagedArrayList(CustomTexture).init(context.alloc),
            .directory = try context.alloc.dupe(u8, Path.dirname(path) orelse ""),
            .filepath = try context.alloc.dupeZ(u8, path),
            .load_textures = true,
            .normal_generation_mode = .skip, // Default to skip generation
        };

        return asset;
    }

    /// Releases mesh buffers, materials, and textures. Before the owning arena resets.
    pub fn cleanUp(self: *Self) void {
        for (self.meshes) |mesh| {
            mesh.cleanUp();
        }

        var texture_iterator = self.loaded_textures.valueIterator();
        while (texture_iterator.next()) |tex| {
            tex.*.releaseGpuObjects();
        }

        for (self.custom_textures.list.items) |custom_tex| {
            if (custom_tex.texture) |tex| {
                tex.releaseGpuObjects();
            }
        }
    }

    pub fn skipModelTextures(self: *Self) void {
        self.load_textures = false;
    }

    /// Load color maps unconverted, for shading in gamma space (see `srgb_color_textures`).
    /// Before `load`.
    pub fn useGammaSpaceTextures(self: *Self) void {
        self.srgb_color_textures = false;
    }

    /// Assign a texture file (relative to the asset's directory) to the meshes named
    /// `mesh_name`, in the material slot `uniform_name` maps to (see `slotForUniformName`).
    /// Overrides the glTF material's texture in that slot. Before `load`.
    pub fn addCustomTexture(self: *Self, mesh_name: []const u8, uniform_name: []const u8, texture_path: []const u8, config: texture.TextureConfig) !void {
        if (self.is_loaded) {
            log.err("Cannot add texture to already loaded asset", .{});
        }

        const slot = slotForUniformName(uniform_name) orelse {
            log.err("addCustomTexture: no material slot for '{s}'", .{uniform_name});
            return error.UnknownCustomTextureSlot;
        };

        const allocator = self.context.alloc;
        try self.custom_textures.append(.{
            .mesh_name = try allocator.dupe(u8, mesh_name),
            .slot = slot,
            .texture_path = try allocator.dupe(u8, texture_path),
            .config = config,
        });
    }

    /// The custom texture for a mesh and slot, if one was added.
    pub fn getCustomTexture(self: *const Self, mesh_name: []const u8, slot: TextureSlot) ?*texture.Texture {
        for (self.custom_textures.list.items) |custom_tex| {
            if (custom_tex.slot == slot and std.mem.eql(u8, custom_tex.mesh_name, mesh_name)) {
                return custom_tex.texture;
            }
        }
        return null;
    }

    pub fn setNormalGenerationMode(self: *Self, mode: NormalGenerationMode) void {
        self.normal_generation_mode = mode;
    }

    pub fn calculateBoundingBox(self: *Self, scene_id: u32) AABB {
        var bbox = AABB.init();

        // Get the scene nodes and calculate bounds
        const scene = self.gltf.scenes.?[@intCast(scene_id)];
        if (scene.nodes) |nodes| {
            for (nodes) |node_index| {
                const node = self.gltf.nodes.?[node_index];
                self.calculateNodeBounds(&bbox, node, Mat4.Identity);
            }
        }

        return bbox;
    }

    fn calculateNodeBounds(self: *Self, bbox: *AABB, node: gltf_types.Node, parent_transform: Mat4) void {
        // A node has either `matrix` or TRS (as Animator.preprocessNodes reads them).
        // Ignoring `matrix` made models like Duck (0.01 scale) normalize 100x too small.
        const local_matrix = node.matrix orelse (Transform{
            .translation = node.translation orelse vec3(0.0, 0.0, 0.0),
            .rotation = node.rotation orelse math.quat(0.0, 0.0, 0.0, 1.0),
            .scale = node.scale orelse vec3(1.0, 1.0, 1.0),
        }).toMatrix();
        const global_matrix = parent_transform.mulMat4(&local_matrix);

        // If this node has a mesh, calculate its bounds
        if (node.mesh) |mesh_index| {
            if (self.gltf.meshes) |meshes| {
                const mesh = meshes[mesh_index];
                self.calculateMeshBounds(bbox, mesh, global_matrix);
            }
        }

        // Process child nodes
        if (node.children) |children| {
            for (children) |child_index| {
                const child_node = self.gltf.nodes.?[child_index];
                self.calculateNodeBounds(bbox, child_node, global_matrix);
            }
        }
    }

    fn calculateMeshBounds(self: *Self, bbox: *AABB, mesh: gltf_types.Mesh, transform: Mat4) void {
        for (mesh.primitives) |primitive| {
            if (primitive.attributes.position) |position_accessor_index| {
                const accessor = self.gltf.accessors.?[position_accessor_index];

                // Use accessor min/max if available (optimized path)
                if (accessor.min != null and accessor.max != null) {
                    const min_pos = vec3(accessor.min.?[0], accessor.min.?[1], accessor.min.?[2]);
                    const max_pos = vec3(accessor.max.?[0], accessor.max.?[1], accessor.max.?[2]);

                    // Transform the min/max corners and expand bounding box
                    const corners = [_]Vec3{
                        min_pos,
                        vec3(min_pos.x, min_pos.y, max_pos.z),
                        vec3(min_pos.x, max_pos.y, min_pos.z),
                        vec3(min_pos.x, max_pos.y, max_pos.z),
                        vec3(max_pos.x, min_pos.y, min_pos.z),
                        vec3(max_pos.x, min_pos.y, max_pos.z),
                        vec3(max_pos.x, max_pos.y, min_pos.z),
                        max_pos,
                    };

                    for (corners) |corner| {
                        const transformed_pos = transform.mulVec4(vec4(corner.x, corner.y, corner.z, 1.0)).toVec3();
                        bbox.expandWithVec3(transformed_pos);
                    }
                }
            }
        }
    }

    pub fn setMeshVisibility(self: *Self, mesh_name: []const u8, visible: bool) void {
        for (self.meshes) |mesh| {
            if (mesh.name) |name| {
                if (std.mem.eql(u8, name, mesh_name)) {
                    mesh.is_visible = visible;
                }
            }
        }
    }

    pub fn hideAllMeshes(self: *Self) void {
        for (self.meshes) |mesh| {
            mesh.is_visible = false;
        }
    }

    pub fn showAllMeshes(self: *Self) void {
        for (self.meshes) |mesh| {
            mesh.is_visible = true;
        }
    }

    pub fn setNodeVisibility(self: *Self, node_name: []const u8, visible: bool) void {
        if (self.gltf.nodes) |nodes| {
            for (nodes) |*node| {
                if (node.name) |name| {
                    if (std.mem.eql(u8, name, node_name)) {
                        self.setNodeMeshesVisibility(node, visible);
                    }
                }
            }
        }
    }

    fn setNodeMeshesVisibility(self: *GltfAsset, node: *const gltf_types.Node, visible: bool) void {
        if (node.mesh) |mesh_index| {
            self.meshes[mesh_index].is_visible = visible;
        }
        if (node.children) |children| {
            for (children) |child_index| {
                const child_node = self.gltf.nodes.?[child_index];
                self.setNodeMeshesVisibility(&child_node, visible);
            }
        }
    }

    pub fn getVertexCount(self: *Self) u32 {
        var total_vertices: u32 = 0;
        for (self.meshes) |mesh| {
            for (mesh.primitives.list.items) |primitive| {
                total_vertices += primitive.vertex_count;
            }
        }
        return total_vertices;
    }

    pub fn getTextureCount(self: *Self) u32 {
        return @intCast(self.loaded_textures.count());
    }

    pub fn getMeshPrimitiveCount(self: *Self) u32 {
        var total_primitives: u32 = 0;
        for (self.meshes) |mesh| {
            total_primitives += @intCast(mesh.primitives.list.items.len);
        }
        return total_primitives;
    }

    // Get pre-generated normals for a specific mesh primitive
    pub fn getGeneratedNormals(self: *Self, mesh_index: u32, primitive_index: u32) ?[]Vec3 {
        const key = (@as(u64, mesh_index) << 32) | primitive_index;
        return self.generated_normals.get(key);
    }

    // Generate missing normals for all mesh primitives based on configuration
    fn generateMissingNormals(self: *Self) !void {
        // Skip generation if mode is set to skip
        if (self.normal_generation_mode == .skip) {
            return;
        }

        if (self.gltf.meshes) |gltf_meshes| {
            for (gltf_meshes, 0..) |gltf_mesh, mesh_index| {
                for (gltf_mesh.primitives, 0..) |primitive, primitive_index| {
                    // Skip if this primitive already has normals
                    if (primitive.attributes.normal != null) {
                        continue;
                    }

                    // Get vertex count from position accessor
                    const position_accessor_id = primitive.attributes.position orelse {
                        log.debug("Primitive {d}.{d} has no position data, skipping normal generation", .{ mesh_index, primitive_index });
                        continue;
                    };

                    const position_accessor = self.gltf.accessors.?[position_accessor_id];
                    const vertex_count: u32 = @intCast(position_accessor.count);

                    // Generate normals based on mode
                    const normals = switch (self.normal_generation_mode) {
                        .skip => unreachable, // Already handled above
                        .simple => generateSimpleNormals(self, vertex_count),
                        .accurate => generateAccurateNormals(self, primitive, vertex_count),
                    };

                    // Store generated normals in the map
                    const key = (@as(u64, @intCast(mesh_index)) << 32) | @as(u64, @intCast(primitive_index));
                    try self.generated_normals.put(key, normals);

                    log.debug("Generated {s} normals for mesh {d} primitive {d} ({d} vertices)", .{ @tagName(self.normal_generation_mode), mesh_index, primitive_index, vertex_count });
                }
            }
        }
    }

    pub fn load(self: *Self) !void {
        const file_contents = try std.Io.Dir.cwd().readFileAllocOptions(
            self.context.io,
            self.filepath,
            self.context.temp_alloc,
            .unlimited,
            .@"4",
            null,
        );
        //catch |err| std.debug.panic("Error reading file. error: '{any}'  file: '{s}'\n", .{ err, self.filepath });

        if (isGlbFile(self.filepath)) {
            // GLB format: parse binary format and extract JSON + binary chunks
            const glb_data = try parseGlbFile(file_contents);
            self.gltf = try parser.parseGltfJson(self.context.alloc, self.context.temp_alloc, glb_data.json_data);

            // Pre-populate buffer_data with GLB binary chunk if present
            if (glb_data.binary_data) |bin_data| {
                // Create aligned copy of binary data
                const aligned_data = try self.context.alloc.alignedAlloc(u8, .@"4", bin_data.len);
                @memcpy(aligned_data, bin_data);
                try self.buffer_data.append(aligned_data);
            }
        } else {
            // GLTF format: parse JSON directly
            self.gltf = try parser.parseGltfJson(self.context.alloc, self.context.temp_alloc, file_contents);

            // Load external buffer data from URIs
            try self.loadBufferData();
        }

        // Generate normals for missing ones based on configuration
        try self.generateMissingNormals();

        // Custom textures first, so meshes find them. Color space follows the slot.
        for (self.custom_textures.list.items) |*custom_tex| {
            var config = custom_tex.config;
            config.is_srgb = self.srgb_color_textures and custom_tex.slot.isSrgb();
            custom_tex.texture = self.loadTextureFromFile(custom_tex.texture_path, config) catch |err| {
                log.err("Failed to load custom texture {s}: {any}", .{ custom_tex.texture_path, err });
                continue;
            };
        }

        if (self.gltf.meshes) |meshes| {
            self.meshes = try self.context.alloc.alloc(*Mesh, meshes.len);
            if (self.gltf.meshes) |gltf_meshes| {
                for (gltf_meshes, 0..) |gltf_mesh, mesh_index| {
                    self.meshes[mesh_index] = try Mesh.init(self.context.alloc, self, gltf_mesh, mesh_index);
                }
            }
        }

        self.is_loaded = true;
    }

    pub fn buildModel(self: *Self) !*Model {
        if (!self.is_loaded) {
            try self.load();
        }

        // Create animator
        const animator = try Animator.init(self.context, self);

        // Create model
        const model = try Model.init(
            self.context.alloc,
            self.name,
            animator,
            self,
        );

        return model;
    }

    pub fn getTexture(self: *Self, texture_index: u32) !*texture.Texture {
        if (self.loaded_textures.get(texture_index)) |tex| {
            return tex;
        }

        return GltAssetError.TextureNotLoaded;
    }

    pub fn loadTextureFromFile(self: *Self, texture_path: []const u8, config: texture.TextureConfig) !*texture.Texture {
        const full_path = try std.fs.path.joinZ(self.context.temp_alloc, &[_][]const u8{ self.directory, texture_path });
        defer self.context.temp_alloc.free(full_path);

        return texture.Texture.initFromFile(self.context, self.gpu, full_path, config);
    }

    /// Loads a texture once per asset; later references reuse it. `is_srgb` is set by the
    /// first use (color vs data); a later use as the other kind keeps the first and warns.
    pub fn loadTextureFromGltf(self: *Self, texture_index: u32, is_srgb: bool) !*texture.Texture {
        if (self.loaded_textures.get(texture_index)) |tex| {
            if (tex.is_srgb != is_srgb) {
                log.warn("texture {d} used as both color and data; keeping srgb={}", .{ texture_index, tex.is_srgb });
            }
            return tex;
        }

        const tex = try texture.Texture.initFromGltf(
            self.context,
            self.gpu,
            self,
            self.directory,
            texture_index,
            is_srgb,
        );
        try self.loaded_textures.put(texture_index, tex);
        return tex;
    }

    // Load buffer data from URIs or embedded data
    fn loadBufferData(self: *Self) !void {
        const buffer_count = if (self.gltf.buffers) |buf| buf.len else 0;

        log.debug("Loading buffer data for {d} buffers", .{buffer_count});

        if (self.gltf.buffers) |buffers| {
            for (buffers, 0..) |buffer, buffer_index| {
                // For GLB files, buffer index 0 is typically the embedded binary chunk
                if (isGlbFile(self.filepath) and buffer_index == 0 and buffer.uri == null) {
                    // GLB embedded buffer - should already be loaded in buffer_data
                    // Verify we have the binary data
                    if (self.buffer_data.list.items.len == 0) {
                        std.debug.panic("GLB file missing binary chunk for buffer {d}\n", .{buffer_index});
                    }
                    continue; // Skip loading - already have the data
                }

                if (buffer.uri) |uri| {
                    if (std.mem.eql(u8, "data:", uri[0..5])) {
                        // Handle base64 data URIs
                        const comma = utils.strchr(uri, ',');
                        if (comma) |idx| {
                            const decoder = std.base64.standard.Decoder;
                            const decoded_length = decoder.calcSizeForSlice(uri[idx + 1 .. uri.len]) catch |err| {
                                std.debug.panic("decoder calcSizeForSlice error: {any}\n", .{err});
                            };
                            const decoded_buffer: []align(4) u8 = try self.context.alloc.allocWithOptions(u8, decoded_length, .@"4", null);
                            decoder.decode(decoded_buffer, uri[idx + 1 .. uri.len]) catch |err| {
                                std.debug.panic("decoder decode error: {any}\n", .{err});
                            };
                            try self.buffer_data.append(decoded_buffer);
                        }
                    } else {
                        // Handle external file URIs
                        const path = try std.fs.path.join(self.context.temp_alloc, &[_][]const u8{ self.directory, uri });

                        const buffer_file = std.Io.Dir.cwd().readFileAllocOptions(
                            self.context.io,
                            path,
                            self.context.alloc,
                            .unlimited,
                            .@"4",
                            null,
                        ) catch |err| {
                            std.debug.panic("readFile error: {any} path: {s}\n", .{ err, path });
                        };
                        try self.buffer_data.append(buffer_file);
                    }
                } else {
                    // Buffer with no URI - should only happen for GLB buffer 0
                    if (!isGlbFile(self.filepath) or buffer_index != 0) {
                        std.debug.panic("Buffer {d} has no URI and is not GLB embedded buffer\n", .{buffer_index});
                    }
                }
                log.debug("Loaded buffer {d} with {d} bytes", .{ buffer_index, self.buffer_data.list.items[self.buffer_data.list.items.len - 1].len });
                log.debug("Total buffer size: {d}", .{self.buffer_data.list.items.len});
            }
        }
    }
};

// GLB Helper Functions

fn isGlbFile(filepath: []const u8) bool {
    return std.mem.endsWith(u8, filepath, ".glb");
}

const GlbData = struct {
    json_data: []const u8,
    binary_data: ?[]const u8,
};

fn parseGlbFile(file_data: []const u8) !GlbData {
    // Validate minimum file size (12 bytes for GLB header)
    if (file_data.len < @sizeOf(GlbHeader)) {
        return GlbError.TruncatedFile;
    }

    // Read GLB header
    const header = std.mem.bytesToValue(GlbHeader, file_data[0..@sizeOf(GlbHeader)]);

    // Validate magic number
    if (header.magic != GLB_MAGIC) {
        return GlbError.InvalidMagic;
    }

    // Validate version
    if (header.version != GLB_VERSION) {
        return GlbError.UnsupportedVersion;
    }

    // Validate file length
    if (header.length != file_data.len) {
        return GlbError.TruncatedFile;
    }

    var offset: usize = @sizeOf(GlbHeader);
    var json_data: ?[]const u8 = null;
    var binary_data: ?[]const u8 = null;

    // Parse chunks
    while (offset < file_data.len) {
        // Check if we have enough data for chunk header
        if (offset + @sizeOf(GlbChunkHeader) > file_data.len) {
            return GlbError.TruncatedFile;
        }

        // Read chunk header
        const chunk_header = std.mem.bytesToValue(GlbChunkHeader, file_data[offset .. offset + @sizeOf(GlbChunkHeader)]);
        offset += @sizeOf(GlbChunkHeader);

        // Check if we have enough data for chunk content
        if (offset + chunk_header.length > file_data.len) {
            return GlbError.TruncatedFile;
        }

        // Extract chunk data
        const chunk_data = file_data[offset .. offset + chunk_header.length];

        // Process chunk based on type
        switch (chunk_header.chunk_type) {
            GLB_JSON_CHUNK_TYPE => {
                json_data = chunk_data;
            },
            GLB_BIN_CHUNK_TYPE => {
                binary_data = chunk_data;
            },
            else => {
                // Unknown chunk type - skip it (per glTF spec)
            },
        }

        // Move to next chunk (handle 4-byte alignment padding)
        offset += chunk_header.length;
        // Align to 4-byte boundary
        offset = (offset + 3) & ~@as(usize, 3);
    }

    // Ensure we found JSON chunk
    if (json_data == null) {
        return GlbError.MissingJsonChunk;
    }

    return GlbData{
        .json_data = json_data.?,
        .binary_data = binary_data,
    };
}

// Helper functions for accessor component and type sizes
fn getComponentSize(component_type: gltf_types.ComponentType) usize {
    return switch (component_type) {
        .byte, .unsigned_byte => 1,
        .short, .unsigned_short => 2,
        .unsigned_int, .float => 4,
    };
}

fn getTypeSize(accessor_type: gltf_types.AccessorType) usize {
    return switch (accessor_type) {
        .scalar => 1,
        .vec2 => 2,
        .vec3 => 3,
        .vec4 => 4,
        .mat2 => 4,
        .mat3 => 9,
        .mat4 => 16,
    };
}

// Generate simple upward-facing normals for models that don't have them
pub fn generateSimpleNormals(gltf_asset: *GltfAsset, vertex_count: u32) []Vec3 {
    const normals = gltf_asset.context.alloc.alloc(Vec3, vertex_count) catch |err| {
        std.debug.panic("Failed to allocate normals: {any}", .{err});
    };

    // Generate simple upward normals (0, 1, 0) for all vertices
    for (normals) |*normal| {
        normal.* = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
    }

    return normals;
}

// Generate accurate normals calculated from triangle geometry
pub fn generateAccurateNormals(gltf_asset: *GltfAsset, primitive: gltf_types.MeshPrimitive, vertex_count: u32) []Vec3 {
    // Get position data
    const position_accessor_id = primitive.attributes.position orelse {
        std.debug.panic("Cannot generate normals without positions", .{});
    };

    const position_accessor = gltf_asset.gltf.accessors.?[position_accessor_id];
    const position_buffer_view = gltf_asset.gltf.buffer_views.?[position_accessor.buffer_view.?];
    const position_buffer_data = gltf_asset.buffer_data.list.items[position_buffer_view.buffer];

    const position_start = position_accessor.byte_offset + position_buffer_view.byte_offset;
    const position_data_size = getComponentSize(position_accessor.component_type) * getTypeSize(position_accessor.accessor_type) * position_accessor.count;
    const position_data = position_buffer_data[position_start .. position_start + position_data_size];
    const positions = @as([*]Vec3, @ptrCast(@alignCast(@constCast(position_data))))[0..vertex_count];

    // Initialize normals to zero
    const normals = gltf_asset.context.alloc.alloc(Vec3, vertex_count) catch |err| {
        std.debug.panic("Failed to allocate normals: {any}", .{err});
    };
    for (normals) |*normal| {
        normal.* = Vec3{ .x = 0.0, .y = 0.0, .z = 0.0 };
    }

    // Calculate normals from triangle faces
    if (primitive.indices) |indices_accessor_id| {
        // Indexed geometry - calculate normals from triangles
        const indices_accessor = gltf_asset.gltf.accessors.?[indices_accessor_id];
        const indices_buffer_view = gltf_asset.gltf.buffer_views.?[indices_accessor.buffer_view.?];
        const indices_buffer_data = gltf_asset.buffer_data.list.items[indices_buffer_view.buffer];

        const indices_start = indices_accessor.byte_offset + indices_buffer_view.byte_offset;
        const indices_data_size = getComponentSize(indices_accessor.component_type) * getTypeSize(indices_accessor.accessor_type) * indices_accessor.count;
        const indices_data = indices_buffer_data[indices_start .. indices_start + indices_data_size];

        // Handle different index types
        switch (indices_accessor.component_type) {
            .unsigned_short => {
                const indices = @as([*]u16, @ptrCast(@alignCast(@constCast(indices_data))))[0..indices_accessor.count];
                var i: usize = 0;
                while (i + 2 < indices.len) : (i += 3) {
                    const idx0 = indices[i];
                    const idx1 = indices[i + 1];
                    const idx2 = indices[i + 2];

                    if (idx0 < vertex_count and idx1 < vertex_count and idx2 < vertex_count) {
                        const v0 = positions[idx0];
                        const v1 = positions[idx1];
                        const v2 = positions[idx2];

                        // Calculate face normal using cross product
                        const edge1 = v1.sub(v0);
                        const edge2 = v2.sub(v0);
                        const face_normal = edge1.crossNormalized(edge2);

                        // Add to vertex normals
                        normals[idx0] = normals[idx0].add(face_normal);
                        normals[idx1] = normals[idx1].add(face_normal);
                        normals[idx2] = normals[idx2].add(face_normal);
                    }
                }
            },
            .unsigned_int => {
                const indices = @as([*]u32, @ptrCast(@alignCast(@constCast(indices_data))))[0..indices_accessor.count];
                var i: usize = 0;
                while (i + 2 < indices.len) : (i += 3) {
                    const idx0 = indices[i];
                    const idx1 = indices[i + 1];
                    const idx2 = indices[i + 2];

                    if (idx0 < vertex_count and idx1 < vertex_count and idx2 < vertex_count) {
                        const v0 = positions[idx0];
                        const v1 = positions[idx1];
                        const v2 = positions[idx2];

                        // Calculate face normal using cross product
                        const edge1 = v1.sub(v0);
                        const edge2 = v2.sub(v0);
                        const face_normal = edge1.crossNormalized(edge2);

                        // Add to vertex normals
                        normals[idx0] = normals[idx0].add(face_normal);
                        normals[idx1] = normals[idx1].add(face_normal);
                        normals[idx2] = normals[idx2].add(face_normal);
                    }
                }
            },
            else => {
                log.debug("Unsupported index type for normal generation: {s}", .{@tagName(indices_accessor.component_type)});
                // Fallback to upward normals
                for (normals) |*normal| {
                    normal.* = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
                }
            },
        }
    } else {
        // Non-indexed geometry - assume triangles in order
        var i: usize = 0;
        while (i + 2 < vertex_count) : (i += 3) {
            const v0 = positions[i];
            const v1 = positions[i + 1];
            const v2 = positions[i + 2];

            // Calculate face normal using cross product
            const edge1 = v1.sub(v0);
            const edge2 = v2.sub(v0);
            const face_normal = edge1.crossNormalized(edge2);

            // Set vertex normals to face normal
            normals[i] = face_normal;
            normals[i + 1] = face_normal;
            normals[i + 2] = face_normal;
        }
    }

    // Normalize all accumulated normals
    for (normals) |*normal| {
        if (normal.length() > 0.0) {
            normal.* = normal.toNormalized();
        } else {
            // Fallback to upward normal if no accumulated normal
            normal.* = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
        }
    }

    return normals;
}
