const executor = @import("../executor.zig");
const storage = @import("../storage.zig");
const Plan = @import("../Plan.zig");

pub const State = struct {};

pub fn runNodeScan(op: Plan.Scan, state: *State, exec: *executor.Executor, op_index: u32) !bool {
    _ = op;
    _ = state;
    _ = exec;
    _ = op_index;
    return false;
}
