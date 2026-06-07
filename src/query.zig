//! Minimal GQL parser and execution layer for the functional Graphon MVP.
//!
//! This module intentionally implements a small, useful subset of GQL while the
//! full ISO grammar is still being built out. Supported today:
//!
//! * `RETURN` scalar expressions (`+`, `-`, `*`, `=`, `<>`) and properties.
//! * `INSERT` node/edge path patterns.
//! * `MATCH` node/edge path patterns with labels and property predicates.
//! * `MATCH ... RETURN`, `MATCH ... INSERT`, `MATCH ... SET`, and
//!   `MATCH ... [DETACH] DELETE`, and `MATCH ... FINISH`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const planner = @import("query/planner.zig");
const runtime = @import("query/runtime.zig");
const storage = @import("storage.zig");
const types = @import("types.zig");
const Value = types.Value;

pub const Error = planner.Error || runtime.Error || error{InvalidRequest};

pub const ResultSet = runtime.ResultSet;
pub const Row = runtime.Row;
pub const ResultValue = runtime.ResultValue;
pub const NodeObject = runtime.NodeObject;
pub const EdgeObject = runtime.EdgeObject;
pub const ResultProperty = runtime.ResultProperty;

pub const CompiledProgram = planner.CompiledProgram;
pub const CompiledStatement = planner.CompiledStatement;
pub const CompiledResult = planner.CompiledResult;
pub const ResultColumn = planner.ResultColumn;

pub fn compile(allocator: Allocator, source: [:0]const u8) Error!CompiledProgram {
    return try planner.compile(allocator, source);
}

pub fn execute(allocator: Allocator, io: std.Io, store: storage.Storage, source: [:0]const u8) Error!ResultSet {
    _ = io;
    var compiled = try compile(allocator, source);
    defer compiled.deinit(allocator);

    var txn = store.txn();
    defer txn.close();

    var result = ResultSet{ .rows_affected = 0 };
    errdefer result.deinit(allocator);

    for (compiled.statements) |*statement| {
        const next_result = try runtime.executeCompiledStatement(allocator, txn, statement.*);
        result.deinit(allocator);
        result = next_result;
    }

    try txn.commit();
    return result;
}

// ------------------------------- Tests ------------------------------------

const Snap = @import("vendor/snaptest.zig").Snap;
const snap = Snap.snap;

fn execForTest(store: storage.Storage, source: [:0]const u8) !ResultSet {
    return try execute(std.testing.allocator, std.testing.io, store, source);
}

fn checkQueryPlanSnapshot(source: [:0]const u8, want: Snap) !void {
    var compiled = try compile(std.testing.allocator, source);
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), compiled.statements.len);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try compiled.statements[0].plan.print(&out.writer);
    try want.diff(out.written());
}

fn jsonForTest(result: ResultSet) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try result.writeJson(&buf.writer);
    return try buf.toOwnedSlice();
}

fn resultContainsString(result: ResultSet, column: usize, expected: []const u8) bool {
    for (result.rows) |row| {
        if (row.values[column] != .scalar) continue;
        const scalar = row.values[column].scalar;
        if (scalar != .string) continue;
        if (std.mem.eql(u8, scalar.string, expected)) return true;
    }
    return false;
}

test "compile match return query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) WHERE p.age > 30 RETURN p.name ORDER BY p.age DESC LIMIT 2", snap(@src(),
        \\Plan{%1}
        \\  Limit 2
        \\  Sort %2 desc
        \\  Project %2: %0.age
        \\  Project %1: %0.name
        \\  Filter (%0.age > 30)
        \\  NodeScan (%0:Person)
    ));
}

test "compile match set query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person {name: 'Eric'}) SET p.age = 23", snap(@src(),
        \\Plan{}
        \\  Update %0.age = 23
        \\  Filter (%0.name = 'Eric')
        \\  NodeScan (%0:Person)
    ));
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

test "return limit zero" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "RETURN 100 * 3 LIMIT 0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), result.columns.len);
    try std.testing.expectEqualStrings("expr", result.columns[0]);
}

test "return skip one" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "RETURN 100 * 3 SKIP 1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), result.columns.len);
    try std.testing.expectEqualStrings("expr", result.columns[0]);
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

test "match return limit" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'}), (:Person {name: 'Cara'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 3), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name LIMIT 2");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);
        try std.testing.expectEqual(@as(usize, 1), result.columns.len);
        try std.testing.expectEqualStrings("p.name", result.columns[0]);
    }
}

test "match return skip and limit" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'}), (:Person {name: 'Cara'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 3), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name SKIP 1 LIMIT 1");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqual(@as(usize, 1), result.columns.len);
        try std.testing.expectEqualStrings("p.name", result.columns[0]);
    }
}

test "match return order by" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada', age: 30}),
            \\       (:Person {name: 'Bert', age: 41}),
            \\       (:Person {name: 'Cara', age: 42})
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 3), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name ORDER BY p.age");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 3), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].scalar.string);
        try std.testing.expectEqualStrings("Bert", result.rows[1].values[0].scalar.string);
        try std.testing.expectEqualStrings("Cara", result.rows[2].values[0].scalar.string);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name ORDER BY p.age DESC SKIP 1 LIMIT 1");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Bert", result.rows[0].values[0].scalar.string);
    }
}

test "match where filters with comparisons and boolean operators" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada', age: 30, active: true}),
            \\       (:Person {name: 'Bert', age: 41, active: false}),
            \\       (:Person {name: 'Cara', age: 42, active: true})
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 3), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) WHERE p.age > 30 AND p.active = true RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Cara", result.rows[0].values[0].scalar.string);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) WHERE NOT p.active OR p.age <= 30 RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);
        try std.testing.expect(resultContainsString(result, 0, "Ada"));
        try std.testing.expect(resultContainsString(result, 0, "Bert"));
    }
}

test "match finish counts matched rows" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 2), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) FINISH");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 2), result.rows_affected);
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
