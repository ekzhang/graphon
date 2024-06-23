//! Storage engine built on top of RocksDB. Serializes graph-structured data.

const std = @import("std");

const RocksDB = @import("storage/rocksdb.zig").RocksDB;
const RocksError = @import("storage/rocksdb.zig").RocksError;

const types = @import("types.zig");
const ElementId = types.ElementId;
const Node = types.Node;
const Edge = types.Edge;

const test_helpers = @import("test_helpers.zig");

pub const Storage = struct {
    db: RocksDB,

    /// Put a node into the storage engine.
    pub fn putNode(self: *Storage, node: Node) !void {
        var list = std.ArrayList(u8).init(std.heap.c_allocator);
        defer list.deinit();

        const writer = list.writer();
        try types.encodeLabels(node.labels, writer);
        try types.encodeProperties(node.properties, writer);

        try self.db.put(.node, &node.id.toBytes(), list.items);
    }

    /// Put an edge into the storage engine.
    pub fn putEdge(self: *Storage, edge: Edge) !void {
        var list = std.ArrayList(u8).init(std.heap.c_allocator);
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
    var tmp = test_helpers.simpleTmpDir();
    defer tmp.cleanup();

    const db = try RocksDB.open(tmp.path("test.db"));
    defer db.close();

    var storage = Storage{ .db = db };
    const n = Node{ .id = ElementId.generate() };
    const e = Edge{ .id = ElementId.generate(), .endpoints = .{ n.id, n.id }, .directed = false };
    try storage.putNode(n);
    try storage.putEdge(e);
}
