//! Minimal Bolt protocol support for Graphon sessions.
//!
//! Supported:
//! * Bolt 5.0 and 4.4 negotiation, including manifest v1.
//! * `HELLO`, `RUN`, `PULL`, `BEGIN`, `COMMIT`, `ROLLBACK`, `RESET`, and `GOODBYE`.
//! * Graphon GQL execution through `RUN` and PackStream `RECORD` rows via `PULL`.
//! * Scalar values plus node/edge values encoded as plain PackStream maps.
//!
//! Unsupported:
//! * TLS, authentication, routing, and parameter binding.
//! * Neo4j `Node`/`Relationship` structures; graph values are map-shaped.
//! * Cypher compatibility beyond Graphon's currently supported GQL syntax.

const std = @import("std");
const Allocator = std.mem.Allocator;

const query = @import("query.zig");
const storage = @import("storage.zig");
const types = @import("types.zig");

const magic = [_]u8{ 0x60, 0x60, 0xb0, 0x17 };
const manifest_v1 = BoltVersion{ .major = 0xff, .minor = 1 };
const bolt_5_0 = BoltVersion.exact(5, 0);
const bolt_4_4 = BoltVersion.exact(4, 4);
const supported_versions = [_]BoltVersion{ bolt_5_0, bolt_4_4 };
const max_message_size = 16 * 1024 * 1024;

const BoltVersion = packed struct(u32) {
    major: u8,
    minor: u8,
    range: u8 = 0,
    reserved: u8 = 0,

    fn exact(major: u8, minor: u8) BoltVersion {
        return .{ .major = major, .minor = minor };
    }

    fn fromInt(value: u32) BoltVersion {
        return @bitCast(value);
    }

    fn toInt(self: BoltVersion) u32 {
        return @bitCast(self);
    }

    fn supports(self: BoltVersion, version: BoltVersion) bool {
        if (self.major != version.major) return false;
        if (version.minor > self.minor) return false;
        return self.minor - version.minor <= self.range;
    }
};

const Tag = struct {
    const hello: u8 = 0x01;
    const goodbye: u8 = 0x02;
    const reset: u8 = 0x0f;
    const run: u8 = 0x10;
    const begin: u8 = 0x11;
    const commit: u8 = 0x12;
    const rollback: u8 = 0x13;
    const pull: u8 = 0x3f;
    const success: u8 = 0x70;
    const record: u8 = 0x71;
    const ignored: u8 = 0x7e;
    const failure: u8 = 0x7f;
};

pub const Error = std.Io.Reader.Error || std.Io.Writer.Error || Allocator.Error || query.Error || error{
    InvalidHandshake,
    InvalidMessage,
    MessageTooLarge,
    NoOpenTransaction,
    TransactionAlreadyOpen,
    UnsupportedBoltVersion,
};

pub fn isHandshake(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], &magic);
}

pub fn handleSession(
    gpa: Allocator,
    store: storage.Storage,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) Error!void {
    const version = try negotiate(reader, writer);
    _ = version;

    var session = Session{ .gpa = gpa, .store = store };
    defer session.deinit();

    while (true) {
        const payload = readMessage(gpa, reader) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer gpa.free(payload);

        var request = parseRequest(gpa, payload) catch |err| {
            try session.fail(writer, @errorName(err));
            continue;
        };
        defer request.deinit(gpa);

        if (!try session.handle(writer, request)) return;
    }
}

const Request = union(enum) {
    hello,
    goodbye,
    reset,
    run: []u8,
    pull: i64,
    begin,
    commit,
    rollback,

    fn deinit(self: *Request, gpa: Allocator) void {
        switch (self.*) {
            .run => |query_text| gpa.free(query_text),
            else => {},
        }
        self.* = undefined;
    }
};

