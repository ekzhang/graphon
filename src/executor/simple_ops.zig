const executor = @import("../executor.zig");

pub fn runEmptyResult(exec: *executor.Executor, op_index: u32) !bool {
    // Consume all results, and then do not return them.
    while (try exec.next(op_index)) {}
    return false;
}

pub fn runLimit(op: u64, exec: *executor.Executor, op_index: u32) !bool {
    const state: *u64 = @ptrCast(@alignCast(exec.states[op_index].ptr));
    if (state.* >= op) {
        return false;
    }
    state.* += 1;
    return try exec.next(op_index);
}

pub fn runSkip(op: u64, exec: *executor.Executor, op_index: u32) !bool {
    // State: Whether it has been skipped yet or not.
    const state: *bool = @ptrCast(@alignCast(exec.states[op_index].ptr));
    if (!state.*) {
        state.* = true;
        for (0..op) |_| {
            if (!try exec.next(op_index)) {
                return false;
            }
        }
    }
    return try exec.next(op_index);
}
