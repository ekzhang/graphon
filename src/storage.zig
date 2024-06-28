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

pub const Error = rocksdb.Error || error{
    CorruptedIndex,
    EdgeDataMismatch,
};

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

    pub fn commit(self: Transaction) !void {
        try self.inner.commit();
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

        // Note: We call get() on each node to trigger transaction conflicts.
        // This is important if a node is deleted.
        for (edge.endpoints) |id| {
            const value = try self.inner.get(.node, &id.toBytes(), false) orelse return Error.NotFound;
            value.close();
        }

        var already_exists = false;
        var old_edge_opt = try self.getEdge(edge.id);
        if (old_edge_opt) |*old_edge| {
            defer old_edge.deinit(self.allocator);
            if (old_edge.endpoints[0].value != edge.endpoints[0].value or
                old_edge.endpoints[1].value != edge.endpoints[1].value or
                old_edge.directed != edge.directed)
            {
                return Error.EdgeDataMismatch;
            }
            already_exists = true;
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
        if (!already_exists) {
            const adj = AdjEntry.fromEdge(edge);
            try self.inner.put(.adj, &adj.packIntoKey(), &edge.endpoints[1].toBytes());
            try self.inner.put(.adj, &adj.reverse().packIntoKey(), &edge.endpoints[0].toBytes());
        }
    }

    /// Remove a node from the storage engine.
    pub fn deleteNode(self: Transaction, id: ElementId) !void {
        var node = try self.getNode(id) orelse return Error.NotFound;
        defer node.deinit(self.allocator);
        try self.inner.delete(.node, &id.toBytes());

        // Update adjacency lists.
        var it = try self.iterateAdj(id, .out, .in);
        defer it.close();
        while (try it.next()) |entry| {
            try self.inner.delete(.adj, &entry.packIntoKey());
            try self.inner.delete(.adj, &entry.reverse().packIntoKey());
        }
    }

    /// Remove an edge from the storage engine.
    pub fn deleteEdge(self: Transaction, id: ElementId) !void {
        var edge = try self.getEdge(id) orelse return Error.NotFound;
        defer edge.deinit(self.allocator);
        try self.inner.delete(.edge, &id.toBytes());

        // Update adjacency lists.
        const adj = AdjEntry.fromEdge(edge);
        try self.inner.delete(.adj, &adj.packIntoKey());
        try self.inner.delete(.adj, &adj.reverse().packIntoKey());
    }

    /// Iterate over a subset of the adjacency list.
    ///
    /// This function does not access any of the node or edge data, or check
    /// that IDs exist. It will not trigger any transaction conflicts.
    pub fn iterateAdj(
        self: Transaction,
        node_id: ElementId,
        min_inout: types.EdgeInOut,
        max_inout: types.EdgeInOut,
    ) !AdjIterator {
        std.debug.assert(@intFromEnum(min_inout) <= @intFromEnum(max_inout));
        var bounds: []u8 = try self.allocator.alloc(u8, 26);
        var lower_bound = bounds[0..13];
        var upper_bound = bounds[13..26];
        lower_bound[0..12].* = node_id.toBytes();
        lower_bound[12] = @intFromEnum(min_inout);
        upper_bound[0..12].* = node_id.toBytes();
        upper_bound[12] = @intFromEnum(max_inout) + 1;
        return .{
            .inner = self.inner.iterate(.adj, lower_bound, upper_bound),
            .bounds = bounds,
            .allocator = self.allocator,
        };
    }
};

/// An entry returned by scanning the adjacency list of a node.
pub const AdjEntry = struct {
    src_node_id: ElementId,
    inout: types.EdgeInOut,
    edge_id: ElementId,
    dest_node_id: ElementId,

    pub fn fromEdge(edge: Edge) AdjEntry {
        return .{
            .src_node_id = edge.endpoints[0],
            .inout = if (edge.directed) .out else .simple,
            .edge_id = edge.id,
            .dest_node_id = edge.endpoints[1],
        };
    }

    pub fn reverse(self: AdjEntry) AdjEntry {
        return .{
            .src_node_id = self.dest_node_id,
            .inout = switch (self.inout) {
                .in => .out,
                .out => .in,
                .simple => .simple,
            },
            .edge_id = self.edge_id,
            .dest_node_id = self.src_node_id,
        };
    }

    pub fn packIntoKey(self: AdjEntry) [25]u8 {
        var key: [25]u8 = undefined;
        key[0..12].* = self.src_node_id.toBytes();
        key[12] = @intFromEnum(self.inout);
        key[13..25].* = self.edge_id.toBytes();
        return key;
    }

    pub fn unpackFromKeyValue(key: []const u8, value: []const u8) !AdjEntry {
        if (key.len != 25 or value.len != 12) {
            return Error.CorruptedIndex;
        }
        return .{
            .src_node_id = ElementId.fromBytes(key[0..12].*),
            .inout = std.meta.intToEnum(types.EdgeInOut, key[12]) catch return Error.CorruptedIndex,
            .edge_id = ElementId.fromBytes(key[13..25].*),
            .dest_node_id = ElementId.fromBytes(value[0..12].*),
        };
    }
};

