const std = @import("std");
const builtin = @import("builtin");

const lib = @import("pyimportls_lib");
const zul = @import("zul");

fn newAllocator() !struct {
    const Self = @This();

    infa: ?*lib.allocators.IncreaseNeverFreeAllocator,
    debug_allocator: ?*std.heap.DebugAllocator(.{}),
    internal_allocator: ?std.mem.Allocator,

    fn allocator(self: *Self) std.mem.Allocator {
        if (self.internal_allocator) |allocator_| return allocator_;
        if (self.debug_allocator) |allocator_| {
            return allocator_.allocator();
        }
        if (self.infa) |allocator_| {
            return allocator_.allocator();
        }
        unreachable;
    }

    fn deinit(self: *Self) void {
        if (self.debug_allocator) |allocator_| {
            const res = allocator_.deinit();
            if (res == .leak) {
                std.debug.print("warning: program leaked memory", .{});
            }
            std.heap.smp_allocator.destroy(allocator_);
        }
        if (self.infa) |allocator_| {
            allocator_.deinit();
            std.heap.smp_allocator.destroy(allocator_);
        }
    }
} {
    var infa: ?*lib.allocators.IncreaseNeverFreeAllocator = null;
    var debug_allocator: ?*std.heap.DebugAllocator(.{}) = null;

    const allocator = gpa: {
        if (builtin.target.os.tag == .wasi) break :gpa std.heap.wasm_allocator;
        break :gpa switch (builtin.mode) {
            .Debug => debug: {
                debug_allocator = try std.heap.smp_allocator.create(std.heap.DebugAllocator(.{}));
                debug_allocator.?.* = .init;
                break :debug null;
            },
            .ReleaseSafe, .ReleaseFast, .ReleaseSmall => infa: {
                infa = try std.heap.smp_allocator.create(lib.allocators.IncreaseNeverFreeAllocator);
                infa.?.* = try lib.allocators.IncreaseNeverFreeAllocator.init(std.heap.smp_allocator, 16 * lib.allocators.kb_to_bytes, 100 * lib.allocators.mb_to_bytes);
                break :infa null;
            },
        };
    };

    return .{
        .internal_allocator = allocator,
        .infa = infa,
        .debug_allocator = debug_allocator,
    };
}

fn parseFromPath(res: lib.python.PythonFileIterator.NextRes) void {
    var gpa2 = newAllocator() catch return;
    defer gpa2.deinit();
    const my_alloc = gpa2.allocator();

    const fpath = std.mem.concat(my_alloc, u8, &.{ res.base_path, std.fs.path.sep_str, res.relative }) catch return;
    defer my_alloc.free(fpath);

    const file = std.fs.openFileAbsolute(fpath, .{}) catch return;
    defer file.close();

    const buf = file.readToEndAlloc(std.heap.c_allocator, 99 * lib.allocators.mb_to_bytes) catch return;
    defer std.heap.c_allocator.free(buf);

    var parsed = lib.parser.parse(buf) catch {
        std.debug.print("couldn't parse {s}\n", .{fpath});
        return;
    };
    defer parsed.deinit();

    var list = parsed.getExportedSymbols(my_alloc) catch return;
    defer list.deinit(my_alloc);

    std.debug.print("{s}:{}", .{ fpath, list });
}

pub fn main() !void {
    var gpa = try newAllocator();
    defer gpa.deinit();

    const allocator = gpa.allocator();

    var paths = try lib.python.getPythonPaths(allocator, "./testfixtures/testproject/.venv/bin/python");
    defer paths.deinit(allocator);

    var iterator = lib.python.PythonFileIterator.init(paths.paths);
    defer iterator.deinit();

    var tp = try zul.ThreadPool(parseFromPath).init(allocator, .{ .count = 16, .backlog = 100 });
    defer tp.deinit(allocator);

    var results = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (results.items) |item| {
            allocator.free(item);
        }
        results.deinit(allocator);
    }

    while (try iterator.next(allocator)) |res| {
        try results.append(allocator, res.relative);
        try tp.spawn(.{res});
    }
}
