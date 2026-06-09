//! GQL parsing tests for Parse.zig

const std = @import("std");

const Ast = @import("Ast.zig");
const EdgeDirection = @import("types.zig").EdgeDirection;
const Parse = @import("Parse.zig");
const Plan = @import("Plan.zig");

test "parse object parses source into ast" {
    var parser: Parse = .{ .source = "RETURN 42", .gpa = std.testing.allocator };
    var program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    const body = try expectSingleQuery(&program.statements[0]);
    try std.testing.expect(body.* == .return_only);
    try expectIntLiteral(body.return_only.items[0].expr, 42);
}

test "parse return clause modifiers and expression precedence" {
    var program = try Ast.parse(std.testing.allocator, "RETURN DISTINCT 1 + 2 * 3 AS total ORDER BY total DESC SKIP 4 LIMIT 5");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    const body = try expectSingleQuery(&program.statements[0]);
    try std.testing.expect(body.* == .return_only);

    const ret = &body.return_only;
    try std.testing.expect(ret.distinct);
    try std.testing.expectEqual(@as(usize, 1), ret.items.len);
    try std.testing.expectEqualStrings("total", ret.items[0].alias.?);

    const add = try expectBinary(ret.items[0].expr, .add);
    try expectIntLiteral(add.left, 1);
    const mul = try expectBinary(add.right, .mul);
    try expectIntLiteral(mul.left, 2);
    try expectIntLiteral(mul.right, 3);

    try std.testing.expectEqual(@as(usize, 1), ret.order_by.len);
    try expectVariable(ret.order_by[0].expr, "total");
    try std.testing.expect(ret.order_by[0].desc);
    try std.testing.expectEqual(@as(usize, 4), ret.skip);
    try std.testing.expectEqual(@as(?usize, 5), ret.limit);
}

test "parse read query with with and optional match" {
    var program = try Ast.parse(std.testing.allocator, "MATCH (p:Person) WITH DISTINCT p, p.name AS name OPTIONAL MATCH (p)-[:Likes]->(f:Food) RETURN name, f.name");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    const body = try expectSingleQuery(&program.statements[0]);
    try std.testing.expect(body.* == .read_query);

    const read = &body.read_query;
    try std.testing.expectEqual(@as(usize, 3), read.clauses.len);
    try std.testing.expect(read.clauses[0] == .match);
    try std.testing.expect(read.clauses[1] == .with);
    try std.testing.expect(read.clauses[2] == .optional_match);

    const first = read.clauses[0].match;
    try std.testing.expectEqual(@as(usize, 1), first.patterns.len);
    try expectOptionalName(first.patterns[0].start.variable, "p");
    try expectOptionalName(first.patterns[0].start.label, "Person");

    const with = read.clauses[1].with;
    try std.testing.expect(with.distinct);
    try std.testing.expectEqual(@as(usize, 2), with.items.len);
    try expectVariable(with.items[0].expr, "p");
    try expectPropertyExpr(with.items[1].expr, "p", "name");
    try std.testing.expectEqualStrings("name", with.items[1].alias.?);

    const optional = read.clauses[2].optional_match;
    try std.testing.expectEqual(@as(usize, 1), optional.patterns.len);
    try expectOptionalName(optional.patterns[0].start.variable, "p");
    try std.testing.expectEqual(@as(usize, 1), optional.patterns[0].segments.len);
    try expectOptionalName(optional.patterns[0].segments[0].node.variable, "f");

    try std.testing.expectEqual(@as(usize, 2), read.ret.items.len);
    try expectVariable(read.ret.items[0].expr, "name");
    try expectPropertyExpr(read.ret.items[1].expr, "f", "name");
}

test "parse union query" {
    var program = try Ast.parse(std.testing.allocator, "RETURN 1 AS n UNION MATCH (p:Person) RETURN p.age UNION ALL RETURN 2");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    try std.testing.expect(program.statements[0] == .query);
    try std.testing.expect(program.statements[0].query == .union_query);

    const union_query = &program.statements[0].query.union_query;
    try std.testing.expect(union_query.first == .return_only);
    try expectIntLiteral(union_query.first.return_only.items[0].expr, 1);
    try std.testing.expectEqual(@as(usize, 2), union_query.parts.len);
    try std.testing.expect(!union_query.parts[0].all);
    try std.testing.expect(union_query.parts[0].query == .match_query);
    try expectPropertyExpr(union_query.parts[0].query.match_query.action.ret.items[0].expr, "p", "age");
    try std.testing.expect(union_query.parts[1].all);
    try std.testing.expect(union_query.parts[1].query == .return_only);
    try expectIntLiteral(union_query.parts[1].query.return_only.items[0].expr, 2);
}