const Session = struct {
    gpa: Allocator,
    store: storage.Storage,
    pending: ?query.ResultSet = null,
    txn: ?storage.Transaction = null,
    row_i: usize = 0,
    failed: bool = false,

    fn deinit(self: *Session) void {
        self.clearPending();
        if (self.txn) |txn| {
            txn.rollback() catch {};
            txn.close();
        }
        self.* = undefined;
    }

    fn handle(self: *Session, writer: *std.Io.Writer, request: Request) Error!bool {
        if (self.failed) {
            switch (request) {
                .reset => {
                    self.failed = false;
                    self.clearPending();
                    self.rollbackTransaction() catch {};
                    try writeEmptySuccess(self.gpa, writer);
                },
                .goodbye => return false,
                else => try writeIgnored(self.gpa, writer),
            }
            return true;
        }

        switch (request) {
            .hello => try writeHelloSuccess(self.gpa, writer),
            .goodbye => return false,
            .reset => {
                self.clearPending();
                self.rollbackTransaction() catch {};
                try writeEmptySuccess(self.gpa, writer);
            },
            .run => |source| try self.run(writer, source),
            .pull => |n| try self.pull(writer, n),
            .begin => try self.begin(writer),
            .commit => try self.commit(writer),
            .rollback => try self.rollback(writer),
        }
        return true;
    }

    fn begin(self: *Session, writer: *std.Io.Writer) Error!void {
        self.clearPending();
        if (self.txn != null) {
            try self.fail(writer, @errorName(error.TransactionAlreadyOpen));
            return;
        }
        self.txn = self.store.txn();
        try writeEmptySuccess(self.gpa, writer);
    }

    fn commit(self: *Session, writer: *std.Io.Writer) Error!void {
        self.clearPending();
        var txn = self.takeTransaction() catch |err| {
            try self.fail(writer, @errorName(err));
            return;
        };
        defer txn.close();
        txn.commit() catch |err| {
            try self.fail(writer, @errorName(err));
            return;
        };
        try writeEmptySuccess(self.gpa, writer);
    }

    fn rollback(self: *Session, writer: *std.Io.Writer) Error!void {
        self.clearPending();
        self.rollbackTransaction() catch |err| {
            try self.fail(writer, @errorName(err));
            return;
        };
        try writeEmptySuccess(self.gpa, writer);
    }

    fn run(self: *Session, writer: *std.Io.Writer, source: []const u8) Error!void {
        self.clearPending();
        const source_z = try self.gpa.dupeZ(u8, source);
        defer self.gpa.free(source_z);

        var prepared = query.prepare(self.gpa, source_z) catch |err| {
            try self.fail(writer, @errorName(err));
            return;
        };
        defer prepared.deinit(self.gpa);

        if (prepared.takeParseErrors()) |errors| {
            var parse_errors = errors;
            defer parse_errors.deinit(self.gpa);
            var diagnostics = std.Io.Writer.Allocating.init(self.gpa);
            defer diagnostics.deinit();
            try parse_errors.render(&diagnostics.writer);
            try self.fail(writer, diagnostics.written());
            return;
        }

        var result = (if (self.txn) |txn|
            query.execute(self.gpa, txn, &prepared)
        else
            executePrepared(self.gpa, self.store, &prepared)) catch |err| {
            try self.fail(writer, @errorName(err));
            return;
        };
        errdefer result.deinit(self.gpa);

        try writeRunSuccess(self.gpa, writer, result.columns);
        self.pending = result;
        self.row_i = 0;
    }

    fn pull(self: *Session, writer: *std.Io.Writer, n: i64) Error!void {
        const result = &(self.pending orelse {
            try self.fail(writer, "no pending result");
            return;
        });

        const max_rows: usize = if (n < 0) std.math.maxInt(usize) else @intCast(n);
        var sent: usize = 0;
        while (self.row_i < result.rows.len and sent < max_rows) : (sent += 1) {
            try writeRecord(self.gpa, writer, result.rows[self.row_i]);
            self.row_i += 1;
        }

        const has_more = self.row_i < result.rows.len;
        try writePullSuccess(self.gpa, writer, has_more);
        if (!has_more) self.clearPending();
    }

    fn fail(self: *Session, writer: *std.Io.Writer, message: []const u8) Error!void {
        self.failed = true;
        self.clearPending();
        try writeFailure(self.gpa, writer, message);
    }

    fn clearPending(self: *Session) void {
        if (self.pending) |*result| result.deinit(self.gpa);
        self.pending = null;
        self.row_i = 0;
    }

    fn rollbackTransaction(self: *Session) Error!void {
        var txn = try self.takeTransaction();
        defer txn.close();
        try txn.rollback();
    }

    fn takeTransaction(self: *Session) Error!storage.Transaction {
        const txn = self.txn orelse return error.NoOpenTransaction;
        self.txn = null;
        return txn;
    }
};

