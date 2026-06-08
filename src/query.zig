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

pub const Error = planner.Error || runtime.Error;

pub const ResultSet = runtime.ResultSet;
pub const Row = runtime.Row;
pub const ResultValue = runtime.ResultValue;
pub const StatementCursor = runtime.StatementCursor;
pub const StatementResultKind = runtime.StatementResultKind;

pub const CompiledProgram = planner.CompiledProgram;
pub const CompiledStatement = planner.CompiledStatement;
pub const CompiledResult = planner.CompiledResult;
pub const ResultColumn = planner.ResultColumn;

/// Parse and lower a query source into a prepared program.
///
/// Allocator split:
/// * `gpa` owns query-level data: parsed/compiled program state and any rows or
///   result objects that escape execution.
/// * `txn.allocator`, when executing, owns storage-decoded graph objects and
///   executor scratch state while a statement is being pulled.
pub fn prepare(gpa: Allocator, source: [:0]const u8) Error!CompiledProgram {
    return try planner.compile(gpa, source);
}

/// Execute a prepared program inside a caller-owned transaction.
///
/// The caller owns transaction lifetime and must commit or roll back after this
/// returns. For streaming use cases, call `StatementCursor.init` directly for
/// each `program.statements` entry instead of collecting a full `ResultSet`.
pub fn execute(gpa: Allocator, txn: storage.Transaction, program: *const CompiledProgram) Error!ResultSet {
    var result = ResultSet{ .rows_affected = 0 };
    errdefer result.deinit(gpa);

    for (program.statements) |*statement| {
        var cursor = try StatementCursor.init(gpa, txn, statement);
        const next_result = blk: {
            defer cursor.deinit();
            break :blk try cursor.collect();
        };
        result.deinit(gpa);
        result = next_result;
    }

    return result;
}

comptime { // Trigger tests to run for this module.
    _ = @import("query_test.zig");
}
