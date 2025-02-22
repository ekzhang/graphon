//! Definition of common types used in modeling property graphs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const random = std.crypto.random;

/// Unique element ID for a node or edge. Element IDs are random 96-bit integers.
pub const ElementId = struct {
    value: u96,

    /// Generates a new random element ID.
    pub fn generate() ElementId {
        return ElementId{ .value = random.int(u96) };
    }

    /// Return this element ID as a big-endian byte array.
    pub fn toBytes(self: ElementId) [12]u8 {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u96, &buf, self.value, .big);
        return buf;
    }

    /// Create an element ID from a big-endian byte array.
    pub fn fromBytes(bytes: [12]u8) ElementId {
        return .{ .value = std.mem.readInt(u96, &bytes, .big) };
    }

    /// Return an element ID as a base64 string.
    pub fn toString(self: ElementId) [16]u8 {
        var buf: [16]u8 = undefined;
        var x = self.value;
        var i = buf.len;
        while (i > 0) {
            i -= 1;
            const c = x & 0x3f;
            buf[i] = switch (c) {
                0...25 => 'A' + @as(u8, @intCast(c)),
                26...51 => 'a' + @as(u8, @intCast(c - 26)),
                52...61 => '0' + @as(u8, @intCast(c - 52)),
                62 => '-',
                63 => '_',
                else => unreachable,
            };
            x >>= 6;
        }
        return buf;
    }

    pub fn encode(self: ElementId, writer: anytype) !void {
        try writer.writeAll(&self.toBytes());
    }

    pub fn decode(reader: anytype) !ElementId {
        var buf: [12]u8 = undefined;
        try reader.readNoEof(&buf);
        return ElementId.fromBytes(buf);
    }

    pub fn next(self: ElementId) ElementId {
        return ElementId{ .value = self.value + 1 };
    }
};

test ElementId {
    const id = ElementId{ .value = 238093323431135580 };
    try std.testing.expectEqualStrings(&id.toString(), "AAAAAANN4J2-gUlc");
    try std.testing.expect(ElementId.generate().value != ElementId.generate().value);
}

/// Edge direction as expressed in a path pattern.
pub const EdgeDirection = enum {
    left, // <-[]-
    right, // -[]->
    undirected, // ~[]~
    left_or_undirected, // <~[]~
    right_or_undirected, // ~[]~>
    left_or_right, // <-[]->
    any, // -[]-

    /// Returns the left part of the edge direction as a string.
    pub fn leftPart(self: EdgeDirection) [:0]const u8 {
        return switch (self) {
            .left => "<-[",
            .right => "-[",
            .undirected => "~[",
            .left_or_undirected => "<~[",
            .right_or_undirected => "~[",
            .left_or_right => "<-[",
            .any => "-[",
        };
    }

    /// Returns the right part of the edge direction as a string.
    pub fn rightPart(self: EdgeDirection) [:0]const u8 {
        return switch (self) {
            .left => "]-",
            .right => "]->",
            .undirected => "]~",
            .left_or_undirected => "]~",
            .right_or_undirected => "]~>",
            .left_or_right => "]->",
            .any => "]-",
        };
    }
};

/// Whether an edge is going in or out of a node. Stored in adjacency lists.
pub const EdgeInOut = enum(u8) {
    /// A directed edge pointing out from a node.
    out = 0,
    /// An undirected edge.
    simple = 1,
    /// A directed edge pointing into a node.
    in = 2,
};

/// The dynamically-typed kind of a value.
pub const ValueKind = enum(u8) {
    string = 1,
    // bytes
    int64 = 2,
    // [various integers]
    float64 = 3,
    // [various floating-points]
    // date, datetime, duration
    node_ref = 4,
    edge_ref = 5,
    id = 6,
    bool = 7,
    null = 8,
};

/// Encode a length-delimited byte buffer.
pub fn encodeBytes(bytes: []const u8, writer: anytype) !void {
    try writer.writeInt(u32, @intCast(bytes.len), .big);
    try writer.writeAll(bytes);
}

/// Decode a length-delimited byte buffer.
pub fn decodeBytes(allocator: Allocator, reader: anytype) ![]const u8 {
    const len: usize = @intCast(try reader.readInt(u32, .big));
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try reader.readNoEof(buf);
    return buf;
}

pub fn encodeLabels(labels: std.StringArrayHashMapUnmanaged(void), writer: anytype) !void {
    try writer.writeInt(u32, @intCast(labels.count()), .big);
    for (labels.keys()) |label| {
        try encodeBytes(label, writer);
    }
}

