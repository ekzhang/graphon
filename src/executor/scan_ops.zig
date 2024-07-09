const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const storage = @import("../storage.zig");
const Plan = @import("../Plan.zig");
const types = @import("../types.zig");

pub const NodeScanState = struct {
    it: ?storage.NodeIterator,

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
    var it = &state.it.?;
    while (true) {
        var next_node: types.Node = try it.next() orelse return false;
        defer next_node.deinit(exec.txn.allocator);

        if (op.label == null or next_node.labels.get(op.label.?) != null) {
            exec.assignments[op_index] = types.Value{ .node_ref = next_node.id };
            return true;
        }
    }
}
