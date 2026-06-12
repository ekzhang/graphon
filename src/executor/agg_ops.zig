const std = @import("std");
const Allocator = std.mem.Allocator;

const executor = @import("../executor.zig");
const Plan = @import("../Plan.zig");
const Value = @import("../types.zig").Value;

pub const DistinctState = struct {
    rows: std.ArrayList(SortRow) = .empty,
    index: usize = 0,
    loaded: bool = false,

    pub fn deinit(self: *DistinctState, allocator: Allocator) void {
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
        self.* = undefined;
    }
};

pub fn runDistinct(op: std.ArrayList(u16), state: *DistinctState, exec: *executor.Executor, op_index: u32) !bool {
    if (!state.loaded) {
        input: while (try exec.next(op_index)) {
            for (state.rows.items) |row| {
                if (distinctRowEqual(op.items, row.assignments, exec.assignments)) continue :input;
            }
            try state.rows.append(exec.txn.allocator, .{ .assignments = try cloneAssignments(exec.txn.allocator, exec.assignments) });
        }
        state.loaded = true;
    }

    if (state.index >= state.rows.items.len) return false;
    const row = state.rows.items[state.index];
    state.index += 1;
    for (exec.assignments, row.assignments) |*dest, source| {
        dest.deinit(exec.txn.allocator);
        dest.* = .null;
        dest.* = try source.dupe(exec.txn.allocator);
    }
    return true;
}

pub const AggregateState = struct {
    rows: std.ArrayList(AggregateRow) = .empty,
    index: usize = 0,
    loaded: bool = false,

    pub fn deinit(self: *AggregateState, allocator: Allocator) void {
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
        self.* = undefined;
    }
};

const AggregateRow = struct {
    assignments: []Value,
    states: []AggregateItemState,

    fn deinit(self: *AggregateRow, allocator: Allocator) void {
        for (self.assignments) |*value| value.deinit(allocator);
        allocator.free(self.assignments);
        for (self.states) |*state| state.deinit(allocator);
        allocator.free(self.states);
        self.* = undefined;
    }
};

const AggregateItemState = struct {
    count: i64 = 0,
    sum: Value = .null,
    value: Value = .null,
    seen: std.ArrayList(Value) = .empty,

    fn deinit(self: *AggregateItemState, allocator: Allocator) void {
        self.sum.deinit(allocator);
        self.value.deinit(allocator);
        for (self.seen.items) |*value| value.deinit(allocator);
        self.seen.deinit(allocator);
        self.* = undefined;
    }
};

pub fn runAggregate(op: Plan.Aggregate, state: *AggregateState, exec: *executor.Executor, op_index: u32) !bool {
    if (!state.loaded) {
        while (try exec.next(op_index)) {
            const row = try aggregateRow(op, state, exec);
            try applyAggregates(op, row, exec);
        }

        if (state.rows.items.len == 0 and op.groups.items.len == 0) {
            _ = try appendAggregateRow(op, state, exec);
        }
        for (state.rows.items) |*row| try finalizeAggregates(op, row, exec.txn.allocator);
        state.loaded = true;
    }

    if (state.index >= state.rows.items.len) return false;
    const row = state.rows.items[state.index];
    state.index += 1;
    for (exec.assignments, row.assignments) |*dest, source| {
        dest.deinit(exec.txn.allocator);
        dest.* = try source.dupe(exec.txn.allocator);
    }
    return true;
}

fn aggregateRow(op: Plan.Aggregate, state: *AggregateState, exec: *executor.Executor) !*AggregateRow {
    for (state.rows.items) |*row| {
        if (distinctRowEqual(op.groups.items, row.assignments, exec.assignments)) return row;
    }
    return appendAggregateRow(op, state, exec);
}

fn appendAggregateRow(op: Plan.Aggregate, state: *AggregateState, exec: *executor.Executor) !*AggregateRow {
    const assignments = try cloneAssignments(exec.txn.allocator, exec.assignments);
    errdefer {
        for (assignments) |*value| value.deinit(exec.txn.allocator);
        exec.txn.allocator.free(assignments);
    }

    const states = try exec.txn.allocator.alloc(AggregateItemState, op.items.items.len);
    errdefer exec.txn.allocator.free(states);
    for (states) |*item_state| item_state.* = .{};
    errdefer for (states) |*item_state| item_state.deinit(exec.txn.allocator);

    try state.rows.append(exec.txn.allocator, .{ .assignments = assignments, .states = states });
    return &state.rows.items[state.rows.items.len - 1];
}

