const std = @import("std");
const testing = std.testing;

const allocators = @import("allocators.zig");
const test_utils = @import("test_utils.zig");

const PythonPaths = struct {
    paths: std.ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *PythonPaths, allocator: std.mem.Allocator) void {
        for (self.paths.items) |item| {
            allocator.free(item);
        }
        self.paths.deinit(allocator);
    }
};

/// Don't forget to call `.deinit` with the same allocator
pub fn getPythonPaths(allocator: std.mem.Allocator, pythonBin: []const u8) !PythonPaths {
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

    var lines = std.ArrayListUnmanaged([]const u8){};

    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');

    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "") or std.mem.endsWith(u8, line, ".zip") or std.mem.endsWith(u8, line, "lib-dynload")) {
            continue;
        }

        const owned_line = try allocator.dupe(u8, line);
        errdefer allocator.free(owned_line);

        try lines.append(allocator, owned_line);
    }

    return PythonPaths{ .paths = lines };
}

test "return paths from testing venv" {
    try test_utils.is_regular();

    const allocator = testing.allocator;
    var python_paths = try getPythonPaths(allocator, "python");
    defer python_paths.deinit(allocator);

    for (python_paths.paths.items) |value| {
        std.log.debug("path: {s}", .{value});
    }
}

/// This is a stateful iterator, the caller is responsible for calling `deinit`
/// when finished to release any resources held by it.
pub const PythonFileIterator = struct {
    const Self = @This();

    paths_to_search: std.ArrayListUnmanaged([]const u8),
    current_path_index: usize,

    current_dir: ?std.fs.Dir,
    walker: ?std.fs.Dir.Walker,

    pub fn init(paths: std.ArrayListUnmanaged([]const u8)) Self {
        return Self{
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
        relative: []const u8,
        base_path: []const u8,
    };

    /// NextRes.relative is owned by the caller, they're responsible for calling `allocator.free` on it
    pub fn next(self: *Self, allocator: std.mem.Allocator) !?NextRes {
        for (self.paths_to_search.items[self.current_path_index..]) |base_path| {
            if (self.walker == null) {
                const dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch |err| {
                    std.log.info("Could not open path '{s}': {s}. Skipping.", .{ base_path, @errorName(err) });
                    self.deinit();
                    self.current_path_index += 1;
                    continue;
                };
                self.current_dir = dir;
                self.walker = try dir.walk(allocator);
            }

            while (try self.walker.?.next()) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".py")) {
                    const ret_entry = try allocator.dupe(u8, entry.path);
                    return .{ .relative = ret_entry, .base_path = base_path };
                }
            }

            self.deinit();
            self.current_path_index += 1;
        }

        return null;
    }
};

fn createTestPaths(allocator: std.mem.Allocator) !struct {
    const Self = @This();

    tmp_dir: testing.TmpDir,
    paths_to_search: std.ArrayListUnmanaged([]const u8),
    fullpath: []const u8,

    fn deinit(self: *Self, allocator_: std.mem.Allocator) void {
        const items = self.paths_to_search.items.len;
        for (0..items) |idx| {
            allocator_.free(self.paths_to_search.items[idx]);
        }
        self.paths_to_search.deinit(allocator_);
        allocator_.free(self.fullpath);
        self.tmp_dir.cleanup();
    }
} {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const fullpath = try tmp.parent_dir.realpathAlloc(allocator, &tmp.sub_path);
    errdefer allocator.free(fullpath);

    try tmp.dir.makePath("dir1/sub");
    try tmp.dir.makePath("dir2");
    try tmp.dir.writeFile(.{ .sub_path = "dir1/main.py", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dir1/not_python.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dir1/sub/utils.py", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dir2/app.py", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "dir2/app.js", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "top_level.py", .data = "" }); // This should not be found.

    var paths_to_search = std.ArrayListUnmanaged([]const u8){};
    errdefer paths_to_search.deinit(allocator);

    try paths_to_search.append(allocator, try std.fs.path.join(allocator, &.{ fullpath, "dir1" }));
    try paths_to_search.append(allocator, try std.fs.path.join(allocator, &.{ fullpath, "dir2" }));
    const alloc_items = paths_to_search.items.len;
    errdefer {
        for (0..alloc_items) |idx| {
            allocator.free(paths_to_search.items[idx]);
        }
        paths_to_search.deinit(allocator);
    }
    // Add a path that doesn't exist to test robustness.
    try paths_to_search.append(allocator, try allocator.dupe(u8, "non_existent_dir"));

    return .{
        .tmp_dir = tmp,
        .paths_to_search = paths_to_search,
        .fullpath = fullpath,
    };
}

fn benchmarkPythonFileIterator(_: std.mem.Allocator, _: *std.time.Timer) !void {
    var infa = try allocators.IncreaseNeverFreeAllocator.init(std.heap.smp_allocator, 16 * allocators.kb_to_bytes, 50 * allocators.mb_to_bytes);
    defer infa.deinit();
    const infa_alloc = infa.allocator();

    var paths = try getPythonPaths(infa_alloc, "./testfixtures/testproject/.venv/bin/python");
    defer paths.deinit(infa_alloc);

    var iterator = PythonFileIterator.init(paths.paths);
    defer iterator.deinit();

    while (try iterator.next(infa_alloc)) |res| {
        infa_alloc.free(res.relative);
    }
}

test "benchmark python file iterators" {
    try test_utils.is_benchmark("benchmark python file iterators");

    const zul = @import("zul");

    var dir = std.fs.cwd().openDir("./testfixtures/testproject/.venv/lib/python3.12/site-packages", .{}) catch {
        std.debug.print("error: python venv not set up\n", .{});
        return error{PythonVenvNotSetUp}.PythonVenvNotSetUp;
    };
    dir.close();

    (try zul.benchmark.run(benchmarkPythonFileIterator, test_utils.default_benchmark_options)).print("benchmark PythonFileIterator");
}

test "PythonFileIterator finds all .py files across multiple directories" {
    try test_utils.is_regular();

    const allocator = testing.allocator;

    var test_paths = try createTestPaths(allocator);
    defer test_paths.deinit(allocator);

    var iterator = PythonFileIterator.init(test_paths.paths_to_search);
    defer iterator.deinit();

    var found_files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (found_files.items) |file| allocator.free(file);
        found_files.deinit();
    }

    while (try iterator.next(allocator)) |res| {
        defer allocator.free(res.relative);
        const val = try std.mem.concat(allocator, u8, &.{ res.base_path, std.fs.path.sep_str, res.relative });
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

    const expected1 = try std.fs.path.join(allocator, &.{ test_paths.fullpath, "dir1/main.py" });
    defer allocator.free(expected1);
    const expected2 = try std.fs.path.join(allocator, &.{ test_paths.fullpath, "dir1/sub/utils.py" });
    defer allocator.free(expected2);
    const expected3 = try std.fs.path.join(allocator, &.{ test_paths.fullpath, "dir2/app.py" });
    defer allocator.free(expected3);

    try testing.expect(results_set.contains(expected1));
    try testing.expect(results_set.contains(expected2));
    try testing.expect(results_set.contains(expected3));
}