/// Iterator through the adjacency list of a node.
pub const AdjIterator = struct {
    inner: rocksdb.Iterator,
    bounds: []u8,
    allocator: Allocator,

    pub fn close(self: AdjIterator) void {
        self.inner.close();
        self.allocator.free(self.bounds);
    }

    pub fn next(self: *AdjIterator) !?AdjEntry {
        if (!self.inner.valid()) {
            return null;
        }
        const key = self.inner.key();
        const value = self.inner.value();
        const result = try AdjEntry.unpackFromKeyValue(key, value);
        self.inner.next();
        return result;
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

    var n2 = try txn.getNode(n.id) orelse @panic("n not found");
    defer n2.deinit(txn.allocator);
    var e2 = try txn.getEdge(e.id) orelse @panic("e not found");
    defer e2.deinit(txn.allocator);

    try std.testing.expectEqual(n.id, n2.id);
    try std.testing.expectEqual(e.id, e2.id);
    try std.testing.expectEqual(e.endpoints, e2.endpoints);

    try txn.deleteNode(n.id);
    try txn.deleteEdge(e.id);
    try std.testing.expectEqual(null, try txn.getNode(n.id));
    try std.testing.expectEqual(null, try txn.getEdge(e.id));
}

test "iterate adjacency" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();
    const db = try rocksdb.DB.open(tmp.path("test.db"));
    defer db.close();

    const storage = Storage{ .db = db };

    const n1 = Node{ .id = ElementId.generate() };
    const n2 = Node{ .id = ElementId.generate() };
    const n3 = Node{ .id = ElementId.generate() };
    const e1 = Edge{ .id = ElementId.generate(), .endpoints = .{ n1.id, n2.id }, .directed = false };
    const e2 = Edge{ .id = ElementId.generate(), .endpoints = .{ n2.id, n3.id }, .directed = false };

    {
        const txn = storage.txn();
        defer txn.close();

        try txn.putNode(n1);
        try txn.putNode(n2);
        try txn.putNode(n3);
        try txn.putEdge(e1);
        try txn.putEdge(e2);
        try txn.commit();
    }

    const txn = storage.txn();
    defer txn.close();

    {
        var it = try txn.iterateAdj(n1.id, .simple, .simple);
        defer it.close();
        const entry = (try it.next()).?;
        try std.testing.expectEqual(n1.id, entry.src_node_id);
        try std.testing.expectEqual(n2.id, entry.dest_node_id);
        try std.testing.expectEqual(e1.id, entry.edge_id);
        try std.testing.expectEqual(null, try it.next());
    }

    {
        var it = try txn.iterateAdj(n2.id, .simple, .simple);
        defer it.close();
        try std.testing.expect(try it.next() != null);
        try std.testing.expect(try it.next() != null);
        try std.testing.expectEqual(null, try it.next());
    }

    {
        var it = try txn.iterateAdj(n2.id, .out, .out);
        defer it.close();
        try std.testing.expectEqual(null, try it.next());
    }

    // Open a second transaction to delete n2, ensure no interference.
    {
        const txn2 = storage.txn();
        defer txn2.close();
        try txn2.deleteNode(n2.id);
        try txn2.commit();
    }

    var n2_fetch = try txn.getNode(n2.id) orelse @panic("n2 not found");
    n2_fetch.deinit(txn.allocator);
    {
        var it = try txn.iterateAdj(n1.id, .simple, .simple);
        defer it.close();
        try std.testing.expect(try it.next() != null);
        try std.testing.expectEqual(null, try it.next());
    }

    try std.testing.expectEqual(Error.Busy, txn.commit());
}
