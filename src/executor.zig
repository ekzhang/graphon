//! Execute query plans against a storage engine.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Plan = @import("Plan.zig");
const types = @import("types.zig");
const Value = types.Value;
const storage = @import("storage.zig");

const join_ops = @import("executor/join_ops.zig");
const modify_ops = @import("executor/modify_ops.zig");
const scan_ops = @import("executor/scan_ops.zig");
const simple_ops = @import("executor/simple_ops.zig");
const step_ops = @import("executor/step_ops.zig");

const test_helpers = @import("test_helpers.zig");

const operator_impls = blk: {
    // Specify implementations of operators here.
    // Format: { op, state type, destructor, run function }
    const operator_impls_raw = .{
        .{ Plan.Operator.node_scan, scan_ops.NodeScanState, scan_ops.NodeScanState.deinit, scan_ops.runNodeScan },
        .{ Plan.Operator.edge_scan, scan_ops.EdgeScanState, scan_ops.EdgeScanState.deinit, scan_ops.runEdgeScan },
        .{ Plan.Operator.node_by_id, void, null, simple_ops.runNodeById },
        .{ Plan.Operator.edge_by_id, void, null, simple_ops.runEdgeById },
        .{ Plan.Operator.step, step_ops.StepState, step_ops.StepState.deinit, step_ops.runStep },
        .{ Plan.Operator.begin, bool, null, join_ops.runBegin },
        .{ Plan.Operator.join, join_ops.JoinState, null, join_ops.runJoin },
        .{ Plan.Operator.semi_join, void, null, join_ops.runSemiJoin },
        .{ Plan.Operator.optional_join, join_ops.OptionalJoinState, join_ops.OptionalJoinState.deinit, join_ops.runOptionalJoin },
        .{ Plan.Operator.anti, bool, null, simple_ops.runAnti },
        .{ Plan.Operator.project, void, null, simple_ops.runProject },
        .{ Plan.Operator.empty_result, void, null, simple_ops.runEmptyResult },
        .{ Plan.Operator.filter, void, null, simple_ops.runFilter },
        .{ Plan.Operator.limit, u64, null, simple_ops.runLimit },
        .{ Plan.Operator.distinct, simple_ops.DistinctState, simple_ops.DistinctState.deinit, simple_ops.runDistinct },
        .{ Plan.Operator.skip, bool, null, simple_ops.runSkip },
        .{ Plan.Operator.sort, simple_ops.SortState, simple_ops.SortState.deinit, simple_ops.runSort },
        .{ Plan.Operator.aggregate, simple_ops.AggregateState, simple_ops.AggregateState.deinit, simple_ops.runAggregate },
        .{ Plan.Operator.union_all, bool, null, join_ops.runUnionAll },
        .{ Plan.Operator.update, void, null, modify_ops.runUpdate },
        .{ Plan.Operator.insert_node, void, null, modify_ops.runInsertNode },
        .{ Plan.Operator.insert_edge, void, null, modify_ops.runInsertEdge },
        .{ Plan.Operator.delete, void, null, modify_ops.runDelete },
    };

    var impls: std.EnumMap(std.meta.Tag(Plan.Operator), OperatorImpl) = .{};

    for (operator_impls_raw) |impl_spec| {
        const spec_tag, const spec_state, const spec_deinit, const spec_run = impl_spec;
        const Impl = struct {
            fn init(allocator: Allocator) Allocator.Error!OperatorState {
                const state = try allocator.create(spec_state);
                switch (@typeInfo(spec_state)) {
                    .@"struct" => state.* = std.mem.zeroInit(spec_state, .{}),
                    else => state.* = std.mem.zeroes(spec_state),
                }
                return OperatorState.of(spec_state, state, spec_deinit);
            }
            fn run(op: Plan.Operator, state: *anyopaque, exec: *Executor, op_index: u32) Error!bool {
                const op1 = @field(op, @tagName(impl_spec[0]));
                const state1 = @as(*spec_state, @ptrCast(@alignCast(state)));
                return spec_run(op1, state1, exec, op_index);
            }
        };
        impls.put(spec_tag, OperatorImpl{ .init = &Impl.init, .run = &Impl.run });
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
pub const Error = storage.Error || error{
    MalformedPlan,
    WrongType,
};

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

    /// Number of graph storage mutations completed by this execution.
    mutations: usize,

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
            .mutations = 0,
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
        const op_tag = std.meta.activeTag(self.plan.ops.items[op_index]);
        if (operator_impls.get(op_tag)) |impl| {
            state.* = try impl.init(self.txn.allocator);
        }
    }

    /// Reset the state of all operators in the given range in the plan. Useful
    /// for resetting a subquery in a join.
    pub fn resetStateRange(self: *Executor, start_index: u32, end_index: u32) Allocator.Error!void {
        std.debug.assert(start_index <= end_index);
        var i = start_index;
        while (i < end_index) : (i += 1) {
            try self.resetState(i);
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
        const op_tag = std.meta.activeTag(op);
        if (operator_impls.get(op_tag)) |impl| {
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

test Executor {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();

    const store = try tmp.store("test.db");
    defer store.db.close();

    const txn = store.txn();
    defer txn.close();

    // Run an empty plan.
    const plan = Plan{};
    var exec = try Executor.init(&plan, txn);
    defer exec.deinit();
    try std.testing.expect(try exec.run() != null);
    try std.testing.expect(try exec.run() == null);
}

/// Evaluate an expression given assignments and storage-backed entity references.
pub fn evaluate(exp: Plan.Exp, assignments: []const Value, txn: storage.Transaction) Error!Value {
    return switch (exp) {
        .literal => |v| v.dupe(txn.allocator),
        .ident => |i| assignments[i].dupe(txn.allocator),
        .property => |p| evaluateProperty(p, assignments, txn),
        .parameter => std.debug.panic("parameters not implemented yet", .{}),
        .unary => |unary| {
            var operand = try evaluate(unary.operand, assignments, txn);
            defer operand.deinit(txn.allocator);
            return switch (unary.op) {
                .not => .{ .bool = !operand.truthy() },
            };
        },
        .binop => |binop| {
            switch (binop.op) {
                .and_ => {
                    var lhs = try evaluate(binop.left, assignments, txn);
                    defer lhs.deinit(txn.allocator);
                    if (!lhs.truthy()) return .{ .bool = false };
                    var rhs = try evaluate(binop.right, assignments, txn);
                    defer rhs.deinit(txn.allocator);
                    return .{ .bool = rhs.truthy() };
                },
                .or_ => {
                    var lhs = try evaluate(binop.left, assignments, txn);
                    defer lhs.deinit(txn.allocator);
                    if (lhs.truthy()) return .{ .bool = true };
                    var rhs = try evaluate(binop.right, assignments, txn);
                    defer rhs.deinit(txn.allocator);
                    return .{ .bool = rhs.truthy() };
                },
                else => {},
            }
            var lhs = try evaluate(binop.left, assignments, txn);
            defer lhs.deinit(txn.allocator);
            var rhs = try evaluate(binop.right, assignments, txn);
            defer rhs.deinit(txn.allocator);
            return switch (binop.op) {
                .add => try lhs.add(rhs, txn.allocator),
                .sub => lhs.sub(rhs),
                .mul => lhs.mul(rhs),
                .eql => .{ .bool = lhs.eql(rhs) },
                .neq => .{ .bool = !lhs.eql(rhs) },
                .lt => .{ .bool = if (lhs.compare(rhs)) |order| order.compare(.lt) else false },
                .lte => .{ .bool = if (lhs.compare(rhs)) |order| order.compare(.lte) else false },
                .gt => .{ .bool = if (lhs.compare(rhs)) |order| order.compare(.gt) else false },
                .gte => .{ .bool = if (lhs.compare(rhs)) |order| order.compare(.gte) else false },
                .and_, .or_ => unreachable,
            };
        },
    };
}

fn evaluateProperty(p: Plan.PropertyExp, assignments: []const Value, txn: storage.Transaction) Error!Value {
    return switch (assignments[p.ident]) {
        .node_ref => |id| {
            var node = try txn.getNode(id) orelse return .null;
            defer node.deinit(txn.allocator);
            const value = node.properties.get(p.key) orelse return .null;
            return try value.dupe(txn.allocator);
        },
        .edge_ref => |id| {
            var edge = try txn.getEdge(id) orelse return .null;
            defer edge.deinit(txn.allocator);
            const value = edge.properties.get(p.key) orelse return .null;
            return try value.dupe(txn.allocator);
        },
        .null => return .null,
        else => return Error.WrongType,
    };
}

test evaluate {
    var tmp = test_helpers.tmp();
    defer tmp.cleanup();
    const store = try tmp.store("test.db");
    defer store.db.close();
    const txn = store.txn();
    defer txn.close();

    try std.testing.expectEqual(
        Value{ .int64 = 12 },
        try evaluate(Plan.Exp{ .literal = Value{ .int64 = 12 } }, &.{}, txn),
    );

    try std.testing.expectEqual(
        Value{ .int64 = 13 },
        try evaluate(Plan.Exp{ .ident = 0 }, &.{Value{ .int64 = 13 }}, txn),
    );

    var bop = Plan.BinopExp{
        .op = Plan.Binop.sub,
        .left = Plan.Exp{ .literal = Value{ .int64 = 500 } },
        .right = Plan.Exp{ .ident = 0 },
    };
    try std.testing.expectEqual(
        Value{ .int64 = 420 },
        try evaluate(Plan.Exp{ .binop = &bop }, &.{Value{ .int64 = 80 }}, txn),
    );

    var cmp = Plan.BinopExp{
        .op = Plan.Binop.gte,
        .left = Plan.Exp{ .ident = 0 },
        .right = Plan.Exp{ .literal = Value{ .int64 = 80 } },
    };
    try std.testing.expectEqual(
        Value{ .bool = true },
        try evaluate(Plan.Exp{ .binop = &cmp }, &.{Value{ .int64 = 80 }}, txn),
    );

    var node = types.Node{ .id = .{ .value = 99 } };
    defer node.deinit(txn.allocator);
    try node.properties.put(txn.allocator, try txn.allocator.dupe(u8, "age"), Value{ .int64 = 42 });
    try txn.putNode(node);

    var property_exp = Plan.Exp{ .property = .{ .ident = 0, .key = try txn.allocator.dupe(u8, "age") } };
    defer property_exp.deinit(txn.allocator);
    var property_value = try evaluate(property_exp, &.{Value{ .node_ref = node.id }}, txn);
    defer property_value.deinit(txn.allocator);
    try std.testing.expectEqual(Value{ .int64 = 42 }, property_value);
}
