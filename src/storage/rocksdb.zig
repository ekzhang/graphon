//! Friendly Zig wrapper types for RocksDB's C API.

const std = @import("std");
const c = @cImport(@cInclude("rocksdb/c.h"));
const allocator = std.heap.c_allocator;

const test_helpers = @import("../test_helpers.zig");

/// Type for known errors from RocksDB.
/// Based on the `Code` enum defined in `include/rocksdb/status.h`.
///
/// In addition to errors returned as a string from API methods, we also can can
/// get error codes from other places like functions returning null pointers.
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

/// Constant set of column families defined for the database.
pub const ColumnFamily = enum(u8) {
    /// The default column family, required by RocksDB when opening a database.
    /// We keep graph metadata here.
    default,
    /// Nodes in the graph.
    node,
    /// Edges in the graph.
    edge,
    /// Forward and backward adjacency lists for nodes.
    adj,
};

/// A handle to a RocksDB database.
pub const RocksDB = struct {
    db: *c.rocksdb_t,
    otxn_db: *c.rocksdb_optimistictransactiondb_t,
    write_opts: *c.rocksdb_writeoptions_t,
    read_opts: *c.rocksdb_readoptions_t,
    cf_handles: std.EnumArray(ColumnFamily, *c.rocksdb_column_family_handle_t),

    pub fn open(name: []const u8) !RocksDB {
        const nameZ = try allocator.dupeZ(u8, name);
        defer allocator.free(nameZ);

        const options = c.rocksdb_options_create() orelse return error.OutOfMemory;
        defer c.rocksdb_options_destroy(options);
        c.rocksdb_options_set_create_if_missing(options, 1);
        c.rocksdb_options_set_create_missing_column_families(options, 1);
        c.rocksdb_options_set_compression(options, c.rocksdb_lz4_compression);
        c.rocksdb_options_set_bottommost_compression(options, c.rocksdb_zstd_compression);
        c.rocksdb_options_increase_parallelism(options, @as(c_int, @intCast(std.Thread.getCpuCount() catch 2)));
        c.rocksdb_options_set_compaction_style(options, c.rocksdb_level_compaction);
        c.rocksdb_options_optimize_level_style_compaction(options, 512 * 1024 * 1024);

        // Set 512 MiB in-memory block cache for reads (default: 32 MiB).
        {
            const table_options = c.rocksdb_block_based_options_create() orelse return error.OutOfMemory;
            defer c.rocksdb_block_based_options_destroy(table_options);
            const cache = c.rocksdb_cache_create_lru(512 * 1024 * 1024) orelse return error.OutOfMemory;
            defer c.rocksdb_cache_destroy(cache);
            c.rocksdb_block_based_options_set_block_cache(table_options, cache);
            c.rocksdb_options_set_block_based_table_factory(options, table_options);
        }

        // pre-create options to avoid repeated allocations
        const write_opts = c.rocksdb_writeoptions_create() orelse return error.OutOfMemory;
        c.rocksdb_writeoptions_disable_WAL(write_opts, 1);
        errdefer c.rocksdb_writeoptions_destroy(write_opts);

        const read_opts = c.rocksdb_readoptions_create() orelse return error.OutOfMemory;
        c.rocksdb_readoptions_set_async_io(read_opts, 1);
        errdefer c.rocksdb_readoptions_destroy(read_opts);

        // Define column families and their options.
        var cf_names = std.EnumArray(ColumnFamily, [*:0]const u8).initUndefined();
        var cf_names_it = cf_names.iterator();
        while (cf_names_it.next()) |entry| {
            entry.value.* = @tagName(entry.key);
        }
        var cf_options = std.EnumArray(ColumnFamily, *const c.rocksdb_options_t).initFill(options);
        var cf_handles = std.EnumArray(ColumnFamily, *c.rocksdb_column_family_handle_t).initUndefined();

        var err: ?[*:0]u8 = null;
        const otxn_db = c.rocksdb_optimistictransactiondb_open_column_families(
            options,
            nameZ.ptr,
            cf_names.values.len,
            &cf_names.values,
            &cf_options.values,
            @ptrCast(&cf_handles.values), // Cast the array type into a ?* pointer.
            &err,
        );
        if (err) |e| return parse_rocks_error(e);

        // Should not be null because otxn_db is only null on error.
        const db = c.rocksdb_optimistictransactiondb_get_base_db(otxn_db);

        return RocksDB{
            .db = db.?,
            .otxn_db = otxn_db.?,
            .write_opts = write_opts,
            .read_opts = read_opts,
            .cf_handles = cf_handles,
        };
    }

    /// Close the database, releasing all resources.
    pub fn close(self: RocksDB) void {
        for (self.cf_handles.values) |cf| {
            c.rocksdb_column_family_handle_destroy(cf);
        }
        c.rocksdb_optimistictransactiondb_close_base_db(self.db);
        c.rocksdb_optimistictransactiondb_close(self.otxn_db);
        c.rocksdb_writeoptions_destroy(self.write_opts);
        c.rocksdb_readoptions_destroy(self.read_opts);
    }

    /// Put a key-value pair into the database.
    pub fn put(self: RocksDB, cf: ColumnFamily, key: []const u8, value: []const u8) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_put_cf(
            self.db,
            self.write_opts,
            self.cf_handles.get(cf),
            key.ptr,
            key.len,
            value.ptr,
            value.len,
            &err,
        );
        if (err) |e| return parse_rocks_error(e);
    }

    /// Get a value from the database by key.
    pub fn get(self: RocksDB, cf: ColumnFamily, key: []const u8) !?PinnableSlice {
        var err: ?[*:0]u8 = null;
        const value = c.rocksdb_get_pinned_cf(
            self.db,
            self.read_opts,
            self.cf_handles.get(cf),
            key.ptr,
            key.len,
            &err,
        );
        if (err) |e| return parse_rocks_error(e);
        const val = value orelse return null;
        return PinnableSlice{ .rep = val };
    }

    /// Iterate over the database by inclusive-exclusive range.
    ///
    /// Make sure that the slices for the lower and upper bounds point to valid
    /// memory while the iterator is active. If the bounds are freed before the
    /// iterator is destroyed, it will lead to undefined behavior.
    pub fn iterate(self: RocksDB, cf: ColumnFamily, lower_bound: ?[]const u8, upper_bound: ?[]const u8) !Iterator {
        const opts = c.rocksdb_readoptions_create() orelse return error.OutOfMemory;
        errdefer c.rocksdb_readoptions_destroy(opts);
        c.rocksdb_readoptions_set_async_io(opts, 1);
        if (lower_bound) |key|
            c.rocksdb_readoptions_set_iterate_lower_bound(opts, key.ptr, key.len);
        if (upper_bound) |key|
            c.rocksdb_readoptions_set_iterate_upper_bound(opts, key.ptr, key.len);
        const it = c.rocksdb_create_iterator_cf(self.db, opts, self.cf_handles.get(cf)) orelse return error.OutOfMemory;
        c.rocksdb_iter_seek_to_first(it);
        return Iterator{ .rep = it, .opts = opts };
    }

    /// Delete a key from the database.
    pub fn delete(self: RocksDB, cf: ColumnFamily, key: []const u8) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_delete_cf(
            self.db,
            self.write_opts,
            self.cf_handles.get(cf),
            key.ptr,
            key.len,
            &err,
        );
        if (err) |e| return parse_rocks_error(e);
    }

    /// Delete a range of keys from the database. The range is inclusive-exclusive.
    pub fn delete_range(self: RocksDB, cf: ColumnFamily, lower_bound: []const u8, upper_bound: []const u8) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_delete_range_cf(
            self.db,
            self.write_opts,
            self.cf_handles.get(cf),
            lower_bound.ptr,
            lower_bound.len,
            upper_bound.ptr,
            upper_bound.len,
            &err,
        );
        if (err) |e| return parse_rocks_error(e);
    }
};

