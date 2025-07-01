const std = @import("std");

// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Test options
    const test_is_benchmark = b.option(bool, "test_is_benchmark", "Run tests with benchmarks") orelse false;
    const test_only_benchmarks = b.option(bool, "test_only_benchmarks", "Run only benchmarks") orelse false;
    const test_benchmark_secs = b.option(usize, "test_benchmark_secs", "Run each benchmark for this duration") orelse 5;

    const test_options = b.addOptions();
    test_options.addOption(bool, "is_benchmark", test_is_benchmark);
    test_options.addOption(bool, "only_benchmarks", test_only_benchmarks);
    test_options.addOption(usize, "benchmark_secs", test_benchmark_secs);

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = if (test_is_benchmark or test_only_benchmarks) .ReleaseFast else b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tree_sitter = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("tree-sitter", tree_sitter.module("tree-sitter"));

    const tree_sitter_python = b.dependency("tree-sitter-python", .{});
    const tree_sitter_python_lib = tree_sitter_python.builder.addStaticLibrary(.{
        .name = "tree-sitter-python",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tree_sitter_python_lib.addIncludePath(tree_sitter_python.path("src"));
    tree_sitter_python_lib.addCSourceFile(.{
        .file = tree_sitter_python.path("src/parser.c"),
    });
    tree_sitter_python_lib.addCSourceFile(.{
        .file = tree_sitter_python.path("src/scanner.c"),
    });
    lib_mod.linkLibrary(tree_sitter_python_lib);

    const lsp_codegen = b.dependency("lsp_codegen", .{
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("lsp", lsp_codegen.module("lsp"));

    lib_mod.addImport("zul", b.dependency("zul", .{}).module("zul"));

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("pyimportls_lib", lib_mod);
    exe_mod.addImport("zul", b.dependency("zul", .{}).module("zul"));

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    // const lib = b.addLibrary(.{
    //     .linkage = .static,
    //     .name = "pyimportls",
    //     .root_module = lib_mod,
    // });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    // b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "pyimportls",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    lib_mod.addOptions("test_options", test_options);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    lib_unit_tests.root_module.addOptions("config", test_options);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    // add a step for zls build on save
    const check_step = b.step("check", "Check if it compiles with unit tests");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&lib_unit_tests.step);
    check_step.dependOn(&exe_unit_tests.step);
}
