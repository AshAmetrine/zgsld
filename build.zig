const std = @import("std");
const build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const sem_ver = try std.SemanticVersion.parse(build_zon.version);
    const version_str = try getVersionStr(b, "zgsld", sem_ver);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const service_name = b.option([]const u8, "service-name","Set PAM service name") orelse "zgsld";
    const greeter_user = b.option([]const u8, "greeter-user","User that runs the greeter") orelse "greeter";
   
    const build_options = b.addOptions();
    build_options.addOption(bool, "standalone", false);
    build_options.addOption([]const u8, "version", version_str);
    build_options.addOption([]const u8, "service_name", service_name);
    build_options.addOption([]const u8, "greeter_user", greeter_user);

    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });

    const ipc_mod = b.addModule("ipc", .{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zgsld",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "ipc", .module = ipc_mod },
            },
            .link_libc = true,
        }),
    });

    exe.linkSystemLibrary("pam");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "ipc", .module = ipc_mod },
            },
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

pub const StandaloneOpts = struct {
    name: []const u8,
    root_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn makeStandalone(b: *std.Build, opts: StandaloneOpts) *std.Build.Step.Compile {
    const zgsld = b.dependencyFromBuildZig(@This(),.{});
    const target = opts.target;
    const optimize = opts.optimize;
    
    const build_options = b.addOptions();
    build_options.addOption(bool, "standalone", true);
    
    const ipc_mod = b.addModule("ipc", .{
        .root_source_file = zgsld.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = b.createModule(.{
            .root_source_file = zgsld.path("src/standalone.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "ipc", .module = ipc_mod },
            },
            .link_libc = true,
        }),
    });
    exe.linkSystemLibrary("pam");
        
    opts.root_module.addImport("zgipc",ipc_mod);
    exe.root_module.addImport("greeter", opts.root_module);

    return exe;
}

fn getVersionStr(b: *std.Build, name: []const u8, version: std.SemanticVersion) ![]const u8 {
    const version_str = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });

    var status: u8 = undefined;
    const git_describe_raw = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "describe",
        "--match",
        "*.*.*",
        "--tags",
    }, &status, .Ignore) catch {
        return version_str;
    };
    var git_describe = std.mem.trim(u8, git_describe_raw, " \n\r");
    git_describe = std.mem.trimLeft(u8, git_describe, "v");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            if (!std.mem.eql(u8, version_str, git_describe)) {
                std.debug.print("{s} version '{s}' does not match git tag: '{s}'\n", .{ name, version_str, git_describe });
                std.process.exit(1);
            }
            return version_str;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = std.mem.trimLeft(u8, it.first(), "v");
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
            if (version.order(ancestor_ver) != .gt) {
                std.debug.print("{s} version '{f}' must be greater than tagged ancestor '{f}'\n", .{ name, version, ancestor_ver });
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                return version_str;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_str, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version_str;
        },
    }
}
