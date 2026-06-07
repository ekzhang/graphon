//! Parser for the currently supported Graphon query subset.
//!
//! This parser intentionally targets the MVP AST in `Ast.zig`, not the full ISO
//! GQL grammar.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Plan = @import("Plan.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const EdgeDirection = @import("types.zig").EdgeDirection;

pub const Error = error{ParseError} || Allocator.Error;

const Lexeme = struct {
    tag: Token.Tag,
    start: usize,
    end: usize,
};

pub fn parse(allocator: Allocator, source: [:0]const u8) Error!Ast.Program {
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
    defer allocator.free(owned_tokens);

    var parser = Parser{ .allocator = allocator, .source = source, .tokens = owned_tokens };
    var statements = std.ArrayList(Ast.Statement).empty;
    errdefer {
        for (statements.items) |*statement| statement.deinit(allocator);
        statements.deinit(allocator);
    }

    while (!parser.at(.eof)) {
        if (parser.eat(.semicolon)) continue;
        var statement: ?Ast.Statement = try parser.parseStatement();
        errdefer if (statement) |*s| s.deinit(allocator);
        try statements.append(allocator, statement.?);
        statement = null;
        _ = parser.eat(.semicolon);
    }

    return .{ .statements = try statements.toOwnedSlice(allocator) };
}

