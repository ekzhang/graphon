const std = @import("std");

const query = @import("query.zig");
const storage = @import("storage.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const ResultSet = query.ResultSet;
const StatementCursor = query.StatementCursor;
const StatementResultKind = query.StatementResultKind;
const Value = types.Value;

const execute = query.execute;
const prepare = query.prepare;

const Snap = @import("vendor/snaptest.zig").Snap;
const snap = Snap.snap;

fn execForTest(store: storage.Storage, source: [:0]const u8) !ResultSet {
    var prepared = try prepare(std.testing.allocator, source);
    defer prepared.deinit(std.testing.allocator);

    const txn = store.txn();
    defer txn.close();
    errdefer txn.rollback() catch {};

    var result = try execute(std.testing.allocator, txn, &prepared);
    errdefer result.deinit(std.testing.allocator);
    try txn.commit();
    return result;
}

fn checkQueryPlanSnapshot(source: [:0]const u8, want: Snap) !void {
    var compiled = try prepare(std.testing.allocator, source);
    defer compiled.deinit(std.testing.allocator);
    const statements = try compiled.statements();
    try std.testing.expectEqual(@as(usize, 1), statements.len);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try statements[0].plan.print(&out.writer);
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
        if (row.values[column] != .value) continue;
        const value = row.values[column].value;
        if (value != .string) continue;
        if (std.mem.eql(u8, value.string, expected)) return true;
    }
    return false;
}

fn resultContainsStringInt(result: ResultSet, string_column: usize, expected_string: []const u8, int_column: usize, expected_int: i64) bool {
    for (result.rows) |row| {
        if (row.values[string_column] != .value) continue;
        const string_value = row.values[string_column].value;
        if (string_value != .string) continue;
        if (!std.mem.eql(u8, string_value.string, expected_string)) continue;

        if (row.values[int_column] != .value) continue;
        const int_value = row.values[int_column].value;
        if (int_value != .int64) continue;
        if (int_value.int64 == expected_int) return true;
    }
    return false;
}

fn prepareForAllocationFailureTest(allocator: Allocator) !void {
    var compiled = try prepare(allocator, "MATCH (p:Person {name: 'Ada'}) WHERE NOT (p.age > 30 AND p.active = true) RETURN p.name ORDER BY p.age DESC LIMIT 1");
    defer compiled.deinit(allocator);
}

fn executeForAllocationFailureTest(allocator: Allocator, store: storage.Storage) !void {
    var prepared = try prepare(allocator, "MATCH (p:Person) RETURN p.name ORDER BY p.name");
    defer prepared.deinit(allocator);

    const txn = store.txn();
    defer txn.close();
    defer txn.rollback() catch {};

    var result = try execute(allocator, txn, &prepared);
    defer result.deinit(allocator);
}

test "compile match return query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) WHERE p.age > 30 RETURN p.name ORDER BY p.age DESC LIMIT 2", snap(@src(),
        \\Plan{%1}
        \\  Top 2 %2 desc
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
        \\  StepBetween (%0)-[:Knows]->(%0)
        \\  NodeScan (%0:Person)
    ));
}

test "compile repeated node path with edge filters query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (a:Person)-[e:Knows {since: 2024}]->(a) RETURN e", snap(@src(),
        \\Plan{%1}
        \\  Filter (%1.since = 2024)
        \\  StepBetween (%0)-[%1:Knows]->(%0)
        \\  NodeScan (%0:Person)
    ));
}

test "compile bound endpoint path query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (a:Person), (b:Person), (a)-[e:Knows]->(b) RETURN a, b, e", snap(@src(),
        \\Plan{%0, %1, %2}
        \\  StepBetween (%0)-[%2:Knows]->(%1)
        \\  Join
        \\    NodeScan (%1:Person)
        \\  Begin
        \\  NodeScan (%0:Person)
    ));
}

test "compile match trail query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH TRAIL (a:Person {name: 'Ada'})-[:Follows]->{1,3}(b:Person) RETURN b.name", snap(@src(),
        \\Plan{%5}
        \\  Project %5: %1.name
        \\  Filter %1: Person
        \\  Repeat trail %0 -> %1 (%2 -> %3){1, 3}
        \\    Step (%2)-[%4:Follows]->(%3)
        \\    Argument %2
        \\  Begin
        \\  Filter (%0.name = 'Ada')
        \\  NodeScan (%0:Person)
    ));
}