fn executePrepared(
    gpa: Allocator,
    store: storage.Storage,
    prepared: *const query.CompiledProgram,
) query.Error!query.ResultSet {
    const txn = store.txn();
    defer txn.close();
    errdefer txn.rollback() catch {};

    var result = try query.execute(gpa, txn, prepared);
    errdefer result.deinit(gpa);
    try txn.commit();
    return result;
}

fn negotiate(reader: *std.Io.Reader, writer: *std.Io.Writer) Error!BoltVersion {
    const got_magic = try reader.takeArray(4);
    if (!std.mem.eql(u8, got_magic, &magic)) return error.InvalidHandshake;

    var proposals: [4]BoltVersion = undefined;
    var uses_manifest = false;
    for (&proposals) |*proposal| {
        proposal.* = BoltVersion.fromInt(try reader.takeInt(u32, .big));
        uses_manifest = uses_manifest or proposal.toInt() == manifest_v1.toInt();
    }

    if (uses_manifest) {
        try writer.writeInt(u32, manifest_v1.toInt(), .big);
        try writeVarInt(writer, supported_versions.len);
        for (supported_versions) |version| {
            try writer.writeInt(u32, version.toInt(), .big);
        }
        try writeVarInt(writer, 0);
        try writer.flush();

        const chosen = BoltVersion.fromInt(try reader.takeInt(u32, .big));
        _ = try readVarInt(reader);
        if (!isSupportedVersion(chosen)) return error.UnsupportedBoltVersion;
        return chosen;
    }

    const chosen = chooseVersion(proposals) orelse {
        try writer.writeInt(u32, 0, .big);
        try writer.flush();
        return error.UnsupportedBoltVersion;
    };
    try writer.writeInt(u32, chosen.toInt(), .big);
    try writer.flush();
    return chosen;
}

fn chooseVersion(proposals: [4]BoltVersion) ?BoltVersion {
    for (proposals) |proposal| {
        for (supported_versions) |version| {
            if (proposal.supports(version)) return version;
        }
    }
    return null;
}

fn isSupportedVersion(version: BoltVersion) bool {
    for (supported_versions) |supported| {
        if (version.toInt() == supported.toInt()) return true;
    }
    return false;
}

fn readMessage(gpa: Allocator, reader: *std.Io.Reader) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    while (true) {
        const chunk_len = try reader.takeInt(u16, .big);
        if (chunk_len == 0) {
            if (out.written().len == 0) continue;
            return try out.toOwnedSlice();
        }
        if (out.written().len + chunk_len > max_message_size) return error.MessageTooLarge;
        try out.writer.writeAll(try reader.take(chunk_len));
    }
}

fn writeMessage(writer: *std.Io.Writer, payload: []const u8) Error!void {
    var remaining = payload;
    while (remaining.len > 0) {
        const chunk_len = @min(remaining.len, std.math.maxInt(u16));
        try writer.writeInt(u16, @intCast(chunk_len), .big);
        try writer.writeAll(remaining[0..chunk_len]);
        remaining = remaining[chunk_len..];
    }
    try writer.writeInt(u16, 0, .big);
    try writer.flush();
}

fn parseRequest(gpa: Allocator, payload: []const u8) Error!Request {
    var fixed = std.Io.Reader.fixed(payload);
    var pack = PackReader{ .reader = &fixed };
    const header = try pack.readStructHeader();
    return switch (header.tag) {
        Tag.hello => blk: {
            if (header.fields != 1) return error.InvalidMessage;
            try pack.skipValue();
            break :blk .hello;
        },
        Tag.goodbye => blk: {
            if (header.fields != 0) return error.InvalidMessage;
            break :blk .goodbye;
        },
        Tag.reset => blk: {
            if (header.fields != 0) return error.InvalidMessage;
            break :blk .reset;
        },
        Tag.run => blk: {
            if (header.fields != 2 and header.fields != 3) return error.InvalidMessage;
            const query_text = try pack.readStringAlloc(gpa);
            errdefer gpa.free(query_text);
            try pack.skipValue();
            if (header.fields == 3) try pack.skipValue();
            break :blk .{ .run = query_text };
        },
        Tag.pull => blk: {
            if (header.fields != 1) return error.InvalidMessage;
            break :blk .{ .pull = try pack.readPullN(gpa) };
        },
        Tag.begin => blk: {
            if (header.fields != 1) return error.InvalidMessage;
            try pack.skipValue();
            break :blk .begin;
        },
        Tag.commit => blk: {
            if (header.fields != 0) return error.InvalidMessage;
            break :blk .commit;
        },
        Tag.rollback => blk: {
            if (header.fields != 0) return error.InvalidMessage;
            break :blk .rollback;
        },
        else => error.InvalidMessage,
    };
}

