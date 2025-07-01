const std = @import("std");
const testing = std.testing;

const test_options = @import("test_options");
const ts = @import("tree-sitter");

extern fn tree_sitter_python() callconv(.C) *const ts.Language;

pub const Parsed = struct {
    language: *const ts.Language,
    parser: *ts.Parser,
    tree: *ts.Tree,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.language.destroy();
        self.parser.destroy();
        self.tree.destroy();
    }
};

const Error = error{
    TreeNotFound,
};

pub fn parse(buffer: []const u8) !Parsed {
    const language = tree_sitter_python();
    errdefer language.destroy();

    const parser = ts.Parser.create();
    errdefer parser.destroy();

    try parser.setLanguage(language);

    if (parser.parseString(buffer, null)) |tree| {
        return .{ .language = language, .parser = parser, .tree = tree };
    } else {
        return Error.TreeNotFound;
    }
}

test "test ABI version" {
    if (test_options.only_benchmarks) {
        return error.SkipZigTest;
    }

    const language = tree_sitter_python();
    defer language.destroy();

    try testing.expectEqual(14, language.abiVersion());
}
