//! Plan of execution for a graph database query.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const EdgeDirection = types.EdgeDirection;
const Value = types.Value;

const Plan = @This();

/// Operators that define the query plan.
ops: std.ArrayList(Operator) = .empty,

/// Results that will be returned by the query, one per value column.
results: std.ArrayList(u16) = .empty,

pub fn deinit(self: *Plan, allocator: Allocator) void {
    for (self.ops.items) |*op| op.deinit(allocator);
    self.ops.deinit(allocator);
    self.results.deinit(allocator);
}

/// Pretty-print the provided query plan.
///
/// As an example, given the query
///
/// ```
/// MATCH (a:Person)-[b:Friend]-(c:Person)
/// WHERE
///   c.age > a.age + 3
///   AND EXISTS ((c)-[:FavoriteFood]->(:Food {name: 'Pizza'})
/// RETURN a.name, c.name, b.duration AS duration
/// ```
///
/// One possible query plan is:
///
/// ```
/// Plan{%4, %5, %6}
///   Project %4: %0.name, %5: %2.name, %6: %1.duration
///   SemiJoin
///     Filter %3.name = 'Pizza'
///     Step (%2)-[:FavoriteFood]->(%3)
///     Argument %2
///   Begin
///   Filter %2:Person, %2.age > %0.age + 3
///   Step (%0)-[%1:Friend]-(%2)
///   NodeScan (%0:Person)
/// ```
pub fn print(self: Plan, writer: anytype) !void {
    try writer.writeAll("Plan{");
    var first = true;
    for (self.results.items) |r| {
        if (!first) try writer.writeAll(", ");
        try writer.print("%{}", .{r});
        first = false;
    }
    try writer.writeByte('}');

    var level: usize = 1;
    var idx = self.ops.items.len;
    while (idx > 0) : (idx -= 1) {
        const op = self.ops.items[idx - 1];
        if (op == .begin and level > 1) {
            level -= 1;
        }
        try writer.writeByte('\n');
        try writer.splatByteAll(' ', 2 * level);
        try op.print(writer);
        if (op.hasSubquery()) {
            level += 1;
        }
    }
}

fn identsChk(ret: *u16, values: anytype) void {
    inline for (values) |v| {
        if (@as(?u16, v)) |value| {
            if (value + 1 > ret.*) {
                ret.* = value + 1;
            }
        }
    }
}

/// Return the number of identifiers in the plan.
pub fn idents(self: Plan) u16 {
    var ret: u16 = 0;
    for (self.ops.items) |op| {
        switch (op) {
            .node_scan => |n| identsChk(&ret, .{n.ident}),
            .edge_scan => |n| identsChk(&ret, .{n.ident}),
            .step => |n| identsChk(&ret, .{ n.ident_edge, n.ident_dest }),
            .step_between => |n| identsChk(&ret, .{n.ident_edge}),
            .argument => |n| identsChk(&ret, .{n}),
            .repeat => |n| {
                identsChk(&ret, .{ n.ident_start, n.ident_argument, n.ident_frontier, n.ident_dest, n.ident_trail_edge });
                for (n.accumulators.items) |accumulator| identsChk(&ret, .{ accumulator.ident, accumulator.item_ident });
            },
            .project => |n| {
                for (n.items) |c| identsChk(&ret, .{c.ident});
            },
            .aggregate => |n| {
                for (n.groups.items) |ident| identsChk(&ret, .{ident});
                for (n.items.items) |c| identsChk(&ret, .{c.ident});
            },
            .insert_node => |n| identsChk(&ret, .{n.ident}),
            .insert_edge => |n| identsChk(&ret, .{n.ident}),
            .update => |n| {
                for (n.items.items) |c| identsChk(&ret, .{c.ident});
            },
            .delete => |n| {
                for (n.idents.items) |ident| identsChk(&ret, .{ident});
            },
            else => {},
        }
    }
    return ret;
}

/// Given a join-style operation's index, return the index of the matching 'Begin'
/// operation or null if not found.
pub fn subqueryBegin(self: Plan, op_index: u32) ?u32 {
    std.debug.assert(self.ops.items[op_index].hasSubquery());
    var level: u32 = 1;
    var i = op_index;
    while (i > 0) {
        i -= 1;
        const op = self.ops.items[i];
        if (op == .begin) {
            if (level == 1) {
                return i;
            }
            level -= 1;
        } else if (op.hasSubquery()) {
            level += 1;
        }
    }
    return null;
}