fn writeHelloSuccess(gpa: Allocator, writer: *std.Io.Writer) Error!void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    var pack = PackWriter{ .writer = &payload.writer };
    try pack.writeStructHeader(1, Tag.success);
    try pack.writeMapHeader(2);
    try pack.writeString("server");
    try pack.writeString("Graphon/0.0");
    try pack.writeString("connection_id");
    try pack.writeString("graphon-0");
    try writeMessage(writer, payload.written());
}

fn writeRunSuccess(gpa: Allocator, writer: *std.Io.Writer, columns: []const []u8) Error!void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    var pack = PackWriter{ .writer = &payload.writer };
    try pack.writeStructHeader(1, Tag.success);
    try pack.writeMapHeader(2);
    try pack.writeString("fields");
    try pack.writeListHeader(columns.len);
    for (columns) |column| try pack.writeString(column);
    try pack.writeString("t_first");
    try pack.writeInt(0);
    try writeMessage(writer, payload.written());
}

fn writePullSuccess(gpa: Allocator, writer: *std.Io.Writer, has_more: bool) Error!void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    var pack = PackWriter{ .writer = &payload.writer };
    try pack.writeStructHeader(1, Tag.success);
    try pack.writeMapHeader(2);
    try pack.writeString("has_more");
    try pack.writeBool(has_more);
    try pack.writeString("t_last");
    try pack.writeInt(0);
    try writeMessage(writer, payload.written());
}

fn writeEmptySuccess(gpa: Allocator, writer: *std.Io.Writer) Error!void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    var pack = PackWriter{ .writer = &payload.writer };
    try pack.writeStructHeader(1, Tag.success);
    try pack.writeMapHeader(0);
    try writeMessage(writer, payload.written());
}

fn writeFailure(gpa: Allocator, writer: *std.Io.Writer, message: []const u8) Error!void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    var pack = PackWriter{ .writer = &payload.writer };
    try pack.writeStructHeader(1, Tag.failure);
    try pack.writeMapHeader(2);
    try pack.writeString("code");
    try pack.writeString("Graphon.ClientError");
    try pack.writeString("message");
    try pack.writeString(message);
    try writeMessage(writer, payload.written());
}

fn writeIgnored(gpa: Allocator, writer: *std.Io.Writer) Error!void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    var pack = PackWriter{ .writer = &payload.writer };
    try pack.writeStructHeader(0, Tag.ignored);
    try writeMessage(writer, payload.written());
}

fn writeRecord(gpa: Allocator, writer: *std.Io.Writer, row: query.Row) Error!void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    var pack = PackWriter{ .writer = &payload.writer };
    try pack.writeStructHeader(1, Tag.record);
    try pack.writeListHeader(row.values.len);
    for (row.values) |value| try pack.writeResultValue(value);
    try writeMessage(writer, payload.written());
}

fn writeVarInt(writer: *std.Io.Writer, value: u64) Error!void {
    var rest = value;
    while (rest >= 0x80) {
        try writer.writeByte(@intCast((rest & 0x7f) | 0x80));
        rest >>= 7;
    }
    try writer.writeByte(@intCast(rest));
}

fn readVarInt(reader: *std.Io.Reader) Error!u64 {
    var shift: u6 = 0;
    var value: u64 = 0;
    while (true) {
        const byte = try reader.takeByte();
        value |= (@as(u64, byte & 0x7f) << shift);
        if (byte & 0x80 == 0) return value;
        shift += 7;
        if (shift >= 63) return error.InvalidMessage;
    }
}

