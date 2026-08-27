//! Structurally patches a vendored lightpanda-io/browser checkout to allow
//! Mozilla-style CDP User-Agent overrides, using std.zig.Ast (the same parser
//! `zig fmt` is built on) instead of a hand-maintained unified diff.
//!
//! Each site is located by AST shape and/or unique literal content (a
//! function name, a test name, an error tag), not by line number, so the
//! patch survives upstream reformatting or unrelated nearby edits. Every
//! site is required to be found; a missing site fails loudly instead of
//! silently doing nothing, since upstream may have changed the code we key
//! on.
//!
//! Usage: zig run tools/patch/main.zig -- <path-to-lightpanda-checkout>

const std = @import("std");
const Ast = std.zig.Ast;

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

/// Byte offsets of a node's full source span, exactly matching
/// `Ast.getNodeSource`'s own [start, end) computation.
fn nodeSpan(tree: Ast, node: Ast.Node.Index) struct { start: usize, end: usize } {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return .{ .start = start, .end = end };
}

/// Walk a deletion's start backward over the node's own leading indentation
/// and any fully-blank lines directly above it, so removing a statement
/// doesn't leave a stray blank/whitespace-only line behind.
fn extendBeforeBlankLines(source: []const u8, start_in: usize) usize {
    var start = start_in;
    while (start > 0 and (source[start - 1] == ' ' or source[start - 1] == '\t')) start -= 1;
    while (start > 0 and source[start - 1] == '\n') {
        var line_start = start - 1;
        while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
        for (source[line_start .. start - 1]) |c| {
            if (c != ' ' and c != '\t') return start;
        }
        start = line_start;
    }
    return start;
}

/// Walk a deletion's end forward past trailing whitespace, an optional
/// trailing comma (switch prongs), and the line's own newline.
fn extendPastTrailingComma(source: []const u8, end_in: usize) usize {
    var end = end_in;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    if (end < source.len and source[end] == ',') end += 1;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    if (end < source.len and source[end] == '\n') end += 1;
    return end;
}

fn deleteNode(edits: *std.ArrayList(Edit), gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) !void {
    const span = nodeSpan(tree, node);
    const start = extendBeforeBlankLines(tree.source, span.start);
    const end = extendPastTrailingComma(tree.source, span.end);
    try edits.append(gpa, .{ .start = start, .end = end, .replacement = "" });
}

fn replaceNode(edits: *std.ArrayList(Edit), gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, replacement: []const u8) !void {
    const span = nodeSpan(tree, node);
    try edits.append(gpa, .{ .start = span.start, .end = span.end, .replacement = replacement });
}

/// Queue a within-node text substitution. `needle` must occur exactly once in
/// the node's source (checked), so drift in the surrounding test body is
/// caught rather than silently mismatched.
fn replaceOnceInNode(edits: *std.ArrayList(Edit), gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, needle: []const u8, replacement: []const u8) !void {
    const span = nodeSpan(tree, node);
    const body = tree.source[span.start..span.end];

    const first = std.mem.indexOf(u8, body, needle) orelse {
        std.log.err("expected to find {s} within node span [{d}, {d})", .{ needle, span.start, span.end });
        return error.PatchSiteNotFound;
    };
    if (std.mem.indexOf(u8, body[first + needle.len ..], needle) != null) {
        std.log.err("{s} occurs more than once within node span [{d}, {d})", .{ needle, span.start, span.end });
        return error.PatchSiteAmbiguous;
    }

    try edits.append(gpa, .{
        .start = span.start + first,
        .end = span.start + first + needle.len,
        .replacement = replacement,
    });
}

