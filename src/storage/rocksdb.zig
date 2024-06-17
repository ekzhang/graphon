//! Friendly Zig wrapper types for RocksDB's C API.

const std = @import("std");
const c = @cImport(@cInclude("rocksdb/c.h"));

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

inline fn slice_starts_with(slice: []const u8, prefix: []const u8) bool {
    if (slice.len < prefix.len) return false;
    return std.mem.eql(u8, slice[0..prefix.len], prefix);
}

test "slice_starts_with" {
    const slice = "hello, world!";
    try std.testing.expect(slice_starts_with(slice, ""));
    try std.testing.expect(slice_starts_with(slice, "hello"));
    try std.testing.expect(!slice_starts_with(slice, "world"));
}

/// Parse a RocksDB error string into a status, logging it. Consumes the string.
fn parse_rocks_error(err: [*:0]u8) RocksError {
    defer c.rocksdb_free(err); // free the memory when done
    log.info("{s}", .{err});

    const slice = std.mem.span(err);
    if (slice.len == 0) return RocksError.UnknownStatus;
    switch (slice[0]) {
        'C' => {
            if (slice_starts_with(slice, "Corruption: ")) return RocksError.Corruption;
            if (slice_starts_with(slice, "Compaction too large: ")) return RocksError.CompactionTooLarge;
            if (slice_starts_with(slice, "Column family dropped: ")) return RocksError.ColumnFamilyDropped;
        },
        'I' => {
            if (slice_starts_with(slice, "Invalid argument: ")) return RocksError.InvalidArgument;
            if (slice_starts_with(slice, "IO error: ")) return RocksError.IOError;
        },
        'M' => {
            if (slice_starts_with(slice, "Merge in progress: ")) return RocksError.MergeInProgress;
        },
        'N' => {
            if (slice_starts_with(slice, "NotFound: ")) return RocksError.NotFound;
            if (slice_starts_with(slice, "Not implemented: ")) return RocksError.NotSupported;
        },
        'O' => {
            if (slice_starts_with(slice, "Operation timed out: ")) return RocksError.TimedOut;
            if (slice_starts_with(slice, "Operation aborted: ")) return RocksError.Aborted;
            if (slice_starts_with(slice, "Operation expired: ")) return RocksError.Expired;
            if (slice_starts_with(slice, "Operation failed. Try again.: ")) return RocksError.TryAgain;
        },
        'R' => {
            if (slice_starts_with(slice, "Result incomplete: ")) return RocksError.Incomplete;
            if (slice_starts_with(slice, "Resource busy: ")) return RocksError.Busy;
        },
        'S' => {
            if (slice_starts_with(slice, "Shutdown in progress: ")) return RocksError.ShutdownInProgress;
        },
        else => {},
    }
    return RocksError.UnknownStatus;
}

test "parse error from rocksdb_open" {
    const options = c.rocksdb_options_create() orelse return error.OutOfMemory;
    defer c.rocksdb_options_destroy(options);

    var err: ?[*:0]u8 = null;
    const db = c.rocksdb_open(options, "<~~not@a/valid&file>", &err);
    try std.testing.expectEqual(null, db);

    const status = parse_rocks_error(err.?);
    try std.testing.expectEqual(RocksError.IOError, status);
}

