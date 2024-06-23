//! Storage engine built on top of RocksDB. Serializes graph-structured data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const RocksDB = @import("storage/rocksdb.zig").RocksDB;
const RocksError = @import("storage/rocksdb.zig").RocksError;

const types = @import("types.zig");
const ElementId = types.ElementId;
const Node = types.Node;
const Edge = types.Edge;

const test_helpers = @import("test_helpers.zig");

pub const Storage = struct {
    db: RocksDB,
    allocator: Allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator,

    /// Get a node from the storage engine. Returns `null` if not found.
    pub fn getNode(self: *Storage, id: ElementId) !?Node {
        const value = try self.db.get(.node, &id.toBytes()) orelse return null;
        defer value.close();
        var stream = std.io.fixedBufferStream(value.bytes());
        const reader = stream.reader();

        var labels = try types.decodeLabels(self.allocator, reader);
        errdefer labels.deinit(self.allocator);
        var properties = try types.decodeProperties(self.allocator, reader);
        errdefer properties.deinit(self.allocator);

        return Node{ .id = id, .labels = labels, .properties = properties };
    }

    /// Get an edge from the storage engine. Returns `null` if not found.
    pub fn getEdge(self: *Storage, id: ElementId) !?Edge {
        const value = try self.db.get(.edge, &id.toBytes()) orelse return null;
        defer value.close();
        var stream = std.io.fixedBufferStream(value.bytes());
        const reader = stream.reader();

        const endpoints = [2]ElementId{ try ElementId.decode(reader), try ElementId.decode(reader) };
        const directed = try reader.readByte() == 1;
        var labels = try types.decodeLabels(self.allocator, reader);
        errdefer labels.deinit(self.allocator);
        var properties = try types.decodeProperties(self.allocator, reader);
        errdefer properties.deinit(self.allocator);

        return Edge{
            .id = id,
            .endpoints = endpoints,
            .directed = directed,
            .labels = labels,
            .properties = properties,
        };
    }

    /// Put a node into the storage engine.
    pub fn putNode(self: *Storage, node: Node) !void {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();

        const writer = list.writer();
        try types.encodeLabels(node.labels, writer);
        try types.encodeProperties(node.properties, writer);

        try self.db.put(.node, &node.id.toBytes(), list.items);
    }

    /// Put an edge into the storage engine.
    pub fn putEdge(self: *Storage, edge: Edge) !void {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();

        const writer = list.writer();
        try edge.endpoints[0].encode(writer);
        try edge.endpoints[1].encode(writer);
        try writer.writeByte(@intCast(@intFromBool(edge.directed)));
        try types.encodeLabels(edge.labels, writer);
        try types.encodeProperties(edge.properties, writer);

        try self.db.put(.edge, &edge.id.toBytes(), list.items);
    }
};

test "put node and edge" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();
    const db = try RocksDB.open(tmp.path("test.db"));
    defer db.close();

    var storage = Storage{ .db = db };
    const n = Node{ .id = ElementId.generate() };
    const e = Edge{ .id = ElementId.generate(), .endpoints = .{ n.id, n.id }, .directed = false };
    try storage.putNode(n);
    try storage.putEdge(e);

    const n2 = try storage.getNode(n.id) orelse @panic("n not found");
    const e2 = try storage.getEdge(e.id) orelse @panic("e not found");

    try std.testing.expectEqual(n.id, n2.id);
    try std.testing.expectEqual(e.id, e2.id);
    try std.testing.expectEqual(e.endpoints, e2.endpoints);
}
