const std = @import("std");
const testing = std.testing;

const ts = @import("tree-sitter");

const allocators = @import("allocators.zig");
const test_utils = @import("test_utils.zig");

extern fn tree_sitter_python() callconv(.C) *const ts.Language;

const SymbolType = enum {
    class,
    function,
    variable,
};

const SymbolList = std.ArrayListUnmanaged(struct { SymbolType, []const u8 });

pub const Parsed = struct {
    buffer: []const u8,
    language: *const ts.Language,
    parser: *ts.Parser,
    tree: *ts.Tree,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.language.destroy();
        self.parser.destroy();
        self.tree.destroy();
    }

    pub fn getExportedSymbols(self: *Self, allocator: std.mem.Allocator) !SymbolList {
        var list = SymbolList{};

        const module_id = self.language.idForNodeKind("module", true);
        const class_id = self.language.idForNodeKind("class_definition", true);
        const func_id = self.language.idForNodeKind("function_definition", true);
        const expr_id = self.language.idForNodeKind("expression_statement", true);
        const assign_id = self.language.idForNodeKind("assignment", true);
        const identifier_id = self.language.idForNodeKind("identifier", true);
        const decorated_definition_id = self.language.idForNodeKind("decorated_definition", true);

        const root = self.tree.rootNode();
        // std.log.debug("root: {} {d}", .{ root, root.childCount() });
        if (root.kindId() == module_id) {
            var cursor = root.walk();
            defer cursor.destroy();

            if (!cursor.gotoFirstChild()) {
                return list;
            }

            while (cursor.gotoNextSibling()) {
                var node = cursor.node();
                var node_kind = node.kindId();

                if (node_kind == decorated_definition_id) {
                    node = node.child(1) orelse return list;
                    node_kind = node.kindId();
                }

                std.log.debug("sibling: {}", .{node});

                if (node_kind == class_id or node_kind == func_id) {
                    if (node.namedChild(0)) |child| {
                        if (child.kindId() != identifier_id) {
                            continue;
                        }
                        try list.append(allocator, .{
                            if (node_kind == class_id) .class else .function,
                            self.buffer[child.startByte()..child.endByte()],
                        });
                    }
                } else if (node_kind == expr_id) {
                    if (node.child(0)) |child| {
                        if (child.kindId() != assign_id) {
                            continue;
                        }

                        if (child.namedChild(0)) |left| {
                            if (left.kindId() != identifier_id) {
                                continue;
                            }
                            try list.append(allocator, .{ .variable, self.buffer[left.startByte()..left.endByte()] });
                        }
                    }
                }
            }
        }
        return list;
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
        return .{ .buffer = buffer, .language = language, .parser = parser, .tree = tree };
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

const test_targets = .{
    "testfixtures/testproject/.venv/lib/python3.12/site-packages/html2text/config.py",
    "testfixtures/testproject/.venv/lib/python3.12/site-packages/dns/rdtypes/tlsabase.py",
    "testfixtures/testproject/.venv/lib/python3.12/site-packages/pandas/tests/arithmetic/test_object.py",
    "testfixtures/testproject/.venv/lib/python3.12/site-packages/botocore/compat.py",
    "testfixtures/testproject/.venv/lib/python3.12/site-packages/virtualenv/create/via_global_ref/builtin/cpython/cpython3.py",
    "testfixtures/testproject/.venv/lib/python3.12/site-packages/django/conf/locale/cs/__init__.py",
    "testfixtures/testproject/.venv/lib/python3.12/site-packages/faker/providers/company/hr_HR/__init__.py",
};

test "test html2text/config.py" {
    try test_utils.is_regular();

    const allocator = testing.allocator;

    const file = try std.fs.cwd().openFile(test_targets[3], .{});
    defer file.close();

    const buf = try file.readToEndAlloc(allocator, 99 * allocators.mb_to_bytes);
    defer allocator.free(buf);

    var parsed = try parse(buf);
    defer parsed.deinit();

    var symbols = try parsed.getExportedSymbols(allocator);
    defer symbols.deinit(allocator);

    for (symbols.items) |item| {
        std.log.debug("{}:{s}", .{ item.@"0", item.@"1" });
    }
}
