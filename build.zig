const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const i18n_generator = b.addExecutable(.{
        .name = "i18n-generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/i18n_gen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const render_i18n = b.addRunArtifact(i18n_generator);
    render_i18n.addFileArg(b.path("src/web/index.html.in"));
    render_i18n.addFileArg(b.path("src/web/locales/pl.json"));
    render_i18n.addFileArg(b.path("src/web/locales/en.json"));
    const i18n_source = render_i18n.addOutputFileArg("i18n.zig");
    const i18n_module = b.createModule(.{
        .root_source_file = i18n_source,
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "szklana-pogoda",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("i18n", i18n_module);
    exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
    if (target.result.os.tag == .macos) exe.root_module.linkSystemLibrary("proc", .{});
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("i18n", i18n_module);
    tests.root_module.addImport("sqlite", sqlite.module("sqlite"));
    if (target.result.os.tag == .macos) tests.root_module.linkSystemLibrary("proc", .{});
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const i18n_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/i18n_gen.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_i18n_tests = b.addRunArtifact(i18n_tests);
    test_step.dependOn(&run_i18n_tests.step);
}
