//! Structurally patches a lightpanda-io/browser checkout to allow Mozilla-style
//! CDP User-Agent overrides, editing matched `std.zig.Ast` nodes rather than
//! applying a stored unified diff.
//!
//! Every site is located by AST shape plus distinguishing literal content, and
//! every lookup must resolve to exactly one node. An anchor matching nothing,
//! or matching more than one node, is reported as a failed site rather than
//! guessed at. That strictness is load-bearing: upstream keeps sibling tests
//! whose names are prefixes of each other ("rejects a Mozilla User-Agent" and
//! "rejects a Mozilla User-Agent smuggled via a colon in the key"), and the
//! sibling asserts a header-smuggling rejection that must survive this patch.
//!
//! Replacement text is derived from the matched nodes wherever possible (the
//! response id, the receiver name, the asserted User-Agent) instead of being
//! hardcoded, and the patched source is re-parsed and re-rendered through the
//! renderer `zig fmt` is built on, so generated code carries no hand-managed
//! indentation and the output is formatted by construction.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Node = Ast.Node;

pub const Target = enum {
    config,
    emulation,
    network,

    pub fn relPath(self: Target) []const u8 {
        return switch (self) {
            .config => "src/Config.zig",
            .emulation => "src/cdp/domains/emulation.zig",
            .network => "src/cdp/domains/network.zig",
        };
    }
};

pub const all_targets = [_]Target{ .config, .emulation, .network };

pub const Status = enum { applied, not_found, ambiguous };

pub const SiteResult = struct {
    target: Target,
    name: []const u8,
    status: Status,
    edits: usize,
};

pub const Report = struct {
    gpa: Allocator,
    sites: std.ArrayList(SiteResult) = .empty,

    pub fn init(gpa: Allocator) Report {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Report) void {
        for (self.sites.items) |site| self.gpa.free(site.name);
        self.sites.deinit(self.gpa);
    }

    /// Site names are owned by the report: some are built per-run against a
    /// scratch arena that does not outlive the file being patched.
    fn record(self: *Report, target: Target, name: []const u8, status: Status, edits: usize) !void {
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.sites.append(self.gpa, .{
            .target = target,
            .name = owned,
            .status = status,
            .edits = edits,
        });
    }

    pub fn failures(self: Report) usize {
        var n: usize = 0;
        for (self.sites.items) |site| {
            if (site.status != .applied) n += 1;
        }
        return n;
    }

    pub fn ok(self: Report) bool {
        return self.sites.items.len != 0 and self.failures() == 0;
    }
};

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

const Span = struct { start: usize, end: usize };

/// A node's full source span, matching `Ast.getNodeSource`'s own computation.
fn nodeSpan(tree: Ast, node: Node.Index) Span {
    return tokenSpan(tree, tree.firstToken(node), tree.lastToken(node));
}

fn tokenSpan(tree: Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) Span {
    return .{
        .start = tree.tokenStart(first),
        .end = tree.tokenStart(last) + tree.tokenSlice(last).len,
    };
}

/// The span of the whole statement a node sits in: a leading `try` and the
/// terminating semicolon belong to the statement, not to the expression node.
fn statementSpan(tree: Ast, node: Node.Index) Span {
    var first = tree.firstToken(node);
    if (first > 0 and tree.tokenTag(first - 1) == .keyword_try) first -= 1;

    var last = tree.lastToken(node);
    if (last + 1 < tree.tokens.len and tree.tokenTag(last + 1) == .semicolon) last += 1;

    return tokenSpan(tree, first, last);
}

/// Walk a deletion's start backward over its own indentation and any blank
/// lines directly above, so removing a declaration leaves no whitespace-only
/// line behind.
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
fn extendPastLineEnd(source: []const u8, end_in: usize) usize {
    var end = end_in;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    if (end < source.len and source[end] == ',') end += 1;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    if (end < source.len and source[end] == '\n') end += 1;
    return end;
}

