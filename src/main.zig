const std = @import("std");
const allocator = std.heap.c_allocator;

const rocksdb = @import("storage/rocksdb.zig");
const graphon = @import("graphon.zig");

fn rocksdb_insert_perf() !void {
    const db = try rocksdb.DB.open("/tmp/graphon");
    defer db.close();
    std.debug.print("opened database at /tmp/graphon\n", .{});

    const n_keys = 2_000_000;
    const size_of_key = 128;

    var prng = std.rand.DefaultPrng.init(0);
    const rand = prng.random();
    var buf: [size_of_key]u8 = undefined;
    var timer = try std.time.Timer.start();
    var total_time: u64 = 0;
    for (0..n_keys) |i| {
        if ((i + 1) % 100_000 == 0) {
            const elapsed = timer.lap();
            std.debug.print("putting key {d} / lap {}\n", .{ i + 1, std.fmt.fmtDuration(elapsed) });
            total_time += elapsed;
        }
        rand.bytes(buf[0..]);
        try db.put(.default, buf[0..], buf[0..]);
    }
    total_time += timer.lap();
    std.debug.print("total time: {}\n", .{std.fmt.fmtDuration(total_time)});
}

pub fn main() !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const C = enum {
        help,
        rocksdb_insert_perf,
        shell,
    };

    _ = args.next(); // skip program name
    const command = std.meta.stringToEnum(C, args.next() orelse "help") orelse {
        std.debug.print("invalid command\n", .{});
        std.posix.exit(1);
    };
    switch (command) {
        .help => {
            std.debug.print("usage: graphon <command>\n", .{});
            return;
        },
        .shell => {
            // Open a GQL shell into a temporary database.
            @panic("not implemented");
        },
        .rocksdb_insert_perf => {
            try rocksdb_insert_perf();
        },
    }
}
