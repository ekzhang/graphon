const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const storage = @import("../storage.zig");
const Plan = @import("../Plan.zig");

pub const NodeScanState = struct {
    it: ?storage.NodeIterator,

    pub fn deinit(self: *NodeScanState, _: Allocator) void {
        if (self.it) |it| it.close();
        self.* = undefined;
    }
};

pub fn runNodeScan(op: Plan.Scan, state: *NodeScanState, exec: *executor.Executor, op_index: u32) !bool {
    if (state.it) |*it| {
        _ = try it.next();
    }
    _ = op;
    _ = exec;
    _ = op_index;
    return false;
}
