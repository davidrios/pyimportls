const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const ts = @import("tree-sitter");

const allocators = @import("allocators.zig");
const test_utils = @import("test_utils.zig");

extern fn tree_sitter_python() callconv(.C) *const ts.Language;

const Error = error{
    TreeNotFound,
    NotInitialized,
    NotPyFile,
    ErrorOpeningDir,
};

const SymbolType = enum {
    class,
    function,
    variable,
};

const SymbolList = std.ArrayListUnmanaged(struct { stype: SymbolType, name: []const u8 });

fn debugNode(node: *const ts.Node, base: []const u8, buf: []const u8) void {
    std.log.debug("{s}: {}, {s}", .{ base, node, buf[node.startByte()..@min(node.endByte(), node.startByte() + 20)] });
}

const NodeKindIdMap = struct {
    module: u16,
    class_definition: u16,
    function_definition: u16,
    expression: u16,
    assignment: u16,
    identifier: u16,
    decorated_definition: u16,
    block: u16,
    try_statement: u16,
    except_clause: u16,
    if_statement: u16,
    else_clause: u16,
    elif_clause: u16,
};

var node_kind_id_map: ?NodeKindIdMap = null;

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
        const idmap = node_kind_id_map orelse return Error.NotInitialized;

        var list = SymbolList{};
        const root = self.tree.rootNode();
        if (root.kindId() != idmap.module) {
            return list;
        }
        var cursor = root.walk();
        defer cursor.destroy();

        if (!cursor.gotoFirstChild()) {
            std.log.debug("no first child", .{});
            return list;
        }

        try self.getExportedSymbolsInner(allocator, &cursor, &list);

        return list;
    }

    fn getExportedSymbolsInner(self: *Self, allocator: Allocator, cursor: *ts.TreeCursor, list: *SymbolList) !void {
        const idmap = node_kind_id_map orelse return Error.NotInitialized;

        std.log.debug("first node: {}", .{cursor.node()});
        var is_first = true;

        while (is_first or cursor.gotoNextSibling()) {
            is_first = false;
            var node = cursor.node();
            var node_kind = node.kindId();

            if (node_kind == idmap.block or
                node_kind == idmap.if_statement or
                node_kind == idmap.else_clause or
                node_kind == idmap.elif_clause or
                node_kind == idmap.try_statement or
                node_kind == idmap.except_clause)
            {
                if (std.log.defaultLogEnabled(std.log.Level.debug)) {
                    debugNode(&node, "entering", self.buffer);
                }
                std.debug.assert(cursor.gotoFirstChild());

                try self.getExportedSymbolsInner(allocator, cursor, list);
                if (cursor.gotoParent()) {
                    if (std.log.defaultLogEnabled(std.log.Level.debug)) {
                        debugNode(&cursor.node(), "exiting", self.buffer);
                    }
                }
                continue;
            }

            if (node_kind == idmap.decorated_definition) {
                node = node.child(1) orelse return;
                node_kind = node.kindId();
            }

            std.log.debug("sibling: {}", .{node});

            if (node_kind == idmap.class_definition or node_kind == idmap.function_definition) {
                if (node.namedChild(0)) |child| {
                    if (child.kindId() != idmap.identifier) {
                        continue;
                    }
                    const name = self.buffer[child.startByte()..child.endByte()];
                    if (std.mem.startsWith(u8, name, "_")) {
                        continue;
                    }
                    std.log.debug("found symbol: {s}", .{name});
                    try list.append(allocator, .{
                        .stype = if (node_kind == idmap.class_definition) .class else .function,
                        .name = name,
                    });
                }
            } else if (node_kind == idmap.expression) {
                if (node.child(0)) |child| {
                    if (child.kindId() != idmap.assignment) {
                        continue;
                    }

                    if (child.namedChild(0)) |left| {
                        if (left.kindId() != idmap.identifier) {
                            continue;
                        }
                        const name = self.buffer[left.startByte()..left.endByte()];
                        if (std.mem.startsWith(u8, name, "_")) {
                            continue;
                        }
                        std.log.debug("found symbol: {s}", .{name});
                        try list.append(allocator, .{
                            .stype = .variable,
                            .name = name,
                        });
                    }
                }
            }
        }
    }
};

pub fn parse(buffer: []const u8) !Parsed {
    const language = tree_sitter_python();
    errdefer language.destroy();

    const parser = ts.Parser.create();
    errdefer parser.destroy();

    try parser.setLanguage(language);

    node_kind_id_map = NodeKindIdMap{
        .module = language.idForNodeKind("module", true),
        .class_definition = language.idForNodeKind("class_definition", true),
        .function_definition = language.idForNodeKind("function_definition", true),
        .expression = language.idForNodeKind("expression_statement", true),
        .assignment = language.idForNodeKind("assignment", true),
        .identifier = language.idForNodeKind("identifier", true),
        .decorated_definition = language.idForNodeKind("decorated_definition", true),
        .block = language.idForNodeKind("block", true),
        .try_statement = language.idForNodeKind("try_statement", true),
        .except_clause = language.idForNodeKind("except_clause", true),
        .if_statement = language.idForNodeKind("if_statement", true),
        .else_clause = language.idForNodeKind("else_clause", true),
        .elif_clause = language.idForNodeKind("elif_clause", true),
    };

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
        return Error.NotPyFile;
    }

    // std.log.debug("trying {s}", .{fpath});
    const dir_name = std.fs.path.dirname(fpath) orelse return Error.ErrorOpeningDir;
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

fn expectAllSymbols(symbols: *const SymbolList, compare: []const []const u8) !void {
    var results_set = std.StringHashMap(void).init(testing.allocator);
    defer results_set.deinit();
    for (symbols.items) |symbol| {
        try results_set.put(symbol.name, {});
    }
    for (compare) |compare_item| {
        try testing.expect(results_set.contains(compare_item));
    }
}

test "test getExportedSymbols" {
    try test_utils.is_regular();

    const allocator = testing.allocator;

    const file = try std.fs.cwd().openFile("testfixtures/test_symbols.py", .{});
    defer file.close();

    const buf = try file.readToEndAlloc(allocator, 99 * allocators.mb_to_bytes);
    defer allocator.free(buf);

    var parsed = try parse(buf);
    defer parsed.deinit();

    var symbols = try parsed.getExportedSymbols(allocator);
    defer symbols.deinit(allocator);

    try expectAllSymbols(&symbols, &.{
        "test",
        "logger",
        "HTTPHeaders",
        "file_type",
        "zip",
        "accepts_kwargs",
        "from_dict",
        "MD5_AVAILABLE",
        "MD5_AVAILABLE",
        "disabled",
        "HAS_CRT",
        "HAS_CRT",
        "XXXX",
        "LS32_PAT",
        "HAS_GZIP",
        "HAS_GZIP",
        "HAS_GZIP2",
        "DDDDDD",
        "CCCC",
        "ZZZ",
        "ZZZ",
        "ZZZZ",
        "VVV",
        "XXX",
        "SSS",
        "AA",
        "BBB",
    });
}
