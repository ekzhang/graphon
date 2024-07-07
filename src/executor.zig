//! Execute query plans against a storage engine.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Plan = @import("Plan.zig");
const types = @import("types.zig");
const Value = types.Value;
const storage = @import("storage.zig");

const scan_ops = @import("executor/scan_ops.zig");
const simple_ops = @import("executor/simple_ops.zig");

const test_helpers = @import("test_helpers.zig");

const operator_impls = blk: {
    // Specify implementations of operators here.
    // Format: { op, state type, destructor, run function }
    const operator_impls_raw = .{
        .{ Plan.Operator.node_scan, scan_ops.State, null, scan_ops.runNodeScan },
        .{ Plan.Operator.empty_result, void, null, simple_ops.runEmptyResult },
        .{ Plan.Operator.limit, u64, null, simple_ops.runLimit },
        .{ Plan.Operator.skip, bool, null, simple_ops.runSkip },
    };

    var impls: std.EnumMap(std.meta.Tag(Plan.Operator), OperatorImpl) = .{};

    for (operator_impls_raw) |impl_spec| {
        const Impl = struct {
            fn init(allocator: Allocator) Allocator.Error!OperatorState {
                const state = try allocator.create(impl_spec[1]);
                return OperatorState.of(impl_spec[1], state, impl_spec[2]);
            }
            fn run(op: Plan.Operator, state: *anyopaque, exec: *Executor, op_index: u32) Error!bool {
                const op1 = @field(op, @tagName(impl_spec[0]));
                const state1 = @as(*impl_spec[1], @ptrCast(@alignCast(state)));
                return impl_spec[3](op1, state1, exec, op_index);
            }
        };
        impls.put(impl_spec[0], OperatorImpl{ .init = &Impl.init, .run = &Impl.run });
    }

    break :blk impls;
};

/// Type-erased implementation of a operator.
const OperatorImpl = struct {
    init: *const fn (allocator: Allocator) Allocator.Error!OperatorState,
    run: *const fn (op: Plan.Operator, state: *anyopaque, exec: *Executor, op_index: u32) Error!bool,
};

/// Type-erased state attached to a query plan operator while it is running.
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
        var exec = try init1(plan, txn);
        errdefer exec.deinit();
        for (plan.ops.items, 0..) |_, i| {
            try exec.resetState(@intCast(i));
        }
        return exec;
    }

    fn init1(plan: *const Plan, txn: storage.Transaction) !Executor {
        const idents = plan.idents();
        const assignments = try txn.allocator.alloc(Value, idents);
        errdefer txn.allocator.free(assignments);
        for (assignments) |*a| a.* = .null;

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

    /// Reset the state of the operator in the given index in the plan.
    pub fn resetState(self: *Executor, op_index: u32) Allocator.Error!void {
        var state = &self.states[op_index];
        if (state.ptr) |p| {
            state.destroy(p, self.txn.allocator);
            state.* = .{ .ptr = null, .destroy = undefined };
        }
        if (operator_impls.get(self.plan.ops.items[op_index])) |impl| {
            state.* = try impl.init(self.txn.allocator);
        }
    }

    /// Run the operators before the given index in the plan.
    ///
    /// Returns false if the set of rows is exhausted for this operator. This is
    /// similar to an iterator API, but the actual values are stored in the
    /// executor's assignment buffer.
    ///
    /// After returning false, next() should not be called on the same operator
    /// again until its state has been reset.
    pub fn next(self: *Executor, end_index: u32) Error!bool {
        if (end_index > self.plan.ops.items.len) {
            std.debug.panic("operator end_index out of bounds: {d}", .{end_index});
        } else if (end_index == 0) {
            const initialized = self.init_op;
            self.init_op = true;
            return !initialized;
        }

        const op_index = end_index - 1;
        const op = self.plan.ops.items[op_index];
        if (operator_impls.get(op)) |impl| {
            return impl.run(op, self.states[op_index].ptr.?, self, op_index);
        } else {
            std.debug.panic("unimplemented operator {s}", .{@tagName(op)});
        }
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

test "basic Executor" {
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
        var exec = try Executor.init(&plan, txn);
        defer exec.deinit();
        try std.testing.expect(try exec.run() == null);
    }
}
