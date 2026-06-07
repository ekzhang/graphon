//! Pull-based execution for compiled query plans plus materialized result sets.

const std = @import("std");
const Allocator = std.mem.Allocator;

const planner = @import("planner.zig");
const storage = @import("../storage.zig");
const types = @import("../types.zig");
const ElementId = types.ElementId;
const Value = types.Value;
const Plan = @import("../Plan.zig");
const executor = @import("../executor.zig");

pub const Error = executor.Error || storage.Error || Allocator.Error || error{WrongResultKind};

pub const ResultSet = struct {
    columns: []const []u8 = &.{},
    rows: []Row = &.{},
    rows_affected: ?usize = null,

    pub fn deinit(self: *ResultSet, allocator: Allocator) void {
        for (self.columns) |col| allocator.free(col);
        allocator.free(self.columns);
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = undefined;
    }

    pub fn writeJson(self: ResultSet, writer: *std.Io.Writer) !void {
        var json: std.json.Stringify = .{ .writer = writer, .options = .{} };

        if (self.rows_affected) |n| {
            try json.beginObject();
            try json.objectField("ok");
            try json.write(true);
            try json.objectField("rows_affected");
            try json.write(n);
            try json.endObject();
            return;
        }

        // Keep README examples nice: `RETURN 55` over HTTP responds with `55`.
        if (self.columns.len == 1 and self.rows.len == 1) {
            try writeJsonValue(&json, self.rows[0].values[0]);
            return;
        }

        try json.beginArray();
        for (self.rows) |row| {
            try json.beginObject();
            for (self.columns, 0..) |column, col_i| {
                try json.objectField(column);
                try writeJsonValue(&json, row.values[col_i]);
            }
            try json.endObject();
        }
        try json.endArray();
    }
};

