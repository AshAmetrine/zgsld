const std = @import("std");
const build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const sem_ver = try std.SemanticVersion.parse(build_zon.version);
    const version_str = try getVersionStr(b, "zgsld", sem_ver);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const standalone_opt = b.option(bool, "standalone", "Build standalone greeter + session manager") orelse false;
    if (b.pkg_hash.len == 0 and standalone_opt) {
        std.log.warn("zgsld: ignoring -Dstandalone=true for top-level builds (library-only option)", .{});
    }
    const standalone = if (b.pkg_hash.len == 0) false else standalone_opt;

    const service_name = b.option([]const u8, "service-name", "Set PAM service name") orelse "login";
    const greeter_user = b.option([]const u8, "greeter-user", "User that runs the greeter") orelse "greeter";
    const greeter_service_name = b.option([]const u8, "greeter_service_name", "PAM service used to open a greeter session") orelse service_name;

    const x11_enabled = b.option(bool, "x11", "Enable X11 session support") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "standalone", standalone);
    build_options.addOption([]const u8, "version", version_str);
    build_options.addOption([]const u8, "service_name", service_name);
    build_options.addOption([]const u8, "greeter_user", greeter_user);
    build_options.addOption([]const u8, "greeter_service_name", greeter_service_name);
    build_options.addOption(?u8, "vt", null);
    build_options.addOption(bool, "x11_support", x11_enabled);
    const build_options_mod = build_options.createModule();

    const pam = b.dependency("pam", .{ .target = target, .optimize = optimize });
    const ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zgsld_mod = b.addModule("zgsld", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "ipc", .module = ipc_mod },
            .{ .name = "pam", .module = pam.module("pam") },
        },
    });

    const test_step = b.step("test", "Run all tests.");
    const tests = b.addTest(.{ .root_module = zgsld_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const docs_obj = b.addObject(.{
        .name = "root",
        .root_module = zgsld_mod,
    });
    const docs_install = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs_install.step);

    const fmt_step = b.step("fmt", "Format source files");
    const fmt_cmd = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src" } });
    fmt_step.dependOn(&fmt_cmd.step);

    if (b.pkg_hash.len == 0) {
        const clap = b.lazyDependency("clap", .{ .target = target, .optimize = optimize }) orelse return;
        const zigini = b.lazyDependency("zigini", .{ .target = target, .optimize = optimize }) orelse return;

        const exe = b.addExecutable(.{
            .name = "zgsld",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "build_options", .module = build_options_mod },
                    .{ .name = "clap", .module = clap.module("clap") },
                    .{ .name = "ipc", .module = ipc_mod },
                    .{ .name = "zigini", .module = zigini.module("zigini") },
                    .{ .name = "pam", .module = pam.module("pam") },
                },
                .link_libc = true,
            }),
        });

        b.installArtifact(exe);
    }
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