test "compile match trail with repeated subplan filters snapshot" {
    try checkQueryPlanSnapshot("MATCH TRAIL (a:Person)-[rels:Follows {since: 2024}]->{1,2}(b:Person {name: 'Cara'}) RETURN rels, b", snap(@src(),
        \\Plan{%5, %1}
        \\  Filter (%1.name = 'Cara')
        \\  Filter %1: Person
        \\  Repeat trail %0 -> %1 (%2 -> %3){1, 2} collect %5 <- %4
        \\    Filter (%4.since = 2024)
        \\    Step (%2)-[%4:Follows]->(%3)
        \\    Argument %2
        \\  Begin
        \\  NodeScan (%0:Person)
    ));
}

test "compile quantified edge chain query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (c1:Comment)<-[:replyOf]-{1,3}(m)-[:replyOf]->{1,3}(c2:Comment) RETURN m, c2", snap(@src(),
        \\Plan{%1, %4}
        \\  Filter %4: Comment
        \\  Repeat walk %1 -> %4 (%5 -> %6){1, 3}
        \\    Step (%5)-[:replyOf]->(%6)
        \\    Argument %5
        \\  Begin
        \\  Repeat walk %0 -> %1 (%2 -> %3){1, 3}
        \\    Step (%2)<-[:replyOf]-(%3)
        \\    Argument %2
        \\  Begin
        \\  NodeScan (%0:Comment)
    ));
}

test "compile right-bound path query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (b:Person), (a:Person)-[:Knows]->(b) RETURN a, b", snap(@src(),
        \\Plan{%1, %0}
        \\  Filter %1: Person
        \\  Step (%0)<-[:Knows]-(%1)
        \\  NodeScan (%0:Person)
    ));
}

test "compile optional bound endpoint path query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (a:Person), (b:Person) OPTIONAL MATCH (a)-[e:Knows]->(b) RETURN e", snap(@src(),
        \\Plan{%2}
        \\  OptionalJoin
        \\    StepBetween (%0)-[%2:Knows]->(%1)
        \\  Begin
        \\  Join
        \\    NodeScan (%1:Person)
        \\  Begin
        \\  NodeScan (%0:Person)
    ));
}

test "compile negative path predicate query plan snapshot" {
    try checkQueryPlanSnapshot(
        \\MATCH
        \\  (me:Person {name: 'me'})-[:WORKS_IN]->(location),
        \\  (other:Person)-[:WORKS_IN]->(location)
        \\WHERE NOT (me)-[:FRIENDS_WITH]->(other)
        \\RETURN other.name
    , snap(@src(),
        \\Plan{%3}
        \\  Project %3: %2.name
        \\  Join
        \\    Anti
        \\    StepBetween (%0)-[:FRIENDS_WITH]->(%2)
        \\  Begin
        \\  Filter %2: Person
        \\  Step (%1)<-[:WORKS_IN]-(%2)
        \\  Step (%0)-[:WORKS_IN]->(%1)
        \\  Filter (%0.name = 'me')
        \\  NodeScan (%0:Person)
    ));
}

test "compile middle-bound path query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (location:Place), (left:Person)-[:LIVES_IN]->(location)<-[:WORKS_IN]-(right:Person) RETURN left.name, right.name", snap(@src(),
        \\Plan{%3, %4}
        \\  Project %3: %1.name, %4: %2.name
        \\  Filter %2: Person
        \\  Step (%0)<-[:WORKS_IN]-(%2)
        \\  Filter %1: Person
        \\  Step (%0)<-[:LIVES_IN]-(%1)
        \\  NodeScan (%0:Place)
    ));
}

test "compile edge path predicate query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (a:Person) WHERE -[:Knows]-> RETURN a", snap(@src(),
        \\Plan{%0}
        \\  SemiJoin
        \\    Step (%1)-[:Knows]->(%2)
        \\    NodeScan (%1)
        \\  Begin
        \\  NodeScan (%0:Person)
    ));
}

test "compile edge-only match query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH -[]- RETURN COUNT(*)", snap(@src(),
        \\Plan{%2}
        \\  OrderedAggregate %2: count(*)
        \\  Step (%0)-[]-(%1)
        \\  NodeScan (%0)
    ));
}

test "compile return distinct query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) RETURN DISTINCT p.name", snap(@src(),
        \\Plan{%1}
        \\  Distinct %1
        \\  Project %1: %0.name
        \\  NodeScan (%0:Person)
    ));
}

test "compile order by return alias query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) RETURN p.name AS name ORDER BY name DESC LIMIT 1", snap(@src(),
        \\Plan{%1}
        \\  Top 1 %1 desc
        \\  Project %1: %0.name
        \\  NodeScan (%0:Person)
    ));
}

