const std = @import("std");
const anyline = @import("anyline");

const default_url = "http://127.0.0.1:7687/";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (args.len > 1) {
        const query = try std.mem.join(gpa, " ", args[1..]);
        defer gpa.free(query);
        try sendQuery(gpa, io, stdout, default_url, query);
        try stdout.flush();
        return;
    }

    try stdout.print("Connected to {s}\n", .{default_url});

    anyline.history.usingHistory();
    defer anyline.freeHistory(gpa);
    defer anyline.freeKillRing(gpa);

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

        sendQuery(gpa, io, stdout, default_url, trimmed) catch |err| {
            try stdout.print("error: {s}\n", .{@errorName(err)});
            try stdout.flush();
            continue;
        };
        try stdout.flush();
    }
    try stdout.flush();
}

fn sendQuery(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, base_url: []const u8, gql: []const u8) !void {
    const url = try queryUrl(gpa, base_url, gql);
    defer gpa.free(url);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    if (response.status != .ok) {
        try stdout.print("HTTP {d}: {s}\n", .{ @intFromEnum(response.status), body.written() });
        return;
    }
    try stdout.writeAll(body.written());
    try stdout.writeByte('\n');
}

fn queryUrl(gpa: std.mem.Allocator, base_url: []const u8, gql: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(base_url);
    if (std.mem.indexOfScalar(u8, base_url, '?') == null) {
        try out.writer.writeAll("?query=");
    } else {
        try out.writer.writeAll("&query=");
    }
    try (std.Uri.Component{ .raw = gql }).formatQuery(&out.writer);
    return try out.toOwnedSlice();
}

test "query URL encodes GQL" {
    const url = try queryUrl(std.testing.allocator, default_url, "RETURN 100 * 3");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:7687/?query=RETURN%20100%20*%203", url);
}