/// A handle to a RocksDB database.
pub const RocksDB = struct {
    db: *c.rocksdb_t,
    otxn_db: *c.rocksdb_optimistictransactiondb_t,
    write_opts: *c.rocksdb_writeoptions_t,
    read_opts: *c.rocksdb_readoptions_t,

    cf_node: *c.rocksdb_column_family_handle_t,
    cf_edge: *c.rocksdb_column_family_handle_t,
    cf_adj: *c.rocksdb_column_family_handle_t,

    pub fn open(name: [:0]const u8) !RocksDB {
        const options = c.rocksdb_options_create() orelse return error.OutOfMemory;
        defer c.rocksdb_options_destroy(options);
        c.rocksdb_options_set_create_if_missing(options, 1);
        c.rocksdb_options_set_create_missing_column_families(options, 1);
        c.rocksdb_options_set_compression(options, c.rocksdb_lz4_compression);
        c.rocksdb_options_set_bottommost_compression(options, c.rocksdb_zstd_compression);
        c.rocksdb_options_increase_parallelism(options, @as(c_int, @intCast(std.Thread.getCpuCount() catch 2)));
        c.rocksdb_options_set_compaction_style(options, c.rocksdb_level_compaction);
        c.rocksdb_options_optimize_level_style_compaction(options, 512 * 1024 * 1024);

        // pre-create options to avoid repeated allocations
        const write_opts = c.rocksdb_writeoptions_create() orelse return error.OutOfMemory;
        c.rocksdb_writeoptions_disable_WAL(write_opts, 1);
        errdefer c.rocksdb_writeoptions_destroy(write_opts);

        const read_opts = c.rocksdb_readoptions_create() orelse return error.OutOfMemory;
        c.rocksdb_readoptions_set_async_io(read_opts, 1);
        errdefer c.rocksdb_readoptions_destroy(read_opts);

        // Define column families and their options.
        const num_cf = 4;
        var cf_names = [num_cf][*:0]const u8{ "default", "node", "edge", "adj" };
        var cf_options = [num_cf]*const c.rocksdb_options_t{ options, options, options, options };
        var cf_handles = [num_cf]?*c.rocksdb_column_family_handle_t{ null, null, null, null };

        var err: ?[*:0]u8 = null;
        const otxn_db = c.rocksdb_optimistictransactiondb_open_column_families(
            options,
            name.ptr,
            num_cf,
            &cf_names,
            &cf_options,
            &cf_handles,
            &err,
        );
        if (err) |e| return parse_rocks_error(e);

        // Should not be null in any case.
        const db = c.rocksdb_optimistictransactiondb_get_base_db(otxn_db);

        return RocksDB{
            .db = db.?,
            .otxn_db = otxn_db.?,
            .write_opts = write_opts,
            .read_opts = read_opts,
            .cf_node = cf_handles[1].?,
            .cf_edge = cf_handles[2].?,
            .cf_adj = cf_handles[3].?,
        };
    }

    pub fn close(self: RocksDB) void {
        c.rocksdb_column_family_handle_destroy(self.cf_node);
        c.rocksdb_column_family_handle_destroy(self.cf_edge);
        c.rocksdb_column_family_handle_destroy(self.cf_adj);
        c.rocksdb_optimistictransactiondb_close_base_db(self.db);
        c.rocksdb_optimistictransactiondb_close(self.otxn_db);
        c.rocksdb_writeoptions_destroy(self.write_opts);
        c.rocksdb_readoptions_destroy(self.read_opts);
    }

    pub fn put(self: RocksDB, key: []const u8, value: []const u8) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_put(self.db, self.write_opts, key.ptr, key.len, value.ptr, value.len, &err);
        if (err) |e| return parse_rocks_error(e);
    }

    pub fn get(self: RocksDB, key: []const u8) !?PinnableSlice {
        var err: ?[*:0]u8 = null;
        const value = c.rocksdb_get_pinned(self.db, self.read_opts, key.ptr, key.len, &err);
        if (err) |e| return parse_rocks_error(e);
        const val = value orelse return null;
        return PinnableSlice{ .rep = val };
    }

    pub fn delete(self: RocksDB, key: []const u8) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_delete(self.db, self.write_opts, key.ptr, key.len, &err);
        if (err) |e| return parse_rocks_error(e);
    }
};

/// A pinnable slice, which can reference memory that is directly owned by RocksDB.
pub const PinnableSlice = struct {
    rep: *c.rocksdb_pinnableslice_t,

    /// Reference the value as a Zig slice.
    pub fn items(self: PinnableSlice) []const u8 {
        var vlen: usize = undefined;
        const vptr = c.rocksdb_pinnableslice_value(self.rep, &vlen);
        // Note: vptr cannot be null here, since self.rep is not null.
        std.debug.assert(vptr != null);
        return vptr[0..vlen];
    }

    /// Release the reference to memory associated with this slice.
    pub fn deinit(self: PinnableSlice) void {
        c.rocksdb_pinnableslice_destroy(self.rep);
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
    {
        const value = try db.get("hello") orelse @panic("value for 'hello' not found");
        defer value.deinit();
        try std.testing.expectEqualSlices(u8, "world", value.items());
    }

    try db.delete("hello");
    try std.testing.expectEqual(null, try db.get("hello"));
}