const PackReader = struct {
    reader: *std.Io.Reader,

    const StructHeader = struct {
        fields: usize,
        tag: u8,
    };

    fn readStructHeader(self: *PackReader) Error!StructHeader {
        const marker = try self.reader.takeByte();
        if (marker & 0xf0 != 0xb0) return error.InvalidMessage;
        return .{ .fields = marker & 0x0f, .tag = try self.reader.takeByte() };
    }

    fn readStringAlloc(self: *PackReader, gpa: Allocator) Error![]u8 {
        const len = try self.readStringLen();
        return try gpa.dupe(u8, try self.reader.take(len));
    }

    fn readPullN(self: *PackReader, gpa: Allocator) Error!i64 {
        const fields = try self.readMapHeader();
        var n: i64 = -1;
        for (0..fields) |_| {
            const key = try self.readStringAlloc(gpa);
            defer gpa.free(key);
            if (std.mem.eql(u8, key, "n")) {
                n = try self.readInt();
            } else {
                try self.skipValue();
            }
        }
        return n;
    }

    fn skipValue(self: *PackReader) Error!void {
        const marker = try self.reader.takeByte();
        switch (marker) {
            0x00...0x7f, 0xf0...0xff, 0xc0, 0xc2, 0xc3 => return,
            0xc1 => try self.reader.discardAll(8),
            0xc8 => try self.reader.discardAll(1),
            0xc9 => try self.reader.discardAll(2),
            0xca => try self.reader.discardAll(4),
            0xcb => try self.reader.discardAll(8),
            0xcc, 0xd0 => try self.reader.discardAll(try self.reader.takeInt(u8, .big)),
            0xcd, 0xd1 => try self.reader.discardAll(try self.reader.takeInt(u16, .big)),
            0xce, 0xd2 => try self.reader.discardAll(try self.reader.takeInt(u32, .big)),
            0xd4 => try self.skipListItems(try self.reader.takeInt(u8, .big)),
            0xd5 => try self.skipListItems(try self.reader.takeInt(u16, .big)),
            0xd6 => try self.skipListItems(try self.reader.takeInt(u32, .big)),
            0xd8 => try self.skipMapItems(try self.reader.takeInt(u8, .big)),
            0xd9 => try self.skipMapItems(try self.reader.takeInt(u16, .big)),
            0xda => try self.skipMapItems(try self.reader.takeInt(u32, .big)),
            0xdc => {
                const fields = try self.reader.takeInt(u8, .big);
                _ = try self.reader.takeByte();
                try self.skipListItems(fields);
            },
            0xdd => {
                const fields = try self.reader.takeInt(u16, .big);
                _ = try self.reader.takeByte();
                try self.skipListItems(fields);
            },
            0x80...0x8f => try self.reader.discardAll(marker & 0x0f),
            0x90...0x9f => try self.skipListItems(marker & 0x0f),
            0xa0...0xaf => try self.skipMapItems(marker & 0x0f),
            0xb0...0xbf => {
                _ = try self.reader.takeByte();
                try self.skipListItems(marker & 0x0f);
            },
            else => return error.InvalidMessage,
        }
    }

    fn readInt(self: *PackReader) Error!i64 {
        const marker = try self.reader.takeByte();
        return switch (marker) {
            0x00...0x7f => marker,
            0xf0...0xff => @as(i8, @bitCast(marker)),
            0xc8 => try self.reader.takeInt(i8, .big),
            0xc9 => try self.reader.takeInt(i16, .big),
            0xca => try self.reader.takeInt(i32, .big),
            0xcb => try self.reader.takeInt(i64, .big),
            else => error.InvalidMessage,
        };
    }

    fn readStringLen(self: *PackReader) Error!usize {
        const marker = try self.reader.takeByte();
        return switch (marker) {
            0x80...0x8f => marker & 0x0f,
            0xd0 => try self.reader.takeInt(u8, .big),
            0xd1 => try self.reader.takeInt(u16, .big),
            0xd2 => try self.reader.takeInt(u32, .big),
            else => error.InvalidMessage,
        };
    }

    fn readMapHeader(self: *PackReader) Error!usize {
        const marker = try self.reader.takeByte();
        return switch (marker) {
            0xa0...0xaf => marker & 0x0f,
            0xd8 => try self.reader.takeInt(u8, .big),
            0xd9 => try self.reader.takeInt(u16, .big),
            0xda => try self.reader.takeInt(u32, .big),
            else => error.InvalidMessage,
        };
    }

    fn skipListItems(self: *PackReader, count: usize) Error!void {
        for (0..count) |_| try self.skipValue();
    }

    fn skipMapItems(self: *PackReader, count: usize) Error!void {
        for (0..count) |_| {
            try self.skipValue();
            try self.skipValue();
        }
    }
};

