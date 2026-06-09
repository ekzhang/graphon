//! Parser for the currently supported Graphon query subset.
//!
//! This parser targets the query AST in `Ast.zig`. The supported syntax is a
//! subset of the full ISO GQL grammar.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Plan = @import("Plan.zig");
const tokenizer = @import("tokenizer.zig");
const EdgeDirection = @import("types.zig").EdgeDirection;

const Parse = @This();

/// An error occurred while parsing.
pub const Error = error{ParseError} || Allocator.Error;

gpa: Allocator,
source: [:0]const u8,
tokens: Ast.TokenList.Slice = .empty,
tok_i: u32 = 0,

pub fn parse(p: *Parse) Error!Ast.Program {
    p.deinitTokens();
    try p.tokenize();
    defer p.deinitTokens();

    var statements = std.ArrayList(Ast.Statement).empty;
    errdefer {
        for (statements.items) |*statement| statement.deinit(p.gpa);
        statements.deinit(p.gpa);
    }

    while (!p.at(.eof)) {
        if (p.eat(.semicolon)) continue;
        var statement: ?Ast.Statement = try p.parseStatement();
        errdefer if (statement) |*s| s.deinit(p.gpa);
        try statements.append(p.gpa, statement.?);
        statement = null;
        _ = p.eat(.semicolon);
    }

    return .{ .statements = try statements.toOwnedSlice(p.gpa) };
}

fn tokenize(p: *Parse) Error!void {
    var toks: Ast.TokenList = .empty;
    errdefer toks.deinit(p.gpa);
    var t = tokenizer.Tokenizer.init(p.source);
    while (true) {
        const token = t.next();
        if (token.tag == .invalid) return error.ParseError;
        const start = std.math.cast(Ast.ByteOffset, token.loc.start) orelse return error.ParseError;
        try toks.append(p.gpa, .{ .tag = token.tag, .start = start });
        if (token.tag == .eof) break;
    }

    p.tokens = toks.toOwnedSlice();
    p.tok_i = 0;
}

fn deinitTokens(p: *Parse) void {
    if (p.tokens.capacity > 0) p.tokens.deinit(p.gpa);
    p.tokens = .empty;
    p.tok_i = 0;
}

fn parseStatement(p: *Parse) Error!Ast.Statement {
    var statement: ?Ast.Statement = try p.parseSingleStatement();
    errdefer if (statement) |*s| s.deinit(p.gpa);

    if (!p.at(.keyword_union)) {
        const out = statement.?;
        statement = null;
        return out;
    }

    const first_statement = statement.?;
    statement = null;
    var first: ?Ast.QueryBody = try p.takeQueryBody(first_statement);
    errdefer if (first) |*query| query.deinit(p.gpa);

    var parts = std.ArrayList(Ast.UnionPart).empty;
    errdefer {
        for (parts.items) |*part| part.deinit(p.gpa);
        parts.deinit(p.gpa);
    }

    while (p.eat(.keyword_union)) {
        const all = p.eat(.keyword_all);
        var query: ?Ast.QueryBody = try p.parseQueryBody();
        errdefer if (query) |*q| q.deinit(p.gpa);
        try parts.append(p.gpa, .{ .all = all, .query = query.? });
        query = null;
    }

    const owned_parts = try parts.toOwnedSlice(p.gpa);
    parts = .empty;
    const out = Ast.Statement{ .query = .{ .union_query = .{ .first = first.?, .parts = owned_parts } } };
    first = null;
    return out;
}