/// Return all identifiers defined by a join-style operation's right subquery.
pub fn subqueryDefinedIdents(self: Plan, allocator: Allocator, op_index: u32) Allocator.Error!?std.ArrayList(u16) {
    const begin = self.subqueryBegin(op_index) orelse return null;
    var defined = std.ArrayList(u16).empty;
    errdefer defined.deinit(allocator);

    const start: usize = @intCast(begin + 1);
    const end: usize = @intCast(op_index);
    for (self.ops.items[start..end]) |op| {
        try op.appendDefinedIdents(allocator, &defined);
    }
    return defined;
}

/// A single step in the query plan, which may depend on previous steps.
pub const Operator = union(enum) {
    node_scan: Scan,
    edge_scan: Scan,
    node_by_id: LookupId,
    edge_by_id: LookupId,
    step: Step,
    step_between: StepBetween,
    begin,
    argument: u16,
    repeat: Repeat,
    // shortest_path,
    join,
    semi_join,
    optional_join,
    anti,
    project: std.ArrayList(ProjectClause),
    // project_endpoints: ProjectEndpoints,
    empty_result,
    filter: std.ArrayList(FilterClause),
    limit: u64,
    distinct: std.ArrayList(u16),
    skip: u64,
    sort: std.MultiArrayList(SortClause),
    top: u64, // unimplemented
    union_all,
    update: Update,
    insert_node: InsertNode,
    insert_edge: InsertEdge,
    delete: Delete,
    aggregate: Aggregate,
    // ordered_aggregate,

    pub fn deinit(self: *Operator, allocator: Allocator) void {
        switch (self.*) {
            .node_scan => |*n| n.deinit(allocator),
            .edge_scan => |*n| n.deinit(allocator),
            .node_by_id => {},
            .edge_by_id => {},
            .step => |*n| n.deinit(allocator),
            .step_between => |*n| n.deinit(allocator),
            .begin => {},
            .argument => {},
            .repeat => |*n| n.deinit(allocator),
            .join => {},
            .semi_join => {},
            .optional_join => {},
            .anti => {},
            .project => |*n| {
                for (n.items) |*c| c.deinit(allocator);
                n.deinit(allocator);
            },
            .empty_result => {},
            .filter => |*n| {
                for (n.items) |*c| c.deinit(allocator);
                n.deinit(allocator);
            },
            .limit => {},
            .distinct => |*n| n.deinit(allocator),
            .skip => {},
            .sort => |*n| n.deinit(allocator),
            .top => {},
            .aggregate => |*n| n.deinit(allocator),
            .union_all => {},
            .update => |*n| n.deinit(allocator),
            .insert_node => |*n| n.deinit(allocator),
            .insert_edge => |*n| n.deinit(allocator),
            .delete => |*n| n.deinit(allocator),
        }
        self.* = undefined;
    }

    /// Pretty-print a query plan node.
    pub fn print(self: Operator, writer: anytype) !void {
        const node_name = switch (self) {
            .node_scan => "NodeScan",
            .edge_scan => "EdgeScan",
            .node_by_id => "NodeById",
            .edge_by_id => "EdgeById",
            .step => "Step",
            .step_between => "StepBetween",
            .begin => "Begin",
            .argument => "Argument",
            .repeat => "Repeat",
            .join => "Join",
            .semi_join => "SemiJoin",
            .optional_join => "OptionalJoin",
            .anti => "Anti",
            .project => "Project",
            .empty_result => "EmptyResult",
            .filter => "Filter",
            .limit => "Limit",
            .distinct => "Distinct",
            .skip => "Skip",
            .sort => "Sort",
            .top => "Top",
            .aggregate => "Aggregate",
            .union_all => "UnionAll",
            .update => "Update",
            .insert_node => "InsertNode",
            .insert_edge => "InsertEdge",
            .delete => "Delete",
        };
        try writer.writeAll(node_name);
        switch (self) {
            .node_scan => |n| {
                try writer.writeByte(' ');
                try printNodeSpec(writer, n.ident, n.label);
            },
            .edge_scan => |n| {
                try writer.writeByte(' ');
                try printEdgeSpec(writer, .any, n.ident, n.label);
            },
            .node_by_id => |n| {
                try writer.print(" %{} -> %{}", .{ n.ident_id, n.ident_ref });
            },
            .edge_by_id => |n| {
                try writer.print(" %{} -> %{}", .{ n.ident_id, n.ident_ref });
            },
            .step => |n| {
                try writer.writeByte(' ');
                try printNodeSpec(writer, n.ident_src, null);
                try printEdgeSpec(writer, n.direction, n.ident_edge, n.edge_label);
                try printNodeSpec(writer, n.ident_dest, null);
            },
            .step_between => |n| {
                try writer.writeByte(' ');
                try printNodeSpec(writer, n.ident_src, null);
                try printEdgeSpec(writer, n.direction, n.ident_edge, n.edge_label);
                try printNodeSpec(writer, n.ident_dest, null);
            },
            .begin => {},
            .argument => |n| {
                try writer.print(" %{}", .{n});
            },
            .repeat => |n| {
                try writer.print(" {s} %{} -> %{} (%{} -> %{}){{{}, {}}}", .{
                    @tagName(n.mode),
                    n.ident_start,
                    n.ident_dest,
                    n.ident_argument,
                    n.ident_frontier,
                    n.min,
                    n.max,
                });
                if (n.dest_bound) try writer.writeAll(" bound");
                for (n.accumulators.items) |accumulator| {
                    try writer.print(" collect %{} <- %{}", .{ accumulator.ident, accumulator.item_ident });
                }
            },
            .join => {},
            .semi_join => {},
            .optional_join => {},
            .anti => {},
            .project => |n| {
                var first = true;
                for (n.items) |c| {
                    if (first) {
                        try writer.writeByte(' ');
                    } else {
                        try writer.writeAll(", ");
                    }
                    try writer.print("%{}: ", .{c.ident});
                    try c.exp.print(writer);
                    first = false;
                }
            },
            .empty_result => {},
            .filter => |n| {
                var first = true;
                for (n.items) |c| {
                    if (first) {
                        try writer.writeByte(' ');
                    } else {
                        try writer.writeAll(", ");
                    }
                    try c.print(writer);
                    first = false;
                }
            },
            .limit => |n| {
                try writer.print(" {}", .{n});
            },
            .distinct => |n| {
                var first = true;
                for (n.items) |i| {
                    if (first) {
                        try writer.writeByte(' ');
                    } else {
                        try writer.writeAll(", ");
                    }
                    try writer.print("%{}", .{i});
                    first = false;
                }
            },
            .skip => |n| {
                try writer.print(" {}", .{n});
            },
            .sort => |n| {
                for (0..n.len) |i| {
                    if (i == 0) {
                        try writer.writeByte(' ');
                    } else {
                        try writer.writeAll(", ");
                    }
                    const s = n.get(i);
                    try writer.print("%{} {s}", .{ s.ident, if (s.desc) "desc" else "asc" });
                }
            },
            .top => |n| {
                try writer.print(" {}", .{n});
            },
            .aggregate => |n| {
                var first = true;
                for (n.items.items) |c| {
                    if (first) {
                        try writer.writeByte(' ');
                    } else {
                        try writer.writeAll(", ");
                    }
                    try writer.print("%{}: {s}(", .{ c.ident, c.function.string() });
                    if (c.distinct) try writer.writeAll("distinct ");
                    if (c.argument) |argument| try argument.print(writer) else try writer.writeByte('*');
                    try writer.writeByte(')');
                    first = false;
                }
                if (n.groups.items.len > 0) {
                    try writer.writeAll(" BY ");
                    for (n.groups.items, 0..) |ident, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.print("%{}", .{ident});
                    }
                }
            },
            .union_all => {},
            .update => |n| {
                var first = true;
                for (n.items.items) |c| {
                    if (first) {
                        try writer.writeByte(' ');
                    } else {
                        try writer.writeAll(", ");
                    }
                    try writer.print("%{}.{s} = ", .{ c.ident, c.key });
                    try c.value.print(writer);
                    first = false;
                }
            },
            .insert_node => |n| {
                try writer.writeAll(" (");
                if (n.ident) |i| {
                    try writer.print("%{}", .{i});
                }
                try printLabels(writer, n.labels.items);
                try printProperties(writer, n.properties);
                try writer.writeByte(')');
            },
            .insert_edge => |n| {
                try writer.writeByte(' ');
                try printNodeSpec(writer, n.ident_src, null);
                const direction: EdgeDirection = if (n.directed) .right else .undirected;
                try writer.writeAll(direction.leftPart());
                if (n.ident) |i| {
                    try writer.print("%{}", .{i});
                }
                try printLabels(writer, n.labels.items);
                try printProperties(writer, n.properties);
                try writer.writeAll(direction.rightPart());
                try printNodeSpec(writer, n.ident_dest, null);
            },
            .delete => |n| {
                try writer.print(" {s}", .{if (n.detach) "Detach" else "NoDetach"});
                for (n.idents.items) |ident| {
                    try writer.print(" %{}", .{ident});
                }
            },
        }
    }

    /// Return if this operator type has a subquery.
    pub fn hasSubquery(self: Operator) bool {
        return switch (self) {
            .repeat, .semi_join, .optional_join, .join, .union_all => true,
            else => false,
        };
    }

    /// Append identifiers defined by this operator to the provided list.
    pub fn appendDefinedIdents(self: Operator, allocator: Allocator, defined: *std.ArrayList(u16)) Allocator.Error!void {
        switch (self) {
            .node_scan => |n| try defined.append(allocator, n.ident),
            .edge_scan => |n| try defined.append(allocator, n.ident),
            .node_by_id => |n| try defined.append(allocator, n.ident_ref),
            .edge_by_id => |n| try defined.append(allocator, n.ident_ref),
            .step => |n| {
                if (n.ident_edge) |ident| try defined.append(allocator, ident);
                if (n.ident_dest) |ident| try defined.append(allocator, ident);
            },
            .step_between => |n| {
                if (n.ident_edge) |ident| try defined.append(allocator, ident);
            },
            .argument => |n| try defined.append(allocator, n),
            .repeat => |n| {
                if (!n.dest_bound) try defined.append(allocator, n.ident_dest);
                for (n.accumulators.items) |accumulator| try defined.append(allocator, accumulator.ident);
            },
            .project => |n| {
                for (n.items) |c| try defined.append(allocator, c.ident);
            },
            .aggregate => |n| {
                for (n.items.items) |c| try defined.append(allocator, c.ident);
            },
            .insert_node => |n| if (n.ident) |ident| try defined.append(allocator, ident),
            .insert_edge => |n| if (n.ident) |ident| try defined.append(allocator, ident),
            else => {},
        }
    }
};

