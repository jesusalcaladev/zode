const std = @import("std");
const tui = @import("../tui.zig");
const cmdsubst = @import("../lib/cmdsubst.zig");

pub const PermOps = struct {
    isBashAlwaysAllowed: *const fn () bool,
    bashCommandAllowed: *const fn ([]const u8) bool,
};

threadlocal var perm_ops: ?PermOps = null;

fn permissionCb(ctx: *const cmdsubst.Ctx, command: []const u8) cmdsubst.Permission {
    if (cmdsubst.matchesAllowRules(command, ctx.allow_rules)) return .allow;
    const ops = perm_ops orelse return .deny;
    if (ops.isBashAlwaysAllowed() or ops.bashCommandAllowed(command)) return .allow;
    return .deny;
}

pub const Ops = struct {
    io: std.Io,
    perm: PermOps,
    reportFailure: *const fn (*tui.Model, []const u8) void,
};

/// Expands prompt command substitutions for a worker turn. On failure reports
/// the error and returns false. On success may replace `user_text` with an
/// owned copy (frees previous).
pub fn expand(
    m: *tui.Model,
    expand_cmdsubst: bool,
    bash_allow_rules: []const []const u8,
    user_text: *[]const u8,
    ops: Ops,
) bool {
    if (!expand_cmdsubst or !cmdsubst.hasSubstitution(user_text.*)) return true;

    var arena_state = std.heap.ArenaAllocator.init(m.allocator);
    defer arena_state.deinit();

    perm_ops = ops.perm;
    defer perm_ops = null;

    var err_out: ?[]const u8 = null;
    const cctx = cmdsubst.Ctx{
        .io = ops.io,
        .arena = arena_state.allocator(),
        .allow_rules = bash_allow_rules,
        .permission = permissionCb,
    };
    const expanded = cmdsubst.expand(user_text.*, &cctx, &err_out) catch {
        const msg = err_out orelse "Shell command failed for prompt substitution: unknown error";
        ops.reportFailure(m, msg);
        return false;
    };
    const expanded_owned = m.allocator.dupe(u8, expanded) catch {
        ops.reportFailure(m, "Shell command failed for prompt substitution: out of memory");
        return false;
    };
    m.allocator.free(@constCast(user_text.*));
    user_text.* = expanded_owned;
    return true;
}
