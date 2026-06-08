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
    try std.testing.expect(program.statements[0] == .return_only);
    try expectIntLiteral(program.statements[0].return_only.items[0].expr, 42);
}

test "parse return clause modifiers and expression precedence" {
    var program = try Ast.parse(std.testing.allocator, "RETURN DISTINCT 1 + 2 * 3 AS total ORDER BY total DESC SKIP 4 LIMIT 5");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    try std.testing.expect(program.statements[0] == .return_only);

    const ret = &program.statements[0].return_only;
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
    try std.testing.expect(program.statements[0] == .read_query);

    const read = &program.statements[0].read_query;
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

test "parse match path with labels properties and directed edge" {
    var program = try Ast.parse(std.testing.allocator, "MATCH (a:User {name: 'Ada'})-[e:Likes {since: 2024}]->(f:Food) RETURN f.name");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    try std.testing.expect(program.statements[0] == .match_query);

    const query = &program.statements[0].match_query;
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
    try std.testing.expect(program.statements[0] == .match_query);

    const query = &program.statements[0].match_query;
    try std.testing.expectEqual(@as(usize, 2), query.patterns.len);
    try expectOptionalName(query.patterns[0].start.variable, "p");
    try expectOptionalName(query.patterns[1].start.variable, "f");

    const where = query.where.?;
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

test "parse multiple mutation statements" {
    var program = try Ast.parse(std.testing.allocator, "INSERT (:Person {name: 'Ada'}); MATCH (p:Person) DETACH DELETE p; MATCH (p:Person) FINISH;");
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), program.statements.len);

    try std.testing.expect(program.statements[0] == .insert);
    const insert_patterns = program.statements[0].insert;
    try std.testing.expectEqual(@as(usize, 1), insert_patterns.len);
    try expectOptionalName(insert_patterns[0].start.label, "Person");
    try expectPropertyString(insert_patterns[0].start.properties[0], "name", "Ada");

    try std.testing.expect(program.statements[1] == .match_query);
    const delete_query = &program.statements[1].match_query;
    try std.testing.expect(delete_query.action == .delete);
    try std.testing.expect(delete_query.action.delete.detach);
    try std.testing.expectEqual(@as(usize, 1), delete_query.action.delete.variables.len);
    try std.testing.expectEqualStrings("p", delete_query.action.delete.variables[0]);

    try std.testing.expect(program.statements[2] == .match_query);
    try std.testing.expect(program.statements[2].match_query.action == .finish);
}

test "parse rejects fractional skip and limit counts" {
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "RETURN 1 SKIP 1.5"));
    try std.testing.expectError(error.ParseError, Ast.parse(std.testing.allocator, "RETURN 1 LIMIT 2.5"));
}

fn expectOptionalName(actual: ?[]const u8, expected: []const u8) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualStrings(expected, actual.?);
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