/// The result of an anchor lookup. `many` is a failure, not a "pick the first":
/// an ambiguous anchor means upstream grew a sibling we can't tell apart.
const Found = union(enum) {
    none,
    one: Node.Index,
    many,

    fn add(self: Found, node: Node.Index) Found {
        return switch (self) {
            .none => .{ .one = node },
            .one, .many => .many,
        };
    }
};

fn findTest(tree: Ast, name_needle: []const u8) Found {
    var found: Found = .none;
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .test_decl) continue;
        const node: Node.Index = @enumFromInt(i);
        const name_tok = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue;
        if (std.mem.indexOf(u8, tree.tokenSlice(name_tok), name_needle) != null) {
            found = found.add(node);
        }
    }
    return found;
}

fn findIfGuard(tree: Ast, cond_needle: []const u8, then_needle: []const u8) Found {
    var found: Found = .none;
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .if_simple) continue;
        const node: Node.Index = @enumFromInt(i);
        const full = tree.fullIf(node) orelse continue;
        if (std.mem.indexOf(u8, tree.getNodeSource(full.ast.cond_expr), cond_needle) != null and
            std.mem.indexOf(u8, tree.getNodeSource(full.ast.then_expr), then_needle) != null)
        {
            found = found.add(node);
        }
    }
    return found;
}

fn findSwitchCase(tree: Ast, value: []const u8) Found {
    var found: Found = .none;
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, i| {
        switch (tag) {
            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {},
            else => continue,
        }
        const node: Node.Index = @enumFromInt(i);
        const case = tree.fullSwitchCase(node) orelse continue;
        if (case.ast.values.len != 1) continue;
        if (std.mem.eql(u8, tree.getNodeSource(case.ast.values[0]), value)) {
            found = found.add(node);
        }
    }
    return found;
}

const Call = struct {
    node: Node.Index,
    params: []const Node.Index,
};

/// Every call inside `parent` whose callee source contains `fn_needle`, in
/// source order.
fn collectCalls(
    gpa: Allocator,
    tree: Ast,
    parent: Node.Index,
    fn_needle: []const u8,
    out: *std.ArrayList(Call),
) !void {
    const parent_span = nodeSpan(tree, parent);
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, i| {
        switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => {},
            else => continue,
        }
        const node: Node.Index = @enumFromInt(i);
        const span = nodeSpan(tree, node);
        if (span.start < parent_span.start or span.end > parent_span.end) continue;

        var buf: [1]Node.Index = undefined;
        const call = tree.fullCall(&buf, node) orelse continue;
        if (std.mem.indexOf(u8, tree.getNodeSource(call.ast.fn_expr), fn_needle) == null) continue;

        // fullCall's params alias a stack buffer for the *_one variants.
        const params = try gpa.dupe(Node.Index, call.ast.params);
        try out.append(gpa, .{ .node = node, .params = params });
    }
}

fn freeCalls(gpa: Allocator, calls: *std.ArrayList(Call)) void {
    for (calls.items) |call| gpa.free(call.params);
    calls.deinit(gpa);
}

/// The value of the first numeric `.id = N` field inside `parent`. The CDP
/// tests set the response id they expect in the request they send, so reading
/// it back beats hardcoding a number that upstream can renumber.
fn findNumericIdField(tree: Ast, parent: Node.Index) ?[]const u8 {
    const first = tree.firstToken(parent);
    const last = tree.lastToken(parent);
    var i = first;
    while (i + 3 <= last) : (i += 1) {
        if (tree.tokenTag(i) != .period) continue;
        if (tree.tokenTag(i + 1) != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(i + 1), "id")) continue;
        if (tree.tokenTag(i + 2) != .equal) continue;
        if (tree.tokenTag(i + 3) != .number_literal) continue;
        return tree.tokenSlice(i + 3);
    }
    return null;
}

