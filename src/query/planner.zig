//! Lower parsed query ASTs into executable query plans.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("../Ast.zig");
const Plan = @import("../Plan.zig");

pub const Error = Ast.ParseError || error{
    Unsupported,
    UnknownIdentifier,
    WrongType,
    MalformedPlan,
};

pub const CompiledProgram = struct {
    statements: []CompiledStatement,

    pub fn deinit(self: *CompiledProgram, gpa: Allocator) void {
        for (self.statements) |*statement| statement.deinit(gpa);
        gpa.free(self.statements);
        self.* = undefined;
    }
};

pub const CompiledStatement = struct {
    plan: Plan,
    result: CompiledResult,

    pub fn deinit(self: *CompiledStatement, gpa: Allocator) void {
        self.plan.deinit(gpa);
        self.result.deinit(gpa);
        self.* = undefined;
    }
};

pub const CompiledResult = union(enum) {
    rows: []ResultColumn,
    mutation: MutationCount,

    pub fn deinit(self: *CompiledResult, gpa: Allocator) void {
        switch (self.*) {
            .rows => |columns| {
                for (columns) |*column| column.deinit(gpa);
                gpa.free(columns);
            },
            .mutation => {},
        }
        self.* = undefined;
    }
};

pub const MutationCount = enum {
    mutations,
    rows,
};

pub const ResultColumn = struct {
    name: []u8,
    graph_value: bool,

    pub fn deinit(self: *ResultColumn, gpa: Allocator) void {
        if (self.name.len > 0) gpa.free(self.name);
        self.* = undefined;
    }
};

pub fn compile(gpa: Allocator, source: [:0]const u8) Error!CompiledProgram {
    var parsed = try Ast.parse(gpa, source);
    defer parsed.deinit(gpa);

    var statements = std.ArrayList(CompiledStatement).empty;
    errdefer {
        for (statements.items) |*statement| statement.deinit(gpa);
        statements.deinit(gpa);
    }

    for (parsed.statements) |statement| {
        var compiled: ?CompiledStatement = try compileStatement(gpa, statement);
        errdefer if (compiled) |*s| s.deinit(gpa);
        try statements.append(gpa, compiled.?);
        compiled = null;
    }

    return .{ .statements = try statements.toOwnedSlice(gpa) };
}

