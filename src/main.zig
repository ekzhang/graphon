const std = @import("std");

const rocksdb = @import("storage/rocksdb.zig");
const storage = @import("storage.zig");
const Ast = @import("Ast.zig");
const query = @import("query.zig");
const bolt = @import("bolt.zig");
const graphon = @import("graphon.zig");

const default_db_path = "/tmp/graphon.db";
const default_host = "127.0.0.1";
const default_port: u16 = 7687;
const json_headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};

const QueryOutcome = union(enum) {
    result: query.ResultSet,
    parse_errors: Ast.ErrorList,

    fn deinit(self: *QueryOutcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .result => |*result| result.deinit(gpa),
            .parse_errors => |*errors| errors.deinit(gpa),
        }
        self.* = undefined;
    }
};

fn rocksdbInsertPerf(io: std.Io) !void {
    const db = try rocksdb.DB.open("/tmp/graphon-perf");
    defer db.close();
    std.debug.print("opened database at /tmp/graphon-perf\n", .{});

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
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 1) {
        try serve(io, gpa, default_db_path, default_host, default_port);
        return;
    }

    const C = enum {
        help,
        serve,
        query,
        shell,
        rocksdb_insert_perf,
    };

    const command = std.meta.stringToEnum(C, args[1]) orelse {
        std.debug.print("invalid command: {s}\n", .{args[1]});
        usage();
        std.process.exit(1);
    };
    switch (command) {
        .help => usage(),
        .serve => {
            const path = if (args.len > 2) args[2] else default_db_path;
            try serve(io, gpa, path, default_host, default_port);
        },
        .query => {
            if (args.len < 3) {
                std.debug.print("usage: graphon query <GQL>\n", .{});
                std.process.exit(1);
            }
            const source = try std.mem.joinZ(gpa, " ", args[2..]);
            defer gpa.free(source);
            var outcome = try executeLocal(gpa, io, default_db_path, source);
            defer outcome.deinit(gpa);
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
            switch (outcome) {
                .result => |*result| {
                    var json: std.json.Stringify = .{ .writer = &stdout_writer.interface, .options = .{} };
                    try result.writeJson(&json);
                    try stdout_writer.interface.writeByte('\n');
                    try stdout_writer.interface.flush();
                },
                .parse_errors => |errors| {
                    var stderr_buffer: [4096]u8 = undefined;
                    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
                    try errors.render(&stderr_writer.interface);
                    try stderr_writer.interface.flush();
                    std.process.exit(1);
                },
            }
        },
        .shell => try localShell(gpa, io, default_db_path),
        .rocksdb_insert_perf => try rocksdbInsertPerf(io),
    }

    _ = graphon;
}

fn usage() void {
    std.debug.print(
        \\usage:
        \\  graphon                         start HTTP server on 127.0.0.1:7687
        \\  graphon serve [db-path]          start HTTP server
        \\  graphon query <GQL>              run one query against /tmp/graphon.db
        \\  graphon shell                    run a local GQL shell
        \\  graphon rocksdb_insert_perf      run RocksDB insert benchmark
        \\
    , .{});
}

fn executeLocal(gpa: std.mem.Allocator, io: std.Io, db_path: []const u8, source: [:0]const u8) !QueryOutcome {
    const db = try rocksdb.DB.open(db_path);
    defer db.close();
    const store = storage.Storage{ .db = db, .allocator = std.heap.c_allocator, .io = io };
    return try executeQuery(gpa, store, source);
}

fn executeQuery(gpa: std.mem.Allocator, store: storage.Storage, source: [:0]const u8) !QueryOutcome {
    var prepared = try query.prepare(gpa, source);
    defer prepared.deinit(gpa);
    if (prepared.takeParseErrors()) |errors| return .{ .parse_errors = errors };

    const txn = store.txn();
    defer txn.close();
    errdefer txn.rollback() catch {};

    var result = try query.execute(gpa, txn, &prepared);
    errdefer result.deinit(gpa);
    try txn.commit();
    return .{ .result = result };
}

fn localShell(gpa: std.mem.Allocator, io: std.Io, db_path: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    try stdout.print("Opened local Graphon database at {s}\n", .{db_path});
    while (true) {
        try stdout.writeAll("> ");
        try stdout.flush();
        const line = (try stdin.takeDelimiter('\n')) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":exit")) break;
        const source = try gpa.dupeZ(u8, trimmed);
        defer gpa.free(source);
        var outcome = executeLocal(gpa, io, db_path, source) catch |err| {
            try stdout.print("error: {s}\n", .{@errorName(err)});
            continue;
        };
        defer outcome.deinit(gpa);
        switch (outcome) {
            .result => |*result| {
                var json: std.json.Stringify = .{ .writer = stdout, .options = .{} };
                try result.writeJson(&json);
                try stdout.writeByte('\n');
            },
            .parse_errors => |errors| try errors.render(stdout),
        }
    }
}