/// The first string literal in `parent`'s body starting with `prefix`. The
/// test's own name token is skipped so a name mentioning the literal doesn't
/// shadow the one in the body.
fn findStringLiteral(tree: Ast, parent: Node.Index, prefix: []const u8) ?[]const u8 {
    const last = tree.lastToken(parent);
    var i = tree.firstToken(parent) + 1;
    while (i <= last) : (i += 1) {
        if (tree.tokenTag(i) != .string_literal) continue;
        const slice = tree.tokenSlice(i);
        if (slice.len >= 1 and std.mem.startsWith(u8, slice[1..], prefix)) return slice;
    }
    return null;
}

const Builder = struct {
    gpa: Allocator,
    arena: Allocator,
    tree: Ast,
    target: Target,
    edits: std.ArrayList(Edit) = .empty,
    report: *Report,

    fn deinit(self: *Builder) void {
        self.edits.deinit(self.gpa);
    }

    /// Resolve an anchor, recording a failed site when it doesn't resolve to
    /// exactly one node. Returning null lets the caller skip its edits and the
    /// run continue, so one broken anchor still yields a full report.
    fn anchor(self: *Builder, name: []const u8, found: Found) !?Node.Index {
        return switch (found) {
            .one => |node| node,
            .none => {
                try self.report.record(self.target, name, .not_found, 0);
                return null;
            },
            .many => {
                try self.report.record(self.target, name, .ambiguous, 0);
                return null;
            },
        };
    }

    fn applied(self: *Builder, name: []const u8, edits: usize) !void {
        try self.report.record(self.target, name, .applied, edits);
    }

    fn missing(self: *Builder, name: []const u8) !void {
        try self.report.record(self.target, name, .not_found, 0);
    }

    fn replaceSpan(self: *Builder, span: Span, replacement: []const u8) !void {
        try self.edits.append(self.gpa, .{
            .start = span.start,
            .end = span.end,
            .replacement = replacement,
        });
    }

    fn replaceNode(self: *Builder, node: Node.Index, replacement: []const u8) !void {
        try self.replaceSpan(nodeSpan(self.tree, node), replacement);
    }

    fn replaceStatement(self: *Builder, node: Node.Index, replacement: []const u8) !void {
        try self.replaceSpan(statementSpan(self.tree, node), replacement);
    }

    fn deleteDecl(self: *Builder, node: Node.Index) !void {
        const span = nodeSpan(self.tree, node);
        try self.replaceSpan(.{
            .start = extendBeforeBlankLines(self.tree.source, span.start),
            .end = extendPastLineEnd(self.tree.source, span.end),
        }, "");
    }

    fn deleteStatement(self: *Builder, node: Node.Index) !void {
        const span = statementSpan(self.tree, node);
        try self.replaceSpan(.{
            .start = extendBeforeBlankLines(self.tree.source, span.start),
            .end = extendPastLineEnd(self.tree.source, span.end),
        }, "");
    }

    /// Rewrite part of a test's name token in place.
    fn renameTest(self: *Builder, test_node: Node.Index, from: []const u8, to: []const u8) !bool {
        const name_tok = self.tree.nodeData(test_node).opt_token_and_node[0].unwrap() orelse return false;
        const slice = self.tree.tokenSlice(name_tok);
        const at = std.mem.indexOf(u8, slice, from) orelse return false;
        const start = self.tree.tokenStart(name_tok) + at;
        try self.replaceSpan(.{ .start = start, .end = start + from.len }, to);
        return true;
    }

    /// Drop the log-silencing call a test only needs while the patched-away
    /// warning still fires.
    fn dropSilenceLog(self: *Builder, name: []const u8, test_node: Node.Index) !void {
        var calls: std.ArrayList(Call) = .empty;
        defer freeCalls(self.gpa, &calls);
        try collectCalls(self.gpa, self.tree, test_node, "silenceLog", &calls);

        if (calls.items.len != 1) {
            try self.report.record(
                self.target,
                name,
                if (calls.items.len == 0) .not_found else .ambiguous,
                0,
            );
            return;
        }
        try self.deleteStatement(calls.items[0].node);
        try self.applied(name, 1);
    }
};

