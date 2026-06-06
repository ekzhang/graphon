//! Minimal GQL parser and execution layer for the functional Graphon MVP.
//!
//! This module intentionally implements a small, useful subset of GQL while the
//! full ISO grammar in `Parse.zig` is still being built out. Supported today:
//!
//! * `RETURN` scalar expressions (`+`, `-`, `*`, `=`, `<>`) and properties.
//! * `INSERT` node/edge path patterns.
//! * `MATCH` node/edge path patterns with labels and property predicates.
//! * `MATCH ... RETURN`, `MATCH ... INSERT`, `MATCH ... SET`, and
//!   `MATCH ... [DETACH] DELETE`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const storage = @import("storage.zig");
const rocksdb = @import("storage/rocksdb.zig");
const types = @import("types.zig");
const ElementId = types.ElementId;
const Value = types.Value;

pub const Error = error{
    ParseError,
    Unsupported,
    UnknownIdentifier,
    WrongType,
    InvalidRequest,
} || Allocator.Error || storage.Error;

const Lexeme = struct {
    tag: Token.Tag,
    start: usize,
    end: usize,
};

pub const ResultSet = struct {
    columns: []const []u8 = &.{},
    rows: []Row = &.{},
    rows_affected: ?usize = null,

    pub fn deinit(self: *ResultSet, allocator: Allocator) void {
        for (self.columns) |col| allocator.free(col);
        allocator.free(self.columns);
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = undefined;
    }

    pub fn writeJson(self: ResultSet, writer: *std.Io.Writer) !void {
        var json: std.json.Stringify = .{ .writer = writer, .options = .{} };

        if (self.rows_affected) |n| {
            try json.beginObject();
            try json.objectField("ok");
            try json.write(true);
            try json.objectField("rows_affected");
            try json.write(n);
            try json.endObject();
            return;
        }

        // Keep README examples nice: `RETURN 55` over HTTP responds with `55`.
        if (self.columns.len == 1 and self.rows.len == 1) {
            try writeJsonValue(&json, self.rows[0].values[0]);
            return;
        }

        try json.beginArray();
        for (self.rows) |row| {
            try json.beginObject();
            for (self.columns, 0..) |column, col_i| {
                try json.objectField(column);
                try writeJsonValue(&json, row.values[col_i]);
            }
            try json.endObject();
        }
        try json.endArray();
    }
};