test "parse count aggregate calls" {
    var program = try Ast.parse(std.testing.allocator, "MATCH (p:Person) WITH p, count(*) AS total RETURN COUNT(DISTINCT p) AS people, SUM(p.age), AVG(p.age), MIN(p.name), MAX(p.age), total");
    defer program.deinit(std.testing.allocator);

    const body = try expectSingleQuery(&program.statements[0]);
    try std.testing.expect(body.* == .read_query);
    const read = &body.read_query;
    try std.testing.expect(read.clauses[1] == .with);

    const with = read.clauses[1].with;
    try std.testing.expectEqual(@as(usize, 2), with.items.len);
    try expectVariable(with.items[0].expr, "p");
    const count_all = try expectAggregate(with.items[1].expr, .count);
    try std.testing.expect(count_all.argument == null);
    try std.testing.expectEqualStrings("total", with.items[1].alias.?);

    const ret = read.ret;
    const count_p = try expectAggregate(ret.items[0].expr, .count);
    try std.testing.expect(count_p.distinct);
    try std.testing.expect(count_p.argument != null);
    try expectVariable(count_p.argument.?, "p");
    try std.testing.expectEqualStrings("people", ret.items[0].alias.?);

    const sum_age = try expectAggregate(ret.items[1].expr, .sum);
    try std.testing.expect(!sum_age.distinct);
    try expectPropertyExpr(sum_age.argument.?, "p", "age");
    const avg_age = try expectAggregate(ret.items[2].expr, .avg);
    try expectPropertyExpr(avg_age.argument.?, "p", "age");
    const min_name = try expectAggregate(ret.items[3].expr, .min);
    try expectPropertyExpr(min_name.argument.?, "p", "name");
    const max_age = try expectAggregate(ret.items[4].expr, .max);
    try expectPropertyExpr(max_age.argument.?, "p", "age");
    try expectVariable(ret.items[5].expr, "total");
}

test "parse rejects invalid aggregate star arguments" {
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "RETURN SUM(*)"));
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "RETURN COUNT(DISTINCT *)"));
}

test "parse aggregate expressions" {
    var program = try Ast.parse(std.testing.allocator, "MATCH (p:Person) RETURN COUNT(p) + 1 AS adjusted");
    defer program.deinit(std.testing.allocator);

    const body = try expectSingleQuery(&program.statements[0]);
    const ret = body.match_query.action.ret;
    const add = try expectBinary(ret.items[0].expr, .add);
    _ = try expectAggregate(add.left, .count);
    try expectIntLiteral(add.right, 1);
    try std.testing.expectEqualStrings("adjusted", ret.items[0].alias.?);
}

test "parse match path with labels properties and directed edge" {
    var program = try Ast.parse(std.testing.allocator, "MATCH (a:User {name: 'Ada'})-[e:Likes {since: 2024}]->(f:Food) RETURN f.name");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    const body = try expectSingleQuery(&program.statements[0]);
    try std.testing.expect(body.* == .match_query);

    const query = &body.match_query;
    try std.testing.expectEqual(@as(usize, 1), query.patterns.len);
    try expectOptionalName(query.patterns[0].start.variable, "a");
    try expectOptionalName(query.patterns[0].start.label, "User");
    try expectPropertyString(query.patterns[0].start.properties[0], "name", "Ada");

    try std.testing.expectEqual(@as(usize, 1), query.patterns[0].segments.len);
    const segment = &query.patterns[0].segments[0];
    try expectOptionalName(segment.edge.variable, "e");
    try expectOptionalName(segment.edge.label, "Likes");
    try std.testing.expectEqual(EdgeDirection.right, segment.edge.direction);
    try expectPropertyInt(segment.edge.properties[0], "since", 2024);
    try expectOptionalName(segment.node.variable, "f");
    try expectOptionalName(segment.node.label, "Food");

    try std.testing.expect(query.action == .ret);
    try expectPropertyExpr(query.action.ret.items[0].expr, "f", "name");
}

