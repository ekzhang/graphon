//! Graphon is a very small graph database.

comptime { // Trigger tests to run on these modules.
    _ = @import("./Plan.zig");
    _ = @import("./storage.zig");
    _ = @import("./types.zig");
}
