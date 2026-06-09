//! Operators implemented in this file take a subquery, starting with 'Begin'.

const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const Plan = @import("../Plan.zig");

/// Subquery execution will eventually trickle down to a 'Begin' operator, which
/// needs to return true exactly once to act as the start of a query.
pub fn runBegin(_: void, state: *bool, _: *executor.Executor, _: u32) !bool {
    if (state.*) return false;
    state.* = true;
    return true;
}

pub const JoinState = enum(u8) {
    left = 0,
    right,
};

pub fn runJoin(_: void, state: *JoinState, exec: *executor.Executor, op_index: u32) !bool {
    const j = exec.plan.subqueryBegin(op_index) orelse return error.MalformedPlan;

    while (true) {
        switch (state.*) {
            .left => {
                if (!try exec.next(j)) return false;
                try exec.resetStateRange(j, op_index);
                state.* = .right;
            },
            .right => {
                if (try exec.next(op_index)) {
                    // Return this row, but stay on the right subquery.
                    return true;
                } else {
                    state.* = .left;
                }
            },
        }
    }
}

pub fn runSemiJoin(_: void, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    const j = exec.plan.subqueryBegin(op_index) orelse return error.MalformedPlan;

    while (true) {
        // Fetch a row from the left subquery.
        if (!try exec.next(j))
            return false;

        // Then reset the right subquery and try to fetch at least one row.
        try exec.resetStateRange(j, op_index);
        if (try exec.next(op_index))
            return true;
    }
}

pub const OptionalJoinState = struct {
    side: JoinState = .left,
    matched: bool = false,
    null_idents: std.ArrayList(u16) = .empty,
    null_idents_loaded: bool = false,

    pub fn deinit(self: *OptionalJoinState, allocator: Allocator) void {
        self.null_idents.deinit(allocator);
        self.* = undefined;
    }
};

pub fn runOptionalJoin(_: void, state: *OptionalJoinState, exec: *executor.Executor, op_index: u32) !bool {
    const j = exec.plan.subqueryBegin(op_index) orelse return error.MalformedPlan;
    if (!state.null_idents_loaded) {
        state.null_idents = (try exec.plan.subqueryDefinedIdents(exec.txn.allocator, op_index)) orelse return error.MalformedPlan;
        state.null_idents_loaded = true;
    }

    while (true) {
        switch (state.side) {
            .left => {
                if (!try exec.next(j)) return false;
                try exec.resetStateRange(j, op_index);
                state.matched = false;
                state.side = .right;
            },
            .right => {
                if (try exec.next(op_index)) {
                    state.matched = true;
                    return true;
                }

                state.side = .left;
                if (!state.matched) {
                    for (state.null_idents.items) |ident| {
                        exec.assignments[ident].deinit(exec.txn.allocator);
                        exec.assignments[ident] = .null;
                    }
                    return true;
                }
            },
        }
    }
}

/// This returns all values from the left subquery, then all values from the
/// right subquery.
pub fn runUnionAll(_: void, state: *bool, exec: *executor.Executor, op_index: u32) !bool {
    if (!state.*) {
        const j = exec.plan.subqueryBegin(op_index) orelse return error.MalformedPlan;
        const has_next_left = try exec.next(j);
        if (has_next_left) {
            return true;
        }
        state.* = true; // We finished the left subquery, move on below
    }
    return try exec.next(op_index);
}