fn parseSingleStatement(p: *Parse) Error!Ast.Statement {
    if (p.eat(.keyword_return)) {
        return .{ .query = .{ .single = .{ .return_only = try p.parseReturnClause() } } };
    }
    if (p.eat(.keyword_insert)) {
        return .{ .mutation = .{ .insert = try p.parseInsertPatternListUntilAction() } };
    }
    if (p.eat(.keyword_optional)) {
        try p.expect(.keyword_match);
        var clause: ?Ast.MatchClause = try p.parseMatchClauseAfterKeyword();
        errdefer if (clause) |*c| c.deinit(p.gpa);
        var first: ?Ast.ReadClause = .{ .optional_match = clause.? };
        clause = null;
        errdefer if (first) |*c| c.deinit(p.gpa);
        var read: ?Ast.ReadQuery = try p.parseReadQueryFromFirst(first.?);
        first = null;
        errdefer if (read) |*rq| rq.deinit(p.gpa);
        const out = Ast.Statement{ .query = .{ .single = .{ .read_query = read.? } } };
        read = null;
        return out;
    }
    if (p.eat(.keyword_match)) {
        var clause: ?Ast.MatchClause = try p.parseMatchClauseAfterKeyword();
        errdefer if (clause) |*c| c.deinit(p.gpa);
        if (p.atReadContinuationKeyword()) {
            var first: ?Ast.ReadClause = .{ .match = clause.? };
            clause = null;
            errdefer if (first) |*c| c.deinit(p.gpa);
            var read: ?Ast.ReadQuery = try p.parseReadQueryFromFirst(first.?);
            first = null;
            errdefer if (read) |*rq| rq.deinit(p.gpa);
            const out = Ast.Statement{ .query = .{ .single = .{ .read_query = read.? } } };
            read = null;
            return out;
        }
        const action = try p.parseMatchAction();
        const query = Ast.MatchQuery{
            .patterns = clause.?.patterns,
            .where = clause.?.where,
            .action = action,
        };
        clause = null;
        return switch (query.action) {
            .ret => .{ .query = .{ .single = .{ .match_query = query } } },
            else => .{ .mutation = .{ .match = query } },
        };
    }
    return error.ParseError;
}

fn parseQueryBody(p: *Parse) Error!Ast.QueryBody {
    var statement: ?Ast.Statement = try p.parseSingleStatement();
    errdefer if (statement) |*s| s.deinit(p.gpa);
    const owned_statement = statement.?;
    statement = null;
    const row = try p.takeQueryBody(owned_statement);
    return row;
}

fn takeQueryBody(p: *Parse, statement: Ast.Statement) Error!Ast.QueryBody {
    switch (statement) {
        .query => |query| switch (query) {
            .single => |body| return body,
            .union_query => {
                var owned = query;
                owned.deinit(p.gpa);
                return error.ParseError;
            },
        },
        .mutation => |mutation| {
            var owned = mutation;
            owned.deinit(p.gpa);
            return error.ParseError;
        },
    }
}

fn parseReadQueryFromFirst(p: *Parse, first: Ast.ReadClause) Error!Ast.ReadQuery {
    var clauses = std.ArrayList(Ast.ReadClause).empty;
    errdefer {
        for (clauses.items) |*clause| clause.deinit(p.gpa);
        clauses.deinit(p.gpa);
    }

    var owned_first: ?Ast.ReadClause = first;
    errdefer if (owned_first) |*clause| clause.deinit(p.gpa);
    try clauses.append(p.gpa, owned_first.?);
    owned_first = null;

    while (true) {
        if (p.eat(.keyword_with)) {
            var ret: ?Ast.ReturnClause = try p.parseReturnClause();
            errdefer if (ret) |*r| r.deinit(p.gpa);
            try clauses.append(p.gpa, .{ .with = ret.? });
            ret = null;
        } else if (p.eat(.keyword_optional)) {
            try p.expect(.keyword_match);
            var clause: ?Ast.MatchClause = try p.parseMatchClauseAfterKeyword();
            errdefer if (clause) |*c| c.deinit(p.gpa);
            try clauses.append(p.gpa, .{ .optional_match = clause.? });
            clause = null;
        } else if (p.eat(.keyword_match)) {
            var clause: ?Ast.MatchClause = try p.parseMatchClauseAfterKeyword();
            errdefer if (clause) |*c| c.deinit(p.gpa);
            try clauses.append(p.gpa, .{ .match = clause.? });
            clause = null;
        } else if (p.eat(.keyword_return)) {
            var ret: ?Ast.ReturnClause = try p.parseReturnClause();
            errdefer if (ret) |*r| r.deinit(p.gpa);
            const owned_clauses = try clauses.toOwnedSlice(p.gpa);
            clauses = .empty;
            const out = Ast.ReadQuery{ .clauses = owned_clauses, .ret = ret.? };
            ret = null;
            return out;
        } else {
            return error.ParseError;
        }
    }
}

