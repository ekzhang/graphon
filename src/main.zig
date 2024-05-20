const std = @import("std");

const graphon = @import("graphon.zig");
const RocksDB = graphon.storage.RocksDB;

pub fn main() !void {
    const db = try RocksDB.open("/tmp/graphon");
    std.debug.print("opened database at /tmp/graphon\n", .{});

    std.debug.print("GET foo -> {?s}\n", .{try db.get("foo")});
    std.debug.print("PUT foo bar\n", .{});
    try db.put("foo", "bar");
    std.debug.print("GET foo -> {?s}\n", .{try db.get("foo")});
    std.debug.print("DELETE foo\n", .{});
    try db.delete("foo");

    db.close();
}