test "compile order by skip limit does not use top snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) RETURN p.name ORDER BY p.name SKIP 1 LIMIT 1", snap(@src(),
        \\Plan{%1}
        \\  Limit 1
        \\  Skip 1
        \\  Sort %2 asc
        \\  Project %2: %0.name
        \\  Project %1: %0.name
        \\  NodeScan (%0:Person)
    ));
}

test "compile multi-key top query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) RETURN p.name, p.team ORDER BY p.team, p.name DESC LIMIT 3", snap(@src(),
        \\Plan{%1, %2}
        \\  Top 3 %3 asc, %4 desc
        \\  Project %3: %0.team, %4: %0.name
        \\  Project %1: %0.name, %2: %0.team
        \\  NodeScan (%0:Person)
    ));
}

test "compile with optional match query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) WITH DISTINCT p OPTIONAL MATCH (p)-[:Likes]->(f:Food) RETURN p.name, f.name", snap(@src(),
        \\Plan{%2, %3}
        \\  Project %2: %0.name, %3: %1.name
        \\  OptionalJoin
        \\    Filter %1: Food
        \\    Step (%0)-[:Likes]->(%1)
        \\  Begin
        \\  Distinct %0
        \\  NodeScan (%0:Person)
    ));
}

test "compile with aggregate query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) OPTIONAL MATCH (p)-[:Likes]->(f:Food) WITH p, COUNT(f) AS likes RETURN p.name, likes", snap(@src(),
        \\Plan{%3, %2}
        \\  Project %3: %0.name
        \\  Aggregate %2: count(%1) BY %0
        \\  OptionalJoin
        \\    Filter %1: Food
        \\    Step (%0)-[:Likes]->(%1)
        \\  Begin
        \\  NodeScan (%0:Person)
    ));
}

test "compile return aggregate query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) RETURN p.name AS name, COUNT(*) AS total ORDER BY name", snap(@src(),
        \\Plan{%1, %2}
        \\  Sort %1 asc
        \\  Aggregate %2: count(*) BY %1
        \\  Project %1: %0.name
        \\  NodeScan (%0:Person)
    ));
}

test "compile numeric aggregate query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) RETURN p.team AS team, COUNT(DISTINCT p.age) AS ages, SUM(p.score) AS total, AVG(p.score) AS avg, MIN(p.name) AS first, MAX(p.score) AS max ORDER BY team", snap(@src(),
        \\Plan{%1, %2, %3, %4, %5, %6}
        \\  Sort %1 asc
        \\  Aggregate %2: count(distinct %0.age), %3: sum(%0.score), %4: avg(%0.score), %5: min(%0.name), %6: max(%0.score) BY %1
        \\  Project %1: %0.team
        \\  NodeScan (%0:Person)
    ));
}

test "compile aggregate expression query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) RETURN COUNT(p) + 1 AS adjusted", snap(@src(),
        \\Plan{%2}
        \\  Project %2: (%1 + 1)
        \\  OrderedAggregate %1: count(%0)
        \\  NodeScan (%0:Person)
    ));
}

test "compile ordered aggregate after sorted with query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) WITH p.team AS team ORDER BY team RETURN team, COUNT(*) AS people", snap(@src(),
        \\Plan{%1, %2}
        \\  OrderedAggregate %2: count(*) BY %1
        \\  Sort %1 asc
        \\  Project %1: %0.team
        \\  NodeScan (%0:Person)
    ));
}

test "compile union all query plan snapshot" {
    try checkQueryPlanSnapshot("RETURN 1 AS n UNION ALL RETURN 2 AS n", snap(@src(),
        \\Plan{%0}
        \\  UnionAll
        \\    Project %0: %1
        \\    Project %1: 2
        \\  Begin
        \\  Project %0: 1
    ));
}

test "compile union query plan snapshot" {
    try checkQueryPlanSnapshot("RETURN 1 AS n UNION RETURN 1 AS n", snap(@src(),
        \\Plan{%0}
        \\  Distinct %0
        \\  UnionAll
        \\    Project %0: %1
        \\    Project %1: 1
        \\  Begin
        \\  Project %0: 1
    ));
}

test "prepare query cleans up across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareForAllocationFailureTest, .{});
}

test "compile match set query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person {name: 'Eric'}) SET p.age = 23", snap(@src(),
        \\Plan{}
        \\  Update %0.age = 23
        \\  Filter (%0.name = 'Eric')
        \\  NodeScan (%0:Person)
    ));
}

