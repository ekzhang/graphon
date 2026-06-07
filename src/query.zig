//! GQL query pipeline for the currently supported Graphon language subset.
//!
//! Queries are parsed, lowered into `Plan.zig`, and executed through the shared
//! executor. The pipeline is intended to last; the supported language coverage
//! is still growing toward the full ISO grammar. Supported today:
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
pub const StatementCursor = runtime.StatementCursor;
pub const StatementResultKind = runtime.StatementResultKind;

pub const CompiledProgram = planner.CompiledProgram;
pub const CompiledStatement = planner.CompiledStatement;
pub const CompiledResult = planner.CompiledResult;
pub const ResultColumn = planner.ResultColumn;

pub fn compile(gpa: Allocator, source: [:0]const u8) Error!CompiledProgram {
    return try planner.compile(gpa, source);
}

/// Owns a compiled query program and transaction while statement results are
/// pulled. A cursor returned by `nextStatement` borrows both, so callers should
/// finish and deinit each cursor before advancing or committing the execution.
///
/// Allocator split:
/// * `gpa` owns query-level data: parsed/compiled program state and any rows or
///   result objects that escape execution.
/// * `store.allocator`, through the transaction, owns storage-decoded graph
///   objects and executor scratch state while a statement is being pulled.
pub const Execution = struct {
    gpa: Allocator,
    compiled: CompiledProgram,
    txn: storage.Transaction,
    next_statement: usize = 0,
    committed: bool = false,

    pub fn init(gpa: Allocator, store: storage.Storage, source: [:0]const u8) Error!Execution {
        var compiled = try compile(gpa, source);
        errdefer compiled.deinit(gpa);
        return .{
            .gpa = gpa,
            .compiled = compiled,
            .txn = store.txn(),
        };
    }

    pub fn deinit(self: *Execution) void {
        self.txn.close();
        self.compiled.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn nextStatement(self: *Execution) Error!?StatementCursor {
        if (self.next_statement >= self.compiled.statements.len) return null;
        const statement = &self.compiled.statements[self.next_statement];
        var cursor = try StatementCursor.init(self.gpa, self.txn, statement);
        errdefer cursor.deinit();
        self.next_statement += 1;
        return cursor;
    }

    pub fn commit(self: *Execution) Error!void {
        if (self.committed) return;
        try self.txn.commit();
        self.committed = true;
    }
};

pub fn execute(gpa: Allocator, store: storage.Storage, source: [:0]const u8) Error!ResultSet {
    var execution = try Execution.init(gpa, store, source);
    defer execution.deinit();

    var result = ResultSet{ .rows_affected = 0 };
    errdefer result.deinit(gpa);

    while (try execution.nextStatement()) |cursor_value| {
        var cursor = cursor_value;
        defer cursor.deinit();
        const next_result = try cursor.collect();
        result.deinit(gpa);
        result = next_result;
    }

    try execution.commit();
    return result;
}

// ------------------------------- Tests ------------------------------------

const Snap = @import("vendor/snaptest.zig").Snap;
const snap = Snap.snap;

fn execForTest(store: storage.Storage, source: [:0]const u8) !ResultSet {
    return try execute(std.testing.allocator, store, source);
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
    var json: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    try result.writeJson(&json);
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

fn compileForAllocationFailureTest(allocator: Allocator) !void {
    var compiled = try compile(allocator, "MATCH (p:Person {name: 'Ada'}) WHERE NOT (p.age > 30 AND p.active = true) RETURN p.name ORDER BY p.age DESC LIMIT 1");
    defer compiled.deinit(allocator);
}

fn executeForAllocationFailureTest(allocator: Allocator, store: storage.Storage) !void {
    var result = try execute(allocator, store, "MATCH (p:Person) RETURN p.name ORDER BY p.name");
    defer result.deinit(allocator);
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

test "compile comma match query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person), (f:Food) RETURN p.name, f.name", snap(@src(),
        \\Plan{%2, %3}
        \\  Project %2: %0.name, %3: %1.name
        \\  Join
        \\    NodeScan (%1:Food)
        \\  Begin
        \\  NodeScan (%0:Person)
    ));
}

test "compile repeated node path query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (a:Person)->[:Knows]->(a) RETURN a", snap(@src(),
        \\Plan{%0}
        \\  Filter (%1 = %0)
        \\  Step (%0)-[:Knows]->(%1)
        \\  NodeScan (%0:Person)
    ));
}