fn printNodeSpec(writer: anytype, ident: ?u16, label: ?[]u8) !void {
    try writer.writeByte('(');
    if (ident) |i| {
        try writer.print("%{}", .{i});
    }
    if (label) |l| {
        try writer.print(":{s}", .{l});
    }
    try writer.writeByte(')');
}

fn printEdgeSpec(writer: anytype, direction: EdgeDirection, ident: ?u16, label: ?[]u8) !void {
    try writer.writeAll(direction.leftPart());
    if (ident) |i| {
        try writer.print("%{}", .{i});
    }
    if (label) |l| {
        try writer.print(":{s}", .{l});
    }
    try writer.writeAll(direction.rightPart());
}

fn printLabels(writer: anytype, labels: [][]u8) !void {
    var first = true;
    for (labels) |l| {
        if (first) {
            try writer.writeByte(':');
        } else {
            try writer.writeByte('&');
        }
        try writer.writeAll(l);
        first = false;
    }
}

pub fn printProperties(writer: anytype, properties: Properties) !void {
    if (properties.len > 0) {
        try writer.writeAll(" {");
        for (0..properties.len) |i| {
            if (i > 0) {
                try writer.writeAll(", ");
            }
            const p = properties.get(i);
            try writer.print("{s}: ", .{p.key});
            try p.value.print(writer);
        }
        try writer.writeByte('}');
    }
}