fn configSites(b: *Builder) !void {
    const guard = "validateUserAgent: mozilla guard";
    if (try b.anchor(guard, findIfGuard(b.tree, "\"mozilla\"", "error.Reserved"))) |node| {
        try b.deleteDecl(node);
        try b.applied(guard, 1);
    }

    const refuses = "test: parseArgs refuses a mozilla user-agent";
    if (try b.anchor(refuses, findTest(b.tree, "parseArgs refuses a mozilla user-agent\""))) |node| {
        try b.deleteDecl(node);
        try b.applied(refuses, 1);
    }

    // `try std.testing.expectError(error.Reserved, validateUserAgent(UA));`
    // becomes `try validateUserAgent(UA);` -- the call being asserted on is
    // already the second argument, so the new statement is the node itself.
    const expectations = "test: validateUserAgent reserved expectations";
    if (try b.anchor(expectations, findTest(b.tree, "Config: validateUserAgent\""))) |node| {
        var calls: std.ArrayList(Call) = .empty;
        defer freeCalls(b.gpa, &calls);
        try collectCalls(b.gpa, b.tree, node, "expectError", &calls);

        var rewritten: usize = 0;
        for (calls.items) |call| {
            if (call.params.len != 2) continue;
            if (!std.mem.eql(u8, b.tree.getNodeSource(call.params[0]), "error.Reserved")) continue;
            try b.replaceNode(call.node, b.tree.getNodeSource(call.params[1]));
            rewritten += 1;
        }

        if (rewritten == 0) try b.missing(expectations) else try b.applied(expectations, rewritten);
    }
}

fn emulationSites(b: *Builder) !void {
    const prong = "setUserAgentOverride: error.Reserved prong";
    if (try b.anchor(prong, findSwitchCase(b.tree, "error.Reserved"))) |node| {
        try b.deleteDecl(node);
        try b.applied(prong, 1);
    }

    // The plain name is a prefix of the case-insensitive one, so the trailing
    // quote is what keeps the two anchors apart.
    for ([_][]const u8{ "ignores mozilla\"", "ignores mozilla case insensitive\"" }) |needle| {
        const label = try std.fmt.allocPrint(b.arena, "test: setUserAgentOverride {s}", .{
            std.mem.trimEnd(u8, needle, "\""),
        });

        const node = try b.anchor(label, findTest(b.tree, needle)) orelse continue;

        const renamed = "  rename to accepts mozilla";
        const rename_label = try std.fmt.allocPrint(b.arena, "{s}{s}", .{ label, renamed });
        if (try b.renameTest(node, "ignores mozilla", "accepts mozilla")) {
            try b.applied(rename_label, 1);
        } else {
            try b.missing(rename_label);
        }

        try b.dropSilenceLog(try std.fmt.allocPrint(b.arena, "{s}  drop silenceLog", .{label}), node);

        // A rejected override replies with a bare result; an accepted one
        // replies against the request id the test itself sent.
        const result_label = try std.fmt.allocPrint(b.arena, "{s}  expect result id", .{label});
        if (findNumericIdField(b.tree, node)) |id| {
            var calls: std.ArrayList(Call) = .empty;
            defer freeCalls(b.gpa, &calls);
            try collectCalls(b.gpa, b.tree, node, "expectSentResult", &calls);

            var rewritten: usize = 0;
            for (calls.items) |call| {
                if (call.params.len != 2) continue;
                if (!std.mem.eql(u8, b.tree.getNodeSource(call.params[1]), ".{}")) continue;
                try b.replaceNode(call.params[1], try std.fmt.allocPrint(b.arena, ".{{ .id = {s} }}", .{id}));
                rewritten += 1;
            }
            if (rewritten == 0) try b.missing(result_label) else try b.applied(result_label, rewritten);
        } else {
            try b.missing(result_label);
        }

        const changed_label = try std.fmt.allocPrint(b.arena, "{s}  expect user_agent_changed", .{label});
        var calls: std.ArrayList(Call) = .empty;
        defer freeCalls(b.gpa, &calls);
        try collectCalls(b.gpa, b.tree, node, "expectEqual", &calls);

        var rewritten: usize = 0;
        for (calls.items) |call| {
            if (call.params.len != 2) continue;
            if (std.mem.indexOf(u8, b.tree.getNodeSource(call.params[1]), "user_agent_changed") == null) continue;
            if (!std.mem.eql(u8, b.tree.getNodeSource(call.params[0]), "false")) continue;
            try b.replaceNode(call.params[0], "true");
            rewritten += 1;
        }
        if (rewritten == 0) try b.missing(changed_label) else try b.applied(changed_label, rewritten);
    }
}