fn applyAggregates(op: Plan.Aggregate, row: *AggregateRow, exec: *executor.Executor) !void {
    for (op.items.items, row.states) |item, *state| {
        var value: ?Value = null;
        defer if (value) |*v| v.deinit(exec.txn.allocator);
        if (item.argument) |argument| {
            value = try executor.evaluate(argument, exec.assignments, exec.txn);
            if (value.? == .null) continue;
            if (item.distinct) {
                if (aggregateSeenContains(state.seen.items, value.?)) continue;
                try state.seen.append(exec.txn.allocator, try value.?.dupe(exec.txn.allocator));
            }
        }

        switch (item.function) {
            .count => {
                state.count += 1;
            },
            .sum => try addAggregateNumeric(state, value.?, exec.txn.allocator),
            .avg => {
                try addAggregateNumeric(state, value.?, exec.txn.allocator);
                state.count += 1;
            },
            .min => try applyAggregateOrder(state, value.?, .lt, exec.txn.allocator),
            .max => try applyAggregateOrder(state, value.?, .gt, exec.txn.allocator),
        }
    }
}

fn finalizeAggregates(op: Plan.Aggregate, row: *AggregateRow, allocator: Allocator) !void {
    for (op.items.items, row.states) |item, state| {
        row.assignments[item.ident].deinit(allocator);
        row.assignments[item.ident] = .null;
        row.assignments[item.ident] = switch (item.function) {
            .count => .{ .int64 = state.count },
            .sum => try state.sum.dupe(allocator),
            .avg => averageValue(state),
            .min, .max => try state.value.dupe(allocator),
        };
    }
}

fn aggregateSeenContains(seen: []const Value, value: Value) bool {
    for (seen) |seen_value| {
        if (seen_value.eql(value)) return true;
    }
    return false;
}

fn addAggregateNumeric(state: *AggregateItemState, value: Value, allocator: Allocator) !void {
    switch (value) {
        .int64, .float64 => {},
        else => return executor.Error.WrongType,
    }

    if (state.sum == .null) {
        state.sum = value;
        return;
    }

    var next = try state.sum.add(value, allocator);
    errdefer next.deinit(allocator);
    if (next == .null) return executor.Error.WrongType;
    state.sum.deinit(allocator);
    state.sum = next;
}

fn applyAggregateOrder(state: *AggregateItemState, value: Value, want: std.math.Order, allocator: Allocator) !void {
    if (state.value == .null) {
        state.value = try value.dupe(allocator);
        return;
    }
    const order = value.compare(state.value) orelse return executor.Error.WrongType;
    if (order == want) {
        state.value.deinit(allocator);
        state.value = try value.dupe(allocator);
    }
}

fn averageValue(state: AggregateItemState) Value {
    if (state.count == 0) return .null;
    return switch (state.sum) {
        .int64 => |sum| .{ .float64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(state.count)) },
        .float64 => |sum| .{ .float64 = sum / @as(f64, @floatFromInt(state.count)) },
        .null => .null,
        else => unreachable,
    };
}

pub const SortState = struct {
    rows: std.ArrayList(SortRow) = .empty,
    index: usize = 0,
    loaded: bool = false,

    pub fn deinit(self: *SortState, allocator: Allocator) void {
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
        self.* = undefined;
    }
};

const SortRow = struct {
    assignments: []Value,

    fn deinit(self: *SortRow, allocator: Allocator) void {
        for (self.assignments) |*value| value.deinit(allocator);
        allocator.free(self.assignments);
        self.* = undefined;
    }
};

const SortClauses = std.MultiArrayList(Plan.SortClause).Slice;

const SortContext = struct {
    clauses: SortClauses,
};

