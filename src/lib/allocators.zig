const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const test_utils = @import("test_utils.zig");

pub const kb_to_bytes = 1024;
pub const mb_to_bytes = kb_to_bytes * 1024;
pub const gb_to_bytes = mb_to_bytes * 1024;

pub const IncreaseNeverFreeAllocator = struct {
    const Self = @This();
    const slots = 20;

    base_allocator: Allocator,
    current_index: usize,
    max_size: usize,
    current_size: usize,

    allocators: [slots]FixedBufferAllocator,

    pub fn init(base_allocator: Allocator, initial_size: usize, max_size: usize) !Self {
        // SAFETY: it's safe, trust me bro
        var allocators: [slots]FixedBufferAllocator = .{undefined} ** slots;

        const new_buf = try base_allocator.alloc(u8, initial_size);
        const buf_alloc = FixedBufferAllocator.init(new_buf);
        allocators[0] = buf_alloc;

        return Self{
            .base_allocator = base_allocator,
            .current_index = 0,
            .max_size = max_size,
            .allocators = allocators,
            .current_size = initial_size,
        };
    }

    pub fn deinit(self: *Self) void {
        for (0..self.current_index + 1) |i| {
            self.base_allocator.free(self.allocators[i].buffer);
        }
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = Allocator.noResize,
                .remap = Allocator.noRemap,
                .free = Allocator.noFree,
            },
        };
    }

    pub fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (FixedBufferAllocator.alloc(@ptrCast(&self.allocators[self.current_index]), n, alignment, ra)) |buf| {
            return buf;
        } else {
            std.log.debug("failed to allocate {d} bytes", .{n});
            self.current_index += 1;
            if (self.current_index >= slots) {
                return null;
            }

            const next_size = @min(self.current_size + self.current_size, self.max_size - self.current_size);
            if (next_size == 0) {
                std.log.debug("reached maximum size", .{});
                return null;
            }

            self.current_size += next_size;
            std.log.debug("increased size by {d} to {d}", .{ next_size, self.current_size });

            const new_buf = self.base_allocator.alloc(u8, next_size) catch return null;
            self.allocators[self.current_index] = FixedBufferAllocator.init(new_buf);

            return Self.alloc(self, n, alignment, ra);
        }
    }
};

fn runAllocatorBenchmark(allocator: Allocator) !void {
    for (0..100000) |_| {
        const aa = try allocator.create(u8);
        defer allocator.destroy(aa);

        const item = try allocator.alloc([10]u8, 100);
        defer allocator.free(item);
    }
}

fn benchmarkDefaultAllocator(default_allocator: Allocator, _: *std.time.Timer) !void {
    try runAllocatorBenchmark(default_allocator);
}

fn benchmarkArenaDefaultAllocator(default_allocator: Allocator, _: *std.time.Timer) !void {
    var arena = std.heap.ArenaAllocator.init(default_allocator);
    defer arena.deinit();
    try runAllocatorBenchmark(arena.allocator());
}

fn benchmarkCAllocator(_: Allocator, _: *std.time.Timer) !void {
    try runAllocatorBenchmark(std.heap.c_allocator);
}

fn benchmarkArenaCAllocator(_: Allocator, _: *std.time.Timer) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    try runAllocatorBenchmark(arena.allocator());
}

fn benchmarkIncreaseNeverFreeAllocator(_: Allocator, _: *std.time.Timer) !void {
    var infa = try IncreaseNeverFreeAllocator.init(std.heap.smp_allocator, 8 * kb_to_bytes, 100 * mb_to_bytes);
    defer infa.deinit();
    try runAllocatorBenchmark(infa.allocator());
}

test "benchmark allocators, lots of small allocs" {
    try test_utils.is_benchmark("benchmark allocators, lots of small allocs");

    const zul = @import("zul");

    (try zul.benchmark.run(benchmarkIncreaseNeverFreeAllocator, test_utils.default_benchmark_options)).print("benchmark IncreaseNeverFreeAllocator");
    (try zul.benchmark.run(benchmarkDefaultAllocator, test_utils.default_benchmark_options)).print("benchmark default allocator");
    (try zul.benchmark.run(benchmarkArenaDefaultAllocator, test_utils.default_benchmark_options)).print("benchmark arena default allocator");
    (try zul.benchmark.run(benchmarkCAllocator, test_utils.default_benchmark_options)).print("benchmark C allocator");
    (try zul.benchmark.run(benchmarkArenaCAllocator, test_utils.default_benchmark_options)).print("benchmark arena C allocator");
}

fn runBigAllocatorBenchmark(allocator: Allocator) !void {
    const item = try allocator.alloc(u8, 32 * kb_to_bytes);
    defer allocator.free(item);

    const item2 = try allocator.alloc(u8, 64 * kb_to_bytes);
    defer allocator.free(item2);
}

fn bigBenchmarkDefaultAllocator(default_allocator: Allocator, _: *std.time.Timer) !void {
    try runBigAllocatorBenchmark(default_allocator);
}

fn bigBenchmarkArenaDefaultAllocator(default_allocator: Allocator, _: *std.time.Timer) !void {
    var arena = std.heap.ArenaAllocator.init(default_allocator);
    defer arena.deinit();
    try runBigAllocatorBenchmark(arena.allocator());
}

fn bigBenchmarkCAllocator(_: Allocator, _: *std.time.Timer) !void {
    try runBigAllocatorBenchmark(std.heap.c_allocator);
}

fn bigBenchmarkArenaCAllocator(_: Allocator, _: *std.time.Timer) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    try runBigAllocatorBenchmark(arena.allocator());
}

fn bigBenchmarkIncreaseNeverFreeAllocator(_: Allocator, _: *std.time.Timer) !void {
    var infa = try IncreaseNeverFreeAllocator.init(std.heap.smp_allocator, 8 * kb_to_bytes, 100 * mb_to_bytes);
    defer infa.deinit();
    try runBigAllocatorBenchmark(infa.allocator());
}

test "benchmark allocators, big allocs" {
    try test_utils.is_benchmark("benchmark allocators, big allocs");

    const zul = @import("zul");

    (try zul.benchmark.run(bigBenchmarkIncreaseNeverFreeAllocator, test_utils.default_benchmark_options)).print("benchmark IncreaseNeverFreeAllocator");
    (try zul.benchmark.run(bigBenchmarkDefaultAllocator, test_utils.default_benchmark_options)).print("benchmark default allocator");
    (try zul.benchmark.run(bigBenchmarkArenaDefaultAllocator, test_utils.default_benchmark_options)).print("benchmark arena default allocator");
    (try zul.benchmark.run(bigBenchmarkCAllocator, test_utils.default_benchmark_options)).print("benchmark C allocator");
    (try zul.benchmark.run(bigBenchmarkArenaCAllocator, test_utils.default_benchmark_options)).print("benchmark arena C allocator");
}

test "test allocators" {
    try test_utils.is_regular();

    var never_free = try IncreaseNeverFreeAllocator.init(std.testing.allocator, 10, 2000);
    defer never_free.deinit();

    const allocator = never_free.allocator();
    // _ = try allocator.create([5]u8);
    // _ = try allocator.create([5]u8);
    _ = try allocator.create([200]u8);
    std.debug.print("200\n", .{});
    _ = try allocator.create([60]u8);
    std.debug.print("60\n", .{});
    _ = try allocator.create([60]u8);
    std.debug.print("60\n", .{});
    _ = try allocator.create([60]u8);
    std.debug.print("60\n", .{});
    _ = try allocator.create([1100]u8);
    std.debug.print("1100\n", .{});
}
