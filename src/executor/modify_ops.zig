//! Execute query plan operators that modify graph data: nodes and edges.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringMap = std.array_hash_map.String;

const executor = @import("../executor.zig");
const Plan = @import("../Plan.zig");
const rocksdb = @import("../storage/rocksdb.zig");
const types = @import("../types.zig");

pub fn runInsertNode(op: Plan.InsertNode, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;

    var node = types.Node{ .id = types.ElementId.generate(exec.txn.io) };
    defer node.deinit(exec.txn.allocator);

    for (op.labels.items) |label| {
        try node.labels.put(exec.txn.allocator, try exec.txn.allocator.dupe(u8, label), void{});
    }
    node.properties = try evaluateProperties(op.properties, exec.assignments, exec.txn);

    try exec.txn.putNode(node);
    exec.mutations += 1;
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
        .id = types.ElementId.generate(exec.txn.io),
        .endpoints = .{ src_id, dest_id },
        .directed = op.directed,
    };
    defer edge.deinit(exec.txn.allocator);

    for (op.labels.items) |label| {
        try edge.labels.put(exec.txn.allocator, try exec.txn.allocator.dupe(u8, label), void{});
    }
    edge.properties = try evaluateProperties(op.properties, exec.assignments, exec.txn);

    try exec.txn.putEdge(edge);
    exec.mutations += 1;
    if (op.ident) |ident| {
        exec.assignments[ident] = .{ .edge_ref = edge.id };
    }
    return true;
}

pub fn runUpdate(op: Plan.Update, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;

    for (op.items.items) |item| {
        var value = try executor.evaluate(item.value, exec.assignments, exec.txn);
        errdefer value.deinit(exec.txn.allocator);
        switch (exec.assignments[item.ident]) {
            .node_ref => |node_id| {
                var node = try exec.txn.getNode(node_id) orelse continue;
                defer node.deinit(exec.txn.allocator);
                try putProperty(exec.txn.allocator, &node.properties, item.key, value);
                value = .null;
                try exec.txn.putNode(node);
                exec.mutations += 1;
            },
            .edge_ref => |edge_id| {
                var edge = try exec.txn.getEdge(edge_id) orelse continue;
                defer edge.deinit(exec.txn.allocator);
                try putProperty(exec.txn.allocator, &edge.properties, item.key, value);
                value = .null;
                try exec.txn.putEdge(edge);
                exec.mutations += 1;
            },
            else => return executor.Error.WrongType,
        }
    }

    return true;
}

pub fn runDelete(op: Plan.Delete, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;

    for (op.idents.items) |ident| {
        switch (exec.assignments[ident]) {
            .edge_ref => |edge_id| {
                if (try deleteEdgeIfPresent(exec, edge_id)) exec.mutations += 1;
            },
            .node_ref => |node_id| {
                if (op.detach) exec.mutations += try deleteAttachedEdges(exec, node_id);
                if (try deleteNodeIfPresent(exec, node_id)) exec.mutations += 1;
            },
            else => return executor.Error.WrongType,
        }
    }

    return true;
}

fn putProperty(
    allocator: Allocator,
    properties: *StringMap(types.Value),
    key: []const u8,
    value: types.Value,
) Allocator.Error!void {
    if (properties.getIndex(key)) |idx| {
        properties.values()[idx].deinit(allocator);
        properties.values()[idx] = value;
    } else {
        try properties.put(allocator, try allocator.dupe(u8, key), value);
    }
}

fn deleteEdgeIfPresent(exec: *executor.Executor, edge_id: types.ElementId) executor.Error!bool {
    exec.txn.deleteEdge(edge_id) catch |err| switch (err) {
        rocksdb.Error.NotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn deleteNodeIfPresent(exec: *executor.Executor, node_id: types.ElementId) executor.Error!bool {
    exec.txn.deleteNode(node_id) catch |err| switch (err) {
        rocksdb.Error.NotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn deleteAttachedEdges(exec: *executor.Executor, node_id: types.ElementId) executor.Error!usize {
    var ids = std.ArrayList(types.ElementId).empty;
    defer ids.deinit(exec.txn.allocator);
    var it = try exec.txn.iterateAdj(node_id, .out, .in);
    defer it.close();
    while (try it.next()) |entry| try ids.append(exec.txn.allocator, entry.edge_id);

    var deleted: usize = 0;
    for (ids.items) |edge_id| {
        if (try deleteEdgeIfPresent(exec, edge_id)) deleted += 1;
    }
    return deleted;
}

/// Evaluate property expressions in a query plan.
fn evaluateProperties(
    properties: Plan.Properties,
    assignments: []const types.Value,
    txn: @import("../storage.zig").Transaction,
) executor.Error!StringMap(types.Value) {
    const allocator = txn.allocator;
    var ret: StringMap(types.Value) = .empty;
    errdefer types.freeProperties(allocator, &ret);
    for (properties.items(.key), properties.items(.value)) |k, v| {
        const key = try allocator.dupe(u8, k);
        errdefer allocator.free(key);
        var value = try executor.evaluate(v, assignments, txn);
        errdefer value.deinit(allocator);
        try ret.put(allocator, key, value);
    }
    return ret;
}
