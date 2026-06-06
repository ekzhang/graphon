const std = @import("std");

const default_url = "http://127.0.0.1:7687/";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (args.len > 1) {
        const query = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(query);
        try sendQuery(allocator, init.io, stdout, default_url, query);
        try stdout.flush();
        return;
    }

    try stdout.print("Connected to {s}\n", .{default_url});
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    while (true) {
        try stdout.writeAll("> ");
        try stdout.flush();
        const line = (try stdin.takeDelimiter('\n')) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":exit")) break;
        sendQuery(allocator, init.io, stdout, default_url, trimmed) catch |err| {
            try stdout.print("error: {s}\n", .{@errorName(err)});
            continue;
        };
    }
    try stdout.flush();
}

fn sendQuery(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, base_url: []const u8, gql: []const u8) !void {
    const url = try queryUrl(allocator, base_url, gql);
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(allocator);
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

fn queryUrl(allocator: std.mem.Allocator, base_url: []const u8, gql: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(base_url);
    if (std.mem.indexOfScalar(u8, base_url, '?') == null) {
        try out.writer.writeAll("?query=");
    } else {
        try out.writer.writeAll("&query=");
    }
    try percentEncode(&out.writer, gql);
    return try out.toOwnedSlice();
}

fn percentEncode(writer: *std.Io.Writer, input: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if ((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~')
        {
            try writer.writeByte(c);
        } else if (c == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[c >> 4]);
            try writer.writeByte(hex[c & 0x0f]);
        }
    }
}

test "query URL encodes GQL" {
    const url = try queryUrl(std.testing.allocator, default_url, "RETURN 100 * 3");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:7687/?query=RETURN+100+%2A+3", url);
}