test "parse match where and set clauses" {
    var program = try Ast.parse(std.testing.allocator, "MATCH (p:Person), (f:Food) WHERE NOT (p.age < 30 AND f.name <> 'Soup') SET p.favorite = f.name, p.active = true");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    const mutation = try expectMutation(&program.statements[0]);
    try std.testing.expect(mutation.* == .match);

    const query = &mutation.match;
    try std.testing.expectEqual(@as(usize, 2), query.patterns.len);
    try expectOptionalName(query.patterns[0].start.variable, "p");
    try expectOptionalName(query.patterns[1].start.variable, "f");

    const where = query.where.?.expr;
    const not = try expectUnary(where, .not);
    const and_expr = try expectBinary(not.operand, .and_);
    const lt = try expectBinary(and_expr.left, .lt);
    try expectPropertyExpr(lt.left, "p", "age");
    try expectIntLiteral(lt.right, 30);
    const neq = try expectBinary(and_expr.right, .neq);
    try expectPropertyExpr(neq.left, "f", "name");
    try expectStringLiteral(neq.right, "Soup");

    try std.testing.expect(query.action == .set);
    const sets = query.action.set;
    try std.testing.expectEqual(@as(usize, 2), sets.len);
    try std.testing.expectEqualStrings("p", sets[0].variable);
    try std.testing.expectEqualStrings("favorite", sets[0].property);
    try expectPropertyExpr(sets[0].value, "f", "name");
    try std.testing.expectEqualStrings("active", sets[1].property);
    try expectBoolLiteral(sets[1].value, true);
}

test "parse where path predicates" {
    var program = try Ast.parse(std.testing.allocator, "MATCH (a:Person), (b:Person) WHERE NOT (a)-[:Knows]->(b) RETURN b.name");
    defer program.deinit(std.testing.allocator);

    const body = try expectSingleQuery(&program.statements[0]);
    const where = body.match_query.where.?;
    try std.testing.expect(where == .not_path_pattern);
    try expectOptionalName(where.not_path_pattern.start.variable, "a");
    try std.testing.expectEqual(@as(usize, 1), where.not_path_pattern.segments.len);
    try expectOptionalName(where.not_path_pattern.segments[0].edge.label, "Knows");
    try expectOptionalName(where.not_path_pattern.segments[0].node.variable, "b");
}

test "parse match edge patterns with implicit endpoints" {
    var program = try Ast.parse(std.testing.allocator, "MATCH -[:Knows]-> RETURN COUNT(*)");
    defer program.deinit(std.testing.allocator);

    const body = try expectSingleQuery(&program.statements[0]);
    try std.testing.expect(body.* == .match_query);
    const pattern = body.match_query.patterns[0];
    try std.testing.expect(pattern.start.variable == null);
    try std.testing.expect(pattern.start.label == null);
    try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
    try expectOptionalName(pattern.segments[0].edge.label, "Knows");
    try std.testing.expectEqual(EdgeDirection.right, pattern.segments[0].edge.direction);
    try std.testing.expect(pattern.segments[0].node.variable == null);
    try std.testing.expect(pattern.segments[0].node.label == null);
}

test "parse GQL edge direction variants" {
    try expectSingleEdgeDirection("MATCH ()-[]-() RETURN COUNT(*)", .any);
    try expectSingleEdgeDirection("MATCH ()~[]~() RETURN COUNT(*)", .undirected);
    try expectSingleEdgeDirection("MATCH ()<-[]->() RETURN COUNT(*)", .left_or_right);
    try expectSingleEdgeDirection("MATCH ()<~[]~() RETURN COUNT(*)", .left_or_undirected);
    try expectSingleEdgeDirection("MATCH ()~[]~>() RETURN COUNT(*)", .right_or_undirected);
}

test "parse match path patterns with implicit leading and trailing endpoints" {
    var program = try Ast.parse(std.testing.allocator, "MATCH -[:From]->(n:Node)-[:To]-> RETURN n");
    defer program.deinit(std.testing.allocator);

    const body = try expectSingleQuery(&program.statements[0]);
    try std.testing.expect(body.* == .match_query);
    const pattern = body.match_query.patterns[0];
    try std.testing.expect(pattern.start.variable == null);
    try std.testing.expectEqual(@as(usize, 2), pattern.segments.len);
    try expectOptionalName(pattern.segments[0].edge.label, "From");
    try expectOptionalName(pattern.segments[0].node.variable, "n");
    try expectOptionalName(pattern.segments[0].node.label, "Node");
    try expectOptionalName(pattern.segments[1].edge.label, "To");
    try std.testing.expect(pattern.segments[1].node.variable == null);
    try std.testing.expect(pattern.segments[1].node.label == null);
}