test "compile match set label query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) SET p:Employee", snap(@src(),
        \\Plan{}
        \\  Update add %0:Employee
        \\  NodeScan (%0:Person)
    ));
}

test "compile match remove label query plan snapshot" {
    try checkQueryPlanSnapshot("MATCH (p:Person) REMOVE p:Employee", snap(@src(),
        \\Plan{}
        \\  Update remove %0:Employee
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
    try std.testing.expectEqual(Value{ .int64 = 300 }, result.rows[0].values[0].value);

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

test "union all keeps duplicate rows" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "RETURN 1 AS n UNION ALL RETURN 1 AS n");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqualStrings("n", result.columns[0]);
    try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[0].values[0].value);
    try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[1].values[0].value);
}

test "union removes duplicate rows" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "RETURN 1 AS n UNION RETURN 1 AS n");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("n", result.columns[0]);
    try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[0].values[0].value);
}

test "union rejects mismatched result column counts" {
    try std.testing.expectError(error.Unsupported, prepare(std.testing.allocator, "RETURN 1 UNION RETURN 1, 2"));
}

test "prepare carries parser diagnostics" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var prepared = try prepare(std.testing.allocator, "RETURN 1 LIMIT 2.5");
    defer prepared.deinit(std.testing.allocator);

    switch (prepared.value) {
        .parse_errors => |errors| {
            try std.testing.expectEqual(@as(usize, 1), errors.errors.len);
            try std.testing.expectEqual(.expected_count, errors.errors[0].tag);
        },
        .statements => try std.testing.expect(false),
    }

    const txn = store.txn();
    defer txn.close();
    defer txn.rollback() catch {};
    try std.testing.expectError(error.InvalidSyntax, execute(std.testing.allocator, txn, &prepared));
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
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'})");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].value.string);
    }
}

test "statement cursor pulls rows without materializing result set" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'})");
        defer result.deinit(std.testing.allocator);
    }

    var prepared = try prepare(std.testing.allocator, "MATCH (p:Person) RETURN p.name ORDER BY p.name");
    defer prepared.deinit(std.testing.allocator);
    const statements = try prepared.statements();
    try std.testing.expectEqual(@as(usize, 1), statements.len);

    const txn = store.txn();
    defer txn.close();
    errdefer txn.rollback() catch {};

    {
        var cursor = try StatementCursor.init(std.testing.allocator, txn, &statements[0]);
        defer cursor.deinit();
        try std.testing.expectEqual(StatementResultKind.rows, cursor.kind());
        try std.testing.expectEqual(@as(usize, 1), cursor.columns().len);
        try std.testing.expectEqualStrings("p.name", cursor.columns()[0].name);
        try std.testing.expectError(error.WrongResultKind, cursor.finishMutation());

        {
            var row = (try cursor.nextRow()).?;
            defer row.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Ada", row.values[0].value.string);
        }
        {
            var row = (try cursor.nextRow()).?;
            defer row.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Bert", row.values[0].value.string);
        }
        try std.testing.expect((try cursor.nextRow()) == null);
    }
    try txn.commit();
}

test "statement cursor pulls mutation count" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'})");
        defer result.deinit(std.testing.allocator);
    }

    var prepared = try prepare(std.testing.allocator, "MATCH (p:Person) FINISH");
    defer prepared.deinit(std.testing.allocator);
    const statements = try prepared.statements();
    try std.testing.expectEqual(@as(usize, 1), statements.len);

    const txn = store.txn();
    defer txn.close();
    errdefer txn.rollback() catch {};

    {
        var cursor = try StatementCursor.init(std.testing.allocator, txn, &statements[0]);
        defer cursor.deinit();
        try std.testing.expectEqual(StatementResultKind.mutation, cursor.kind());
        try std.testing.expectEqual(@as(usize, 0), cursor.columns().len);
        try std.testing.expectError(error.WrongResultKind, cursor.nextRow());
        try std.testing.expectEqual(@as(usize, 2), try cursor.finishMutation());
        try std.testing.expectEqual(@as(usize, 2), try cursor.finishMutation());
    }
    try txn.commit();
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
        try std.testing.expectEqualStrings("Pizza", result.rows[0].values[0].value.string);
        try std.testing.expectEqual(Value{ .int64 = 285 }, result.rows[0].values[1].value);
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
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].value.string);
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
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].value.string);
        try std.testing.expectEqualStrings("Bert", result.rows[1].values[0].value.string);
        try std.testing.expectEqualStrings("Cara", result.rows[2].values[0].value.string);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name ORDER BY p.age DESC LIMIT 2");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);
        try std.testing.expectEqualStrings("Cara", result.rows[0].values[0].value.string);
        try std.testing.expectEqualStrings("Bert", result.rows[1].values[0].value.string);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name ORDER BY p.age DESC SKIP 1 LIMIT 1");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Bert", result.rows[0].values[0].value.string);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN p.name AS name ORDER BY name DESC SKIP 1 LIMIT 1");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Bert", result.rows[0].values[0].value.string);
        try std.testing.expectEqualStrings("name", result.columns[0]);
    }
}

