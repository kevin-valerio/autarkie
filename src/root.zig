const std = @import("std");

pub const Id = u64;

pub const DepthInfo = struct {
    generate: usize,
    iterate: usize,
};

pub const GenerateSettings = union(enum) {
    length: usize,
    range: Range,

    pub const Range = struct {
        min: usize,
        max_inclusive: usize,
    };
};

pub const NodeType = union(enum) {
    non_recursive,
    recursive,
    iterable: Iterable,

    pub const Iterable = struct {
        fixed: bool,
        len: usize,
        inner_id: Id,
    };

    pub fn isRecursive(self: NodeType) bool {
        return self == .recursive;
    }

    pub fn isIterable(self: NodeType) bool {
        return self == .iterable;
    }
};

pub const Serialized = struct {
    data: []u8,
    id: Id,
};

pub const FieldLocation = struct {
    index: usize,
    node_type: NodeType,
    id: Id,
};

pub const Cmp = struct {
    left: u64,
    right: u64,
};

pub const CmpMatch = struct {
    path: std.ArrayList(FieldLocation),
    data: []u8,
};

pub const GenerateError = error{
    OutOfMemory,
    RecursionLimit,
};

pub const CodecError = error{
    OutOfMemory,
    UnexpectedEnd,
    InvalidTag,
    TrailingBytes,
};

pub const Mutation = union(enum) {
    generate_replace,
    recursive_replace,
    splice: []const u8,
    generate_append,
    splice_append: []const u8,
    iterable_pop: usize,
};

pub const MutationError = error{
    OutOfMemory,
    RecursionLimit,
    UnexpectedEnd,
    InvalidTag,
    TrailingBytes,
    InvalidPath,
    ImmutableField,
    UnsupportedMutation,
};

pub const FuzzResult = enum {
    ok,
    interesting,
    crash,
};

pub const FuzzConfig = struct {
    seed: u64 = 0,
    depth: DepthInfo = .{
        .generate = 2,
        .iterate = 5,
    },
    string_count: usize = 50,
    generated_inputs: usize = 100,
    mutations_per_input: usize = 0,
};

pub const FuzzStats = struct {
    executions: usize = 0,
    generated: usize = 0,
    mutations: usize = 0,
    interesting: usize = 0,
    crashes: usize = 0,

    fn record(self: *FuzzStats, result: FuzzResult) void {
        self.executions += 1;
        switch (result) {
            .ok => {},
            .interesting => self.interesting += 1,
            .crash => self.crashes += 1,
        }
    }
};

pub const Visitor = struct {
    allocator: std.mem.Allocator,
    depth: DepthInfo,
    prng: std.Random.DefaultPrng,
    strings: std.ArrayList([]u8),
    serialized_items: std.ArrayList(Serialized),
    fields_items: std.ArrayList(std.ArrayList(FieldLocation)),
    matching_cmps: std.ArrayList(CmpMatch),
    field_stack: std.ArrayList(FieldLocation),

    pub fn init(
        allocator: std.mem.Allocator,
        seed: u64,
        depth: DepthInfo,
        string_count: usize,
    ) !Visitor {
        var visitor = Visitor{
            .allocator = allocator,
            .depth = depth,
            .prng = std.Random.DefaultPrng.init(seed),
            .strings = .empty,
            .serialized_items = .empty,
            .fields_items = .empty,
            .matching_cmps = .empty,
            .field_stack = .empty,
        };
        errdefer visitor.deinit();

        try visitor.addRandomStrings(string_count, 10);
        return visitor;
    }

    pub fn deinit(self: *Visitor) void {
        for (self.strings.items) |item| {
            self.allocator.free(item);
        }
        self.strings.deinit(self.allocator);

        for (self.serialized_items.items) |item| {
            self.allocator.free(item.data);
        }
        self.serialized_items.deinit(self.allocator);

        for (self.fields_items.items) |*field_path| {
            field_path.deinit(self.allocator);
        }
        self.fields_items.deinit(self.allocator);

        for (self.matching_cmps.items) |*match| {
            match.path.deinit(self.allocator);
            self.allocator.free(match.data);
        }
        self.matching_cmps.deinit(self.allocator);
        self.field_stack.deinit(self.allocator);
    }

    pub fn random(self: *Visitor) std.Random {
        return self.prng.random();
    }

    pub fn generateDepth(self: *const Visitor) usize {
        return self.depth.generate;
    }

    pub fn iterateDepth(self: *const Visitor) usize {
        return self.depth.iterate;
    }

    pub fn coinflip(self: *Visitor) bool {
        return self.random().boolean();
    }

    pub fn coinflipWithProbability(self: *Visitor, probability: f64) bool {
        std.debug.assert(probability >= 0.0 and probability <= 1.0);
        return self.random().float(f64) < probability;
    }

    pub fn randomRange(self: *Visitor, min: usize, max_exclusive: usize) usize {
        std.debug.assert(min < max_exclusive);
        return self.random().intRangeLessThan(usize, min, max_exclusive);
    }

    pub fn generateBytes(self: *Visitor, amount: usize) ![]u8 {
        const bytes = try self.allocator.alloc(u8, amount);
        self.random().bytes(bytes);
        return bytes;
    }

    pub fn registerString(self: *Visitor, string: []const u8) !void {
        for (self.strings.items) |existing| {
            if (std.mem.eql(u8, existing, string)) return;
        }
        try self.strings.append(self.allocator, try self.allocator.dupe(u8, string));
    }

    pub fn getString(self: *Visitor) ![]u8 {
        if (self.strings.items.len == 0) {
            try self.addRandomStrings(1, 10);
        }
        const index = self.randomRange(0, self.strings.items.len);
        return self.allocator.dupe(u8, self.strings.items[index]);
    }

    pub fn addSerialized(self: *Visitor, data: []const u8, id: Id) !void {
        try self.serialized_items.append(self.allocator, .{
            .data = try self.allocator.dupe(u8, data),
            .id = id,
        });
    }

    pub fn takeSerialized(self: *Visitor) std.ArrayList(Serialized) {
        const items = self.serialized_items;
        self.serialized_items = .empty;
        return items;
    }

    pub fn registerCmp(self: *Visitor, data: []const u8) !void {
        var path: std.ArrayList(FieldLocation) = .empty;
        errdefer path.deinit(self.allocator);
        try path.appendSlice(self.allocator, self.field_stack.items);

        const owned_data = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned_data);

        try self.matching_cmps.append(self.allocator, .{
            .path = path,
            .data = owned_data,
        });
    }

    pub fn takeCmps(self: *Visitor) std.ArrayList(CmpMatch) {
        const matches = self.matching_cmps;
        self.matching_cmps = .empty;

        for (self.fields_items.items) |*field_path| {
            field_path.deinit(self.allocator);
        }
        self.fields_items.clearRetainingCapacity();
        self.field_stack.clearRetainingCapacity();

        return matches;
    }

    pub fn registerField(self: *Visitor, item: FieldLocation) !void {
        try self.field_stack.append(self.allocator, item);
        var path: std.ArrayList(FieldLocation) = .empty;
        errdefer path.deinit(self.allocator);
        try path.appendSlice(self.allocator, self.field_stack.items);
        try self.fields_items.append(self.allocator, path);
    }

    pub fn registerFieldStack(self: *Visitor, item: FieldLocation) !void {
        try self.field_stack.append(self.allocator, item);
    }

    pub fn popField(self: *Visitor) void {
        _ = self.field_stack.pop();
    }

    pub fn takeFields(self: *Visitor) std.ArrayList(std.ArrayList(FieldLocation)) {
        const items = self.fields_items;
        self.fields_items = .empty;
        self.field_stack.clearRetainingCapacity();
        return items;
    }

    fn addRandomStrings(self: *Visitor, count: usize, max_len: usize) !void {
        const printables = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        while (self.strings.items.len < count) {
            const len = self.randomRange(1, max_len + 1);
            const string = try self.allocator.alloc(u8, len);
            errdefer self.allocator.free(string);
            for (string) |*byte| {
                byte.* = printables[self.randomRange(0, printables.len)];
            }
            try self.registerOwnedUniqueString(string);
        }
    }

    fn registerOwnedUniqueString(self: *Visitor, string: []u8) !void {
        for (self.strings.items) |existing| {
            if (std.mem.eql(u8, existing, string)) {
                self.allocator.free(string);
                return;
            }
        }
        try self.strings.append(self.allocator, string);
    }
};

