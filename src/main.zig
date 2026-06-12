const std = @import("std");
const anyline = @import("anyline");

const rocksdb = @import("storage/rocksdb.zig");
const storage = @import("storage.zig");
const Ast = @import("Ast.zig");
const query = @import("query.zig");
const bolt = @import("bolt.zig");
const graphon = @import("graphon.zig");

const default_db_path = "/tmp/graphon.db";
const default_host = "127.0.0.1";
const default_port: u16 = 7687;
const default_concurrency: usize = 64;
const json_headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
const have_signal_handlers = std.posix.Sigaction != void;

var server_shutdown_requested: std.atomic.Value(bool) = .init(false);

const ServeOptions = struct {
    db_path: []const u8 = default_db_path,
    concurrency: usize = default_concurrency,
};

const ConnectionJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: storage.Storage,
    stream: std.Io.net.Stream,
    sema: *std.Io.Semaphore,
};

const AcceptContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: storage.Storage,
    server: *std.Io.net.Server,
    connection_group: *std.Io.Group,
    connection_sema: *std.Io.Semaphore,
};

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

const SignalHandlers = struct {
    old_int: if (have_signal_handlers) std.posix.Sigaction else void = undefined,
    old_term: if (have_signal_handlers) std.posix.Sigaction else void = undefined,
    installed: bool = false,

    fn install() SignalHandlers {
        server_shutdown_requested.store(false, .release);

        var self: SignalHandlers = .{};
        if (have_signal_handlers) {
            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = handleShutdownSignal },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &action, &self.old_int);
            std.posix.sigaction(.TERM, &action, &self.old_term);
            self.installed = true;
        }
        return self;
    }

    fn deinit(self: *SignalHandlers) void {
        if (have_signal_handlers and self.installed) {
            std.posix.sigaction(.INT, &self.old_int, null);
            std.posix.sigaction(.TERM, &self.old_term, null);
            self.installed = false;
        }
    }
};

fn handleShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    server_shutdown_requested.store(true, .release);
}

fn shutdownRequested() bool {
    return server_shutdown_requested.load(.acquire);
}

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
        try serve(gpa, io, .{});
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
            const options = parseServeOptions(args[2..]) catch |err| {
                std.debug.print("invalid serve options: {s}\n", .{@errorName(err)});
                usage();
                std.process.exit(1);
            };
            try serve(gpa, io, options);
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
        \\  graphon serve [db-path] [--concurrency N]
        \\                                  start HTTP/Bolt server
        \\  graphon query <GQL>              run one query against /tmp/graphon.db
        \\  graphon shell                    run a local GQL shell
        \\  graphon rocksdb_insert_perf      run RocksDB insert benchmark
        \\
    , .{});
}

fn parseServeOptions(args: []const []const u8) !ServeOptions {
    var options: ServeOptions = .{};
    var seen_path = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--concurrency")) {
            i += 1;
            if (i >= args.len) return error.MissingConcurrency;
            options.concurrency = try parseConcurrency(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--concurrency=")) {
            options.concurrency = try parseConcurrency(arg["--concurrency=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else if (seen_path) {
            return error.TooManyArguments;
        } else {
            options.db_path = arg;
            seen_path = true;
        }
    }
    return options;
}

fn parseConcurrency(value: []const u8) !usize {
    const concurrency = try std.fmt.parseUnsigned(usize, value, 10);
    if (concurrency == 0) return error.InvalidConcurrency;
    return concurrency;
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

    anyline.history.usingHistory();
    defer anyline.freeHistory(gpa);
    defer anyline.freeKillRing(gpa);

    try stdout.print("Opened local Graphon database at {s}\n", .{db_path});
    while (true) {
        try stdout.flush();
        const line = anyline.readLine(io, gpa, "> ") catch |err| switch (err) {
            error.EndOfInput => break,
            error.ProcessExit => break,
            else => return err,
        };
        defer gpa.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":exit")) break;
        try anyline.history.addHistory(gpa, trimmed);

        const source = try gpa.dupeZ(u8, trimmed);
        defer gpa.free(source);
        var outcome = executeLocal(gpa, io, db_path, source) catch |err| {
            try stdout.print("error: {s}\n", .{@errorName(err)});
            try stdout.flush();
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
        try stdout.flush();
    }
}