pub const Scan = struct {
    ident: u16, // Name of the bound variable.
    label: ?[]u8,

    pub fn deinit(self: *Scan, allocator: Allocator) void {
        if (self.label) |l| {
            allocator.free(l);
        }
    }
};

pub const LookupId = struct {
    ident_ref: u16, // Name of the bound entity reference (output).
    ident_id: u16, // Name of the ID to look up (input).
};

pub const Step = struct {
    ident_src: u16, // Name of the starting node (input).
    ident_edge: ?u16, // Name of the edge, to be bound (output).
    ident_dest: ?u16, // Name of the ending node, to be bound (output).
    direction: EdgeDirection,
    edge_label: ?[]u8, // Label to traverse on the edge.

    pub fn deinit(self: *Step, allocator: Allocator) void {
        if (self.edge_label) |l| {
            allocator.free(l);
        }
    }
};

pub const StepBetween = struct {
    ident_src: u16, // Name of the starting node (input).
    ident_edge: ?u16, // Name of the edge, to be bound (output).
    ident_dest: u16, // Name of the ending node (input).
    direction: EdgeDirection,
    edge_label: ?[]u8, // Label to traverse on the edge.

    pub fn deinit(self: *StepBetween, allocator: Allocator) void {
        if (self.edge_label) |l| {
            allocator.free(l);
        }
    }
};