pub const Row = struct {
    values: []ResultValue,

    pub fn deinit(self: *Row, allocator: Allocator) void {
        for (self.values) |*value| value.deinit(allocator);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub const ResultValue = union(enum) {
    scalar: Value,
    node: NodeObject,
    edge: EdgeObject,

    pub fn deinit(self: *ResultValue, allocator: Allocator) void {
        switch (self.*) {
            .scalar => |*value| value.deinit(allocator),
            .node => |*node| node.deinit(allocator),
            .edge => |*edge| edge.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const NodeObject = struct {
    id: ElementId,
    labels: [][]u8,
    properties: []ResultProperty,

    pub fn deinit(self: *NodeObject, allocator: Allocator) void {
        for (self.labels) |label| allocator.free(label);
        allocator.free(self.labels);
        for (self.properties) |*property| property.deinit(allocator);
        allocator.free(self.properties);
        self.* = undefined;
    }
};

pub const EdgeObject = struct {
    id: ElementId,
    endpoints: [2]ElementId,
    directed: bool,
    labels: [][]u8,
    properties: []ResultProperty,

    pub fn deinit(self: *EdgeObject, allocator: Allocator) void {
        for (self.labels) |label| allocator.free(label);
        allocator.free(self.labels);
        for (self.properties) |*property| property.deinit(allocator);
        allocator.free(self.properties);
        self.* = undefined;
    }
};

pub const ResultProperty = struct {
    key: []u8,
    value: Value,

    pub fn deinit(self: *ResultProperty, allocator: Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const StatementResultKind = enum {
    rows,
    mutation,
};

pub const StatementCursor = struct {
    result_allocator: Allocator,
    txn: storage.Transaction,
    inner: union(StatementResultKind) {
        rows: RowCursor,
        mutation: MutationCursor,
    },

    const RowCursor = struct {
        exec: executor.Executor,
        columns: []const planner.ResultColumn,
        done: bool = false,
    };

    const MutationCursor = struct {
        exec: executor.Executor,
        count: planner.MutationCount,
        rows: usize = 0,
        rows_affected: ?usize = null,
    };

    pub fn init(
        result_allocator: Allocator,
        txn: storage.Transaction,
        statement: *const planner.CompiledStatement,
    ) Error!StatementCursor {
        const exec = try executor.Executor.init(&statement.plan, txn);
        return .{
            .result_allocator = result_allocator,
            .txn = txn,
            .inner = switch (statement.result) {
                .rows => |result_columns| .{ .rows = .{ .exec = exec, .columns = result_columns } },
                .mutation => |count| .{ .mutation = .{ .exec = exec, .count = count } },
            },
        };
    }

    pub fn deinit(self: *StatementCursor) void {
        switch (self.inner) {
            .rows => |*rows| rows.exec.deinit(),
            .mutation => |*mutation| mutation.exec.deinit(),
        }
        self.* = undefined;
    }

    pub fn kind(self: StatementCursor) StatementResultKind {
        return std.meta.activeTag(self.inner);
    }

    pub fn columns(self: StatementCursor) []const planner.ResultColumn {
        return switch (self.inner) {
            .rows => |rows| rows.columns,
            .mutation => &.{},
        };
    }

    pub fn nextRow(self: *StatementCursor) Error!?Row {
        switch (self.inner) {
            .rows => |*rows| {
                if (rows.done) return null;

                var result = (try rows.exec.run()) orelse {
                    rows.done = true;
                    return null;
                };
                defer result.deinit(self.txn.allocator);
                return try rowFromCompiledResult(self.result_allocator, self.txn, result, rows.columns);
            },
            .mutation => return error.WrongResultKind,
        }
    }

    pub fn finishMutation(self: *StatementCursor) Error!usize {
        switch (self.inner) {
            .rows => return error.WrongResultKind,
            .mutation => |*mutation| {
                if (mutation.rows_affected) |rows_affected| return rows_affected;

                while (try mutation.exec.run()) |result_value| {
                    var result = result_value;
                    result.deinit(self.txn.allocator);
                    mutation.rows += 1;
                }

                const rows_affected = switch (mutation.count) {
                    .mutations => mutation.exec.mutations,
                    .rows => mutation.rows,
                };
                mutation.rows_affected = rows_affected;
                return rows_affected;
            },
        }
    }

    pub fn collect(self: *StatementCursor) Error!ResultSet {
        const allocator = self.result_allocator;
        switch (self.kind()) {
            .rows => {
                var rows = std.ArrayList(Row).empty;
                errdefer deinitRowList(&rows, allocator);
                while (try self.nextRow()) |row| {
                    var owned_row: ?Row = row;
                    errdefer if (owned_row) |*r| r.deinit(allocator);
                    try rows.append(allocator, owned_row.?);
                    owned_row = null;
                }

                const owned_rows = try rows.toOwnedSlice(allocator);
                rows = .empty;
                errdefer {
                    for (owned_rows) |*row| row.deinit(allocator);
                    allocator.free(owned_rows);
                }
                const names = try resultColumnNames(allocator, self.columns());
                errdefer {
                    for (names) |name| allocator.free(name);
                    allocator.free(names);
                }

                return .{
                    .columns = names,
                    .rows = owned_rows,
                    .rows_affected = null,
                };
            },
            .mutation => return mutationResult(try self.finishMutation()),
        }
    }
};

fn writeJsonValue(json: *std.json.Stringify, value: ResultValue) !void {
    switch (value) {
        .scalar => |scalar| try writeJsonScalar(json, scalar),
        .node => |node| try writeJsonNode(json, node),
        .edge => |edge| try writeJsonEdge(json, edge),
    }
}

fn writeJsonScalar(json: *std.json.Stringify, value: Value) !void {
    switch (value) {
        .string => |s| try json.write(s),
        .int64 => |n| try json.write(n),
        .float64 => |f| try json.write(f),
        .bool => |b| try json.write(b),
        .null => try json.write(null),
        .node_ref, .edge_ref, .id => |id| {
            const id_string = id.toString();
            try json.write(id_string[0..]);
        },
    }
}

fn writeJsonNode(json: *std.json.Stringify, node: NodeObject) !void {
    try json.beginObject();
    try json.objectField("id");
    const id = node.id.toString();
    try json.write(id[0..]);
    try json.objectField("labels");
    try json.write(node.labels);
    try json.objectField("properties");
    try writeJsonProperties(json, node.properties);
    try json.endObject();
}

fn writeJsonEdge(json: *std.json.Stringify, edge: EdgeObject) !void {
    try json.beginObject();
    try json.objectField("id");
    const id = edge.id.toString();
    try json.write(id[0..]);
    try json.objectField("start");
    const start = edge.endpoints[0].toString();
    try json.write(start[0..]);
    try json.objectField("end");
    const end = edge.endpoints[1].toString();
    try json.write(end[0..]);
    try json.objectField("directed");
    try json.write(edge.directed);
    try json.objectField("labels");
    try json.write(edge.labels);
    try json.objectField("properties");
    try writeJsonProperties(json, edge.properties);
    try json.endObject();
}

fn writeJsonProperties(json: *std.json.Stringify, properties: []const ResultProperty) !void {
    try json.beginObject();
    for (properties) |property| {
        try json.objectField(property.key);
        try writeJsonScalar(json, property.value);
    }
    try json.endObject();
}

pub fn executeCompiledStatement(
    result_allocator: Allocator,
    txn: storage.Transaction,
    statement: *const planner.CompiledStatement,
) Error!ResultSet {
    var cursor = try StatementCursor.init(result_allocator, txn, statement);
    defer cursor.deinit();
    return try cursor.collect();
}

fn mutationResult(rows_affected: usize) ResultSet {
    return .{ .columns = &.{}, .rows = &.{}, .rows_affected = rows_affected };
}

fn rowFromCompiledResult(
    allocator: Allocator,
    txn: storage.Transaction,
    result: executor.Result,
    columns: []const planner.ResultColumn,
) Error!Row {
    const values = try allocator.alloc(ResultValue, columns.len);
    errdefer allocator.free(values);
    for (values) |*value| value.* = .{ .scalar = .null };
    errdefer for (values) |*value| value.deinit(allocator);

    for (columns, result.values, 0..) |column, value, i| {
        const next_value = try resultValueFromCompiledValue(allocator, txn, column, value);
        values[i].deinit(allocator);
        values[i] = next_value;
    }
    return .{ .values = values };
}

fn resultValueFromCompiledValue(
    allocator: Allocator,
    txn: storage.Transaction,
    column: planner.ResultColumn,
    value: Value,
) Error!ResultValue {
    if (column.graph_value) {
        switch (value) {
            .node_ref => |id| {
                var node = try txn.getNode(id) orelse return .{ .scalar = .null };
                defer node.deinit(txn.allocator);
                return .{ .node = try nodeObjectFromNode(allocator, node) };
            },
            .edge_ref => |id| {
                var edge = try txn.getEdge(id) orelse return .{ .scalar = .null };
                defer edge.deinit(txn.allocator);
                return .{ .edge = try edgeObjectFromEdge(allocator, edge) };
            },
            else => {},
        }
    }
    return .{ .scalar = try value.dupe(allocator) };
}

// ----------------------------- Execution ----------------------------------

fn deinitRowList(rows: *std.ArrayList(Row), allocator: Allocator) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn nodeObjectFromNode(allocator: Allocator, node: types.Node) Allocator.Error!NodeObject {
    return .{
        .id = node.id,
        .labels = try cloneLabels(allocator, node.labels.keys()),
        .properties = try cloneResultProperties(allocator, node.properties.keys(), node.properties.values()),
    };
}

fn edgeObjectFromEdge(allocator: Allocator, edge: types.Edge) Allocator.Error!EdgeObject {
    return .{
        .id = edge.id,
        .endpoints = edge.endpoints,
        .directed = edge.directed,
        .labels = try cloneLabels(allocator, edge.labels.keys()),
        .properties = try cloneResultProperties(allocator, edge.properties.keys(), edge.properties.values()),
    };
}

fn cloneLabels(allocator: Allocator, labels: []const []const u8) Allocator.Error![][]u8 {
    const out = try allocator.alloc([]u8, labels.len);
    errdefer allocator.free(out);
    for (out) |*label| label.* = &.{};
    errdefer for (out) |label| allocator.free(label);
    for (labels, 0..) |label, i| {
        out[i] = try allocator.dupe(u8, label);
    }
    return out;
}

fn cloneResultProperties(allocator: Allocator, keys: []const []const u8, values: []const Value) Allocator.Error![]ResultProperty {
    const out = try allocator.alloc(ResultProperty, keys.len);
    errdefer allocator.free(out);
    for (out) |*property| property.* = .{ .key = &.{}, .value = .null };
    errdefer for (out) |*property| property.deinit(allocator);
    for (keys, values, 0..) |key, value, i| {
        out[i] = .{
            .key = try allocator.dupe(u8, key),
            .value = try value.dupe(allocator),
        };
    }
    return out;
}

fn resultColumnNames(allocator: Allocator, columns: []const planner.ResultColumn) Allocator.Error![]const []u8 {
    const names = try allocator.alloc([]u8, columns.len);
    errdefer allocator.free(names);
    for (names) |*name| name.* = &.{};
    errdefer for (names) |name| allocator.free(name);

    for (columns, 0..) |column, i| {
        names[i] = try allocator.dupe(u8, column.name);
    }
    return names;
}