fn networkSites(b: *Builder) !void {
    // The sibling "...smuggled via a colon in the key" test shares this prefix
    // and must keep rejecting: its rejection comes from HTTP token validation,
    // not the User-Agent check, so the trailing quote is what protects it.
    const label = "test: setExtraHTTPHeaders Mozilla User-Agent";
    const node = try b.anchor(label, findTest(b.tree, "rejects a Mozilla User-Agent\"")) orelse return;

    if (try b.renameTest(node, "rejects a Mozilla User-Agent", "accepts a Mozilla User-Agent")) {
        try b.applied(label ++ "  rename to accepts", 1);
    } else {
        try b.missing(label ++ "  rename to accepts");
    }

    try b.dropSilenceLog(label ++ "  drop silenceLog", node);

    const assert_label = label ++ "  assert header kept";
    var calls: std.ArrayList(Call) = .empty;
    defer freeCalls(b.gpa, &calls);
    try collectCalls(b.gpa, b.tree, node, "expectEqual", &calls);

    const ua = findStringLiteral(b.tree, node, "Mozilla") orelse {
        try b.missing(assert_label);
        return;
    };

    var rewritten: usize = 0;
    for (calls.items) |call| {
        if (call.params.len != 2) continue;

        // Upstream writes this assertion actual-first; accept either order.
        const a = b.tree.getNodeSource(call.params[0]);
        const c = b.tree.getNodeSource(call.params[1]);
        const len_src = if (std.mem.endsWith(u8, a, ".extra_headers.items.len"))
            a
        else if (std.mem.endsWith(u8, c, ".extra_headers.items.len"))
            c
        else
            continue;
        const zero = if (len_src.ptr == a.ptr) c else a;
        if (!std.mem.eql(u8, zero, "0")) continue;

        const receiver = len_src[0 .. len_src.len - ".extra_headers.items.len".len];
        try b.replaceStatement(call.node, try std.fmt.allocPrint(b.arena,
            \\try testing.expectEqual(1, {0s}.extra_headers.items.len);
            \\try testing.expectEqual("User-Agent", {0s}.extra_headers.items[0].name);
            \\try testing.expectEqual({1s}, {0s}.extra_headers.items[0].value);
        , .{ receiver, ua }));
        rewritten += 1;
    }
    if (rewritten == 0) try b.missing(assert_label) else try b.applied(assert_label, rewritten);
}

fn applyEdits(gpa: Allocator, source: []const u8, edits: []const Edit) ![]u8 {
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
    for (sorted) |edit| {
        if (edit.start < cursor) return error.OverlappingEdits;
        try out.appendSlice(gpa, source[cursor..edit.start]);
        try out.appendSlice(gpa, edit.replacement);
        cursor = edit.end;
    }
    try out.appendSlice(gpa, source[cursor..]);
    return out.toOwnedSlice(gpa);
}

