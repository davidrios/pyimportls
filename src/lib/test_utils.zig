const std = @import("std");

const test_options = @import("test_options");
const zul = @import("zul");

pub fn is_regular() !void {
    if (test_options.only_benchmarks or !std.mem.eql(u8, test_options.single_benchmark, "")) {
        return error.SkipZigTest;
    }
}

pub const default_benchmark_options = zul.benchmark.Opts{ .runtime = test_options.benchmark_secs * std.time.ms_per_s };

pub fn is_benchmark(name: []const u8) !void {
    if (!(test_options.is_benchmark or test_options.only_benchmarks or
        (!std.mem.eql(u8, test_options.single_benchmark, "") and std.mem.eql(u8, name, test_options.single_benchmark))))
    {
        return error.SkipZigTest;
    }
}
