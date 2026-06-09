const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const storage = @import("../storage.zig");
const Plan = @import("../Plan.zig");
const types = @import("../types.zig");

const test_helpers = @import("../test_helpers.zig");

const StepFsm = enum {
    init,
    iter_out_before_in, // Needs a separate state because they are noncontiguous.
    iterating,
};

pub const StepState = struct {
    fsm: StepFsm = .init,
    it: ?storage.AdjIterator,

    pub fn deinit(self: *StepState, _: Allocator) void {
        if (self.it) |it| it.close();
        self.* = undefined;
    }
};

fn edgeLabelMatches(txn: storage.Transaction, edge_id: types.ElementId, expected_label: ?[]const u8) !bool {
    const label = expected_label orelse return true;
    var edge = try txn.getEdge(edge_id) orelse return false;
    defer edge.deinit(txn.allocator);
    return edge.labels.contains(label);
}

fn startIterator(
    state: *StepState,
    txn: storage.Transaction,
    node_id: types.ElementId,
    direction: types.EdgeDirection,
) !void {
    state.fsm = .iterating;
    const min_inout: types.EdgeInOut, const max_inout: types.EdgeInOut = switch (direction) {
        .left => .{ .in, .in },
        .right => .{ .out, .out },
        .undirected => .{ .simple, .simple },
        .left_or_undirected => .{ .simple, .in },
        .right_or_undirected => .{ .out, .simple },
        .left_or_right => blk: {
            state.fsm = .iter_out_before_in;
            break :blk .{ .out, .out };
        },
        .any => .{ .out, .in },
    };
    state.it = try txn.iterateAdj(node_id, min_inout, max_inout);
}

fn startLeftOrRightInIterator(state: *StepState, txn: storage.Transaction, node_id: types.ElementId) !void {
    state.fsm = .iterating;
    state.it = try txn.iterateAdj(node_id, .in, .in);
}

pub fn runStep(op: Plan.Step, state: *StepState, exec: *executor.Executor, op_index: u32) !bool {
    while (true) {
        if (state.fsm == .iterating or state.fsm == .iter_out_before_in) {
            // We are processing an existing iterator.
            var it = state.it.?;
            while (try it.next()) |entry| {
                if (try edgeLabelMatches(exec.txn, entry.edge_id, op.edge_label)) {
                    // We've found a matching edge.
                    if (op.ident_edge) |i| exec.assignments[i] = .{ .edge_ref = entry.edge_id };
                    if (op.ident_dest) |i| exec.assignments[i] = .{ .node_ref = entry.dest_node_id };
                    return true;
                }
            }

            // We've finished iterating, exhausting this branch.
            it.close();
            state.it = null;

            switch (state.fsm) {
                .iterating => state.fsm = .init,
                .iter_out_before_in => {
                    state.fsm = .iterating;
                    // Set up the next iterator to EdgeInOut.in direction.
                    switch (exec.assignments[op.ident_src]) {
                        .node_ref => |src_node_id| {
                            try startLeftOrRightInIterator(state, exec.txn, src_node_id);
                        },
                        // Type error, this should never happen.
                        else => return false,
                    }
                },
                else => unreachable,
            }
        } else {
            std.debug.assert(state.fsm == .init);
            // Grab the next source node from the previous operator.
            const has_next = try exec.next(op_index);
            if (!has_next) return false;

            switch (exec.assignments[op.ident_src]) {
                .node_ref => |src_node_id| {
                    try startIterator(state, exec.txn, src_node_id, op.direction);
                },
                // Type error reading the type of ident_src.
                else => return false,
            }
        }
    }
}

pub fn runStepBetween(op: Plan.StepBetween, state: *StepState, exec: *executor.Executor, op_index: u32) !bool {
    while (true) {
        if (state.fsm == .iterating or state.fsm == .iter_out_before_in) {
            var it = state.it.?;
            while (try it.next()) |entry| {
                const dest_node_id = switch (exec.assignments[op.ident_dest]) {
                    .node_ref => |id| id,
                    else => return false,
                };
                if (entry.dest_node_id.value != dest_node_id.value) continue;
                if (!try edgeLabelMatches(exec.txn, entry.edge_id, op.edge_label)) continue;

                if (op.ident_edge) |i| exec.assignments[i] = .{ .edge_ref = entry.edge_id };
                return true;
            }

            it.close();
            state.it = null;

            switch (state.fsm) {
                .iterating => state.fsm = .init,
                .iter_out_before_in => {
                    switch (exec.assignments[op.ident_src]) {
                        .node_ref => |src_node_id| {
                            try startLeftOrRightInIterator(state, exec.txn, src_node_id);
                        },
                        else => return false,
                    }
                },
                else => unreachable,
            }
        } else {
            std.debug.assert(state.fsm == .init);
            const has_next = try exec.next(op_index);
            if (!has_next) return false;

            switch (exec.assignments[op.ident_src]) {
                .node_ref => |src_node_id| {
                    if (exec.assignments[op.ident_dest] != .node_ref) return false;
                    try startIterator(state, exec.txn, src_node_id, op.direction);
                },
                else => return false,
            }
        }
    }
}

