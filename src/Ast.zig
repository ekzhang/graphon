//! Abstract syntax tree for GQL expressions, based on ISO/IEC 39075:2024.
//!
//! The flat-layout data structures defined in this file are borrowed from Zig's
//! `std.zig.Ast` struct. This is available under the MIT license.
//! https://github.com/ziglang/zig/blob/0.13.0/LICENSE
//!
//! Of course, the actual parsing was rewritten to parse GQL instead of Zig.

// Copyright (c) Zig contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @This();
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;
const Parse = @import("Parse.zig");

/// Reference to externally-owned data.
source: [:0]const u8,

tokens: TokenList.Slice,
/// The root AST node is assumed to be index 0. Since there can be no
/// references to the root node, this means 0 is available to indicate null.
nodes: NodeList.Slice,
extra_data: []Node.Index,

errors: []const Error,

pub const TokenIndex = u32;
pub const ByteOffset = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

pub const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

pub const Span = struct {
    start: u32,
    end: u32,
    main: u32,
};

pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra_data);
    gpa.free(tree.errors);
    tree.* = undefined;
}

/// Result should be freed with tree.deinit() when there are
/// no more references to any of the tokens or nodes.
pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!Ast {
    var tokens = Ast.TokenList{};
    defer tokens.deinit(gpa);

    // Empirically, the zig std lib has an 8:1 ratio of source bytes to token count.
    const estimated_token_count = source.len / 8;
    try tokens.ensureTotalCapacity(gpa, estimated_token_count);

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(token.loc.start),
        });
        if (token.tag == .eof) break;
    }

    var parser: Parse = .{
        .source = source,
        .gpa = gpa,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .errors = .{},
        .nodes = .{},
        .extra_data = .{},
        .scratch = .{},
        .tok_i = 0,
    };
    defer parser.errors.deinit(gpa);
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit(gpa);
    defer parser.scratch.deinit(gpa);

    // Empirically, Zig source code has a 2:1 ratio of tokens to AST nodes.
    // Make sure at least 1 so we can use appendAssumeCapacity on the root node below.
    const estimated_node_count = (tokens.len + 2) / 2;
    try parser.nodes.ensureTotalCapacity(gpa, estimated_node_count);

    try parser.parseRoot();

    // TODO experiment with compacting the MultiArrayList slices here
    return Ast{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = try parser.extra_data.toOwnedSlice(gpa),
        .errors = try parser.errors.toOwnedSlice(gpa),
    };
}

/// Returns an extra offset for column and byte offset of errors that
/// should point after the token in the error message.
pub fn errorOffset(tree: Ast, parse_error: Error) u32 {
    return if (parse_error.token_is_prev)
        @as(u32, @intCast(tree.tokenSlice(parse_error.token).len))
    else
        0;
}

pub fn tokenLocation(self: Ast, start_offset: ByteOffset, token_index: TokenIndex) Location {
    var loc = Location{
        .line = 0,
        .column = 0,
        .line_start = start_offset,
        .line_end = self.source.len,
    };
    const token_start = self.tokens.items(.start)[token_index];

    // Scan to by line until we go past the token start
    while (std.mem.indexOfScalarPos(u8, self.source, loc.line_start, '\n')) |i| {
        if (i >= token_start) {
            break; // Went past
        }
        loc.line += 1;
        loc.line_start = i + 1;
    }

    const offset = loc.line_start;
    for (self.source[offset..], 0..) |c, i| {
        if (i + offset == token_start) {
            loc.line_end = i + offset;
            while (loc.line_end < self.source.len and self.source[loc.line_end] != '\n') {
                loc.line_end += 1;
            }
            return loc;
        }
        if (c == '\n') {
            loc.line += 1;
            loc.column = 0;
            loc.line_start = i + 1;
        } else {
            loc.column += 1;
        }
    }
    return loc;
}

pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
    const token_starts = tree.tokens.items(.start);
    const token_tags = tree.tokens.items(.tag);
    const token_tag = token_tags[token_index];

    // Many tokens can be determined entirely by their tag.
    if (token_tag.lexeme()) |lexeme| {
        return lexeme;
    }

    // For some tokens, re-tokenization is needed to find the end.
    var tokenizer: std.zig.Tokenizer = .{
        .buffer = tree.source,
        .index = token_starts[token_index],
    };
    const token = tokenizer.next();
    assert(token.tag == token_tag);
    return tree.source[token.loc.start..token.loc.end];
}

pub fn extraData(tree: Ast, index: usize, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    inline for (fields, 0..) |field, i| {
        comptime assert(field.type == Node.Index);
        @field(result, field.name) = tree.extra_data[index + i];
    }
    return result;
}

pub fn rootDecls(tree: Ast) []const Node.Index {
    // Root is always index 0.
    const nodes_data = tree.nodes.items(.data);
    return tree.extra_data[nodes_data[0].lhs..nodes_data[0].rhs];
}

