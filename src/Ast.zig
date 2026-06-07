//! Typed AST for the currently supported Graphon query subset.
//!
//! This is intentionally smaller than ISO GQL. `Parse.zig` produces these
//! structs, and the query planner lowers them into `Plan.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Plan = @import("Plan.zig");
const types = @import("types.zig");
const EdgeDirection = types.EdgeDirection;
const Value = types.Value;

pub const Program = struct {
    statements: []Statement,

    pub fn deinit(self: *Program, allocator: Allocator) void {
        for (self.statements) |*statement| statement.deinit(allocator);
        allocator.free(self.statements);
        self.* = undefined;
    }
};

pub const Statement = union(enum) {
    return_only: ReturnClause,
    insert: []PathPattern,
    match_query: MatchQuery,

    pub fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.*) {
            .return_only => |*ret| ret.deinit(allocator),
            .insert => |patterns| deinitPatterns(patterns, allocator),
            .match_query => |*mq| mq.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const MatchQuery = struct {
    patterns: []PathPattern,
    where: ?Expr = null,
    action: MatchAction,

    pub fn deinit(self: *MatchQuery, allocator: Allocator) void {
        deinitPatterns(self.patterns, allocator);
        if (self.where) |*where| where.deinit(allocator);
        self.action.deinit(allocator);
        self.* = undefined;
    }
};

pub const MatchAction = union(enum) {
    ret: ReturnClause,
    insert: []PathPattern,
    delete: DeleteAction,
    set: []SetClause,
    finish,

    pub fn deinit(self: *MatchAction, allocator: Allocator) void {
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

pub const ReturnClause = struct {
    items: []ReturnItem,
    order_by: []SortItem = &.{},
    skip: usize = 0,
    limit: ?usize = null,

    pub fn deinit(self: *ReturnClause, allocator: Allocator) void {
        deinitReturnItems(self.items, allocator);
        deinitSortItems(self.order_by, allocator);
        self.* = undefined;
    }
};

pub const SortItem = struct {
    expr: Expr,
    desc: bool = false,

    pub fn deinit(self: *SortItem, allocator: Allocator) void {
        self.expr.deinit(allocator);
        self.* = undefined;
    }
};

pub const DeleteAction = struct {
    detach: bool,
    variables: []const []const u8,
};

pub const SetClause = struct {
    variable: []const u8,
    property: []const u8,
    value: Expr,

    pub fn deinit(self: *SetClause, allocator: Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReturnItem = struct {
    expr: Expr,
    alias: ?[]const u8 = null,

    pub fn deinit(self: *ReturnItem, allocator: Allocator) void {
        self.expr.deinit(allocator);
        self.* = undefined;
    }
};

pub const PathPattern = struct {
    start: NodePattern,
    segments: []PathSegment,

    pub fn deinit(self: *PathPattern, allocator: Allocator) void {
        self.start.deinit(allocator);
        for (self.segments) |*segment| segment.deinit(allocator);
        allocator.free(self.segments);
        self.* = undefined;
    }
};

pub const PathSegment = struct {
    edge: EdgePattern,
    node: NodePattern,

    pub fn deinit(self: *PathSegment, allocator: Allocator) void {
        self.edge.deinit(allocator);
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const NodePattern = struct {
    variable: ?[]const u8 = null,
    label: ?[]const u8 = null,
    properties: []Property = &.{},

    pub fn deinit(self: *NodePattern, allocator: Allocator) void {
        deinitProperties(self.properties, allocator);
        self.* = undefined;
    }
};

pub const EdgePattern = struct {
    variable: ?[]const u8 = null,
    label: ?[]const u8 = null,
    properties: []Property = &.{},
    direction: EdgeDirection,

    pub fn deinit(self: *EdgePattern, allocator: Allocator) void {
        deinitProperties(self.properties, allocator);
        self.* = undefined;
    }
};

pub const Property = struct {
    key: []const u8,
    value: Expr,

    pub fn deinit(self: *Property, allocator: Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Expr = union(enum) {
    literal: Value,
    variable: []const u8,
    property: struct { variable: []const u8, property: []const u8 },
    unary: *UnaryExpr,
    binary: *BinaryExpr,

    pub fn deinit(self: *Expr, allocator: Allocator) void {
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

pub const UnaryExpr = struct {
    op: Plan.UnaryOp,
    operand: Expr,

    pub fn deinit(self: *UnaryExpr, allocator: Allocator) void {
        self.operand.deinit(allocator);
        self.* = undefined;
    }
};

pub const BinaryExpr = struct {
    op: Plan.Binop,
    left: Expr,
    right: Expr,

    pub fn deinit(self: *BinaryExpr, allocator: Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
        self.* = undefined;
    }
};

pub fn deinitPatterns(patterns: []PathPattern, allocator: Allocator) void {
    for (patterns) |*pattern| pattern.deinit(allocator);
    allocator.free(patterns);
}

pub fn deinitReturnItems(items: []ReturnItem, allocator: Allocator) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn deinitSortItems(items: []SortItem, allocator: Allocator) void {
    for (items) |*item| item.deinit(allocator);
    if (items.len > 0) allocator.free(items);
}

pub fn deinitProperties(properties: []Property, allocator: Allocator) void {
    for (properties) |*property| property.deinit(allocator);
    if (properties.len > 0) allocator.free(properties);
}
