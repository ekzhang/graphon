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

pub const Error = planner.Error || runtime.Error || error{
    MissingParameter,
};

pub const ResultSet = runtime.ResultSet;
pub const Row = runtime.Row;
pub const ResultValue = runtime.ResultValue;
pub const StatementCursor = runtime.StatementCursor;
pub const StatementResultKind = runtime.StatementResultKind;
pub const ParameterMap = std.array_hash_map.String(types.Value);

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
/// returns. For streaming use cases, call `StatementCursor.init` directly over
/// `program.statements()` instead of collecting a full `ResultSet`.
pub fn execute(gpa: Allocator, txn: storage.Transaction, program: *const CompiledProgram) Error!ResultSet {
    const empty_parameters: ParameterMap = .empty;
    return executeWithParams(gpa, txn, program, empty_parameters);
}

pub fn executeWithParams(
    gpa: Allocator,
    txn: storage.Transaction,
    program: *const CompiledProgram,
    parameter_map: ParameterMap,
) Error!ResultSet {
    const parameters = try bindParameters(gpa, program, parameter_map);
    defer deinitParameterValues(gpa, parameters);

    const statements = try program.statements();
    var result = ResultSet{ .rows_affected = 0 };
    errdefer result.deinit(gpa);

    for (statements) |*statement| {
        var cursor = try StatementCursor.initWithParams(gpa, txn, statement, parameters);
        const next_result = blk: {
            defer cursor.deinit();
            break :blk try cursor.collect();
        };
        result.deinit(gpa);
        result = next_result;
    }

    return result;
}

pub fn deinitParameterMap(allocator: Allocator, map: *ParameterMap) void {
    for (map.values()) |*value| value.deinit(allocator);
    for (map.keys()) |key| allocator.free(key);
    map.deinit(allocator);
    map.* = .empty;
}

fn bindParameters(
    gpa: Allocator,
    program: *const CompiledProgram,
    parameter_map: ParameterMap,
) Error![]types.Value {
    const values = try gpa.alloc(types.Value, program.parameters.len);
    for (values) |*value| value.* = .null;
    errdefer deinitParameterValues(gpa, values);

    for (program.parameters, values) |name, *value| {
        const provided = parameter_map.get(name) orelse return error.MissingParameter;
        value.* = try provided.dupe(gpa);
    }

    return values;
}

fn deinitParameterValues(allocator: Allocator, values: []types.Value) void {
    for (values) |*value| value.deinit(allocator);
    allocator.free(values);
}

comptime { // Trigger tests to run for this module.
    _ = @import("query_test.zig");
}
