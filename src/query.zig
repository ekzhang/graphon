//! Minimal GQL parser and execution layer for the functional Graphon MVP.
//!
//! This module intentionally implements a small, useful subset of GQL while the
//! full ISO grammar in `Parse.zig` is still being built out. Supported today:
//!
//! * `RETURN` scalar expressions (`+`, `-`, `*`, `=`, `<>`) and properties.
//! * `INSERT` node/edge path patterns.
//! * `MATCH` node/edge path patterns with labels and property predicates.
//! * `MATCH ... RETURN`, `MATCH ... INSERT`, `MATCH ... SET`, and
//!   `MATCH ... [DETACH] DELETE`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const storage = @import("storage.zig");
const rocksdb = @import("storage/rocksdb.zig");
const types = @import("types.zig");
const ElementId = types.ElementId;
const Value = types.Value;
const Plan = @import("Plan.zig");
const executor = @import("executor.zig");

pub const Error = error{
    ParseError,
    Unsupported,
    UnknownIdentifier,
    WrongType,
    InvalidRequest,
    MalformedPlan,
} || Allocator.Error || storage.Error;

const Lexeme = struct {
    tag: Token.Tag,
    start: usize,
    end: usize,
};

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

pub fn execute(allocator: Allocator, io: std.Io, store: storage.Storage, source: [:0]const u8) Error!ResultSet {
    var parsed = try Parser.parse(allocator, source);
    defer parsed.deinit(allocator);

    var txn = store.txn();
    defer txn.close();

    var result = ResultSet{ .rows_affected = 0 };
    errdefer result.deinit(allocator);

    for (parsed.statements) |*statement| {
        result.deinit(allocator);
        result = try executeStatement(allocator, io, txn, statement.*);
    }

    try txn.commit();
    return result;
}

fn executeStatement(allocator: Allocator, io: std.Io, txn: storage.Transaction, statement: Statement) Error!ResultSet {
    switch (statement) {
        .return_only => |ret| return try executeReturnPlan(allocator, txn, ret),
        .insert => |patterns| return try executeInsertPlan(allocator, txn, patterns),
        .match_query => |mq| {
            if (mq.action == .ret) {
                if (executeMatchReturnPlan(allocator, txn, mq)) |result| {
                    return result;
                } else |err| {
                    switch (err) {
                        error.Unsupported => {},
                        else => |e| return e,
                    }
                }
            }

            var rows = std.ArrayList(Binding).empty;
            errdefer deinitBindings(&rows, allocator);
            try rows.append(allocator, Binding{});
            for (mq.patterns) |pattern| {
                try matchPath(allocator, txn, &rows, pattern);
            }
            if (mq.where) |where| {
                try filterBindings(allocator, txn, &rows, where);
            }

            switch (mq.action) {
                .ret => |ret| {
                    var out_rows = std.ArrayList(Row).empty;
                    errdefer deinitRowList(&out_rows, allocator);
                    var skipped: usize = 0;
                    for (rows.items) |binding| {
                        if (skipped < ret.skip) {
                            skipped += 1;
                            continue;
                        }
                        if (ret.limit) |limit| {
                            if (out_rows.items.len >= limit) break;
                        }
                        try appendReturnRow(allocator, txn, &out_rows, binding, ret.items);
                    }
                    deinitBindings(&rows, allocator);
                    return .{
                        .columns = try columnNames(allocator, ret.items),
                        .rows = try out_rows.toOwnedSlice(allocator),
                        .rows_affected = null,
                    };
                },
                .insert => |patterns| {
                    var count: usize = 0;
                    for (rows.items) |*binding| {
                        for (patterns) |pattern| {
                            count += try insertPath(allocator, io, txn, binding, pattern);
                        }
                    }
                    deinitBindings(&rows, allocator);
                    return mutationResult(count);
                },
                .delete => |del| {
                    const count = try deleteBindings(allocator, txn, rows.items, del);
                    deinitBindings(&rows, allocator);
                    return mutationResult(count);
                },
                .set => |sets| {
                    const count = try setProperties(allocator, txn, rows.items, sets);
                    deinitBindings(&rows, allocator);
                    return mutationResult(count);
                },
                .finish => {
                    const n = rows.items.len;
                    deinitBindings(&rows, allocator);
                    return mutationResult(n);
                },
            }
        },
    }
}

fn mutationResult(rows_affected: usize) ResultSet {
    return .{ .columns = &.{}, .rows = &.{}, .rows_affected = rows_affected };
}

// ------------------------------- AST --------------------------------------

const Statement = union(enum) {
    return_only: ReturnClause,
    insert: []PathPattern,
    match_query: MatchQuery,

    fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.*) {
            .return_only => |*ret| ret.deinit(allocator),
            .insert => |patterns| deinitPatterns(patterns, allocator),
            .match_query => |*mq| mq.deinit(allocator),
        }
        self.* = undefined;
    }
};

const MatchQuery = struct {
    patterns: []PathPattern,
    where: ?Expr = null,
    action: MatchAction,

    fn deinit(self: *MatchQuery, allocator: Allocator) void {
        deinitPatterns(self.patterns, allocator);
        if (self.where) |*where| where.deinit(allocator);
        self.action.deinit(allocator);
        self.* = undefined;
    }
};

const MatchAction = union(enum) {
    ret: ReturnClause,
    insert: []PathPattern,
    delete: DeleteAction,
    set: []SetClause,
    finish,

    fn deinit(self: *MatchAction, allocator: Allocator) void {
        switch (self.*) {
            .ret => |*ret| ret.deinit(allocator),
            .insert => |patterns| deinitPatterns(patterns, allocator),
            .delete => |del| allocator.free(del.variables),
            .set => |sets| {
                for (sets) |*s| s.deinit(allocator);
                allocator.free(sets);
            },
            .finish => {},
        }
        self.* = undefined;
    }
};

const ReturnClause = struct {
    items: []ReturnItem,
    order_by: []SortItem = &.{},
    skip: usize = 0,
    limit: ?usize = null,

    fn deinit(self: *ReturnClause, allocator: Allocator) void {
        deinitReturnItems(self.items, allocator);
        deinitSortItems(self.order_by, allocator);
        self.* = undefined;
    }
};

const SortDirection = enum { asc, desc };

const SortItem = struct {
    expr: Expr,
    direction: SortDirection = .asc,

    fn deinit(self: *SortItem, allocator: Allocator) void {
        self.expr.deinit(allocator);
        self.* = undefined;
    }
};

const DeleteAction = struct {
    detach: bool,
    variables: []const []const u8,
};

