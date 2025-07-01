const test_options = @import("test_options");

pub fn is_regular() !void {
    if (test_options.only_benchmarks) {
        return error.SkipZigTest;
    }
}

pub fn is_benchmark() !void {
    if (!test_options.is_benchmark and !test_options.only_benchmarks) {
        return error.SkipZigTest;
    }
}