test "triangle steps" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();

    const store = try tmp.store("test.db");
    defer store.db.close();

    const txn = store.txn();
    defer txn.close();

    const allocator = std.testing.allocator;
    var plan = Plan{};
    defer plan.deinit(allocator);

    try plan.results.appendSlice(allocator, &[_]u16{ 0, 1, 2 });
    try plan.ops.append(allocator, Plan.Operator{
        .node_scan = Plan.Scan{
            .ident = 0,
            .label = null,
        },
    });
    try plan.ops.append(allocator, Plan.Operator{
        .step = Plan.Step{
            .ident_src = 0,
            .ident_edge = 1,
            .ident_dest = 2,
            .direction = .right,
            .edge_label = null,
        },
    });

    const n1 = types.Node{ .id = .{ .value = 1 } };
    const n2 = types.Node{ .id = .{ .value = 2 } };
    const n3 = types.Node{ .id = .{ .value = 3 } };
    try txn.putNode(n1);
    try txn.putNode(n2);
    try txn.putNode(n3);

    {
        // No edges found.
        var exec = try executor.Executor.init(&plan, txn);
        defer exec.deinit();
        try std.testing.expect(try exec.run() == null);
    }

    const e1 = types.Edge{
        .id = .{ .value = 11 },
        .endpoints = .{ n1.id, n2.id },
        .directed = true,
    };
    try txn.putEdge(e1);

    {
        // There is now one directed edge.
        var exec = try executor.Executor.init(&plan, txn);
        defer exec.deinit();
        var result = try exec.run() orelse unreachable;
        defer result.deinit(allocator);
        try std.testing.expectEqual(n1.id, result.values[0].node_ref);
        try std.testing.expectEqual(e1.id, result.values[1].edge_ref);
        try std.testing.expectEqual(n2.id, result.values[2].node_ref);
        try std.testing.expect(try exec.run() == null);
    }

    const e2 = types.Edge{
        .id = .{ .value = 12 },
        .endpoints = .{ n2.id, n3.id },
        .directed = true,
    };
    try txn.putEdge(e2);

    {
        // We should see two edges now.
        var exec = try executor.Executor.init(&plan, txn);
        defer exec.deinit();
        var result = try exec.run() orelse unreachable;
        defer result.deinit(allocator);
        var result2 = try exec.run() orelse unreachable;
        defer result2.deinit(allocator);
        try std.testing.expect(try exec.run() == null);
    }

    // Try doing a two-edge traversal.
    try plan.results.appendSlice(allocator, &[_]u16{ 3, 4 });
    try plan.ops.append(allocator, Plan.Operator{
        .step = Plan.Step{
            .ident_src = 2,
            .ident_edge = 3,
            .ident_dest = 4,
            .direction = .right,
            .edge_label = null,
        },
    });

    {
        var exec = try executor.Executor.init(&plan, txn);
        defer exec.deinit();
        var result = try exec.run() orelse unreachable;
        defer result.deinit(allocator);
        try std.testing.expectEqual(n1.id, result.values[0].node_ref);
        try std.testing.expectEqual(e1.id, result.values[1].edge_ref);
        try std.testing.expectEqual(n2.id, result.values[2].node_ref);
        try std.testing.expectEqual(e2.id, result.values[3].edge_ref);
        try std.testing.expectEqual(n3.id, result.values[4].node_ref);
        try std.testing.expect(try exec.run() == null);
    }
}

test "step between traverses only to bound destination" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();

    const store = try tmp.store("test.db");
    defer store.db.close();

    const txn = store.txn();
    defer txn.close();

    const allocator = std.testing.allocator;
    var plan = Plan{};
    defer plan.deinit(allocator);

    try plan.results.appendSlice(allocator, &[_]u16{ 0, 1, 2 });
    try plan.ops.append(allocator, .{ .node_scan = .{ .ident = 0, .label = null } });
    try plan.ops.append(allocator, .begin);
    try plan.ops.append(allocator, .{ .node_scan = .{ .ident = 1, .label = null } });
    try plan.ops.append(allocator, .join);
    try plan.ops.append(allocator, .{ .step_between = .{
        .ident_src = 0,
        .ident_edge = 2,
        .ident_dest = 1,
        .direction = .right,
        .edge_label = null,
    } });

    const n1 = types.Node{ .id = .{ .value = 1 } };
    const n2 = types.Node{ .id = .{ .value = 2 } };
    const n3 = types.Node{ .id = .{ .value = 3 } };
    try txn.putNode(n1);
    try txn.putNode(n2);
    try txn.putNode(n3);

    const e12 = types.Edge{
        .id = .{ .value = 12 },
        .endpoints = .{ n1.id, n2.id },
        .directed = true,
    };
    const e13 = types.Edge{
        .id = .{ .value = 13 },
        .endpoints = .{ n1.id, n3.id },
        .directed = true,
    };
    const e21 = types.Edge{
        .id = .{ .value = 21 },
        .endpoints = .{ n2.id, n1.id },
        .directed = true,
    };
    try txn.putEdge(e12);
    try txn.putEdge(e13);
    try txn.putEdge(e21);

    var found12 = false;
    var found13 = false;
    var found21 = false;
    var exec = try executor.Executor.init(&plan, txn);
    defer exec.deinit();
    while (try exec.run()) |result| {
        var row = result;
        defer row.deinit(allocator);
        const src = row.values[0].node_ref;
        const dest = row.values[1].node_ref;
        const edge = row.values[2].edge_ref;
        if (src.value == n1.id.value and dest.value == n2.id.value and edge.value == e12.id.value) {
            found12 = true;
        } else if (src.value == n1.id.value and dest.value == n3.id.value and edge.value == e13.id.value) {
            found13 = true;
        } else if (src.value == n2.id.value and dest.value == n1.id.value and edge.value == e21.id.value) {
            found21 = true;
        } else {
            return error.TestFailed;
        }
    }

    try std.testing.expect(found12);
    try std.testing.expect(found13);
    try std.testing.expect(found21);
}
