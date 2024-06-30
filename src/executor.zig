//! Execute query plans against a storage engine.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Plan = @import("Plan.zig");
const types = @import("types.zig");
const Value = types.Value;

/// Execution state attached to a query plan operator while it is running.
const OperatorState = union(std.meta.Tag(Plan.Operator)) {
    node_scan,
    rel_scan,
    step,
    begin,
    repeat,
    join,
    semi_join,
    argument,
    anti,
    project,
    empty_result,
    filter,
    limit,
    distinct,
    skip,
    sort,
    top,
    union_all,
    insert_node,
    insert_edge,
};

comptime {
    _ = OperatorState.node_scan;
}
