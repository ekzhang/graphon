//! Plan of execution for a graph database query.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Plan = @This();

const Snap = @import("vendor/snaptest.zig").Snap;
const snap = Snap.snap;

const EdgeDirection = @import("./types.zig").EdgeDirection;

/// Nodes that define the query plan.
nodes: std.ArrayListUnmanaged(Node) = .{},

/// Column names that will be returned by the query. Must match arity of results.
columns: std.ArrayListUnmanaged([]u8) = .{},

/// Release all allocated memory.
pub fn deinit(self: *Plan, allocator: Allocator) void {
    for (self.nodes.items) |*n| n.deinit(allocator);
    self.nodes.deinit(allocator);
    for (self.columns.items) |n| allocator.free(n);
    self.columns.deinit(allocator);
}

/// Pretty-print the provided query plan.
///
/// Example output:
///
/// ```
/// Plan{name, friend_name, duration}
///   NodeScan (%0:Person)
///   Step (%0)-[%1:Friend]-(%2)
///   Filter %2:Person, %2.age > %0.age + 3
///   Begin
///     Argument %2
///     Step (%2)-[:FavoriteFood]->(%3)
///     Filter %3.name = 'Pizza'
///   SemiJoin
///   Projection %4: %0.name, %5: %2.name, %6: %1.duration
/// ```
pub fn print(self: Plan, writer: anytype) !void {
    try writer.writeAll("Plan{");
    var first = true;
    for (self.columns.items) |c| {
        if (!first) try writer.writeAll(", ");
        try writer.writeAll(c);
        first = false;
    }
    try writer.writeByte('}');

    var level: usize = 1;
    for (self.nodes.items) |n| {
        const level_change: i32 = switch (n) {
            .begin => 1,
            .repeat, .semi_join, .join, .union_all => -1,
            else => 0,
        };
        if (level_change == -1 and level > 1) {
            level -= 1;
        }
        try writer.writeByte('\n');
        try writer.writeByteNTimes(' ', 2 * level);
        try n.print(writer);
        if (level_change == 1) {
            level += 1;
        }
    }
}

/// Check the value of a query plan, for snapshot testing.
fn check_plan_snapshot(plan: Plan, want: Snap) !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try plan.print(buf.writer());
    try want.diff(buf.items);
}

test "can create, free and print plan" {
    const allocator = std.testing.allocator;
    // MATCH (n) RETURN n AS my_node;
    var plan = Plan{};
    defer plan.deinit(std.testing.allocator);

    try plan.columns.append(allocator, try allocator.dupe(u8, "my_node"));
    try plan.nodes.append(allocator, Node{
        .node_scan = Scan{
            .ident = 0,
            .label = null,
        },
    });

    try check_plan_snapshot(plan, snap(@src(),
        \\Plan{my_node}
        \\  NodeScan (%0)
    ));

    try plan.nodes.append(allocator, Node{
        .step = Step{
            .ident_src = 0,
            .ident_edge = 1,
            .ident_dst = 2,
            .direction = .right_or_undirected,
            .edge_label = try allocator.dupe(u8, "Likes"),
        },
    });

    try check_plan_snapshot(plan, snap(@src(),
        \\Plan{my_node}
        \\  NodeScan (%0)
        \\  Step (%0)~[%1:Likes]~>(%2)
    ));
}