test "match return distinct" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada'}),
            \\       (:Food {name: 'Pizza'}),
            \\       (:Food {name: 'Soup'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Ada'}), (f:Food) INSERT (p)-[:Likes]->(f)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person)-[:Likes]->(f:Food) RETURN DISTINCT p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].value.string);
    }
}

test "with distinct carries scoped bindings" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada'}),
            \\       (:Food {name: 'Pizza'}),
            \\       (:Food {name: 'Soup'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Ada'}), (f:Food) INSERT (p)-[:Likes]->(f)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person)-[:Likes]->(f:Food) WITH DISTINCT p RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].value.string);
    }
}

test "with optional match returns null extended rows" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada'}),
            \\       (:Person {name: 'Bert'}),
            \\       (:Food {name: 'Pizza'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Ada'}), (f:Food {name: 'Pizza'}) INSERT (p)-[:Likes]->(f)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) WITH p, p.name AS name OPTIONAL MATCH (p)-[:Likes]->(f:Food) RETURN name, f.name ORDER BY name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].value.string);
        try std.testing.expectEqualStrings("Pizza", result.rows[0].values[1].value.string);
        try std.testing.expectEqualStrings("Bert", result.rows[1].values[0].value.string);
        try std.testing.expect(result.rows[1].values[1].value == .null);
    }
}

test "with aggregate counts optional matches by group" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada'}),
            \\       (:Person {name: 'Bert'}),
            \\       (:Food {name: 'Pizza'}),
            \\       (:Food {name: 'Soup'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Ada'}), (f:Food) INSERT (p)-[:Likes]->(f)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store,
            \\MATCH (p:Person)
            \\OPTIONAL MATCH (p)-[:Likes]->(f:Food)
            \\WITH p, COUNT(f) AS likes
            \\RETURN p.name AS name, likes
            \\ORDER BY name
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].value.string);
        try std.testing.expectEqual(Value{ .int64 = 2 }, result.rows[0].values[1].value);
        try std.testing.expectEqualStrings("Bert", result.rows[1].values[0].value.string);
        try std.testing.expectEqual(Value{ .int64 = 0 }, result.rows[1].values[1].value);
    }
}

test "return count aggregates matched rows" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bert'})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN COUNT(*) AS people");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("people", result.columns[0]);
        try std.testing.expectEqual(Value{ .int64 = 2 }, result.rows[0].values[0].value);
    }
    {
        var result = try execForTest(store, "MATCH (p:Missing) RETURN COUNT(*) AS people");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqual(Value{ .int64 = 0 }, result.rows[0].values[0].value);
    }
}

test "directionless edge match counts oriented GQL paths" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Node)-[:R]->(:Node)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH -[]- RETURN COUNT(*) AS paths");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqual(Value{ .int64 = 2 }, result.rows[0].values[0].value);
    }
    {
        var result = try execForTest(store, "MATCH -[]-> RETURN COUNT(*) AS paths");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[0].values[0].value);
    }
}

test "match trail returns bounded variable length paths" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bob'}), (:Person {name: 'Cara'}), (:Person {name: 'Dan'})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}), (b:Person {name: 'Bob'}) INSERT (a)-[:Follows]->(b)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (b:Person {name: 'Bob'}), (c:Person {name: 'Cara'}) INSERT (b)-[:Follows]->(c)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}), (d:Person {name: 'Dan'}) INSERT (a)-[:Follows]->(d)");
        defer result.deinit(std.testing.allocator);
    }

    var result = try execForTest(store, "MATCH TRAIL (a:Person {name: 'Ada'})-[:Follows]->{1,2}(b:Person) RETURN b.name ORDER BY b.name");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
    try std.testing.expectEqualStrings("Bob", result.rows[0].values[0].value.string);
    try std.testing.expectEqualStrings("Cara", result.rows[1].values[0].value.string);
    try std.testing.expectEqualStrings("Dan", result.rows[2].values[0].value.string);
}

