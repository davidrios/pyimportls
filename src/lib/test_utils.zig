const std = @import("std");

const test_options = @import("test_options");
const zul = @import("zul");

pub fn is_regular() !void {
    if (test_options.only_benchmarks) {
        return error.SkipZigTest;
    }
}

pub const default_benchmark_options = zul.benchmark.Opts{ .runtime = test_options.benchmark_secs * std.time.ms_per_s };

pub fn is_benchmark() !void {
    if (!test_options.is_benchmark and !test_options.only_benchmarks) {
        return error.SkipZigTest;
    }
}
