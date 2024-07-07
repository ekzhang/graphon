//! Execute query plans against a storage engine.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Plan = @import("Plan.zig");
const types = @import("types.zig");
const Value = types.Value;
const storage = @import("storage.zig");
const rocksdb = @import("storage/rocksdb.zig");

const simple_ops = @import("executor/simple_ops.zig");

const test_helpers = @import("test_helpers.zig");

/// Error type returned by running a query plan.
pub const Error = storage.Error;

/// State corresponding to a query plan while it is executing.
pub const Executor = struct {
    plan: *const Plan,
    txn: storage.Transaction,

    /// State for each operator in the plan.
    states: []OperatorState,

    /// Value assignments, implicitly represents the current row.
    assignments: []Value,

    /// Whether the implicit "initial operator" has returned yet.
    init_op: bool,

    /// Create a new executor for the given plan, within a storage transaction.
    pub fn init(plan: *const Plan, txn: storage.Transaction) !Executor {
        const idents = plan.idents();
        const assignments = try txn.allocator.alloc(Value, idents);
        errdefer txn.allocator.free(assignments);
        for (assignments) |*a| {
            a.* = .null;
        }

        const states = try txn.allocator.alloc(OperatorState, plan.ops.items.len);
        for (states) |*state| {
            state.* = .{ .ptr = null, .destroy = undefined };
        }
        return .{
            .plan = plan,
            .txn = txn,
            .states = states,
            .assignments = assignments,
            .init_op = false,
        };
    }

    pub fn deinit(self: *Executor) void {
        for (self.states) |s| {
            if (s.ptr) |p| {
                s.destroy(p, self.txn.allocator);
            }
        }
        self.txn.allocator.free(self.states);
        for (self.assignments) |*v| {
            v.deinit(self.txn.allocator);
        }
        self.txn.allocator.free(self.assignments);
        self.* = undefined;
    }

    /// Run the operators before the given index in the plan.
    ///
    /// Returns false if the set of rows is exhausted for this operator. This is
    /// similar to an iterator API, but the actual values are stored in the
    /// executor's assignment buffer.
    ///
    /// After returning false, next() should not be called on the same operator
    /// again until its state has been reset.
    pub fn next(exec: *Executor, end_index: u32) Error!bool {
        if (end_index > exec.plan.ops.items.len) {
            std.debug.panic("operator end_index out of bounds: {d}", .{end_index});
        } else if (end_index == 0) {
            const initialized = exec.init_op;
            exec.init_op = true;
            return !initialized;
        }

        const op_index = end_index - 1;
        return switch (exec.plan.ops.items[op_index]) {
            .node_scan => |_| @panic("todo!"),
            .empty_result => try simple_ops.runEmptyResult(exec, op_index),
            .limit => |op| try simple_ops.runLimit(op, exec, op_index),
            .skip => |op| try simple_ops.runSkip(op, exec, op_index),
            else => std.debug.panic(
                "unimplemented operator {s}",
                .{@tagName(exec.plan.ops.items[op_index])},
            ),
        };
    }

    /// Return the next row from the plan, or false if the plan is exhausted.
    pub fn run(self: *Executor) Error!?Result {
        const has_next = try self.next(@intCast(self.plan.ops.items.len));
        if (!has_next) return null;
        var values = try self.txn.allocator.alloc(Value, self.plan.results.items.len);
        for (values) |*v| v.* = .null;
        errdefer {
            for (values) |*v| {
                v.deinit(self.txn.allocator);
            }
            self.txn.allocator.free(values);
        }
        for (self.plan.results.items, 0..) |r, i| {
            values[i] = try self.assignments[r].dupe(self.txn.allocator);
        }
        return .{ .values = values };
    }
};

pub const Result = struct {
    /// A single row in the set of results from an executed query.
    values: []Value,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        for (self.values) |*v| {
            v.deinit(allocator);
        }
        allocator.free(self.values);
        self.* = undefined;
    }
};

/// Execution state attached to a query plan operator while it is running.
const OperatorState = struct {
    ptr: ?*anyopaque,
    destroy: *const fn (self: *anyopaque, allocator: Allocator) void,

    fn of(comptime T: type, ptr: *T, comptime deinit: ?*const fn (self: *T, allocator: Allocator) void) OperatorState {
        return .{
            .ptr = ptr,
            .destroy = &struct {
                fn opaque_destroy(self: *anyopaque, allocator: Allocator) void {
                    const state: *T = @ptrCast(@alignCast(self));
                    if (deinit) |func| {
                        func(state, allocator);
                    }
                    allocator.destroy(state);
                }
            }.opaque_destroy,
        };
    }
};

fn stateForOperator(op: Plan.Operator, allocator: Allocator) !OperatorState {
    switch (op) {
        .limit => {
            const state = try allocator.create(u64);
            state.* = 0;
            return OperatorState.of(u64, state, null);
        },
        .skip => {
            const state = try allocator.create(bool);
            state.* = false;
            return OperatorState.of(bool, state, null);
        },
        else => return .{ .ptr = null, .destroy = undefined },
    }
}

test "basic Executor" {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();
    const db = try rocksdb.DB.open(tmp.path("test.db"));
    defer db.close();

    const store = storage.Storage{ .db = db };
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
        var exec = try Executor.init(&plan, txn);
        defer exec.deinit();
        try std.testing.expect(try exec.run() == null);
    }
}
