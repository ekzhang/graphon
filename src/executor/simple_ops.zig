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
            exec.assignments,
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