/// An iterator over a range of keys in a RocksDB database.
pub const Iterator = struct {
    rep: *c.rocksdb_iterator_t,
    opts: *c.rocksdb_readoptions_t,

    /// Check if the current position of the iterator is valid.
    pub fn valid(self: Iterator) bool {
        return c.rocksdb_iter_valid(self.rep) != 0;
    }

    /// Advance the iterator. This invalidates any previous key or value slice.
    pub fn next(self: Iterator) void {
        c.rocksdb_iter_next(self.rep);
    }

    /// Get the key at the current position of the iterator.
    pub fn key(self: Iterator) []const u8 {
        var klen: usize = undefined;
        const kptr = c.rocksdb_iter_key(self.rep, &klen);
        std.debug.assert(kptr != null);
        return kptr[0..klen];
    }

    /// Get the value at the current position of the iterator.
    pub fn value(self: Iterator) []const u8 {
        var vlen: usize = undefined;
        const vptr = c.rocksdb_iter_value(self.rep, &vlen);
        std.debug.assert(vptr != null);
        return vptr[0..vlen];
    }

    /// Release the iterator.
    pub fn deinit(self: Iterator) void {
        c.rocksdb_iter_destroy(self.rep);
        c.rocksdb_readoptions_destroy(self.opts);
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
    var tmp = test_helpers.simpleTmpDir();
    defer tmp.cleanup();

    const db = try RocksDB.open(tmp.path("test.db"));
    defer db.close();

    try std.testing.expectEqual(null, try db.get(.default, "hello"));

    try db.put(.default, "hello", "world");
    {
        const value = try db.get(.default, "hello") orelse @panic("value for 'hello' not found");
        defer value.deinit();
        try std.testing.expectEqualSlices(u8, "world", value.items());
    }

    try db.delete(.default, "hello");
    try std.testing.expectEqual(null, try db.get(.default, "hello"));
}

test "iterate range" {
    var tmp = test_helpers.simpleTmpDir();
    defer tmp.cleanup();

    const db = try RocksDB.open(tmp.path("test.db"));
    defer db.close();

    try db.put(.default, "a", "1");
    try db.put(.default, "aa", "2");
    try db.put(.default, "aaa", "3");
    try db.put(.default, "aab", "4");
    try db.put(.default, "ab", "5");
    {
        const it = try db.iterate(.default, "aa", "ab");
        defer it.deinit();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, "aa", it.key());
        try std.testing.expectEqualSlices(u8, "2", it.value());
        it.next();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, "aaa", it.key());
        try std.testing.expectEqualSlices(u8, "3", it.value());
        it.next();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, "aab", it.key());
        try std.testing.expectEqualSlices(u8, "4", it.value());
        it.next();
        try std.testing.expect(!it.valid());
    }

    try db.delete_range(.default, "aa", "aab");
    {
        const it = try db.iterate(.default, "aa", "ab");
        defer it.deinit();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, "aab", it.key());
        try std.testing.expectEqualSlices(u8, "4", it.value());
        it.next();
        try std.testing.expect(!it.valid());
    }
}