pub fn deinitFieldPaths(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList(std.ArrayList(FieldLocation)),
) void {
    for (paths.items) |*path| {
        path.deinit(allocator);
    }
    paths.deinit(allocator);
}

pub fn deinitCmpMatches(allocator: std.mem.Allocator, matches: *std.ArrayList(CmpMatch)) void {
    for (matches.items) |*match| {
        match.path.deinit(allocator);
        allocator.free(match.data);
    }
    matches.deinit(allocator);
}

pub fn typeId(comptime T: type) Id {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

pub fn generate(comptime T: type, visitor: *Visitor) GenerateError!T {
    return generateWithSettings(T, visitor, null);
}

pub fn generateWithSettings(
    comptime T: type,
    visitor: *Visitor,
    settings: ?GenerateSettings,
) GenerateError!T {
    return generateValue(T, visitor, 0, settings);
}

pub fn serializeAlloc(comptime T: type, allocator: std.mem.Allocator, value: T) CodecError![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try appendEncoded(T, allocator, &bytes, value);
    return bytes.toOwnedSlice(allocator);
}

pub fn deserializeAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    data: []const u8,
) CodecError!T {
    var decoder = Decoder{
        .allocator = allocator,
        .data = data,
    };
    var value = try decoder.readValue(T);
    errdefer deinitGenerated(T, allocator, &value);

    if (!decoder.finished()) return error.TrailingBytes;
    return value;
}

pub fn maybeDeserializeAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    data: []const u8,
) CodecError!?T {
    var decoder = Decoder{
        .allocator = allocator,
        .data = data,
    };
    var value = decoder.readValue(T) catch |err| switch (err) {
        error.UnexpectedEnd, error.InvalidTag, error.TrailingBytes => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (!decoder.finished()) {
        deinitGenerated(T, allocator, &value);
        return null;
    }
    return value;
}

pub fn collectFields(comptime T: type, visitor: *Visitor, value: *const T) !void {
    try collectFieldsAt(T, visitor, value);
}

pub fn collectCmps(comptime T: type, visitor: *Visitor, value: *const T, cmp: Cmp) !void {
    try collectCmpMatchesAt(T, visitor, value, cmp);
}

pub fn runGenerated(
    comptime T: type,
    allocator: std.mem.Allocator,
    config: FuzzConfig,
    harness: anytype,
) !FuzzStats {
    var visitor = try Visitor.init(allocator, config.seed, config.depth, config.string_count);
    defer visitor.deinit();

    var stats = FuzzStats{};
    for (0..config.generated_inputs) |_| {
        var value = try generate(T, &visitor);
        defer deinitGenerated(T, allocator, &value);

        stats.generated += 1;
        stats.record(harness(&value));
    }

    return stats;
}

pub fn runMutational(
    comptime T: type,
    allocator: std.mem.Allocator,
    config: FuzzConfig,
    harness: anytype,
) !FuzzStats {
    var visitor = try Visitor.init(allocator, config.seed, config.depth, config.string_count);
    defer visitor.deinit();

    var stats = FuzzStats{};
    for (0..config.generated_inputs) |_| {
        var value = try generate(T, &visitor);
        defer deinitGenerated(T, allocator, &value);

        stats.generated += 1;
        stats.record(harness(&value));

        for (0..config.mutations_per_input) |_| {
            try mutateRandomPath(T, allocator, &visitor, &value);
            stats.mutations += 1;
            stats.record(harness(&value));
        }
    }

    return stats;
}

pub fn mutateAtPath(
    comptime T: type,
    visitor: *Visitor,
    value: *T,
    path: []const usize,
    mutation: Mutation,
) MutationError!void {
    if (path.len == 0) {
        return mutateHere(T, visitor, value, mutation);
    }

    switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => return mutateAtPath(pointer.child, visitor, value.*, path, mutation),
            .slice => {
                if (pointer.is_const) return error.ImmutableField;
                const index = path[0];
                if (index >= value.*.len) return error.InvalidPath;
                return mutateAtPath(pointer.child, visitor, &value.*[index], path[1..], mutation);
            },
            else => return error.InvalidPath,
        },
        .array => |array| {
            const index = path[0];
            if (index >= array.len) return error.InvalidPath;
            return mutateAtPath(array.child, visitor, &value[index], path[1..], mutation);
        },
        .optional => |optional| {
            if (path[0] != 0) return error.InvalidPath;
            if (value.*) |*payload| {
                return mutateAtPath(optional.child, visitor, payload, path[1..], mutation);
            }
            return error.InvalidPath;
        },
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, i| {
                if (path[0] == i) {
                    if (field.is_comptime) return error.ImmutableField;
                    return mutateAtPath(field.type, visitor, &@field(value, field.name), path[1..], mutation);
                }
            }
            return error.InvalidPath;
        },
        .@"union" => |info| {
            if (info.tag_type == null) return error.InvalidPath;
            switch (value.*) {
                inline else => |*payload, tag| {
                    inline for (info.fields, 0..) |field, i| {
                        if (comptime std.mem.eql(u8, field.name, @tagName(tag))) {
                            if (path[0] != i) return error.InvalidPath;
                            if (field.type == void) return error.InvalidPath;
                            return mutateAtPath(field.type, visitor, payload, path[1..], mutation);
                        }
                    }
                    unreachable;
                },
            }
        },
        else => return error.InvalidPath,
    }
}