pub fn renderError(tree: Ast, parse_error: Error, stream: anytype) !void {
    const token_tags = tree.tokens.items(.tag);
    switch (parse_error.tag) {
        .chained_comparison_operators => {
            return stream.writeAll("comparison operators cannot be chained");
        },
        // TODO: Other errors

        .expected_token => {
            const found_tag = token_tags[parse_error.token + @intFromBool(parse_error.token_is_prev)];
            const expected_symbol = parse_error.extra.expected_tag.symbol();
            switch (found_tag) {
                .invalid => return stream.print("expected '{s}', found invalid bytes", .{
                    expected_symbol,
                }),
                else => return stream.print("expected '{s}', found '{s}'", .{
                    expected_symbol, found_tag.symbol(),
                }),
            }
        },
    }
}

pub fn tokensOnSameLine(tree: Ast, token1: TokenIndex, token2: TokenIndex) bool {
    const token_starts = tree.tokens.items(.start);
    const source = tree.source[token_starts[token1]..token_starts[token2]];
    return mem.indexOfScalar(u8, source, '\n') == null;
}

pub const Error = struct {
    tag: Tag,
    is_note: bool = false,
    /// True if `token` points to the token before the token causing an issue.
    token_is_prev: bool = false,
    token: TokenIndex,
    extra: union {
        none: void,
        expected_tag: Token.Tag,
    } = .{ .none = {} },

    pub const Tag = enum {
        chained_comparison_operators,

        /// `expected_tag` is populated.
        expected_token,
    };
};

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    pub const Index = u32;

    comptime {
        // Goal is to keep this under one byte for efficiency.
        assert(@sizeOf(Tag) == 1);
    }

    pub const Tag = enum {
        /// Node stored in lhs.
        root,

        /// Section 14.3, `extra_data[lhs..rhs]`.
        /// `(MATCH | LET | FOR | FILTER | ORDER BY ...)* RETURN ...`
        simple_query_statement,

        /// Section 14.4, `extra_data[lhs..rhs]`.
        /// `MATCH <graph_pattern>`
        /// `OPTIONAL MATCH <graph_pattern>`
        /// `OPTIONAL MATCH { ... }`, `OPTIONAL MATCH ( ... )`
        match_statement,

        /// Section 14.11, `extra_data[lhs..rhs]`.
        return_statement,

        /// Section 14.11, `lhs AS rhs`.
        return_alias,

        /// Section 16.4, for now just lhs is a `<path_pattern>`.
        graph_pattern,

        /// Section 16.7, `extra_data[lhs..rhs]`.
        /// List of `<path_primary>`, each possibly quantified.
        path_pattern,

        /// Section 16.7, `extra_data[lhs..rhs]`.
        /// List of node or edge patterns, or parenthesized path patterns.
        path_primary,

        /// Section 16.7, `lhs?`.
        questioned_path_primary,

        /// Section 16.11, `lhs*`, `lhs+`, `lhs[x]`, `lhs{x, y}`. GraphPatternQuantifier[rhs]
        quantified_path_primary,

        /// Section 16.7, `(Name:Label Predicate)`. `ElementPatternFiller[lhs]`.
        /// rhs is the closing parenthesis.
        node_pattern,

        /// Section 16.7. `<half_arrow> Name:Label Predicate <half_arrow>`. `ElementPatternFiller[lhs]`.
        /// main_token is the left half, and rhs is the right half.
        /// Both lhs and rhs can be null in case of an abbreviated edge pattern.
        edge_pattern,

        /// Both lhs and rhs unused.
        /// Most identifiers will not have explicit AST nodes, however for expressions
        /// which could be one of many different kinds of AST nodes, there will be an
        /// identifier AST node for it.
        identifier,

        /// Both lhs and rhs unused.
        number_literal,

        /// Both lhs and rhs unused.
        string_literal,
    };

    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };
};

pub fn nodeToSpan(tree: *const Ast, node: u32) Span {
    return tokensToSpan(
        tree,
        tree.firstToken(node),
        tree.lastToken(node),
        tree.nodes.items(.main_token)[node],
    );
}

pub fn tokenToSpan(tree: *const Ast, token: Ast.TokenIndex) Span {
    return tokensToSpan(tree, token, token, token);
}

pub fn tokensToSpan(tree: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex, main: Ast.TokenIndex) Span {
    const token_starts = tree.tokens.items(.start);
    var start_tok = start;
    var end_tok = end;

    if (tree.tokensOnSameLine(start, end)) {
        // do nothing
    } else if (tree.tokensOnSameLine(start, main)) {
        end_tok = main;
    } else if (tree.tokensOnSameLine(main, end)) {
        start_tok = main;
    } else {
        start_tok = main;
        end_tok = main;
    }
    const start_off = token_starts[start_tok];
    const end_off = token_starts[end_tok] + @as(u32, @intCast(tree.tokenSlice(end_tok).len));
    return Span{ .start = start_off, .end = end_off, .main = token_starts[main] };
}

test {
    _ = Parse;
}