/// Patch one file's source, appending a result per site to `report`. The
/// returned source is always rendered, even when sites failed; whether it is
/// fit to write is the caller's call, via `report`.
pub fn patchSource(gpa: Allocator, target: Target, source: [:0]const u8, report: *Report) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        std.log.err("{s}: {d} parse error(s) before patching; refusing to touch it", .{ target.relPath(), tree.errors.len });
        return error.SourceHasParseErrors;
    }

    var builder: Builder = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .tree = tree,
        .target = target,
        .report = report,
    };
    defer builder.deinit();

    switch (target) {
        .config => try configSites(&builder),
        .emulation => try emulationSites(&builder),
        .network => try networkSites(&builder),
    }

    // Two sites resolving to overlapping spans is a bug in this tool, not
    // upstream drift, so spell the spans out rather than just failing.
    const patched = applyEdits(gpa, source, builder.edits.items) catch |err| {
        if (err == error.OverlappingEdits) {
            std.log.err("{s}: sites produced overlapping edits:", .{target.relPath()});
            for (builder.edits.items) |edit| {
                std.log.err("  [{d}, {d}) -> \"{f}\"", .{ edit.start, edit.end, std.zig.fmtString(edit.replacement) });
            }
        }
        return err;
    };
    defer gpa.free(patched);

    const patched_z = try gpa.dupeZ(u8, patched);
    defer gpa.free(patched_z);

    var out_tree = try Ast.parse(gpa, patched_z, .zig);
    defer out_tree.deinit(gpa);
    if (out_tree.errors.len != 0) {
        std.log.err("{s}: {d} parse error(s) after patching; the edit produced invalid Zig", .{ target.relPath(), out_tree.errors.len });
        return error.PatchProducedInvalidSource;
    }

    return out_tree.renderAlloc(gpa);
}

const testing = std.testing;

fn expectPatch(target: Target, source: [:0]const u8, expected: []const u8) !void {
    var report = Report.init(testing.allocator);
    defer report.deinit();

    const patched = try patchSource(testing.allocator, target, source, &report);
    defer testing.allocator.free(patched);

    for (report.sites.items) |site| {
        if (site.status != .applied) {
            std.debug.print("site {s} -> {s}\n", .{ site.name, @tagName(site.status) });
        }
    }
    try testing.expect(report.ok());
    try testing.expectEqualStrings(expected, patched);
}

fn expectFailedSite(target: Target, source: [:0]const u8, name: []const u8, status: Status) !void {
    var report = Report.init(testing.allocator);
    defer report.deinit();

    const patched = try patchSource(testing.allocator, target, source, &report);
    defer testing.allocator.free(patched);

    for (report.sites.items) |site| {
        if (std.mem.eql(u8, site.name, name)) {
            try testing.expectEqual(status, site.status);
            return;
        }
    }
    std.debug.print("no site named {s} in report\n", .{name});
    return error.SiteNotReported;
}