pub fn deinitGenerated(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => {
                deinitGenerated(pointer.child, allocator, value.*);
                allocator.destroy(value.*);
            },
            .slice => {
                if (comptime needsGeneratedDeinit(pointer.child)) {
                    for (value.*) |*item| {
                        deinitGenerated(pointer.child, allocator, item);
                    }
                }
                allocator.free(value.*);
            },
            else => {},
        },
        .array => |array| {
            if (comptime needsGeneratedDeinit(array.child)) {
                for (value) |*item| {
                    deinitGenerated(array.child, allocator, item);
                }
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!field.is_comptime and comptime needsGeneratedDeinit(field.type)) {
                    deinitGenerated(field.type, allocator, &@field(value, field.name));
                }
            }
        },
        .optional => |optional| {
            if (value.*) |*payload| {
                deinitGenerated(optional.child, allocator, payload);
            }
        },
        .@"union" => {
            switch (value.*) {
                inline else => |*payload| {
                    deinitGenerated(@TypeOf(payload.*), allocator, payload);
                },
            }
        },
        else => {},
    }
}

const Decoder = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    index: usize = 0,

    fn finished(self: *const Decoder) bool {
        return self.index == self.data.len;
    }

    fn readBytes(self: *Decoder, len: usize) CodecError![]const u8 {
        if (self.index + len > self.data.len) return error.UnexpectedEnd;
        const bytes = self.data[self.index..][0..len];
        self.index += len;
        return bytes;
    }

    fn readValue(self: *Decoder, comptime T: type) CodecError!T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => {
                const byte = (try self.readBytes(1))[0];
                return switch (byte) {
                    0 => false,
                    1 => true,
                    else => error.InvalidTag,
                };
            },
            .int => return try self.readInt(T),
            .float => {
                const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                return @bitCast(try self.readInt(U));
            },
            .array => |array| {
                var result: T = undefined;
                var decoded: usize = 0;
                errdefer {
                    if (comptime needsGeneratedDeinit(array.child)) {
                        for (result[0..decoded]) |*item| {
                            deinitGenerated(array.child, self.allocator, item);
                        }
                    }
                }

                for (&result) |*item| {
                    item.* = try self.readValue(array.child);
                    decoded += 1;
                }
                return result;
            },
            .pointer => |pointer| return try self.readPointer(T, pointer),
            .optional => |optional| {
                const tag = (try self.readBytes(1))[0];
                return switch (tag) {
                    0 => null,
                    1 => try self.readValue(optional.child),
                    else => error.InvalidTag,
                };
            },
            .@"enum" => |info| {
                const raw = try self.readInt(info.tag_type);
                inline for (info.fields) |field| {
                    if (field.value == raw) return @enumFromInt(raw);
                }
                return error.InvalidTag;
            },
            .@"struct" => |info| {
                var result: T = undefined;
                var decoded: usize = 0;
                errdefer {
                    inline for (info.fields, 0..) |field, i| {
                        if (i < decoded and !field.is_comptime and comptime needsGeneratedDeinit(field.type)) {
                            deinitGenerated(field.type, self.allocator, &@field(result, field.name));
                        }
                    }
                }

                inline for (info.fields) |field| {
                    if (!field.is_comptime) {
                        @field(result, field.name) = try self.readValue(field.type);
                        decoded += 1;
                    }
                }
                return result;
            },
            .@"union" => |info| return try self.readUnion(T, info),
            else => @compileError("autarkie cannot deserialize values for " ++ @typeName(T)),
        }
    }

    fn readInt(self: *Decoder, comptime T: type) CodecError!T {
        comptime {
            const bits = @typeInfo(T).int.bits;
            if (bits % 8 != 0) {
                @compileError("autarkie serialization requires byte-aligned integers");
            }
        }

        const byte_count = @divExact(@typeInfo(T).int.bits, 8);
        const bytes = try self.readBytes(byte_count);
        return std.mem.readInt(T, bytes[0..byte_count], .little);
    }

    fn readPointer(
        self: *Decoder,
        comptime T: type,
        comptime pointer: std.builtin.Type.Pointer,
    ) CodecError!T {
        switch (pointer.size) {
            .one => {
                const value = try self.allocator.create(pointer.child);
                errdefer self.allocator.destroy(value);
                value.* = try self.readValue(pointer.child);
                return value;
            },
            .slice => {
                const len = try self.readInt(u64);
                if (len > std.math.maxInt(usize)) return error.InvalidTag;
                const slice = try self.allocator.alloc(pointer.child, @intCast(len));
                var decoded: usize = 0;
                errdefer {
                    if (comptime needsGeneratedDeinit(pointer.child)) {
                        for (slice[0..decoded]) |*item| {
                            deinitGenerated(pointer.child, self.allocator, item);
                        }
                    }
                    self.allocator.free(slice);
                }

                for (slice) |*item| {
                    item.* = try self.readValue(pointer.child);
                    decoded += 1;
                }
                return slice;
            },
            else => @compileError("autarkie only deserializes single-item pointers and slices"),
        }
    }

    fn readUnion(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Union,
    ) CodecError!T {
        if (info.tag_type == null) {
            @compileError("autarkie only deserializes tagged unions");
        }

        const tag = try self.readInt(u32);
        inline for (info.fields, 0..) |field, i| {
            if (tag == i) {
                if (field.type == void) return @unionInit(T, field.name, {});
                return @unionInit(T, field.name, try self.readValue(field.type));
            }
        }
        return error.InvalidTag;
    }
};