pub fn decodeLabels(allocator: Allocator, reader: anytype) !std.StringArrayHashMapUnmanaged(void) {
    const len: usize = @intCast(try reader.readInt(u32, .big));
    var labels: std.StringArrayHashMapUnmanaged(void) = .{};
    errdefer freeLabels(allocator, &labels);
    for (0..len) |_| {
        const label = try decodeBytes(allocator, reader);
        try labels.put(allocator, label, void{});
    }
    return labels;
}

pub fn freeLabels(allocator: Allocator, labels: *std.StringArrayHashMapUnmanaged(void)) void {
    for (labels.keys()) |label| {
        allocator.free(label);
    }
    labels.deinit(allocator);
}

pub fn encodeProperties(properties: std.StringArrayHashMapUnmanaged(Value), writer: anytype) !void {
    try writer.writeInt(u32, @intCast(properties.count()), .big);
    var it = properties.iterator();
    while (it.next()) |entry| {
        try encodeBytes(entry.key_ptr.*, writer);
        try entry.value_ptr.encode(writer);
    }
}

pub fn decodeProperties(allocator: Allocator, reader: anytype) !std.StringArrayHashMapUnmanaged(Value) {
    const len: usize = @intCast(try reader.readInt(u32, .big));
    var properties: std.StringArrayHashMapUnmanaged(Value) = .{};
    errdefer freeProperties(allocator, &properties);
    for (0..len) |_| {
        const key = try decodeBytes(allocator, reader);
        errdefer allocator.free(key);
        var value = try Value.decode(allocator, reader);
        errdefer value.deinit(allocator);
        try properties.put(allocator, key, value);
    }
    return properties;
}

pub fn freeProperties(allocator: Allocator, properties: *std.StringArrayHashMapUnmanaged(Value)) void {
    for (properties.values()) |*value| {
        value.deinit(allocator);
    }
    for (properties.keys()) |key| {
        allocator.free(key);
    }
    properties.deinit(allocator);
}