pub fn runSort(op: std.MultiArrayList(Plan.SortClause), state: *SortState, exec: *executor.Executor, op_index: u32) !bool {
    if (!state.loaded) {
        while (try exec.next(op_index)) {
            try state.rows.append(exec.txn.allocator, .{ .assignments = try cloneAssignments(exec.txn.allocator, exec.assignments) });
        }
        state.loaded = true;
        std.mem.sort(SortRow, state.rows.items, SortContext{ .clauses = op.slice() }, sortRowLessThan);
    }

    if (state.index >= state.rows.items.len) return false;
    const row = state.rows.items[state.index];
    state.index += 1;
    for (exec.assignments, row.assignments) |*dest, source| {
        dest.deinit(exec.txn.allocator);
        dest.* = try source.dupe(exec.txn.allocator);
    }
    return true;
}

pub const TopState = struct {
    heap: std.PriorityQueue(SortRow, SortClauses, orderRowsReverse) = .empty,
    finalItems: []SortRow = &.{}, // Borrowed from heap capacity after it is emptied.
    loaded: bool = false,

    pub fn deinit(self: *TopState, allocator: Allocator) void {
        for (self.heap.items) |*row| row.deinit(allocator);
        for (self.finalItems) |*row| row.deinit(allocator);
        self.heap.deinit(allocator); // includes `finalItems` memory in its capacity
        self.* = undefined;
    }
};

pub fn runTop(op: Plan.Top, state: *TopState, exec: *executor.Executor, op_index: u32) !bool {
    if (!state.loaded) {
        state.heap = .initContext(op.clauses.slice());
        const count = std.math.cast(usize, op.count) orelse return error.MalformedPlan;
        if (count == 0) {
            state.loaded = true;
            return false;
        }

        try state.heap.ensureTotalCapacityPrecise(exec.txn.allocator, count);
        while (try exec.next(op_index)) {
            try state.heap.push(
                exec.txn.allocator,
                .{ .assignments = try cloneAssignments(exec.txn.allocator, exec.assignments) },
            );
            if (state.heap.items.len > count) {
                var dropped = state.heap.pop().?;
                dropped.deinit(exec.txn.allocator);
            }
        }
        // In-place heapsort using the heap slice.
        const finalItems = state.heap.items;
        while (state.heap.items.len > 0) {
            const idx = state.heap.items.len - 1;
            finalItems[idx] = state.heap.pop().?;
        }
        state.finalItems = finalItems;
        state.loaded = true;
    }
    if (state.finalItems.len == 0) return false;
    const row = state.finalItems[0];
    state.finalItems = state.finalItems[1..];
    for (exec.assignments, row.assignments) |*dest, source| {
        dest.deinit(exec.txn.allocator);
        dest.* = source;
    }
    exec.txn.allocator.free(row.assignments);
    return true;
}

fn cloneAssignments(allocator: Allocator, assignments: []const Value) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, assignments.len);
    errdefer allocator.free(out);
    for (out) |*value| value.* = .null;
    errdefer for (out) |*value| value.deinit(allocator);

    for (assignments, 0..) |value, i| {
        out[i].deinit(allocator);
        out[i] = try value.dupe(allocator);
    }
    return out;
}

fn distinctRowEqual(idents: []const u16, left: []const Value, right: []const Value) bool {
    for (idents) |ident| {
        if (!left[ident].eql(right[ident])) return false;
    }
    return true;
}

fn sortRowLessThan(ctx: SortContext, left: SortRow, right: SortRow) bool {
    return orderRows(ctx.clauses, left, right) == .lt;
}

fn orderRowsReverse(clauses: SortClauses, left: SortRow, right: SortRow) std.math.Order {
    // Top keeps the heap root as the worst retained row, so `pop()` can drop it
    // whenever the heap grows beyond the requested limit.
    return orderRows(clauses, left, right).invert();
}

fn orderRows(clauses: SortClauses, left: SortRow, right: SortRow) std.math.Order {
    for (0..clauses.len) |i| {
        const clause = clauses.get(i);
        var ord = compareSortValues(left.assignments[clause.ident], right.assignments[clause.ident]);
        if (ord == .eq) continue;
        if (clause.desc) ord = ord.invert();
        return ord;
    }
    return .eq;
}

fn compareSortValues(left: Value, right: Value) std.math.Order {
    if (left.compare(right)) |order| return order;
    if (left == .null and right != .null) return .gt;
    if (left != .null and right == .null) return .lt;
    return .eq;
}