fn appendEncoded(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    value: T,
) CodecError!void {
    switch (@typeInfo(T)) {
        .void => return,
        .bool => try bytes.append(allocator, @intFromBool(value)),
        .int => try appendInt(T, allocator, bytes, value),
        .float => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            try appendInt(U, allocator, bytes, @bitCast(value));
        },
        .array => |array| {
            for (value) |item| {
                try appendEncoded(array.child, allocator, bytes, item);
            }
        },
        .pointer => |pointer| try appendPointer(T, pointer, allocator, bytes, value),
        .optional => |optional| {
            if (value) |payload| {
                try bytes.append(allocator, 1);
                try appendEncoded(optional.child, allocator, bytes, payload);
            } else {
                try bytes.append(allocator, 0);
            }
        },
        .@"enum" => |info| {
            try appendInt(info.tag_type, allocator, bytes, @intFromEnum(value));
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!field.is_comptime) {
                    try appendEncoded(field.type, allocator, bytes, @field(value, field.name));
                }
            }
        },
        .@"union" => |info| try appendUnion(T, info, allocator, bytes, value),
        else => @compileError("autarkie cannot serialize values for " ++ @typeName(T)),
    }
}

fn appendInt(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    value: T,
) CodecError!void {
    comptime {
        const bits = @typeInfo(T).int.bits;
        if (bits % 8 != 0) {
            @compileError("autarkie serialization requires byte-aligned integers");
        }
    }

    const byte_count = @divExact(@typeInfo(T).int.bits, 8);
    var buffer: [byte_count]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try bytes.appendSlice(allocator, &buffer);
}

fn appendPointer(
    comptime T: type,
    comptime pointer: std.builtin.Type.Pointer,
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    value: T,
) CodecError!void {
    switch (pointer.size) {
        .one => try appendEncoded(pointer.child, allocator, bytes, value.*),
        .slice => {
            try appendInt(u64, allocator, bytes, value.len);
            for (value) |item| {
                try appendEncoded(pointer.child, allocator, bytes, item);
            }
        },
        else => @compileError("autarkie only serializes single-item pointers and slices"),
    }
}

fn appendUnion(
    comptime T: type,
    comptime info: std.builtin.Type.Union,
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    value: T,
) CodecError!void {
    if (info.tag_type == null) {
        @compileError("autarkie only serializes tagged unions");
    }

    switch (value) {
        inline else => |payload, tag| {
            inline for (info.fields, 0..) |field, i| {
                if (comptime std.mem.eql(u8, field.name, @tagName(tag))) {
                    try appendInt(u32, allocator, bytes, @intCast(i));
                    try appendEncoded(field.type, allocator, bytes, payload);
                    return;
                }
            }
            unreachable;
        },
    }
}

fn collectFieldsAt(comptime T: type, visitor: *Visitor, value: *const T) !void {
    switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => try collectFieldsAt(pointer.child, visitor, value.*),
            .slice => {
                for (value.*, 0..) |*item, i| {
                    try visitor.registerFieldStack(.{
                        .index = i,
                        .node_type = nodeTypeOf(pointer.child, item),
                        .id = typeId(pointer.child),
                    });
                    try collectFieldsAt(pointer.child, visitor, item);
                    visitor.popField();
                }
            },
            else => {},
        },
        .array => |array| {
            for (value, 0..) |*item, i| {
                try visitor.registerFieldStack(.{
                    .index = i,
                    .node_type = nodeTypeOf(array.child, item),
                    .id = typeId(array.child),
                });
                try collectFieldsAt(array.child, visitor, item);
                visitor.popField();
            }
        },
        .optional => |optional| {
            if (value.*) |*payload| {
                try visitor.registerFieldStack(.{
                    .index = 0,
                    .node_type = nodeTypeOf(optional.child, payload),
                    .id = typeId(optional.child),
                });
                try collectFieldsAt(optional.child, visitor, payload);
                visitor.popField();
            }
        },
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, i| {
                if (!field.is_comptime) {
                    const field_value = &@field(value, field.name);
                    try visitor.registerField(.{
                        .index = i,
                        .node_type = nodeTypeOf(field.type, field_value),
                        .id = typeId(field.type),
                    });
                    try collectFieldsAt(field.type, visitor, field_value);
                    visitor.popField();
                }
            }
        },
        .@"union" => |info| {
            if (info.tag_type == null) return;
            switch (value.*) {
                inline else => |*payload, tag| {
                    inline for (info.fields, 0..) |field, i| {
                        if (comptime std.mem.eql(u8, field.name, @tagName(tag))) {
                            if (field.type == void) return;
                            try visitor.registerField(.{
                                .index = i,
                                .node_type = nodeTypeOf(field.type, payload),
                                .id = typeId(field.type),
                            });
                            try collectFieldsAt(field.type, visitor, payload);
                            visitor.popField();
                            return;
                        }
                    }
                    unreachable;
                },
            }
        },
        else => {},
    }
}

fn collectCmpMatchesAt(comptime T: type, visitor: *Visitor, value: *const T, cmp: Cmp) !void {
    switch (@typeInfo(T)) {
        .int, .float => try collectScalarCmp(T, visitor, value.*, cmp),
        .pointer => |pointer| switch (pointer.size) {
            .one => try collectCmpMatchesAt(pointer.child, visitor, value.*, cmp),
            .slice => {
                for (value.*, 0..) |*item, i| {
                    try visitor.registerFieldStack(.{
                        .index = i,
                        .node_type = nodeTypeOf(pointer.child, item),
                        .id = typeId(pointer.child),
                    });
                    try collectCmpMatchesAt(pointer.child, visitor, item, cmp);
                    visitor.popField();
                }
            },
            else => {},
        },
        .array => |array| {
            for (value, 0..) |*item, i| {
                try visitor.registerFieldStack(.{
                    .index = i,
                    .node_type = nodeTypeOf(array.child, item),
                    .id = typeId(array.child),
                });
                try collectCmpMatchesAt(array.child, visitor, item, cmp);
                visitor.popField();
            }
        },
        .optional => |optional| {
            if (value.*) |*payload| {
                try visitor.registerFieldStack(.{
                    .index = 0,
                    .node_type = nodeTypeOf(optional.child, payload),
                    .id = typeId(optional.child),
                });
                try collectCmpMatchesAt(optional.child, visitor, payload, cmp);
                visitor.popField();
            }
        },
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, i| {
                if (!field.is_comptime) {
                    const field_value = &@field(value, field.name);
                    try visitor.registerFieldStack(.{
                        .index = i,
                        .node_type = nodeTypeOf(field.type, field_value),
                        .id = typeId(field.type),
                    });
                    try collectCmpMatchesAt(field.type, visitor, field_value, cmp);
                    visitor.popField();
                }
            }
        },
        .@"union" => |info| {
            if (info.tag_type == null) return;
            switch (value.*) {
                inline else => |*payload, tag| {
                    inline for (info.fields, 0..) |field, i| {
                        if (comptime std.mem.eql(u8, field.name, @tagName(tag))) {
                            if (field.type == void) return;
                            try visitor.registerFieldStack(.{
                                .index = i,
                                .node_type = nodeTypeOf(field.type, payload),
                                .id = typeId(field.type),
                            });
                            try collectCmpMatchesAt(field.type, visitor, payload, cmp);
                            visitor.popField();
                            return;
                        }
                    }
                    unreachable;
                },
            }
        },
        else => {},
    }
}