pub const PathMode = enum {
    walk,
    trail,
};

pub const Repeat = struct {
    mode: PathMode,
    ident_start: u16,
    ident_argument: u16,
    ident_frontier: u16,
    ident_dest: u16,
    ident_trail_edge: ?u16 = null,
    dest_bound: bool = false,
    min: usize,
    max: usize,
    accumulators: std.ArrayList(RepeatAccumulator) = .empty,

    pub fn deinit(self: *Repeat, allocator: Allocator) void {
        self.accumulators.deinit(allocator);
        self.* = undefined;
    }
};

pub const RepeatAccumulator = struct {
    ident: u16,
    item_ident: u16,
};

/// A new variable assignment made in a Project operator.
pub const ProjectClause = struct {
    ident: u16,
    exp: Exp,

    pub fn deinit(self: *ProjectClause, allocator: Allocator) void {
        self.exp.deinit(allocator);
    }
};

/// A filter clause that can be applied to the query.
pub const FilterClause = union(enum) {
    /// Include a row if the expression is truthy.
    bool_exp: Exp,

    /// CHeck that a node or edge has the given label.
    ident_label: struct {
        ident: u16,
        label: []u8,
    },

    pub fn deinit(self: *FilterClause, allocator: Allocator) void {
        switch (self.*) {
            .bool_exp => |*n| n.deinit(allocator),
            .ident_label => |*n| allocator.free(n.label),
        }
        self.* = undefined;
    }

    /// Pretty-print a filter clause.
    pub fn print(self: FilterClause, writer: anytype) !void {
        switch (self) {
            .bool_exp => |e| try e.print(writer),
            .ident_label => |f| try writer.print("%{}: {s}", .{ f.ident, f.label }),
        }
    }
};

pub const SortClause = struct {
    ident: u16,
    desc: bool,
};

pub const Aggregate = struct {
    groups: std.ArrayList(u16) = .empty,
    items: std.ArrayList(AggregateClause) = .empty,

    pub fn deinit(self: *Aggregate, allocator: Allocator) void {
        self.groups.deinit(allocator);
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }
};

pub const AggregateClause = struct {
    ident: u16,
    function: AggregateFunction,
    distinct: bool = false,
    argument: ?Exp,

    pub fn deinit(self: *AggregateClause, allocator: Allocator) void {
        if (self.argument) |*argument| argument.deinit(allocator);
        self.* = undefined;
    }
};

pub const AggregateFunction = enum {
    count,
    sum,
    avg,
    min,
    max,

    pub fn string(self: AggregateFunction) []const u8 {
        return switch (self) {
            .count => "count",
            .sum => "sum",
            .avg => "avg",
            .min => "min",
            .max => "max",
        };
    }
};