const PackWriter = struct {
    writer: *std.Io.Writer,

    fn writeStructHeader(self: *PackWriter, fields: usize, tag: u8) Error!void {
        if (fields > 15) return error.InvalidMessage;
        try self.writer.writeByte(0xb0 | @as(u8, @intCast(fields)));
        try self.writer.writeByte(tag);
    }

    fn writeResultValue(self: *PackWriter, value: query.ResultValue) Error!void {
        switch (value) {
            .value => |result_value| try self.writeScalar(result_value),
            .node => |node| try self.writeNode(node),
            .edge => |edge| try self.writeEdge(edge),
        }
    }

    fn writeScalar(self: *PackWriter, value: types.Value) Error!void {
        switch (value) {
            .string => |s| try self.writeString(s),
            .int64 => |n| try self.writeInt(n),
            .float64 => |f| try self.writeFloat(f),
            .bool => |b| try self.writeBool(b),
            .null => try self.writeNull(),
            .node_ref, .edge_ref, .id => |id| {
                const encoded = id.toString();
                try self.writeString(encoded[0..]);
            },
            .list => |items| {
                try self.writeListHeader(items.len);
                for (items) |item| try self.writeScalar(item);
            },
        }
    }

    fn writeNode(self: *PackWriter, node: types.Node) Error!void {
        try self.writeMapHeader(3);
        try self.writeString("id");
        const id = node.id.toString();
        try self.writeString(id[0..]);
        try self.writeString("labels");
        try self.writeStringList(node.labels.keys());
        try self.writeString("properties");
        try self.writeProperties(node.properties);
    }

    fn writeEdge(self: *PackWriter, edge: types.Edge) Error!void {
        try self.writeMapHeader(6);
        try self.writeString("id");
        const id = edge.id.toString();
        try self.writeString(id[0..]);
        try self.writeString("start");
        const start = edge.endpoints[0].toString();
        try self.writeString(start[0..]);
        try self.writeString("end");
        const end = edge.endpoints[1].toString();
        try self.writeString(end[0..]);
        try self.writeString("directed");
        try self.writeBool(edge.directed);
        try self.writeString("labels");
        try self.writeStringList(edge.labels.keys());
        try self.writeString("properties");
        try self.writeProperties(edge.properties);
    }

    fn writeProperties(self: *PackWriter, properties: std.array_hash_map.String(types.Value)) Error!void {
        try self.writeMapHeader(properties.count());
        var it = properties.iterator();
        while (it.next()) |entry| {
            try self.writeString(entry.key_ptr.*);
            try self.writeScalar(entry.value_ptr.*);
        }
    }

    fn writeStringList(self: *PackWriter, values: []const []const u8) Error!void {
        try self.writeListHeader(values.len);
        for (values) |value| try self.writeString(value);
    }

    fn writeNull(self: *PackWriter) Error!void {
        try self.writer.writeByte(0xc0);
    }

    fn writeBool(self: *PackWriter, value: bool) Error!void {
        try self.writer.writeByte(if (value) 0xc3 else 0xc2);
    }

    fn writeInt(self: *PackWriter, value: i64) Error!void {
        if (value >= -16 and value < 128) {
            try self.writer.writeByte(@bitCast(@as(i8, @intCast(value))));
        } else if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) {
            try self.writer.writeByte(0xc8);
            try self.writer.writeInt(i8, @intCast(value), .big);
        } else if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
            try self.writer.writeByte(0xc9);
            try self.writer.writeInt(i16, @intCast(value), .big);
        } else if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
            try self.writer.writeByte(0xca);
            try self.writer.writeInt(i32, @intCast(value), .big);
        } else {
            try self.writer.writeByte(0xcb);
            try self.writer.writeInt(i64, value, .big);
        }
    }

    fn writeFloat(self: *PackWriter, value: f64) Error!void {
        try self.writer.writeByte(0xc1);
        try self.writer.writeInt(u64, @bitCast(value), .big);
    }

    fn writeString(self: *PackWriter, value: []const u8) Error!void {
        try self.writeStringHeader(value.len);
        try self.writer.writeAll(value);
    }

    fn writeStringHeader(self: *PackWriter, len: usize) Error!void {
        if (len < 16) {
            try self.writer.writeByte(0x80 | @as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u8)) {
            try self.writer.writeByte(0xd0);
            try self.writer.writeInt(u8, @intCast(len), .big);
        } else if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xd1);
            try self.writer.writeInt(u16, @intCast(len), .big);
        } else {
            try self.writer.writeByte(0xd2);
            try self.writer.writeInt(u32, @intCast(len), .big);
        }
    }

    fn writeListHeader(self: *PackWriter, len: usize) Error!void {
        if (len < 16) {
            try self.writer.writeByte(0x90 | @as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u8)) {
            try self.writer.writeByte(0xd4);
            try self.writer.writeInt(u8, @intCast(len), .big);
        } else if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xd5);
            try self.writer.writeInt(u16, @intCast(len), .big);
        } else {
            try self.writer.writeByte(0xd6);
            try self.writer.writeInt(u32, @intCast(len), .big);
        }
    }

    fn writeMapHeader(self: *PackWriter, len: usize) Error!void {
        if (len < 16) {
            try self.writer.writeByte(0xa0 | @as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u8)) {
            try self.writer.writeByte(0xd8);
            try self.writer.writeInt(u8, @intCast(len), .big);
        } else if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xd9);
            try self.writer.writeInt(u16, @intCast(len), .big);
        } else {
            try self.writer.writeByte(0xda);
            try self.writer.writeInt(u32, @intCast(len), .big);
        }
    }
};

