//! Execute query plans against a storage engine.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Plan = @import("Plan.zig");
const types = @import("types.zig");
const Value = types.Value;
const storage = @import("storage.zig");

const rocksdb = @import("storage/rocksdb.zig");
const test_helpers = @import("test_helpers.zig");

fn identity(_: *anyopaque) void {}

/// State corresponding to a query plan while it is executing.
pub const Executor = struct {
    plan: *const Plan,
    txn: storage.Transaction,
    state: []OperatorState,
    allocator: Allocator,

    /// Create a new executor for the given plan, within a storage transaction.
    pub fn init(plan: *const Plan, txn: storage.Transaction) !Executor {
        const allocator = txn.allocator;
        const state = try allocator.alloc(OperatorState, plan.ops.items.len);
        for (state) |*s| {
            s.* = .{ .ptr = null, .deinit = &identity };
        }
        return .{
            .plan = plan,
            .txn = txn,
            .state = state,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Executor) void {
        for (self.state) |s| {
            if (s.ptr) |p| {
                s.deinit(p);
            }
        }
        self.allocator.free(self.state);
        self.* = undefined;
    }
};

/// Execution state attached to a query plan operator while it is running.
const OperatorState = struct {
    ptr: ?*anyopaque,
    deinit: *const fn (self: *anyopaque) void,
};

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

    try plan.columns.append(allocator, try allocator.dupe(u8, "my_node"));
    try plan.ops.append(allocator, Plan.Operator{
        .node_scan = Plan.Scan{
            .ident = 0,
            .label = null,
        },
    });

    var executor = try Executor.init(&plan, txn);
    defer executor.deinit();
}
