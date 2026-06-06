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
        self.paths.deinit(testing.allocator);
        self.tmp_dir.cleanup();
    }

    pub fn path(self: *SimpleTmpDir, subpath: []const u8) []const u8 {
        var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir_path_len = self.tmp_dir.dir.realPath(testing.io, &dir_path_buf) catch
            std.debug.panic("realPath failed", .{});
        const dir_path = dir_path_buf[0..dir_path_len];
        const full_path = std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, subpath }) catch
            std.debug.panic("failed to allocPrint", .{});
        self.paths.append(testing.allocator, full_path) catch
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
    return SimpleTmpDir{ .tmp_dir = tmp_dir, .paths = .empty };
}
