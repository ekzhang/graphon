//! Storage engine built on top of RocksDB. Serializes graph-structured data.

const std = @import("std");

const RocksDB = @import("./storage/rocksdb.zig").RocksDB;
const RocksError = @import("./storage/rocksdb.zig").RocksError;

pub const Storage = struct {
    db: RocksDB,
};
