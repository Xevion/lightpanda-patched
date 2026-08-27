//! CLI over `patch.zig`: applies the CDP Mozilla User-Agent patch to a
//! lightpanda-io/browser checkout, or reports whether it still applies.
//!
//! Usage: patch [--check] [--json] [--quiet] <path-to-lightpanda-checkout>
//!        patch --targets
//!
//!   --check    Report per-site status without writing anything.
//!   --json     Emit the report as JSON on stdout instead of a table.
//!   --quiet    Suppress the report; rely on the exit code.
//!   --targets  Print the files this tool touches, one per line, and exit.
//!              Scripts that stage a checkout ask for the list rather than
//!              keeping their own copy of it.
//!
//! Exit codes: 0 every site applied, 1 one or more sites failed to match,
//! 2 bad usage or an I/O failure. `--check` is what lets CI and the history
//! audit ask "does this still apply?" without paying for a build.

const std = @import("std");
const patch = @import("patch.zig");

const Options = struct {
    root: []const u8,
    check: bool = false,
    json: bool = false,
    quiet: bool = false,
    targets: bool = false,
};

fn parseArgs(args: *std.process.Args.Iterator) ?Options {
    var root: ?[]const u8 = null;
    var check = false;
    var json = false;
    var quiet = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--targets")) {
            return .{ .root = "", .targets = true };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("unknown flag: {s}", .{arg});
            return null;
        } else if (root != null) {
            std.log.err("expected a single checkout path, also got: {s}", .{arg});
            return null;
        } else {
            root = arg;
        }
    }

    return .{ .root = root orelse return null, .check = check, .json = json, .quiet = quiet };
}

fn writeTable(w: *std.Io.Writer, report: patch.Report) !void {
    var current: ?patch.Target = null;
    for (report.sites.items) |site| {
        if (current == null or current.? != site.target) {
            try w.print("{s}\n", .{site.target.relPath()});
            current = site.target;
        }
        const mark = switch (site.status) {
            .applied => "ok       ",
            .not_found => "MISSING  ",
            .ambiguous => "AMBIGUOUS",
        };
        try w.print("  {s}  {s}", .{ mark, site.name });
        if (site.status == .applied and site.edits > 1) {
            try w.print(" ({d} edits)", .{site.edits});
        }
        try w.writeAll("\n");
    }

    const failed = report.failures();
    if (failed == 0) {
        try w.print("\n{d} site(s) applied\n", .{report.sites.items.len});
    } else {
        try w.print("\n{d} of {d} site(s) did not match\n", .{ failed, report.sites.items.len });
    }
}

fn writeJson(w: *std.Io.Writer, report: patch.Report) !void {
    try w.writeAll("{\"sites\":[");
    for (report.sites.items, 0..) |site, i| {
        if (i != 0) try w.writeAll(",");
        try w.print(
            "{{\"file\":{f},\"site\":{f},\"status\":\"{s}\",\"edits\":{d}}}",
            .{
                std.json.fmt(site.target.relPath(), .{}),
                std.json.fmt(site.name, .{}),
                @tagName(site.status),
                site.edits,
            },
        );
    }
    try w.print("],\"applied\":{d},\"failed\":{d}}}\n", .{
        report.sites.items.len - report.failures(),
        report.failures(),
    });
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const opts = parseArgs(&args) orelse {
        std.log.err("usage: patch [--check] [--json] [--quiet] <path-to-lightpanda-checkout>", .{});
        std.log.err("       patch --targets", .{});
        return 2;
    };

    if (opts.targets) {
        var buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
        for (patch.all_targets) |target| try stdout.interface.print("{s}\n", .{target.relPath()});
        try stdout.interface.flush();
        return 0;
    }

    var report = patch.Report.init(gpa);
    defer report.deinit();

    // Every target is patched into memory before anything is written, so a
    // later file failing to match can't leave the checkout half-patched.
    var outputs: [patch.all_targets.len][]u8 = undefined;
    var produced: usize = 0;
    defer for (outputs[0..produced]) |out| gpa.free(out);

    for (patch.all_targets) |target| {
        const path = try std.fs.path.join(gpa, &.{ opts.root, target.relPath() });
        defer gpa.free(path);

        const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(64 * 1024 * 1024), .of(u8), 0) catch |err| {
            std.log.err("failed to read {s}: {t}", .{ path, err });
            return 2;
        };
        defer gpa.free(source);

        outputs[produced] = patch.patchSource(gpa, target, source, &report) catch |err| {
            std.log.err("failed to patch {s}: {t}", .{ target.relPath(), err });
            return 2;
        };
        produced += 1;
    }

    if (!opts.quiet) {
        var buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
        if (opts.json) try writeJson(&stdout.interface, report) else try writeTable(&stdout.interface, report);
        try stdout.interface.flush();
    }

    if (report.failures() != 0) {
        if (!opts.check) {
            std.log.err("refusing to write a partial patch; upstream has drifted from what this tool matches", .{});
        }
        return 1;
    }

    if (opts.check) return 0;

    for (patch.all_targets, outputs[0..produced]) |target, out| {
        const path = try std.fs.path.join(gpa, &.{ opts.root, target.relPath() });
        defer gpa.free(path);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out }) catch |err| {
            std.log.err("failed to write {s}: {t}", .{ path, err });
            return 2;
        };
    }

    return 0;
}