pub const Row = struct {
    values: []ResultValue,

    pub fn deinit(self: *Row, allocator: Allocator) void {
        for (self.values) |*value| value.deinit(allocator);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub const ResultValue = union(enum) {
    scalar: Value,
    node: NodeObject,
    edge: EdgeObject,

    pub fn deinit(self: *ResultValue, allocator: Allocator) void {
        switch (self.*) {
            .scalar => |*value| value.deinit(allocator),
            .node => |*node| node.deinit(allocator),
            .edge => |*edge| edge.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const NodeObject = struct {
    id: ElementId,
    labels: [][]u8,
    properties: []ResultProperty,

    pub fn deinit(self: *NodeObject, allocator: Allocator) void {
        for (self.labels) |label| allocator.free(label);
        allocator.free(self.labels);
        for (self.properties) |*property| property.deinit(allocator);
        allocator.free(self.properties);
        self.* = undefined;
    }
};

pub const EdgeObject = struct {
    id: ElementId,
    endpoints: [2]ElementId,
    directed: bool,
    labels: [][]u8,
    properties: []ResultProperty,

    pub fn deinit(self: *EdgeObject, allocator: Allocator) void {
        for (self.labels) |label| allocator.free(label);
        allocator.free(self.labels);
        for (self.properties) |*property| property.deinit(allocator);
        allocator.free(self.properties);
        self.* = undefined;
    }
};

pub const ResultProperty = struct {
    key: []u8,
    value: Value,

    pub fn deinit(self: *ResultProperty, allocator: Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

fn writeJsonValue(json: *std.json.Stringify, value: ResultValue) !void {
    switch (value) {
        .scalar => |scalar| try writeJsonScalar(json, scalar),
        .node => |node| try writeJsonNode(json, node),
        .edge => |edge| try writeJsonEdge(json, edge),
    }
}

fn writeJsonScalar(json: *std.json.Stringify, value: Value) !void {
    switch (value) {
        .string => |s| try json.write(s),
        .int64 => |n| try json.write(n),
        .float64 => |f| try json.write(f),
        .bool => |b| try json.write(b),
        .null => try json.write(null),
        .node_ref, .edge_ref, .id => |id| {
            const id_string = id.toString();
            try json.write(id_string[0..]);
        },
    }
}

fn writeJsonNode(json: *std.json.Stringify, node: NodeObject) !void {
    try json.beginObject();
    try json.objectField("id");
    const id = node.id.toString();
    try json.write(id[0..]);
    try json.objectField("labels");
    try json.write(node.labels);
    try json.objectField("properties");
    try writeJsonProperties(json, node.properties);
    try json.endObject();
}

fn writeJsonEdge(json: *std.json.Stringify, edge: EdgeObject) !void {
    try json.beginObject();
    try json.objectField("id");
    const id = edge.id.toString();
    try json.write(id[0..]);
    try json.objectField("start");
    const start = edge.endpoints[0].toString();
    try json.write(start[0..]);
    try json.objectField("end");
    const end = edge.endpoints[1].toString();
    try json.write(end[0..]);
    try json.objectField("directed");
    try json.write(edge.directed);
    try json.objectField("labels");
    try json.write(edge.labels);
    try json.objectField("properties");
    try writeJsonProperties(json, edge.properties);
    try json.endObject();
}

fn writeJsonProperties(json: *std.json.Stringify, properties: []const ResultProperty) !void {
    try json.beginObject();
    for (properties) |property| {
        try json.objectField(property.key);
        try writeJsonScalar(json, property.value);
    }
    try json.endObject();
}

pub fn execute(allocator: Allocator, io: std.Io, store: storage.Storage, source: [:0]const u8) Error!ResultSet {
    var parsed = try Parser.parse(allocator, source);
    defer parsed.deinit(allocator);

    var txn = store.txn();
    defer txn.close();

    var result = ResultSet{ .rows_affected = 0 };
    errdefer result.deinit(allocator);

    for (parsed.statements) |*statement| {
        result.deinit(allocator);
        result = try executeStatement(allocator, io, txn, statement.*);
    }

    try txn.commit();
    return result;
}

fn executeStatement(allocator: Allocator, io: std.Io, txn: storage.Transaction, statement: Statement) Error!ResultSet {
    switch (statement) {
        .return_only => |items| {
            var rows = std.ArrayList(Row).empty;
            errdefer deinitRowList(&rows, allocator);
            var binding = Binding{};
            defer binding.deinit(allocator);
            try appendReturnRow(allocator, txn, &rows, binding, items);
            return .{
                .columns = try columnNames(allocator, items),
                .rows = try rows.toOwnedSlice(allocator),
                .rows_affected = null,
            };
        },
        .insert => |patterns| {
            var binding = Binding{};
            defer binding.deinit(allocator);
            var count: usize = 0;
            for (patterns) |pattern| {
                count += try insertPath(allocator, io, txn, &binding, pattern);
            }
            return mutationResult(count);
        },
        .match_query => |mq| {
            var rows = std.ArrayList(Binding).empty;
            errdefer deinitBindings(&rows, allocator);
            try rows.append(allocator, Binding{});
            for (mq.patterns) |pattern| {
                try matchPath(allocator, txn, &rows, pattern);
            }

            switch (mq.action) {
                .ret => |items| {
                    var out_rows = std.ArrayList(Row).empty;
                    errdefer deinitRowList(&out_rows, allocator);
                    for (rows.items) |binding| {
                        try appendReturnRow(allocator, txn, &out_rows, binding, items);
                    }
                    deinitBindings(&rows, allocator);
                    return .{
                        .columns = try columnNames(allocator, items),
                        .rows = try out_rows.toOwnedSlice(allocator),
                        .rows_affected = null,
                    };
                },
                .insert => |patterns| {
                    var count: usize = 0;
                    for (rows.items) |*binding| {
                        for (patterns) |pattern| {
                            count += try insertPath(allocator, io, txn, binding, pattern);
                        }
                    }
                    deinitBindings(&rows, allocator);
                    return mutationResult(count);
                },
                .delete => |del| {
                    const count = try deleteBindings(allocator, txn, rows.items, del);
                    deinitBindings(&rows, allocator);
                    return mutationResult(count);
                },
                .set => |sets| {
                    const count = try setProperties(allocator, txn, rows.items, sets);
                    deinitBindings(&rows, allocator);
                    return mutationResult(count);
                },
                .finish => {
                    const n = rows.items.len;
                    deinitBindings(&rows, allocator);
                    return mutationResult(n);
                },
            }
        },
    }
}

fn mutationResult(rows_affected: usize) ResultSet {
    return .{ .columns = &.{}, .rows = &.{}, .rows_affected = rows_affected };
}

// ------------------------------- AST --------------------------------------

const Statement = union(enum) {
    return_only: []ReturnItem,
    insert: []PathPattern,
    match_query: MatchQuery,

    fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.*) {
            .return_only => |items| deinitReturnItems(items, allocator),
            .insert => |patterns| deinitPatterns(patterns, allocator),
            .match_query => |*mq| mq.deinit(allocator),
        }
        self.* = undefined;
    }
};

const MatchQuery = struct {
    patterns: []PathPattern,
    action: MatchAction,

    fn deinit(self: *MatchQuery, allocator: Allocator) void {
        deinitPatterns(self.patterns, allocator);
        self.action.deinit(allocator);
        self.* = undefined;
    }
};

const MatchAction = union(enum) {
    ret: []ReturnItem,
    insert: []PathPattern,
    delete: DeleteAction,
    set: []SetClause,
    finish,

    fn deinit(self: *MatchAction, allocator: Allocator) void {
        switch (self.*) {
            .ret => |items| deinitReturnItems(items, allocator),
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

const DeleteAction = struct {
    detach: bool,
    variables: []const []const u8,
};

const SetClause = struct {
    variable: []const u8,
    property: []const u8,
    value: Expr,

    fn deinit(self: *SetClause, allocator: Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

const ReturnItem = struct {
    expr: Expr,
    alias: ?[]const u8 = null,

    fn deinit(self: *ReturnItem, allocator: Allocator) void {
        self.expr.deinit(allocator);
        self.* = undefined;
    }
};

const PathPattern = struct {
    start: NodePattern,
    segments: []PathSegment,

    fn deinit(self: *PathPattern, allocator: Allocator) void {
        self.start.deinit(allocator);
        for (self.segments) |*segment| segment.deinit(allocator);
        allocator.free(self.segments);
        self.* = undefined;
    }
};

const PathSegment = struct {
    edge: EdgePattern,
    node: NodePattern,

    fn deinit(self: *PathSegment, allocator: Allocator) void {
        self.edge.deinit(allocator);
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

const NodePattern = struct {
    variable: ?[]const u8 = null,
    label: ?[]const u8 = null,
    properties: []Property = &.{},

    fn deinit(self: *NodePattern, allocator: Allocator) void {
        deinitProperties(self.properties, allocator);
        self.* = undefined;
    }
};

const EdgePattern = struct {
    variable: ?[]const u8 = null,
    label: ?[]const u8 = null,
    properties: []Property = &.{},
    direction: Direction,

    fn deinit(self: *EdgePattern, allocator: Allocator) void {
        deinitProperties(self.properties, allocator);
        self.* = undefined;
    }
};

const Direction = enum { right, left, undirected, any };

const Property = struct {
    key: []const u8,
    value: Expr,

    fn deinit(self: *Property, allocator: Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

const Expr = union(enum) {
    literal: Value,
    variable: []const u8,
    property: struct { variable: []const u8, property: []const u8 },
    binary: *BinaryExpr,

    fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .literal => |*v| v.deinit(allocator),
            .binary => |b| {
                b.deinit(allocator);
                allocator.destroy(b);
            },
            .variable, .property => {},
        }
        self.* = undefined;
    }
};

const BinaryExpr = struct {
    op: BinaryOp,
    left: Expr,
    right: Expr,

    fn deinit(self: *BinaryExpr, allocator: Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
        self.* = undefined;
    }
};

const BinaryOp = enum { add, sub, mul, eql, neq };

fn deinitPatterns(patterns: []PathPattern, allocator: Allocator) void {
    for (patterns) |*pattern| pattern.deinit(allocator);
    allocator.free(patterns);
}

fn deinitReturnItems(items: []ReturnItem, allocator: Allocator) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitProperties(properties: []Property, allocator: Allocator) void {
    for (properties) |*property| property.deinit(allocator);
    allocator.free(properties);
}

// ------------------------------ Parser ------------------------------------

const Parsed = struct {
    tokens: []Lexeme,
    statements: []Statement,

    fn deinit(self: *Parsed, allocator: Allocator) void {
        for (self.statements) |*statement| statement.deinit(allocator);
        allocator.free(self.statements);
        allocator.free(self.tokens);
        self.* = undefined;
    }
};

const Parser = struct {
    allocator: Allocator,
    source: [:0]const u8,
    tokens: []Lexeme,
    i: usize = 0,

    fn parse(allocator: Allocator, source: [:0]const u8) Error!Parsed {
        var toks = std.ArrayList(Lexeme).empty;
        errdefer toks.deinit(allocator);
        var t = tokenizer.Tokenizer.init(source);
        while (true) {
            const token = t.next();
            if (token.tag == .invalid) return error.ParseError;
            try toks.append(allocator, .{ .tag = token.tag, .start = token.loc.start, .end = token.loc.end });
            if (token.tag == .eof) break;
        }

        const owned_tokens = try toks.toOwnedSlice(allocator);
        errdefer allocator.free(owned_tokens);

        var parser = Parser{ .allocator = allocator, .source = source, .tokens = owned_tokens };
        var statements = std.ArrayList(Statement).empty;
        errdefer {
            for (statements.items) |*statement| statement.deinit(allocator);
            statements.deinit(allocator);
        }

        while (!parser.at(.eof)) {
            if (parser.eat(.semicolon)) continue;
            try statements.append(allocator, try parser.parseStatement());
            _ = parser.eat(.semicolon);
        }

        return .{ .tokens = owned_tokens, .statements = try statements.toOwnedSlice(allocator) };
    }

    fn parseStatement(p: *Parser) Error!Statement {
        if (p.eat(.keyword_return)) {
            return .{ .return_only = try p.parseReturnItems() };
        }
        if (p.eat(.keyword_insert)) {
            return .{ .insert = try p.parsePatternListUntilAction() };
        }
        if (p.eat(.keyword_match)) {
            const patterns = try p.parsePatternListUntilAction();
            errdefer deinitPatterns(patterns, p.allocator);
            const action = try p.parseMatchAction();
            return .{ .match_query = .{ .patterns = patterns, .action = action } };
        }
        return error.ParseError;
    }

    fn parseMatchAction(p: *Parser) Error!MatchAction {
        if (p.eat(.keyword_return)) return .{ .ret = try p.parseReturnItems() };
        if (p.eat(.keyword_insert)) return .{ .insert = try p.parsePatternListUntilAction() };
        if (p.eat(.keyword_finish)) return .finish;
        if (p.eat(.keyword_set)) return .{ .set = try p.parseSetClauses() };

        var detach = false;
        if (p.eat(.keyword_detach)) detach = true;
        if (p.eat(.keyword_delete)) {
            var vars = std.ArrayList([]const u8).empty;
            errdefer vars.deinit(p.allocator);
            while (true) {
                try vars.append(p.allocator, try p.expectName());
                if (!p.eat(.comma)) break;
            }
            return .{ .delete = .{ .detach = detach, .variables = try vars.toOwnedSlice(p.allocator) } };
        }
        return error.ParseError;
    }

    fn parseSetClauses(p: *Parser) Error![]SetClause {
        var clauses = std.ArrayList(SetClause).empty;
        errdefer {
            for (clauses.items) |*clause| clause.deinit(p.allocator);
            clauses.deinit(p.allocator);
        }
        while (true) {
            const variable = try p.expectName();
            try p.expect(.period);
            const property = try p.expectName();
            try p.expect(.equal);
            const value = try p.parseExpr(0);
            try clauses.append(p.allocator, .{ .variable = variable, .property = property, .value = value });
            if (!p.eat(.comma)) break;
        }
        return try clauses.toOwnedSlice(p.allocator);
    }

    fn parseReturnItems(p: *Parser) Error![]ReturnItem {
        var items = std.ArrayList(ReturnItem).empty;
        errdefer {
            for (items.items) |*item| item.deinit(p.allocator);
            items.deinit(p.allocator);
        }
        while (!p.at(.semicolon) and !p.at(.eof)) {
            var expr = try p.parseExpr(0);
            errdefer expr.deinit(p.allocator);
            const alias = if (p.eat(.keyword_as)) try p.expectName() else null;
            try items.append(p.allocator, .{ .expr = expr, .alias = alias });
            if (!p.eat(.comma)) break;
        }
        if (items.items.len == 0) return error.ParseError;
        return try items.toOwnedSlice(p.allocator);
    }

    fn parsePatternListUntilAction(p: *Parser) Error![]PathPattern {
        var patterns = std.ArrayList(PathPattern).empty;
        errdefer {
            for (patterns.items) |*pattern| pattern.deinit(p.allocator);
            patterns.deinit(p.allocator);
        }
        while (!p.at(.semicolon) and !p.at(.eof) and !p.atActionKeyword()) {
            try patterns.append(p.allocator, try p.parsePathPattern());
            if (!p.eat(.comma)) break;
        }
        if (patterns.items.len == 0) return error.ParseError;
        return try patterns.toOwnedSlice(p.allocator);
    }

    fn parsePathPattern(p: *Parser) Error!PathPattern {
        const start = try p.parseNodePattern();
        errdefer {
            var s = start;
            s.deinit(p.allocator);
        }
        var segments = std.ArrayList(PathSegment).empty;
        errdefer {
            for (segments.items) |*segment| segment.deinit(p.allocator);
            segments.deinit(p.allocator);
        }
        while (p.edgeStartsHere()) {
            const edge = try p.parseEdgePattern();
            errdefer {
                var e = edge;
                e.deinit(p.allocator);
            }
            const node = try p.parseNodePattern();
            errdefer {
                var n = node;
                n.deinit(p.allocator);
            }
            try segments.append(p.allocator, .{ .edge = edge, .node = node });
        }
        return .{ .start = start, .segments = try segments.toOwnedSlice(p.allocator) };
    }

    fn parseNodePattern(p: *Parser) Error!NodePattern {
        try p.expect(.l_paren);
        var node = NodePattern{};
        errdefer node.deinit(p.allocator);

        if (p.isName() and !p.atKeywordLike(.keyword_return)) {
            node.variable = try p.expectName();
        }
        while (p.eat(.colon)) {
            const label = try p.expectName();
            if (node.label == null) node.label = label;
        }
        if (p.at(.l_brace)) node.properties = try p.parseProperties();
        try p.expect(.r_paren);
        return node;
    }

    fn parseEdgePattern(p: *Parser) Error!EdgePattern {
        var direction: Direction = .undirected;
        var bracketed = true;

        switch (p.peek()) {
            .minus_left_bracket => {
                _ = p.next();
                direction = .undirected;
            },
            .left_arrow_bracket => {
                _ = p.next();
                direction = .left;
            },
            .right_arrow => {
                _ = p.next();
                direction = .right;
                if (p.eat(.l_bracket)) {
                    bracketed = true;
                } else {
                    bracketed = false;
                }
            },
            .left_arrow => {
                _ = p.next();
                direction = .left;
                bracketed = false;
            },
            .left_minus_right => {
                _ = p.next();
                direction = .any;
                bracketed = false;
            },
            else => return error.ParseError,
        }

        var edge = EdgePattern{ .direction = direction };
        errdefer edge.deinit(p.allocator);

        if (bracketed) {
            if (p.isName() and !p.at(.r_bracket)) {
                edge.variable = try p.expectName();
            }
            while (p.eat(.colon)) {
                const label = try p.expectName();
                if (edge.label == null) edge.label = label;
            }
            if (p.at(.l_brace)) edge.properties = try p.parseProperties();

            const close = p.peek();
            switch (close) {
                .bracket_right_arrow => {
                    _ = p.next();
                    edge.direction = .right;
                },
                .right_bracket_minus => {
                    _ = p.next();
                    // Keep explicit left arrows left; otherwise `-[]-` is undirected.
                    if (direction != .left) edge.direction = .undirected;
                },
                .r_bracket => {
                    _ = p.next();
                    edge.direction = direction;
                },
                else => return error.ParseError,
            }
        }
        return edge;
    }

    fn parseProperties(p: *Parser) Error![]Property {
        try p.expect(.l_brace);
        var properties = std.ArrayList(Property).empty;
        errdefer {
            for (properties.items) |*property| property.deinit(p.allocator);
            properties.deinit(p.allocator);
        }
        while (!p.eat(.r_brace)) {
            const key = try p.expectName();
            try p.expect(.colon);
            var value = try p.parseExpr(0);
            errdefer value.deinit(p.allocator);
            try properties.append(p.allocator, .{ .key = key, .value = value });
            if (!p.eat(.comma)) {
                try p.expect(.r_brace);
                break;
            }
        }
        return try properties.toOwnedSlice(p.allocator);
    }

    fn parseExpr(p: *Parser, min_prec: u8) Error!Expr {
        var left = try p.parsePrimary();
        errdefer left.deinit(p.allocator);

        while (binaryInfo(p.peek())) |info| {
            if (info.prec < min_prec) break;
            _ = p.next();
            var right = try p.parseExpr(info.prec + 1);
            errdefer right.deinit(p.allocator);
            const bin = try p.allocator.create(BinaryExpr);
            bin.* = .{ .op = info.op, .left = left, .right = right };
            left = .{ .binary = bin };
        }
        return left;
    }

    fn parsePrimary(p: *Parser) Error!Expr {
        const tok = p.next();
        switch (tok.tag) {
            .number_literal => {
                const s = p.slice(tok);
                if (std.mem.indexOfScalar(u8, s, '.') != null) {
                    return .{ .literal = .{ .float64 = std.fmt.parseFloat(f64, s) catch return error.ParseError } };
                }
                return .{ .literal = .{ .int64 = std.fmt.parseInt(i64, s, 10) catch return error.ParseError } };
            },
            .string_literal => return .{ .literal = .{ .string = try p.unquoteString(p.slice(tok)) } },
            .keyword_true => return .{ .literal = .{ .bool = true } },
            .keyword_false => return .{ .literal = .{ .bool = false } },
            .keyword_null => return .{ .literal = .null },
            .l_paren => {
                const expr = try p.parseExpr(0);
                try p.expect(.r_paren);
                return expr;
            },
            else => {
                if (!isNameToken(tok.tag)) return error.ParseError;
                const name = p.slice(tok);
                if (p.eat(.period)) {
                    return .{ .property = .{ .variable = name, .property = try p.expectName() } };
                }
                return .{ .variable = name };
            },
        }
    }

    fn unquoteString(p: *Parser, s: []const u8) Error![]u8 {
        if (s.len < 2) return error.ParseError;
        var start: usize = 1;
        const delimiter = s[0];
        if (delimiter == '@') {
            if (s.len < 3) return error.ParseError;
            start = 2;
        }
        const end = s.len - 1;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(p.allocator);
        var i = start;
        while (i < end) : (i += 1) {
            if (s[i] == delimiter and i + 1 < end and s[i + 1] == delimiter) {
                try out.append(p.allocator, delimiter);
                i += 1;
            } else if (s[i] == '\\' and i + 1 < end) {
                i += 1;
                try out.append(p.allocator, switch (s[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => s[i],
                });
            } else {
                try out.append(p.allocator, s[i]);
            }
        }
        return try out.toOwnedSlice(p.allocator);
    }

    fn binaryInfo(tag: Token.Tag) ?struct { op: BinaryOp, prec: u8 } {
        return switch (tag) {
            .equal => .{ .op = .eql, .prec = 1 },
            .not_equal => .{ .op = .neq, .prec = 1 },
            .plus => .{ .op = .add, .prec = 2 },
            .minus => .{ .op = .sub, .prec = 2 },
            .asterisk => .{ .op = .mul, .prec = 3 },
            else => null,
        };
    }

    fn atActionKeyword(p: *Parser) bool {
        return switch (p.peek()) {
            .keyword_return, .keyword_insert, .keyword_delete, .keyword_detach, .keyword_set, .keyword_finish => true,
            else => false,
        };
    }

    fn edgeStartsHere(p: *Parser) bool {
        return switch (p.peek()) {
            .minus_left_bracket, .left_arrow_bracket, .right_arrow, .left_arrow, .left_minus_right => true,
            else => false,
        };
    }

    fn isName(p: *Parser) bool {
        return isNameToken(p.peek());
    }

    fn at(p: *Parser, tag: Token.Tag) bool {
        return p.peek() == tag;
    }

    fn atKeywordLike(p: *Parser, tag: Token.Tag) bool {
        return p.peek() == tag;
    }

    fn eat(p: *Parser, tag: Token.Tag) bool {
        if (p.peek() == tag) {
            p.i += 1;
            return true;
        }
        return false;
    }

    fn expect(p: *Parser, tag: Token.Tag) Error!void {
        if (!p.eat(tag)) return error.ParseError;
    }

    fn expectName(p: *Parser) Error![]const u8 {
        const tok = p.next();
        if (!isNameToken(tok.tag)) return error.ParseError;
        return p.slice(tok);
    }

    fn peek(p: *Parser) Token.Tag {
        return p.tokens[p.i].tag;
    }

    fn next(p: *Parser) Lexeme {
        const tok = p.tokens[p.i];
        p.i += 1;
        return tok;
    }

    fn slice(p: *Parser, tok: Lexeme) []const u8 {
        return p.source[tok.start..tok.end];
    }
};

fn isNameToken(tag: Token.Tag) bool {
    if (tag == .identifier) return true;
    return std.mem.startsWith(u8, @tagName(tag), "keyword_");
}

// ----------------------------- Execution ----------------------------------

const Bound = union(enum) {
    node: ElementId,
    edge: ElementId,
};

const Binding = struct {
    vars: std.StringHashMapUnmanaged(Bound) = .empty,

    fn deinit(self: *Binding, allocator: Allocator) void {
        self.vars.deinit(allocator);
        self.* = undefined;
    }

    fn clone(self: Binding, allocator: Allocator) Allocator.Error!Binding {
        return .{ .vars = try self.vars.clone(allocator) };
    }

    fn bindNode(self: *Binding, allocator: Allocator, name: []const u8, id: ElementId) Allocator.Error!bool {
        if (self.vars.get(name)) |bound| return switch (bound) {
            .node => |node_id| node_id.value == id.value,
            .edge => false,
        };
        try self.vars.put(allocator, name, .{ .node = id });
        return true;
    }

    fn bindEdge(self: *Binding, allocator: Allocator, name: []const u8, id: ElementId) Allocator.Error!bool {
        if (self.vars.get(name)) |bound| return switch (bound) {
            .edge => |edge_id| edge_id.value == id.value,
            .node => false,
        };
        try self.vars.put(allocator, name, .{ .edge = id });
        return true;
    }
};

const PathRow = struct {
    binding: Binding,
    current: ElementId,

    fn deinit(self: *PathRow, allocator: Allocator) void {
        self.binding.deinit(allocator);
        self.* = undefined;
    }
};

fn deinitBindings(rows: *std.ArrayList(Binding), allocator: Allocator) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitPathRows(rows: *std.ArrayList(PathRow), allocator: Allocator) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitRowList(rows: *std.ArrayList(Row), allocator: Allocator) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn matchPath(allocator: Allocator, txn: storage.Transaction, rows: *std.ArrayList(Binding), pattern: PathPattern) Error!void {
    var path_rows = std.ArrayList(PathRow).empty;
    errdefer deinitPathRows(&path_rows, allocator);

    for (rows.items) |row| {
        if (pattern.start.variable) |name| {
            if (row.vars.get(name)) |bound| {
                if (bound != .node) continue;
                var node = try txn.getNode(bound.node) orelse continue;
                defer node.deinit(allocator);
                if (!try nodeMatches(allocator, txn, row, pattern.start, node)) continue;
                try path_rows.append(allocator, .{ .binding = try row.clone(allocator), .current = bound.node });
                continue;
            }
        }

        var it = try txn.iterateNodes();
        defer it.close();
        while (try it.next()) |node_value| {
            var node = node_value;
            defer node.deinit(allocator);
            if (!try nodeMatches(allocator, txn, row, pattern.start, node)) continue;
            var next_binding = try row.clone(allocator);
            errdefer next_binding.deinit(allocator);
            if (pattern.start.variable) |name| {
                if (!try next_binding.bindNode(allocator, name, node.id)) continue;
            }
            try path_rows.append(allocator, .{ .binding = next_binding, .current = node.id });
        }
    }

    for (pattern.segments) |segment| {
        var next_path_rows = std.ArrayList(PathRow).empty;
        errdefer deinitPathRows(&next_path_rows, allocator);

        for (path_rows.items) |path_row| {
            const min_inout, const max_inout = inoutRange(segment.edge.direction);
            var adj = try txn.iterateAdj(path_row.current, min_inout, max_inout);
            defer adj.close();
            while (try adj.next()) |entry| {
                var edge = try txn.getEdge(entry.edge_id) orelse continue;
                defer edge.deinit(allocator);
                if (!try edgeMatches(allocator, txn, path_row.binding, segment.edge, edge)) continue;

                var dest_node = try txn.getNode(entry.dest_node_id) orelse continue;
                defer dest_node.deinit(allocator);
                if (!try nodeMatches(allocator, txn, path_row.binding, segment.node, dest_node)) continue;

                var next_binding = try path_row.binding.clone(allocator);
                errdefer next_binding.deinit(allocator);
                if (segment.edge.variable) |name| {
                    if (!try next_binding.bindEdge(allocator, name, edge.id)) continue;
                }
                if (segment.node.variable) |name| {
                    if (!try next_binding.bindNode(allocator, name, dest_node.id)) continue;
                }
                try next_path_rows.append(allocator, .{ .binding = next_binding, .current = dest_node.id });
            }
        }

        deinitPathRows(&path_rows, allocator);
        path_rows = next_path_rows;
    }

    deinitBindings(rows, allocator);
    rows.* = std.ArrayList(Binding).empty;
    for (path_rows.items) |path_row| {
        try rows.append(allocator, path_row.binding);
    }
    // `path_row.binding` ownership moved into `rows`; only free the backing array.
    path_rows.deinit(allocator);
}

fn inoutRange(direction: Direction) struct { types.EdgeInOut, types.EdgeInOut } {
    return switch (direction) {
        .right => .{ .out, .out },
        .left => .{ .in, .in },
        .undirected => .{ .simple, .simple },
        .any => .{ .out, .in },
    };
}

fn nodeMatches(allocator: Allocator, txn: storage.Transaction, binding: Binding, pattern: NodePattern, node: types.Node) Error!bool {
    if (pattern.label) |label| {
        if (!node.labels.contains(label)) return false;
    }
    const b = binding;
    for (pattern.properties) |property| {
        const actual = node.properties.get(property.key) orelse return false;
        var expected = try evalExpr(allocator, txn, b, property.value);
        defer expected.deinit(allocator);
        if (!actual.eql(expected)) return false;
    }
    return true;
}

fn edgeMatches(allocator: Allocator, txn: storage.Transaction, binding: Binding, pattern: EdgePattern, edge: types.Edge) Error!bool {
    if (pattern.label) |label| {
        if (!edge.labels.contains(label)) return false;
    }
    const b = binding;
    for (pattern.properties) |property| {
        const actual = edge.properties.get(property.key) orelse return false;
        var expected = try evalExpr(allocator, txn, b, property.value);
        defer expected.deinit(allocator);
        if (!actual.eql(expected)) return false;
    }
    return true;
}

fn insertPath(allocator: Allocator, io: std.Io, txn: storage.Transaction, binding: *Binding, pattern: PathPattern) Error!usize {
    var count: usize = 0;
    var current = try insertOrUseNode(allocator, io, txn, binding, pattern.start, &count);
    for (pattern.segments) |segment| {
        const dest = try insertOrUseNode(allocator, io, txn, binding, segment.node, &count);
        try insertEdge(allocator, io, txn, binding, current, dest, segment.edge);
        count += 1;
        current = dest;
    }
    return count;
}

fn insertOrUseNode(
    allocator: Allocator,
    io: std.Io,
    txn: storage.Transaction,
    binding: *Binding,
    pattern: NodePattern,
    count: *usize,
) Error!ElementId {
    if (pattern.variable) |name| {
        if (binding.vars.get(name)) |bound| return switch (bound) {
            .node => |id| id,
            .edge => error.WrongType,
        };
    }

    var node = types.Node{ .id = ElementId.generate(io) };
    errdefer node.deinit(allocator);
    if (pattern.label) |label| {
        try node.labels.put(allocator, try allocator.dupe(u8, label), void{});
    }
    node.properties = try evaluateProperties(allocator, txn, binding.*, pattern.properties);
    try txn.putNode(node);
    const id = node.id;
    node.deinit(allocator);
    if (pattern.variable) |name| {
        _ = try binding.bindNode(allocator, name, id);
    }
    count.* += 1;
    return id;
}

fn insertEdge(
    allocator: Allocator,
    io: std.Io,
    txn: storage.Transaction,
    binding: *Binding,
    src: ElementId,
    dest: ElementId,
    pattern: EdgePattern,
) Error!void {
    var edge = types.Edge{
        .id = ElementId.generate(io),
        .endpoints = .{ src, dest },
        .directed = pattern.direction == .right or pattern.direction == .left,
    };
    errdefer edge.deinit(allocator);

    if (pattern.direction == .left) {
        edge.endpoints = .{ dest, src };
    }
    if (pattern.label) |label| {
        try edge.labels.put(allocator, try allocator.dupe(u8, label), void{});
    }
    edge.properties = try evaluateProperties(allocator, txn, binding.*, pattern.properties);
    try txn.putEdge(edge);
    const id = edge.id;
    edge.deinit(allocator);
    if (pattern.variable) |name| {
        _ = try binding.bindEdge(allocator, name, id);
    }
}

fn evaluateProperties(
    allocator: Allocator,
    txn: storage.Transaction,
    binding: Binding,
    properties: []const Property,
) Error!std.StringArrayHashMapUnmanaged(Value) {
    var ret: std.StringArrayHashMapUnmanaged(Value) = .empty;
    errdefer types.freeProperties(allocator, &ret);
    for (properties) |property| {
        const key = try allocator.dupe(u8, property.key);
        errdefer allocator.free(key);
        var value = try evalExpr(allocator, txn, binding, property.value);
        errdefer value.deinit(allocator);
        try ret.put(allocator, key, value);
    }
    return ret;
}

fn deleteBindings(allocator: Allocator, txn: storage.Transaction, rows: []const Binding, del: DeleteAction) Error!usize {
    var deleted_nodes: std.AutoHashMapUnmanaged(u96, void) = .empty;
    defer deleted_nodes.deinit(allocator);
    var deleted_edges: std.AutoHashMapUnmanaged(u96, void) = .empty;
    defer deleted_edges.deinit(allocator);

    var count: usize = 0;
    for (rows) |binding| {
        for (del.variables) |name| {
            const bound = binding.vars.get(name) orelse continue;
            switch (bound) {
                .edge => |edge_id| {
                    if (deleted_edges.contains(edge_id.value)) continue;
                    txn.deleteEdge(edge_id) catch |err| switch (err) {
                        rocksdb.Error.NotFound => {},
                        else => |e| return e,
                    };
                    try deleted_edges.put(allocator, edge_id.value, void{});
                    count += 1;
                },
                .node => |node_id| {
                    if (deleted_nodes.contains(node_id.value)) continue;
                    if (del.detach) {
                        try deleteAttachedEdges(allocator, txn, node_id, &deleted_edges, &count);
                    }
                    txn.deleteNode(node_id) catch |err| switch (err) {
                        rocksdb.Error.NotFound => {},
                        else => |e| return e,
                    };
                    try deleted_nodes.put(allocator, node_id.value, void{});
                    count += 1;
                },
            }
        }
    }
    return count;
}

fn deleteAttachedEdges(
    allocator: Allocator,
    txn: storage.Transaction,
    node_id: ElementId,
    deleted_edges: *std.AutoHashMapUnmanaged(u96, void),
    count: *usize,
) Error!void {
    var ids = std.ArrayList(ElementId).empty;
    defer ids.deinit(allocator);
    var it = try txn.iterateAdj(node_id, .out, .in);
    defer it.close();
    while (try it.next()) |entry| try ids.append(allocator, entry.edge_id);

    for (ids.items) |edge_id| {
        if (deleted_edges.contains(edge_id.value)) continue;
        txn.deleteEdge(edge_id) catch |err| switch (err) {
            rocksdb.Error.NotFound => {},
            else => |e| return e,
        };
        try deleted_edges.put(allocator, edge_id.value, void{});
        count.* += 1;
    }
}

fn setProperties(allocator: Allocator, txn: storage.Transaction, rows: []const Binding, sets: []const SetClause) Error!usize {
    var count: usize = 0;
    for (rows) |binding| {
        for (sets) |set| {
            const bound = binding.vars.get(set.variable) orelse return error.UnknownIdentifier;
            var value = try evalExpr(allocator, txn, binding, set.value);
            errdefer value.deinit(allocator);
            switch (bound) {
                .node => |node_id| {
                    var node = try txn.getNode(node_id) orelse continue;
                    defer node.deinit(allocator);
                    try putProperty(allocator, &node.properties, set.property, value);
                    value = .null; // ownership moved
                    try txn.putNode(node);
                    count += 1;
                },
                .edge => |edge_id| {
                    var edge = try txn.getEdge(edge_id) orelse continue;
                    defer edge.deinit(allocator);
                    try putProperty(allocator, &edge.properties, set.property, value);
                    value = .null; // ownership moved
                    try txn.putEdge(edge);
                    count += 1;
                },
            }
        }
    }
    return count;
}

fn putProperty(allocator: Allocator, properties: *std.StringArrayHashMapUnmanaged(Value), key: []const u8, value: Value) Allocator.Error!void {
    if (properties.getIndex(key)) |idx| {
        properties.values()[idx].deinit(allocator);
        properties.values()[idx] = value;
    } else {
        try properties.put(allocator, try allocator.dupe(u8, key), value);
    }
}

fn appendReturnRow(
    allocator: Allocator,
    txn: storage.Transaction,
    out_rows: *std.ArrayList(Row),
    binding: Binding,
    items: []const ReturnItem,
) Error!void {
    const values = try allocator.alloc(ResultValue, items.len);
    errdefer allocator.free(values);
    for (values) |*v| v.* = .{ .scalar = .null };
    errdefer for (values) |*v| v.deinit(allocator);

    for (items, 0..) |item, i| {
        values[i].deinit(allocator);
        values[i] = try evalReturnExpr(allocator, txn, binding, item.expr);
    }
    try out_rows.append(allocator, .{ .values = values });
}

fn evalReturnExpr(allocator: Allocator, txn: storage.Transaction, binding: Binding, expr: Expr) Error!ResultValue {
    switch (expr) {
        .variable => |name| {
            const bound = binding.vars.get(name) orelse return error.UnknownIdentifier;
            return switch (bound) {
                .node => |id| blk: {
                    var node = try txn.getNode(id) orelse return .{ .scalar = .null };
                    defer node.deinit(allocator);
                    break :blk .{ .node = try nodeObjectFromNode(allocator, node) };
                },
                .edge => |id| blk: {
                    var edge = try txn.getEdge(id) orelse return .{ .scalar = .null };
                    defer edge.deinit(allocator);
                    break :blk .{ .edge = try edgeObjectFromEdge(allocator, edge) };
                },
            };
        },
        else => return .{ .scalar = try evalExpr(allocator, txn, binding, expr) },
    }
}

fn nodeObjectFromNode(allocator: Allocator, node: types.Node) Allocator.Error!NodeObject {
    return .{
        .id = node.id,
        .labels = try cloneLabels(allocator, node.labels.keys()),
        .properties = try cloneResultProperties(allocator, node.properties.keys(), node.properties.values()),
    };
}

fn edgeObjectFromEdge(allocator: Allocator, edge: types.Edge) Allocator.Error!EdgeObject {
    return .{
        .id = edge.id,
        .endpoints = edge.endpoints,
        .directed = edge.directed,
        .labels = try cloneLabels(allocator, edge.labels.keys()),
        .properties = try cloneResultProperties(allocator, edge.properties.keys(), edge.properties.values()),
    };
}

fn cloneLabels(allocator: Allocator, labels: []const []const u8) Allocator.Error![][]u8 {
    const out = try allocator.alloc([]u8, labels.len);
    errdefer allocator.free(out);
    for (out) |*label| label.* = &.{};
    errdefer for (out) |label| allocator.free(label);
    for (labels, 0..) |label, i| {
        out[i] = try allocator.dupe(u8, label);
    }
    return out;
}

fn cloneResultProperties(allocator: Allocator, keys: []const []const u8, values: []const Value) Allocator.Error![]ResultProperty {
    const out = try allocator.alloc(ResultProperty, keys.len);
    errdefer allocator.free(out);
    for (out) |*property| property.* = .{ .key = &.{}, .value = .null };
    errdefer for (out) |*property| property.deinit(allocator);
    for (keys, values, 0..) |key, value, i| {
        out[i] = .{
            .key = try allocator.dupe(u8, key),
            .value = try value.dupe(allocator),
        };
    }
    return out;
}

fn columnNames(allocator: Allocator, items: []const ReturnItem) Allocator.Error![]const []u8 {
    var cols = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(cols);
    for (items, 0..) |item, i| {
        cols[i] = try exprName(allocator, item);
    }
    return cols;
}

fn exprName(allocator: Allocator, item: ReturnItem) Allocator.Error![]u8 {
    if (item.alias) |alias| return allocator.dupe(u8, alias);
    return switch (item.expr) {
        .variable => |name| allocator.dupe(u8, name),
        .property => |p| std.fmt.allocPrint(allocator, "{s}.{s}", .{ p.variable, p.property }),
        .literal => allocator.dupe(u8, "value"),
        .binary => allocator.dupe(u8, "expr"),
    };
}

fn evalExpr(allocator: Allocator, txn: storage.Transaction, binding: Binding, expr: Expr) Error!Value {
    switch (expr) {
        .literal => |v| return try v.dupe(allocator),
        .variable => |name| {
            const bound = binding.vars.get(name) orelse return error.UnknownIdentifier;
            return switch (bound) {
                .node => |id| .{ .node_ref = id },
                .edge => |id| .{ .edge_ref = id },
            };
        },
        .property => |p| {
            const bound = binding.vars.get(p.variable) orelse return error.UnknownIdentifier;
            switch (bound) {
                .node => |id| {
                    var node = try txn.getNode(id) orelse return .null;
                    defer node.deinit(allocator);
                    const value = node.properties.get(p.property) orelse return .null;
                    return try value.dupe(allocator);
                },
                .edge => |id| {
                    var edge = try txn.getEdge(id) orelse return .null;
                    defer edge.deinit(allocator);
                    const value = edge.properties.get(p.property) orelse return .null;
                    return try value.dupe(allocator);
                },
            }
        },
        .binary => |bin| {
            var left = try evalExpr(allocator, txn, binding, bin.left);
            defer left.deinit(allocator);
            var right = try evalExpr(allocator, txn, binding, bin.right);
            defer right.deinit(allocator);
            return switch (bin.op) {
                .add => try left.add(right, allocator),
                .sub => left.sub(right),
                .mul => multiplyValues(left, right),
                .eql => .{ .bool = left.eql(right) },
                .neq => .{ .bool = !left.eql(right) },
            };
        },
    }
}

fn multiplyValues(left: Value, right: Value) Value {
    return switch (left) {
        .int64 => |a| switch (right) {
            .int64 => |b| .{ .int64 = a * b },
            .float64 => |b| .{ .float64 = @as(f64, @floatFromInt(a)) * b },
            else => .null,
        },
        .float64 => |a| switch (right) {
            .int64 => |b| .{ .float64 = a * @as(f64, @floatFromInt(b)) },
            .float64 => |b| .{ .float64 = a * b },
            else => .null,
        },
        else => .null,
    };
}

// ------------------------------- Tests ------------------------------------

fn execForTest(store: storage.Storage, source: [:0]const u8) !ResultSet {
    return try execute(std.testing.allocator, std.testing.io, store, source);
}

fn jsonForTest(result: ResultSet) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try result.writeJson(&buf.writer);
    return try buf.toOwnedSlice();
}

test "return arithmetic" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "RETURN 100 * 3");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(Value{ .int64 = 300 }, result.rows[0].values[0].scalar);

    const json = try jsonForTest(result);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("300", json);
}

test "insert match return and detach delete" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:User {name: 'Eric'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "INSERT (:Food {name: 'Pizza', calories: 285})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (a:User {name: 'Eric'}), (f:Food {name: 'Pizza'}) INSERT (a)->[:Likes]->(f)");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (a:User {name: 'Eric'})->[:Likes]->(f:Food) RETURN f.name, f.calories");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Pizza", result.rows[0].values[0].scalar.string);
        try std.testing.expectEqual(Value{ .int64 = 285 }, result.rows[0].values[1].scalar);
    }
    {
        var result = try execForTest(store, "MATCH (f:Food {name: 'Pizza'}) DETACH DELETE f");
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.rows_affected.? >= 1);
    }
    {
        var result = try execForTest(store, "MATCH (a:User {name: 'Eric'})->[:Likes]->(f:Food) RETURN f.name, f.calories");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    }
}

test "returning a node includes labels and properties" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Alice', age: 30})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Alice'}) RETURN a");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        const node = result.rows[0].values[0].node;
        try std.testing.expectEqual(@as(usize, 1), node.labels.len);
        try std.testing.expectEqualStrings("Person", node.labels[0]);
        try std.testing.expectEqual(@as(usize, 2), node.properties.len);

        const json = try jsonForTest(result);
        defer std.testing.allocator.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"labels\":[\"Person\"]") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Alice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"age\":30") != null);
    }
}

test "set updates matched properties" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Eric'})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Eric'}) SET p.age = 23");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Eric'}) RETURN p.age");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(Value{ .int64 = 23 }, result.rows[0].values[0].scalar);
    }
}