fn parseMatchClauseAfterKeyword(p: *Parse) Error!Ast.MatchClause {
    const patterns = try p.parsePatternListUntilAction();
    errdefer Ast.deinitPatterns(patterns, p.gpa);
    var where: ?Ast.WherePredicate = null;
    errdefer if (where) |*predicate| predicate.deinit(p.gpa);
    if (p.eat(.keyword_where)) {
        where = try p.parseWherePredicate();
    }
    return .{ .patterns = patterns, .where = where };
}

fn parseMatchAction(p: *Parse) Error!Ast.MatchAction {
    if (p.eat(.keyword_return)) return .{ .ret = try p.parseReturnClause() };
    if (p.eat(.keyword_insert)) return .{ .insert = try p.parsePatternListUntilAction() };
    if (p.eat(.keyword_finish)) return .finish;
    if (p.eat(.keyword_set)) return .{ .set = try p.parseSetClauses() };

    var detach = false;
    if (p.eat(.keyword_detach)) detach = true;
    if (p.eat(.keyword_delete)) {
        var vars = std.ArrayList([]const u8).empty;
        errdefer vars.deinit(p.gpa);
        while (true) {
            try vars.append(p.gpa, try p.expectName());
            if (!p.eat(.comma)) break;
        }
        return .{ .delete = .{ .detach = detach, .variables = try vars.toOwnedSlice(p.gpa) } };
    }
    return error.ParseError;
}

fn parseSetClauses(p: *Parse) Error![]Ast.SetClause {
    var clauses = std.ArrayList(Ast.SetClause).empty;
    errdefer {
        for (clauses.items) |*clause| clause.deinit(p.gpa);
        clauses.deinit(p.gpa);
    }
    while (true) {
        const variable = try p.expectName();
        try p.expect(.period);
        const property = try p.expectName();
        try p.expect(.equal);
        var value: ?Ast.Expr = try p.parseExpr(0);
        errdefer if (value) |*expr| expr.deinit(p.gpa);
        try clauses.append(p.gpa, .{ .variable = variable, .property = property, .value = value.? });
        value = null;
        if (!p.eat(.comma)) break;
    }
    return try clauses.toOwnedSlice(p.gpa);
}

fn parseReturnClause(p: *Parse) Error!Ast.ReturnClause {
    const distinct = p.eat(.keyword_distinct);
    const items = try p.parseReturnItems();
    var ret = Ast.ReturnClause{ .items = items, .distinct = distinct };
    errdefer ret.deinit(p.gpa);
    if (p.eat(.keyword_order)) {
        try p.expect(.keyword_by);
        ret.order_by = try p.parseSortItems();
    }
    while (true) {
        if (p.eat(.keyword_skip)) {
            ret.skip = try p.parseCount();
        } else if (p.eat(.keyword_limit)) {
            ret.limit = try p.parseCount();
        } else {
            break;
        }
    }
    const out = ret;
    ret = .{ .items = &.{} };
    return out;
}

fn parseSortItems(p: *Parse) Error![]Ast.SortItem {
    var items = std.ArrayList(Ast.SortItem).empty;
    errdefer {
        for (items.items) |*item| item.deinit(p.gpa);
        items.deinit(p.gpa);
    }
    while (!p.atReturnModifierTerminator()) {
        var expr: ?Ast.Expr = try p.parseExpr(0);
        errdefer if (expr) |*e| e.deinit(p.gpa);
        const desc = if (p.eat(.keyword_desc) or p.eat(.keyword_descending))
            true
        else if (p.eat(.keyword_asc) or p.eat(.keyword_ascending))
            false
        else
            false;
        try items.append(p.gpa, .{ .expr = expr.?, .desc = desc });
        expr = null;
        if (!p.eat(.comma)) break;
    }
    if (items.items.len == 0) return error.ParseError;
    return try items.toOwnedSlice(p.gpa);
}

fn parseReturnItems(p: *Parse) Error![]Ast.ReturnItem {
    var items = std.ArrayList(Ast.ReturnItem).empty;
    errdefer {
        for (items.items) |*item| item.deinit(p.gpa);
        items.deinit(p.gpa);
    }
    while (!p.atReturnItemTerminator()) {
        var expr: ?Ast.Expr = try p.parseExpr(0);
        errdefer if (expr) |*e| e.deinit(p.gpa);
        const alias = if (p.eat(.keyword_as)) try p.expectName() else null;
        try items.append(p.gpa, .{ .expr = expr.?, .alias = alias });
        expr = null;
        if (!p.eat(.comma)) break;
    }
    if (items.items.len == 0) return error.ParseError;
    return try items.toOwnedSlice(p.gpa);
}

