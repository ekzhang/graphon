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
pub const Error = error{
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
fn parse_rocks_error(err: [*:0]u8) Error {
    defer c.rocksdb_free(err); // free the memory when done
    log.info("{s}", .{err});

    const slice = std.mem.span(err);
    if (slice.len == 0) return Error.UnknownStatus;
    switch (slice[0]) {
        'C' => {
            if (slice_starts_with(slice, "Corruption: ")) return Error.Corruption;
            if (slice_starts_with(slice, "Compaction too large: ")) return Error.CompactionTooLarge;
            if (slice_starts_with(slice, "Column family dropped: ")) return Error.ColumnFamilyDropped;
        },
        'I' => {
            if (slice_starts_with(slice, "Invalid argument: ")) return Error.InvalidArgument;
            if (slice_starts_with(slice, "IO error: ")) return Error.IOError;
        },
        'M' => {
            if (slice_starts_with(slice, "Merge in progress: ")) return Error.MergeInProgress;
        },
        'N' => {
            if (slice_starts_with(slice, "NotFound: ")) return Error.NotFound;
            if (slice_starts_with(slice, "Not implemented: ")) return Error.NotSupported;
        },
        'O' => {
            if (slice_starts_with(slice, "Operation timed out: ")) return Error.TimedOut;
            if (slice_starts_with(slice, "Operation aborted: ")) return Error.Aborted;
            if (slice_starts_with(slice, "Operation expired: ")) return Error.Expired;
            if (slice_starts_with(slice, "Operation failed. Try again.: ")) return Error.TryAgain;
        },
        'R' => {
            if (slice_starts_with(slice, "Result incomplete: ")) return Error.Incomplete;
            if (slice_starts_with(slice, "Resource busy: ")) return Error.Busy;
        },
        'S' => {
            if (slice_starts_with(slice, "Shutdown in progress: ")) return Error.ShutdownInProgress;
        },
        else => {},
    }
    return Error.UnknownStatus;
}

test "parse error from rocksdb_open" {
    const options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(options);

    var err: ?[*:0]u8 = null;
    const db = c.rocksdb_open(options, "<~~not@a/valid&file>", &err);
    try std.testing.expectEqual(null, db);

    const status = parse_rocks_error(err.?);
    try std.testing.expectEqual(Error.IOError, status);
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
pub const DB = struct {
    db: *c.rocksdb_t,
    otxn_db: *c.rocksdb_optimistictransactiondb_t,
    write_opts: *c.rocksdb_writeoptions_t,
    read_opts: *c.rocksdb_readoptions_t,
    otxn_opts: *c.rocksdb_optimistictransaction_options_t,
    cf_handles: std.EnumArray(ColumnFamily, *c.rocksdb_column_family_handle_t),

    /// Open a RocksDB database with the given name, creating it if it does not exist.
    pub fn open(name: []const u8) !DB {
        const nameZ = try allocator.dupeZ(u8, name);
        defer allocator.free(nameZ);

        const options = c.rocksdb_options_create().?;
        defer c.rocksdb_options_destroy(options);
        c.rocksdb_options_set_create_if_missing(options, 1);
        c.rocksdb_options_set_create_missing_column_families(options, 1);
        c.rocksdb_options_set_compression(options, c.rocksdb_lz4_compression);
        c.rocksdb_options_set_bottommost_compression(options, c.rocksdb_zstd_compression);
        c.rocksdb_options_increase_parallelism(options, @as(c_int, @intCast(std.Thread.getCpuCount() catch 2)));
        c.rocksdb_options_set_compaction_style(options, c.rocksdb_level_compaction);
        c.rocksdb_options_optimize_level_style_compaction(options, 512 * 1024 * 1024);
        c.rocksdb_options_set_write_buffer_size(options, 256 * 1024 * 1024);

        // Set 512 MiB in-memory block cache for reads (default: 32 MiB).
        {
            const table_options = c.rocksdb_block_based_options_create().?;
            defer c.rocksdb_block_based_options_destroy(table_options);
            const cache = c.rocksdb_cache_create_lru(512 * 1024 * 1024).?;
            defer c.rocksdb_cache_destroy(cache);
            c.rocksdb_block_based_options_set_block_cache(table_options, cache);
            c.rocksdb_options_set_block_based_table_factory(options, table_options);
        }

        // pre-create options to avoid repeated allocations
        const write_opts = c.rocksdb_writeoptions_create().?;
        c.rocksdb_writeoptions_disable_WAL(write_opts, 1);
        errdefer c.rocksdb_writeoptions_destroy(write_opts);

        const read_opts = c.rocksdb_readoptions_create().?;
        c.rocksdb_readoptions_set_async_io(read_opts, 1);
        errdefer c.rocksdb_readoptions_destroy(read_opts);

        const otxn_opts = c.rocksdb_optimistictransaction_options_create().?;
        c.rocksdb_optimistictransaction_options_set_set_snapshot(otxn_opts, 1);
        errdefer c.rocksdb_optimistictransaction_options_destroy(otxn_opts);

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

        return DB{
            .db = db.?,
            .otxn_db = otxn_db.?,
            .write_opts = write_opts,
            .read_opts = read_opts,
            .otxn_opts = otxn_opts,
            .cf_handles = cf_handles,
        };
    }

    /// Close the database, releasing all resources.
    pub fn close(self: DB) void {
        for (self.cf_handles.values) |cf| {
            c.rocksdb_column_family_handle_destroy(cf);
        }
        c.rocksdb_optimistictransactiondb_close_base_db(self.db);
        c.rocksdb_optimistictransactiondb_close(self.otxn_db);
        c.rocksdb_writeoptions_destroy(self.write_opts);
        c.rocksdb_readoptions_destroy(self.read_opts);
    }

    /// Put a key-value pair into the database.
    pub fn put(self: DB, cf: ColumnFamily, key: []const u8, value: []const u8) !void {
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
    pub fn get(self: DB, cf: ColumnFamily, key: []const u8) !?PinnableSlice {
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
    pub fn iterate(self: DB, cf: ColumnFamily, lower_bound: ?[]const u8, upper_bound: ?[]const u8) Iterator {
        const opts = c.rocksdb_readoptions_create().?;
        c.rocksdb_readoptions_set_async_io(opts, 1);
        if (lower_bound) |key|
            c.rocksdb_readoptions_set_iterate_lower_bound(opts, key.ptr, key.len);
        if (upper_bound) |key|
            c.rocksdb_readoptions_set_iterate_upper_bound(opts, key.ptr, key.len);
        const it = c.rocksdb_create_iterator_cf(self.db, opts, self.cf_handles.get(cf)).?;
        c.rocksdb_iter_seek_to_first(it);
        return Iterator{ .rep = it, .opts = opts };
    }

    /// Delete a key from the database.
    pub fn delete(self: DB, cf: ColumnFamily, key: []const u8) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_delete_cf(self.db, self.write_opts, self.cf_handles.get(cf), key.ptr, key.len, &err);
        if (err) |e| return parse_rocks_error(e);
    }

    /// Delete a range of keys from the database. The range is inclusive-exclusive.
    pub fn deleteRange(self: DB, cf: ColumnFamily, lower_bound: []const u8, upper_bound: []const u8) !void {
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

    /// Begin a new optimistic transaction on the database.
    pub fn begin(self: DB) Transaction {
        const txn = c.rocksdb_optimistictransaction_begin(self.otxn_db, self.write_opts, self.otxn_opts, null).?;
        // The snapshot exists because we enabled set_snapshot in otxn_opts.
        const snapshot = c.rocksdb_transaction_get_snapshot(txn).?;
        return Transaction{ .txn = txn, .snap = snapshot, .cf_handles = self.cf_handles };
    }
};

/// A transaction on a RocksDB database.
/// Transactions are not thread-safe and should not be shared between threads.
pub const Transaction = struct {
    txn: *c.rocksdb_transaction_t,
    snap: *const c.rocksdb_snapshot_t,
    cf_handles: std.EnumArray(ColumnFamily, *c.rocksdb_column_family_handle_t),

    /// Release the transaction.
    pub fn close(self: Transaction) void {
        c.rocksdb_transaction_destroy(self.txn);
    }

    /// See `RocksDB.put()`.
    pub fn put(self: Transaction, cf: ColumnFamily, key: []const u8, value: []const u8) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_transaction_put_cf(
            self.txn,
            self.cf_handles.get(cf),
            key.ptr,
            key.len,
            value.ptr,
            value.len,
            &err,
        );
        if (err) |e| return parse_rocks_error(e);
    }

    /// See `RocksDB.get()`.
    ///
    /// This function uses the GetForUpdate() operation to hint the underlying
    /// RocksDB transaction engine to trigger read-write conflicts. This is the
    /// only way to trigger conflicts, as `iterate()` does not do the check.
    ///
    /// If `exclusive` is true, the transaction is recorded as having written to
    /// this key.
    pub fn get(self: Transaction, cf: ColumnFamily, key: []const u8, exclusive: bool) !?PinnableSlice {
        const opts = c.rocksdb_readoptions_create().?;
        defer c.rocksdb_readoptions_destroy(opts);
        c.rocksdb_readoptions_set_snapshot(opts, self.snap); // Use snapshot in transaction.
        c.rocksdb_readoptions_set_async_io(opts, 1);
        var err: ?[*:0]u8 = null;
        const value = c.rocksdb_transaction_get_pinned_for_update_cf(
            self.txn,
            opts,
            self.cf_handles.get(cf),
            key.ptr,
            key.len,
            @intFromBool(exclusive),
            &err,
        );
        if (err) |e| return parse_rocks_error(e);
        const val = value orelse return null;
        return PinnableSlice{ .rep = val };
    }

    /// See `RocksDB.iterate()`.
    pub fn iterate(self: Transaction, cf: ColumnFamily, lower_bound: ?[]const u8, upper_bound: ?[]const u8) Iterator {
        const opts = c.rocksdb_readoptions_create().?;
        c.rocksdb_readoptions_set_snapshot(opts, self.snap); // Use snapshot in transaction.
        c.rocksdb_readoptions_set_async_io(opts, 1);
        if (lower_bound) |key|
            c.rocksdb_readoptions_set_iterate_lower_bound(opts, key.ptr, key.len);
        if (upper_bound) |key|
            c.rocksdb_readoptions_set_iterate_upper_bound(opts, key.ptr, key.len);
        const it = c.rocksdb_transaction_create_iterator_cf(self.txn, opts, self.cf_handles.get(cf)).?;
        c.rocksdb_iter_seek_to_first(it);
        return Iterator{ .rep = it, .opts = opts };
    }

    /// See `RocksDB.delete()`.
    pub fn delete(self: Transaction, cf: ColumnFamily, key: []const u8) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_transaction_delete_cf(self.txn, self.cf_handles.get(cf), key.ptr, key.len, &err);
        if (err) |e| return parse_rocks_error(e);
    }

    /// Commit the transaction and write all batched keys atomically.
    ///
    /// This will fail if there are any optimistic transaction conflicts. The
    /// error returned will be `Busy`. Otherwise, if the memtable history size
    /// is not large enough, it will return `TryAgain`.
    pub fn commit(self: Transaction) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_transaction_commit(self.txn, &err);
        if (err) |e| return parse_rocks_error(e);
    }

    /// Rollback the transaction and discard all batched writes.
    pub fn rollback(self: Transaction) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_transaction_rollback(self.txn, &err);
        if (err) |e| return parse_rocks_error(e);
    }

    /// Set the savepoint, allowing it to be rolled back to this point.
    pub fn set_savepoint(self: Transaction) void {
        c.rocksdb_transaction_set_savepoint(self.txn);
    }

    /// Rollback to the last savepoint, discarding all writes since then.
    pub fn rollback_to_savepoint(self: Transaction) !void {
        var err: ?[*:0]u8 = null;
        c.rocksdb_transaction_rollback_to_savepoint(self.txn, &err);
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
    pub fn close(self: Iterator) void {
        c.rocksdb_iter_destroy(self.rep);
        c.rocksdb_readoptions_destroy(self.opts);
    }
};

/// A pinnable slice, which can reference memory that is directly owned by RocksDB.
pub const PinnableSlice = struct {
    rep: *c.rocksdb_pinnableslice_t,

    /// Reference the value as a Zig slice.
    pub fn bytes(self: PinnableSlice) []const u8 {
        var vlen: usize = undefined;
        const vptr = c.rocksdb_pinnableslice_value(self.rep, &vlen);
        // Note: vptr cannot be null here, since self.rep is not null.
        std.debug.assert(vptr != null);
        return vptr[0..vlen];
    }

    /// Release the reference to memory associated with this slice.
    pub fn close(self: PinnableSlice) void {
        c.rocksdb_pinnableslice_destroy(self.rep);
    }
};

test "get and put value" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();
    const db = try DB.open(tmp.path("test.db"));
    defer db.close();

    try std.testing.expectEqual(null, try db.get(.default, "hello"));

    try db.put(.default, "hello", "world");
    {
        const value = try db.get(.default, "hello") orelse
            std.debug.panic("value for 'hello' not found", .{});
        defer value.close();
        try std.testing.expectEqualSlices(u8, "world", value.bytes());
    }

    try db.delete(.default, "hello");
    try std.testing.expectEqual(null, try db.get(.default, "hello"));
}

