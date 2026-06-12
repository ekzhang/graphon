//! Repeat and repeated-path operators.

const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const Plan = @import("../Plan.zig");
const types = @import("../types.zig");
const Value = types.Value;

pub fn runArgument(_: u16, _: *void, exec: *executor.Executor, op_index: u32) !bool {
    return exec.next(op_index);
}

const RepeatChoice = struct {
    assignments: []Value,
    frontier: types.ElementId,
    trail_edge: ?types.ElementId = null,
    items: []Value,

    fn deinit(self: *RepeatChoice, allocator: Allocator) void {
        deinitAssignments(allocator, self.assignments);
        if (self.items.len > 0) {
            for (self.items) |*item| item.deinit(allocator);
            allocator.free(self.items);
        }
        self.* = undefined;
    }
};

const Frame = struct {
    depth: usize,
    frontier: types.ElementId,
    assignments: []Value,
    used_edges: []types.ElementId,
    accumulated: []std.ArrayList(Value),
    yielded: bool = false,
    choices_loaded: bool = false,
    choices: std.ArrayList(RepeatChoice) = .empty,
    choice_i: usize = 0,

    fn deinit(self: *Frame, allocator: Allocator) void {
        deinitAssignments(allocator, self.assignments);
        allocator.free(self.used_edges);
        deinitAccumulated(allocator, self.accumulated);
        for (self.choices.items) |*choice| choice.deinit(allocator);
        self.choices.deinit(allocator);
        self.* = undefined;
    }
};

pub const RepeatState = struct {
    stack: std.ArrayList(Frame) = .empty,

    pub fn deinit(self: *RepeatState, allocator: Allocator) void {
        self.clear(allocator);
        self.stack.deinit(allocator);
        self.* = undefined;
    }

    fn clear(self: *RepeatState, allocator: Allocator) void {
        for (self.stack.items) |*frame| frame.deinit(allocator);
        self.stack.clearRetainingCapacity();
    }
};

pub fn runRepeat(op: Plan.Repeat, state: *RepeatState, exec: *executor.Executor, op_index: u32) !bool {
    const begin = exec.plan.subqueryBegin(op_index) orelse return error.MalformedPlan;

    while (true) {
        if (state.stack.items.len == 0) {
            if (!try exec.next(begin)) return false;
            try state.stack.append(exec.txn.allocator, try rootFrame(exec.txn.allocator, op, exec.assignments));
        }

        const frame_i = state.stack.items.len - 1;
        var frame = &state.stack.items[frame_i];

        if (!frame.yielded) {
            frame.yielded = true;
            if (frame.depth >= op.min and destMatches(op, frame.*)) {
                try restoreAssignments(exec.txn.allocator, exec.assignments, frame.assignments);
                try applyFrameResult(exec.txn.allocator, op, frame.*, exec.assignments);
                return true;
            }
        }

        if (frame.depth == op.max) {
            popFrame(state, exec.txn.allocator);
            continue;
        }

        if (!frame.choices_loaded) {
            try loadChoices(op, frame, exec, begin, op_index);
            continue;
        }

        if (frame.choice_i < frame.choices.items.len) {
            const choice = &frame.choices.items[frame.choice_i];
            frame.choice_i += 1;
            try state.stack.append(exec.txn.allocator, try childFrame(exec.txn.allocator, frame.*, choice.*));
            continue;
        }

        popFrame(state, exec.txn.allocator);
    }
}

fn rootFrame(allocator: Allocator, op: Plan.Repeat, assignments: []const Value) !Frame {
    const frontier = switch (assignments[op.ident_start]) {
        .node_ref => |id| id,
        else => return error.WrongType,
    };

    var frame = Frame{
        .depth = 0,
        .frontier = frontier,
        .assignments = try cloneAssignments(allocator, assignments),
        .used_edges = &.{},
        .accumulated = try emptyAccumulated(allocator, op.accumulators.items.len),
    };
    errdefer frame.deinit(allocator);
    return frame;
}

fn childFrame(allocator: Allocator, parent: Frame, choice: RepeatChoice) !Frame {
    var frame = Frame{
        .depth = parent.depth + 1,
        .frontier = choice.frontier,
        .assignments = try cloneAssignments(allocator, choice.assignments),
        .used_edges = try appendUsedEdge(allocator, parent.used_edges, choice.trail_edge),
        .accumulated = try appendAccumulated(allocator, parent.accumulated, choice.items),
    };
    errdefer frame.deinit(allocator);
    return frame;
}