/// A node in the query plan, stored as a list.
pub const Node = union(enum) {
    node_scan: Scan,
    // node_by_id,
    rel_scan: Scan,
    // rel_by_id,
    step: Step,
    // step_between,
    begin: void,
    repeat, // unimplemented
    // shortest_path,
    join, // unimplemented
    semi_join, // unimplemented
    argument: u16,
    anti: void,
    projection: std.ArrayListUnmanaged(ProjectionClause),
    empty_result: void,
    // project_endpoints: ProjectEndpoints,
    filter: std.ArrayListUnmanaged(FilterClause),
    limit: u64,
    distinct: std.ArrayListUnmanaged(u16),
    skip: u64,
    sort: std.MultiArrayList(SortClause),
    top: u64,
    union_all: void,
    // update,
    insert_node: InsertNode,
    insert_edge: InsertEdge,
    // delete,
    // aggregate,
    // group_aggregate,

    /// Release all allocated memory.
    pub fn deinit(self: *Node, allocator: Allocator) void {
        switch (self.*) {
            .node_scan => |*n| n.deinit(allocator),
            .rel_scan => |*n| n.deinit(allocator),
            .step => |*n| n.deinit(allocator),
            .begin => {},
            .repeat => {},
            .join => {},
            .semi_join => {},
            .argument => {},
            .anti => {},
            .projection => |*n| {
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
    pub fn print(self: Node, writer: anytype) !void {
        const node_name = switch (self) {
            .node_scan => "NodeScan",
            .rel_scan => "RelScan",
            .step => "Step",
            .begin => "Begin",
            .repeat => "Repeat",
            .join => "Join",
            .semi_join => "SemiJoin",
            .argument => "Argument",
            .anti => "Anti",
            .projection => "Projection",
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
            .rel_scan => |n| {
                try writer.writeByte(' ');
                try print_edge_spec(writer, .any, n.ident, n.label);
            },
            .step => |n| {
                try writer.writeByte(' ');
                try print_node_spec(writer, n.ident_src, null);
                try print_edge_spec(writer, n.direction, n.ident_edge, n.edge_label);
                try print_node_spec(writer, n.ident_dst, null);
            },
            .begin => {},
            .repeat => @panic("repeat unimplemented"),
            .join => @panic("join unimplemented"),
            .semi_join => @panic("semi_join unimplemented"),
            .argument => |n| {
                try writer.print(" %{}", .{n});
            },
            .anti => {},
            .projection => |n| {
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
                try print_node_spec(writer, n.ident_dst, null);
            },
        }
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

    /// Release all allocated memory.
    pub fn deinit(self: *Scan, allocator: Allocator) void {
        if (self.label) |l| {
            allocator.free(l);
        }
    }
};

pub const Step = struct {
    ident_src: u16, // Name of the starting node.
    ident_edge: ?u16, // Name of the edge, to be bound.
    ident_dst: ?u16, // Name of the ending node, to be bound.
    direction: EdgeDirection,
    edge_label: ?[]u8, // Label to traverse on the edge.

    /// Release all allocated memory.
    pub fn deinit(self: *Step, allocator: Allocator) void {
        if (self.edge_label) |l| {
            allocator.free(l);
        }
    }
};

/// An ordered single item in the projection output. If an ident is not in any
/// clause, it is dropped. If exp is null, keep the existing value.
pub const ProjectionClause = struct {
    ident: u16,
    exp: Exp,

    /// Release all allocated memory.
    pub fn deinit(self: *ProjectionClause, allocator: Allocator) void {
        self.exp.deinit(allocator);
    }
};

/// A filter clause that can be applied to the query.
pub const FilterClause = union(enum) {
    bool_exp: Exp, // should be a boolean expression
    ident_label: struct {
        ident: u16,
        label: []u8,
    },

    /// Release all allocated memory.
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

    /// Release all allocated memory.
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
    ident_dst: u16,
    directed: bool,
    labels: std.ArrayListUnmanaged([]u8),
    properties: Properties,

    /// Release all allocated memory.
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

/// A low-level expression used by some query plan operators.
pub const Exp = union(enum) {
    literal_int: i64, // TODO: Replace literals with a value type later.
    literal_string: []u8,
    parameter: u32,
    binop: *BinopExp,

    /// Release all allocated memory.
    pub fn deinit(self: *Exp, allocator: Allocator) void {
        switch (self.*) {
            .literal_string => |s| allocator.free(s),
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
            .literal_int => |n| try writer.print("{}", .{n}),
            .literal_string => |s| try writer.print("'{s}'", .{s}),
            .parameter => |n| try writer.print("${}", .{n}),
            .binop => |b| {
                // todo: infix formatting / precedence is broken
                try b.left.print(writer);
                try writer.print(" %{} ", .{b.op});
                try b.right.print(writer);
            },
        }
    }
};

pub const BinopExp = struct {
    op: Binop,
    left: Exp,
    right: Exp,

    /// Release all allocated memory.
    pub fn deinit(self: *BinopExp, allocator: Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
        self.* = undefined;
    }
};

pub const Binop = enum {
    add,
    sub,
    mul,
    div,
};