test "bolt handshake selects exact v5" {
    const bytes = [_]u8{
        0x60, 0x60, 0xb0, 0x17,
        0x00, 0x00, 0x00, 0x05,
        0x00, 0x00, 0x04, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var reader = std.Io.Reader.fixed(&bytes);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(bolt_5_0, try negotiate(&reader, &out.writer));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x05 }, out.written());
}

test "bolt handshake supports manifest v1" {
    const bytes = [_]u8{
        0x60, 0x60, 0xb0, 0x17,
        0x00, 0x00, 0x01, 0xff,
        0x00, 0x00, 0x04, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x05,
        0x00,
    };
    var reader = std.Io.Reader.fixed(&bytes);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(bolt_5_0, try negotiate(&reader, &out.writer));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x01, 0xff,
        0x02, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x04,
        0x04, 0x00,
    }, out.written());
}

test "bolt message chunk reader combines chunks" {
    const bytes = [_]u8{
        0x00, 0x02, 0xb1, 0x3f,
        0x00, 0x01, 0xa0, 0x00,
        0x00,
    };
    var reader = std.Io.Reader.fixed(&bytes);
    const payload = try readMessage(std.testing.allocator, &reader);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xb1, 0x3f, 0xa0 }, payload);
}

test "bolt parses run request" {
    const payload = [_]u8{
        0xb3, 0x10,
        0x8d, 'R',
        'E',  'T',
        'U',  'R',
        'N',  ' ',
        '1',  ' ',
        'A',  'S',
        ' ',  'n',
        0xa0, 0xa0,
    };
    var request = try parseRequest(std.testing.allocator, &payload);
    defer request.deinit(std.testing.allocator);
    try std.testing.expect(request == .run);
    try std.testing.expectEqualStrings("RETURN 1 AS n", request.run);
}

test "bolt writes scalar record message" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const values = [_]query.ResultValue{.{ .value = .{ .int64 = 55 } }};
    try writeRecord(std.testing.allocator, &out.writer, .{ .values = @constCast(values[0..]) });
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x04,
        0xb1, 0x71,
        0x91, 0x37,
        0x00, 0x00,
    }, out.written());
}

