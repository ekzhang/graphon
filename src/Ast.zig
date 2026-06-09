//! Typed AST for the currently supported Graphon query subset.
//!
//! This is intentionally smaller than ISO GQL. `Parse.zig` produces these
//! structs, and the query planner lowers them into `Plan.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Parse = @import("Parse.zig");
const Plan = @import("Plan.zig");
const types = @import("types.zig");
const EdgeDirection = types.EdgeDirection;
const Value = types.Value;

pub const ByteOffset = u32;

pub const Token = @import("tokenizer.zig").Token;

/// Compact list of tokens after lexical analysis, with offsets into source.
pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});

/// Parse a GQL query into an AST (list of statements).
pub fn parse(gpa: Allocator, source: [:0]const u8) Parse.Error!Program {
    var parser: Parse = .{ .gpa = gpa, .source = source };
    return try parser.parse();
}

pub const Program = struct {
    statements: []Statement,

    pub fn deinit(self: *Program, allocator: Allocator) void {
        for (self.statements) |*statement| statement.deinit(allocator);
        allocator.free(self.statements);
        self.* = undefined;
    }
};

pub const Statement = union(enum) {
    query: RowQuery,
    mutation: MutationQuery,

    pub fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.*) {
            .query => |*query| query.deinit(allocator),
            .mutation => |*mutation| mutation.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const MutationQuery = union(enum) {
    insert: []PathPattern,
    match: MatchQuery,

    pub fn deinit(self: *MutationQuery, allocator: Allocator) void {
        switch (self.*) {
            .insert => |patterns| deinitPatterns(patterns, allocator),
            .match => |*mq| mq.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const QueryBody = union(enum) {
    return_only: ReturnClause,
    match_query: MatchQuery,
    read_query: ReadQuery,

    pub fn deinit(self: *QueryBody, allocator: Allocator) void {
        switch (self.*) {
            .return_only => |*ret| ret.deinit(allocator),
            .match_query => |*mq| mq.deinit(allocator),
            .read_query => |*rq| rq.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const RowQuery = union(enum) {
    single: QueryBody,
    union_query: UnionQuery,

    pub fn deinit(self: *RowQuery, allocator: Allocator) void {
        switch (self.*) {
            .single => |*query| query.deinit(allocator),
            .union_query => |*query| query.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const UnionQuery = struct {
    first: QueryBody,
    parts: []UnionPart,

    pub fn deinit(self: *UnionQuery, allocator: Allocator) void {
        self.first.deinit(allocator);
        for (self.parts) |*part| part.deinit(allocator);
        allocator.free(self.parts);
        self.* = undefined;
    }
};

pub const UnionPart = struct {
    all: bool,
    query: QueryBody,

    pub fn deinit(self: *UnionPart, allocator: Allocator) void {
        self.query.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReadQuery = struct {
    clauses: []ReadClause,
    ret: ReturnClause,

    pub fn deinit(self: *ReadQuery, allocator: Allocator) void {
        for (self.clauses) |*clause| clause.deinit(allocator);
        allocator.free(self.clauses);
        self.ret.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReadClause = union(enum) {
    match: MatchClause,
    optional_match: MatchClause,
    with: ReturnClause,

    pub fn deinit(self: *ReadClause, allocator: Allocator) void {
        switch (self.*) {
            .match, .optional_match => |*clause| clause.deinit(allocator),
            .with => |*ret| ret.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const MatchClause = struct {
    patterns: []PathPattern,
    where: ?Expr = null,

    pub fn deinit(self: *MatchClause, allocator: Allocator) void {
        deinitPatterns(self.patterns, allocator);
        if (self.where) |*where| where.deinit(allocator);
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
    distinct: bool = false,
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
    aggregate: *AggregateCall,
    unary: *UnaryExpr,
    binary: *BinaryExpr,

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .literal => |*v| v.deinit(allocator),
            .aggregate => |a| {
                a.deinit(allocator);
                allocator.destroy(a);
            },
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

pub const AggregateCall = struct {
    function: Plan.AggregateFunction,
    distinct: bool = false,
    argument: ?Expr,

    pub fn deinit(self: *AggregateCall, allocator: Allocator) void {
        if (self.argument) |*argument| argument.deinit(allocator);
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