fn parseCount(p: *Parse) Error!usize {
    const tok = p.next();
    if (p.tokenTag(tok) != .number_literal) return error.ParseError;
    const s = p.slice(tok);
    if (std.mem.indexOfScalar(u8, s, '.') != null) return error.ParseError;
    return std.fmt.parseInt(usize, s, 10) catch return error.ParseError;
}

fn parsePatternListUntilAction(p: *Parse) Error![]Ast.PathPattern {
    return p.parsePatternListUntilActionWith(.{});
}

fn parseInsertPatternListUntilAction(p: *Parse) Error![]Ast.PathPattern {
    return p.parsePatternListUntilActionWith(.{
        .require_explicit_start_node = true,
        .require_explicit_end_node = true,
        .require_insert_edge_directions = true,
    });
}

fn parsePatternListUntilActionWith(p: *Parse, options: PathPatternOptions) Error![]Ast.PathPattern {
    var patterns = std.ArrayList(Ast.PathPattern).empty;
    errdefer {
        for (patterns.items) |*pattern| pattern.deinit(p.gpa);
        patterns.deinit(p.gpa);
    }
    while (!p.at(.semicolon) and !p.at(.eof) and !p.atActionKeyword()) {
        var pattern: ?Ast.PathPattern = try p.parsePathPatternWith(options);
        errdefer if (pattern) |*patt| patt.deinit(p.gpa);
        try patterns.append(p.gpa, pattern.?);
        pattern = null;
        if (!p.eat(.comma)) break;
    }
    if (patterns.items.len == 0) return error.ParseError;
    return try patterns.toOwnedSlice(p.gpa);
}

fn parsePathPattern(p: *Parse) Error!Ast.PathPattern {
    return p.parsePathPatternWith(.{});
}

const PathPatternOptions = struct {
    require_edge: bool = false,
    require_explicit_start_node: bool = false,
    require_explicit_end_node: bool = false,
    require_insert_edge_directions: bool = false,
};

fn parsePathPatternWith(p: *Parse, options: PathPatternOptions) Error!Ast.PathPattern {
    var start = Ast.NodePattern{};
    var start_owned = false;
    errdefer if (start_owned) start.deinit(p.gpa);
    const explicit_start_node = !p.edgeStartsHere();

    if (explicit_start_node) {
        start = try p.parseNodePattern();
        start_owned = true;
    } else if (options.require_explicit_start_node) {
        return error.ParseError;
    }

    var parsed_segments = try p.parsePathSegments();
    errdefer deinitPathSegments(parsed_segments.segments, p.gpa);

    if (options.require_edge and parsed_segments.segments.len == 0) return error.ParseError;
    if (options.require_explicit_end_node and !parsed_segments.explicit_end_node) return error.ParseError;
    if (options.require_insert_edge_directions) {
        for (parsed_segments.segments) |segment| {
            if (!isInsertEdgeDirection(segment.edge.direction)) return error.ParseError;
        }
    }

    const out = Ast.PathPattern{ .start = start, .segments = parsed_segments.segments };
    start_owned = false;
    parsed_segments.segments = &.{};
    return out;
}

fn isInsertEdgeDirection(direction: EdgeDirection) bool {
    return switch (direction) {
        .left, .right, .undirected => true,
        .any, .left_or_right, .left_or_undirected, .right_or_undirected => false,
    };
}

const ParsedPathSegments = struct {
    segments: []Ast.PathSegment,
    explicit_end_node: bool,
};

fn parsePathSegments(p: *Parse) Error!ParsedPathSegments {
    var segments = std.ArrayList(Ast.PathSegment).empty;
    var explicit_end_node = true;
    errdefer {
        for (segments.items) |*segment| segment.deinit(p.gpa);
        segments.deinit(p.gpa);
    }
    while (p.edgeStartsHere()) {
        var edge: ?Ast.EdgePattern = try p.parseEdgePattern();
        errdefer if (edge) |*e| e.deinit(p.gpa);
        const explicit_node = p.at(.l_paren);
        var node: ?Ast.NodePattern = if (explicit_node) try p.parseNodePattern() else Ast.NodePattern{};
        errdefer if (node) |*n| n.deinit(p.gpa);
        try segments.append(p.gpa, .{ .edge = edge.?, .node = node.? });
        explicit_end_node = explicit_node;
        edge = null;
        node = null;
        if (!explicit_node) break;
    }
    return .{
        .segments = try segments.toOwnedSlice(p.gpa),
        .explicit_end_node = explicit_end_node,
    };
}

