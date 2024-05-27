//! Friendly Zig wrapper types for RocksDB's C API.

const std = @import("std");
const rocks = @cImport(@cInclude("rocksdb/c.h"));

/// Type for known errors from RocksDB.
/// Based on the [`Code`](https://github.com/facebook/rocksdb/blob/v9.1.1/include/rocksdb/status.h#L75-L93) enum.
///
/// In addition to errors returned as a string from API methods, we also can can get error codes
/// from other places like functions returning null pointers.
pub const RocksError = error{
    NotFound,
    Corruption,
    NotSupported,
    InvalidArgument,
    IOError,
    MergeInProgress,
    Incomplete,
    ShutdownInProgress,
    TimedOut,
    Aborted,
    Busy,
    Expired,
    TryAgain,
    CompactionTooLarge,
    ColumnFamilyDropped,
    UnknownStatus,
    OutOfMemory,
};

const log = std.log.scoped(.rocksdb);

fn slice_starts_with(slice: []const u8, prefix: []const u8) bool {
    if (slice.len < prefix.len) return false;
    return std.mem.eql(u8, slice[0..prefix.len], prefix);
}

test "slice_starts_with" {
    const slice = "hello, world!";
    try std.testing.expect(slice_starts_with(slice, "hello"));
    try std.testing.expect(!slice_starts_with(slice, "world"));
}

/// Parse a RocksDB error string into a status, logging it. Consumes the string.
fn parse_rocks_error(err: [*:0]u8) RocksError {
    defer rocks.rocksdb_free(err); // free the memory when done
    log.info("{s}", .{err});

    const slice = std.mem.span(err);
    if (slice_starts_with(slice, "NotFound: ")) return RocksError.NotFound;
    if (slice_starts_with(slice, "Corruption: ")) return RocksError.Corruption;
    if (slice_starts_with(slice, "Not implemented: ")) return RocksError.NotSupported;
    if (slice_starts_with(slice, "Invalid argument: ")) return RocksError.InvalidArgument;
    if (slice_starts_with(slice, "IO error: ")) return RocksError.IOError;
    if (slice_starts_with(slice, "Merge in progress: ")) return RocksError.MergeInProgress;
    if (slice_starts_with(slice, "Result incomplete: ")) return RocksError.Incomplete;
    if (slice_starts_with(slice, "Shutdown in progress: ")) return RocksError.ShutdownInProgress;
    if (slice_starts_with(slice, "Operation timed out: ")) return RocksError.TimedOut;
    if (slice_starts_with(slice, "Operation aborted: ")) return RocksError.Aborted;
    if (slice_starts_with(slice, "Resource busy: ")) return RocksError.Busy;
    if (slice_starts_with(slice, "Operation expired: ")) return RocksError.Expired;
    if (slice_starts_with(slice, "Operation failed. Try again.: ")) return RocksError.TryAgain;
    if (slice_starts_with(slice, "Compaction too large: ")) return RocksError.CompactionTooLarge;
    if (slice_starts_with(slice, "Column family dropped: ")) return RocksError.ColumnFamilyDropped;

    return RocksError.UnknownStatus;
}

test "parse error from rocksdb_open" {
    const options = rocks.rocksdb_options_create() orelse return error.OutOfMemory;
    defer rocks.rocksdb_options_destroy(options);

    var err: ?[*:0]u8 = null;
    const db = rocks.rocksdb_open(options, "<~~not@a/valid&file>", &err);
    try std.testing.expectEqual(null, db);

    const status = parse_rocks_error(err.?);
    try std.testing.expectEqual(RocksError.IOError, status);
}

/// A handle to a RocksDB database.
pub const RocksDB = struct {
    db: *rocks.rocksdb_t,
    write_opts: *rocks.rocksdb_writeoptions_t,
    read_opts: *rocks.rocksdb_readoptions_t,

    pub fn open(name: [:0]const u8) !RocksDB {
        const options = rocks.rocksdb_options_create() orelse return error.OutOfMemory;
        defer rocks.rocksdb_options_destroy(options);
        rocks.rocksdb_options_set_create_if_missing(options, 1);
        rocks.rocksdb_options_set_compression(options, rocks.rocksdb_lz4_compression);
        rocks.rocksdb_options_set_bottommost_compression(options, rocks.rocksdb_zstd_compression);

        // pre-create options to avoid repeated allocations
        const write_opts = rocks.rocksdb_writeoptions_create() orelse return error.OutOfMemory;
        rocks.rocksdb_writeoptions_disable_WAL(write_opts, 1);
        errdefer rocks.rocksdb_writeoptions_destroy(write_opts);

        const read_opts = rocks.rocksdb_readoptions_create() orelse return error.OutOfMemory;
        rocks.rocksdb_readoptions_set_async_io(read_opts, 1);
        errdefer rocks.rocksdb_readoptions_destroy(read_opts);

        var err: ?[*:0]u8 = null;
        const db: ?*rocks.rocksdb_t = rocks.rocksdb_open(options, name.ptr, &err);
        if (err) |e| return parse_rocks_error(e);
        return RocksDB{ .db = db.?, .write_opts = write_opts, .read_opts = read_opts };
    }

    pub fn close(self: RocksDB) void {
        rocks.rocksdb_close(self.db);
        rocks.rocksdb_writeoptions_destroy(self.write_opts);
        rocks.rocksdb_readoptions_destroy(self.read_opts);
    }

    pub fn put(self: RocksDB, key: []const u8, value: []const u8) !void {
        var err: ?[*:0]u8 = null;
        rocks.rocksdb_put(self.db, self.write_opts, key.ptr, key.len, value.ptr, value.len, &err);
        if (err) |e| return parse_rocks_error(e);
    }

    pub fn get(self: RocksDB, key: []const u8) !?[]const u8 {
        var err: ?[*:0]u8 = null;
        var vallen: usize = 0;
        const value = rocks.rocksdb_get(self.db, self.read_opts, key.ptr, key.len, &vallen, &err);
        if (err) |e| return parse_rocks_error(e);
        if (vallen == 0) return null;
        return value[0..vallen];
    }

    pub fn delete(self: RocksDB, key: []const u8) !void {
        var err: ?[*:0]u8 = null;
        rocks.rocksdb_delete(self.db, self.write_opts, key.ptr, key.len, &err);
        if (err) |e| return parse_rocks_error(e);
    }

    pub fn free_value(_: RocksDB, value: ?[]const u8) void {
        rocks.rocksdb_free(@ptrCast(@constCast(value)));
    }
};

test "get and put value" {
    var tmp = std.testing.tmpDir(.{});
    try tmp.dir.setAsCwd();
    defer tmp.cleanup();

    const db = try RocksDB.open("test.db"); // opened in tmpDir
    defer db.close();

    try std.testing.expectEqual(null, try db.get("hello"));

    try db.put("hello", "world");
    const value = try db.get("hello");
    try std.testing.expectEqualSlices(u8, "world", value.?);
    db.free_value(value);

    try db.delete("hello");
    try std.testing.expectEqual(null, try db.get("hello"));
}
