//! Minimal GQL parser and execution layer for the functional Graphon MVP.
//!
//! This module intentionally implements a small, useful subset of GQL while the
//! full ISO grammar is still being built out. Supported today:
//!
//! * `RETURN` scalar expressions (`+`, `-`, `*`, `=`, `<>`) and properties.
//! * `INSERT` node/edge path patterns.
//! * `MATCH` node/edge path patterns with labels and property predicates.
//! * `MATCH ... RETURN`, `MATCH ... INSERT`, `MATCH ... SET`, and
//!   `MATCH ... [DETACH] DELETE`, and `MATCH ... FINISH`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const storage = @import("storage.zig");
const types = @import("types.zig");
const ElementId = types.ElementId;
const Value = types.Value;
const Ast = @import("Ast.zig");
const Parse = @import("Parse.zig");
const Plan = @import("Plan.zig");
const executor = @import("executor.zig");

pub const Error = Parse.Error || error{
    Unsupported,
    UnknownIdentifier,
    WrongType,
    InvalidRequest,
    MalformedPlan,
} || storage.Error;

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

pub const CompiledProgram = struct {
    statements: []CompiledStatement,

    pub fn deinit(self: *CompiledProgram, allocator: Allocator) void {
        for (self.statements) |*statement| statement.deinit(allocator);
        allocator.free(self.statements);
        self.* = undefined;
    }
};