fn serve(gpa: std.mem.Allocator, io: std.Io, options: ServeOptions) !void {
    var signals = SignalHandlers.install();
    defer signals.deinit();

    const db = try rocksdb.DB.open(options.db_path);
    defer db.close();
    const worker_allocator = std.heap.c_allocator;
    const store = storage.Storage{ .db = db, .allocator = worker_allocator, .io = io };

    var connection_group: std.Io.Group = .init;
    defer connection_group.cancel(io);
    var connection_sema: std.Io.Semaphore = .{ .permits = options.concurrency };
    var accept_group: std.Io.Group = .init;
    defer accept_group.cancel(io);

    const addr = try std.Io.net.IpAddress.parse(default_host, default_port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print(
        "Graphon listening at http://{s}:{d} and bolt://{s}:{d} using {s} with up to {d} concurrent connections\n",
        .{
            default_host,
            default_port,
            default_host,
            default_port,
            options.db_path,
            options.concurrency,
        },
    );

    var accept_context = AcceptContext{
        .gpa = gpa,
        .io = io,
        .store = store,
        .server = &server,
        .connection_group = &connection_group,
        .connection_sema = &connection_sema,
    };
    accept_group.async(io, acceptConnections, .{&accept_context});

    while (!shutdownRequested()) {
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch |err| switch (err) {
            error.Canceled => break,
        };
    }

    std.debug.print("Graphon shutting down\n", .{});
    accept_group.cancel(io);
    connection_group.cancel(io);
}

fn acceptConnections(context: *AcceptContext) std.Io.Cancelable!void {
    while (true) {
        try context.connection_sema.wait(context.io);
        const stream = context.server.accept(context.io) catch |err| switch (err) {
            error.Canceled => {
                context.connection_sema.post(context.io);
                return error.Canceled;
            },
            else => {
                context.connection_sema.post(context.io);
                std.debug.print("accept error: {s}\n", .{@errorName(err)});
                continue;
            },
        };

        const job = ConnectionJob{
            .gpa = context.gpa,
            .io = context.io,
            .store = context.store,
            .stream = stream,
            .sema = context.connection_sema,
        };
        context.connection_group.async(context.io, handleConnectionJob, .{job});
    }
}

fn handleConnectionJob(job: ConnectionJob) void {
    defer job.sema.post(job.io);
    handleConnection(job.gpa, job.io, job.store, job.stream) catch |err| {
        std.debug.print("connection error: {s}\n", .{@errorName(err)});
    };
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

test "parse serve concurrency options" {
    {
        const options = try parseServeOptions(&.{});
        try std.testing.expectEqualStrings(default_db_path, options.db_path);
        try std.testing.expectEqual(@as(usize, default_concurrency), options.concurrency);
    }
    {
        const options = try parseServeOptions(&.{ "--concurrency", "4" });
        try std.testing.expectEqualStrings(default_db_path, options.db_path);
        try std.testing.expectEqual(@as(usize, 4), options.concurrency);
    }
    {
        const options = try parseServeOptions(&.{ "/tmp/custom.db", "--concurrency=8" });
        try std.testing.expectEqualStrings("/tmp/custom.db", options.db_path);
        try std.testing.expectEqual(@as(usize, 8), options.concurrency);
    }
    {
        const options = try parseServeOptions(&.{ "--concurrency", "128" });
        try std.testing.expectEqual(@as(usize, 128), options.concurrency);
    }
}

test "parse serve rejects invalid concurrency" {
    try std.testing.expectError(error.InvalidConcurrency, parseServeOptions(&.{ "--concurrency", "0" }));
    try std.testing.expectError(error.MissingConcurrency, parseServeOptions(&.{"--concurrency"}));
}
