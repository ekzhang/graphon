//! Storage engine built on top of RocksDB. Serializes graph-structured data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const rocksdb = @import("storage/rocksdb.zig");

const types = @import("types.zig");
const ElementId = types.ElementId;
const Node = types.Node;
const Edge = types.Edge;

const test_helpers = @import("test_helpers.zig");

/// This is the main storage engine type.
///
/// Based on a RocksDB backend, this object stores nodes and edges. It is also
/// able to index into the graph data to provide fast lookups, and it is
/// responsible for maintaining consistent indices.
pub const Storage = struct {
    db: rocksdb.DB,
    allocator: Allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator,

    pub fn txn(self: Storage) Transaction {
        return .{ .inner = self.db.begin(), .allocator = self.allocator };
    }
};

/// An isolated transaction inside the storage engine.
///
/// This uses RocksDB transactions to implement snapshot isolation using
/// optimistic concurrency control.
pub const Transaction = struct {
    inner: rocksdb.Transaction,
    allocator: Allocator,

    /// Close the inner transaction object.
    pub fn close(self: Transaction) void {
        self.inner.close();
    }

    /// Get a node from the storage engine. Returns `null` if not found.
    pub fn getNode(self: Transaction, id: ElementId) !?Node {
        const value = try self.inner.get(.node, &id.toBytes(), false) orelse return null;
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
    pub fn getEdge(self: Transaction, id: ElementId) !?Edge {
        const value = try self.inner.get(.edge, &id.toBytes(), false) orelse return null;
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
    pub fn putNode(self: Transaction, node: Node) !void {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();

        const writer = list.writer();
        try types.encodeLabels(node.labels, writer);
        try types.encodeProperties(node.properties, writer);
        try self.inner.put(.node, &node.id.toBytes(), list.items);
    }

    /// Put an edge into the storage engine.
    pub fn putEdge(self: Transaction, edge: Edge) !void {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();

        // Note: Call get() on each node to avoid concurrency issues.
        for (edge.endpoints) |id| {
            const value = try self.inner.get(.node, &id.toBytes(), true) orelse return error.NotFound;
            value.close();
        }

        // Add the actual edge into the database.
        const writer = list.writer();
        try edge.endpoints[0].encode(writer);
        try edge.endpoints[1].encode(writer);
        try writer.writeByte(@intFromBool(edge.directed));
        try types.encodeLabels(edge.labels, writer);
        try types.encodeProperties(edge.properties, writer);
        try self.inner.put(.edge, &edge.id.toBytes(), list.items);

        // Update adjacency lists for the two endpoints.
        unreachable; // TODO
    }

    // Remove a node from the storage engine.
    pub fn deleteNode(self: Transaction, id: ElementId) !void {
        var node = try self.getNode(id) orelse return error.NotFound;
        defer node.deinit(self.allocator);
        try self.inner.delete(.node, &id.toBytes());

        // Update adjacency lists.
        unreachable; // TODO
    }

    // Remove an edge from the storage engine.
    pub fn deleteEdge(self: Transaction, id: ElementId) !void {
        var edge = try self.getEdge(id) orelse return error.NotFound;
        defer edge.deinit(self.allocator);
        try self.inner.delete(.edge, &id.toBytes());

        // Update adjacency lists.
        unreachable; // TODO
    }
};

test "put node and edge" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();
    const db = try rocksdb.DB.open(tmp.path("test.db"));
    defer db.close();

    const storage = Storage{ .db = db };
    const txn = storage.txn();
    defer txn.close();

    const n = Node{ .id = ElementId.generate() };
    const e = Edge{ .id = ElementId.generate(), .endpoints = .{ n.id, n.id }, .directed = false };

    try txn.putNode(n);
    try txn.putEdge(e);

    const n2 = try txn.getNode(n.id) orelse @panic("n not found");
    const e2 = try txn.getEdge(e.id) orelse @panic("e not found");

    try std.testing.expectEqual(n.id, n2.id);
    try std.testing.expectEqual(e.id, e2.id);
    try std.testing.expectEqual(e.endpoints, e2.endpoints);

    try txn.deleteNode(n.id);
    try txn.deleteEdge(e.id);
    try std.testing.expectEqual(null, try txn.getNode(n.id));
    try std.testing.expectEqual(null, try txn.getEdge(e.id));
}