test "match quantified edge returns repeated edge bindings" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bob'}), (:Person {name: 'Cara'})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}), (b:Person {name: 'Bob'}) INSERT (a)-[:Follows]->(b)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (b:Person {name: 'Bob'}), (c:Person {name: 'Cara'}) INSERT (b)-[:Follows]->(c)");
        defer result.deinit(std.testing.allocator);
    }

    var result = try execForTest(store, "MATCH TRAIL (a:Person {name: 'Ada'})-[e:Follows]->{2,2}(b:Person) RETURN b.name, e");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("Cara", result.rows[0].values[0].value.string);
    try std.testing.expectEqual(@as(usize, 2), result.rows[0].values[1].value.list.len);
    try std.testing.expect(result.rows[0].values[1].value.list[0] == .edge_ref);
    try std.testing.expect(result.rows[0].values[1].value.list[1] == .edge_ref);

    var indexed = try execForTest(store, "MATCH TRAIL (a:Person {name: 'Ada'})-[e:Follows]->{2,2}(b:Person) WITH e, 1 AS i RETURN e[0] AS first, e[i] AS second, e[2] AS missing");
    defer indexed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), indexed.rows.len);
    try std.testing.expect(indexed.rows[0].values[0].value == .edge_ref);
    try std.testing.expect(indexed.rows[0].values[1].value == .edge_ref);
    try std.testing.expect(!indexed.rows[0].values[0].value.eql(indexed.rows[0].values[1].value));
    try std.testing.expect(indexed.rows[0].values[2].value == .null);
}

test "complex trail query with optional aggregate executes" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada'}),
            \\       (:Person {name: 'Bert'}),
            \\       (:Person {name: 'Cara'}),
            \\       (:Post {title: 'Runtime Tips', likes_count: 120, creation_date: '2024-02-01'}),
            \\       (:Post {title: 'Planner Notes', likes_count: 170, creation_date: '2024-02-10'}),
            \\       (:Post {title: 'Extra Fresh', likes_count: 10, creation_date: '2024-03-01'}),
            \\       (:Post {title: 'Old Notes', likes_count: 80, creation_date: '2023-12-01'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}), (b:Person {name: 'Bert'}) INSERT (a)-[:Follows]->(b)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (b:Person {name: 'Bert'}), (c:Person {name: 'Cara'}) INSERT (b)-[:Follows]->(c)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (b:Person {name: 'Bert'}), (p:Post {title: 'Runtime Tips'}) INSERT (b)-[:Created]->(p)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (c:Person {name: 'Cara'}), (p:Post {title: 'Planner Notes'}) INSERT (c)-[:Created]->(p)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (c:Person {name: 'Cara'}), (p:Post {title: 'Extra Fresh'}) INSERT (c)-[:Created]->(p)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (c:Person {name: 'Cara'}), (p:Post {title: 'Old Notes'}) INSERT (c)-[:Created]->(p)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}), (p:Post {title: 'Runtime Tips'}) INSERT (a)-[:Likes]->(p)");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}), (p:Post {title: 'Planner Notes'}) INSERT (a)-[:Likes]->(p)");
        defer result.deinit(std.testing.allocator);
    }

    var result = try execForTest(store,
        \\MATCH TRAIL (follower:Person)-[follows:Follows]->{1,3}(influencer:Person),
        \\            (influencer)-[:Created]->(post:Post),
        \\            (follower)-[:Likes]->(post)
        \\WHERE post.likes_count > 100
        \\OPTIONAL MATCH (influencer)-[:Created]->(otherPost:Post)
        \\         WHERE otherPost.creation_date > '2024-01-01'
        \\WITH follower, influencer, post, follows, COUNT(otherPost) AS recentPosts
        \\RETURN DISTINCT follower.name AS FollowerName,
        \\                influencer.name AS InfluencerName,
        \\                post.title AS PopularPost,
        \\                recentPosts AS RecentPostCount,
        \\                follows AS FollowerTrail
        \\ORDER BY RecentPostCount DESC, InfluencerName
        \\LIMIT 10;
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqualStrings("FollowerName", result.columns[0]);
    try std.testing.expectEqualStrings("InfluencerName", result.columns[1]);
    try std.testing.expectEqualStrings("PopularPost", result.columns[2]);
    try std.testing.expectEqualStrings("RecentPostCount", result.columns[3]);
    try std.testing.expectEqualStrings("FollowerTrail", result.columns[4]);

    try std.testing.expectEqualStrings("Ada", result.rows[0].values[0].value.string);
    try std.testing.expectEqualStrings("Cara", result.rows[0].values[1].value.string);
    try std.testing.expectEqualStrings("Planner Notes", result.rows[0].values[2].value.string);
    try std.testing.expectEqual(Value{ .int64 = 2 }, result.rows[0].values[3].value);
    try std.testing.expectEqual(@as(usize, 2), result.rows[0].values[4].value.list.len);

    try std.testing.expectEqualStrings("Ada", result.rows[1].values[0].value.string);
    try std.testing.expectEqualStrings("Bert", result.rows[1].values[1].value.string);
    try std.testing.expectEqualStrings("Runtime Tips", result.rows[1].values[2].value.string);
    try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[1].values[3].value);
    try std.testing.expectEqual(@as(usize, 1), result.rows[1].values[4].value.list.len);
}

