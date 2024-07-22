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

pub fn runStep(op: Plan.Step, state: *StepState, exec: *executor.Executor, op_index: u32) !bool {
    while (true) {
        if (state.fsm == .iterating or state.fsm == .iter_out_before_in) {
            // We are processing an existing iterator.
            var it = state.it.?;
            while (try it.next()) |entry| {
                var ok = true;

                // Check that the label matches, if needed.
                if (op.edge_label) |expected_label| {
                    var edge = try exec.txn.getEdge(entry.edge_id);
                    if (edge != null) {
                        defer edge.?.deinit(exec.txn.allocator);
                        if (!edge.?.labels.contains(expected_label)) {
                            ok = false;
                        }
                    } else ok = false;
                }

                if (ok) {
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
                            state.it = try exec.txn.iterateAdj(src_node_id, .in, .in);
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

            state.fsm = .iterating;
            const min_inout: types.EdgeInOut, const max_inout: types.EdgeInOut = switch (op.direction) {
                .left => .{ .in, .in },
                .right => .{ .out, .out },
                .undirected => .{ .simple, .simple },
                .left_or_undirected => .{ .simple, .in },
                .right_or_undirected => .{ .out, .simple },
                .left_or_right => blk: {
                    // Special case: there are two iterators to run, use this state.
                    state.fsm = .iter_out_before_in;
                    break :blk .{ .out, .out };
                },
                .any => .{ .out, .in },
            };
            switch (exec.assignments[op.ident_src]) {
                .node_ref => |src_node_id| {
                    state.it = try exec.txn.iterateAdj(src_node_id, min_inout, max_inout);
                },
                // Type error reading the type of ident_src.
                else => return false,
            }
        }
    }
}

test "tree steps" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();

    const store = try tmp.store("test.db");
    defer store.db.close();

    const txn = store.txn();
    defer txn.close();

    const allocator = std.testing.allocator;
    var plan = Plan{};
    defer plan.deinit(allocator);

    try plan.results.append(allocator, 0);
    try plan.ops.append(allocator, Plan.Operator{
        .node_scan = Plan.Scan{
            .ident = 0,
            .label = null,
        },
    });

    {
        // Currently, there are no nodes in the graph to scan through.
        var exec = try executor.Executor.init(&plan, txn);
        defer exec.deinit();
        try std.testing.expect(try exec.run() == null);
    }

    const n = types.Node{ .id = types.ElementId.generate() };
    try txn.putNode(n);

    {
        // There is now one node.
        var exec = try executor.Executor.init(&plan, txn);
        defer exec.deinit();
        var result = try exec.run() orelse unreachable;
        defer result.deinit(allocator);
        try std.testing.expectEqual(n.id, result.values[0].node_ref);
        try std.testing.expect(try exec.run() == null);
    }
}