fn deinitPathSegments(segments: []Ast.PathSegment, gpa: Allocator) void {
    for (segments) |*segment| segment.deinit(gpa);
    gpa.free(segments);
}

fn parseWherePredicate(p: *Parse) Error!Ast.WherePredicate {
    const start = p.tok_i;
    if (p.eat(.keyword_not)) {
        if (try p.isPathPredicateStart()) {
            return .{ .not_path_pattern = try p.parsePathPredicate() };
        }
        p.tok_i = start;
    } else if (try p.isPathPredicateStart()) {
        return .{ .path_pattern = try p.parsePathPredicate() };
    }

    return .{ .expr = try p.parseExpr(0) };
}

fn parsePathPredicate(p: *Parse) Error!Ast.PathPattern {
    return p.parsePathPatternWith(.{ .require_edge = true });
}

fn parseNodePattern(p: *Parse) Error!Ast.NodePattern {
    try p.expect(.l_paren);
    var node = Ast.NodePattern{};
    errdefer node.deinit(p.gpa);

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

fn parseEdgePattern(p: *Parse) Error!Ast.EdgePattern {
    const EdgeStart = enum { minus, left_arrow, tilde, left_arrow_tilde };

    var direction: EdgeDirection = .any;
    var start: EdgeStart = .minus;
    var bracketed = true;

    switch (p.peek()) {
        .minus_left_bracket => {
            _ = p.next();
            start = .minus;
            direction = .any;
        },
        .left_arrow_bracket => {
            _ = p.next();
            start = .left_arrow;
            direction = .left;
        },
        .tilde_left_bracket => {
            _ = p.next();
            start = .tilde;
            direction = .undirected;
        },
        .left_arrow_tilde_bracket => {
            _ = p.next();
            start = .left_arrow_tilde;
            direction = .left_or_undirected;
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
            direction = .left_or_right;
            bracketed = false;
        },
        .tilde => {
            _ = p.next();
            direction = .undirected;
            bracketed = false;
        },
        .left_arrow_tilde => {
            _ = p.next();
            direction = .left_or_undirected;
            bracketed = false;
        },
        .tilde_right_arrow => {
            _ = p.next();
            direction = .right_or_undirected;
            bracketed = false;
        },
        .minus => {
            _ = p.next();
            direction = .any;
            bracketed = false;
        },
        else => return error.ParseError,
    }

    var edge = Ast.EdgePattern{ .direction = direction };
    errdefer edge.deinit(p.gpa);

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
                edge.direction = switch (start) {
                    .minus => .right,
                    .left_arrow => .left_or_right,
                    .tilde, .left_arrow_tilde => return error.ParseError,
                };
            },
            .right_bracket_minus => {
                _ = p.next();
                edge.direction = switch (start) {
                    .minus => .any,
                    .left_arrow => .left,
                    .tilde, .left_arrow_tilde => return error.ParseError,
                };
            },
            .right_bracket_tilde => {
                _ = p.next();
                edge.direction = switch (start) {
                    .tilde => .undirected,
                    .left_arrow_tilde => .left_or_undirected,
                    .minus, .left_arrow => return error.ParseError,
                };
            },
            .bracket_tilde_right_arrow => {
                _ = p.next();
                edge.direction = switch (start) {
                    .tilde => .right_or_undirected,
                    .minus, .left_arrow, .left_arrow_tilde => return error.ParseError,
                };
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

fn parseProperties(p: *Parse) Error![]Ast.Property {
    try p.expect(.l_brace);
    var properties = std.ArrayList(Ast.Property).empty;
    errdefer {
        for (properties.items) |*property| property.deinit(p.gpa);
        properties.deinit(p.gpa);
    }
    while (!p.eat(.r_brace)) {
        const key = try p.expectName();
        try p.expect(.colon);
        var value: ?Ast.Expr = try p.parseExpr(0);
        errdefer if (value) |*expr| expr.deinit(p.gpa);
        try properties.append(p.gpa, .{ .key = key, .value = value.? });
        value = null;
        if (!p.eat(.comma)) {
            try p.expect(.r_brace);
            break;
        }
    }
    return try properties.toOwnedSlice(p.gpa);
}

fn parseExpr(p: *Parse, min_prec: u8) Error!Ast.Expr {
    var left = try p.parseUnary();
    errdefer left.deinit(p.gpa);

    while (binaryInfo(p.peek())) |info| {
        if (info.prec < min_prec) break;
        _ = p.next();
        var right: ?Ast.Expr = try p.parseExpr(info.prec + 1);
        errdefer if (right) |*expr| expr.deinit(p.gpa);
        const bin = try p.gpa.create(Ast.BinaryExpr);
        bin.* = .{ .op = info.op, .left = left, .right = right.? };
        right = null;
        left = .{ .binary = bin };
    }
    return left;
}

fn parseUnary(p: *Parse) Error!Ast.Expr {
    if (p.eat(.keyword_not)) {
        var operand: ?Ast.Expr = try p.parseExpr(3);
        errdefer if (operand) |*expr| expr.deinit(p.gpa);
        const unary = try p.gpa.create(Ast.UnaryExpr);
        unary.* = .{ .op = .not, .operand = operand.? };
        operand = null;
        return .{ .unary = unary };
    }
    return p.parsePrimary();
}

fn parsePrimary(p: *Parse) Error!Ast.Expr {
    const tok = p.next();
    const tag = p.tokenTag(tok);
    switch (tag) {
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
            if (!isNameToken(tag)) return error.ParseError;
            const name = p.slice(tok);
            if (p.eat(.l_paren)) {
                return p.parseCall(tag);
            }
            if (p.eat(.period)) {
                return .{ .property = .{ .variable = name, .property = try p.expectName() } };
            }
            return .{ .variable = name };
        },
    }
}

fn parseCall(p: *Parse, tag: Ast.Token.Tag) Error!Ast.Expr {
    const function: Plan.AggregateFunction = switch (tag) {
        .keyword_count => .count,
        .keyword_sum => .sum,
        .keyword_avg => .avg,
        .keyword_min => .min,
        .keyword_max => .max,
        else => return error.ParseError,
    };

    const distinct = p.eat(.keyword_distinct);
    var argument: ?Ast.Expr = null;
    errdefer if (argument) |*arg| arg.deinit(p.gpa);
    if (p.eat(.asterisk)) {
        if (function != .count or distinct) return error.ParseError;
        argument = null;
    } else {
        argument = try p.parseExpr(0);
    }
    try p.expect(.r_paren);

    const aggregate = try p.gpa.create(Ast.AggregateCall);
    aggregate.* = .{ .function = function, .distinct = distinct, .argument = argument };
    argument = null;
    return .{ .aggregate = aggregate };
}

fn unquoteString(p: *Parse, s: []const u8) Error![]u8 {
    if (s.len < 2) return error.ParseError;
    var start: usize = 1;
    const delimiter = s[0];
    if (delimiter == '@') {
        if (s.len < 3) return error.ParseError;
        start = 2;
    }
    const end = s.len - 1;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(p.gpa);
    var i = start;
    while (i < end) : (i += 1) {
        if (s[i] == delimiter and i + 1 < end and s[i + 1] == delimiter) {
            try out.append(p.gpa, delimiter);
            i += 1;
        } else if (s[i] == '\\' and i + 1 < end) {
            i += 1;
            try out.append(p.gpa, switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => s[i],
            });
        } else {
            try out.append(p.gpa, s[i]);
        }
    }
    return try out.toOwnedSlice(p.gpa);
}

