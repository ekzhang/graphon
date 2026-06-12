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

pub const SourceLocation = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

pub const Error = struct {
    tag: Tag,
    offset: ByteOffset,
    found: Token.Tag,
    expected: ?Token.Tag = null,

    pub const Tag = enum {
        invalid_token,
        expected_token,
        expected_statement,
        expected_query_statement,
        expected_read_clause,
        expected_match_action,
        expected_name,
        expected_expression,
        expected_return_item,
        expected_sort_item,
        expected_count,
        expected_path_pattern,
        expected_edge_pattern,
        expected_node_pattern,
        expected_insert_edge_endpoint,
        expected_insert_edge_direction,
        invalid_integer,
        invalid_float,
        invalid_string,
        invalid_aggregate_argument,
        unexpected_statement,
    };

    pub fn render(self: Error, source: []const u8, writer: anytype) !void {
        const loc = sourceLocation(source, self.offset);
        try writer.print("{d}:{d}: error: ", .{ loc.line + 1, loc.column + 1 });
        try self.renderMessage(writer);
        try writer.writeByte('\n');
        if (loc.line_start <= loc.line_end and loc.line_end <= source.len) {
            try writer.writeAll(source[loc.line_start..loc.line_end]);
            try writer.writeByte('\n');
            for (0..loc.column) |_| try writer.writeByte(' ');
            try writer.writeByte('^');
            try writer.writeByte('\n');
        }
    }

    pub fn renderMessage(self: Error, writer: anytype) !void {
        switch (self.tag) {
            .invalid_token => try writer.print("invalid token '{s}'", .{self.found.symbol()}),
            .expected_token => try writer.print("expected {s}, found {s}", .{ self.expected.?.symbol(), self.found.symbol() }),
            .expected_statement => try writer.print("expected a statement, found {s}", .{self.found.symbol()}),
            .expected_query_statement => try writer.print("expected a row-producing query, found {s}", .{self.found.symbol()}),
            .expected_read_clause => try writer.print("expected WITH, MATCH, OPTIONAL MATCH, or RETURN, found {s}", .{self.found.symbol()}),
            .expected_match_action => try writer.print("expected RETURN, INSERT, SET, DELETE, or FINISH after MATCH, found {s}", .{self.found.symbol()}),
            .expected_name => try writer.print("expected an identifier, found {s}", .{self.found.symbol()}),
            .expected_expression => try writer.print("expected an expression, found {s}", .{self.found.symbol()}),
            .expected_return_item => try writer.print("expected a RETURN item, found {s}", .{self.found.symbol()}),
            .expected_sort_item => try writer.print("expected an ORDER BY expression, found {s}", .{self.found.symbol()}),
            .expected_count => try writer.print("expected an integer count, found {s}", .{self.found.symbol()}),
            .expected_path_pattern => try writer.print("expected a path pattern, found {s}", .{self.found.symbol()}),
            .expected_edge_pattern => try writer.print("expected an edge pattern, found {s}", .{self.found.symbol()}),
            .expected_node_pattern => try writer.print("expected a node pattern, found {s}", .{self.found.symbol()}),
            .expected_insert_edge_endpoint => try writer.writeAll("INSERT edge patterns must have explicit node endpoints"),
            .expected_insert_edge_direction => try writer.writeAll("INSERT edge patterns must use ->, <-, or ~[]~"),
            .invalid_integer => try writer.print("invalid integer literal '{s}'", .{self.found.symbol()}),
            .invalid_float => try writer.print("invalid float literal '{s}'", .{self.found.symbol()}),
            .invalid_string => try writer.writeAll("invalid string literal"),
            .invalid_aggregate_argument => try writer.writeAll("only COUNT accepts '*' and COUNT(DISTINCT *) is invalid"),
            .unexpected_statement => try writer.writeAll("UNION can only combine row-producing queries"),
        }
    }
};

pub const ErrorList = struct {
    source: [:0]const u8,
    errors: []Error,

    pub fn deinit(self: *ErrorList, allocator: Allocator) void {
        allocator.free(self.errors);
        self.* = undefined;
    }

    pub fn render(self: ErrorList, writer: anytype) !void {
        for (self.errors) |err| {
            try err.render(self.source, writer);
        }
    }
};

pub fn sourceLocation(source: []const u8, offset: usize) SourceLocation {
    var loc: SourceLocation = .{
        .line = 0,
        .column = 0,
        .line_start = 0,
        .line_end = source.len,
    };
    const clamped_offset = @min(offset, source.len);
    for (source[0..clamped_offset], 0..) |c, i| {
        if (c == '\n') {
            loc.line += 1;
            loc.column = 0;
            loc.line_start = i + 1;
        } else {
            loc.column += 1;
        }
    }
    loc.line_end = loc.line_start;
    while (loc.line_end < source.len and source[loc.line_end] != '\n') {
        loc.line_end += 1;
    }
    return loc;
}

/// Parse a GQL query into an AST (list of statements).
pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!Program {
    var parser: Parse = .{ .gpa = gpa, .source = source };
    return try parser.parse();
}

pub const Program = struct {
    source: [:0]const u8,
    statements: []Statement,
    errors: []Error = &.{},

    pub fn deinit(self: *Program, allocator: Allocator) void {
        for (self.statements) |*statement| statement.deinit(allocator);
        allocator.free(self.statements);
        allocator.free(self.errors);
        self.* = undefined;
    }

    pub fn takeErrors(self: *Program) ErrorList {
        const errors = self.errors;
        self.errors = &.{};
        return .{ .source = self.source, .errors = errors };
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

pub const PathMode = enum {
    walk,
    trail,
};

pub const MatchClause = struct {
    patterns: []PathPattern,
    where: ?WherePredicate = null,

    pub fn deinit(self: *MatchClause, allocator: Allocator) void {
        deinitPatterns(self.patterns, allocator);
        if (self.where) |*where| where.deinit(allocator);
        self.* = undefined;
    }
};

pub const MatchQuery = struct {
    patterns: []PathPattern,
    where: ?WherePredicate = null,
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
    mode: PathMode = .walk,
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
    repeat: ?PathRepeat = null,

    pub fn deinit(self: *PathSegment, allocator: Allocator) void {
        self.edge.deinit(allocator);
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PathRepeat = struct {
    min: usize,
    max: usize,
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

pub const WherePredicate = union(enum) {
    expr: Expr,
    path_pattern: PathPattern,
    not_path_pattern: PathPattern,

    pub fn deinit(self: *WherePredicate, allocator: Allocator) void {
        switch (self.*) {
            .expr => |*expr| expr.deinit(allocator),
            .path_pattern, .not_path_pattern => |*pattern| pattern.deinit(allocator),
        }
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
    index: *IndexExpr,

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
            .index => |i| {
                i.deinit(allocator);
                allocator.destroy(i);
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

pub const IndexExpr = struct {
    base: Expr,
    index: Expr,

    pub fn deinit(self: *IndexExpr, allocator: Allocator) void {
        self.base.deinit(allocator);
        self.index.deinit(allocator);
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
