const std = @import("std");
const tui = @import("../tui.zig");
const providers = @import("../lib/providers.zig");
const config_mod = @import("../config.zig");
const chat = @import("../chat.zig");
const router_mod = @import("../lib/router.zig");
const subagent_mod = @import("../lib/subagent.zig");
const roster_mod = @import("../roster.zig");

pub const Target = struct {
    def: *const providers.ProviderDef,
    model: []const u8,
    kind: chat.ProviderKind,
    base_url: []const u8,
    key: ?[]const u8,
    /// The pool candidate, or null if this turn goes to the active provider/model.
    from_roster: ?roster_mod.Candidate = null,
};

/// The endpoint for a target.
pub fn targetUrl(buf: []u8, t: Target) []const u8 {
    return if (t.kind == .anthropic)
        std.fmt.bufPrint(buf, "{s}/messages", .{t.base_url}) catch t.base_url
    else
        std.fmt.bufPrint(buf, "{s}/chat/completions", .{t.base_url}) catch t.base_url;
}

pub const SubPick = struct {
    provider: []const u8,
    model: []const u8,
    source: []const u8,
};

pub var sub_session: enum { unset, set, off } = .unset;
pub var sub_provider_buf: [64]u8 = undefined;
pub var sub_provider_len: usize = 0;
pub var sub_model_buf: [128]u8 = undefined;
pub var sub_model_len: usize = 0;

pub var sub_fail_buf: [256]u8 = undefined;
pub var sub_fail_len: usize = 0;

pub fn submodelFail(text: []const u8) void {
    const n = @min(text.len, sub_fail_buf.len);
    @memcpy(sub_fail_buf[0..n], text[0..n]);
    sub_fail_len = n;
}

pub fn submodelClearFail() void {
    sub_fail_len = 0;
}

pub fn submodelSetOff() void {
    sub_session = .off;
    sub_fail_len = 0;
}

/// Formats a reason into `buf` and returns what fit.
pub fn reasonFmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {};
    return w.buffered();
}

pub fn submodelPick(m: *tui.Model, user_config: config_mod.Config) ?SubPick {
    switch (sub_session) {
        .off => return null,
        .set => return .{
            .provider = sub_provider_buf[0..sub_provider_len],
            .model = sub_model_buf[0..sub_model_len],
            .source = "/submodel",
        },
        .unset => {},
    }
    if (user_config.subagent_provider.len > 0 or user_config.subagent_model.len > 0) {
        return .{
            .provider = user_config.subagent_provider,
            .model = user_config.subagent_model,
            .source = "config.json",
        };
    }
    const p = envGet(m.environ, "ZODE_SUBAGENT_PROVIDER") orelse "";
    const mo = envGet(m.environ, "ZODE_SUBAGENT_MODEL") orelse "";
    if (p.len == 0 and mo.len == 0) return null;
    return .{
        .provider = p,
        .model = mo,
        .source = if (mo.len > 0) "ZODE_SUBAGENT_MODEL" else "ZODE_SUBAGENT_PROVIDER",
    };
}

pub const SubResolve = union(enum) {
    ok: Target,
    why: []const u8,
};

pub const ResolveCtx = struct {
    active_def: *const providers.ProviderDef,
    cur_key: ?[]const u8,
    user_config: config_mod.Config,
    environ: ?*const std.process.Environ.Map,
};

pub fn submodelTarget(pick: SubPick, reason: []u8, ctx: ResolveCtx) SubResolve {
    const def: *const providers.ProviderDef = blk: {
        if (pick.provider.len == 0) break :blk ctx.active_def;
        if (config_mod.find(ctx.user_config, pick.provider)) |d| break :blk d;
        if (providers.byId(pick.provider)) |d| break :blk d;
        return .{ .why = reasonFmt(reason, "zode does not know the provider \"{s}\" (see /providers)", .{pick.provider}) };
    };
    const model: []const u8 = if (pick.model.len > 0) pick.model else def.default_model;
    if (model.len == 0) {
        return .{ .why = reasonFmt(reason, "\"{s}\" has no default model; name one: /submodel {s} <model>", .{ def.id, def.id }) };
    }
    const key = if (std.mem.eql(u8, def.id, ctx.active_def.id))
        ctx.cur_key
    else
        providers.keyFor(def, ctx.environ);
    if (key == null and def.key_env.len > 0) {
        return .{ .why = reasonFmt(reason, "there is no API key for \"{s}\" (connect it with ctrl+a, or set its ZODE_*_KEY)", .{def.id}) };
    }
    return .{ .ok = .{
        .def = def,
        .model = model,
        .kind = chat.kindForProvider(def.id),
        .base_url = def.base_url,
        .key = key,
        .from_roster = null,
    } };
}