test "iterate range" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();
    const db = try DB.open(tmp.path("test.db"));
    defer db.close();

    try db.put(.default, "a", "1");
    try db.put(.default, "aa", "2");
    try db.put(.default, "aaa", "3");
    try db.put(.default, "aab", "4");
    try db.put(.default, "ab", "5");
    {
        const it = db.iterate(.default, "aa", "ab");
        defer it.close();
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

    try db.deleteRange(.default, "aa", "aab");
    {
        const it = db.iterate(.default, "aa", "ab");
        defer it.close();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, "aab", it.key());
        try std.testing.expectEqualSlices(u8, "4", it.value());
        it.next();
        try std.testing.expect(!it.valid());
    }
}

test "transaction" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();
    const db = try DB.open(tmp.path("test.db"));
    defer db.close();

    const tx1 = db.begin();
    const tx2 = db.begin();
    defer tx1.close();
    defer tx2.close();
    try tx1.put(.default, "x", "1");

    // Outside the transaction, we shouldn't see the value yet.
    try std.testing.expectEqual(null, try db.get(.default, "x"));
    try std.testing.expectEqual(null, try tx2.get(.default, "x", false));

    try tx1.commit();

    // After commit, we should see the value.
    {
        const value = try db.get(.default, "x") orelse
            std.debug.panic("value not found", .{});
        defer value.close();
        try std.testing.expectEqualSlices(u8, value.bytes(), "1");
    }

    {
        const it = db.iterate(.default, "x", null);
        defer it.close();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, "x", it.key());
        try std.testing.expectEqualSlices(u8, "1", it.value());
    }

    // But tx2 should still not be able to see the value.
    try std.testing.expectEqual(null, try tx2.get(.default, "x", false));

    {
        const it = tx2.iterate(.default, "x", null);
        defer it.close();
        try std.testing.expect(!it.valid());
    }

    // If tx2 then modifies "x", it should cause a conflict.
    try tx2.put(.default, "x", "2");
    try std.testing.expectError(Error.Busy, tx2.commit());
    try tx2.rollback();
}
