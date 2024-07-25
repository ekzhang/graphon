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
        const new_value = try executor.evaluate(clause.exp, exec.assignments, exec.txn.allocator);
        exec.assignments[clause.ident].deinit(exec.txn.allocator);
        exec.assignments[clause.ident] = new_value;
    }
    return true;
}

pub fn runEmptyResult(_: void, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    // Consume all results, and then do not return them.
    while (try exec.next(op_index)) {}
    return false;
}

pub fn runFilter(op: std.ArrayListUnmanaged(Plan.FilterClause), _: *void, exec: *executor.Executor, op_index: u32) !bool {
    filter: while (true) {
        if (!try exec.next(op_index)) return false;

        for (op.items) |clause| {
            switch (clause) {
                .bool_exp => |exp| {
                    var value = try executor.evaluate(exp, exec.assignments, exec.txn.allocator);
                    defer value.deinit(exec.txn.allocator);
                    if (!value.truthy()) {
                        continue :filter;
                    }
                },
                .ident_label => |ident_label| {
                    // Must be a reference, otherwise we give a type error.
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
