const std = @import("std");

const graphon = @import("graphon.zig");
const RocksDB = graphon.storage.RocksDB;

pub fn main() !void {
    const db = try RocksDB.open("/tmp/graphon");
    std.debug.print("created database at /tmp/graphon\n", .{});
    db.close();
}
