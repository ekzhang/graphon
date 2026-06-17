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
    node.properties = try evaluateProperties(op.properties, exec.assignments, exec.txn, exec.parameters);

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
    edge.properties = try evaluateProperties(op.properties, exec.assignments, exec.txn, exec.parameters);

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
        switch (item) {
            .property => |property| try updateProperty(exec, property),
            .add_label => |label| try updateLabel(exec, label, .add),
            .remove_label => |label| try updateLabel(exec, label, .remove),
        }
    }

    return true;
}

fn updateProperty(exec: *executor.Executor, item: Plan.UpdateProperty) !void {
    var value = try executor.evaluateWithParams(item.value, exec.assignments, exec.txn, exec.parameters);
    errdefer value.deinit(exec.txn.allocator);
    switch (exec.assignments[item.ident]) {
        .node_ref => |node_id| {
            var node = try exec.txn.getNode(node_id) orelse return;
            defer node.deinit(exec.txn.allocator);
            try putProperty(exec.txn.allocator, &node.properties, item.key, value);
            value = .null;
            try exec.txn.putNode(node);
            exec.mutations += 1;
        },
        .edge_ref => |edge_id| {
            var edge = try exec.txn.getEdge(edge_id) orelse return;
            defer edge.deinit(exec.txn.allocator);
            try putProperty(exec.txn.allocator, &edge.properties, item.key, value);
            value = .null;
            try exec.txn.putEdge(edge);
            exec.mutations += 1;
        },
        else => return executor.Error.WrongType,
    }
}

const LabelUpdate = enum { add, remove };

fn updateLabel(exec: *executor.Executor, item: Plan.UpdateLabel, update: LabelUpdate) !void {
    switch (exec.assignments[item.ident]) {
        .node_ref => |node_id| {
            var node = try exec.txn.getNode(node_id) orelse return;
            defer node.deinit(exec.txn.allocator);
            const changed = switch (update) {
                .add => try addLabel(exec.txn.allocator, &node.labels, item.label),
                .remove => removeLabel(exec.txn.allocator, &node.labels, item.label),
            };
            if (!changed) return;
            try exec.txn.putNode(node);
            exec.mutations += 1;
        },
        .edge_ref => |edge_id| {
            var edge = try exec.txn.getEdge(edge_id) orelse return;
            defer edge.deinit(exec.txn.allocator);
            const changed = switch (update) {
                .add => try addLabel(exec.txn.allocator, &edge.labels, item.label),
                .remove => removeLabel(exec.txn.allocator, &edge.labels, item.label),
            };
            if (!changed) return;
            try exec.txn.putEdge(edge);
            exec.mutations += 1;
        },
        else => return executor.Error.WrongType,
    }
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

fn addLabel(allocator: Allocator, labels: *StringMap(void), label: []const u8) Allocator.Error!bool {
    if (labels.contains(label)) return false;
    var owned_label: ?[]u8 = try allocator.dupe(u8, label);
    errdefer if (owned_label) |owned| allocator.free(owned);
    try labels.put(allocator, owned_label.?, void{});
    owned_label = null;
    return true;
}

fn removeLabel(allocator: Allocator, labels: *StringMap(void), label: []const u8) bool {
    const index = labels.getIndex(label) orelse return false;
    const owned_label = labels.keys()[index];
    labels.swapRemoveAt(index);
    allocator.free(owned_label);
    return true;
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
    parameters: []const types.Value,
) executor.Error!StringMap(types.Value) {
    const allocator = txn.allocator;
    var ret: StringMap(types.Value) = .empty;
    errdefer types.freeProperties(allocator, &ret);
    for (properties.items(.key), properties.items(.value)) |k, v| {
        const key = try allocator.dupe(u8, k);
        errdefer allocator.free(key);
        var value = try executor.evaluateWithParams(v, assignments, txn, parameters);
        errdefer value.deinit(allocator);
        try ret.put(allocator, key, value);
    }
    return ret;
}
