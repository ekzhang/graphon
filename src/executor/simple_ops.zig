const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const Plan = @import("../Plan.zig");
const types = @import("../types.zig");
const Value = types.Value;

const test_helpers = @import("../test_helpers.zig");

pub fn runNodeById(op: Plan.LookupId, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;
    switch (exec.assignments[op.ident_id]) {
        .id => |id| {
            var node = try exec.txn.getNode(id);
            if (node == null)
                return false;
            node.?.deinit(exec.txn.allocator);
            exec.assignments[op.ident_ref] = .{ .node_ref = id };
            return true;
        },
        else => return false, // Type error
    }
}

pub fn runEdgeById(op: Plan.LookupId, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;
    switch (exec.assignments[op.ident_id]) {
        .id => |id| {
            var edge = try exec.txn.getEdge(id);
            if (edge == null)
                return false;
            edge.?.deinit(exec.txn.allocator);
            exec.assignments[op.ident_ref] = .{ .edge_ref = id };
            return true;
        },
        else => return false, // Type error
    }
}

pub fn runAnti(_: void, state: *bool, exec: *executor.Executor, op_index: u32) !bool {
    // Anti only returns up to one row, so we keep track of this with the state.
    if (state.*) return false;
    state.* = true;

    // Return a row if and only if there are no rows.
    return !(try exec.next(op_index));
}

pub fn runProject(op: std.ArrayList(Plan.ProjectClause), _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;
    for (op.items) |clause| {
        // This allows later assignment clauses to depend on earlier ones in the list.
        const new_value = try executor.evaluateWithParams(clause.exp, exec.assignments, exec.txn, exec.parameters);
        exec.assignments[clause.ident].deinit(exec.txn.allocator);
        exec.assignments[clause.ident] = new_value;
    }
    return true;
}

pub fn runProjectEndpoints(op: Plan.ProjectEndpoints, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;

    const edge_id = switch (exec.assignments[op.ident_edge]) {
        .edge_ref => |id| id,
        else => return executor.Error.WrongType,
    };
    var edge = try exec.txn.getEdge(edge_id) orelse return false;
    defer edge.deinit(exec.txn.allocator);

    exec.assignments[op.ident_src].deinit(exec.txn.allocator);
    exec.assignments[op.ident_src] = .{ .node_ref = edge.endpoints[0] };
    exec.assignments[op.ident_dest].deinit(exec.txn.allocator);
    exec.assignments[op.ident_dest] = .{ .node_ref = edge.endpoints[1] };
    return true;
}

pub fn runEmptyResult(_: void, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    // Consume all results, and then do not return them.
    while (try exec.next(op_index)) {}
    return false;
}

pub fn runFilter(op: std.ArrayList(Plan.FilterClause), _: *void, exec: *executor.Executor, op_index: u32) !bool {
    filter: while (true) {
        if (!try exec.next(op_index)) return false;

        for (op.items) |clause| {
            switch (clause) {
                .bool_exp => |exp| {
                    var value = try executor.evaluateWithParams(exp, exec.assignments, exec.txn, exec.parameters);
                    defer value.deinit(exec.txn.allocator);
                    if (!value.truthy()) {
                        continue :filter;
                    }
                },
                .ident_label => |ident_label| {
                    // Must be a reference, otherwise we return a type error.
                    switch (exec.assignments[ident_label.ident]) {
                        .node_ref => |node_id| {
                            var node = try exec.txn.getNode(node_id) orelse continue :filter;
                            defer node.deinit(exec.txn.allocator);
                            node.labels.get(ident_label.label) orelse continue :filter;
                        },
                        .edge_ref => |edge_id| {
                            var edge = try exec.txn.getEdge(edge_id) orelse continue :filter;
                            defer edge.deinit(exec.txn.allocator);
                            edge.labels.get(ident_label.label) orelse continue :filter;
                        },
                        else => return executor.Error.WrongType,
                    }
                },
            }
        }

        // If we got to this point, all filter clauses have passed.
        return true;
    }
}

pub fn runLimit(op: u64, state: *u64, exec: *executor.Executor, op_index: u32) !bool {
    if (state.* >= op) {
        return false;
    } else {
        state.* += 1;
        return try exec.next(op_index);
    }
}

pub fn runSkip(op: u64, state: *bool, exec: *executor.Executor, op_index: u32) !bool {
    if (!state.*) {
        state.* = true; // Mark this as having done the skip
        for (0..op) |_| {
            if (!try exec.next(op_index)) {
                return false;
            }
        }
    }
    return try exec.next(op_index);
}

test "project endpoints assigns edge endpoint node refs" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();

    const store = try tmp.store("test.db");
    defer store.db.close();

    const txn = store.txn();
    defer txn.close();

    const allocator = std.testing.allocator;
    var plan = Plan{};
    defer plan.deinit(allocator);

    try plan.results.appendSlice(allocator, &[_]u16{ 1, 2 });
    try plan.ops.append(allocator, .{ .edge_scan = .{ .ident = 0, .label = null } });
    try plan.ops.append(allocator, .{ .project_endpoints = .{
        .ident_edge = 0,
        .ident_src = 1,
        .ident_dest = 2,
    } });

    const n1 = types.Node{ .id = .{ .value = 1 } };
    const n2 = types.Node{ .id = .{ .value = 2 } };
    const edge = types.Edge{
        .id = .{ .value = 10 },
        .endpoints = .{ n1.id, n2.id },
        .directed = true,
    };
    try txn.putNode(n1);
    try txn.putNode(n2);
    try txn.putEdge(edge);

    var exec = try executor.Executor.init(&plan, txn);
    defer exec.deinit();
    var result = try exec.run() orelse unreachable;
    defer result.deinit(allocator);

    try std.testing.expectEqual(n1.id, result.values[0].node_ref);
    try std.testing.expectEqual(n2.id, result.values[1].node_ref);
    try std.testing.expect(try exec.run() == null);
}