test "applyEdits splices in offset order" {
    const out = try applyEdits(testing.allocator, "abcdef", &.{
        .{ .start = 4, .end = 5, .replacement = "E" },
        .{ .start = 1, .end = 3, .replacement = "" },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("adEf", out);
}

test "applyEdits rejects overlapping edits" {
    try testing.expectError(error.OverlappingEdits, applyEdits(testing.allocator, "abcdef", &.{
        .{ .start = 1, .end = 4, .replacement = "" },
        .{ .start = 2, .end = 5, .replacement = "" },
    }));
}

test "extendBeforeBlankLines eats indentation and blank lines" {
    const src = "a\n\n    b";
    try testing.expectEqual(@as(usize, 2), extendBeforeBlankLines(src, src.len - 1));
}

test "extendBeforeBlankLines stops at a non-blank line" {
    const src = "a\n    b";
    try testing.expectEqual(@as(usize, 2), extendBeforeBlankLines(src, src.len - 1));
}

test "extendPastLineEnd eats a trailing comma and newline" {
    const src = "x, \nnext";
    try testing.expectEqual(@as(usize, 4), extendPastLineEnd(src, 1));
}

test "config: guard and expectations are rewritten" {
    try expectPatch(.config,
        \\const std = @import("std");
        \\
        \\pub fn validateUserAgent(ua: []const u8) !void {
        \\    for (ua) |c| {
        \\        if (!std.ascii.isPrint(c)) {
        \\            return error.NonPrintable;
        \\        }
        \\    }
        \\
        \\    if (std.ascii.indexOfIgnoreCase(ua, "mozilla") != null) {
        \\        return error.Reserved;
        \\    }
        \\}
        \\
        \\test "Config: parseArgs refuses a mozilla user-agent" {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\test "Config: validateUserAgent" {
        \\    try validateUserAgent("Bot/1.0");
        \\    try std.testing.expectError(error.Reserved, validateUserAgent("mozilla/1.0"));
        \\    try std.testing.expectError(error.Reserved, validateUserAgent("Mozilla/5.0"));
        \\}
        \\
    ,
        \\const std = @import("std");
        \\
        \\pub fn validateUserAgent(ua: []const u8) !void {
        \\    for (ua) |c| {
        \\        if (!std.ascii.isPrint(c)) {
        \\            return error.NonPrintable;
        \\        }
        \\    }
        \\}
        \\
        \\test "Config: validateUserAgent" {
        \\    try validateUserAgent("Bot/1.0");
        \\    try validateUserAgent("mozilla/1.0");
        \\    try validateUserAgent("Mozilla/5.0");
        \\}
        \\
    );
}

test "emulation: prong deleted, tests renamed and re-asserted" {
    try expectPatch(.emulation,
        \\const Config = @import("Config.zig");
        \\const testing = @import("../testing.zig");
        \\
        \\fn setUserAgentOverride(cmd: *CDP.Command) !void {
        \\    Config.validateUserAgent(ua) catch |err| switch (err) {
        \\        error.NonPrintable => return cmd.sendError(-32602, "nope", .{}),
        \\        error.Reserved => {
        \\            log.warn(.not_implemented, "Emulation.setUserAgentOverride", .{});
        \\            return cmd.sendResult(null, .{});
        \\        },
        \\    };
        \\}
        \\
        \\test "cdp.Emulation: setUserAgentOverride ignores mozilla" {
        \\    testing.silenceLog(&.{.not_implemented});
        \\
        \\    var ctx = try testing.context();
        \\    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA2" });
        \\
        \\    try ctx.processMessage(.{
        \\        .id = 2,
        \\        .method = "Emulation.setUserAgentOverride",
        \\    });
        \\
        \\    try ctx.expectSentResult(null, .{});
        \\    try testing.expectEqual(false, ctx.cdp().browser_context.?.user_agent_changed);
        \\}
        \\
        \\test "cdp.Emulation: setUserAgentOverride ignores mozilla case insensitive" {
        \\    testing.silenceLog(&.{.not_implemented});
        \\
        \\    var ctx = try testing.context();
        \\    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA3" });
        \\
        \\    try ctx.processMessage(.{
        \\        .id = 3,
        \\        .method = "Emulation.setUserAgentOverride",
        \\    });
        \\
        \\    try ctx.expectSentResult(null, .{});
        \\    try testing.expectEqual(false, ctx.cdp().browser_context.?.user_agent_changed);
        \\}
        \\
    ,
        \\const Config = @import("Config.zig");
        \\const testing = @import("../testing.zig");
        \\
        \\fn setUserAgentOverride(cmd: *CDP.Command) !void {
        \\    Config.validateUserAgent(ua) catch |err| switch (err) {
        \\        error.NonPrintable => return cmd.sendError(-32602, "nope", .{}),
        \\    };
        \\}
        \\
        \\test "cdp.Emulation: setUserAgentOverride accepts mozilla" {
        \\    var ctx = try testing.context();
        \\    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA2" });
        \\
        \\    try ctx.processMessage(.{
        \\        .id = 2,
        \\        .method = "Emulation.setUserAgentOverride",
        \\    });
        \\
        \\    try ctx.expectSentResult(null, .{ .id = 2 });
        \\    try testing.expectEqual(true, ctx.cdp().browser_context.?.user_agent_changed);
        \\}
        \\
        \\test "cdp.Emulation: setUserAgentOverride accepts mozilla case insensitive" {
        \\    var ctx = try testing.context();
        \\    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA3" });
        \\
        \\    try ctx.processMessage(.{
        \\        .id = 3,
        \\        .method = "Emulation.setUserAgentOverride",
        \\    });
        \\
        \\    try ctx.expectSentResult(null, .{ .id = 3 });
        \\    try testing.expectEqual(true, ctx.cdp().browser_context.?.user_agent_changed);
        \\}
        \\
    );
}

test "network: the smuggling sibling is left alone" {
    try expectPatch(.network,
        \\const testing = @import("../testing.zig");
        \\
        \\test "cdp.network setExtraHTTPHeaders rejects a Mozilla User-Agent" {
        \\    testing.silenceLog(&.{.cdp});
        \\
        \\    var ctx = try testing.context();
        \\
        \\    try ctx.processMessage(.{
        \\        .id = 3,
        \\        .params = .{ .headers = .{ .@"User-Agent" = "Mozilla/5.0" } },
        \\    });
        \\
        \\    const bc = ctx.cdp().browser_context.?;
        \\    try testing.expectEqual(bc.extra_headers.items.len, 0);
        \\}
        \\
        \\test "cdp.network setExtraHTTPHeaders rejects a Mozilla User-Agent smuggled via a colon in the key" {
        \\    testing.silenceLog(&.{.cdp});
        \\
        \\    var ctx = try testing.context();
        \\
        \\    try ctx.processMessage(.{
        \\        .id = 3,
        \\        .params = .{ .headers = .{ .@"User-Agent:Mozilla/5.0 (X" = "Y)" } },
        \\    });
        \\
        \\    const bc = ctx.cdp().browser_context.?;
        \\    try testing.expectEqual(bc.extra_headers.items.len, 0);
        \\}
        \\
    ,
        \\const testing = @import("../testing.zig");
        \\
        \\test "cdp.network setExtraHTTPHeaders accepts a Mozilla User-Agent" {
        \\    var ctx = try testing.context();
        \\
        \\    try ctx.processMessage(.{
        \\        .id = 3,
        \\        .params = .{ .headers = .{ .@"User-Agent" = "Mozilla/5.0" } },
        \\    });
        \\
        \\    const bc = ctx.cdp().browser_context.?;
        \\    try testing.expectEqual(1, bc.extra_headers.items.len);
        \\    try testing.expectEqual("User-Agent", bc.extra_headers.items[0].name);
        \\    try testing.expectEqual("Mozilla/5.0", bc.extra_headers.items[0].value);
        \\}
        \\
        \\test "cdp.network setExtraHTTPHeaders rejects a Mozilla User-Agent smuggled via a colon in the key" {
        \\    testing.silenceLog(&.{.cdp});
        \\
        \\    var ctx = try testing.context();
        \\
        \\    try ctx.processMessage(.{
        \\        .id = 3,
        \\        .params = .{ .headers = .{ .@"User-Agent:Mozilla/5.0 (X" = "Y)" } },
        \\    });
        \\
        \\    const bc = ctx.cdp().browser_context.?;
        \\    try testing.expectEqual(bc.extra_headers.items.len, 0);
        \\}
        \\
    );
}

test "a missing anchor is reported, not guessed" {
    try expectFailedSite(.config,
        \\pub fn validateUserAgent(ua: []const u8) !void {}
        \\
    , "validateUserAgent: mozilla guard", .not_found);
}

test "a duplicated anchor is ambiguous, not first-wins" {
    try expectFailedSite(.network,
        \\test "cdp.network setExtraHTTPHeaders rejects a Mozilla User-Agent" {
        \\    try testing.expectEqual(bc.extra_headers.items.len, 0);
        \\}
        \\
        \\test "another rejects a Mozilla User-Agent" {
        \\    try testing.expectEqual(bc.extra_headers.items.len, 0);
        \\}
        \\
    , "test: setExtraHTTPHeaders Mozilla User-Agent", .ambiguous);
}

test "patching is idempotent in the sense that a patched file no longer matches" {
    const patched: [:0]const u8 =
        \\pub fn validateUserAgent(ua: []const u8) !void {
        \\    for (ua) |c| {
        \\        if (!std.ascii.isPrint(c)) {
        \\            return error.NonPrintable;
        \\        }
        \\    }
        \\}
        \\
    ;
    try expectFailedSite(.config, patched, "validateUserAgent: mozilla guard", .not_found);
}
