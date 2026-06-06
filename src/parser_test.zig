//! GQL parsing tests for Parse.zig

const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const io = std.io;
const maxInt = std.math.maxInt;

var fixed_buffer_mem: [100 * 1024]u8 = undefined;

fn testParse(source: [:0]const u8, allocator: mem.Allocator, anything_changed: *bool) ![]u8 {
    const stderr = io.getStdErr().writer();

    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    for (tree.errors) |parse_error| {
        const loc = tree.tokenLocation(0, parse_error.token);
        try stderr.print("(memory buffer):{d}:{d}: error: ", .{ loc.line + 1, loc.column + 1 });
        try tree.renderError(parse_error, stderr);
        try stderr.print("\n{s}\n", .{source[loc.line_start..loc.line_end]});
        {
            var i: usize = 0;
            while (i < loc.column) : (i += 1) {
                try stderr.writeAll(" ");
            }
            try stderr.writeAll("^");
        }
        try stderr.writeAll("\n");
    }
    if (tree.errors.len != 0) {
        return error.ParseError;
    }

    const formatted = try tree.render(allocator);
    anything_changed.* = !mem.eql(u8, formatted, source);
    return formatted;
}
fn testTransformImpl(allocator: mem.Allocator, fba: *std.heap.FixedBufferAllocator, source: [:0]const u8, expected_source: []const u8) !void {
    // reset the fixed buffer allocator each run so that it can be re-used for each
    // iteration of the failing index
    fba.reset();
    var anything_changed: bool = undefined;
    const result_source = try testParse(source, allocator, &anything_changed);
    try std.testing.expectEqualStrings(expected_source, result_source);
    const changes_expected = source.ptr != expected_source.ptr;
    if (anything_changed != changes_expected) {
        print("std.zig.render returned {} instead of {}\n", .{ anything_changed, changes_expected });
        return error.TestFailed;
    }
    try std.testing.expect(anything_changed == changes_expected);
    allocator.free(result_source);
}
fn testTransform(source: [:0]const u8, expected_source: []const u8) !void {
    var fixed_allocator = std.heap.FixedBufferAllocator.init(fixed_buffer_mem[0..]);
    return std.testing.checkAllAllocationFailures(fixed_allocator.allocator(), testTransformImpl, .{ &fixed_allocator, source, expected_source });
}
fn testCanonical(source: [:0]const u8) !void {
    return testTransform(source, source);
}

const Error = std.zig.Ast.Error.Tag;

fn testError(source: [:0]const u8, expected_errors: []const Error) !void {
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    std.testing.expectEqual(expected_errors.len, tree.errors.len) catch |err| {
        std.debug.print("errors found: {any}\n", .{tree.errors});
        return err;
    };
    for (expected_errors, 0..) |expected, i| {
        try std.testing.expectEqual(expected, tree.errors[i].tag);
    }
}