test "parse where edge predicates" {
    var program = try Ast.parse(std.testing.allocator, "MATCH (a:Person) WHERE -[:Knows]-> RETURN a");
    defer program.deinit(std.testing.allocator);

    const body = try expectSingleQuery(&program.statements[0]);
    const where = body.match_query.where.?;
    try std.testing.expect(where == .path_pattern);
    try std.testing.expectEqual(@as(usize, 1), where.path_pattern.segments.len);
    try expectOptionalName(where.path_pattern.segments[0].edge.label, "Knows");
    try std.testing.expectEqual(EdgeDirection.right, where.path_pattern.segments[0].edge.direction);
    try std.testing.expect(where.path_pattern.segments[0].node.variable == null);
}

test "parse multiple mutation statements" {
    var program = try Ast.parse(std.testing.allocator, "INSERT (:Person {name: 'Ada'}); MATCH (p:Person) DETACH DELETE p; MATCH (p:Person) FINISH;");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), program.statements.len);

    const insert_mutation = try expectMutation(&program.statements[0]);
    try std.testing.expect(insert_mutation.* == .insert);
    const insert_patterns = insert_mutation.insert;
    try std.testing.expectEqual(@as(usize, 1), insert_patterns.len);
    try expectOptionalName(insert_patterns[0].start.label, "Person");
    try expectPropertyString(insert_patterns[0].start.properties[0], "name", "Ada");

    const delete_mutation = try expectMutation(&program.statements[1]);
    try std.testing.expect(delete_mutation.* == .match);
    const delete_query = &delete_mutation.match;
    try std.testing.expect(delete_query.action == .delete);
    try std.testing.expect(delete_query.action.delete.detach);
    try std.testing.expectEqual(@as(usize, 1), delete_query.action.delete.variables.len);
    try std.testing.expectEqualStrings("p", delete_query.action.delete.variables[0]);

    const finish_mutation = try expectMutation(&program.statements[2]);
    try std.testing.expect(finish_mutation.* == .match);
    try std.testing.expect(finish_mutation.match.action == .finish);
}

test "parse insert requires explicit edge endpoints" {
    var program = try Ast.parse(std.testing.allocator, "INSERT ()-[]->()");
    defer program.deinit(std.testing.allocator);

    const insert = try expectMutation(&program.statements[0]);
    try std.testing.expect(insert.* == .insert);
    try std.testing.expectEqual(@as(usize, 1), insert.insert.len);
    try std.testing.expectEqual(@as(usize, 1), insert.insert[0].segments.len);
    try std.testing.expectEqual(EdgeDirection.right, insert.insert[0].segments[0].edge.direction);

    var undirected_program = try Ast.parse(std.testing.allocator, "INSERT ()~[]~()");
    defer undirected_program.deinit(std.testing.allocator);
    const undirected_insert = try expectMutation(&undirected_program.statements[0]);
    try std.testing.expectEqual(EdgeDirection.undirected, undirected_insert.insert[0].segments[0].edge.direction);

    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "INSERT -[]-"));
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "INSERT ()-[]-()"));
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "INSERT ()-[]->"));
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "INSERT -[]->()"));
}

test "parse ISO GQL comments" {
    var program = try Ast.parse(std.testing.allocator,
        \\// Insert a seed user.
        \\INSERT (:Person {name: 'Ada'}) -- statement-local comment
        \\/* Then read the user back. */
        \\MATCH (p:Person {name: 'Ada'}) RETURN p.name
    );
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), program.statements.len);
    try std.testing.expect((try expectMutation(&program.statements[0])).* == .insert);
    const body = try expectSingleQuery(&program.statements[1]);
    try std.testing.expect(body.* == .match_query);

    const query = &body.match_query;
    try std.testing.expect(query.action == .ret);
    try expectPropertyExpr(query.action.ret.items[0].expr, "p", "name");
}

