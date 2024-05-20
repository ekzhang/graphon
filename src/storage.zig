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
    const db = rocks.rocksdb_open(options, "~~not@a/real&file", &err);
    try std.testing.expectEqual(db, null);

    const status = parse_rocks_error(err.?);
    try std.testing.expectEqual(status, RocksError.IOError);
}

/// A handle to a RocksDB database.
pub const RocksDB = struct {
    db: *rocks.rocksdb_t,

    pub fn open(name: [:0]const u8) !RocksDB {
        const options = rocks.rocksdb_options_create() orelse return error.OutOfMemory;
        defer rocks.rocksdb_options_destroy(options);
        rocks.rocksdb_options_set_create_if_missing(options, 1);

        var err: ?[*:0]u8 = null;
        const db: ?*rocks.rocksdb_t = rocks.rocksdb_open(options, name.ptr, &err);
        if (err) |e| return parse_rocks_error(e);
        return RocksDB{ .db = db.? };
    }

    pub fn close(self: RocksDB) void {
        rocks.rocksdb_close(self.db);
    }
};
