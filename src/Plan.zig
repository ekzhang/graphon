//! Plan of execution for a graph database query.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const EdgeDirection = types.EdgeDirection;
const Value = types.Value;

const Plan = @This();

/// Operators that define the query plan.
ops: std.ArrayListUnmanaged(Operator) = .{},

/// Results that will be returned by the query, one per value column.
results: std.ArrayListUnmanaged(u16) = .{},

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
        try writer.writeByteNTimes(' ', 2 * level);
        try op.print(writer);
        if (op.hasSubquery()) {
            level += 1;
        }
    }
}

fn idents_chk(ret: *u16, values: anytype) void {
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
            .node_scan => |n| idents_chk(&ret, .{n.ident}),
            .edge_scan => |n| idents_chk(&ret, .{n.ident}),
            .step => |n| idents_chk(&ret, .{ n.ident_edge, n.ident_dest }),
            .argument => |n| idents_chk(&ret, .{n}),
            .project => |n| {
                for (n.items) |c| idents_chk(&ret, .{c.ident});
            },
            .insert_node => |n| idents_chk(&ret, .{n.ident}),
            .insert_edge => |n| idents_chk(&ret, .{n.ident}),
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
    var i = op_index + 1;
    while (i < self.ops.items.len) : (i += 1) {
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

/// A single step in the query plan, which may depend on previous steps.
pub const Operator = union(enum) {
    node_scan: Scan,
    edge_scan: Scan,
    node_by_id: LookupId,
    edge_by_id: LookupId,
    step: Step,
    // step_between,
    begin,
    argument: u16, // unimplemented
    repeat, // unimplemented
    // shortest_path,
    join,
    semi_join,
    anti,
    project: std.ArrayListUnmanaged(ProjectClause),
    // project_endpoints: ProjectEndpoints,
    empty_result,
    filter: std.ArrayListUnmanaged(FilterClause),
    limit: u64,
    distinct: std.ArrayListUnmanaged(u16), // unimplemented
    skip: u64,
    sort: std.MultiArrayList(SortClause), // unimplemented
    top: u64, // unimplemented
    union_all,
    // update,
    insert_node: InsertNode,
    insert_edge: InsertEdge,
    // delete,
    // aggregate,
    // group_aggregate,

    pub fn deinit(self: *Operator, allocator: Allocator) void {
        switch (self.*) {
            .node_scan => |*n| n.deinit(allocator),
            .edge_scan => |*n| n.deinit(allocator),
            .node_by_id => {},
            .edge_by_id => {},
            .step => |*n| n.deinit(allocator),
            .begin => {},
            .argument => {},
            .repeat => {},
            .join => {},
            .semi_join => {},
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
            .union_all => {},
            .insert_node => |*n| n.deinit(allocator),
            .insert_edge => |*n| n.deinit(allocator),
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
            .begin => "Begin",
            .argument => "Argument",
            .repeat => "Repeat",
            .join => "Join",
            .semi_join => "SemiJoin",
            .anti => "Anti",
            .project => "Project",
            .empty_result => "EmptyResult",
            .filter => "Filter",
            .limit => "Limit",
            .distinct => "Distinct",
            .skip => "Skip",
            .sort => "Sort",
            .top => "Top",
            .union_all => "UnionAll",
            .insert_node => "InsertNode",
            .insert_edge => "InsertEdge",
        };
        try writer.writeAll(node_name);
        switch (self) {
            .node_scan => |n| {
                try writer.writeByte(' ');
                try print_node_spec(writer, n.ident, n.label);
            },
            .edge_scan => |n| {
                try writer.writeByte(' ');
                try print_edge_spec(writer, .any, n.ident, n.label);
            },
            .node_by_id => |n| {
                try writer.print(" %{} -> %{}", .{ n.ident_id, n.ident_ref });
            },
            .edge_by_id => |n| {
                try writer.print(" %{} -> %{}", .{ n.ident_id, n.ident_ref });
            },
            .step => |n| {
                try writer.writeByte(' ');
                try print_node_spec(writer, n.ident_src, null);
                try print_edge_spec(writer, n.direction, n.ident_edge, n.edge_label);
                try print_node_spec(writer, n.ident_dest, null);
            },
            .begin => {},
            .argument => |n| {
                try writer.print(" %{}", .{n});
            },
            .repeat => std.debug.panic("repeat unimplemented", .{}),
            .join => std.debug.panic("join unimplemented", .{}),
            .semi_join => std.debug.panic("semi_join unimplemented", .{}),
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
            .union_all => {},
            .insert_node => |n| {
                try writer.writeAll(" (");
                if (n.ident) |i| {
                    try writer.print("%{}", .{i});
                }
                try print_labels(writer, n.labels.items);
                try print_properties(writer, n.properties);
                try writer.writeByte(')');
            },
            .insert_edge => |n| {
                try writer.writeByte(' ');
                try print_node_spec(writer, n.ident_src, null);
                const direction: EdgeDirection = if (n.directed) .right else .undirected;
                try writer.writeAll(direction.leftPart());
                if (n.ident) |i| {
                    try writer.print("%{}", .{i});
                }
                try print_labels(writer, n.labels.items);
                try print_properties(writer, n.properties);
                try writer.writeAll(direction.rightPart());
                try print_node_spec(writer, n.ident_dest, null);
            },
        }
    }

    /// Return if this operator type has a subquery.
    pub fn hasSubquery(self: Operator) bool {
        return switch (self) {
            .repeat, .semi_join, .join, .union_all => true,
            else => false,
        };
    }
};

fn print_node_spec(writer: anytype, ident: ?u16, label: ?[]u8) !void {
    try writer.writeByte('(');
    if (ident) |i| {
        try writer.print("%{}", .{i});
    }
    if (label) |l| {
        try writer.print(":{s}", .{l});
    }
    try writer.writeByte(')');
}

fn print_edge_spec(writer: anytype, direction: EdgeDirection, ident: ?u16, label: ?[]u8) !void {
    try writer.writeAll(direction.leftPart());
    if (ident) |i| {
        try writer.print("%{}", .{i});
    }
    if (label) |l| {
        try writer.print(":{s}", .{l});
    }
    try writer.writeAll(direction.rightPart());
}

fn print_labels(writer: anytype, labels: [][]u8) !void {
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

pub fn print_properties(writer: anytype, properties: Properties) !void {
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

pub const InsertNode = struct {
    ident: ?u16,
    labels: std.ArrayListUnmanaged([]u8),
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
    labels: std.ArrayListUnmanaged([]u8),
    properties: Properties,

    pub fn deinit(self: *InsertEdge, allocator: Allocator) void {
        for (self.labels.items) |s| allocator.free(s);
        self.labels.deinit(allocator);

        for (self.properties.items(.key)) |k| allocator.free(k);
        for (self.properties.items(.value)) |*v| v.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

/// A list of properties for a node or edge.
pub const Properties = std.MultiArrayList(struct { key: []u8, value: Exp });

/// A low-level expression used by query plan operators.
pub const Exp = union(enum) {
    literal: Value,
    ident: u32,
    parameter: u32,
    binop: *BinopExp,

    pub fn deinit(self: *Exp, allocator: Allocator) void {
        switch (self.*) {
            .literal => |*v| v.deinit(allocator),
            .binop => |b| {
                b.deinit(allocator);
                allocator.destroy(b); // Needed because binop is a pointer.
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
            .parameter => |n| try writer.print("${}", .{n}),
            .binop => |b| {
                try writer.writeByte('(');
                try b.left.print(writer);
                try writer.print(" {s} ", .{b.op.string()});
                try b.right.print(writer);
                try writer.writeByte(')');
            },
        }
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

pub const Binop = enum {
    add,
    sub,
    eql,
    neq,

    fn string(self: Binop) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .eql => "=",
            .neq => "<>",
        };
    }
};

const Snap = @import("vendor/snaptest.zig").Snap;
const snap = Snap.snap;

/// Check the value of a query plan, for snapshot testing.
fn check_plan_snapshot(plan: Plan, want: Snap) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try plan.print(buf.writer());
    try want.diff(buf.items);
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

    try check_plan_snapshot(plan, snap(@src(),
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

    try check_plan_snapshot(plan, snap(@src(),
        \\Plan{%1, %2}
        \\  Step (%0)~[%1:Likes]~>(%2)
        \\  NodeScan (%0)
    ));

    try std.testing.expectEqual(3, plan.idents());
}
