const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const Plan = @import("../Plan.zig");
const Value = @import("../types.zig").Value;

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
        const new_value = try executor.evaluate(clause.exp, exec.assignments, exec.txn);
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

pub fn runFilter(op: std.ArrayList(Plan.FilterClause), _: *void, exec: *executor.Executor, op_index: u32) !bool {
    filter: while (true) {
        if (!try exec.next(op_index)) return false;

        for (op.items) |clause| {
            switch (clause) {
                .bool_exp => |exp| {
                    var value = try executor.evaluate(exp, exec.assignments, exec.txn);
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

pub const SortState = struct {
    rows: std.ArrayList(SortRow) = .empty,
    index: usize = 0,
    loaded: bool = false,

    pub fn deinit(self: *SortState, allocator: Allocator) void {
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
        self.* = undefined;
    }
};

const SortRow = struct {
    assignments: []Value,

    fn deinit(self: *SortRow, allocator: Allocator) void {
        for (self.assignments) |*value| value.deinit(allocator);
        allocator.free(self.assignments);
        self.* = undefined;
    }
};

const SortContext = struct {
    clauses: std.MultiArrayList(Plan.SortClause).Slice,
};

pub fn runSort(op: std.MultiArrayList(Plan.SortClause), state: *SortState, exec: *executor.Executor, op_index: u32) !bool {
    if (!state.loaded) {
        while (try exec.next(op_index)) {
            try state.rows.append(exec.txn.allocator, .{ .assignments = try cloneAssignments(exec.txn.allocator, exec.assignments) });
        }
        state.loaded = true;
        std.mem.sort(SortRow, state.rows.items, SortContext{ .clauses = op.slice() }, sortRowLessThan);
    }

    if (state.index >= state.rows.items.len) return false;
    const row = state.rows.items[state.index];
    state.index += 1;
    for (exec.assignments, row.assignments) |*dest, source| {
        dest.deinit(exec.txn.allocator);
        dest.* = try source.dupe(exec.txn.allocator);
    }
    return true;
}

fn cloneAssignments(allocator: Allocator, assignments: []const Value) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, assignments.len);
    errdefer allocator.free(out);
    for (out) |*value| value.* = .null;
    errdefer for (out) |*value| value.deinit(allocator);

    for (assignments, 0..) |value, i| {
        out[i].deinit(allocator);
        out[i] = try value.dupe(allocator);
    }
    return out;
}

fn sortRowLessThan(ctx: SortContext, left: SortRow, right: SortRow) bool {
    for (0..ctx.clauses.len) |i| {
        const clause = ctx.clauses.get(i);
        const order = compareSortValues(left.assignments[clause.ident], right.assignments[clause.ident]);
        if (order == .eq) continue;
        return if (clause.desc) order == .gt else order == .lt;
    }
    return false;
}

fn compareSortValues(left: Value, right: Value) std.math.Order {
    if (left.compare(right)) |order| return order;
    if (left == .null and right != .null) return .gt;
    if (left != .null and right == .null) return .lt;
    return .eq;
}