const SetClause = struct {
    variable: []const u8,
    property: []const u8,
    value: Expr,

    fn deinit(self: *SetClause, allocator: Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

const ReturnItem = struct {
    expr: Expr,
    alias: ?[]const u8 = null,

    fn deinit(self: *ReturnItem, allocator: Allocator) void {
        self.expr.deinit(allocator);
        self.* = undefined;
    }
};

const PathPattern = struct {
    start: NodePattern,
    segments: []PathSegment,

    fn deinit(self: *PathPattern, allocator: Allocator) void {
        self.start.deinit(allocator);
        for (self.segments) |*segment| segment.deinit(allocator);
        allocator.free(self.segments);
        self.* = undefined;
    }
};

const PathSegment = struct {
    edge: EdgePattern,
    node: NodePattern,

    fn deinit(self: *PathSegment, allocator: Allocator) void {
        self.edge.deinit(allocator);
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

const NodePattern = struct {
    variable: ?[]const u8 = null,
    label: ?[]const u8 = null,
    properties: []Property = &.{},

    fn deinit(self: *NodePattern, allocator: Allocator) void {
        deinitProperties(self.properties, allocator);
        self.* = undefined;
    }
};

const EdgePattern = struct {
    variable: ?[]const u8 = null,
    label: ?[]const u8 = null,
    properties: []Property = &.{},
    direction: Direction,

    fn deinit(self: *EdgePattern, allocator: Allocator) void {
        deinitProperties(self.properties, allocator);
        self.* = undefined;
    }
};

const Direction = enum { right, left, undirected, any };

const Property = struct {
    key: []const u8,
    value: Expr,

    fn deinit(self: *Property, allocator: Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

const Expr = union(enum) {
    literal: Value,
    variable: []const u8,
    property: struct { variable: []const u8, property: []const u8 },
    unary: *UnaryExpr,
    binary: *BinaryExpr,

    fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .literal => |*v| v.deinit(allocator),
            .unary => |u| {
                u.deinit(allocator);
                allocator.destroy(u);
            },
            .binary => |b| {
                b.deinit(allocator);
                allocator.destroy(b);
            },
            .variable, .property => {},
        }
        self.* = undefined;
    }
};

const UnaryExpr = struct {
    op: UnaryOp,
    operand: Expr,

    fn deinit(self: *UnaryExpr, allocator: Allocator) void {
        self.operand.deinit(allocator);
        self.* = undefined;
    }
};

const UnaryOp = enum { not };

const BinaryExpr = struct {
    op: BinaryOp,
    left: Expr,
    right: Expr,

    fn deinit(self: *BinaryExpr, allocator: Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
        self.* = undefined;
    }
};

const BinaryOp = enum { add, sub, mul, eql, neq, lt, lte, gt, gte, and_, or_ };

fn deinitPatterns(patterns: []PathPattern, allocator: Allocator) void {
    for (patterns) |*pattern| pattern.deinit(allocator);
    allocator.free(patterns);
}

fn deinitReturnItems(items: []ReturnItem, allocator: Allocator) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitSortItems(items: []SortItem, allocator: Allocator) void {
    for (items) |*item| item.deinit(allocator);
    if (items.len > 0) allocator.free(items);
}

fn deinitProperties(properties: []Property, allocator: Allocator) void {
    for (properties) |*property| property.deinit(allocator);
    allocator.free(properties);
}

// ------------------------------ Planner -----------------------------------

const PlanBindingKind = enum { node, edge };

const PlanBinding = struct {
    ident: u16,
    kind: PlanBindingKind,
};

const Planner = struct {
    allocator: Allocator,
    plan: Plan = .{},
    bindings: std.StringHashMapUnmanaged(PlanBinding) = .empty,
    next_ident: u16 = 0,

    fn deinit(self: *Planner) void {
        self.plan.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.* = undefined;
    }

    fn allocIdent(self: *Planner) u16 {
        const ident = self.next_ident;
        self.next_ident += 1;
        return ident;
    }

    fn bind(self: *Planner, name: []const u8, kind: PlanBindingKind, ident: u16) Error!void {
        try self.bindings.put(self.allocator, name, .{ .ident = ident, .kind = kind });
    }

    fn get(self: *Planner, name: []const u8, kind: PlanBindingKind) Error!PlanBinding {
        const binding = self.bindings.get(name) orelse return error.UnknownIdentifier;
        if (binding.kind != kind) return error.WrongType;
        return binding;
    }
};

fn executeReturnPlan(allocator: Allocator, txn: storage.Transaction, ret: ReturnClause) Error!ResultSet {
    var planner = Planner{ .allocator = allocator };
    defer planner.deinit();
    try appendReturnProjection(&planner, ret);
    try appendOrderBy(&planner, ret);
    try appendSkipLimit(&planner, ret);
    return try executePlannedResult(allocator, txn, &planner.plan, ret.items);
}

fn executeMatchReturnPlan(allocator: Allocator, txn: storage.Transaction, mq: MatchQuery) Error!ResultSet {
    if (mq.action != .ret) return error.Unsupported;
    if (mq.patterns.len != 1) return error.Unsupported;

    var planner = Planner{ .allocator = allocator };
    defer planner.deinit();
    try appendPathPattern(&planner, mq.patterns[0]);
    if (mq.where) |where| {
        try appendFilter(&planner, .{ .bool_exp = try planExpr(&planner, where) });
    }
    const ret = mq.action.ret;
    try appendReturnProjection(&planner, ret);
    try appendOrderBy(&planner, ret);
    try appendSkipLimit(&planner, ret);
    return try executePlannedResult(allocator, txn, &planner.plan, ret.items);
}

fn executeInsertPlan(allocator: Allocator, txn: storage.Transaction, patterns: []PathPattern) Error!ResultSet {
    var planner = Planner{ .allocator = allocator };
    defer planner.deinit();

    var inserted_per_row: usize = 0;
    for (patterns) |pattern| {
        inserted_per_row += try appendInsertPath(&planner, pattern);
    }

    var exec = try executor.Executor.init(&planner.plan, txn);
    defer exec.deinit();

    var rows: usize = 0;
    while (try exec.run()) |result_value| {
        var result = result_value;
        result.deinit(allocator);
        rows += 1;
    }

    return mutationResult(rows * inserted_per_row);
}

fn appendInsertPath(planner: *Planner, pattern: PathPattern) Error!usize {
    var count: usize = 0;
    var current = try appendInsertNodeOrUse(planner, pattern.start, &count);
    for (pattern.segments) |segment| {
        const dest = try appendInsertNodeOrUse(planner, segment.node, &count);
        try appendInsertEdge(planner, current, dest, segment.edge);
        count += 1;
        current = dest;
    }
    return count;
}

fn appendInsertNodeOrUse(planner: *Planner, pattern: NodePattern, count: *usize) Error!u16 {
    if (pattern.variable) |name| {
        if (planner.bindings.get(name)) |binding| {
            if (binding.kind != .node) return error.WrongType;
            return binding.ident;
        }
    }

    const ident = planner.allocIdent();
    if (pattern.variable) |name| try planner.bind(name, .node, ident);
    var labels = try planLabels(planner, pattern.label);
    errdefer deinitLabelList(&labels, planner.allocator);
    var properties = try planProperties(planner, pattern.properties);
    errdefer deinitPlanProperties(&properties, planner.allocator);
    try planner.plan.ops.append(planner.allocator, .{ .insert_node = .{
        .ident = ident,
        .labels = labels,
        .properties = properties,
    } });
    labels = .empty;
    properties = .{};
    count.* += 1;
    return ident;
}

fn appendInsertEdge(planner: *Planner, src: u16, dest: u16, pattern: EdgePattern) Error!void {
    const ident = if (pattern.variable) |name| blk: {
        if (planner.bindings.get(name) != null) return error.Unsupported;
        const edge_ident = planner.allocIdent();
        try planner.bind(name, .edge, edge_ident);
        break :blk edge_ident;
    } else null;

    var labels = try planLabels(planner, pattern.label);
    errdefer deinitLabelList(&labels, planner.allocator);
    var properties = try planProperties(planner, pattern.properties);
    errdefer deinitPlanProperties(&properties, planner.allocator);

    const edge_src, const edge_dest = if (pattern.direction == .left) .{ dest, src } else .{ src, dest };
    try planner.plan.ops.append(planner.allocator, .{ .insert_edge = .{
        .ident = ident,
        .ident_src = edge_src,
        .ident_dest = edge_dest,
        .directed = pattern.direction == .right or pattern.direction == .left,
        .labels = labels,
        .properties = properties,
    } });
    labels = .empty;
    properties = .{};
}

fn planLabels(planner: *Planner, label: ?[]const u8) Error!std.ArrayList([]u8) {
    var labels = std.ArrayList([]u8).empty;
    errdefer deinitLabelList(&labels, planner.allocator);
    if (label) |value| {
        try labels.append(planner.allocator, try planner.allocator.dupe(u8, value));
    }
    return labels;
}

fn deinitLabelList(labels: *std.ArrayList([]u8), allocator: Allocator) void {
    for (labels.items) |label| allocator.free(label);
    labels.deinit(allocator);
}

fn planProperties(planner: *Planner, properties: []Property) Error!Plan.Properties {
    var out: Plan.Properties = .{};
    errdefer deinitPlanProperties(&out, planner.allocator);
    for (properties) |property| {
        const key = try planner.allocator.dupe(u8, property.key);
        errdefer planner.allocator.free(key);
        var value = try planExpr(planner, property.value);
        errdefer value.deinit(planner.allocator);
        try out.append(planner.allocator, .{ .key = key, .value = value });
    }
    return out;
}

fn deinitPlanProperties(properties: *Plan.Properties, allocator: Allocator) void {
    for (properties.items(.key)) |key| allocator.free(key);
    for (properties.items(.value)) |*value| value.deinit(allocator);
    properties.deinit(allocator);
}

fn appendReturnProjection(planner: *Planner, ret: ReturnClause) Error!void {
    var project = std.ArrayList(Plan.ProjectClause).empty;
    errdefer {
        for (project.items) |*clause| clause.deinit(planner.allocator);
        project.deinit(planner.allocator);
    }

    for (ret.items) |item| {
        if (item.expr == .variable) {
            const binding = planner.bindings.get(item.expr.variable) orelse null;
            if (binding) |b| {
                try planner.plan.results.append(planner.allocator, b.ident);
                continue;
            }
        }

        const ident = planner.allocIdent();
        try project.append(planner.allocator, .{ .ident = ident, .exp = try planExpr(planner, item.expr) });
        try planner.plan.results.append(planner.allocator, ident);
    }

    if (project.items.len > 0) {
        try planner.plan.ops.append(planner.allocator, .{ .project = project });
    } else {
        project.deinit(planner.allocator);
    }
}

fn appendSkipLimit(planner: *Planner, ret: ReturnClause) Error!void {
    if (ret.skip > 0) {
        try planner.plan.ops.append(planner.allocator, .{ .skip = @intCast(ret.skip) });
    }
    if (ret.limit) |limit| {
        try planner.plan.ops.append(planner.allocator, .{ .limit = @intCast(limit) });
    }
}

fn appendOrderBy(planner: *Planner, ret: ReturnClause) Error!void {
    if (ret.order_by.len == 0) return;

    var project = std.ArrayList(Plan.ProjectClause).empty;
    errdefer {
        for (project.items) |*clause| clause.deinit(planner.allocator);
        project.deinit(planner.allocator);
    }
    var sort: std.MultiArrayList(Plan.SortClause) = .{};
    errdefer sort.deinit(planner.allocator);

    for (ret.order_by) |item| {
        const ident = planner.allocIdent();
        try project.append(planner.allocator, .{ .ident = ident, .exp = try planExpr(planner, item.expr) });
        try sort.append(planner.allocator, .{ .ident = ident, .desc = item.direction == .desc });
    }

    try planner.plan.ops.append(planner.allocator, .{ .project = project });
    project = .empty;
    try planner.plan.ops.append(planner.allocator, .{ .sort = sort });
    sort = .{};
}

fn appendPathPattern(planner: *Planner, pattern: PathPattern) Error!void {
    var current = try appendNodeStart(planner, pattern.start);
    for (pattern.segments) |segment| {
        current = try appendPathSegment(planner, current, segment);
    }
}

fn appendNodeStart(planner: *Planner, pattern: NodePattern) Error!u16 {
    if (pattern.variable) |name| {
        if (planner.bindings.get(name)) |binding| {
            if (binding.kind != .node) return error.WrongType;
            try appendNodeFilters(planner, binding.ident, pattern, false);
            return binding.ident;
        }
    }

    const ident = planner.allocIdent();
    if (pattern.variable) |name| try planner.bind(name, .node, ident);
    try planner.plan.ops.append(planner.allocator, .{ .node_scan = .{
        .ident = ident,
        .label = if (pattern.label) |label| try planner.allocator.dupe(u8, label) else null,
    } });
    try appendNodeFilters(planner, ident, pattern, true);
    return ident;
}

fn appendPathSegment(planner: *Planner, current: u16, segment: PathSegment) Error!u16 {
    if (segment.node.variable) |name| {
        if (planner.bindings.get(name) != null) return error.Unsupported;
    }
    if (segment.edge.variable) |name| {
        if (planner.bindings.get(name) != null) return error.Unsupported;
    }

    const edge_ident: ?u16 = if (segment.edge.variable != null or segment.edge.properties.len > 0)
        planner.allocIdent()
    else
        null;
    const dest_ident = planner.allocIdent();

    if (segment.edge.variable) |name| try planner.bind(name, .edge, edge_ident.?);
    if (segment.node.variable) |name| try planner.bind(name, .node, dest_ident);

    try planner.plan.ops.append(planner.allocator, .{ .step = .{
        .ident_src = current,
        .ident_edge = edge_ident,
        .ident_dest = dest_ident,
        .direction = planDirection(segment.edge.direction),
        .edge_label = if (segment.edge.label) |label| try planner.allocator.dupe(u8, label) else null,
    } });

    if (edge_ident) |ident| try appendEdgeFilters(planner, ident, segment.edge);
    try appendNodeFilters(planner, dest_ident, segment.node, false);
    return dest_ident;
}

fn appendNodeFilters(planner: *Planner, ident: u16, pattern: NodePattern, label_in_scan: bool) Error!void {
    if (!label_in_scan) {
        if (pattern.label) |label| {
            try appendFilter(planner, .{ .ident_label = .{ .ident = ident, .label = try planner.allocator.dupe(u8, label) } });
        }
    }
    for (pattern.properties) |property| {
        try appendPropertyFilter(planner, ident, property);
    }
}

fn appendEdgeFilters(planner: *Planner, ident: u16, pattern: EdgePattern) Error!void {
    for (pattern.properties) |property| {
        try appendPropertyFilter(planner, ident, property);
    }
}

fn appendPropertyFilter(planner: *Planner, ident: u16, property: Property) Error!void {
    var left = Plan.Exp{ .property = .{ .ident = ident, .key = try planner.allocator.dupe(u8, property.key) } };
    errdefer left.deinit(planner.allocator);
    var right = try planExpr(planner, property.value);
    errdefer right.deinit(planner.allocator);
    const binop = try planner.allocator.create(Plan.BinopExp);
    binop.* = .{ .op = .eql, .left = left, .right = right };
    try appendFilter(planner, .{ .bool_exp = .{ .binop = binop } });
}

fn appendFilter(planner: *Planner, clause: Plan.FilterClause) Error!void {
    var clauses = std.ArrayList(Plan.FilterClause).empty;
    errdefer {
        for (clauses.items) |*item| item.deinit(planner.allocator);
        clauses.deinit(planner.allocator);
    }
    try clauses.append(planner.allocator, clause);
    try planner.plan.ops.append(planner.allocator, .{ .filter = clauses });
}

fn planExpr(planner: *Planner, expr: Expr) Error!Plan.Exp {
    return switch (expr) {
        .literal => |value| .{ .literal = try value.dupe(planner.allocator) },
        .variable => |name| .{ .ident = (planner.bindings.get(name) orelse return error.UnknownIdentifier).ident },
        .property => |p| blk: {
            const binding = planner.bindings.get(p.variable) orelse return error.UnknownIdentifier;
            break :blk .{ .property = .{ .ident = binding.ident, .key = try planner.allocator.dupe(u8, p.property) } };
        },
        .unary => |unary| blk: {
            const planned = try planner.allocator.create(Plan.UnaryExp);
            planned.* = .{ .op = switch (unary.op) {
                .not => .not,
            }, .operand = try planExpr(planner, unary.operand) };
            break :blk .{ .unary = planned };
        },
        .binary => |bin| blk: {
            const planned = try planner.allocator.create(Plan.BinopExp);
            planned.* = .{
                .op = planBinop(bin.op),
                .left = try planExpr(planner, bin.left),
                .right = try planExpr(planner, bin.right),
            };
            break :blk .{ .binop = planned };
        },
    };
}

fn planBinop(op: BinaryOp) Plan.Binop {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .eql => .eql,
        .neq => .neq,
        .lt => .lt,
        .lte => .lte,
        .gt => .gt,
        .gte => .gte,
        .and_ => .and_,
        .or_ => .or_,
    };
}

fn planDirection(direction: Direction) types.EdgeDirection {
    return switch (direction) {
        .right => .right,
        .left => .left,
        .undirected => .undirected,
        .any => .any,
    };
}

fn executePlannedResult(
    allocator: Allocator,
    txn: storage.Transaction,
    plan: *const Plan,
    items: []const ReturnItem,
) Error!ResultSet {
    var exec = try executor.Executor.init(plan, txn);
    defer exec.deinit();

    var rows = std.ArrayList(Row).empty;
    errdefer deinitRowList(&rows, allocator);
    while (try exec.run()) |result_value| {
        var result = result_value;
        defer result.deinit(allocator);
        try rows.append(allocator, try rowFromPlanResult(allocator, txn, result, items));
    }

    return .{
        .columns = try columnNames(allocator, items),
        .rows = try rows.toOwnedSlice(allocator),
        .rows_affected = null,
    };
}

fn rowFromPlanResult(
    allocator: Allocator,
    txn: storage.Transaction,
    result: executor.Result,
    items: []const ReturnItem,
) Error!Row {
    const values = try allocator.alloc(ResultValue, items.len);
    errdefer allocator.free(values);
    for (values) |*value| value.* = .{ .scalar = .null };
    errdefer for (values) |*value| value.deinit(allocator);

    for (items, result.values, 0..) |item, value, i| {
        values[i].deinit(allocator);
        values[i] = try resultValueFromPlanValue(allocator, txn, item.expr, value);
    }
    return .{ .values = values };
}

fn resultValueFromPlanValue(
    allocator: Allocator,
    txn: storage.Transaction,
    expr: Expr,
    value: Value,
) Error!ResultValue {
    if (expr == .variable) {
        switch (value) {
            .node_ref => |id| {
                var node = try txn.getNode(id) orelse return .{ .scalar = .null };
                defer node.deinit(allocator);
                return .{ .node = try nodeObjectFromNode(allocator, node) };
            },
            .edge_ref => |id| {
                var edge = try txn.getEdge(id) orelse return .{ .scalar = .null };
                defer edge.deinit(allocator);
                return .{ .edge = try edgeObjectFromEdge(allocator, edge) };
            },
            else => {},
        }
    }
    return .{ .scalar = try value.dupe(allocator) };
}

// ------------------------------ Parser ------------------------------------

const Parsed = struct {
    tokens: []Lexeme,
    statements: []Statement,

    fn deinit(self: *Parsed, allocator: Allocator) void {
        for (self.statements) |*statement| statement.deinit(allocator);
        allocator.free(self.statements);
        allocator.free(self.tokens);
        self.* = undefined;
    }
};

const Parser = struct {
    allocator: Allocator,
    source: [:0]const u8,
    tokens: []Lexeme,
    i: usize = 0,

    fn parse(allocator: Allocator, source: [:0]const u8) Error!Parsed {
        var toks = std.ArrayList(Lexeme).empty;
        errdefer toks.deinit(allocator);
        var t = tokenizer.Tokenizer.init(source);
        while (true) {
            const token = t.next();
            if (token.tag == .invalid) return error.ParseError;
            try toks.append(allocator, .{ .tag = token.tag, .start = token.loc.start, .end = token.loc.end });
            if (token.tag == .eof) break;
        }

        const owned_tokens = try toks.toOwnedSlice(allocator);
        errdefer allocator.free(owned_tokens);

        var parser = Parser{ .allocator = allocator, .source = source, .tokens = owned_tokens };
        var statements = std.ArrayList(Statement).empty;
        errdefer {
            for (statements.items) |*statement| statement.deinit(allocator);
            statements.deinit(allocator);
        }

        while (!parser.at(.eof)) {
            if (parser.eat(.semicolon)) continue;
            try statements.append(allocator, try parser.parseStatement());
            _ = parser.eat(.semicolon);
        }

        return .{ .tokens = owned_tokens, .statements = try statements.toOwnedSlice(allocator) };
    }

    fn parseStatement(p: *Parser) Error!Statement {
        if (p.eat(.keyword_return)) {
            return .{ .return_only = try p.parseReturnClause() };
        }
        if (p.eat(.keyword_insert)) {
            return .{ .insert = try p.parsePatternListUntilAction() };
        }
        if (p.eat(.keyword_match)) {
            const patterns = try p.parsePatternListUntilAction();
            errdefer deinitPatterns(patterns, p.allocator);
            var where: ?Expr = null;
            errdefer if (where) |*expr| expr.deinit(p.allocator);
            if (p.eat(.keyword_where)) {
                where = try p.parseExpr(0);
            }
            const action = try p.parseMatchAction();
            return .{ .match_query = .{ .patterns = patterns, .where = where, .action = action } };
        }
        return error.ParseError;
    }

    fn parseMatchAction(p: *Parser) Error!MatchAction {
        if (p.eat(.keyword_return)) return .{ .ret = try p.parseReturnClause() };
        if (p.eat(.keyword_insert)) return .{ .insert = try p.parsePatternListUntilAction() };
        if (p.eat(.keyword_finish)) return .finish;
        if (p.eat(.keyword_set)) return .{ .set = try p.parseSetClauses() };

        var detach = false;
        if (p.eat(.keyword_detach)) detach = true;
        if (p.eat(.keyword_delete)) {
            var vars = std.ArrayList([]const u8).empty;
            errdefer vars.deinit(p.allocator);
            while (true) {
                try vars.append(p.allocator, try p.expectName());
                if (!p.eat(.comma)) break;
            }
            return .{ .delete = .{ .detach = detach, .variables = try vars.toOwnedSlice(p.allocator) } };
        }
        return error.ParseError;
    }

    fn parseSetClauses(p: *Parser) Error![]SetClause {
        var clauses = std.ArrayList(SetClause).empty;
        errdefer {
            for (clauses.items) |*clause| clause.deinit(p.allocator);
            clauses.deinit(p.allocator);
        }
        while (true) {
            const variable = try p.expectName();
            try p.expect(.period);
            const property = try p.expectName();
            try p.expect(.equal);
            const value = try p.parseExpr(0);
            try clauses.append(p.allocator, .{ .variable = variable, .property = property, .value = value });
            if (!p.eat(.comma)) break;
        }
        return try clauses.toOwnedSlice(p.allocator);
    }

    fn parseReturnClause(p: *Parser) Error!ReturnClause {
        const items = try p.parseReturnItems();
        var ret = ReturnClause{ .items = items };
        errdefer ret.deinit(p.allocator);
        if (p.eat(.keyword_order)) {
            try p.expect(.keyword_by);
            ret.order_by = try p.parseSortItems();
        }
        while (true) {
            if (p.eat(.keyword_skip)) {
                ret.skip = try p.parseCount();
            } else if (p.eat(.keyword_limit)) {
                ret.limit = try p.parseCount();
            } else {
                break;
            }
        }
        const out = ret;
        ret = .{ .items = &.{} };
        return out;
    }

    fn parseSortItems(p: *Parser) Error![]SortItem {
        var items = std.ArrayList(SortItem).empty;
        errdefer {
            for (items.items) |*item| item.deinit(p.allocator);
            items.deinit(p.allocator);
        }
        while (!p.at(.keyword_skip) and !p.at(.keyword_limit) and !p.at(.semicolon) and !p.at(.eof)) {
            var expr = try p.parseExpr(0);
            errdefer expr.deinit(p.allocator);
            const direction: SortDirection = if (p.eat(.keyword_desc) or p.eat(.keyword_descending))
                .desc
            else if (p.eat(.keyword_asc) or p.eat(.keyword_ascending))
                .asc
            else
                .asc;
            try items.append(p.allocator, .{ .expr = expr, .direction = direction });
            if (!p.eat(.comma)) break;
        }
        if (items.items.len == 0) return error.ParseError;
        return try items.toOwnedSlice(p.allocator);
    }

    fn parseReturnItems(p: *Parser) Error![]ReturnItem {
        var items = std.ArrayList(ReturnItem).empty;
        errdefer {
            for (items.items) |*item| item.deinit(p.allocator);
            items.deinit(p.allocator);
        }
        while (!p.at(.keyword_order) and !p.at(.keyword_skip) and !p.at(.keyword_limit) and !p.at(.semicolon) and !p.at(.eof)) {
            var expr = try p.parseExpr(0);
            errdefer expr.deinit(p.allocator);
            const alias = if (p.eat(.keyword_as)) try p.expectName() else null;
            try items.append(p.allocator, .{ .expr = expr, .alias = alias });
            if (!p.eat(.comma)) break;
        }
        if (items.items.len == 0) return error.ParseError;
        return try items.toOwnedSlice(p.allocator);
    }

    fn parseCount(p: *Parser) Error!usize {
        const tok = p.next();
        if (tok.tag != .number_literal) return error.ParseError;
        const s = p.slice(tok);
        if (std.mem.indexOfScalar(u8, s, '.') != null) return error.ParseError;
        return std.fmt.parseInt(usize, s, 10) catch return error.ParseError;
    }

    fn parsePatternListUntilAction(p: *Parser) Error![]PathPattern {
        var patterns = std.ArrayList(PathPattern).empty;
        errdefer {
            for (patterns.items) |*pattern| pattern.deinit(p.allocator);
            patterns.deinit(p.allocator);
        }
        while (!p.at(.semicolon) and !p.at(.eof) and !p.atActionKeyword()) {
            try patterns.append(p.allocator, try p.parsePathPattern());
            if (!p.eat(.comma)) break;
        }
        if (patterns.items.len == 0) return error.ParseError;
        return try patterns.toOwnedSlice(p.allocator);
    }

    fn parsePathPattern(p: *Parser) Error!PathPattern {
        const start = try p.parseNodePattern();
        errdefer {
            var s = start;
            s.deinit(p.allocator);
        }
        var segments = std.ArrayList(PathSegment).empty;
        errdefer {
            for (segments.items) |*segment| segment.deinit(p.allocator);
            segments.deinit(p.allocator);
        }
        while (p.edgeStartsHere()) {
            const edge = try p.parseEdgePattern();
            errdefer {
                var e = edge;
                e.deinit(p.allocator);
            }
            const node = try p.parseNodePattern();
            errdefer {
                var n = node;
                n.deinit(p.allocator);
            }
            try segments.append(p.allocator, .{ .edge = edge, .node = node });
        }
        return .{ .start = start, .segments = try segments.toOwnedSlice(p.allocator) };
    }

    fn parseNodePattern(p: *Parser) Error!NodePattern {
        try p.expect(.l_paren);
        var node = NodePattern{};
        errdefer node.deinit(p.allocator);

        if (p.isName() and !p.atKeywordLike(.keyword_return)) {
            node.variable = try p.expectName();
        }
        while (p.eat(.colon)) {
            const label = try p.expectName();
            if (node.label == null) node.label = label;
        }
        if (p.at(.l_brace)) node.properties = try p.parseProperties();
        try p.expect(.r_paren);
        return node;
    }

    fn parseEdgePattern(p: *Parser) Error!EdgePattern {
        var direction: Direction = .undirected;
        var bracketed = true;

        switch (p.peek()) {
            .minus_left_bracket => {
                _ = p.next();
                direction = .undirected;
            },
            .left_arrow_bracket => {
                _ = p.next();
                direction = .left;
            },
            .right_arrow => {
                _ = p.next();
                direction = .right;
                if (p.eat(.l_bracket)) {
                    bracketed = true;
                } else {
                    bracketed = false;
                }
            },
            .left_arrow => {
                _ = p.next();
                direction = .left;
                bracketed = false;
            },
            .left_minus_right => {
                _ = p.next();
                direction = .any;
                bracketed = false;
            },
            else => return error.ParseError,
        }

        var edge = EdgePattern{ .direction = direction };
        errdefer edge.deinit(p.allocator);

        if (bracketed) {
            if (p.isName() and !p.at(.r_bracket)) {
                edge.variable = try p.expectName();
            }
            while (p.eat(.colon)) {
                const label = try p.expectName();
                if (edge.label == null) edge.label = label;
            }
            if (p.at(.l_brace)) edge.properties = try p.parseProperties();

            const close = p.peek();
            switch (close) {
                .bracket_right_arrow => {
                    _ = p.next();
                    edge.direction = .right;
                },
                .right_bracket_minus => {
                    _ = p.next();
                    // Keep explicit left arrows left; otherwise `-[]-` is undirected.
                    if (direction != .left) edge.direction = .undirected;
                },
                .r_bracket => {
                    _ = p.next();
                    edge.direction = direction;
                },
                else => return error.ParseError,
            }
        }
        return edge;
    }

    fn parseProperties(p: *Parser) Error![]Property {
        try p.expect(.l_brace);
        var properties = std.ArrayList(Property).empty;
        errdefer {
            for (properties.items) |*property| property.deinit(p.allocator);
            properties.deinit(p.allocator);
        }
        while (!p.eat(.r_brace)) {
            const key = try p.expectName();
            try p.expect(.colon);
            var value = try p.parseExpr(0);
            errdefer value.deinit(p.allocator);
            try properties.append(p.allocator, .{ .key = key, .value = value });
            if (!p.eat(.comma)) {
                try p.expect(.r_brace);
                break;
            }
        }
        return try properties.toOwnedSlice(p.allocator);
    }

    fn parseExpr(p: *Parser, min_prec: u8) Error!Expr {
        var left = try p.parseUnary();
        errdefer left.deinit(p.allocator);

        while (binaryInfo(p.peek())) |info| {
            if (info.prec < min_prec) break;
            _ = p.next();
            var right = try p.parseExpr(info.prec + 1);
            errdefer right.deinit(p.allocator);
            const bin = try p.allocator.create(BinaryExpr);
            bin.* = .{ .op = info.op, .left = left, .right = right };
            left = .{ .binary = bin };
        }
        return left;
    }

    fn parseUnary(p: *Parser) Error!Expr {
        if (p.eat(.keyword_not)) {
            var operand = try p.parseExpr(3);
            errdefer operand.deinit(p.allocator);
            const unary = try p.allocator.create(UnaryExpr);
            unary.* = .{ .op = .not, .operand = operand };
            return .{ .unary = unary };
        }
        return p.parsePrimary();
    }

    fn parsePrimary(p: *Parser) Error!Expr {
        const tok = p.next();
        switch (tok.tag) {
            .number_literal => {
                const s = p.slice(tok);
                if (std.mem.indexOfScalar(u8, s, '.') != null) {
                    return .{ .literal = .{ .float64 = std.fmt.parseFloat(f64, s) catch return error.ParseError } };
                }
                return .{ .literal = .{ .int64 = std.fmt.parseInt(i64, s, 10) catch return error.ParseError } };
            },
            .string_literal => return .{ .literal = .{ .string = try p.unquoteString(p.slice(tok)) } },
            .keyword_true => return .{ .literal = .{ .bool = true } },
            .keyword_false => return .{ .literal = .{ .bool = false } },
            .keyword_null => return .{ .literal = .null },
            .l_paren => {
                const expr = try p.parseExpr(0);
                try p.expect(.r_paren);
                return expr;
            },
            else => {
                if (!isNameToken(tok.tag)) return error.ParseError;
                const name = p.slice(tok);
                if (p.eat(.period)) {
                    return .{ .property = .{ .variable = name, .property = try p.expectName() } };
                }
                return .{ .variable = name };
            },
        }
    }

    fn unquoteString(p: *Parser, s: []const u8) Error![]u8 {
        if (s.len < 2) return error.ParseError;
        var start: usize = 1;
        const delimiter = s[0];
        if (delimiter == '@') {
            if (s.len < 3) return error.ParseError;
            start = 2;
        }
        const end = s.len - 1;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(p.allocator);
        var i = start;
        while (i < end) : (i += 1) {
            if (s[i] == delimiter and i + 1 < end and s[i + 1] == delimiter) {
                try out.append(p.allocator, delimiter);
                i += 1;
            } else if (s[i] == '\\' and i + 1 < end) {
                i += 1;
                try out.append(p.allocator, switch (s[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => s[i],
                });
            } else {
                try out.append(p.allocator, s[i]);
            }
        }
        return try out.toOwnedSlice(p.allocator);
    }

    fn binaryInfo(tag: Token.Tag) ?struct { op: BinaryOp, prec: u8 } {
        return switch (tag) {
            .keyword_or => .{ .op = .or_, .prec = 1 },
            .keyword_and => .{ .op = .and_, .prec = 2 },
            .equal => .{ .op = .eql, .prec = 3 },
            .not_equal => .{ .op = .neq, .prec = 3 },
            .angle_bracket_left => .{ .op = .lt, .prec = 3 },
            .angle_bracket_left_equal => .{ .op = .lte, .prec = 3 },
            .angle_bracket_right => .{ .op = .gt, .prec = 3 },
            .angle_bracket_right_equal => .{ .op = .gte, .prec = 3 },
            .plus => .{ .op = .add, .prec = 4 },
            .minus => .{ .op = .sub, .prec = 4 },
            .asterisk => .{ .op = .mul, .prec = 5 },
            else => null,
        };
    }

    fn atActionKeyword(p: *Parser) bool {
        return switch (p.peek()) {
            .keyword_return, .keyword_insert, .keyword_delete, .keyword_detach, .keyword_set, .keyword_finish, .keyword_where => true,
            else => false,
        };
    }

    fn edgeStartsHere(p: *Parser) bool {
        return switch (p.peek()) {
            .minus_left_bracket, .left_arrow_bracket, .right_arrow, .left_arrow, .left_minus_right => true,
            else => false,
        };
    }

    fn isName(p: *Parser) bool {
        return isNameToken(p.peek());
    }

    fn at(p: *Parser, tag: Token.Tag) bool {
        return p.peek() == tag;
    }

    fn atKeywordLike(p: *Parser, tag: Token.Tag) bool {
        return p.peek() == tag;
    }

    fn eat(p: *Parser, tag: Token.Tag) bool {
        if (p.peek() == tag) {
            p.i += 1;
            return true;
        }
        return false;
    }

    fn expect(p: *Parser, tag: Token.Tag) Error!void {
        if (!p.eat(tag)) return error.ParseError;
    }

    fn expectName(p: *Parser) Error![]const u8 {
        const tok = p.next();
        if (!isNameToken(tok.tag)) return error.ParseError;
        return p.slice(tok);
    }

    fn peek(p: *Parser) Token.Tag {
        return p.tokens[p.i].tag;
    }

    fn next(p: *Parser) Lexeme {
        const tok = p.tokens[p.i];
        p.i += 1;
        return tok;
    }

    fn slice(p: *Parser, tok: Lexeme) []const u8 {
        return p.source[tok.start..tok.end];
    }
};

fn isNameToken(tag: Token.Tag) bool {
    if (tag == .identifier) return true;
    return std.mem.startsWith(u8, @tagName(tag), "keyword_");
}

// ----------------------------- Execution ----------------------------------

const Bound = union(enum) {
    node: ElementId,
    edge: ElementId,
};

const Binding = struct {
    vars: std.StringHashMapUnmanaged(Bound) = .empty,

    fn deinit(self: *Binding, allocator: Allocator) void {
        self.vars.deinit(allocator);
        self.* = undefined;
    }

    fn clone(self: Binding, allocator: Allocator) Allocator.Error!Binding {
        return .{ .vars = try self.vars.clone(allocator) };
    }

    fn bindNode(self: *Binding, allocator: Allocator, name: []const u8, id: ElementId) Allocator.Error!bool {
        if (self.vars.get(name)) |bound| return switch (bound) {
            .node => |node_id| node_id.value == id.value,
            .edge => false,
        };
        try self.vars.put(allocator, name, .{ .node = id });
        return true;
    }

    fn bindEdge(self: *Binding, allocator: Allocator, name: []const u8, id: ElementId) Allocator.Error!bool {
        if (self.vars.get(name)) |bound| return switch (bound) {
            .edge => |edge_id| edge_id.value == id.value,
            .node => false,
        };
        try self.vars.put(allocator, name, .{ .edge = id });
        return true;
    }
};

const PathRow = struct {
    binding: Binding,
    current: ElementId,

    fn deinit(self: *PathRow, allocator: Allocator) void {
        self.binding.deinit(allocator);
        self.* = undefined;
    }
};

fn deinitBindings(rows: *std.ArrayList(Binding), allocator: Allocator) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitPathRows(rows: *std.ArrayList(PathRow), allocator: Allocator) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitRowList(rows: *std.ArrayList(Row), allocator: Allocator) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn filterBindings(allocator: Allocator, txn: storage.Transaction, rows: *std.ArrayList(Binding), predicate: Expr) Error!void {
    var kept = std.ArrayList(Binding).empty;
    errdefer deinitBindings(&kept, allocator);

    for (rows.items) |*binding| {
        var value = try evalExpr(allocator, txn, binding.*, predicate);
        defer value.deinit(allocator);
        if (value.truthy()) {
            const moved = binding.*;
            try kept.append(allocator, moved);
            binding.* = Binding{};
        }
    }

    deinitBindings(rows, allocator);
    rows.* = kept;
}

fn matchPath(allocator: Allocator, txn: storage.Transaction, rows: *std.ArrayList(Binding), pattern: PathPattern) Error!void {
    var path_rows = std.ArrayList(PathRow).empty;
    errdefer deinitPathRows(&path_rows, allocator);

    for (rows.items) |row| {
        if (pattern.start.variable) |name| {
            if (row.vars.get(name)) |bound| {
                if (bound != .node) continue;
                var node = try txn.getNode(bound.node) orelse continue;
                defer node.deinit(allocator);
                if (!try nodeMatches(allocator, txn, row, pattern.start, node)) continue;
                try path_rows.append(allocator, .{ .binding = try row.clone(allocator), .current = bound.node });
                continue;
            }
        }

        var it = try txn.iterateNodes();
        defer it.close();
        while (try it.next()) |node_value| {
            var node = node_value;
            defer node.deinit(allocator);
            if (!try nodeMatches(allocator, txn, row, pattern.start, node)) continue;
            var next_binding = try row.clone(allocator);
            errdefer next_binding.deinit(allocator);
            if (pattern.start.variable) |name| {
                if (!try next_binding.bindNode(allocator, name, node.id)) continue;
            }
            try path_rows.append(allocator, .{ .binding = next_binding, .current = node.id });
        }
    }

    for (pattern.segments) |segment| {
        var next_path_rows = std.ArrayList(PathRow).empty;
        errdefer deinitPathRows(&next_path_rows, allocator);

        for (path_rows.items) |path_row| {
            const min_inout, const max_inout = inoutRange(segment.edge.direction);
            var adj = try txn.iterateAdj(path_row.current, min_inout, max_inout);
            defer adj.close();
            while (try adj.next()) |entry| {
                var edge = try txn.getEdge(entry.edge_id) orelse continue;
                defer edge.deinit(allocator);
                if (!try edgeMatches(allocator, txn, path_row.binding, segment.edge, edge)) continue;

                var dest_node = try txn.getNode(entry.dest_node_id) orelse continue;
                defer dest_node.deinit(allocator);
                if (!try nodeMatches(allocator, txn, path_row.binding, segment.node, dest_node)) continue;

                var next_binding = try path_row.binding.clone(allocator);
                errdefer next_binding.deinit(allocator);
                if (segment.edge.variable) |name| {
                    if (!try next_binding.bindEdge(allocator, name, edge.id)) continue;
                }
                if (segment.node.variable) |name| {
                    if (!try next_binding.bindNode(allocator, name, dest_node.id)) continue;
                }
                try next_path_rows.append(allocator, .{ .binding = next_binding, .current = dest_node.id });
            }
        }

        deinitPathRows(&path_rows, allocator);
        path_rows = next_path_rows;
    }

    deinitBindings(rows, allocator);
    rows.* = std.ArrayList(Binding).empty;
    for (path_rows.items) |path_row| {
        try rows.append(allocator, path_row.binding);
    }
    // `path_row.binding` ownership moved into `rows`; only free the backing array.
    path_rows.deinit(allocator);
}

fn inoutRange(direction: Direction) struct { types.EdgeInOut, types.EdgeInOut } {
    return switch (direction) {
        .right => .{ .out, .out },
        .left => .{ .in, .in },
        .undirected => .{ .simple, .simple },
        .any => .{ .out, .in },
    };
}

fn nodeMatches(allocator: Allocator, txn: storage.Transaction, binding: Binding, pattern: NodePattern, node: types.Node) Error!bool {
    if (pattern.label) |label| {
        if (!node.labels.contains(label)) return false;
    }
    const b = binding;
    for (pattern.properties) |property| {
        const actual = node.properties.get(property.key) orelse return false;
        var expected = try evalExpr(allocator, txn, b, property.value);
        defer expected.deinit(allocator);
        if (!actual.eql(expected)) return false;
    }
    return true;
}

fn edgeMatches(allocator: Allocator, txn: storage.Transaction, binding: Binding, pattern: EdgePattern, edge: types.Edge) Error!bool {
    if (pattern.label) |label| {
        if (!edge.labels.contains(label)) return false;
    }
    const b = binding;
    for (pattern.properties) |property| {
        const actual = edge.properties.get(property.key) orelse return false;
        var expected = try evalExpr(allocator, txn, b, property.value);
        defer expected.deinit(allocator);
        if (!actual.eql(expected)) return false;
    }
    return true;
}

fn insertPath(allocator: Allocator, io: std.Io, txn: storage.Transaction, binding: *Binding, pattern: PathPattern) Error!usize {
    var count: usize = 0;
    var current = try insertOrUseNode(allocator, io, txn, binding, pattern.start, &count);
    for (pattern.segments) |segment| {
        const dest = try insertOrUseNode(allocator, io, txn, binding, segment.node, &count);
        try insertEdge(allocator, io, txn, binding, current, dest, segment.edge);
        count += 1;
        current = dest;
    }
    return count;
}

fn insertOrUseNode(
    allocator: Allocator,
    io: std.Io,
    txn: storage.Transaction,
    binding: *Binding,
    pattern: NodePattern,
    count: *usize,
) Error!ElementId {
    if (pattern.variable) |name| {
        if (binding.vars.get(name)) |bound| return switch (bound) {
            .node => |id| id,
            .edge => error.WrongType,
        };
    }

    var node = types.Node{ .id = ElementId.generate(io) };
    errdefer node.deinit(allocator);
    if (pattern.label) |label| {
        try node.labels.put(allocator, try allocator.dupe(u8, label), void{});
    }
    node.properties = try evaluateProperties(allocator, txn, binding.*, pattern.properties);
    try txn.putNode(node);
    const id = node.id;
    node.deinit(allocator);
    if (pattern.variable) |name| {
        _ = try binding.bindNode(allocator, name, id);
    }
    count.* += 1;
    return id;
}

fn insertEdge(
    allocator: Allocator,
    io: std.Io,
    txn: storage.Transaction,
    binding: *Binding,
    src: ElementId,
    dest: ElementId,
    pattern: EdgePattern,
) Error!void {
    var edge = types.Edge{
        .id = ElementId.generate(io),
        .endpoints = .{ src, dest },
        .directed = pattern.direction == .right or pattern.direction == .left,
    };
    errdefer edge.deinit(allocator);

    if (pattern.direction == .left) {
        edge.endpoints = .{ dest, src };
    }
    if (pattern.label) |label| {
        try edge.labels.put(allocator, try allocator.dupe(u8, label), void{});
    }
    edge.properties = try evaluateProperties(allocator, txn, binding.*, pattern.properties);
    try txn.putEdge(edge);
    const id = edge.id;
    edge.deinit(allocator);
    if (pattern.variable) |name| {
        _ = try binding.bindEdge(allocator, name, id);
    }
}

fn evaluateProperties(
    allocator: Allocator,
    txn: storage.Transaction,
    binding: Binding,
    properties: []const Property,
) Error!std.StringArrayHashMapUnmanaged(Value) {
    var ret: std.StringArrayHashMapUnmanaged(Value) = .empty;
    errdefer types.freeProperties(allocator, &ret);
    for (properties) |property| {
        const key = try allocator.dupe(u8, property.key);
        errdefer allocator.free(key);
        var value = try evalExpr(allocator, txn, binding, property.value);
        errdefer value.deinit(allocator);
        try ret.put(allocator, key, value);
    }
    return ret;
}

fn deleteBindings(allocator: Allocator, txn: storage.Transaction, rows: []const Binding, del: DeleteAction) Error!usize {
    var deleted_nodes: std.AutoHashMapUnmanaged(u96, void) = .empty;
    defer deleted_nodes.deinit(allocator);
    var deleted_edges: std.AutoHashMapUnmanaged(u96, void) = .empty;
    defer deleted_edges.deinit(allocator);

    var count: usize = 0;
    for (rows) |binding| {
        for (del.variables) |name| {
            const bound = binding.vars.get(name) orelse continue;
            switch (bound) {
                .edge => |edge_id| {
                    if (deleted_edges.contains(edge_id.value)) continue;
                    txn.deleteEdge(edge_id) catch |err| switch (err) {
                        rocksdb.Error.NotFound => {},
                        else => |e| return e,
                    };
                    try deleted_edges.put(allocator, edge_id.value, void{});
                    count += 1;
                },
                .node => |node_id| {
                    if (deleted_nodes.contains(node_id.value)) continue;
                    if (del.detach) {
                        try deleteAttachedEdges(allocator, txn, node_id, &deleted_edges, &count);
                    }
                    txn.deleteNode(node_id) catch |err| switch (err) {
                        rocksdb.Error.NotFound => {},
                        else => |e| return e,
                    };
                    try deleted_nodes.put(allocator, node_id.value, void{});
                    count += 1;
                },
            }
        }
    }
    return count;
}

fn deleteAttachedEdges(
    allocator: Allocator,
    txn: storage.Transaction,
    node_id: ElementId,
    deleted_edges: *std.AutoHashMapUnmanaged(u96, void),
    count: *usize,
) Error!void {
    var ids = std.ArrayList(ElementId).empty;
    defer ids.deinit(allocator);
    var it = try txn.iterateAdj(node_id, .out, .in);
    defer it.close();
    while (try it.next()) |entry| try ids.append(allocator, entry.edge_id);

    for (ids.items) |edge_id| {
        if (deleted_edges.contains(edge_id.value)) continue;
        txn.deleteEdge(edge_id) catch |err| switch (err) {
            rocksdb.Error.NotFound => {},
            else => |e| return e,
        };
        try deleted_edges.put(allocator, edge_id.value, void{});
        count.* += 1;
    }
}

fn setProperties(allocator: Allocator, txn: storage.Transaction, rows: []const Binding, sets: []const SetClause) Error!usize {
    var count: usize = 0;
    for (rows) |binding| {
        for (sets) |set| {
            const bound = binding.vars.get(set.variable) orelse return error.UnknownIdentifier;
            var value = try evalExpr(allocator, txn, binding, set.value);
            errdefer value.deinit(allocator);
            switch (bound) {
                .node => |node_id| {
                    var node = try txn.getNode(node_id) orelse continue;
                    defer node.deinit(allocator);
                    try putProperty(allocator, &node.properties, set.property, value);
                    value = .null; // ownership moved
                    try txn.putNode(node);
                    count += 1;
                },
                .edge => |edge_id| {
                    var edge = try txn.getEdge(edge_id) orelse continue;
                    defer edge.deinit(allocator);
                    try putProperty(allocator, &edge.properties, set.property, value);
                    value = .null; // ownership moved
                    try txn.putEdge(edge);
                    count += 1;
                },
            }
        }
    }
    return count;
}

fn putProperty(allocator: Allocator, properties: *std.StringArrayHashMapUnmanaged(Value), key: []const u8, value: Value) Allocator.Error!void {
    if (properties.getIndex(key)) |idx| {
        properties.values()[idx].deinit(allocator);
        properties.values()[idx] = value;
    } else {
        try properties.put(allocator, try allocator.dupe(u8, key), value);
    }
}

fn appendReturnRow(
    allocator: Allocator,
    txn: storage.Transaction,
    out_rows: *std.ArrayList(Row),
    binding: Binding,
    items: []const ReturnItem,
) Error!void {
    const values = try allocator.alloc(ResultValue, items.len);
    errdefer allocator.free(values);
    for (values) |*v| v.* = .{ .scalar = .null };
    errdefer for (values) |*v| v.deinit(allocator);

    for (items, 0..) |item, i| {
        values[i].deinit(allocator);
        values[i] = try evalReturnExpr(allocator, txn, binding, item.expr);
    }
    try out_rows.append(allocator, .{ .values = values });
}

fn evalReturnExpr(allocator: Allocator, txn: storage.Transaction, binding: Binding, expr: Expr) Error!ResultValue {
    switch (expr) {
        .variable => |name| {
            const bound = binding.vars.get(name) orelse return error.UnknownIdentifier;
            return switch (bound) {
                .node => |id| blk: {
                    var node = try txn.getNode(id) orelse return .{ .scalar = .null };
                    defer node.deinit(allocator);
                    break :blk .{ .node = try nodeObjectFromNode(allocator, node) };
                },
                .edge => |id| blk: {
                    var edge = try txn.getEdge(id) orelse return .{ .scalar = .null };
                    defer edge.deinit(allocator);
                    break :blk .{ .edge = try edgeObjectFromEdge(allocator, edge) };
                },
            };
        },
        else => return .{ .scalar = try evalExpr(allocator, txn, binding, expr) },
    }
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

fn columnNames(allocator: Allocator, items: []const ReturnItem) Allocator.Error![]const []u8 {
    var cols = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(cols);
    for (items, 0..) |item, i| {
        cols[i] = try exprName(allocator, item);
    }
    return cols;
}

fn exprName(allocator: Allocator, item: ReturnItem) Allocator.Error![]u8 {
    if (item.alias) |alias| return allocator.dupe(u8, alias);
    return switch (item.expr) {
        .variable => |name| allocator.dupe(u8, name),
        .property => |p| std.fmt.allocPrint(allocator, "{s}.{s}", .{ p.variable, p.property }),
        .literal => allocator.dupe(u8, "value"),
        .unary => allocator.dupe(u8, "expr"),
        .binary => allocator.dupe(u8, "expr"),
    };
}

fn evalExpr(allocator: Allocator, txn: storage.Transaction, binding: Binding, expr: Expr) Error!Value {
    switch (expr) {
        .literal => |v| return try v.dupe(allocator),
        .variable => |name| {
            const bound = binding.vars.get(name) orelse return error.UnknownIdentifier;
            return switch (bound) {
                .node => |id| .{ .node_ref = id },
                .edge => |id| .{ .edge_ref = id },
            };
        },
        .property => |p| {
            const bound = binding.vars.get(p.variable) orelse return error.UnknownIdentifier;
            switch (bound) {
                .node => |id| {
                    var node = try txn.getNode(id) orelse return .null;
                    defer node.deinit(allocator);
                    const value = node.properties.get(p.property) orelse return .null;
                    return try value.dupe(allocator);
                },
                .edge => |id| {
                    var edge = try txn.getEdge(id) orelse return .null;
                    defer edge.deinit(allocator);
                    const value = edge.properties.get(p.property) orelse return .null;
                    return try value.dupe(allocator);
                },
            }
        },
        .unary => |unary| {
            var operand = try evalExpr(allocator, txn, binding, unary.operand);
            defer operand.deinit(allocator);
            return switch (unary.op) {
                .not => .{ .bool = !operand.truthy() },
            };
        },
        .binary => |bin| {
            switch (bin.op) {
                .and_ => {
                    var left = try evalExpr(allocator, txn, binding, bin.left);
                    defer left.deinit(allocator);
                    if (!left.truthy()) return .{ .bool = false };
                    var right = try evalExpr(allocator, txn, binding, bin.right);
                    defer right.deinit(allocator);
                    return .{ .bool = right.truthy() };
                },
                .or_ => {
                    var left = try evalExpr(allocator, txn, binding, bin.left);
                    defer left.deinit(allocator);
                    if (left.truthy()) return .{ .bool = true };
                    var right = try evalExpr(allocator, txn, binding, bin.right);
                    defer right.deinit(allocator);
                    return .{ .bool = right.truthy() };
                },
                else => {},
            }
            var left = try evalExpr(allocator, txn, binding, bin.left);
            defer left.deinit(allocator);
            var right = try evalExpr(allocator, txn, binding, bin.right);
            defer right.deinit(allocator);
            return switch (bin.op) {
                .add => try left.add(right, allocator),
                .sub => left.sub(right),
                .mul => multiplyValues(left, right),
                .eql => .{ .bool = left.eql(right) },
                .neq => .{ .bool = !left.eql(right) },
                .lt => .{ .bool = if (compareValues(left, right)) |order| order == .lt else false },
                .lte => .{ .bool = if (compareValues(left, right)) |order| order == .lt or order == .eq else false },
                .gt => .{ .bool = if (compareValues(left, right)) |order| order == .gt else false },
                .gte => .{ .bool = if (compareValues(left, right)) |order| order == .gt or order == .eq else false },
                .and_, .or_ => unreachable,
            };
        },
    }
}

fn compareValues(left: Value, right: Value) ?std.math.Order {
    return switch (left) {
        .int64 => |a| switch (right) {
            .int64 => |b| orderInt(a, b),
            .float64 => |b| orderFloat(@floatFromInt(a), b),
            else => null,
        },
        .float64 => |a| switch (right) {
            .int64 => |b| orderFloat(a, @floatFromInt(b)),
            .float64 => |b| orderFloat(a, b),
            else => null,
        },
        .string => |a| switch (right) {
            .string => |b| std.mem.order(u8, a, b),
            else => null,
        },
        else => null,
    };
}

fn orderInt(a: i64, b: i64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

fn orderFloat(a: f64, b: f64) ?std.math.Order {
    if (std.math.isNan(a) or std.math.isNan(b)) return null;
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

fn multiplyValues(left: Value, right: Value) Value {
    return switch (left) {
        .int64 => |a| switch (right) {
            .int64 => |b| .{ .int64 = a * b },
            .float64 => |b| .{ .float64 = @as(f64, @floatFromInt(a)) * b },
            else => .null,
        },
        .float64 => |a| switch (right) {
            .int64 => |b| .{ .float64 = a * @as(f64, @floatFromInt(b)) },
            .float64 => |b| .{ .float64 = a * b },
            else => .null,
        },
        else => .null,
    };
}

// ------------------------------- Tests ------------------------------------

fn execForTest(store: storage.Storage, source: [:0]const u8) !ResultSet {
    return try execute(std.testing.allocator, std.testing.io, store, source);
}

fn jsonForTest(result: ResultSet) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try result.writeJson(&buf.writer);
    return try buf.toOwnedSlice();
}

fn resultContainsString(result: ResultSet, column: usize, expected: []const u8) bool {
    for (result.rows) |row| {
        if (row.values[column] != .scalar) continue;
        const scalar = row.values[column].scalar;
        if (scalar != .string) continue;
        if (std.mem.eql(u8, scalar.string, expected)) return true;
    }
    return false;
}

test "return arithmetic" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "RETURN 100 * 3");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(Value{ .int64 = 300 }, result.rows[0].values[0].scalar);

    const json = try jsonForTest(result);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("300", json);
}

test "return limit zero" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "RETURN 100 * 3 LIMIT 0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), result.columns.len);
    try std.testing.expectEqualStrings("expr", result.columns[0]);
}

test "return skip one" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "RETURN 100 * 3 SKIP 1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), result.columns.len);
    try std.testing.expectEqualStrings("expr", result.columns[0]);
}

test "insert match return and detach delete" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:User {name: 'Eric'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "INSERT (:Food {name: 'Pizza', calories: 285})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (a:User {name: 'Eric'}), (f:Food {name: 'Pizza'}) INSERT (a)->[:Likes]->(f)");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (a:User {name: 'Eric'})->[:Likes]->(f:Food) RETURN f.name, f.calories");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Pizza", result.rows[0].values[0].scalar.string);
        try std.testing.expectEqual(Value{ .int64 = 285 }, result.rows[0].values[1].scalar);
    }
    {
        var result = try execForTest(store, "MATCH (f:Food {name: 'Pizza'}) DETACH DELETE f");
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.rows_affected.? >= 1);
    }
    {
        var result = try execForTest(store, "MATCH (a:User {name: 'Eric'})->[:Likes]->(f:Food) RETURN f.name, f.calories");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    }
}