fn compileStatement(gpa: Allocator, statement: Ast.Statement) Error!CompiledStatement {
    var planner = Planner{ .gpa = gpa };
    defer planner.deinit();

    switch (statement) {
        .return_only => |ret| return try appendReturnResult(gpa, &planner, ret),
        .insert => |patterns| {
            try appendInsertPatterns(&planner, patterns);
            return appendMutationResult(&planner, .mutations);
        },
        .match_query => |mq| {
            try appendMatchQuery(&planner, mq);
            return switch (mq.action) {
                .ret => |ret| try appendReturnResult(gpa, &planner, ret),
                .insert => |patterns| blk: {
                    try appendInsertPatterns(&planner, patterns);
                    break :blk appendMutationResult(&planner, .mutations);
                },
                .set => |sets| blk: {
                    try appendUpdate(&planner, sets);
                    break :blk appendMutationResult(&planner, .mutations);
                },
                .delete => |del| blk: {
                    try appendDelete(&planner, del);
                    break :blk appendMutationResult(&planner, .mutations);
                },
                .finish => appendMutationResult(&planner, .rows),
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
    gpa: Allocator,
    plan: Plan = .{},
    bindings: std.StringHashMapUnmanaged(PlanBinding) = .empty,
    next_ident: u16 = 0,

    fn deinit(self: *Planner) void {
        self.plan.deinit(self.gpa);
        self.bindings.deinit(self.gpa);
        self.* = undefined;
    }

    fn allocIdent(self: *Planner) u16 {
        const ident = self.next_ident;
        self.next_ident += 1;
        return ident;
    }

    fn bind(self: *Planner, name: []const u8, kind: PlanBindingKind, ident: u16) Error!void {
        try self.bindings.put(self.gpa, name, .{ .ident = ident, .kind = kind });
    }

    fn get(self: *Planner, name: []const u8, kind: PlanBindingKind) Error!PlanBinding {
        const binding = self.bindings.get(name) orelse return error.UnknownIdentifier;
        if (binding.kind != kind) return error.WrongType;
        return binding;
    }
};

fn appendReturnResult(gpa: Allocator, planner: *Planner, ret: Ast.ReturnClause) Error!CompiledStatement {
    try appendReturnProjection(planner, ret);
    try appendOrderBy(planner, ret);
    try appendSkipLimit(planner, ret);

    const columns = try resultColumns(gpa, ret);
    errdefer deinitResultColumns(gpa, columns);
    return .{
        .plan = takePlan(planner),
        .result = .{ .rows = columns },
    };
}

fn appendMutationResult(planner: *Planner, count: MutationCount) CompiledStatement {
    return .{
        .plan = takePlan(planner),
        .result = .{ .mutation = count },
    };
}

fn appendInsertPatterns(planner: *Planner, patterns: []Ast.PathPattern) Error!void {
    for (patterns) |pattern| {
        try appendInsertPath(planner, pattern);
    }
}

fn takePlan(planner: *Planner) Plan {
    const plan = planner.plan;
    planner.plan = .{};
    return plan;
}

fn resultColumns(gpa: Allocator, ret: Ast.ReturnClause) Allocator.Error![]ResultColumn {
    const columns = try gpa.alloc(ResultColumn, ret.items.len);
    for (columns) |*column| column.* = .{ .name = &.{}, .graph_value = false };
    errdefer deinitResultColumns(gpa, columns);

    for (ret.items, 0..) |item, i| {
        columns[i] = .{
            .name = try exprName(gpa, item),
            .graph_value = item.expr == .variable,
        };
    }

    return columns;
}

fn deinitResultColumns(gpa: Allocator, columns: []ResultColumn) void {
    for (columns) |*column| column.deinit(gpa);
    gpa.free(columns);
}

fn appendUpdate(planner: *Planner, sets: []const Ast.SetClause) Error!void {
    var items = std.ArrayList(Plan.UpdateClause).empty;
    errdefer {
        for (items.items) |*item| item.deinit(planner.gpa);
        items.deinit(planner.gpa);
    }

    for (sets) |set| {
        const binding = planner.bindings.get(set.variable) orelse return error.UnknownIdentifier;
        var key: ?[]u8 = try planner.gpa.dupe(u8, set.property);
        errdefer if (key) |k| planner.gpa.free(k);
        var value: ?Plan.Exp = try planExpr(planner, set.value);
        errdefer if (value) |*v| v.deinit(planner.gpa);
        try items.append(planner.gpa, .{ .ident = binding.ident, .key = key.?, .value = value.? });
        key = null;
        value = null;
    }

    try planner.plan.ops.append(planner.gpa, .{ .update = .{ .items = items } });
    items = .empty;
}

fn appendDelete(planner: *Planner, del: Ast.DeleteAction) Error!void {
    var idents = std.ArrayList(u16).empty;
    errdefer idents.deinit(planner.gpa);

    for (del.variables) |name| {
        const binding = planner.bindings.get(name) orelse return error.UnknownIdentifier;
        try idents.append(planner.gpa, binding.ident);
    }

    if (idents.items.len > 0) {
        try planner.plan.ops.append(planner.gpa, .{ .delete = .{
            .detach = del.detach,
            .idents = idents,
        } });
        idents = .empty;
    }
}

fn appendMatchQuery(planner: *Planner, mq: Ast.MatchQuery) Error!void {
    for (mq.patterns, 0..) |pattern, i| {
        if (i > 0) try planner.plan.ops.append(planner.gpa, .begin);
        try appendPathPattern(planner, pattern);
        if (i > 0) try planner.plan.ops.append(planner.gpa, .join);
    }
    if (mq.where) |where| {
        try appendFilter(planner, .{ .bool_exp = try planExpr(planner, where) });
    }
}

fn appendInsertPath(planner: *Planner, pattern: Ast.PathPattern) Error!void {
    var current = try appendInsertNodeOrUse(planner, pattern.start);
    for (pattern.segments) |segment| {
        const dest = try appendInsertNodeOrUse(planner, segment.node);
        try appendInsertEdge(planner, current, dest, segment.edge);
        current = dest;
    }
}

fn appendInsertNodeOrUse(planner: *Planner, pattern: Ast.NodePattern) Error!u16 {
    if (pattern.variable) |name| {
        if (planner.bindings.get(name)) |binding| {
            if (binding.kind != .node) return error.WrongType;
            return binding.ident;
        }
    }

    const ident = planner.allocIdent();
    if (pattern.variable) |name| try planner.bind(name, .node, ident);
    var labels = try planLabels(planner, pattern.label);
    errdefer deinitLabelList(&labels, planner.gpa);
    var properties = try planProperties(planner, pattern.properties);
    errdefer deinitPlanProperties(&properties, planner.gpa);
    try planner.plan.ops.append(planner.gpa, .{ .insert_node = .{
        .ident = ident,
        .labels = labels,
        .properties = properties,
    } });
    labels = .empty;
    properties = .{};
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
    errdefer deinitLabelList(&labels, planner.gpa);
    var properties = try planProperties(planner, pattern.properties);
    errdefer deinitPlanProperties(&properties, planner.gpa);

    const edge_src, const edge_dest = if (pattern.direction == .left) .{ dest, src } else .{ src, dest };
    try planner.plan.ops.append(planner.gpa, .{ .insert_edge = .{
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
    errdefer deinitLabelList(&labels, planner.gpa);
    if (label) |value| {
        var owned: ?[]u8 = try planner.gpa.dupe(u8, value);
        errdefer if (owned) |s| planner.gpa.free(s);
        try labels.append(planner.gpa, owned.?);
        owned = null;
    }
    return labels;
}

fn deinitLabelList(labels: *std.ArrayList([]u8), gpa: Allocator) void {
    for (labels.items) |label| gpa.free(label);
    labels.deinit(gpa);
}

fn planProperties(planner: *Planner, properties: []Ast.Property) Error!Plan.Properties {
    var out: Plan.Properties = .{};
    errdefer deinitPlanProperties(&out, planner.gpa);
    for (properties) |property| {
        var key: ?[]u8 = try planner.gpa.dupe(u8, property.key);
        errdefer if (key) |k| planner.gpa.free(k);
        var value: ?Plan.Exp = try planExpr(planner, property.value);
        errdefer if (value) |*v| v.deinit(planner.gpa);
        try out.append(planner.gpa, .{ .key = key.?, .value = value.? });
        key = null;
        value = null;
    }
    return out;
}

fn deinitPlanProperties(properties: *Plan.Properties, gpa: Allocator) void {
    for (properties.items(.key)) |key| gpa.free(key);
    for (properties.items(.value)) |*value| value.deinit(gpa);
    properties.deinit(gpa);
}

fn appendReturnProjection(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    var project = std.ArrayList(Plan.ProjectClause).empty;
    errdefer {
        for (project.items) |*clause| clause.deinit(planner.gpa);
        project.deinit(planner.gpa);
    }

    for (ret.items) |item| {
        if (item.expr == .variable) {
            const binding = planner.bindings.get(item.expr.variable) orelse null;
            if (binding) |b| {
                try planner.plan.results.append(planner.gpa, b.ident);
                continue;
            }
        }

        const ident = planner.allocIdent();
        var exp = try planExpr(planner, item.expr);
        errdefer exp.deinit(planner.gpa);
        try project.append(planner.gpa, .{ .ident = ident, .exp = exp });
        exp = .{ .ident = 0 };
        try planner.plan.results.append(planner.gpa, ident);
    }

    if (project.items.len > 0) {
        try planner.plan.ops.append(planner.gpa, .{ .project = project });
    } else {
        project.deinit(planner.gpa);
    }
}

fn appendSkipLimit(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    if (ret.skip > 0) {
        try planner.plan.ops.append(planner.gpa, .{ .skip = @intCast(ret.skip) });
    }
    if (ret.limit) |limit| {
        try planner.plan.ops.append(planner.gpa, .{ .limit = @intCast(limit) });
    }
}

fn appendOrderBy(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    if (ret.order_by.len == 0) return;

    var project = std.ArrayList(Plan.ProjectClause).empty;
    errdefer {
        for (project.items) |*clause| clause.deinit(planner.gpa);
        project.deinit(planner.gpa);
    }
    var sort: std.MultiArrayList(Plan.SortClause) = .{};
    errdefer sort.deinit(planner.gpa);

    for (ret.order_by) |item| {
        const ident = planner.allocIdent();
        var exp = try planExpr(planner, item.expr);
        errdefer exp.deinit(planner.gpa);
        try project.append(planner.gpa, .{ .ident = ident, .exp = exp });
        exp = .{ .ident = 0 };
        try sort.append(planner.gpa, .{ .ident = ident, .desc = item.desc });
    }

    try planner.plan.ops.append(planner.gpa, .{ .project = project });
    project = .empty;
    try planner.plan.ops.append(planner.gpa, .{ .sort = sort });
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
    var label: ?[]u8 = if (pattern.label) |name| try planner.gpa.dupe(u8, name) else null;
    errdefer if (label) |l| planner.gpa.free(l);
    try planner.plan.ops.append(planner.gpa, .{ .node_scan = .{
        .ident = ident,
        .label = label,
    } });
    label = null;
    try appendNodeFilters(planner, ident, pattern, true);
    return ident;
}

fn appendPathSegment(planner: *Planner, current: u16, segment: Ast.PathSegment) Error!u16 {
    const existing_dest = if (segment.node.variable) |name| blk: {
        if (planner.bindings.get(name)) |binding| {
            if (binding.kind != .node) return error.WrongType;
            break :blk binding.ident;
        }
        break :blk null;
    } else null;
    const existing_edge = if (segment.edge.variable) |name| blk: {
        if (planner.bindings.get(name)) |binding| {
            if (binding.kind != .edge) return error.WrongType;
            break :blk binding.ident;
        }
        break :blk null;
    } else null;

    const edge_ident: ?u16 = if (segment.edge.variable != null or segment.edge.properties.len > 0 or existing_edge != null)
        planner.allocIdent()
    else
        null;
    const dest_ident = planner.allocIdent();

    if (segment.edge.variable) |name| {
        if (existing_edge == null) try planner.bind(name, .edge, edge_ident.?);
    }
    if (segment.node.variable) |name| {
        if (existing_dest == null) try planner.bind(name, .node, dest_ident);
    }

    var edge_label: ?[]u8 = if (segment.edge.label) |label| try planner.gpa.dupe(u8, label) else null;
    errdefer if (edge_label) |label| planner.gpa.free(label);
    try planner.plan.ops.append(planner.gpa, .{ .step = .{
        .ident_src = current,
        .ident_edge = edge_ident,
        .ident_dest = dest_ident,
        .direction = segment.edge.direction,
        .edge_label = edge_label,
    } });
    edge_label = null;

    if (edge_ident) |ident| try appendEdgeFilters(planner, ident, segment.edge);
    if (existing_edge) |ident| try appendIdentEqualityFilter(planner, edge_ident.?, ident);
    try appendNodeFilters(planner, dest_ident, segment.node, false);
    if (existing_dest) |ident| try appendIdentEqualityFilter(planner, dest_ident, ident);
    return dest_ident;
}

fn appendNodeFilters(planner: *Planner, ident: u16, pattern: Ast.NodePattern, label_in_scan: bool) Error!void {
    if (!label_in_scan) {
        if (pattern.label) |label| {
            try appendFilter(planner, .{ .ident_label = .{ .ident = ident, .label = try planner.gpa.dupe(u8, label) } });
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

fn appendIdentEqualityFilter(planner: *Planner, left_ident: u16, right_ident: u16) Error!void {
    var binop: ?*Plan.BinopExp = try planner.gpa.create(Plan.BinopExp);
    errdefer if (binop) |b| {
        var exp = Plan.Exp{ .binop = b };
        exp.deinit(planner.gpa);
    };
    binop.?.* = .{
        .op = .eql,
        .left = .{ .ident = left_ident },
        .right = .{ .ident = right_ident },
    };
    const owned = binop.?;
    binop = null;
    try appendFilter(planner, .{ .bool_exp = .{ .binop = owned } });
}

fn appendPropertyFilter(planner: *Planner, ident: u16, property: Ast.Property) Error!void {
    var left = Plan.Exp{ .property = .{ .ident = ident, .key = try planner.gpa.dupe(u8, property.key) } };
    errdefer left.deinit(planner.gpa);
    var right = try planExpr(planner, property.value);
    errdefer right.deinit(planner.gpa);
    var binop: ?*Plan.BinopExp = try planner.gpa.create(Plan.BinopExp);
    errdefer if (binop) |b| {
        var exp = Plan.Exp{ .binop = b };
        exp.deinit(planner.gpa);
    };
    binop.?.* = .{ .op = .eql, .left = left, .right = right };
    left = .{ .ident = 0 };
    right = .{ .ident = 0 };
    const owned = binop.?;
    binop = null;
    try appendFilter(planner, .{ .bool_exp = .{ .binop = owned } });
}

fn appendFilter(planner: *Planner, clause: Plan.FilterClause) Error!void {
    var clauses = std.ArrayList(Plan.FilterClause).empty;
    errdefer {
        for (clauses.items) |*item| item.deinit(planner.gpa);
        clauses.deinit(planner.gpa);
    }
    var owned_clause = clause;
    errdefer owned_clause.deinit(planner.gpa);
    try clauses.append(planner.gpa, owned_clause);
    owned_clause = .{ .bool_exp = .{ .ident = 0 } };
    try planner.plan.ops.append(planner.gpa, .{ .filter = clauses });
}

fn planExpr(planner: *Planner, expr: Ast.Expr) Error!Plan.Exp {
    return switch (expr) {
        .literal => |value| .{ .literal = try value.dupe(planner.gpa) },
        .variable => |name| .{ .ident = (planner.bindings.get(name) orelse return error.UnknownIdentifier).ident },
        .property => |p| blk: {
            const binding = planner.bindings.get(p.variable) orelse return error.UnknownIdentifier;
            break :blk .{ .property = .{ .ident = binding.ident, .key = try planner.gpa.dupe(u8, p.property) } };
        },
        .unary => |unary| blk: {
            const planned = try planner.gpa.create(Plan.UnaryExp);
            errdefer planner.gpa.destroy(planned);
            var operand = try planExpr(planner, unary.operand);
            errdefer operand.deinit(planner.gpa);
            planned.* = .{ .op = unary.op, .operand = operand };
            operand = .{ .ident = 0 };
            break :blk .{ .unary = planned };
        },
        .binary => |bin| blk: {
            const planned = try planner.gpa.create(Plan.BinopExp);
            errdefer planner.gpa.destroy(planned);
            var left = try planExpr(planner, bin.left);
            errdefer left.deinit(planner.gpa);
            var right = try planExpr(planner, bin.right);
            errdefer right.deinit(planner.gpa);
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

fn exprName(gpa: Allocator, item: Ast.ReturnItem) Allocator.Error![]u8 {
    if (item.alias) |alias| return gpa.dupe(u8, alias);
    return switch (item.expr) {
        .variable => |name| gpa.dupe(u8, name),
        .property => |p| std.fmt.allocPrint(gpa, "{s}.{s}", .{ p.variable, p.property }),
        .literal => gpa.dupe(u8, "value"),
        .unary => gpa.dupe(u8, "expr"),
        .binary => gpa.dupe(u8, "expr"),
    };
}
