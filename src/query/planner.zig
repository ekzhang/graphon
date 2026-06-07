//! Lower parsed query ASTs into executable query plans.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("../Ast.zig");
const Parse = @import("../Parse.zig");
const Plan = @import("../Plan.zig");

pub const Error = Parse.Error || error{
    Unsupported,
    UnknownIdentifier,
    WrongType,
    MalformedPlan,
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
        const binding = planner.bindings.get(name) orelse return error.UnknownIdentifier;
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
        var exp = try planExpr(planner, item.expr);
        errdefer exp.deinit(planner.allocator);
        try project.append(planner.allocator, .{ .ident = ident, .exp = exp });
        exp = .{ .ident = 0 };
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
        var exp = try planExpr(planner, item.expr);
        errdefer exp.deinit(planner.allocator);
        try project.append(planner.allocator, .{ .ident = ident, .exp = exp });
        exp = .{ .ident = 0 };
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
    errdefer {
        var exp = Plan.Exp{ .binop = binop };
        exp.deinit(planner.allocator);
    }
    left = .{ .ident = 0 };
    right = .{ .ident = 0 };
    try appendFilter(planner, .{ .bool_exp = .{ .binop = binop } });
}

fn appendFilter(planner: *Planner, clause: Plan.FilterClause) Error!void {
    var clauses = std.ArrayList(Plan.FilterClause).empty;
    errdefer {
        for (clauses.items) |*item| item.deinit(planner.allocator);
        clauses.deinit(planner.allocator);
    }
    var owned_clause = clause;
    errdefer owned_clause.deinit(planner.allocator);
    try clauses.append(planner.allocator, owned_clause);
    owned_clause = .{ .bool_exp = .{ .ident = 0 } };
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
            errdefer planner.allocator.destroy(planned);
            var operand = try planExpr(planner, unary.operand);
            errdefer operand.deinit(planner.allocator);
            planned.* = .{ .op = unary.op, .operand = operand };
            operand = .{ .ident = 0 };
            break :blk .{ .unary = planned };
        },
        .binary => |bin| blk: {
            const planned = try planner.allocator.create(Plan.BinopExp);
            errdefer planner.allocator.destroy(planned);
            var left = try planExpr(planner, bin.left);
            errdefer left.deinit(planner.allocator);
            var right = try planExpr(planner, bin.right);
            errdefer right.deinit(planner.allocator);
            planned.* = .{
                .op = bin.op,
                .left = left,
                .right = right,
            };
            left = .{ .ident = 0 };
            right = .{ .ident = 0 };
            break :blk .{ .binop = planned };
        },
    };
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