test "bolt session executes return query" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("bolt.db");
    defer store.db.close();

    var input: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer input.deinit();
    try input.writer.writeAll(&[_]u8{
        0x60, 0x60, 0xb0, 0x17,
        0x00, 0x00, 0x00, 0x05,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    });
    try writeTestMessage(&input.writer, &[_]u8{ 0xb1, 0x01, 0xa0 });
    try writeTestMessage(&input.writer, &[_]u8{
        0xb3, 0x10,
        0x8e, 'R',
        'E',  'T',
        'U',  'R',
        'N',  ' ',
        '5',  '5',
        ' ',  'A',
        'S',  ' ',
        'n',  0xa0,
        0xa0,
    });
    try writeTestMessage(&input.writer, &[_]u8{ 0xb1, 0x3f, 0xa1, 0x81, 'n', 0xff });
    try writeTestMessage(&input.writer, &[_]u8{ 0xb0, 0x02 });

    var reader = std.Io.Reader.fixed(input.written());
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try handleSession(std.testing.allocator, store, &reader, &output.writer);

    try std.testing.expect(std.mem.startsWith(u8, output.written(), &[_]u8{ 0x00, 0x00, 0x00, 0x05 }));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), &[_]u8{ 0xb1, 0x71, 0x91, 0x37 }) != null);
}

test "bolt explicit transactions preserve snapshot isolation across sessions" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("bolt-snapshot.db");
    defer store.db.close();

    var session_a = Session{ .gpa = std.testing.allocator, .store = store };
    defer session_a.deinit();
    var session_b = Session{ .gpa = std.testing.allocator, .store = store };
    defer session_b.deinit();
    var session_c = Session{ .gpa = std.testing.allocator, .store = store };
    defer session_c.deinit();

    var out_a: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_a.deinit();
    var out_b: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_b.deinit();
    var out_c: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_c.deinit();

    try handleTestPayload(&session_a, &out_a.writer, &[_]u8{ 0xb1, Tag.begin, 0xa0 });

    try handleTestPayload(&session_b, &out_b.writer, &[_]u8{ 0xb1, Tag.begin, 0xa0 });
    try handleTestRunAndPull(&session_b, &out_b.writer, "INSERT (:SnapshotNode {name: 'committed-on-b'})");
    try handleTestPayload(&session_b, &out_b.writer, &[_]u8{ 0xb0, Tag.commit });

    try handleTestRunAndPull(&session_a, &out_a.writer, "MATCH (n:SnapshotNode) RETURN COUNT(n) AS count");
    try expectBoltRecordInt(out_a.written(), 0);
    try handleTestPayload(&session_a, &out_a.writer, &[_]u8{ 0xb0, Tag.rollback });

    try handleTestRunAndPull(&session_c, &out_c.writer, "MATCH (n:SnapshotNode) RETURN COUNT(n) AS count");
    try expectBoltRecordInt(out_c.written(), 1);
}

fn writeTestMessage(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.writeInt(u16, @intCast(payload.len), .big);
    try writer.writeAll(payload);
    try writer.writeInt(u16, 0, .big);
}

fn handleTestRunAndPull(session: *Session, writer: *std.Io.Writer, source: []const u8) !void {
    var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();
    var pack = PackWriter{ .writer = &payload.writer };
    try pack.writeStructHeader(3, Tag.run);
    try pack.writeString(source);
    try pack.writeMapHeader(0);
    try pack.writeMapHeader(0);
    try handleTestPayload(session, writer, payload.written());
    try handleTestPayload(session, writer, &[_]u8{ 0xb1, Tag.pull, 0xa1, 0x81, 'n', 0xff });
}

fn handleTestPayload(session: *Session, writer: *std.Io.Writer, payload: []const u8) !void {
    var request = try parseRequest(std.testing.allocator, payload);
    defer request.deinit(std.testing.allocator);
    try std.testing.expect(try session.handle(writer, request));
}

fn expectBoltRecordInt(output: []const u8, value: u8) !void {
    const needle = [_]u8{ 0xb1, Tag.record, 0x91, value };
    try std.testing.expect(std.mem.indexOf(u8, output, &needle) != null);
}