fn atActionKeyword(p: *Parse) bool {
    return switch (p.peek()) {
        .keyword_return, .keyword_insert, .keyword_delete, .keyword_detach, .keyword_set, .keyword_finish, .keyword_where, .keyword_with, .keyword_optional, .keyword_match => true,
        else => false,
    };
}

fn atReadContinuationKeyword(p: *Parse) bool {
    return switch (p.peek()) {
        .keyword_with, .keyword_optional, .keyword_match => true,
        else => false,
    };
}

fn atReturnItemTerminator(p: *Parse) bool {
    return switch (p.peek()) {
        .keyword_order, .keyword_skip, .keyword_limit, .keyword_union, .semicolon, .eof, .keyword_match, .keyword_optional, .keyword_return, .keyword_with => true,
        else => false,
    };
}

fn atReturnModifierTerminator(p: *Parse) bool {
    return switch (p.peek()) {
        .keyword_skip, .keyword_limit, .keyword_union, .semicolon, .eof, .keyword_match, .keyword_optional, .keyword_return, .keyword_with => true,
        else => false,
    };
}

fn edgeStartsHere(p: *Parse) bool {
    return switch (p.peek()) {
        .minus,
        .minus_left_bracket,
        .left_arrow,
        .left_arrow_bracket,
        .left_arrow_tilde,
        .left_arrow_tilde_bracket,
        .left_minus_right,
        .right_arrow,
        .tilde,
        .tilde_left_bracket,
        .tilde_right_arrow,
        => true,
        else => false,
    };
}

