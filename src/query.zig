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