test "match trail does not repeat an edge" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Ada'}), (:Person {name: 'Bob'})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Ada'}), (b:Person {name: 'Bob'}) INSERT (a)~[:Knows]~(b)");
        defer result.deinit(std.testing.allocator);
    }

    var result = try execForTest(store, "MATCH TRAIL (a:Person {name: 'Ada'})~[:Knows]~{2,2}(b:Person) RETURN b.name");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
}

test "return numeric aggregates by group" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'Ada', team: 'A', age: 30, score: 10}),
            \\       (:Person {name: 'Amy', team: 'A', age: 30, score: 20}),
            \\       (:Person {name: 'Bert', team: 'B', age: 41, score: 7})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store,
            \\MATCH (p:Person)
            \\RETURN p.team AS team,
            \\       COUNT(*) AS people,
            \\       COUNT(DISTINCT p.age) AS ages,
            \\       SUM(p.score) AS total,
            \\       AVG(p.score) AS avg,
            \\       MIN(p.name) AS first,
            \\       MAX(p.score) AS max_score
            \\ORDER BY team
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);

        try std.testing.expectEqualStrings("A", result.rows[0].values[0].value.string);
        try std.testing.expectEqual(Value{ .int64 = 2 }, result.rows[0].values[1].value);
        try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[0].values[2].value);
        try std.testing.expectEqual(Value{ .int64 = 30 }, result.rows[0].values[3].value);
        try std.testing.expectEqual(Value{ .float64 = 15.0 }, result.rows[0].values[4].value);
        try std.testing.expectEqualStrings("Ada", result.rows[0].values[5].value.string);
        try std.testing.expectEqual(Value{ .int64 = 20 }, result.rows[0].values[6].value);

        try std.testing.expectEqualStrings("B", result.rows[1].values[0].value.string);
        try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[1].values[1].value);
        try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[1].values[2].value);
        try std.testing.expectEqual(Value{ .int64 = 7 }, result.rows[1].values[3].value);
        try std.testing.expectEqual(Value{ .float64 = 7.0 }, result.rows[1].values[4].value);
        try std.testing.expectEqualStrings("Bert", result.rows[1].values[5].value.string);
        try std.testing.expectEqual(Value{ .int64 = 7 }, result.rows[1].values[6].value);
    }
}

test "ordered aggregate groups sorted with input" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {team: 'B'}),
            \\       (:Person {team: 'A'}),
            \\       (:Person {team: 'A'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store,
            \\MATCH (p:Person)
            \\WITH p.team AS team ORDER BY team
            \\RETURN team, COUNT(*) AS people
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), result.rows.len);
        try std.testing.expectEqualStrings("A", result.rows[0].values[0].value.string);
        try std.testing.expectEqual(Value{ .int64 = 2 }, result.rows[0].values[1].value);
        try std.testing.expectEqualStrings("B", result.rows[1].values[0].value.string);
        try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[1].values[1].value);
    }
}

test "union can combine aggregate branch results with grouping" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {team: 'A'}),
            \\       (:Person {team: 'A'}),
            \\       (:Person {team: 'B'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store,
            \\MATCH (p:Person)
            \\RETURN p.team AS team, COUNT(*) AS people
            \\UNION ALL
            \\RETURN 'all' AS team, 0 AS people
        );
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 3), result.rows.len);
        try std.testing.expect(resultContainsStringInt(result, 0, "A", 1, 2));
        try std.testing.expect(resultContainsStringInt(result, 0, "B", 1, 1));
        try std.testing.expect(resultContainsStringInt(result, 0, "all", 1, 0));
    }
}

test "numeric distinct aggregates skip duplicate values" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {age: 30}),
            \\       (:Person {age: 30}),
            \\       (:Person {age: 41})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) RETURN SUM(DISTINCT p.age) AS total, AVG(DISTINCT p.age) AS avg");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqual(Value{ .int64 = 71 }, result.rows[0].values[0].value);
        try std.testing.expectEqual(Value{ .float64 = 35.5 }, result.rows[0].values[1].value);
    }
}