fn isPathPredicateStart(p: *Parse) Error!bool {
    if (p.edgeStartsHere()) return true;
    if (!p.at(.l_paren)) return false;

    const saved_tok_i = p.tok_i;
    var node = p.parseNodePattern() catch |err| {
        p.tok_i = saved_tok_i;
        if (err == error.ParseError) return false;
        return err;
    };
    defer {
        node.deinit(p.gpa);
        p.tok_i = saved_tok_i;
    }
    return p.edgeStartsHere();
}

fn isName(p: *Parse) bool {
    return isNameToken(p.peek());
}

fn at(p: *Parse, tag: Ast.Token.Tag) bool {
    return p.peek() == tag;
}

fn atKeywordLike(p: *Parse, tag: Ast.Token.Tag) bool {
    return p.peek() == tag;
}

fn eat(p: *Parse, tag: Ast.Token.Tag) bool {
    if (p.peek() == tag) {
        p.tok_i += 1;
        return true;
    }
    return false;
}

fn expect(p: *Parse, tag: Ast.Token.Tag) Error!void {
    if (!p.eat(tag)) return error.ParseError;
}

fn expectName(p: *Parse) Error![]const u8 {
    const tok = p.next();
    if (!isNameToken(p.tokenTag(tok))) return error.ParseError;
    return p.slice(tok);
}

fn peek(p: *Parse) Ast.Token.Tag {
    return p.tokenTag(p.tok_i);
}

fn next(p: *Parse) u32 {
    const tok = p.tok_i;
    p.tok_i += 1;
    return tok;
}

fn tokenTag(p: *Parse, tok: u32) Ast.Token.Tag {
    return p.tokens.items(.tag)[@intCast(tok)];
}

fn tokenStart(p: *Parse, tok: u32) usize {
    return p.tokens.items(.start)[@intCast(tok)];
}

fn slice(p: *Parse, tok: u32) []const u8 {
    var t = tokenizer.Tokenizer{
        .buffer = p.source,
        .index = p.tokenStart(tok),
    };
    const token = t.next();
    std.debug.assert(token.tag == p.tokenTag(tok));
    return p.source[token.loc.start..token.loc.end];
}

fn binaryInfo(tag: Ast.Token.Tag) ?struct { op: Plan.Binop, prec: u8 } {
    return switch (tag) {
        .keyword_or => .{ .op = .or_, .prec = 1 },
        .keyword_and => .{ .op = .and_, .prec = 2 },
        .equal => .{ .op = .eql, .prec = 3 },
        .not_equal => .{ .op = .neq, .prec = 3 },
        .angle_bracket_left => .{ .op = .lt, .prec = 3 },
        .angle_bracket_left_equal => .{ .op = .lte, .prec = 3 },
        .angle_bracket_right => .{ .op = .gt, .prec = 3 },
        .angle_bracket_right_equal => .{ .op = .gte, .prec = 3 },
        .plus => .{ .op = .add, .prec = 4 },
        .minus => .{ .op = .sub, .prec = 4 },
        .asterisk => .{ .op = .mul, .prec = 5 },
        else => null,
    };
}

fn isNameToken(tag: Ast.Token.Tag) bool {
    if (tag == .identifier) return true;
    return std.mem.startsWith(u8, @tagName(tag), "keyword_");
}

test {
    _ = @import("parser_test.zig");
}