fn mutateHere(comptime T: type, visitor: *Visitor, value: *T, mutation: Mutation) MutationError!void {
    switch (mutation) {
        .generate_replace => {
            var replacement = try generateValue(T, visitor, 0, null);
            errdefer deinitGenerated(T, visitor.allocator, &replacement);
            replaceValue(T, visitor.allocator, value, replacement);
        },
        .recursive_replace => {
            var replacement = try generateValue(T, visitor, visitor.generateDepth(), null);
            errdefer deinitGenerated(T, visitor.allocator, &replacement);
            replaceValue(T, visitor.allocator, value, replacement);
        },
        .splice => |data| {
            var replacement = try deserializeAlloc(T, visitor.allocator, data);
            errdefer deinitGenerated(T, visitor.allocator, &replacement);
            replaceValue(T, visitor.allocator, value, replacement);
        },
        .generate_append, .splice_append, .iterable_pop => {
            return mutateIterableHere(T, visitor, value, mutation);
        },
    }
}

fn mutateRandomPath(
    comptime T: type,
    allocator: std.mem.Allocator,
    visitor: *Visitor,
    value: *T,
) !void {
    try collectFields(T, visitor, value);
    var paths = visitor.takeFields();
    defer deinitFieldPaths(allocator, &paths);

    if (paths.items.len == 0) {
        try mutateAtPath(T, visitor, value, &[_]usize{}, .generate_replace);
        return;
    }

    const selected_index = visitor.randomRange(0, paths.items.len);
    const selected = paths.items[selected_index].items;
    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(allocator);
    for (selected) |field| {
        try path.append(allocator, field.index);
    }

    try mutateAtPath(T, visitor, value, path.items, .generate_replace);
}

fn mutateIterableHere(
    comptime T: type,
    visitor: *Visitor,
    value: *T,
    mutation: Mutation,
) MutationError!void {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .slice) return error.UnsupportedMutation;
            switch (mutation) {
                .generate_append => {
                    var item = try generateValue(pointer.child, visitor, 0, null);
                    errdefer deinitGenerated(pointer.child, visitor.allocator, &item);
                    try appendSliceItem(T, pointer, visitor.allocator, value, item);
                },
                .splice_append => |data| {
                    var item = try deserializeAlloc(pointer.child, visitor.allocator, data);
                    errdefer deinitGenerated(pointer.child, visitor.allocator, &item);
                    try appendSliceItem(T, pointer, visitor.allocator, value, item);
                },
                .iterable_pop => |index| try popSliceItem(T, pointer, visitor.allocator, value, index),
                else => return error.UnsupportedMutation,
            }
        },
        else => return error.UnsupportedMutation,
    }
}

fn replaceValue(comptime T: type, allocator: std.mem.Allocator, value: *T, replacement: T) void {
    deinitGenerated(T, allocator, value);
    value.* = replacement;
}

fn appendSliceItem(
    comptime T: type,
    comptime pointer: std.builtin.Type.Pointer,
    allocator: std.mem.Allocator,
    value: *T,
    item: pointer.child,
) MutationError!void {
    const old = value.*;
    const replacement = try allocator.alloc(pointer.child, old.len + 1);
    for (old, 0..) |old_item, i| {
        replacement[i] = old_item;
    }
    replacement[old.len] = item;
    allocator.free(old);
    value.* = replacement;
}

fn popSliceItem(
    comptime T: type,
    comptime pointer: std.builtin.Type.Pointer,
    allocator: std.mem.Allocator,
    value: *T,
    index: usize,
) MutationError!void {
    const old = value.*;
    if (index >= old.len) return error.InvalidPath;
    const replacement = try allocator.alloc(pointer.child, old.len - 1);
    errdefer allocator.free(replacement);

    var out: usize = 0;
    for (old, 0..) |old_item, i| {
        if (i == index) {
            if (comptime needsGeneratedDeinit(pointer.child)) {
                var removed = old_item;
                deinitGenerated(pointer.child, allocator, &removed);
            }
            continue;
        }
        replacement[out] = old_item;
        out += 1;
    }
    allocator.free(old);
    value.* = replacement;
}

fn nodeTypeOf(comptime T: type, value: *const T) NodeType {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => nodeTypeOf(pointer.child, value.*),
            .slice => .{
                .iterable = .{
                    .fixed = false,
                    .len = value.*.len,
                    .inner_id = typeId(pointer.child),
                },
            },
            else => .non_recursive,
        },
        .array => |array| .{
            .iterable = .{
                .fixed = true,
                .len = array.len,
                .inner_id = typeId(array.child),
            },
        },
        .@"union" => |info| blk: {
            if (info.tag_type == null) break :blk .non_recursive;
            switch (value.*) {
                inline else => |_, tag| {
                    inline for (info.fields) |field| {
                        if (comptime std.mem.eql(u8, field.name, @tagName(tag))) {
                            if (containsType(field.type, T)) break :blk .recursive;
                            break :blk .non_recursive;
                        }
                    }
                    unreachable;
                },
            }
        },
        else => .non_recursive,
    };
}

fn collectScalarCmp(comptime T: type, visitor: *Visitor, value: T, cmp: Cmp) !void {
    const value_as_u64 = valueAsCmpU64(T, value) orelse return;
    if (value_as_u64 == cmp.left) {
        try registerCmpReplacement(T, visitor, cmp.right);
    } else if (value_as_u64 == cmp.right) {
        try registerCmpReplacement(T, visitor, cmp.left);
    }
}

