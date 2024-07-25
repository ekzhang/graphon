//! Execute query plan operators that modify graph data: nodes and edges.

const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const Plan = @import("../Plan.zig");
const types = @import("../types.zig");

pub fn runInsertNode(op: Plan.InsertNode, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;

    var node = types.Node{ .id = types.ElementId.generate() };
    defer node.deinit(exec.txn.allocator);

    for (op.labels.items) |label| {
        try node.labels.put(exec.txn.allocator, label, void{});
    }
    node.properties = try evaluateProperties(op.properties, exec.assignments, exec.txn.allocator);

    try exec.txn.putNode(node);
    if (op.ident) |ident| {
        exec.assignments[ident] = .{ .node_ref = node.id };
    }
    return true;
}

pub fn runInsertEdge(op: Plan.InsertEdge, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;

    const src_id = switch (exec.assignments[op.ident_src]) {
        .node_ref => |n| n,
        else => return executor.Error.WrongType,
    };
    const dest_id = switch (exec.assignments[op.ident_dest]) {
        .node_ref => |n| n,
        else => return executor.Error.WrongType,
    };

    var edge = types.Edge{
        .id = types.ElementId.generate(),
        .endpoints = .{ src_id, dest_id },
        .directed = op.directed,
    };
    defer edge.deinit(exec.txn.allocator);

    for (op.labels.items) |label| {
        try edge.labels.put(exec.txn.allocator, label, void{});
    }
    edge.properties = try evaluateProperties(op.properties, exec.assignments, exec.txn.allocator);

    try exec.txn.putEdge(edge);
    if (op.ident) |ident| {
        exec.assignments[ident] = .{ .edge_ref = edge.id };
    }
    return true;
}

/// Evaluate property expressions in a query plan.
fn evaluateProperties(
    properties: Plan.Properties,
    assignments: []const types.Value,
    allocator: Allocator,
) Allocator.Error!std.StringArrayHashMapUnmanaged(types.Value) {
    var ret: std.StringArrayHashMapUnmanaged(types.Value) = .{};
    errdefer types.freeProperties(allocator, &ret);
    for (properties.items(.key), properties.items(.value)) |k, v| {
        const key = try allocator.dupe(u8, k);
        errdefer allocator.free(key);
        var value = try executor.evaluate(v, assignments, allocator);
        errdefer value.deinit(allocator);
        try ret.put(allocator, key, value);
    }
    return ret;
}
