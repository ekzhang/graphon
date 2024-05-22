//! Plan of execution for a graph database query.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Plan = @This();

const EdgeDirection = @import("./types.zig").EdgeDirection;

nodes: std.ArrayListUnmanaged(Node) = .{},
return_idents: std.ArrayListUnmanaged(u16) = .{},
return_names: std.ArrayListUnmanaged([]u8) = .{},

pub fn deinit(self: *Plan, allocator: Allocator) void {
    for (self.nodes.items) |*n| n.deinit(allocator);
    self.nodes.deinit(allocator);
    self.return_idents.deinit(allocator);
    for (self.return_names.items) |n| allocator.free(n);
    self.return_names.deinit(allocator);
}

test "can create and free plan" {
    const allocator = std.testing.allocator;
    var plan = Plan{};

    try plan.return_idents.append(allocator, 3);
    try plan.return_names.append(allocator, try allocator.dupe(u8, "some_column"));

    plan.deinit(std.testing.allocator);
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
    // repeat: Repeat,
    // shortest_path,
    // join,
    // semi_join,
    argument: u16,
    anti: void,
    projection: std.ArrayListUnmanaged(ProjectionClause),
    // project_endpoints: ProjectEndpoints,
    filter: Exp, // should be a boolean expression
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
            .argument => {},
            .anti => {},
            .projection => |*n| {
                for (n.items) |*c| c.deinit(allocator);
                n.deinit(allocator);
            },
            .filter => |*n| n.deinit(allocator),
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
};

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

/// An ordered single clause in the projection. Sets idents in the row equal to
/// the associated expressions.
pub const ProjectionClause = struct {
    ident: u16,
    exp: Exp,

    /// Release all allocated memory.
    pub fn deinit(self: *ProjectionClause, allocator: Allocator) void {
        self.exp.deinit(allocator);
    }
};

pub const SortClause = struct {
    name: u16,
    desc: bool,
};

pub const InsertNode = struct {
    ident: ?u16,
    labels: std.ArrayListUnmanaged([]u8),
    properties: std.MultiArrayList(struct { key: []u8, value: Exp }),

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
    properties: std.MultiArrayList(struct { key: []u8, value: Exp }),

    /// Release all allocated memory.
    pub fn deinit(self: *InsertEdge, allocator: Allocator) void {
        for (self.labels.items) |s| allocator.free(s);
        self.labels.deinit(allocator);

        for (self.properties.items(.key)) |k| allocator.free(k);
        for (self.properties.items(.value)) |*v| v.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

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