pub const CompiledStatement = struct {
    plan: Plan,
    result: CompiledResult,

    pub fn deinit(self: *CompiledStatement, allocator: Allocator) void {
        self.plan.deinit(allocator);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const CompiledResult = union(enum) {
    rows: []ResultColumn,
    mutation: usize,

    pub fn deinit(self: *CompiledResult, allocator: Allocator) void {
        switch (self.*) {
            .rows => |columns| {
                for (columns) |*column| column.deinit(allocator);
                allocator.free(columns);
            },
            .mutation => {},
        }
        self.* = undefined;
    }
};

pub const ResultColumn = struct {
    name: []u8,
    graph_value: bool,

    pub fn deinit(self: *ResultColumn, allocator: Allocator) void {
        allocator.free(self.name);
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

pub fn compile(allocator: Allocator, source: [:0]const u8) Error!CompiledProgram {
    var parsed = try Parse.parse(allocator, source);
    defer parsed.deinit(allocator);

    var statements = std.ArrayList(CompiledStatement).empty;
    errdefer {
        for (statements.items) |*statement| statement.deinit(allocator);
        statements.deinit(allocator);
    }

    for (parsed.statements) |statement| {
        try statements.append(allocator, try compileStatement(allocator, statement));
    }

    return .{ .statements = try statements.toOwnedSlice(allocator) };
}

pub fn execute(allocator: Allocator, io: std.Io, store: storage.Storage, source: [:0]const u8) Error!ResultSet {
    var compiled = try compile(allocator, source);
    defer compiled.deinit(allocator);

    var txn = store.txn();
    defer txn.close();

    var result = ResultSet{ .rows_affected = 0 };
    errdefer result.deinit(allocator);

    for (compiled.statements) |*statement| {
        result.deinit(allocator);
        result = try executeCompiledStatement(allocator, io, txn, statement.*);
    }

    try txn.commit();
    return result;
}

fn compileStatement(allocator: Allocator, statement: Ast.Statement) Error!CompiledStatement {
    var planner = Planner{ .allocator = allocator };
    defer planner.deinit();

    switch (statement) {
        .return_only => |ret| return try appendReturnResult(allocator, &planner, ret),
        .insert => |patterns| return appendMutationResult(&planner, try appendInsertPatterns(&planner, patterns)),
        .match_query => |mq| {
            try appendMatchQuery(&planner, mq);
            return switch (mq.action) {
                .ret => |ret| try appendReturnResult(allocator, &planner, ret),
                .insert => |patterns| appendMutationResult(&planner, try appendInsertPatterns(&planner, patterns)),
                .set => |sets| appendMutationResult(&planner, try appendUpdate(&planner, sets)),
                .delete => |del| appendMutationResult(&planner, try appendDelete(&planner, del)),
                .finish => appendMutationResult(&planner, 1),
            };
        },
    }
}

fn executeCompiledStatement(
    allocator: Allocator,
    io: std.Io,
    txn: storage.Transaction,
    statement: CompiledStatement,
) Error!ResultSet {
    _ = io;
    return switch (statement.result) {
        .rows => |columns| try executeCompiledRows(allocator, txn, &statement.plan, columns),
        .mutation => |affected_per_row| blk: {
            const rows = try consumePlanRows(allocator, txn, &statement.plan);
            break :blk mutationResult(rows * affected_per_row);
        },
    };
}

fn mutationResult(rows_affected: usize) ResultSet {
    return .{ .columns = &.{}, .rows = &.{}, .rows_affected = rows_affected };
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

fn appendReturnResult(allocator: Allocator, planner: *Planner, ret: Ast.ReturnClause) Error!CompiledStatement {
    try appendReturnProjection(planner, ret);
    try appendOrderBy(planner, ret);
    try appendSkipLimit(planner, ret);

    const columns = try resultColumns(allocator, ret);
    errdefer deinitResultColumns(allocator, columns);
    return .{
        .plan = takePlan(planner),
        .result = .{ .rows = columns },
    };
}

fn appendMutationResult(planner: *Planner, affected_per_row: usize) CompiledStatement {
    return .{
        .plan = takePlan(planner),
        .result = .{ .mutation = affected_per_row },
    };
}

fn appendInsertPatterns(planner: *Planner, patterns: []Ast.PathPattern) Error!usize {
    var inserted_per_row: usize = 0;
    for (patterns) |pattern| {
        inserted_per_row += try appendInsertPath(planner, pattern);
    }
    return inserted_per_row;
}

fn takePlan(planner: *Planner) Plan {
    const plan = planner.plan;
    planner.plan = .{};
    return plan;
}

fn resultColumns(allocator: Allocator, ret: Ast.ReturnClause) Allocator.Error![]ResultColumn {
    const columns = try allocator.alloc(ResultColumn, ret.items.len);
    errdefer allocator.free(columns);
    for (columns) |*column| column.* = .{ .name = &.{}, .graph_value = false };
    errdefer deinitResultColumns(allocator, columns);

    for (ret.items, 0..) |item, i| {
        columns[i] = .{
            .name = try exprName(allocator, item),
            .graph_value = item.expr == .variable,
        };
    }

    return columns;
}

fn deinitResultColumns(allocator: Allocator, columns: []ResultColumn) void {
    for (columns) |*column| column.deinit(allocator);
    allocator.free(columns);
}

fn consumePlanRows(allocator: Allocator, txn: storage.Transaction, plan: *const Plan) Error!usize {
    var exec = try executor.Executor.init(plan, txn);
    defer exec.deinit();

    var rows: usize = 0;
    while (try exec.run()) |result_value| {
        var result = result_value;
        result.deinit(allocator);
        rows += 1;
    }

    return rows;
}

fn appendUpdate(planner: *Planner, sets: []const Ast.SetClause) Error!usize {
    var items = std.ArrayList(Plan.UpdateClause).empty;
    errdefer {
        for (items.items) |*item| item.deinit(planner.allocator);
        items.deinit(planner.allocator);
    }

    for (sets) |set| {
        const binding = planner.bindings.get(set.variable) orelse return error.UnknownIdentifier;
        const key = try planner.allocator.dupe(u8, set.property);
        errdefer planner.allocator.free(key);
        var value = try planExpr(planner, set.value);
        errdefer value.deinit(planner.allocator);
        try items.append(planner.allocator, .{ .ident = binding.ident, .key = key, .value = value });
    }

    try planner.plan.ops.append(planner.allocator, .{ .update = .{ .items = items } });
    items = .empty;
    return sets.len;
}

fn appendDelete(planner: *Planner, del: Ast.DeleteAction) Error!usize {
    var idents = std.ArrayList(u16).empty;
    errdefer idents.deinit(planner.allocator);

    for (del.variables) |name| {
        const binding = planner.bindings.get(name) orelse continue;
        try idents.append(planner.allocator, binding.ident);
    }

    const count = idents.items.len;
    if (count > 0) {
        try planner.plan.ops.append(planner.allocator, .{ .delete = .{
            .detach = del.detach,
            .idents = idents,
        } });
        idents = .empty;
    }
    return count;
}

fn appendMatchQuery(planner: *Planner, mq: Ast.MatchQuery) Error!void {
    for (mq.patterns) |pattern| {
        try appendPathPattern(planner, pattern);
    }
    if (mq.where) |where| {
        try appendFilter(planner, .{ .bool_exp = try planExpr(planner, where) });
    }
}

fn appendInsertPath(planner: *Planner, pattern: Ast.PathPattern) Error!usize {
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

fn appendInsertNodeOrUse(planner: *Planner, pattern: Ast.NodePattern, count: *usize) Error!u16 {
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

fn appendInsertEdge(planner: *Planner, src: u16, dest: u16, pattern: Ast.EdgePattern) Error!void {
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

fn planProperties(planner: *Planner, properties: []Ast.Property) Error!Plan.Properties {
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

fn appendReturnProjection(planner: *Planner, ret: Ast.ReturnClause) Error!void {
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

fn appendSkipLimit(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    if (ret.skip > 0) {
        try planner.plan.ops.append(planner.allocator, .{ .skip = @intCast(ret.skip) });
    }
    if (ret.limit) |limit| {
        try planner.plan.ops.append(planner.allocator, .{ .limit = @intCast(limit) });
    }
}

fn appendOrderBy(planner: *Planner, ret: Ast.ReturnClause) Error!void {
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
        try sort.append(planner.allocator, .{ .ident = ident, .desc = item.desc });
    }

    try planner.plan.ops.append(planner.allocator, .{ .project = project });
    project = .empty;
    try planner.plan.ops.append(planner.allocator, .{ .sort = sort });
    sort = .{};
}

fn appendPathPattern(planner: *Planner, pattern: Ast.PathPattern) Error!void {
    var current = try appendNodeStart(planner, pattern.start);
    for (pattern.segments) |segment| {
        current = try appendPathSegment(planner, current, segment);
    }
}

fn appendNodeStart(planner: *Planner, pattern: Ast.NodePattern) Error!u16 {
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

fn appendPathSegment(planner: *Planner, current: u16, segment: Ast.PathSegment) Error!u16 {
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
        .direction = segment.edge.direction,
        .edge_label = if (segment.edge.label) |label| try planner.allocator.dupe(u8, label) else null,
    } });

    if (edge_ident) |ident| try appendEdgeFilters(planner, ident, segment.edge);
    try appendNodeFilters(planner, dest_ident, segment.node, false);
    return dest_ident;
}

fn appendNodeFilters(planner: *Planner, ident: u16, pattern: Ast.NodePattern, label_in_scan: bool) Error!void {
    if (!label_in_scan) {
        if (pattern.label) |label| {
            try appendFilter(planner, .{ .ident_label = .{ .ident = ident, .label = try planner.allocator.dupe(u8, label) } });
        }
    }
    for (pattern.properties) |property| {
        try appendPropertyFilter(planner, ident, property);
    }
}

fn appendEdgeFilters(planner: *Planner, ident: u16, pattern: Ast.EdgePattern) Error!void {
    for (pattern.properties) |property| {
        try appendPropertyFilter(planner, ident, property);
    }
}

fn appendPropertyFilter(planner: *Planner, ident: u16, property: Ast.Property) Error!void {
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

fn planExpr(planner: *Planner, expr: Ast.Expr) Error!Plan.Exp {
    return switch (expr) {
        .literal => |value| .{ .literal = try value.dupe(planner.allocator) },
        .variable => |name| .{ .ident = (planner.bindings.get(name) orelse return error.UnknownIdentifier).ident },
        .property => |p| blk: {
            const binding = planner.bindings.get(p.variable) orelse return error.UnknownIdentifier;
            break :blk .{ .property = .{ .ident = binding.ident, .key = try planner.allocator.dupe(u8, p.property) } };
        },
        .unary => |unary| blk: {
            const planned = try planner.allocator.create(Plan.UnaryExp);
            planned.* = .{ .op = unary.op, .operand = try planExpr(planner, unary.operand) };
            break :blk .{ .unary = planned };
        },
        .binary => |bin| blk: {
            const planned = try planner.allocator.create(Plan.BinopExp);
            planned.* = .{
                .op = bin.op,
                .left = try planExpr(planner, bin.left),
                .right = try planExpr(planner, bin.right),
            };
            break :blk .{ .binop = planned };
        },
    };
}

fn executeCompiledRows(
    allocator: Allocator,
    txn: storage.Transaction,
    plan: *const Plan,
    columns: []const ResultColumn,
) Error!ResultSet {
    var exec = try executor.Executor.init(plan, txn);
    defer exec.deinit();

    var rows = std.ArrayList(Row).empty;
    errdefer deinitRowList(&rows, allocator);
    while (try exec.run()) |result_value| {
        var result = result_value;
        defer result.deinit(allocator);
        try rows.append(allocator, try rowFromCompiledResult(allocator, txn, result, columns));
    }

    return .{
        .columns = try resultColumnNames(allocator, columns),
        .rows = try rows.toOwnedSlice(allocator),
        .rows_affected = null,
    };
}

fn rowFromCompiledResult(
    allocator: Allocator,
    txn: storage.Transaction,
    result: executor.Result,
    columns: []const ResultColumn,
) Error!Row {
    const values = try allocator.alloc(ResultValue, columns.len);
    errdefer allocator.free(values);
    for (values) |*value| value.* = .{ .scalar = .null };
    errdefer for (values) |*value| value.deinit(allocator);

    for (columns, result.values, 0..) |column, value, i| {
        values[i].deinit(allocator);
        values[i] = try resultValueFromCompiledValue(allocator, txn, column, value);
    }
    return .{ .values = values };
}

fn resultValueFromCompiledValue(
    allocator: Allocator,
    txn: storage.Transaction,
    column: ResultColumn,
    value: Value,
) Error!ResultValue {
    if (column.graph_value) {
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

fn resultColumnNames(allocator: Allocator, columns: []const ResultColumn) Allocator.Error![]const []u8 {
    const names = try allocator.alloc([]u8, columns.len);
    errdefer allocator.free(names);
    for (names) |*name| name.* = &.{};
    errdefer for (names) |name| allocator.free(name);

    for (columns, 0..) |column, i| {
        names[i] = try allocator.dupe(u8, column.name);
    }
    return names;
}

fn exprName(allocator: Allocator, item: Ast.ReturnItem) Allocator.Error![]u8 {
    if (item.alias) |alias| return allocator.dupe(u8, alias);
    return switch (item.expr) {
        .variable => |name| allocator.dupe(u8, name),
        .property => |p| std.fmt.allocPrint(allocator, "{s}.{s}", .{ p.variable, p.property }),
        .literal => allocator.dupe(u8, "value"),
        .unary => allocator.dupe(u8, "expr"),
        .binary => allocator.dupe(u8, "expr"),
    };
}

// ------------------------------- Tests ------------------------------------

const Snap = @import("vendor/snaptest.zig").Snap;
const snap = Snap.snap;

fn execForTest(store: storage.Storage, source: [:0]const u8) !ResultSet {
    return try execute(std.testing.allocator, std.testing.io, store, source);
}

fn checkQueryPlanSnapshot(source: [:0]const u8, want: Snap) !void {
    var compiled = try compile(std.testing.allocator, source);
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), compiled.statements.len);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try compiled.statements[0].plan.print(&out.writer);
    try want.diff(out.written());
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

test "compile match return query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) WHERE p.age > 30 RETURN p.name ORDER BY p.age DESC LIMIT 2", snap(@src(),
        \\Plan{%1}
        \\  Limit 2
        \\  Sort %2 desc
        \\  Project %2: %0.age
        \\  Project %1: %0.name
        \\  Filter (%0.age > 30)
        \\  NodeScan (%0:Person)
    ));
}

test "compile match set query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person {name: 'Eric'}) SET p.age = 23", snap(@src(),
        \\Plan{}
        \\  Update %0.age = 23
        \\  Filter (%0.name = 'Eric')
        \\  NodeScan (%0:Person)
    ));
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

test "match finish counts matched rows" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 2), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) FINISH");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 2), result.rows_affected);
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