fn applyEdits(gpa: std.mem.Allocator, source: []const u8, edits: []const Edit) ![]u8 {
    const sorted = try gpa.dupe(Edit, edits);
    defer gpa.free(sorted);
    std.mem.sort(Edit, sorted, {}, struct {
        fn lessThan(_: void, a: Edit, b: Edit) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var cursor: usize = 0;
    for (sorted, 0..) |edit, i| {
        if (edit.start < cursor) {
            std.log.err("edit {d} at [{d}, {d}) overlaps the previous edit ending at {d}", .{ i, edit.start, edit.end, cursor });
            return error.OverlappingEdits;
        }
        try out.appendSlice(gpa, source[cursor..edit.start]);
        try out.appendSlice(gpa, edit.replacement);
        cursor = edit.end;
    }
    try out.appendSlice(gpa, source[cursor..]);
    return out.toOwnedSlice(gpa);
}

fn findIfSimpleByContent(tree: Ast, cond_needle: []const u8, then_needle: []const u8) ?Ast.Node.Index {
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .if_simple) continue;
        const node: Ast.Node.Index = @enumFromInt(i);
        const full = tree.fullIf(node) orelse continue;
        const cond_src = tree.getNodeSource(full.ast.cond_expr);
        const then_src = tree.getNodeSource(full.ast.then_expr);
        if (std.mem.indexOf(u8, cond_src, cond_needle) != null and
            std.mem.indexOf(u8, then_src, then_needle) != null)
        {
            return node;
        }
    }
    return null;
}

fn findSwitchCaseByValue(tree: Ast, value_needle: []const u8) ?Ast.Node.Index {
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, i| {
        switch (tag) {
            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {},
            else => continue,
        }
        const node: Ast.Node.Index = @enumFromInt(i);
        const case = tree.fullSwitchCase(node) orelse continue;
        if (case.ast.values.len != 1) continue;
        const value_src = tree.getNodeSource(case.ast.values[0]);
        if (std.mem.eql(u8, value_src, value_needle)) {
            return node;
        }
    }
    return null;
}

fn findTestByNameSubstring(tree: Ast, needle: []const u8) ?Ast.Node.Index {
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .test_decl) continue;
        const node: Ast.Node.Index = @enumFromInt(i);
        const name_tok = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue;
        const name_raw = tree.tokenSlice(name_tok);
        if (std.mem.indexOf(u8, name_raw, needle) != null) {
            return node;
        }
    }
    return null;
}

fn readFileZ(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(64 * 1024 * 1024), .of(u8), 0);
}

fn parseChecked(gpa: std.mem.Allocator, source: [:0]const u8, path: []const u8) !Ast {
    var tree = try Ast.parse(gpa, source, .zig);
    if (tree.errors.len != 0) {
        std.log.err("{s} has {d} parse error(s) before patching; refusing to touch it", .{ path, tree.errors.len });
        tree.deinit(gpa);
        return error.SourceHasParseErrors;
    }
    return tree;
}

/// Re-parses the edited source to confirm the splice produced valid Zig
/// before it's written to disk.
fn validate(gpa: std.mem.Allocator, source: [:0]const u8, path: []const u8) !void {
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        std.log.err("{s} has {d} parse error(s) after patching; the edit produced invalid Zig", .{ path, tree.errors.len });
        return error.PatchProducedInvalidSource;
    }
}

fn patchFile(gpa: std.mem.Allocator, io: std.Io, root: []const u8, rel_path: []const u8, buildEdits: fn (std.mem.Allocator, Ast, *std.ArrayList(Edit)) anyerror!void) !void {
    const path = try std.fs.path.join(gpa, &.{ root, rel_path });
    defer gpa.free(path);

    const source = try readFileZ(gpa, io, path);
    defer gpa.free(source);

    var tree = try parseChecked(gpa, source, rel_path);
    defer tree.deinit(gpa);

    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(gpa);
    try buildEdits(gpa, tree, &edits);

    const patched = try applyEdits(gpa, source, edits.items);
    defer gpa.free(patched);

    const patched_z = try gpa.dupeZ(u8, patched);
    defer gpa.free(patched_z);
    try validate(gpa, patched_z, rel_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = patched });
    std.log.info("{s}: applied {d} edit(s)", .{ rel_path, edits.items.len });
}

