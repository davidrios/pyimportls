const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ts = @import("tree-sitter");

const allocators = @import("allocators.zig");
const test_utils = @import("test_utils.zig");

extern fn tree_sitter_python() callconv(.C) *const ts.Language;

const SymbolType = enum {
    class,
    function,
    variable,
};

const SymbolList = std.ArrayListUnmanaged(struct { stype: SymbolType, name: []const u8 });

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

    pub fn getExportedSymbols(self: *Self, allocator: Allocator) !SymbolList {
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
                            .stype = if (node_kind == class_id) .class else .function,
                            .name = self.buffer[child.startByte()..child.endByte()],
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
                            try list.append(allocator, .{
                                .stype = .variable,
                                .name = self.buffer[left.startByte()..left.endByte()],
                            });
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

const PARENT_DIR = (".." ++ std.fs.path.sep_str)[0..3];
const PARENT_DIR_LEN = 3;

/// The returned string is allocated and owned by the called
pub fn getModulePath(allocator: Allocator, fpath: []const u8) ![]const u8 {
    if (!std.mem.endsWith(u8, fpath, ".py")) {
        return error.NotPyFile;
    }

    // std.log.debug("trying {s}", .{fpath});
    const dir_name = std.fs.path.dirname(fpath) orelse return error.ErrorOpeningDir;
    var dir = try std.fs.cwd().openDir(dir_name, .{});
    defer dir.close();

    var parts = std.ArrayListUnmanaged([]const u8){};
    defer parts.deinit(allocator);

    var level: usize = 0;
    var pathSlices = std.mem.splitBackwardsScalar(u8, fpath, std.fs.path.sep);
    var parents: [8192:0]u8 = .{0} ** 8192;

    while (pathSlices.next()) |pathSlice| {
        if (level == 0) {
            if (!std.mem.eql(u8, pathSlice, "__init__.py")) {
                try parts.append(allocator, pathSlice[0 .. pathSlice.len - 3]);
            }
        } else {
            const parents_slice = parents[0 .. PARENT_DIR_LEN * (level - 1)];
            const parents_init = if (parents_slice.len == 0)
                try std.mem.concat(allocator, u8, &.{ ".", std.fs.path.sep_str, "__init__.py" })
            else
                try std.mem.concat(allocator, u8, &.{ parents_slice, "__init__.py" });
            defer allocator.free(parents_init);
            // std.log.debug("{s}", .{parents_init});

            dir.access(parents_init, .{}) catch break;
            try parts.append(allocator, pathSlice);
            @memcpy(parents[PARENT_DIR_LEN * (level - 1) .. (PARENT_DIR_LEN * (level - 1)) + PARENT_DIR_LEN], PARENT_DIR);
        }
        level += 1;
    }

    std.mem.reverse([]const u8, parts.items);

    return std.mem.join(allocator, ".", parts.items);
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
    "testfixtures/testproject/.venv/lib/python3.12/site-packages/split.py",
};

test "test getModulePath returns correct value" {
    const allocator = testing.allocator;
    {
        const module_path = try getModulePath(allocator, test_targets[0]);
        defer allocator.free(module_path);
        try testing.expectEqualStrings("html2text.config", module_path);
    }
    {
        const module_path = try getModulePath(allocator, test_targets[1]);
        defer allocator.free(module_path);
        try testing.expectEqualStrings("dns.rdtypes.tlsabase", module_path);
    }
    {
        const module_path = try getModulePath(allocator, test_targets[2]);
        defer allocator.free(module_path);
        try testing.expectEqualStrings("pandas.tests.arithmetic.test_object", module_path);
    }
    {
        const module_path = try getModulePath(allocator, test_targets[3]);
        defer allocator.free(module_path);
        try testing.expectEqualStrings("botocore.compat", module_path);
    }
    {
        const module_path = try getModulePath(allocator, test_targets[5]);
        defer allocator.free(module_path);
        try testing.expectEqualStrings("django.conf.locale.cs", module_path);
    }
    {
        const module_path = try getModulePath(allocator, test_targets[6]);
        defer allocator.free(module_path);
        try testing.expectEqualStrings("faker.providers.company.hr_HR", module_path);
    }
    {
        const module_path = try getModulePath(allocator, test_targets[7]);
        defer allocator.free(module_path);
        try testing.expectEqualStrings("split", module_path);
    }
}

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
        std.log.debug("{}:{s}", .{ item.stype, item.name });
    }
}