const Parser = struct {
    allocator: Allocator,
    source: [:0]const u8,
    tokens: []Lexeme,
    i: usize = 0,

    fn parseStatement(p: *Parser) Error!Ast.Statement {
        if (p.eat(.keyword_return)) {
            return .{ .return_only = try p.parseReturnClause() };
        }
        if (p.eat(.keyword_insert)) {
            return .{ .insert = try p.parsePatternListUntilAction() };
        }
        if (p.eat(.keyword_match)) {
            const patterns = try p.parsePatternListUntilAction();
            errdefer Ast.deinitPatterns(patterns, p.allocator);
            var where: ?Ast.Expr = null;
            errdefer if (where) |*expr| expr.deinit(p.allocator);
            if (p.eat(.keyword_where)) {
                where = try p.parseExpr(0);
            }
            const action = try p.parseMatchAction();
            return .{ .match_query = .{ .patterns = patterns, .where = where, .action = action } };
        }
        return error.ParseError;
    }

    fn parseMatchAction(p: *Parser) Error!Ast.MatchAction {
        if (p.eat(.keyword_return)) return .{ .ret = try p.parseReturnClause() };
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

    fn parseSetClauses(p: *Parser) Error![]Ast.SetClause {
        var clauses = std.ArrayList(Ast.SetClause).empty;
        errdefer {
            for (clauses.items) |*clause| clause.deinit(p.allocator);
            clauses.deinit(p.allocator);
        }
        while (true) {
            const variable = try p.expectName();
            try p.expect(.period);
            const property = try p.expectName();
            try p.expect(.equal);
            var value: ?Ast.Expr = try p.parseExpr(0);
            errdefer if (value) |*expr| expr.deinit(p.allocator);
            try clauses.append(p.allocator, .{ .variable = variable, .property = property, .value = value.? });
            value = null;
            if (!p.eat(.comma)) break;
        }
        return try clauses.toOwnedSlice(p.allocator);
    }

    fn parseReturnClause(p: *Parser) Error!Ast.ReturnClause {
        const items = try p.parseReturnItems();
        var ret = Ast.ReturnClause{ .items = items };
        errdefer ret.deinit(p.allocator);
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

    fn parseSortItems(p: *Parser) Error![]Ast.SortItem {
        var items = std.ArrayList(Ast.SortItem).empty;
        errdefer {
            for (items.items) |*item| item.deinit(p.allocator);
            items.deinit(p.allocator);
        }
        while (!p.at(.keyword_skip) and !p.at(.keyword_limit) and !p.at(.semicolon) and !p.at(.eof)) {
            var expr: ?Ast.Expr = try p.parseExpr(0);
            errdefer if (expr) |*e| e.deinit(p.allocator);
            const desc = if (p.eat(.keyword_desc) or p.eat(.keyword_descending))
                true
            else if (p.eat(.keyword_asc) or p.eat(.keyword_ascending))
                false
            else
                false;
            try items.append(p.allocator, .{ .expr = expr.?, .desc = desc });
            expr = null;
            if (!p.eat(.comma)) break;
        }
        if (items.items.len == 0) return error.ParseError;
        return try items.toOwnedSlice(p.allocator);
    }

    fn parseReturnItems(p: *Parser) Error![]Ast.ReturnItem {
        var items = std.ArrayList(Ast.ReturnItem).empty;
        errdefer {
            for (items.items) |*item| item.deinit(p.allocator);
            items.deinit(p.allocator);
        }
        while (!p.at(.keyword_order) and !p.at(.keyword_skip) and !p.at(.keyword_limit) and !p.at(.semicolon) and !p.at(.eof)) {
            var expr: ?Ast.Expr = try p.parseExpr(0);
            errdefer if (expr) |*e| e.deinit(p.allocator);
            const alias = if (p.eat(.keyword_as)) try p.expectName() else null;
            try items.append(p.allocator, .{ .expr = expr.?, .alias = alias });
            expr = null;
            if (!p.eat(.comma)) break;
        }
        if (items.items.len == 0) return error.ParseError;
        return try items.toOwnedSlice(p.allocator);
    }

    fn parseCount(p: *Parser) Error!usize {
        const tok = p.next();
        if (tok.tag != .number_literal) return error.ParseError;
        const s = p.slice(tok);
        if (std.mem.indexOfScalar(u8, s, '.') != null) return error.ParseError;
        return std.fmt.parseInt(usize, s, 10) catch return error.ParseError;
    }

    fn parsePatternListUntilAction(p: *Parser) Error![]Ast.PathPattern {
        var patterns = std.ArrayList(Ast.PathPattern).empty;
        errdefer {
            for (patterns.items) |*pattern| pattern.deinit(p.allocator);
            patterns.deinit(p.allocator);
        }
        while (!p.at(.semicolon) and !p.at(.eof) and !p.atActionKeyword()) {
            var pattern: ?Ast.PathPattern = try p.parsePathPattern();
            errdefer if (pattern) |*patt| patt.deinit(p.allocator);
            try patterns.append(p.allocator, pattern.?);
            pattern = null;
            if (!p.eat(.comma)) break;
        }
        if (patterns.items.len == 0) return error.ParseError;
        return try patterns.toOwnedSlice(p.allocator);
    }

    fn parsePathPattern(p: *Parser) Error!Ast.PathPattern {
        const start = try p.parseNodePattern();
        errdefer {
            var s = start;
            s.deinit(p.allocator);
        }
        var segments = std.ArrayList(Ast.PathSegment).empty;
        errdefer {
            for (segments.items) |*segment| segment.deinit(p.allocator);
            segments.deinit(p.allocator);
        }
        while (p.edgeStartsHere()) {
            var edge: ?Ast.EdgePattern = try p.parseEdgePattern();
            errdefer if (edge) |*e| e.deinit(p.allocator);
            var node: ?Ast.NodePattern = try p.parseNodePattern();
            errdefer if (node) |*n| n.deinit(p.allocator);
            try segments.append(p.allocator, .{ .edge = edge.?, .node = node.? });
            edge = null;
            node = null;
        }
        return .{ .start = start, .segments = try segments.toOwnedSlice(p.allocator) };
    }

    fn parseNodePattern(p: *Parser) Error!Ast.NodePattern {
        try p.expect(.l_paren);
        var node = Ast.NodePattern{};
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

    fn parseEdgePattern(p: *Parser) Error!Ast.EdgePattern {
        var direction: EdgeDirection = .undirected;
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

        var edge = Ast.EdgePattern{ .direction = direction };
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

    fn parseProperties(p: *Parser) Error![]Ast.Property {
        try p.expect(.l_brace);
        var properties = std.ArrayList(Ast.Property).empty;
        errdefer {
            for (properties.items) |*property| property.deinit(p.allocator);
            properties.deinit(p.allocator);
        }
        while (!p.eat(.r_brace)) {
            const key = try p.expectName();
            try p.expect(.colon);
            var value: ?Ast.Expr = try p.parseExpr(0);
            errdefer if (value) |*expr| expr.deinit(p.allocator);
            try properties.append(p.allocator, .{ .key = key, .value = value.? });
            value = null;
            if (!p.eat(.comma)) {
                try p.expect(.r_brace);
                break;
            }
        }
        return try properties.toOwnedSlice(p.allocator);
    }

    fn parseExpr(p: *Parser, min_prec: u8) Error!Ast.Expr {
        var left = try p.parseUnary();
        errdefer left.deinit(p.allocator);

        while (binaryInfo(p.peek())) |info| {
            if (info.prec < min_prec) break;
            _ = p.next();
            var right: ?Ast.Expr = try p.parseExpr(info.prec + 1);
            errdefer if (right) |*expr| expr.deinit(p.allocator);
            const bin = try p.allocator.create(Ast.BinaryExpr);
            bin.* = .{ .op = info.op, .left = left, .right = right.? };
            right = null;
            left = .{ .binary = bin };
        }
        return left;
    }

    fn parseUnary(p: *Parser) Error!Ast.Expr {
        if (p.eat(.keyword_not)) {
            var operand: ?Ast.Expr = try p.parseExpr(3);
            errdefer if (operand) |*expr| expr.deinit(p.allocator);
            const unary = try p.allocator.create(Ast.UnaryExpr);
            unary.* = .{ .op = .not, .operand = operand.? };
            operand = null;
            return .{ .unary = unary };
        }
        return p.parsePrimary();
    }

    fn parsePrimary(p: *Parser) Error!Ast.Expr {
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

    fn atActionKeyword(p: *Parser) bool {
        return switch (p.peek()) {
            .keyword_return, .keyword_insert, .keyword_delete, .keyword_detach, .keyword_set, .keyword_finish, .keyword_where => true,
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

fn binaryInfo(tag: Token.Tag) ?struct { op: Plan.Binop, prec: u8 } {
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

fn isNameToken(tag: Token.Tag) bool {
    if (tag == .identifier) return true;
    return std.mem.startsWith(u8, @tagName(tag), "keyword_");
}

test {
    _ = @import("parser_test.zig");
}
