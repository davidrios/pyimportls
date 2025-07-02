const std = @import("std");
const testing = std.testing;

const test_utils = @import("test_utils.zig");

/// # Caller's Responsibility
/// The caller OWNS the memory of the returned ArrayList AND each of the strings inside it.
/// You must deinitialize the list and free each string element to prevent memory leaks.
///
/// Example Cleanup:
/// ```zig
/// var list = try getPythonPaths(allocator, ...);
/// defer {
///     for (list.items) |item| {
///         allocator.free(item);
///     }
///     list.deinit();
/// }
/// ```
pub fn getPythonPaths(allocator: std.mem.Allocator, pythonBin: []const u8) !std.ArrayList([]const u8) {
    const argv = &[_][]const u8{ pythonBin, "-c", "import sys; print('\\n'.join(sys.path))" };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        std.log.err("Command '{s}' failed with exit code {d}.\nStderr:\n{s}", .{
            argv,
            result.term.Exited,
            result.stderr,
        });
        return error.CommandFailed;
    }

    var lines = std.ArrayList([]const u8).init(allocator);
    errdefer lines.deinit();

    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');

    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, ".zip") or std.mem.endsWith(u8, line, "lib-dynload")) {
            continue;
        }

        const owned_line = try allocator.dupe(u8, line);
        errdefer allocator.free(owned_line);

        try lines.append(owned_line);
    }

    return lines;
}

test "return paths from testing venv" {
    try test_utils.is_regular();

    const allocator = testing.allocator;
    const paths = try getPythonPaths(allocator, "python");
    defer {
        for (paths.items) |item| {
            allocator.free(item);
        }
        paths.deinit();
    }

    for (paths.items) |value| {
        std.log.debug("path: {s}", .{value});
    }
}

/// This is a stateful iterator, the caller is responsible for calling `deinit`
/// when finished to release any resources held by it.
pub const PythonFileIterator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    paths_to_search: std.ArrayList([]const u8),
    current_path_index: usize,

    current_dir: ?std.fs.Dir,
    walker: ?std.fs.Dir.Walker,

    pub fn init(allocator: std.mem.Allocator, paths: std.ArrayList([]const u8)) Self {
        return Self{
            .allocator = allocator,
            .paths_to_search = paths,
            .current_path_index = 0,
            .current_dir = null,
            .walker = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.walker) |*walker| {
            walker.deinit();
            self.walker = null;
        }
        if (self.current_dir) |*dir| {
            dir.close();
            self.current_dir = null;
        }
    }

    const NextRes = struct {
        size: usize,
        base_path: *const []const u8,
    };

    pub fn next(self: *Self, relative_path_out_buf: []u8) !?NextRes {
        for (self.paths_to_search.items[self.current_path_index..]) |base_path| {
            if (self.walker == null) {
                const dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch |err| {
                    std.log.info("Could not open path '{s}': {s}. Skipping.", .{ base_path, @errorName(err) });
                    self.deinit();
                    self.current_path_index += 1;
                    continue;
                };
                self.current_dir = dir;
                self.walker = try dir.walk(self.allocator);
            }

            while (try self.walker.?.next()) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".py")) {
                    if (entry.path.len >= relative_path_out_buf.len) {
                        return error.OutOfMemory;
                    }
                    @memcpy(relative_path_out_buf[0..entry.path.len], entry.path);
                    return .{ .size = entry.path.len, .base_path = &base_path };
                }
            }

            self.deinit();
            self.current_path_index += 1;
        }

        return null;
    }
};

test "PythonFileIterator finds all .py files across multiple directories" {
    try test_utils.is_regular();

    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const fullpath = try tmp.parent_dir.realpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(fullpath);

    try tmp.dir.makePath("dir1/sub");
    try tmp.dir.makePath("dir2");
    try tmp.dir.writeFile(.{ .sub_path = "dir1/main.py", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dir1/not_python.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dir1/sub/utils.py", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dir2/app.py", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dir2/app.js", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "top_level.py", .data = "" }); // This should not be found.

    var paths_to_search = std.ArrayList([]const u8).init(allocator);
    defer paths_to_search.deinit();

    try paths_to_search.append(try std.fs.path.join(allocator, &.{ fullpath, "dir1" }));
    try paths_to_search.append(try std.fs.path.join(allocator, &.{ fullpath, "dir2" }));
    const alloc_items = paths_to_search.items.len;
    defer {
        for (0..alloc_items) |idx| {
            allocator.free(paths_to_search.items[idx]);
        }
    }
    // Add a path that doesn't exist to test robustness.
    try paths_to_search.append("non_existent_dir");

    var iterator = PythonFileIterator.init(allocator, paths_to_search);
    defer iterator.deinit();

    var found_files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (found_files.items) |file| allocator.free(file);
        found_files.deinit();
    }

    var nbuf: [4096:0]u8 = undefined;
    while (try iterator.next(&nbuf)) |res| {
        const val = try std.mem.concat(allocator, u8, &.{ res.base_path.*, std.fs.path.sep_str, nbuf[0..res.size] });
        std.log.debug("res: {s}", .{val});
        try found_files.append(val);
    }

    try testing.expectEqual(@as(usize, 3), found_files.items.len);

    // Use a HashMap for easier checking, as filesystem walk order is not guaranteed.
    var results_set = std.StringHashMap(void).init(allocator);
    defer results_set.deinit();
    for (found_files.items) |file| {
        try results_set.put(file, {});
    }

    const expected1 = try std.fs.path.join(allocator, &.{ fullpath, "dir1/main.py" });
    defer allocator.free(expected1);
    const expected2 = try std.fs.path.join(allocator, &.{ fullpath, "dir1/sub/utils.py" });
    defer allocator.free(expected2);
    const expected3 = try std.fs.path.join(allocator, &.{ fullpath, "dir2/app.py" });
    defer allocator.free(expected3);

    try testing.expect(results_set.contains(expected1));
    try testing.expect(results_set.contains(expected2));
    try testing.expect(results_set.contains(expected3));
}