fn serve(io: std.Io, gpa: std.mem.Allocator, db_path: []const u8, host: []const u8, port: u16) !void {
    const db = try rocksdb.DB.open(db_path);
    defer db.close();
    const store = storage.Storage{ .db = db, .allocator = std.heap.c_allocator, .io = io };

    const addr = try std.Io.net.IpAddress.parse(host, port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print(
        "Graphon listening at http://{s}:{d}/ and bolt://{s}:{d}/ using {s}\n",
        .{ host, port, host, port, db_path },
    );
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        handleConnection(gpa, io, store, stream) catch |err| {
            std.debug.print("connection error: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnection(gpa: std.mem.Allocator, io: std.Io, store: storage.Storage, stream: std.Io.net.Stream) !void {
    defer stream.close(io);

    var recv_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buffer);
    var stream_writer = stream.writer(io, &send_buffer);
    if (bolt.isHandshake(try stream_reader.interface.peek(4))) {
        try bolt.handleSession(gpa, store, &stream_reader.interface, &stream_writer.interface);
        return;
    }

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (http_server.reader.state == .ready) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try handleRequest(gpa, store, &request);
    }
}

fn handleRequest(gpa: std.mem.Allocator, store: storage.Storage, request: *std.http.Server.Request) !void {
    if (request.head.method != .GET) {
        try request.respond("{\"error\":\"only GET is supported\"}", .{
            .status = .method_not_allowed,
            .keep_alive = false,
            .extra_headers = &json_headers,
        });
        return;
    }

    const raw_query = queryParam(gpa, request.head.target, "query") catch |err| {
        var body = std.Io.Writer.Allocating.init(gpa);
        defer body.deinit();
        try body.writer.print("{{\"error\":\"{s}\"}}", .{@errorName(err)});
        try request.respond(body.written(), .{
            .status = .bad_request,
            .keep_alive = false,
            .extra_headers = &json_headers,
        });
        return;
    };
    defer gpa.free(raw_query);
    const gql = try gpa.dupeZ(u8, raw_query);
    defer gpa.free(gql);

    var outcome = executeQuery(gpa, store, gql) catch |err| {
        try respondJsonError(gpa, request, .bad_request, @errorName(err));
        return;
    };
    defer outcome.deinit(gpa);

    const result = switch (outcome) {
        .result => |*result| result,
        .parse_errors => |errors| {
            var diagnostics = std.Io.Writer.Allocating.init(gpa);
            defer diagnostics.deinit();
            try errors.render(&diagnostics.writer);
            try respondJsonError(gpa, request, .bad_request, diagnostics.written());
            return;
        },
    };

    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    var json: std.json.Stringify = .{ .writer = &body.writer, .options = .{} };
    try result.writeJson(&json);
    try request.respond(body.written(), .{ .extra_headers = &json_headers });
}

fn respondJsonError(
    gpa: std.mem.Allocator,
    request: *std.http.Server.Request,
    status: std.http.Status,
    message: []const u8,
) !void {
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    try body.writer.writeAll("{\"error\":");
    try std.json.Stringify.value(message, .{}, &body.writer);
    try body.writer.writeByte('}');
    try request.respond(body.written(), .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &json_headers,
    });
}

fn queryParam(gpa: std.mem.Allocator, target: []const u8, name: []const u8) ![]u8 {
    const q_pos = std.mem.indexOfScalar(u8, target, '?') orelse return error.InvalidRequest;
    var params = std.mem.splitScalar(u8, target[q_pos + 1 ..], '&');
    while (params.next()) |param| {
        const eq_pos = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq_pos];
        if (!std.mem.eql(u8, key, name)) continue;
        return try decodeQueryValue(gpa, param[eq_pos + 1 ..]);
    }
    return error.InvalidRequest;
}

fn decodeQueryValue(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var decoded = try gpa.alloc(u8, input.len);
    errdefer gpa.free(decoded);

    const decoded_tail = std.Uri.percentDecodeBackwards(decoded, input);
    std.mem.copyForwards(u8, decoded[0..decoded_tail.len], decoded_tail);

    if (gpa.resize(decoded, decoded_tail.len)) {
        return decoded[0..decoded_tail.len];
    }

    const owned = try gpa.dupe(u8, decoded[0..decoded_tail.len]);
    gpa.free(decoded);
    return owned;
}

test "percent decode query parameter" {
    const decoded = try queryParam(std.testing.allocator, "/?query=RETURN%20100%20%2A%203", "query");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("RETURN 100 * 3", decoded);
}