fn registerCmpReplacement(comptime T: type, visitor: *Visitor, raw: u64) !void {
    const replacement = cmpU64AsValue(T, raw);
    const data = try serializeAlloc(T, visitor.allocator, replacement);
    defer visitor.allocator.free(data);
    try visitor.registerCmp(data);
}

fn valueAsCmpU64(comptime T: type, value: T) ?u64 {
    return switch (@typeInfo(T)) {
        .int => |int| switch (int.signedness) {
            .unsigned => @truncate(value),
            .signed => signedAsCmpU64(T, int.bits, value),
        },
        .float => {
            if (!std.math.isFinite(value) or value < 0 or value > std.math.maxInt(u64)) return null;
            return @intFromFloat(value);
        },
        else => null,
    };
}

fn signedAsCmpU64(comptime T: type, comptime bits: u16, value: T) u64 {
    if (bits < 64) {
        return @bitCast(@as(i64, value));
    }
    const U = std.meta.Int(.unsigned, bits);
    return @truncate(@as(U, @bitCast(value)));
}

fn cmpU64AsValue(comptime T: type, raw: u64) T {
    return switch (@typeInfo(T)) {
        .int => |int| {
            const U = std.meta.Int(.unsigned, int.bits);
            const truncated: U = @truncate(raw);
            return switch (int.signedness) {
                .unsigned => truncated,
                .signed => @bitCast(truncated),
            };
        },
        .float => @floatFromInt(raw),
        else => unreachable,
    };
}

fn generateValue(
    comptime T: type,
    visitor: *Visitor,
    depth: usize,
    settings: ?GenerateSettings,
) GenerateError!T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return visitor.coinflip(),
        .int => return generateInt(T, visitor, settings),
        .float => return visitor.random().float(T),
        .array => |array| {
            var result: T = undefined;
            for (&result) |*item| {
                item.* = try generateValue(array.child, visitor, depth, null);
            }
            return result;
        },
        .pointer => |pointer| return generatePointer(T, pointer, visitor, depth, settings),
        .optional => |optional| {
            if (depth >= visitor.generateDepth() or !visitor.coinflip()) return null;
            return try generateValue(optional.child, visitor, depth + 1, null);
        },
        .@"enum" => |info| {
            if (info.fields.len == 0) {
                @compileError("cannot generate values for an enum with no fields");
            }
            const index = visitor.randomRange(0, info.fields.len);
            inline for (info.fields, 0..) |field, i| {
                if (i == index) return @enumFromInt(field.value);
            }
            unreachable;
        },
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |field| {
                if (!field.is_comptime) {
                    @field(result, field.name) = try generateValue(field.type, visitor, depth, null);
                }
            }
            return result;
        },
        .@"union" => |info| return generateUnion(T, info, visitor, depth),
        else => @compileError("autarkie cannot generate values for " ++ @typeName(T)),
    }
}

fn generateInt(comptime T: type, visitor: *Visitor, settings: ?GenerateSettings) T {
    const info = @typeInfo(T).int;
    if (settings) |value| {
        if (value == .range) {
            const range = value.range;
            std.debug.assert(range.min <= range.max_inclusive);
            if (info.signedness == .signed) {
                const min: T = @intCast(range.min);
                const max: T = @intCast(range.max_inclusive);
                return visitor.random().intRangeAtMost(T, min, max);
            }
            const min: T = @intCast(range.min);
            const max: T = @intCast(range.max_inclusive);
            return visitor.random().intRangeAtMost(T, min, max);
        }
    }
    return visitor.random().int(T);
}

fn generatePointer(
    comptime T: type,
    comptime pointer: std.builtin.Type.Pointer,
    visitor: *Visitor,
    depth: usize,
    settings: ?GenerateSettings,
) GenerateError!T {
    switch (pointer.size) {
        .one => {
            if (depth >= visitor.generateDepth()) return error.RecursionLimit;
            const value = try visitor.allocator.create(pointer.child);
            errdefer visitor.allocator.destroy(value);
            value.* = try generateValue(pointer.child, visitor, depth + 1, null);
            return value;
        },
        .slice => {
            const len = generatedLength(visitor, settings);
            const slice = try visitor.allocator.alloc(pointer.child, len);
            errdefer visitor.allocator.free(slice);
            for (slice) |*item| {
                item.* = try generateValue(pointer.child, visitor, depth, null);
            }
            return slice;
        },
        else => @compileError("autarkie only generates single-item pointers and slices"),
    }
}

fn generateUnion(
    comptime T: type,
    comptime info: std.builtin.Type.Union,
    visitor: *Visitor,
    depth: usize,
) GenerateError!T {
    if (info.tag_type == null) {
        @compileError("autarkie only generates tagged unions");
    }

    var allowed: usize = 0;
    inline for (info.fields) |field| {
        if (depth < visitor.generateDepth() or !containsType(field.type, T)) {
            allowed += 1;
        }
    }
    if (allowed == 0) return error.RecursionLimit;

    const selected = visitor.randomRange(0, allowed);
    var seen: usize = 0;
    inline for (info.fields) |field| {
        if (depth < visitor.generateDepth() or !containsType(field.type, T)) {
            if (seen == selected) {
                if (field.type == void) {
                    return @unionInit(T, field.name, {});
                }
                return @unionInit(T, field.name, try generateValue(field.type, visitor, depth + 1, null));
            }
            seen += 1;
        }
    }
    unreachable;
}

fn generatedLength(visitor: *Visitor, settings: ?GenerateSettings) usize {
    if (settings) |value| {
        switch (value) {
            .length => |len| return len,
            .range => |range| return visitor.randomRange(range.min, range.max_inclusive + 1),
        }
    }
    if (visitor.iterateDepth() == 0) return 0;
    return visitor.randomRange(0, visitor.iterateDepth() + 1);
}