test "match return limit" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'}), (:Person {name: 'Cara'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 3), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name LIMIT 2");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);
        try std.testing.expectEqual(@as(usize, 1), result.columns.len);
        try std.testing.expectEqualStrings("p.name", result.columns[0]);
    }
}

test "match return skip and limit" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'}), (:Person {name: 'Cara'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 3), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name SKIP 1 LIMIT 1");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqual(@as(usize, 1), result.columns.len);
        try std.testing.expectEqualStrings("p.name", result.columns[0]);
    }
}

test "match return order by" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada', age: 30}),
            \\       (:Person {name: 'Bert', age: 41}),
            \\       (:Person {name: 'Cara', age: 42})
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 3), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name ORDER BY p.age");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 3), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].scalar.string);
        try std.testing.expectEqualStrings("Bert", result.rows[1].values[0].scalar.string);
        try std.testing.expectEqualStrings("Cara", result.rows[2].values[0].scalar.string);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name ORDER BY p.age DESC SKIP 1 LIMIT 1");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Bert", result.rows[0].values[0].scalar.string);
    }
}

test "match where filters with comparisons and boolean operators" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada', age: 30, active: true}),
            \\       (:Person {name: 'Bert', age: 41, active: false}),
            \\       (:Person {name: 'Cara', age: 42, active: true})
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 3), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) WHERE p.age > 30 AND p.active = true RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Cara", result.rows[0].values[0].scalar.string);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) WHERE NOT p.active OR p.age <= 30 RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);
        try std.testing.expect(resultContainsString(result, 0, "Ada"));
        try std.testing.expect(resultContainsString(result, 0, "Bert"));
    }
}

test "returning a node includes labels and properties" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Alice', age: 30})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Alice'}) RETURN a");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        const node = result.rows[0].values[0].node;
        try std.testing.expectEqual(@as(usize, 1), node.labels.len);
        try std.testing.expectEqualStrings("Person", node.labels[0]);
        try std.testing.expectEqual(@as(usize, 2), node.properties.len);

        const json = try jsonForTest(result);
        defer std.testing.allocator.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"labels\":[\"Person\"]") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Alice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"age\":30") != null);
    }
}

test "set updates matched properties" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Eric'})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Eric'}) SET p.age = 23");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Eric'}) RETURN p.age");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(Value{ .int64 = 23 }, result.rows[0].values[0].scalar);
    }
}
