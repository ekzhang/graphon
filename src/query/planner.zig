//! Lower parsed query ASTs into executable query plans.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringMap = std.array_hash_map.String;

const Ast = @import("../Ast.zig");
const Plan = @import("../Plan.zig");
const types = @import("../types.zig");

pub const Error = Allocator.Error || error{
    InvalidSyntax,
    Unsupported,
    UnknownIdentifier,
    WrongType,
    MalformedPlan,
};

pub const CompiledProgram = struct {
    value: union(enum) {
        statements: []CompiledStatement,
        parse_errors: Ast.ErrorList,
    },

    pub fn deinit(self: *CompiledProgram, gpa: Allocator) void {
        switch (self.value) {
            .statements => |statement_slice| {
                for (statement_slice) |*statement| statement.deinit(gpa);
                gpa.free(statement_slice);
            },
            .parse_errors => |*errors| errors.deinit(gpa),
        }
        self.* = undefined;
    }

    pub fn statements(self: *const CompiledProgram) Error![]CompiledStatement {
        return switch (self.value) {
            .statements => |statements_slice| statements_slice,
            .parse_errors => error.InvalidSyntax,
        };
    }

    pub fn takeParseErrors(self: *CompiledProgram) ?Ast.ErrorList {
        return switch (self.value) {
            .statements => null,
            .parse_errors => |errors| {
                self.value = .{ .statements = &.{} };
                return errors;
            },
        };
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
    if (parsed.errors.len > 0) {
        const errors = parsed.takeErrors();
        return .{ .value = .{ .parse_errors = errors } };
    }

    return try compileParsed(gpa, parsed);
}

fn compileParsed(gpa: Allocator, parsed: Ast.Program) Error!CompiledProgram {
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

    return .{ .value = .{ .statements = try statements.toOwnedSlice(gpa) } };
}

fn compileStatement(gpa: Allocator, statement: Ast.Statement) Error!CompiledStatement {
    var planner = Planner{ .gpa = gpa };
    defer planner.deinit();

    switch (statement) {
        .query => |query| return try appendRowQueryResult(gpa, &planner, query),
        .mutation => |mutation| switch (mutation) {
            .insert => |patterns| {
                try appendInsertPatterns(&planner, patterns);
                return appendMutationResult(&planner, .mutations);
            },
            .match => |mq| return try appendMatchStatementResult(gpa, &planner, mq),
        },
    }
}

fn appendMatchStatementResult(gpa: Allocator, planner: *Planner, mq: Ast.MatchQuery) Error!CompiledStatement {
    try appendMatchQuery(planner, mq);
    return switch (mq.action) {
        .ret => |ret| try appendReturnResult(gpa, planner, ret),
        .insert => |patterns| blk: {
            try appendInsertPatterns(planner, patterns);
            break :blk appendMutationResult(planner, .mutations);
        },
        .set => |sets| blk: {
            try appendUpdate(planner, sets);
            break :blk appendMutationResult(planner, .mutations);
        },
        .remove => |removes| blk: {
            try appendRemove(planner, removes);
            break :blk appendMutationResult(planner, .mutations);
        },
        .delete => |del| blk: {
            try appendDelete(planner, del);
            break :blk appendMutationResult(planner, .mutations);
        },
        .finish => appendMutationResult(planner, .rows),
    };
}

// ------------------------------ Planner -----------------------------------

const PlanBindingKind = enum { node, edge, scalar };

const PlanBinding = struct {
    ident: u16,
    kind: PlanBindingKind,
};

const Planner = struct {
    gpa: Allocator,
    plan: Plan = .{},
    bindings: StringMap(PlanBinding) = .empty,
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
    try appendReturnClause(planner, ret);

    const columns = try resultColumns(gpa, planner, ret);
    errdefer deinitResultColumns(gpa, columns);
    return .{
        .plan = takePlan(planner),
        .result = .{ .rows = columns },
    };
}

fn appendReturnClause(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    try appendResultProjection(planner, ret);
    try appendReturnAliases(planner, ret);
    try appendDistinct(planner, ret);
    try appendOrderBy(planner, ret);
    try appendSkipLimit(planner, ret);
}

fn appendRowQueryResult(gpa: Allocator, planner: *Planner, query: Ast.RowQuery) Error!CompiledStatement {
    try appendRowQuery(planner, query);

    const ret = rowQueryReturn(query);
    const columns = try resultColumns(gpa, planner, ret);
    errdefer deinitResultColumns(gpa, columns);
    return .{
        .plan = takePlan(planner),
        .result = .{ .rows = columns },
    };
}

fn appendReadQuery(planner: *Planner, query: Ast.ReadQuery) Error!void {
    for (query.clauses) |clause| {
        switch (clause) {
            .match => |match| try appendMatchClause(planner, match),
            .optional_match => |match| try appendOptionalMatchClause(planner, match),
            .with => |ret| try appendWithClause(planner, ret),
        }
    }
    try appendReturnClause(planner, query.ret);
}

fn appendUnionQuery(planner: *Planner, query: Ast.UnionQuery) Error!void {
    try appendQueryBody(planner, query.first);
    const output_idents = try planner.gpa.dupe(u16, planner.plan.results.items);
    defer planner.gpa.free(output_idents);
    planner.plan.results.clearRetainingCapacity();

    for (query.parts) |part| {
        planner.bindings.clearRetainingCapacity();
        try planner.plan.ops.append(planner.gpa, .begin);
        try appendQueryBody(planner, part.query);
        if (planner.plan.results.items.len != output_idents.len) return error.Unsupported;

        try appendUnionOutputProjection(planner, output_idents, planner.plan.results.items);
        planner.plan.results.clearRetainingCapacity();
        try planner.plan.ops.append(planner.gpa, .union_all);
        if (!part.all) try appendDistinctIdents(planner, output_idents);
    }

    try planner.plan.results.appendSlice(planner.gpa, output_idents);
}

fn appendRowQuery(planner: *Planner, query: Ast.RowQuery) Error!void {
    switch (query) {
        .single => |body| try appendQueryBody(planner, body),
        .union_query => |union_query| try appendUnionQuery(planner, union_query),
    }
}

fn appendQueryBody(planner: *Planner, query: Ast.QueryBody) Error!void {
    switch (query) {
        .return_only => |ret| try appendReturnClause(planner, ret),
        .read_query => |rq| try appendReadQuery(planner, rq),
        .match_query => |mq| {
            try appendMatchQuery(planner, mq);
            if (mq.action != .ret) return error.Unsupported;
            try appendReturnClause(planner, mq.action.ret);
        },
    }
}

fn rowQueryReturn(query: Ast.RowQuery) Ast.ReturnClause {
    return switch (query) {
        .single => |body| queryBodyReturn(body),
        .union_query => |union_query| queryBodyReturn(union_query.first),
    };
}

fn queryBodyReturn(query: Ast.QueryBody) Ast.ReturnClause {
    return switch (query) {
        .return_only => |ret| ret,
        .read_query => |rq| rq.ret,
        .match_query => |mq| mq.action.ret,
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

fn resultColumns(gpa: Allocator, planner: *Planner, ret: Ast.ReturnClause) Error![]ResultColumn {
    const columns = try gpa.alloc(ResultColumn, ret.items.len);
    for (columns) |*column| column.* = .{ .name = &.{}, .graph_value = false };
    errdefer deinitResultColumns(gpa, columns);

    for (ret.items, 0..) |item, i| {
        columns[i] = .{
            .name = try exprName(gpa, item),
            .graph_value = try itemReturnsGraphValue(planner, item),
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
        switch (set) {
            .property => |property| {
                const binding = planner.bindings.get(property.variable) orelse return error.UnknownIdentifier;
                var key: ?[]u8 = try planner.gpa.dupe(u8, property.property);
                errdefer if (key) |k| planner.gpa.free(k);
                var value: ?Plan.Exp = try planExpr(planner, property.value);
                errdefer if (value) |*v| v.deinit(planner.gpa);
                try items.append(planner.gpa, .{ .property = .{
                    .ident = binding.ident,
                    .key = key.?,
                    .value = value.?,
                } });
                key = null;
                value = null;
            },
            .label => |label| try appendLabelUpdate(planner, &items, .add, label),
        }
    }

    try planner.plan.ops.append(planner.gpa, .{ .update = .{ .items = items } });
    items = .empty;
}

fn appendRemove(planner: *Planner, removes: []const Ast.RemoveClause) Error!void {
    var items = std.ArrayList(Plan.UpdateClause).empty;
    errdefer {
        for (items.items) |*item| item.deinit(planner.gpa);
        items.deinit(planner.gpa);
    }

    for (removes) |remove| {
        switch (remove) {
            .label => |label| try appendLabelUpdate(planner, &items, .remove, label),
        }
    }

    try planner.plan.ops.append(planner.gpa, .{ .update = .{ .items = items } });
    items = .empty;
}

const LabelUpdateKind = enum { add, remove };

fn appendLabelUpdate(
    planner: *Planner,
    items: *std.ArrayList(Plan.UpdateClause),
    kind: LabelUpdateKind,
    label: Ast.LabelClause,
) Error!void {
    const binding = planner.bindings.get(label.variable) orelse return error.UnknownIdentifier;
    if (binding.kind == .scalar) return error.WrongType;
    var label_copy: ?[]u8 = try planner.gpa.dupe(u8, label.label);
    errdefer if (label_copy) |l| planner.gpa.free(l);
    const item: Plan.UpdateClause = switch (kind) {
        .add => .{ .add_label = .{ .ident = binding.ident, .label = label_copy.? } },
        .remove => .{ .remove_label = .{ .ident = binding.ident, .label = label_copy.? } },
    };
    try items.append(planner.gpa, item);
    label_copy = null;
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
    try appendMatchClause(planner, .{ .patterns = mq.patterns, .where = mq.where });
}

fn appendMatchClause(planner: *Planner, clause: Ast.MatchClause) Error!void {
    try appendMatchPatterns(planner, clause.patterns);
    if (clause.where) |where| {
        try appendWhere(planner, where);
    }
}

fn appendWhere(planner: *Planner, where: Ast.WherePredicate) Error!void {
    switch (where) {
        .expr => |expr| try appendFilter(planner, .{ .bool_exp = try planExpr(planner, expr) }),
        .path_pattern => |pattern| try appendPatternPredicate(planner, pattern, false),
        .not_path_pattern => |pattern| try appendPatternPredicate(planner, pattern, true),
    }
}

fn appendPatternPredicate(planner: *Planner, pattern: Ast.PathPattern, negate: bool) Error!void {
    try planner.plan.ops.append(planner.gpa, .begin);
    try appendPathPattern(planner, pattern);
    if (negate) {
        try planner.plan.ops.append(planner.gpa, .anti);
        try planner.plan.ops.append(planner.gpa, .join);
    } else {
        try planner.plan.ops.append(planner.gpa, .semi_join);
    }
}

fn appendMatchPatterns(planner: *Planner, patterns: []Ast.PathPattern) Error!void {
    for (patterns, 0..) |pattern, i| {
        if (i > 0) try planner.plan.ops.append(planner.gpa, .begin);
        try appendPathPattern(planner, pattern);
        if (i > 0) try planner.plan.ops.append(planner.gpa, .join);
    }
}

fn appendOptionalMatchClause(planner: *Planner, clause: Ast.MatchClause) Error!void {
    try planner.plan.ops.append(planner.gpa, .begin);
    try appendMatchClause(planner, clause);
    try planner.plan.ops.append(planner.gpa, .optional_join);
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

fn appendResultProjection(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    if (returnHasAggregates(ret)) {
        try appendAggregateProjection(planner, ret);
    } else {
        try appendReturnProjection(planner, ret);
    }
}

fn appendAggregateProjection(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    var before_project = std.ArrayList(Plan.ProjectClause).empty;
    errdefer {
        for (before_project.items) |*clause| clause.deinit(planner.gpa);
        before_project.deinit(planner.gpa);
    }

    var after_project = std.ArrayList(Plan.ProjectClause).empty;
    errdefer {
        for (after_project.items) |*clause| clause.deinit(planner.gpa);
        after_project.deinit(planner.gpa);
    }

    var aggregate = Plan.Aggregate{};
    errdefer aggregate.deinit(planner.gpa);

    for (ret.items) |item| {
        if (exprHasAggregate(item.expr)) {
            if (exprHasRowValueOutsideAggregate(item.expr)) return error.Unsupported;

            var exp = try planAggregateExpr(planner, item.expr, &aggregate);
            errdefer exp.deinit(planner.gpa);
            if (exp == .ident) {
                try planner.plan.results.append(planner.gpa, @intCast(exp.ident));
            } else {
                const ident = planner.allocIdent();
                try after_project.append(planner.gpa, .{ .ident = ident, .exp = exp });
                exp = .{ .ident = 0 };
                try planner.plan.results.append(planner.gpa, ident);
            }
        } else {
            const ident = try appendGroupKey(planner, &before_project, item.expr);
            try aggregate.groups.append(planner.gpa, ident);
            try planner.plan.results.append(planner.gpa, ident);
        }
    }

    if (aggregate.items.items.len == 0) return error.Unsupported;

    if (before_project.items.len > 0) {
        try planner.plan.ops.append(planner.gpa, .{ .project = before_project });
        before_project = .empty;
    } else {
        before_project.deinit(planner.gpa);
    }
    try planner.plan.ops.append(planner.gpa, if (canUseOrderedAggregate(planner, aggregate))
        .{ .ordered_aggregate = aggregate }
    else
        .{ .aggregate = aggregate });
    aggregate = .{};
    if (after_project.items.len > 0) {
        try planner.plan.ops.append(planner.gpa, .{ .project = after_project });
        after_project = .empty;
    } else {
        after_project.deinit(planner.gpa);
    }
}

fn appendGroupKey(planner: *Planner, project: *std.ArrayList(Plan.ProjectClause), expr: Ast.Expr) Error!u16 {
    if (expr == .variable) {
        if (planner.bindings.get(expr.variable)) |binding| return binding.ident;
    }

    const ident = planner.allocIdent();
    var exp = try planExpr(planner, expr);
    errdefer exp.deinit(planner.gpa);
    try project.append(planner.gpa, .{ .ident = ident, .exp = exp });
    exp = .{ .ident = 0 };
    return ident;
}

const SortClauses = std.MultiArrayList(Plan.SortClause).Slice;

fn canUseOrderedAggregate(planner: *Planner, aggregate: Plan.Aggregate) bool {
    if (aggregate.groups.items.len == 0) return true;
    if (planner.plan.ops.items.len == 0) return false;
    return switch (planner.plan.ops.getLast()) {
        .sort => |sort| sortPrefixContainsGroups(sort.slice(), aggregate.groups.items),
        .top => |top| sortPrefixContainsGroups(top.clauses.slice(), aggregate.groups.items),
        else => false,
    };
}

fn sortPrefixContainsGroups(clauses: SortClauses, groups: []const u16) bool {
    if (clauses.len < groups.len) return false;
    for (groups) |group| {
        var found = false;
        for (0..groups.len) |i| {
            if (clauses.get(i).ident == group) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn planAggregateExpr(planner: *Planner, expr: Ast.Expr, aggregate: *Plan.Aggregate) Error!Plan.Exp {
    return switch (expr) {
        .aggregate => |call| try appendAggregateCall(planner, call, aggregate),
        .literal => |value| .{ .literal = try value.dupe(planner.gpa) },
        .unary => |unary| blk: {
            const planned = try planner.gpa.create(Plan.UnaryExp);
            errdefer planner.gpa.destroy(planned);
            var operand = try planAggregateExpr(planner, unary.operand, aggregate);
            errdefer operand.deinit(planner.gpa);
            planned.* = .{ .op = unary.op, .operand = operand };
            operand = .{ .ident = 0 };
            break :blk .{ .unary = planned };
        },
        .binary => |bin| blk: {
            const planned = try planner.gpa.create(Plan.BinopExp);
            errdefer planner.gpa.destroy(planned);
            var left = try planAggregateExpr(planner, bin.left, aggregate);
            errdefer left.deinit(planner.gpa);
            var right = try planAggregateExpr(planner, bin.right, aggregate);
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
        .index => |index| blk: {
            const planned = try planner.gpa.create(Plan.IndexExp);
            errdefer planner.gpa.destroy(planned);
            var base = try planAggregateExpr(planner, index.base, aggregate);
            errdefer base.deinit(planner.gpa);
            var index_exp = try planAggregateExpr(planner, index.index, aggregate);
            errdefer index_exp.deinit(planner.gpa);
            planned.* = .{ .base = base, .index = index_exp };
            base = .{ .ident = 0 };
            index_exp = .{ .ident = 0 };
            break :blk .{ .index = planned };
        },
        .variable, .property => return error.Unsupported,
    };
}

fn appendAggregateCall(planner: *Planner, call: *Ast.AggregateCall, aggregate: *Plan.Aggregate) Error!Plan.Exp {
    if (call.function != .count and call.argument == null) return error.Unsupported;
    if (call.distinct and call.argument == null) return error.Unsupported;
    if (call.argument) |argument| {
        if (exprHasAggregate(argument)) return error.Unsupported;
    }

    const ident = planner.allocIdent();
    var argument: ?Plan.Exp = null;
    errdefer if (argument) |*exp| exp.deinit(planner.gpa);
    if (call.argument) |arg| argument = try planExpr(planner, arg);
    try aggregate.items.append(planner.gpa, .{
        .ident = ident,
        .function = call.function,
        .distinct = call.distinct,
        .argument = argument,
    });
    argument = null;
    return .{ .ident = ident };
}

fn appendReturnAliases(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    for (ret.items, planner.plan.results.items[0..ret.items.len]) |item, ident| {
        if (item.alias) |alias| {
            try planner.bind(alias, try itemBindingKind(planner, item), ident);
        }
    }
}

fn appendDistinct(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    if (!ret.distinct) return;

    var idents = std.ArrayList(u16).empty;
    errdefer idents.deinit(planner.gpa);
    try idents.appendSlice(planner.gpa, planner.plan.results.items[0..ret.items.len]);
    try planner.plan.ops.append(planner.gpa, .{ .distinct = idents });
    idents = .empty;
}

fn appendDistinctIdents(planner: *Planner, idents: []const u16) Error!void {
    var owned = std.ArrayList(u16).empty;
    errdefer owned.deinit(planner.gpa);
    try owned.appendSlice(planner.gpa, idents);
    try planner.plan.ops.append(planner.gpa, .{ .distinct = owned });
    owned = .empty;
}

fn appendUnionOutputProjection(planner: *Planner, output_idents: []const u16, branch_idents: []const u16) Error!void {
    var project = std.ArrayList(Plan.ProjectClause).empty;
    errdefer {
        for (project.items) |*clause| clause.deinit(planner.gpa);
        project.deinit(planner.gpa);
    }

    for (output_idents, branch_idents) |output_ident, branch_ident| {
        if (output_ident == branch_ident) continue;
        try project.append(planner.gpa, .{
            .ident = output_ident,
            .exp = .{ .ident = branch_ident },
        });
    }

    if (project.items.len > 0) {
        try planner.plan.ops.append(planner.gpa, .{ .project = project });
        project = .empty;
    } else {
        project.deinit(planner.gpa);
    }
}

fn appendWithClause(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    std.debug.assert(planner.plan.results.items.len == 0);
    try appendResultProjection(planner, ret);
    try appendReturnAliases(planner, ret);
    try appendDistinct(planner, ret);
    try appendOrderBy(planner, ret);
    try appendSkipLimit(planner, ret);

    const idents = try planner.gpa.dupe(u16, planner.plan.results.items[0..ret.items.len]);
    defer planner.gpa.free(idents);
    planner.plan.results.clearRetainingCapacity();

    var bindings: StringMap(PlanBinding) = .empty;
    defer bindings.deinit(planner.gpa);
    for (ret.items, idents) |item, ident| {
        const name = try withBindingName(item);
        try bindings.put(planner.gpa, name, .{ .ident = ident, .kind = try itemBindingKind(planner, item) });
    }

    planner.bindings.clearRetainingCapacity();
    var it = bindings.iterator();
    while (it.next()) |entry| {
        try planner.bindings.put(planner.gpa, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn appendSkipLimit(planner: *Planner, ret: Ast.ReturnClause) Error!void {
    if (ret.skip > 0) {
        try planner.plan.ops.append(planner.gpa, .{ .skip = @intCast(ret.skip) });
    }
    if (ret.limit) |limit| {
        // Memory optimization: Sort + Limit = Top.
        if (planner.plan.ops.items.len > 0 and planner.plan.ops.getLast() == .sort) {
            const idx = planner.plan.ops.items.len - 1;
            const clauses = planner.plan.ops.items[idx].sort;
            planner.plan.ops.items[idx] = .{
                .top = Plan.Top{
                    .count = @intCast(limit),
                    .clauses = clauses,
                },
            };
        } else {
            try planner.plan.ops.append(planner.gpa, .{ .limit = @intCast(limit) });
        }
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
        if (orderByBinding(planner, item.expr)) |ident| {
            try sort.append(planner.gpa, .{ .ident = ident, .desc = item.desc });
            continue;
        }

        const ident = planner.allocIdent();
        var exp = try planExpr(planner, item.expr);
        errdefer exp.deinit(planner.gpa);
        try project.append(planner.gpa, .{ .ident = ident, .exp = exp });
        exp = .{ .ident = 0 };
        try sort.append(planner.gpa, .{ .ident = ident, .desc = item.desc });
    }

    if (project.items.len > 0) {
        try planner.plan.ops.append(planner.gpa, .{ .project = project });
        project = .empty;
    }
    try planner.plan.ops.append(planner.gpa, .{ .sort = sort });
    sort = .{};
}

fn orderByBinding(planner: *Planner, expr: Ast.Expr) ?u16 {
    return switch (expr) {
        .variable => |name| if (planner.bindings.get(name)) |binding| binding.ident else null,
        else => null,
    };
}

fn appendPathPattern(planner: *Planner, pattern: Ast.PathPattern) Error!void {
    if (try pathPatternAnchor(planner, pattern)) |anchor| {
        try appendNodeFilters(planner, anchor.ident, pathPatternNode(pattern, anchor.node_i), false);

        var current = anchor.ident;
        var segment_i = anchor.node_i;
        while (segment_i > 0) {
            segment_i -= 1;
            const segment = pattern.segments[segment_i];
            if (segment.repeat != null) return error.Unsupported;
            current = try appendPathTraversal(
                planner,
                current,
                pathPatternNode(pattern, segment_i),
                segment.edge,
                segment.edge.direction.reverse(),
            );
        }

        current = anchor.ident;
        segment_i = anchor.node_i;
        while (segment_i < pattern.segments.len) : (segment_i += 1) {
            const segment = pattern.segments[segment_i];
            current = if (segment.repeat) |repeat|
                try appendPathRepeatTraversal(planner, pattern.mode, current, pathPatternNode(pattern, segment_i + 1), segment.edge, repeat)
            else
                try appendPathTraversal(
                    planner,
                    current,
                    pathPatternNode(pattern, segment_i + 1),
                    segment.edge,
                    segment.edge.direction,
                );
        }
        return;
    }

    var current = try appendNodeStart(planner, pattern.start);
    for (pattern.segments) |segment| {
        current = if (segment.repeat) |repeat|
            try appendPathRepeatTraversal(planner, pattern.mode, current, segment.node, segment.edge, repeat)
        else
            try appendPathTraversal(planner, current, segment.node, segment.edge, segment.edge.direction);
    }
}

const PathPatternAnchor = struct {
    node_i: usize,
    ident: u16,
};

fn pathPatternAnchor(planner: *Planner, pattern: Ast.PathPattern) Error!?PathPatternAnchor {
    const node_count = pattern.segments.len + 1;
    for (0..node_count) |node_i| {
        if (try boundNodeIdent(planner, pathPatternNode(pattern, node_i))) |ident| {
            return .{ .node_i = node_i, .ident = ident };
        }
    }
    return null;
}

fn pathPatternNode(pattern: Ast.PathPattern, node_i: usize) Ast.NodePattern {
    if (node_i == 0) return pattern.start;
    return pattern.segments[node_i - 1].node;
}

fn boundNodeIdent(planner: *Planner, pattern: Ast.NodePattern) Error!?u16 {
    if (pattern.variable) |name| {
        if (planner.bindings.get(name)) |binding| {
            if (binding.kind != .node) return error.WrongType;
            return binding.ident;
        }
    }
    return null;
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

fn appendPathRepeatTraversal(
    planner: *Planner,
    mode: Ast.PathMode,
    current: u16,
    dest_pattern: Ast.NodePattern,
    edge_pattern: Ast.EdgePattern,
    repeat: Ast.PathRepeat,
) Error!u16 {
    const existing_dest = try boundNodeIdent(planner, dest_pattern);
    const dest_ident = existing_dest orelse planner.allocIdent();
    if (dest_pattern.variable) |name| {
        if (existing_dest == null) try planner.bind(name, .node, dest_ident);
    }

    const argument_ident = planner.allocIdent();
    const frontier_ident = planner.allocIdent();
    const needs_edge_ident =
        mode == .trail or
        edge_pattern.variable != null or
        edge_pattern.properties.len > 0;
    const edge_ident: ?u16 = if (needs_edge_ident) planner.allocIdent() else null;

    var accumulators = std.ArrayList(Plan.RepeatAccumulator).empty;
    errdefer accumulators.deinit(planner.gpa);
    if (edge_pattern.variable) |name| {
        if (planner.bindings.get(name) != null) return error.Unsupported;
        const ident = planner.allocIdent();
        try planner.bind(name, .scalar, ident);
        try accumulators.append(planner.gpa, .{ .ident = ident, .item_ident = edge_ident.? });
    }

    try planner.plan.ops.append(planner.gpa, .begin);
    try planner.plan.ops.append(planner.gpa, .{ .argument = argument_ident });

    var edge_label: ?[]u8 = if (edge_pattern.label) |label| try planner.gpa.dupe(u8, label) else null;
    errdefer if (edge_label) |label| planner.gpa.free(label);
    try planner.plan.ops.append(planner.gpa, .{ .step = .{
        .ident_src = argument_ident,
        .ident_edge = edge_ident,
        .ident_dest = frontier_ident,
        .direction = edge_pattern.direction,
        .edge_label = edge_label,
    } });
    edge_label = null;
    if (edge_ident) |ident| try appendEdgeFilters(planner, ident, edge_pattern);

    try planner.plan.ops.append(planner.gpa, .{ .repeat = .{
        .mode = planPathMode(mode),
        .ident_start = current,
        .ident_argument = argument_ident,
        .ident_frontier = frontier_ident,
        .ident_dest = dest_ident,
        .ident_trail_edge = if (mode == .trail) edge_ident else null,
        .dest_bound = existing_dest != null,
        .min = repeat.min,
        .max = repeat.max,
        .accumulators = accumulators,
    } });
    accumulators = .empty;

    try appendNodeFilters(planner, dest_ident, dest_pattern, false);
    return dest_ident;
}

fn planPathMode(mode: Ast.PathMode) Plan.PathMode {
    return switch (mode) {
        .walk => .walk,
        .trail => .trail,
    };
}

fn appendPathTraversal(
    planner: *Planner,
    current: u16,
    dest_pattern: Ast.NodePattern,
    edge_pattern: Ast.EdgePattern,
    direction: types.EdgeDirection,
) Error!u16 {
    const existing_dest = try boundNodeIdent(planner, dest_pattern);
    const existing_edge = if (edge_pattern.variable) |name| blk: {
        if (planner.bindings.get(name)) |binding| {
            if (binding.kind != .edge) return error.WrongType;
            break :blk binding.ident;
        }
        break :blk null;
    } else null;

    const needs_edge_ident =
        edge_pattern.variable != null or
        edge_pattern.properties.len > 0 or
        existing_edge != null;
    const edge_ident: ?u16 = if (needs_edge_ident) planner.allocIdent() else null;
    const dest_ident = existing_dest orelse planner.allocIdent();

    if (edge_pattern.variable) |name| {
        if (existing_edge == null) try planner.bind(name, .edge, edge_ident.?);
    }
    if (dest_pattern.variable) |name| {
        if (existing_dest == null) try planner.bind(name, .node, dest_ident);
    }

    var edge_label: ?[]u8 = if (edge_pattern.label) |label| try planner.gpa.dupe(u8, label) else null;
    errdefer if (edge_label) |label| planner.gpa.free(label);
    if (existing_dest != null) {
        try appendNodeFilters(planner, dest_ident, dest_pattern, false);
        try planner.plan.ops.append(planner.gpa, .{ .step_between = .{
            .ident_src = current,
            .ident_edge = edge_ident,
            .ident_dest = dest_ident,
            .direction = direction,
            .edge_label = edge_label,
        } });
    } else {
        try planner.plan.ops.append(planner.gpa, .{ .step = .{
            .ident_src = current,
            .ident_edge = edge_ident,
            .ident_dest = dest_ident,
            .direction = direction,
            .edge_label = edge_label,
        } });
        try appendNodeFilters(planner, dest_ident, dest_pattern, false);
    }
    edge_label = null;

    if (edge_ident) |ident| try appendEdgeFilters(planner, ident, edge_pattern);
    if (existing_edge) |ident| try appendIdentEqualityFilter(planner, edge_ident.?, ident);
    return dest_ident;
}

fn appendNodeFilters(planner: *Planner, ident: u16, pattern: Ast.NodePattern, label_in_scan: bool) Error!void {
    if (!label_in_scan) {
        if (pattern.label) |label| {
            var label_copy: ?[]u8 = try planner.gpa.dupe(u8, label);
            errdefer if (label_copy) |owned| planner.gpa.free(owned);
            try appendFilter(planner, .{ .ident_label = .{ .ident = ident, .label = label_copy.? } });
            label_copy = null;
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
        .index => |index| blk: {
            const planned = try planner.gpa.create(Plan.IndexExp);
            errdefer planner.gpa.destroy(planned);
            var base = try planExpr(planner, index.base);
            errdefer base.deinit(planner.gpa);
            var index_exp = try planExpr(planner, index.index);
            errdefer index_exp.deinit(planner.gpa);
            planned.* = .{ .base = base, .index = index_exp };
            base = .{ .ident = 0 };
            index_exp = .{ .ident = 0 };
            break :blk .{ .index = planned };
        },
        .aggregate => return error.Unsupported,
    };
}

fn exprName(gpa: Allocator, item: Ast.ReturnItem) Allocator.Error![]u8 {
    if (item.alias) |alias| return gpa.dupe(u8, alias);
    return switch (item.expr) {
        .variable => |name| gpa.dupe(u8, name),
        .property => |p| std.fmt.allocPrint(gpa, "{s}.{s}", .{ p.variable, p.property }),
        .literal => gpa.dupe(u8, "value"),
        .aggregate => |call| gpa.dupe(u8, call.function.string()),
        .unary => gpa.dupe(u8, "expr"),
        .binary => gpa.dupe(u8, "expr"),
        .index => gpa.dupe(u8, "expr"),
    };
}

fn withBindingName(item: Ast.ReturnItem) Error![]const u8 {
    if (item.alias) |alias| return alias;
    return switch (item.expr) {
        .variable => |name| name,
        else => error.Unsupported,
    };
}

fn itemBindingKind(planner: *Planner, item: Ast.ReturnItem) Error!PlanBindingKind {
    return switch (item.expr) {
        .variable => |name| (planner.bindings.get(name) orelse return error.UnknownIdentifier).kind,
        .aggregate => .scalar,
        else => .scalar,
    };
}

fn itemReturnsGraphValue(planner: *Planner, item: Ast.ReturnItem) Error!bool {
    if (item.expr != .variable) return false;
    const binding = planner.bindings.get(item.expr.variable) orelse return error.UnknownIdentifier;
    return binding.kind == .node or binding.kind == .edge;
}

fn returnHasAggregates(ret: Ast.ReturnClause) bool {
    for (ret.items) |item| {
        if (exprHasAggregate(item.expr)) return true;
    }
    return false;
}

fn exprHasAggregate(expr: Ast.Expr) bool {
    return switch (expr) {
        .aggregate => true,
        .unary => |unary| exprHasAggregate(unary.operand),
        .binary => |binary| exprHasAggregate(binary.left) or exprHasAggregate(binary.right),
        .index => |index| exprHasAggregate(index.base) or exprHasAggregate(index.index),
        .literal, .variable, .property => false,
    };
}

fn exprHasRowValueOutsideAggregate(expr: Ast.Expr) bool {
    return switch (expr) {
        .aggregate => false,
        .unary => |unary| exprHasRowValueOutsideAggregate(unary.operand),
        .binary => |binary| exprHasRowValueOutsideAggregate(binary.left) or
            exprHasRowValueOutsideAggregate(binary.right),
        .index => |index| exprHasRowValueOutsideAggregate(index.base) or
            exprHasRowValueOutsideAggregate(index.index),
        .variable, .property => true,
        .literal => false,
    };
}
