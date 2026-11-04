//! The command the harness uses to run this project's test suite.
//!
//! The pipeline's verify stage must not ask the model "did the tests pass?"
//! — it runs them itself, with a fixed command, and reads the exit code. This
//! module is the table of markers → command, pure and testable, with the same
//! marker-scan discipline as the `check` tool.

const std = @import("std");

pub const Plan = struct {
    /// The argv to pass to the shell: "zig build test", one per token.
    argv: []const []const u8,
    /// How to refer to the check in reports.
    label: []const u8,
    /// Marker files that decided it.
    reason: []const u8,
};

pub const Markers = struct {
    zig: bool = false,
    node: bool = false,
    cargo: bool = false,
    go: bool = false,
    pyproject: bool = false,
    pytest_ini: bool = false,
    mix: bool = false,
    gemfile: bool = false,
};

/// The plan for a marked project, or null when nothing known matches.
///
/// Order is the precedence: Zig first (it is the project this harness was
/// built for), then the common ones. The first hit wins.
pub fn planFor(m: Markers) ?Plan {
    if (m.zig) return .{ .argv = &.{ "zig", "build", "test" }, .label = "zig build test", .reason = "build.zig" };
    if (m.node) return .{ .argv = &.{ "npm", "test" }, .label = "npm test", .reason = "package.json" };
    if (m.cargo) return .{ .argv = &.{ "cargo", "test" }, .label = "cargo test", .reason = "Cargo.toml" };
    if (m.go) return .{ .argv = &.{ "go", "test", "./..." }, .label = "go test ./...", .reason = "go.mod" };
    if (m.pytest_ini) return .{ .argv = &.{ "python3", "-m", "pytest" }, .label = "python3 -m pytest", .reason = "pytest.ini" };
    if (m.pyproject) return .{ .argv = &.{ "python3", "-m", "pytest" }, .label = "python3 -m pytest", .reason = "pyproject.toml" };
    if (m.mix) return .{ .argv = &.{ "mix", "test" }, .label = "mix test", .reason = "mix.exs" };
    if (m.gemfile) return .{ .argv = &.{ "bundle", "exec", "rake", "test" }, .label = "bundle exec rake test", .reason = "Gemfile" };
    return null;
}

/// Scan `dir` (top level only, not recursive) for the markers.
pub fn planAt(io: std.Io, dir_path: []const u8) ?Plan {
    var m = Markers{};
    var dirh = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dirh.close(io);
    var it = dirh.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (std.mem.eql(u8, e.name, "build.zig")) m.zig = true;
        if (std.mem.eql(u8, e.name, "package.json")) m.node = true;
        if (std.mem.eql(u8, e.name, "Cargo.toml")) m.cargo = true;
        if (std.mem.eql(u8, e.name, "go.mod")) m.go = true;
        if (std.mem.eql(u8, e.name, "pyproject.toml")) m.pyproject = true;
        if (std.mem.eql(u8, e.name, "pytest.ini") or std.mem.eql(u8, e.name, "setup.cfg") or std.mem.eql(u8, e.name, "tox.ini"))
            m.pytest_ini = true;
        if (std.mem.eql(u8, e.name, "mix.exs")) m.mix = true;
        if (std.mem.eql(u8, e.name, "Gemfile")) m.gemfile = true;
    }
    return planFor(m);
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "planFor: zig wins over everything else" {
    const p = planFor(.{ .zig = true, .node = true, .cargo = true }) orelse return error.NoPlan;
    try t.expectEqualStrings("zig build test", p.label);
    try t.expectEqual(@as(usize, 3), p.argv.len);
    try t.expectEqualStrings("test", p.argv[2]);
}

test "planFor: each marker maps to its own command" {
    try t.expectEqualStrings("npm test", (planFor(.{ .node = true }) orelse return error.NoPlan).label);
    try t.expectEqualStrings("cargo test", (planFor(.{ .cargo = true }) orelse return error.NoPlan).label);
    try t.expectEqualStrings("go test ./...", (planFor(.{ .go = true }) orelse return error.NoPlan).label);
    try t.expectEqualStrings("python3 -m pytest", (planFor(.{ .pyproject = true }) orelse return error.NoPlan).label);
    try t.expectEqualStrings("python3 -m pytest", (planFor(.{ .pytest_ini = true }) orelse return error.NoPlan).label);
    try t.expectEqualStrings("mix test", (planFor(.{ .mix = true }) orelse return error.NoPlan).label);
    try t.expectEqualStrings("bundle exec rake test", (planFor(.{ .gemfile = true }) orelse return error.NoPlan).label);
}

test "planFor: nothing marked means no plan, never a guess" {
    try t.expect(planFor(.{}) == null);
}
