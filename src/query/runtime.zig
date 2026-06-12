//! Pull-based execution for compiled query plans plus materialized result sets.

const std = @import("std");
const Allocator = std.mem.Allocator;

const planner = @import("planner.zig");
const storage = @import("../storage.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Plan = @import("../Plan.zig");
const executor = @import("../executor.zig");

pub const Error = executor.Error || Allocator.Error || error{WrongResultKind};

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

    pub fn writeJson(self: ResultSet, json: *std.json.Stringify) !void {
        if (self.rows_affected) |n| {
            try json.beginObject();
            try json.objectField("ok");
            try json.write(true);
            try json.objectField("rows_affected");
            try json.write(n);
            try json.endObject();
            return;
        }

        try json.beginArray();
        for (self.rows) |row| {
            try json.beginObject();
            for (self.columns, 0..) |column, col_i| {
                try json.objectField(column);
                try row.values[col_i].writeJson(json);
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

/// A returned column value after optional graph-element materialization.
pub const ResultValue = union(enum) {
    value: Value,
    node: types.Node,
    edge: types.Edge,

    pub fn deinit(self: *ResultValue, allocator: Allocator) void {
        switch (self.*) {
            .value => |*value| value.deinit(allocator),
            .node => |*node| node.deinit(allocator),
            .edge => |*edge| edge.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn writeJson(self: ResultValue, json: *std.json.Stringify) !void {
        switch (self) {
            .value => |value| try value.writeJson(json),
            .node => |node| try node.writeJson(json),
            .edge => |edge| try edge.writeJson(json),
        }
    }
};

pub const StatementResultKind = enum {
    rows,
    mutation,
};

pub const StatementCursor = struct {
    gpa: Allocator,
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
        gpa: Allocator,
        txn: storage.Transaction,
        statement: *const planner.CompiledStatement,
    ) Error!StatementCursor {
        const exec = try executor.Executor.init(&statement.plan, txn);
        return .{
            .gpa = gpa,
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
                return try rowFromCompiledResult(self.gpa, self.txn, result, rows.columns);
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
        const allocator = self.gpa;
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
    for (values) |*value| value.* = .{ .value = .null };
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
                var node = try txn.getNode(id) orelse return .{ .value = .null };
                defer node.deinit(txn.allocator);
                return .{ .node = try node.dupe(allocator) };
            },
            .edge_ref => |id| {
                var edge = try txn.getEdge(id) orelse return .{ .value = .null };
                defer edge.deinit(txn.allocator);
                return .{ .edge = try edge.dupe(allocator) };
            },
            else => {},
        }
    }
    return .{ .value = try value.dupe(allocator) };
}

// ----------------------------- Execution ----------------------------------

fn deinitRowList(rows: *std.ArrayList(Row), allocator: Allocator) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
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