/// The main value type for graph properties and binding tables elements.
///
/// This is a full list of data types supported by Graphon and supported by the
/// expression language. Values can be assigned to properties or constructed
/// during execution of a query.
///
/// Reference: ISO/IEC 39075:2024, Section 18.9.
pub const Value = union(ValueKind) {
    string: []const u8, // Binary-safe string.
    int64: i64,
    float64: f64,
    node_ref: ElementId, // Reference to a node (must exist).
    edge_ref: ElementId, // Reference to an edge (must exist).
    id: ElementId, // Not necessarily populated by node or edge.
    bool: bool,
    null,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
        self.* = undefined;
    }

    /// Duplicate a value, using the provided allocator.
    pub fn dupe(self: Value, allocator: Allocator) !Value {
        return switch (self) {
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            else => self,
        };
    }

    /// Pretty-print a value to a writer.
    pub fn print(self: Value, writer: anytype) !void {
        switch (self) {
            .string => |s| try writer.print("'{s}'", .{s}),
            .int64 => |n| try writer.print("{}", .{n}),
            .float64 => |f| try writer.print("{}", .{f}),
            .node_ref => |id| try writer.print("{s}", .{id.toString()}),
            .edge_ref => |id| try writer.print("{s}", .{id.toString()}),
            .id => |id| try writer.print("{s}", .{id.toString()}),
            .bool => |b| try writer.print("{s}", .{if (b) "true" else "false"}),
            .null => try writer.print("null", .{}),
        }
    }

    /// Encode this value to a binary format for storage or transmission.
    ///
    /// On failure due to out-of-memory, this function may leave the provided
    /// buffer in an invalid or partially-written state.
    pub fn encode(self: Value, writer: anytype) Allocator.Error!void {
        const tag: u8 = @intFromEnum(self);
        try writer.writeByte(tag);
        switch (self) {
            .string => |s| try encodeBytes(s, writer),
            .int64 => |n| try writer.writeInt(i64, n, .big),
            .float64 => |f| try writer.writeInt(u64, @bitCast(f), .big),
            .node_ref => |id| try id.encode(writer),
            .edge_ref => |id| try id.encode(writer),
            .id => |id| try id.encode(writer),
            .bool => |b| try writer.writeByte(if (b) 1 else 0),
            .null => {},
        }
    }

    /// Decode a value encoded by `Value.encode()`.
    pub fn decode(allocator: Allocator, reader: anytype) !Value {
        const tag_int = try reader.readByte();
        const tag = std.meta.intToEnum(ValueKind, tag_int) catch {
            return error.InvalidValueTag;
        };
        switch (tag) {
            .string => {
                const s = try decodeBytes(allocator, reader);
                return .{ .string = s };
            },
            .int64 => {
                const n = try reader.readInt(i64, .big);
                return .{ .int64 = n };
            },
            .float64 => {
                const bits = try reader.readInt(u64, .big);
                return .{ .float64 = @bitCast(bits) };
            },
            .node_ref => {
                const id = try ElementId.decode(reader);
                return .{ .node_ref = id };
            },
            .edge_ref => {
                const id = try ElementId.decode(reader);
                return .{ .edge_ref = id };
            },
            .id => {
                const id = try ElementId.decode(reader);
                return .{ .id = id };
            },
            .bool => {
                const b = try reader.readByte();
                return .{ .bool = b != 0 };
            },
            .null => return .null,
        }
    }

    /// Add two values together, allocating a result.
    pub fn add(a: Value, b: Value, allocator: Allocator) Allocator.Error!Value {
        return switch (a) {
            .string => |a_| switch (b) {
                .string => |b_| {
                    const len = a_.len + b_.len;
                    const buf = try allocator.alloc(u8, len);
                    std.mem.copyForwards(u8, buf, a_);
                    std.mem.copyForwards(u8, buf[a_.len..], b_);
                    return .{ .string = buf };
                },
                else => .null,
            },
            .int64 => |a_| switch (b) {
                .int64 => |b_| .{ .int64 = a_ + b_ },
                .float64 => |b_| .{ .float64 = @as(f64, @floatFromInt(a_)) + b_ },
                else => .null,
            },
            .float64 => |a_| switch (b) {
                .int64 => |b_| .{ .float64 = a_ + @as(f64, @floatFromInt(b_)) },
                .float64 => |b_| .{ .float64 = a_ + b_ },
                else => .null,
            },
            else => .null,
        };
    }

    /// Subtract two values.
    pub fn sub(a: Value, b: Value) Value {
        return switch (a) {
            .int64 => |a_| switch (b) {
                .int64 => |b_| .{ .int64 = a_ - b_ },
                .float64 => |b_| .{ .float64 = @as(f64, @floatFromInt(a_)) - b_ },
                else => .null,
            },
            .float64 => |a_| switch (b) {
                .int64 => |b_| .{ .float64 = a_ - @as(f64, @floatFromInt(b_)) },
                .float64 => |b_| .{ .float64 = a_ - b_ },
                else => .null,
            },
            else => .null,
        };
    }

    /// Check if two values are equal.
    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .string => |a_| switch (b) {
                .string => |b_| std.mem.eql(u8, a_, b_),
                else => false,
            },
            .int64 => |a_| switch (b) {
                .int64 => |b_| a_ == b_,
                .float64 => |b_| @as(f64, @floatFromInt(a_)) == b_,
                else => false,
            },
            .float64 => |a_| switch (b) {
                .int64 => |b_| a_ == @as(f64, @floatFromInt(b_)),
                .float64 => |b_| a_ == b_,
                else => false,
            },
            .node_ref => |a_| switch (b) {
                .node_ref => |b_| a_.value == b_.value,
                else => false,
            },
            .edge_ref => |a_| switch (b) {
                .edge_ref => |b_| a_.value == b_.value,
                else => false,
            },
            .id => |a_| switch (b) {
                .id => |b_| a_.value == b_.value,
                else => false,
            },
            .bool => |a_| switch (b) {
                .bool => |b_| a_ == b_,
                else => false,
            },
            .null => b == .null,
        };
    }

    /// Returns whether a value is truthy.
    ///
    /// All values are generally truthy, except for the following values: false,
    /// 0, -0, "", null, and NaN.
    pub fn truthy(self: Value) bool {
        return switch (self) {
            .string => |s| s.len > 0,
            .int64 => |n| n != 0,
            .float64 => |f| f != 0 and !std.math.isNan(f),
            .node_ref, .edge_ref, .id => true,
            .bool => |b| b,
            .null => false,
        };
    }
};

/// A property graph node.
///
/// Reference: ISO/IEC 39075:2024, Section 4.3.5.1.
pub const Node = struct {
    id: ElementId,
    labels: std.StringArrayHashMapUnmanaged(void) = .{},
    properties: std.StringArrayHashMapUnmanaged(Value) = .{},

    pub fn deinit(self: *Node, allocator: Allocator) void {
        freeLabels(allocator, &self.labels);
        freeProperties(allocator, &self.properties);
        self.* = undefined;
    }
};

/// A property graph edge.
///
/// Reference: ISO/IEC 39075:2024, Section 4.3.5.1.
pub const Edge = struct {
    id: ElementId,
    endpoints: [2]ElementId,
    directed: bool,
    labels: std.StringArrayHashMapUnmanaged(void) = .{},
    properties: std.StringArrayHashMapUnmanaged(Value) = .{},

    pub fn deinit(self: *Edge, allocator: Allocator) void {
        freeLabels(allocator, &self.labels);
        freeProperties(allocator, &self.properties);
        self.* = undefined;
    }
};