fn containsType(comptime T: type, comptime Needle: type) bool {
    if (T == Needle) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| containsType(pointer.child, Needle),
        .array => |array| containsType(array.child, Needle),
        .optional => |optional| containsType(optional.child, Needle),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (containsType(field.type, Needle)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (containsType(field.type, Needle)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn needsGeneratedDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |array| needsGeneratedDeinit(array.child),
        .optional => |optional| needsGeneratedDeinit(optional.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (!field.is_comptime and needsGeneratedDeinit(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (needsGeneratedDeinit(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

test "visitor string pool returns registered strings" {
    var visitor = try Visitor.init(std.testing.allocator, 7, .{ .generate = 3, .iterate = 4 }, 0);
    defer visitor.deinit();

    try visitor.registerString("alpha");
    const value = try visitor.getString();
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualStrings("alpha", value);
}

test "generate scalar, array, slice, and struct values" {
    const Sample = struct {
        enabled: bool,
        amount: u16,
        bytes: []u8,
        fixed: [3]u8,
    };

    var visitor = try Visitor.init(std.testing.allocator, 11, .{ .generate = 3, .iterate = 4 }, 2);
    defer visitor.deinit();

    var value = try generateWithSettings(Sample, &visitor, null);
    defer deinitGenerated(Sample, std.testing.allocator, &value);

    _ = value.enabled;
    _ = value.amount;
    try std.testing.expect(value.bytes.len <= visitor.iterateDepth());
    try std.testing.expectEqual(@as(usize, 3), value.fixed.len);
}

test "generate length and range settings" {
    var visitor = try Visitor.init(std.testing.allocator, 13, .{ .generate = 2, .iterate = 8 }, 1);
    defer visitor.deinit();

    var bytes = try generateWithSettings([]u8, &visitor, .{ .length = 5 });
    defer deinitGenerated([]u8, std.testing.allocator, &bytes);
    try std.testing.expectEqual(@as(usize, 5), bytes.len);

    const small = try generateWithSettings(u8, &visitor, .{
        .range = .{ .min = 3, .max_inclusive = 7 },
    });
    try std.testing.expect(small >= 3 and small <= 7);
}

test "generate tagged unions and avoid recursive variants at depth limit" {
    const Expr = union(enum) {
        literal: u8,
        nested: ?*@This(),
    };

    var visitor = try Visitor.init(std.testing.allocator, 1, .{ .generate = 0, .iterate = 2 }, 1);
    defer visitor.deinit();

    var value = try generate(Expr, &visitor);
    defer deinitGenerated(Expr, std.testing.allocator, &value);

    try std.testing.expect(value == .literal);
}

test "serialize and deserialize struct with slice and optional fields" {
    const Sample = struct {
        enabled: bool,
        amount: u16,
        bytes: []const u8,
        maybe: ?u32,
        fixed: [3]u8,
    };

    const original = Sample{
        .enabled = true,
        .amount = 0x1234,
        .bytes = "abc",
        .maybe = 0xfeed_beef,
        .fixed = .{ 1, 2, 3 },
    };

    const encoded = try serializeAlloc(Sample, std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    var decoded = try deserializeAlloc(Sample, std.testing.allocator, encoded);
    defer deinitGenerated(Sample, std.testing.allocator, &decoded);

    try std.testing.expect(decoded.enabled);
    try std.testing.expectEqual(@as(u16, 0x1234), decoded.amount);
    try std.testing.expectEqualSlices(u8, "abc", decoded.bytes);
    try std.testing.expectEqual(@as(?u32, 0xfeed_beef), decoded.maybe);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, &decoded.fixed);
}

test "serialize and deserialize enums and tagged unions" {
    const Flavor = enum(u8) {
        vanilla = 1,
        chocolate = 7,
    };
    const Expr = union(enum) {
        literal: u16,
        flavor: Flavor,
        empty,
    };

    const encoded_enum = try serializeAlloc(Flavor, std.testing.allocator, .chocolate);
    defer std.testing.allocator.free(encoded_enum);
    const decoded_enum = try deserializeAlloc(Flavor, std.testing.allocator, encoded_enum);
    try std.testing.expectEqual(Flavor.chocolate, decoded_enum);

    const encoded_union = try serializeAlloc(Expr, std.testing.allocator, .{ .literal = 0xabcd });
    defer std.testing.allocator.free(encoded_union);
    var decoded_union = try deserializeAlloc(Expr, std.testing.allocator, encoded_union);
    defer deinitGenerated(Expr, std.testing.allocator, &decoded_union);

    try std.testing.expect(decoded_union == .literal);
    try std.testing.expectEqual(@as(u16, 0xabcd), decoded_union.literal);
}

test "maybeDeserializeAlloc rejects invalid or trailing bytes" {
    const Sample = struct {
        value: u16,
    };
    const WithSlice = struct {
        bytes: []u8,
    };

    const short = try maybeDeserializeAlloc(Sample, std.testing.allocator, &[_]u8{0x01});
    try std.testing.expect(short == null);

    const trailing = try maybeDeserializeAlloc(Sample, std.testing.allocator, &[_]u8{ 0x01, 0x00, 0xff });
    try std.testing.expect(trailing == null);

    const encoded = try serializeAlloc(WithSlice, std.testing.allocator, .{ .bytes = @constCast("abc") });
    defer std.testing.allocator.free(encoded);

    var encoded_with_trailing = try std.ArrayList(u8).initCapacity(std.testing.allocator, encoded.len + 1);
    defer encoded_with_trailing.deinit(std.testing.allocator);
    try encoded_with_trailing.appendSlice(std.testing.allocator, encoded);
    try encoded_with_trailing.append(std.testing.allocator, 0xff);

    const allocated_then_rejected = try maybeDeserializeAlloc(
        WithSlice,
        std.testing.allocator,
        encoded_with_trailing.items,
    );
    try std.testing.expect(allocated_then_rejected == null);
}

test "collectFields records struct iterable paths" {
    const Sample = struct {
        amount: u16,
        bytes: []u8,
    };

    var visitor = try Visitor.init(std.testing.allocator, 21, .{ .generate = 2, .iterate = 4 }, 0);
    defer visitor.deinit();

    var value = Sample{
        .amount = 7,
        .bytes = try std.testing.allocator.dupe(u8, "abc"),
    };
    defer deinitGenerated(Sample, std.testing.allocator, &value);

    try collectFields(Sample, &visitor, &value);
    var paths = visitor.takeFields();
    defer deinitFieldPaths(std.testing.allocator, &paths);

    try std.testing.expect(paths.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 0), paths.items[0].items[0].index);
    try std.testing.expectEqual(@as(usize, 1), paths.items[1].items[0].index);
    try std.testing.expect(paths.items[1].items[0].node_type.isIterable());
    try std.testing.expectEqual(@as(usize, 3), paths.items[1].items[0].node_type.iterable.len);
}

test "mutateAtPath splices scalar and optional fields" {
    const Sample = struct {
        amount: u16,
        maybe: ?u8,
    };

    var visitor = try Visitor.init(std.testing.allocator, 22, .{ .generate = 2, .iterate = 4 }, 0);
    defer visitor.deinit();

    var value = Sample{
        .amount = 1,
        .maybe = 2,
    };
    defer deinitGenerated(Sample, std.testing.allocator, &value);

    const amount = try serializeAlloc(u16, std.testing.allocator, 0x1234);
    defer std.testing.allocator.free(amount);
    try mutateAtPath(Sample, &visitor, &value, &[_]usize{0}, .{ .splice = amount });
    try std.testing.expectEqual(@as(u16, 0x1234), value.amount);

    const maybe = try serializeAlloc(u8, std.testing.allocator, 9);
    defer std.testing.allocator.free(maybe);
    try mutateAtPath(Sample, &visitor, &value, &[_]usize{ 1, 0 }, .{ .splice = maybe });
    try std.testing.expectEqual(@as(?u8, 9), value.maybe);
}

test "mutateAtPath appends and pops slice fields" {
    const Sample = struct {
        bytes: []u8,
    };

    var visitor = try Visitor.init(std.testing.allocator, 23, .{ .generate = 2, .iterate = 4 }, 0);
    defer visitor.deinit();

    var value = Sample{
        .bytes = try std.testing.allocator.dupe(u8, "ab"),
    };
    defer deinitGenerated(Sample, std.testing.allocator, &value);

    const item = try serializeAlloc(u8, std.testing.allocator, 'X');
    defer std.testing.allocator.free(item);
    try mutateAtPath(Sample, &visitor, &value, &[_]usize{0}, .{ .splice_append = item });
    try std.testing.expectEqualSlices(u8, "abX", value.bytes);

    try mutateAtPath(Sample, &visitor, &value, &[_]usize{0}, .{ .iterable_pop = 1 });
    try std.testing.expectEqualSlices(u8, "aX", value.bytes);
}

test "mutateAtPath splices tagged union payload" {
    const Expr = union(enum) {
        literal: u16,
        empty,
    };

    var visitor = try Visitor.init(std.testing.allocator, 24, .{ .generate = 2, .iterate = 4 }, 0);
    defer visitor.deinit();

    var value = Expr{ .literal = 1 };
    defer deinitGenerated(Expr, std.testing.allocator, &value);

    const replacement = try serializeAlloc(u16, std.testing.allocator, 0xbeef);
    defer std.testing.allocator.free(replacement);
    try mutateAtPath(Expr, &visitor, &value, &[_]usize{0}, .{ .splice = replacement });

    try std.testing.expect(value == .literal);
    try std.testing.expectEqual(@as(u16, 0xbeef), value.literal);
}

test "collectCmps records scalar match replacement bytes" {
    const Sample = struct {
        amount: u16,
        other: u16,
    };

    var visitor = try Visitor.init(std.testing.allocator, 31, .{ .generate = 2, .iterate = 4 }, 0);
    defer visitor.deinit();

    var value = Sample{
        .amount = 0x1234,
        .other = 7,
    };
    defer deinitGenerated(Sample, std.testing.allocator, &value);

    try collectCmps(Sample, &visitor, &value, .{ .left = 0x1234, .right = 0xbeef });
    var matches = visitor.takeCmps();
    defer deinitCmpMatches(std.testing.allocator, &matches);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), matches.items[0].path.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].path.items[0].index);

    const replacement = try deserializeAlloc(u16, std.testing.allocator, matches.items[0].data);
    try std.testing.expectEqual(@as(u16, 0xbeef), replacement);

    try mutateAtPath(Sample, &visitor, &value, &[_]usize{matches.items[0].path.items[0].index}, .{
        .splice = matches.items[0].data,
    });
    try std.testing.expectEqual(@as(u16, 0xbeef), value.amount);
}

test "collectCmps records nested slice element path" {
    const Sample = struct {
        bytes: []u8,
    };

    var visitor = try Visitor.init(std.testing.allocator, 32, .{ .generate = 2, .iterate = 4 }, 0);
    defer visitor.deinit();

    var value = Sample{
        .bytes = try std.testing.allocator.dupe(u8, "abc"),
    };
    defer deinitGenerated(Sample, std.testing.allocator, &value);

    try collectCmps(Sample, &visitor, &value, .{ .left = 'b', .right = 'X' });
    var matches = visitor.takeCmps();
    defer deinitCmpMatches(std.testing.allocator, &matches);

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(usize, 2), matches.items[0].path.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0].path.items[0].index);
    try std.testing.expectEqual(@as(usize, 1), matches.items[0].path.items[1].index);

    const path = [_]usize{
        matches.items[0].path.items[0].index,
        matches.items[0].path.items[1].index,
    };
    try mutateAtPath(Sample, &visitor, &value, &path, .{ .splice = matches.items[0].data });
    try std.testing.expectEqualSlices(u8, "aXc", value.bytes);
}

test "runGenerated executes typed harness for generated inputs" {
    const Sample = struct {
        amount: u8,
    };
    const Harness = struct {
        fn run(value: *const Sample) FuzzResult {
            _ = value;
            return .interesting;
        }
    };

    const stats = try runGenerated(
        Sample,
        std.testing.allocator,
        .{
            .seed = 41,
            .depth = .{ .generate = 2, .iterate = 4 },
            .string_count = 0,
            .generated_inputs = 5,
        },
        Harness.run,
    );

    try std.testing.expectEqual(@as(usize, 5), stats.generated);
    try std.testing.expectEqual(@as(usize, 0), stats.mutations);
    try std.testing.expectEqual(@as(usize, 5), stats.executions);
    try std.testing.expectEqual(@as(usize, 5), stats.interesting);
    try std.testing.expectEqual(@as(usize, 0), stats.crashes);
}

test "runMutational executes generated and mutated inputs" {
    const Sample = struct {
        amount: u8,
        bytes: []u8,
    };
    const Harness = struct {
        fn run(value: *const Sample) FuzzResult {
            if (value.bytes.len > 0 and value.amount == value.bytes[0]) {
                return .interesting;
            }
            return .ok;
        }
    };

    const stats = try runMutational(
        Sample,
        std.testing.allocator,
        .{
            .seed = 42,
            .depth = .{ .generate = 2, .iterate = 4 },
            .string_count = 0,
            .generated_inputs = 3,
            .mutations_per_input = 2,
        },
        Harness.run,
    );

    try std.testing.expectEqual(@as(usize, 3), stats.generated);
    try std.testing.expectEqual(@as(usize, 6), stats.mutations);
    try std.testing.expectEqual(@as(usize, 9), stats.executions);
}
