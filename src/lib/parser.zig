const std = @import("std");
const testing = std.testing;

const ts = @import("tree-sitter");

const test_utils = @import("test_utils.zig");

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
    try test_utils.is_regular();

    const language = tree_sitter_python();
    defer language.destroy();

    try testing.expectEqual(14, language.abiVersion());
}
