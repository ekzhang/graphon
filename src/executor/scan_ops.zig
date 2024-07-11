const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const storage = @import("../storage.zig");
const Plan = @import("../Plan.zig");
const types = @import("../types.zig");

const test_helpers = @import("../test_helpers.zig");

pub const NodeScanState = struct {
    it: ?storage.ScanIterator(types.Node),

    pub fn deinit(self: *NodeScanState, _: Allocator) void {
        if (self.it) |it| it.close();
        self.* = undefined;
    }
};

pub fn runNodeScan(op: Plan.Scan, state: *NodeScanState, exec: *executor.Executor, op_index: u32) !bool {
    if (state.it == null) {
        const has_next = try exec.next(op_index);
        if (!has_next) return false;
        state.it = try exec.txn.iterateNodes();
    }
    const it = &state.it.?;
    while (true) {
        var next_node: types.Node = try it.next() orelse return false;
        defer next_node.deinit(exec.txn.allocator);

        if (op.label == null or next_node.labels.get(op.label.?) != null) {
            exec.assignments[op_index] = types.Value{ .node_ref = next_node.id };
            return true;
        }
    }
}

pub const EdgeScanState = struct {
    it: ?storage.ScanIterator(types.Edge),

    pub fn deinit(self: *EdgeScanState, _: Allocator) void {
        if (self.it) |it| it.close();
        self.* = undefined;
    }
};

pub fn runEdgeScan(op: Plan.Scan, state: *EdgeScanState, exec: *executor.Executor, op_index: u32) !bool {
    if (state.it == null) {
        const has_next = try exec.next(op_index);
        if (!has_next) return false;
        state.it = try exec.txn.iterateEdges();
    }
    const it = &state.it.?;
    while (true) {
        var next_edge: types.Edge = try it.next() orelse return false;
        defer next_edge.deinit(exec.txn.allocator);

        if (op.label == null or next_edge.labels.get(op.label.?) != null) {
            exec.assignments[op_index] = types.Value{ .edge_ref = next_edge.id };
            return true;
        }
    }
}

test "node scan" {
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
