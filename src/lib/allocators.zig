const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const test_utils = @import("test_utils.zig");

const IncreaseNeverFreeAllocator = struct {
    const Self = @This();
    const slots = 20;

    start_buffer: []u8,
    current_index: usize,
    max_size: usize,
    current_size: usize,

    allocators: [slots]FixedBufferAllocator,

    pub fn init(start_buffer: []u8, max_size: usize) Self {
        // SAFETY: it's safe, trust me bro
        var allocators: [slots]FixedBufferAllocator = .{undefined} ** slots;

        const first_buf_allocator = FixedBufferAllocator.init(start_buffer);
        allocators[0] = first_buf_allocator;

        return Self{
            .start_buffer = start_buffer,
            .current_index = 0,
            .max_size = max_size,
            .allocators = allocators,
            .current_size = start_buffer.len,
        };
    }

    pub fn deinit(self: *Self) void {
        for (1..self.current_index + 1) |i| {
            std.heap.page_allocator.free(self.allocators[i].buffer);
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
            std.log.debug("success allocating {d} bytes", .{n});
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

            const new_buf = std.heap.page_allocator.alloc(u8, next_size) catch return null;
            self.allocators[self.current_index] = FixedBufferAllocator.init(new_buf);

            return Self.alloc(self, n, alignment, ra);
        }
    }
};

const HAYSTACK = "abcdefghijklmnopqrstvuwxyz0123456789";
fn indexOfScalar(_: Allocator, _: *std.time.Timer) !void {
    const i = std.mem.indexOfScalar(u8, HAYSTACK, '9').?;
    if (i != 35) {
        @panic("fail");
    }
}

test "benchmark: asdfasdf" {
    try test_utils.is_benchmark();

    const zul = @import("zul");

    std.log.debug("aaaa", .{});

    (try zul.benchmark.run(indexOfScalar, .{})).print("indexOfScalar");
}

test "test allocators" {
    try test_utils.is_regular();

    var buf: [10]u8 = undefined;
    var never_free = IncreaseNeverFreeAllocator.init(&buf, 2000);
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
    std.debug.print("60\n", .{});
}