fn configZigEdits(gpa: std.mem.Allocator, tree: Ast, edits: *std.ArrayList(Edit)) !void {
    const if_node = findIfSimpleByContent(tree, "\"mozilla\"", "error.Reserved") orelse {
        std.log.err("Config.zig: couldn't find the `indexOfIgnoreCase(ua, \"mozilla\") -> error.Reserved` guard in validateUserAgent", .{});
        return error.PatchSiteNotFound;
    };
    try deleteNode(edits, gpa, tree, if_node);

    const refuses_test = findTestByNameSubstring(tree, "parseArgs refuses a mozilla user-agent") orelse {
        std.log.err("Config.zig: couldn't find the \"parseArgs refuses a mozilla user-agent\" test", .{});
        return error.PatchSiteNotFound;
    };
    try deleteNode(edits, gpa, tree, refuses_test);

    const validate_test = findTestByNameSubstring(tree, "Config: validateUserAgent") orelse {
        std.log.err("Config.zig: couldn't find the \"Config: validateUserAgent\" test", .{});
        return error.PatchSiteNotFound;
    };
    try replaceOnceInNode(
        edits,
        gpa,
        tree,
        validate_test,
        "try std.testing.expectError(error.Reserved, validateUserAgent(\"mozilla/1.0\"));",
        "try validateUserAgent(\"mozilla/1.0\");",
    );
    try replaceOnceInNode(
        edits,
        gpa,
        tree,
        validate_test,
        "try std.testing.expectError(error.Reserved, validateUserAgent(\"Mozilla/5.0\"));",
        "try validateUserAgent(\"Mozilla/5.0\");",
    );
}

fn emulationZigEdits(gpa: std.mem.Allocator, tree: Ast, edits: *std.ArrayList(Edit)) !void {
    const case_node = findSwitchCaseByValue(tree, "error.Reserved") orelse {
        std.log.err("emulation.zig: couldn't find the `error.Reserved =>` switch prong in setUserAgentOverride", .{});
        return error.PatchSiteNotFound;
    };
    try deleteNode(edits, gpa, tree, case_node);

    inline for (.{
        .{ .needle = "ignores mozilla case insensitive", .id = "3" },
        .{ .needle = "ignores mozilla", .id = "2" },
    }) |t| {
        const node = findTestByNameSubstring(tree, t.needle) orelse {
            std.log.err("emulation.zig: couldn't find the \"{s}\" test", .{t.needle});
            return error.PatchSiteNotFound;
        };
        try replaceOnceInNode(edits, gpa, tree, node, "ignores mozilla", "accepts mozilla");
        try replaceOnceInNode(edits, gpa, tree, node, "    testing.silenceLog(&.{.not_implemented});\n\n", "");
        try replaceOnceInNode(edits, gpa, tree, node, "try ctx.expectSentResult(null, .{});", "try ctx.expectSentResult(null, .{ .id = " ++ t.id ++ " });");
        try replaceOnceInNode(
            edits,
            gpa,
            tree,
            node,
            "try testing.expectEqual(false, ctx.cdp().browser_context.?.user_agent_changed);",
            "try testing.expectEqual(true, ctx.cdp().browser_context.?.user_agent_changed);",
        );
    }
}

fn networkZigEdits(gpa: std.mem.Allocator, tree: Ast, edits: *std.ArrayList(Edit)) !void {
    const node = findTestByNameSubstring(tree, "rejects a Mozilla User-Agent") orelse {
        std.log.err("network.zig: couldn't find the \"rejects a Mozilla User-Agent\" test", .{});
        return error.PatchSiteNotFound;
    };
    try replaceOnceInNode(edits, gpa, tree, node, "rejects a Mozilla User-Agent", "accepts a Mozilla User-Agent");
    try replaceOnceInNode(edits, gpa, tree, node, "    testing.silenceLog(&.{.cdp});\n\n", "");
    try replaceOnceInNode(
        edits,
        gpa,
        tree,
        node,
        "try testing.expectEqual(bc.extra_headers.items.len, 0);",
        "try testing.expectEqual(bc.extra_headers.items.len, 1);\n" ++
            "    try testing.expectEqual(\"User-Agent\", bc.extra_headers.items[0].name);\n" ++
            "    try testing.expectEqual(\"Mozilla/5.0\", bc.extra_headers.items[0].value);",
    );
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const root = args.next() orelse {
        std.log.err("usage: patch <path-to-lightpanda-checkout>", .{});
        return 1;
    };

    patchFile(gpa, io, root, "src/Config.zig", configZigEdits) catch |err| {
        std.log.err("failed to patch src/Config.zig: {t}", .{err});
        return 1;
    };
    patchFile(gpa, io, root, "src/cdp/domains/emulation.zig", emulationZigEdits) catch |err| {
        std.log.err("failed to patch src/cdp/domains/emulation.zig: {t}", .{err});
        return 1;
    };
    patchFile(gpa, io, root, "src/cdp/domains/network.zig", networkZigEdits) catch |err| {
        std.log.err("failed to patch src/cdp/domains/network.zig: {t}", .{err});
        return 1;
    };

    return 0;
}