fn loadChoices(
    op: Plan.Repeat,
    frame: *Frame,
    exec: *executor.Executor,
    begin: u32,
    op_index: u32,
) !void {
    try restoreAssignments(exec.txn.allocator, exec.assignments, frame.assignments);
    exec.assignments[op.ident_argument].deinit(exec.txn.allocator);
    exec.assignments[op.ident_argument] = .{ .node_ref = frame.frontier };

    try exec.resetStateRange(begin, op_index);
    while (try exec.next(op_index)) {
        const frontier = switch (exec.assignments[op.ident_frontier]) {
            .node_ref => |id| id,
            else => return error.WrongType,
        };
        const trail_edge = if (op.ident_trail_edge) |ident| switch (exec.assignments[ident]) {
            .edge_ref => |id| id,
            else => return error.WrongType,
        } else null;
        if (trail_edge) |edge| {
            if (containsId(frame.used_edges, edge)) continue;
        }

        var items: ?[]Value = try exec.txn.allocator.alloc(Value, op.accumulators.items.len);
        for (items.?) |*item| item.* = .null;
        errdefer if (items) |owned| {
            for (owned) |*item| item.deinit(exec.txn.allocator);
            exec.txn.allocator.free(owned);
        };
        for (op.accumulators.items, items.?) |accumulator, *item| {
            item.* = try exec.assignments[accumulator.item_ident].dupe(exec.txn.allocator);
        }

        var assignments: ?[]Value = try cloneAssignments(exec.txn.allocator, exec.assignments);
        errdefer if (assignments) |owned| deinitAssignments(exec.txn.allocator, owned);
        try frame.choices.append(exec.txn.allocator, .{
            .assignments = assignments.?,
            .frontier = frontier,
            .trail_edge = trail_edge,
            .items = items.?,
        });
        assignments = null;
        items = null;
    }
    frame.choices_loaded = true;
}

fn popFrame(state: *RepeatState, allocator: Allocator) void {
    var frame = state.stack.pop().?;
    frame.deinit(allocator);
}

fn destMatches(op: Plan.Repeat, frame: Frame) bool {
    if (!op.dest_bound) return true;
    return switch (frame.assignments[op.ident_dest]) {
        .node_ref => |id| sameId(frame.frontier, id),
        else => false,
    };
}

fn applyFrameResult(allocator: Allocator, op: Plan.Repeat, frame: Frame, assignments: []Value) !void {
    if (!op.dest_bound) {
        assignments[op.ident_dest].deinit(allocator);
        assignments[op.ident_dest] = .{ .node_ref = frame.frontier };
    }

    for (op.accumulators.items, frame.accumulated) |accumulator, accumulated| {
        const list = try valueList(allocator, accumulated.items);
        errdefer {
            for (list) |*item| item.deinit(allocator);
            allocator.free(list);
        }
        assignments[accumulator.ident].deinit(allocator);
        assignments[accumulator.ident] = .{ .list = list };
    }
}

fn emptyAccumulated(allocator: Allocator, count: usize) ![]std.ArrayList(Value) {
    const accumulated = try allocator.alloc(std.ArrayList(Value), count);
    for (accumulated) |*items| items.* = .empty;
    return accumulated;
}

fn appendAccumulated(
    allocator: Allocator,
    parent: []const std.ArrayList(Value),
    items: []const Value,
) ![]std.ArrayList(Value) {
    std.debug.assert(parent.len == items.len);

    const accumulated = try emptyAccumulated(allocator, parent.len);
    errdefer deinitAccumulated(allocator, accumulated);

    for (parent, accumulated, items) |parent_list, *out, item| {
        for (parent_list.items) |value| try appendValueDupe(allocator, out, value);
        try appendValueDupe(allocator, out, item);
    }
    return accumulated;
}

fn appendValueDupe(allocator: Allocator, values: *std.ArrayList(Value), value: Value) !void {
    var owned = try value.dupe(allocator);
    errdefer owned.deinit(allocator);
    try values.append(allocator, owned);
}

fn deinitAccumulated(allocator: Allocator, accumulated: []std.ArrayList(Value)) void {
    for (accumulated) |*items| {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    allocator.free(accumulated);
}

fn appendUsedEdge(
    allocator: Allocator,
    parent: []const types.ElementId,
    edge: ?types.ElementId,
) ![]types.ElementId {
    const extra: usize = if (edge == null) 0 else 1;
    const out = try allocator.alloc(types.ElementId, parent.len + extra);
    @memcpy(out[0..parent.len], parent);
    if (edge) |id| out[parent.len] = id;
    return out;
}

fn valueList(allocator: Allocator, values: []const Value) ![]Value {
    const out = try allocator.alloc(Value, values.len);
    for (out) |*item| item.* = .null;
    errdefer {
        for (out) |*item| item.deinit(allocator);
        allocator.free(out);
    }
    for (values, out) |value, *dest| dest.* = try value.dupe(allocator);
    return out;
}

fn cloneAssignments(allocator: Allocator, assignments: []const Value) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, assignments.len);
    for (out) |*value| value.* = .null;
    errdefer deinitAssignments(allocator, out);
    for (assignments, out) |value, *dest| dest.* = try value.dupe(allocator);
    return out;
}

fn restoreAssignments(allocator: Allocator, assignments: []Value, base: []const Value) Allocator.Error!void {
    std.debug.assert(assignments.len == base.len);
    for (assignments, base) |*assignment, value| {
        assignment.deinit(allocator);
        assignment.* = try value.dupe(allocator);
    }
}

fn deinitAssignments(allocator: Allocator, assignments: []Value) void {
    for (assignments) |*value| value.deinit(allocator);
    allocator.free(assignments);
}

fn containsId(items: []const types.ElementId, id: types.ElementId) bool {
    for (items) |item| {
        if (sameId(item, id)) return true;
    }
    return false;
}

fn sameId(left: types.ElementId, right: types.ElementId) bool {
    return left.value == right.value;
}
