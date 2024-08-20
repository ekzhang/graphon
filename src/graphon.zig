//! Graphon is a very small graph database.

comptime { // Trigger tests to run on these modules.
    _ = @import("executor.zig");
    _ = @import("Plan.zig");
    _ = @import("storage.zig");
    _ = @import("tokenizer.zig");
    _ = @import("types.zig");
}
