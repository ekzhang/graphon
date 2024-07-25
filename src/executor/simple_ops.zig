const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const Plan = @import("../Plan.zig");

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

/// Subquery execution will eventually trickle down to a 'Begin' operator, which
/// needs to return true exactly once to act as the start of a query.
pub fn runBegin(_: void, state: *bool, _: *executor.Executor, _: u32) !bool {
    if (state.*) return false;
    state.* = true;
    return true;
}

pub fn runAnti(_: void, state: *bool, exec: *executor.Executor, op_index: u32) !bool {
    // Anti only returns up to one row, so we keep track of this with the state.
    if (state.*) return false;
    state.* = true;

    // Return a row if and only if there are no rows.
    return !(try exec.next(op_index));
}

pub fn runProject(op: std.ArrayListUnmanaged(Plan.ProjectClause), _: *void, exec: *executor.Executor, op_index: u32) !bool {
    if (!try exec.next(op_index)) return false;
    for (op.items) |clause| {
        // This allows later assignment clauses to depend on earlier ones in the list.
        exec.assignments[clause.ident] = try executor.evaluate(
            clause.exp,
            exec.assignments.items,
            exec.txn.allocator,
        );
    }
    return true;
}

pub fn runEmptyResult(_: void, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    // Consume all results, and then do not return them.
    while (try exec.next(op_index)) {}
    return false;
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

/// This returns all values from the left subquery, then all values from the
/// right subquery.
pub fn runUnionAll(_: void, state: *bool, exec: *executor.Executor, op_index: u32) !bool {
    if (!state.*) {
        const j = exec.plan.subqueryBegin(op_index) orelse return error.MalformedPlan;
        const has_next_left = try exec.next(j);
        if (has_next_left) {
            return true;
        }
        state.* = true; // We finished the left subquery, move on below
    }
    return try exec.next(op_index);
}