pub fn submodelFallbackNote(
    buf: []u8,
    from_provider: []const u8,
    from_model: []const u8,
    w: router_mod.Why,
    to_provider: []const u8,
    to_model: []const u8,
) []const u8 {
    return reasonFmt(
        buf,
        "[subagent note: {s}/{s} {s}, so this search went to {s}/{s}. Set another with /submodel, or /submodel off.]",
        .{ from_provider, from_model, router_mod.phraseHead(w), to_provider, to_model },
    );
}

pub fn applySubmodel(
    m: *tui.Model,
    base: *Target,
    rep: *subagent_mod.Report,
    user_config: config_mod.Config,
    ctx: ResolveCtx,
) bool {
    if (sub_fail_len > 0) return false;
    const pick = submodelPick(m, user_config) orelse return false;

    var reason_buf: [400]u8 = undefined;
    switch (submodelTarget(pick, &reason_buf, ctx)) {
        .why => |why_not| {
            var nbuf: [640]u8 = undefined;
            const prov: []const u8 = if (pick.provider.len > 0)
                pick.provider
            else
                ctx.active_def.id;
            rep.setNote(reasonFmt(
                &nbuf,
                "[subagent note: the subagent model {s}/{s} was not used ({s}). Fix it with /submodel, or /submodel off.]",
                .{ prov, pick.model, why_not },
            ));
            return false;
        },
        .ok => |target| {
            base.* = target;
            var nbuf: [320]u8 = undefined;
            rep.setNote(reasonFmt(
                &nbuf,
                "[subagent note: this search runs on {s}/{s} ({s}).]",
                .{ target.def.id, target.model, pick.source },
            ));
            return true;
        },
    }
}

pub fn setSubmodel(provider: []const u8, model: []const u8) void {
    const p = @min(provider.len, sub_provider_buf.len);
    std.mem.copyForwards(u8, sub_provider_buf[0..p], provider[0..p]);
    sub_provider_len = p;
    const mm = @min(model.len, sub_model_buf.len);
    std.mem.copyForwards(u8, sub_model_buf[0..mm], model[0..mm]);
    sub_model_len = mm;
    sub_session = .set;
}

pub fn submodelReport(m: *tui.Model, user_config: config_mod.Config, ctx: ResolveCtx) void {
    if (sub_session == .off) {
        m.pushInfoFmt("subagents: the same model as the main turn (/submodel off). Set: /submodel <model> | /submodel <provider> <model>", .{});
        return;
    }
    const pick = submodelPick(m, user_config) orelse {
        m.pushInfoFmt("subagents: the same model as the main turn (no override). Set: /submodel <model> | /submodel <provider> <model>", .{});
        return;
    };
    const prov: []const u8 = if (pick.provider.len > 0)
        pick.provider
    else
        ctx.active_def.id;
    var reason_buf: [400]u8 = undefined;
    switch (submodelTarget(pick, &reason_buf, ctx)) {
        .ok => |t| {
            if (sub_fail_len > 0) {
                m.pushInfoFmt("subagents: {s}/{s} ({s}) — NOT in use: {s}. Change it with /submodel, or /submodel off", .{
                    t.def.id, t.model, pick.source, sub_fail_buf[0..sub_fail_len],
                });
            } else {
                m.pushInfoFmt("subagents: {s}/{s} ({s}). Off with /submodel off.", .{ t.def.id, t.model, pick.source });
            }
        },
        .why => |why_not| m.pushInfoFmt("subagents: {s}/{s} ({s}) — CANNOT be used: {s}", .{
            prov, pick.model, pick.source, why_not,
        }),
    }
}

pub fn failReason() []const u8 {
    return sub_fail_buf[0..sub_fail_len];
}

fn envGet(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const e = env orelse return null;
    return e.get(key);
}