test "empty aggregates return null except count" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    var result = try execForTest(store, "MATCH (p:Missing) RETURN COUNT(p) AS n, SUM(p.score) AS total, AVG(p.score) AS avg, MIN(p.name) AS first, MAX(p.score) AS max_score");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(Value{ .int64 = 0 }, result.rows[0].values[0].value);
    try std.testing.expect(result.rows[0].values[1].value == .null);
    try std.testing.expect(result.rows[0].values[2].value == .null);
    try std.testing.expect(result.rows[0].values[3].value == .null);
    try std.testing.expect(result.rows[0].values[4].value == .null);
}

test "aggregate expressions execute after aggregation" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {score: 10}), (:Person {score: 20})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store,
            \\MATCH (p:Person)
            \\RETURN COUNT(*) + 1 AS adjusted,
            \\       MAX(p.score) - MIN(p.score) AS spread,
            \\       SUM(p.score) + COUNT(*) AS totalish
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqual(Value{ .int64 = 3 }, result.rows[0].values[0].value);
        try std.testing.expectEqual(Value{ .int64 = 10 }, result.rows[0].values[1].value);
        try std.testing.expectEqual(Value{ .int64 = 32 }, result.rows[0].values[2].value);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person) WITH COUNT(*) + 1 AS adjusted RETURN adjusted");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(Value{ .int64 = 3 }, result.rows[0].values[0].value);
    }
}

test "aggregate expressions reject row values outside aggregate calls" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    try std.testing.expectError(error.Unsupported, execForTest(store, "MATCH (p:Person) RETURN COUNT(*) + p.score AS bad"));
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
        try std.testing.expectEqualStrings("Cara", result.rows[0].values[0].value.string);
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
        try std.testing.expectEqual(@as(usize, 1), node.labels.count());
        try std.testing.expect(node.labels.contains("Person"));
        try std.testing.expectEqual(@as(usize, 2), node.properties.count());

        const json = try jsonForTest(result);
        defer std.testing.allocator.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"labels\":[\"Person\"]") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Alice\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"age\":30") != null);
    }
}

test "returning an edge includes labels endpoints and properties" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Alice'})-[:Knows {since: 2024}]->(:Person {name: 'Bob'})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (a:Person {name: 'Alice'})-[e:Knows]->(b:Person {name: 'Bob'}) RETURN e");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        const edge = result.rows[0].values[0].edge;
        try std.testing.expect(edge.directed);
        try std.testing.expectEqual(@as(usize, 1), edge.labels.count());
        try std.testing.expect(edge.labels.contains("Knows"));
        try std.testing.expectEqual(@as(usize, 1), edge.properties.count());
        try std.testing.expectEqual(Value{ .int64 = 2024 }, edge.properties.get("since").?);

        const json = try jsonForTest(result);
        defer std.testing.allocator.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"labels\":[\"Knows\"]") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"start\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"end\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"since\":2024") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"directed\":true") != null);
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
        try std.testing.expectEqual(Value{ .int64 = 23 }, result.rows[0].values[0].value);
    }
}

test "set and remove update node labels" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store, "INSERT (:Person {name: 'Eric'})");
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Eric'}) SET p:Employee");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Eric'}) SET p:Employee");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 0), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Employee) RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        try std.testing.expectEqualStrings("Eric", result.rows[0].values[0].value.string);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Eric'}) REMOVE p:Employee");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Person {name: 'Eric'}) REMOVE p:Employee");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 0), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH (p:Employee) RETURN p.name");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    }
}

test "set and remove update edge labels" {
    var tmp = @import("test_helpers.zig").tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();

    {
        var result = try execForTest(store,
            \\INSERT (:Person {name: 'A'})-[:Knows]->(:Person {name: 'B'})
        );
        defer result.deinit(std.testing.allocator);
    }
    {
        var result = try execForTest(store,
            \\MATCH (:Person {name: 'A'})-[e:Knows]->(:Person {name: 'B'})
            \\SET e:Recent
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH ()-[e:Recent]->() RETURN COUNT(e)");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(Value{ .int64 = 1 }, result.rows[0].values[0].value);
    }
    {
        var result = try execForTest(store, "MATCH ()-[e:Recent]->() REMOVE e:Recent");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?usize, 1), result.rows_affected);
    }
    {
        var result = try execForTest(store, "MATCH ()-[e:Recent]->() RETURN COUNT(e)");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(Value{ .int64 = 0 }, result.rows[0].values[0].value);
    }
}
