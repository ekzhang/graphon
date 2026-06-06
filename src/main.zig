const std = @import("std");

const rocksdb = @import("storage/rocksdb.zig");
const graphon = @import("graphon.zig");

fn rocksdb_insert_perf(io: std.Io) !void {
    const db = try rocksdb.DB.open("/tmp/graphon");
    defer db.close();
    std.debug.print("opened database at /tmp/graphon\n", .{});

    const n_keys = 2_000_000;
    const size_of_key = 128;

    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();
    var buf: [size_of_key]u8 = undefined;
    var last = std.Io.Timestamp.now(io, .awake);
    var total_time: std.Io.Duration = .zero;
    for (0..n_keys) |i| {
        if ((i + 1) % 100_000 == 0) {
            const now = std.Io.Timestamp.now(io, .awake);
            const elapsed = last.durationTo(now);
            last = now;
            std.debug.print("putting key {d} / lap {f}\n", .{ i + 1, elapsed });
            total_time.nanoseconds += elapsed.nanoseconds;
        }
        rand.bytes(buf[0..]);
        try db.put(.default, buf[0..], buf[0..]);
    }
    const now = std.Io.Timestamp.now(io, .awake);
    const elapsed = last.durationTo(now);
    total_time.nanoseconds += elapsed.nanoseconds;
    std.debug.print("total time: {f}\n", .{total_time});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const C = enum {
        help,
        rocksdb_insert_perf,
        shell,
    };

    const command_name = if (args.len > 1) args[1] else "help";
    const command = std.meta.stringToEnum(C, command_name) orelse {
        std.debug.print("invalid command\n", .{});
        std.process.exit(1);
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
            try rocksdb_insert_perf(init.io);
        },
    }

    _ = graphon;
}