test "parse keeps comment delimiters inside strings" {
    var program = try Ast.parse(std.testing.allocator, "RETURN '// not a comment', '-- not a comment', '/* not a comment */'");
    defer program.deinit(std.testing.allocator);

    const body = try expectSingleQuery(&program.statements[0]);
    const ret = &body.return_only;
    try expectStringLiteral(ret.items[0].expr, "// not a comment");
    try expectStringLiteral(ret.items[1].expr, "-- not a comment");
    try expectStringLiteral(ret.items[2].expr, "/* not a comment */");
}

test "parse rejects invalid comment forms" {
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "RETURN 1 /* unterminated"));
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "MATCH (:User)<--(n:User) RETURN n"));
}

test "parse rejects fractional skip and limit counts" {
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "RETURN 1 SKIP 1.5"));
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "RETURN 1 LIMIT 2.5"));
}

fn expectOptionalName(actual: ?[]const u8, expected: []const u8) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualStrings(expected, actual.?);
}

fn expectSingleEdgeDirection(source: [:0]const u8, expected: EdgeDirection) !void {
    var program = try Ast.parse(std.testing.allocator, source);
    defer program.deinit(std.testing.allocator);

    const body = try expectSingleQuery(&program.statements[0]);
    try std.testing.expect(body.* == .match_query);
    try std.testing.expectEqual(@as(usize, 1), body.match_query.patterns.len);
    try std.testing.expectEqual(@as(usize, 1), body.match_query.patterns[0].segments.len);
    try std.testing.expectEqual(expected, body.match_query.patterns[0].segments[0].edge.direction);
}

fn expectSingleQuery(statement: *Ast.Statement) !*Ast.QueryBody {
    try std.testing.expect(statement.* == .query);
    try std.testing.expect(statement.query == .single);
    return &statement.query.single;
}

fn expectMutation(statement: *Ast.Statement) !*Ast.MutationQuery {
    try std.testing.expect(statement.* == .mutation);
    return &statement.mutation;
}

fn expectBinary(expr: Ast.Expr, op: Plan.Binop) !*Ast.BinaryExpr {
    try std.testing.expect(expr == .binary);
    try std.testing.expectEqual(op, expr.binary.op);
    return expr.binary;
}

fn expectUnary(expr: Ast.Expr, op: Plan.UnaryOp) !*Ast.UnaryExpr {
    try std.testing.expect(expr == .unary);
    try std.testing.expectEqual(op, expr.unary.op);
    return expr.unary;
}

fn expectAggregate(expr: Ast.Expr, function: Plan.AggregateFunction) !*Ast.AggregateCall {
    try std.testing.expect(expr == .aggregate);
    try std.testing.expectEqual(function, expr.aggregate.function);
    return expr.aggregate;
}

fn expectVariable(expr: Ast.Expr, expected: []const u8) !void {
    try std.testing.expect(expr == .variable);
    try std.testing.expectEqualStrings(expected, expr.variable);
}

fn expectPropertyExpr(expr: Ast.Expr, variable: []const u8, property: []const u8) !void {
    try std.testing.expect(expr == .property);
    try std.testing.expectEqualStrings(variable, expr.property.variable);
    try std.testing.expectEqualStrings(property, expr.property.property);
}

fn expectPropertyInt(property: Ast.Property, expected_key: []const u8, expected_value: i64) !void {
    try std.testing.expectEqualStrings(expected_key, property.key);
    try expectIntLiteral(property.value, expected_value);
}

fn expectPropertyString(property: Ast.Property, expected_key: []const u8, expected_value: []const u8) !void {
    try std.testing.expectEqualStrings(expected_key, property.key);
    try expectStringLiteral(property.value, expected_value);
}

fn expectIntLiteral(expr: Ast.Expr, expected: i64) !void {
    try std.testing.expect(expr == .literal);
    try std.testing.expect(expr.literal == .int64);
    try std.testing.expectEqual(expected, expr.literal.int64);
}

fn expectStringLiteral(expr: Ast.Expr, expected: []const u8) !void {
    try std.testing.expect(expr == .literal);
    try std.testing.expect(expr.literal == .string);
    try std.testing.expectEqualStrings(expected, expr.literal.string);
}

fn expectBoolLiteral(expr: Ast.Expr, expected: bool) !void {
    try std.testing.expect(expr == .literal);
    try std.testing.expect(expr.literal == .bool);
    try std.testing.expectEqual(expected, expr.literal.bool);
}