pub const InsertNode = struct {
    ident: ?u16,
    labels: std.ArrayList([]u8),
    properties: Properties,

    pub fn deinit(self: *InsertNode, allocator: Allocator) void {
        for (self.labels.items) |s| allocator.free(s);
        self.labels.deinit(allocator);

        for (self.properties.items(.key)) |k| allocator.free(k);
        for (self.properties.items(.value)) |*v| v.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const InsertEdge = struct {
    ident: ?u16,
    ident_src: u16,
    ident_dest: u16,
    directed: bool,
    labels: std.ArrayList([]u8),
    properties: Properties,

    pub fn deinit(self: *InsertEdge, allocator: Allocator) void {
        for (self.labels.items) |s| allocator.free(s);
        self.labels.deinit(allocator);

        for (self.properties.items(.key)) |k| allocator.free(k);
        for (self.properties.items(.value)) |*v| v.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const Update = struct {
    items: std.ArrayList(UpdateClause),

    pub fn deinit(self: *Update, allocator: Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
    }
};

pub const UpdateClause = struct {
    ident: u16,
    key: []u8,
    value: Exp,

    pub fn deinit(self: *UpdateClause, allocator: Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Delete = struct {
    detach: bool,
    idents: std.ArrayList(u16),

    pub fn deinit(self: *Delete, allocator: Allocator) void {
        self.idents.deinit(allocator);
        self.* = undefined;
    }
};

/// A list of properties for a node or edge.
pub const Properties = std.MultiArrayList(struct { key: []u8, value: Exp });

/// A low-level expression used by query plan operators.
pub const Exp = union(enum) {
    literal: Value,
    ident: u32,
    property: PropertyExp,
    parameter: u32,
    unary: *UnaryExp,
    binop: *BinopExp,
    index: *IndexExp,

    pub fn deinit(self: *Exp, allocator: Allocator) void {
        switch (self.*) {
            .literal => |*v| v.deinit(allocator),
            .property => |*p| p.deinit(allocator),
            .unary => |u| {
                u.deinit(allocator);
                allocator.destroy(u);
            },
            .binop => |b| {
                b.deinit(allocator);
                allocator.destroy(b); // Needed because binop is a pointer.
            },
            .index => |i| {
                i.deinit(allocator);
                allocator.destroy(i);
            },
            else => {},
        }
        self.* = undefined;
    }

    /// Pretty-print an expression.
    pub fn print(self: Exp, writer: anytype) !void {
        switch (self) {
            .literal => |v| try v.print(writer),
            .ident => |i| try writer.print("%{}", .{i}),
            .property => |p| try writer.print("%{}.{s}", .{ p.ident, p.key }),
            .parameter => |n| try writer.print("${}", .{n}),
            .unary => |u| {
                try writer.print("{s} ", .{u.op.string()});
                try u.operand.print(writer);
            },
            .binop => |b| {
                try writer.writeByte('(');
                try b.left.print(writer);
                try writer.print(" {s} ", .{b.op.string()});
                try b.right.print(writer);
                try writer.writeByte(')');
            },
            .index => |i| {
                try i.base.print(writer);
                try writer.writeByte('[');
                try i.index.print(writer);
                try writer.writeByte(']');
            },
        }
    }
};

pub const PropertyExp = struct {
    ident: u32,
    key: []u8,

    pub fn deinit(self: *PropertyExp, allocator: Allocator) void {
        allocator.free(self.key);
        self.* = undefined;
    }
};

pub const UnaryExp = struct {
    op: UnaryOp,
    operand: Exp,

    pub fn deinit(self: *UnaryExp, allocator: Allocator) void {
        self.operand.deinit(allocator);
        self.* = undefined;
    }
};

pub const UnaryOp = enum {
    not,

    fn string(self: UnaryOp) []const u8 {
        return switch (self) {
            .not => "NOT",
        };
    }
};

pub const BinopExp = struct {
    op: Binop,
    left: Exp,
    right: Exp,

    pub fn deinit(self: *BinopExp, allocator: Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
        self.* = undefined;
    }
};

pub const IndexExp = struct {
    base: Exp,
    index: Exp,

    pub fn deinit(self: *IndexExp, allocator: Allocator) void {
        self.base.deinit(allocator);
        self.index.deinit(allocator);
        self.* = undefined;
    }
};

pub const Binop = enum {
    add,
    sub,
    mul,
    eql,
    neq,
    lt,
    lte,
    gt,
    gte,
    and_,
    or_,

    fn string(self: Binop) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .eql => "=",
            .neq => "<>",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .and_ => "AND",
            .or_ => "OR",
        };
    }
};

const Snap = @import("vendor/snaptest.zig").Snap;
const snap = Snap.snap;

/// Check the value of a query plan, for snapshot testing.
fn checkPlanSnapshot(plan: Plan, want: Snap) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try plan.print(&out.writer);
    try want.diff(out.written());
}

test "can create, free and print plan" {
    const allocator = std.testing.allocator;
    // MATCH (n) RETURN n;
    var plan = Plan{};
    defer plan.deinit(allocator);

    try plan.results.append(allocator, 0);
    try plan.ops.append(allocator, Operator{
        .node_scan = Scan{
            .ident = 0,
            .label = null,
        },
    });

    try checkPlanSnapshot(plan, snap(@src(),
        \\Plan{%0}
        \\  NodeScan (%0)
    ));

    try plan.ops.append(allocator, Operator{
        .step = Step{
            .ident_src = 0,
            .ident_edge = 1,
            .ident_dest = 2,
            .direction = .right_or_undirected,
            .edge_label = try allocator.dupe(u8, "Likes"),
        },
    });
    plan.results.items[0] = 1;
    try plan.results.append(allocator, 2);

    try checkPlanSnapshot(plan, snap(@src(),
        \\Plan{%1, %2}
        \\  Step (%0)~[%1:Likes]~>(%2)
        \\  NodeScan (%0)
    ));

    try std.testing.expectEqual(3, plan.idents());
}

test "can print step between plan" {
    const allocator = std.testing.allocator;
    var plan = Plan{};
    defer plan.deinit(allocator);

    try plan.results.appendSlice(allocator, &[_]u16{ 0, 1, 2 });
    try plan.ops.append(allocator, .{ .node_scan = .{ .ident = 0, .label = null } });
    try plan.ops.append(allocator, .{ .node_scan = .{ .ident = 1, .label = null } });
    try plan.ops.append(allocator, .{ .step_between = .{
        .ident_src = 0,
        .ident_edge = 2,
        .ident_dest = 1,
        .direction = .right,
        .edge_label = try allocator.dupe(u8, "Knows"),
    } });

    try checkPlanSnapshot(plan, snap(@src(),
        \\Plan{%0, %1, %2}
        \\  StepBetween (%0)-[%2:Knows]->(%1)
        \\  NodeScan (%1)
        \\  NodeScan (%0)
    ));

    try std.testing.expectEqual(3, plan.idents());
}

test "subquery begin searches backward from join" {
    const allocator = std.testing.allocator;
    var plan = Plan{};
    defer plan.deinit(allocator);

    try plan.ops.append(allocator, .{
        .node_scan = .{
            .ident = 0,
            .label = null,
        },
    });
    try plan.ops.append(allocator, .begin);
    try plan.ops.append(allocator, .{
        .node_scan = .{
            .ident = 1,
            .label = null,
        },
    });
    try plan.ops.append(allocator, .join);

    try std.testing.expectEqual(@as(?u32, 1), plan.subqueryBegin(3));
}

test "subquery defined idents collects right-side definitions" {
    const allocator = std.testing.allocator;
    var plan = Plan{};
    defer plan.deinit(allocator);

    try plan.ops.append(allocator, .{
        .node_scan = .{
            .ident = 0,
            .label = null,
        },
    });
    try plan.ops.append(allocator, .begin);
    try plan.ops.append(allocator, .{
        .step = .{
            .ident_src = 0,
            .ident_edge = 1,
            .ident_dest = 2,
            .direction = .right,
            .edge_label = null,
        },
    });
    var project = std.ArrayList(ProjectClause).empty;
    errdefer {
        for (project.items) |*clause| clause.deinit(allocator);
        project.deinit(allocator);
    }
    try project.append(allocator, .{ .ident = 3, .exp = .{ .ident = 2 } });
    try plan.ops.append(allocator, .{ .project = project });
    project = .empty;
    try plan.ops.append(allocator, .optional_join);

    var defined = (try plan.subqueryDefinedIdents(allocator, 4)).?;
    defer defined.deinit(allocator);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, defined.items);
}
