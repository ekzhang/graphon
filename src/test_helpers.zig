//! Helper functions to make testing less repetitive.

const std = @import("std");
const testing = std.testing;

const rocksdb = @import("storage/rocksdb.zig");
const storage = @import("storage.zig");

pub const SimpleTmpDir = struct {
    tmp_dir: testing.TmpDir,
    paths: std.ArrayList([]const u8),

    pub fn cleanup(self: *SimpleTmpDir) void {
        for (self.paths.items) |p| {
            testing.allocator.free(p);
        }
        self.paths.deinit();
        self.tmp_dir.cleanup();
    }

    pub fn path(self: *SimpleTmpDir, subpath: []const u8) []const u8 {
        const dir_path = self.tmp_dir.dir.realpathAlloc(testing.allocator, ".") catch
            std.debug.panic("realpathAlloc failed", .{});
        defer testing.allocator.free(dir_path);
        const full_path = std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, subpath }) catch
            std.debug.panic("failed to allocPrint", .{});
        self.paths.append(full_path) catch
            std.debug.panic("failed to append full_path", .{});
        return full_path;
    }

    pub fn store(self: *SimpleTmpDir, subpath: []const u8) !storage.Storage {
        const db = try rocksdb.DB.open(self.path(subpath));
        return .{ .db = db };
    }
};

pub fn tmp() SimpleTmpDir {
    const tmp_dir = testing.tmpDir(.{});
    const paths = std.ArrayList([]const u8).init(testing.allocator);
    return SimpleTmpDir{ .tmp_dir = tmp_dir, .paths = paths };
}