test "compile query cleans up across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileForAllocationFailureTest, .{});
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
    try std.testing.expectEqualStrings("[{\"expr\":300}]", json);
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

test "execute cleans prior result when later statement fails" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    try std.testing.expectError(error.UnknownIdentifier, execForTest(store, "RETURN 'ok'; RETURN missing"));
}

test "execute can use different result and transaction allocators" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const base_store = try tmp.store("test.db");
    defer base_store.db.close();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const store = storage.Storage{
        .db = base_store.db,
        .allocator = arena.allocator(),
        .io = std.testing.io,
    };

    {
        var result = try execute(std.testing.allocator, store, "INSERT (:Person {name: 'Ada'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execute(std.testing.allocator, store, "MATCH (p:Person) RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].scalar.string);
    }
}

test "execution pulls rows without materializing result set" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'})");
        defer result.deinit(std.testing.allocator);
    }

    var execution = try Execution.init(std.testing.allocator, store, "MATCH (p:Person) RETURN p.name ORDER BY p.name");
    defer execution.deinit();

    {
        var cursor = (try execution.nextStatement()).?;
        defer cursor.deinit();
        try std.testing.expectEqual(StatementResultKind.rows, cursor.kind());
        try std.testing.expectEqual(@as(usize, 1), cursor.columns().len);
        try std.testing.expectEqualStrings("p.name", cursor.columns()[0].name);
        try std.testing.expectError(error.WrongResultKind, cursor.finishMutation());

        {
            var row = (try cursor.nextRow()).?;
            defer row.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Ada", row.values[0].scalar.string);
        }
        {
            var row = (try cursor.nextRow()).?;
            defer row.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Bert", row.values[0].scalar.string);
        }
        try std.testing.expect((try cursor.nextRow()) == null);
    }
    try std.testing.expect((try execution.nextStatement()) == null);
    try execution.commit();
}

test "execution pulls mutation count" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'})");
        defer result.deinit(std.testing.allocator);
    }

    var execution = try Execution.init(std.testing.allocator, store, "MATCH (p:Person) FINISH");
    defer execution.deinit();

    {
        var cursor = (try execution.nextStatement()).?;
        defer cursor.deinit();
        try std.testing.expectEqual(StatementResultKind.mutation, cursor.kind());
        try std.testing.expectEqual(@as(usize, 0), cursor.columns().len);
        try std.testing.expectError(error.WrongResultKind, cursor.nextRow());
        try std.testing.expectEqual(@as(usize, 2), try cursor.finishMutation());
        try std.testing.expectEqual(@as(usize, 2), try cursor.finishMutation());
    }
    try std.testing.expect((try execution.nextStatement()) == null);
    try execution.commit();
}

test "execute materializes pulled rows with allocation failure cleanup" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'})");
        defer result.deinit(std.testing.allocator);
    }

    try std.testing.checkAllAllocationFailures(std.testing.allocator, executeForAllocationFailureTest, .{store});
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
        try std.testing.expectEqual(@as(?usize, 2), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (a:User {name: 'Eric'})->[:Likes]->(f:Food) RETURN f.name, f.calories");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    }
}

test "delete counts actual removed graph elements" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:User {name: 'Eric'}),
            \\       (:Food {name: 'Pizza'})
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 2), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (a:User {name: 'Eric'}), (f:Food {name: 'Pizza'}) INSERT (a)-[:Likes]->(f)");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (a:User)-[e:Likes]->(f:Food) DELETE e, e");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
}

test "match comma patterns produce cross product" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada'}),
            \\       (:Person {name: 'Bert'}),
            \\       (:Food {name: 'Pizza'}),
            \\       (:Food {name: 'Salad'}),
            \\       (:Food {name: 'Soup'})
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 5), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person), (f:Food) RETURN p.name, f.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 6), result.rows.len);
    }
}

test "match path can reuse a node variable" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada'}),
            \\       (:Person {name: 'Bob'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}) INSERT (a)-[:Knows]->(a)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}), (b:Person {name: 'Bob'}) INSERT (a)-[:Knows]->(b)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'})->[:Knows]->(a) RETURN a.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].scalar.string);
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

test "delete rejects unknown variables" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    try std.testing.expectError(error.UnknownIdentifier, execForTest(store, "MATCH (p:Person) DELETE missing"));
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
