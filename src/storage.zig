//! Storage engine built on top of RocksDB. Serializes graph-structured data.

const std = @import("std");

const RocksDB = @import("./storage/rocksdb.zig").RocksDB;
const RocksError = @import("./storage/rocksdb.zig").RocksError;

pub const Storage = struct {
    db: RocksDB,
};

pub fn insert_node(self: *Storage, node_id: u64, node_data: []const u8) !void {
    try self.db.put(node_id, node_data);
}

comptime {
    // Temporary until we write some tests
    _ = Storage;
}
