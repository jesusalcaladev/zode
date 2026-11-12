const std = @import("std");
const common = @import("common.zig");
const agent = @import("../agent.zig");
const gh = @import("../lib/github.zig");
const context = gh.context;
const api = gh.api;
const types = gh.types;

const max_pages: usize = 10;

pub fn toolGithub(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const op = common.getStr(obj, "operation") orelse
        return "github needs an `operation`: auth_status, whoami, repo, pr_list, pr_view, pr_checks, pr_create, pr_update, pr_comment, issue_list, issue_view, issue_create, issue_comment, actions_runs.";
    if (std.ascii.eqlIgnoreCase(op, "auth_status")) return opAuthStatus(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "whoami")) return opWhoami(io, arena);
    if (std.ascii.eqlIgnoreCase(op, "repo")) return opRepo(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "pr_list")) return opPrList(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "pr_view")) return opPrView(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "pr_checks")) return opPrChecks(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "pr_create")) return opPrCreate(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "pr_update")) return opPrUpdate(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "pr_comment")) return opPrComment(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "issue_list")) return opIssueList(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "issue_view")) return opIssueView(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "issue_create")) return opIssueCreate(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "issue_comment")) return opIssueComment(io, obj, arena);
    if (std.ascii.eqlIgnoreCase(op, "actions_runs")) return opActionsRuns(io, obj, arena);
    return std.fmt.allocPrint(arena, "unknown github operation \"{s}\". Use: auth_status, whoami, repo, pr_list, pr_view, pr_checks, pr_create, pr_update, pr_comment, issue_list, issue_view, issue_create, issue_comment, actions_runs.", .{op}) catch "unknown github operation";
}

const Resolved = struct { host: []const u8, owner: []const u8, repo: []const u8, api_base: []const u8, token: ?[]const u8, token_source: []const u8 };

/// The environment the HARNESS was started with.
///
/// It is the agent's map and not a fresh read of `environ`: the harness
/// already owns the environment it was given, and a second copy of it is a
/// second answer to "what is configured" — the one place where two answers
/// would be a bug (a token that the harness knows and the tool does not).
fn envMap(_: std.mem.Allocator) ?*const std.process.Environ.Map {
    return agent.environ_global;
}

fn resolveRepo(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) !Resolved {
    const env = envMap(arena);
    var host: []const u8 = "github.com";
    var owner: []const u8 = "";
    var repo: []const u8 = "";
    if (common.getStr(obj, "repo")) |explicit| {
        const t = std.mem.trim(u8, explicit, " \t\r\n");
        if (std.mem.indexOfScalar(u8, t, '/')) |slash| { owner = t[0..slash]; repo = t[slash + 1 ..]; } else return error.BadArgs;
        if (owner.len == 0 or repo.len == 0) return error.BadArgs;
        if (context.resolve(arena, io)) |r| { if (std.ascii.eqlIgnoreCase(r.owner, owner) and std.ascii.eqlIgnoreCase(r.repo, repo)) host = r.host; }
    } else {
        const r = context.resolve(arena, io) orelse return error.NoGitHubContext;
        host = r.host; owner = r.owner; repo = r.repo;
    }
    const auth = api.resolveToken(arena, io, env, host);
    return .{ .host = host, .owner = owner, .repo = repo, .api_base = api.apiBaseForHost(arena, host), .token = auth.token, .token_source = auth.source };
}

fn noContextMsg() []const u8 { return "could not resolve GitHub repository from git remotes. Pass `repo` as owner/name, or add a GitHub remote (e.g. origin/upstream)."; }
fn doRequest(arena: std.mem.Allocator, io: std.Io, method: api.Method, r: Resolved, path_or_url: []const u8, body: ?[]const u8) !api.Response { return api.request(arena, io, method, try api.buildUrl(arena, r.api_base, path_or_url), r.token, body); }
fn clampLimit(obj: std.json.ObjectMap, default_n: usize, max_n: usize) usize { if (common.getInt(obj, "limit")) |l| { if (l > 0) return @min(@as(usize, @intCast(l)), max_n); } return default_n; }
fn isUnreserved(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~'; }
fn urlEncode(arena: std.mem.Allocator, input: []const u8) []const u8 { var out: std.ArrayList(u8) = .empty; for (input) |c| { if (isUnreserved(c)) { out.append(arena, c) catch return input; } else { out.appendSlice(arena, std.fmt.allocPrint(arena, "%{X:0>2}", .{c}) catch return input) catch return input; } } return out.items; }
fn appendMeta(out: *std.ArrayList(u8), arena: std.mem.Allocator, resp: api.Response) !void { if (resp.next_link != null) try out.appendSlice(arena, "more: yes (additional pages available)\n"); if (resp.rate_remaining) |rr| if (rr <= 20) try out.print(arena, "rate_remaining: {d}\n", .{rr}); }

fn collectArrayPages(io: std.Io, arena: std.mem.Allocator, r: Resolved, first_path: []const u8, max_items: usize) !struct { items: []std.json.Value, next_link: ?[]const u8, last: api.Response } {
    var items: std.ArrayList(std.json.Value) = .empty; var next: ?[]const u8 = first_path; var pages: usize = 0; var last: ?api.Response = null;
    while (next) |n| : (pages += 1) { if (pages >= max_pages or items.items.len >= max_items) break; const resp = try doRequest(arena, io, .GET, r, n, null); last = resp; if (resp.status < 200 or resp.status >= 300) return error.ApiStatus; const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return error.BadJson; if (v != .array) return error.BadShape; for (v.array.items) |it| { if (items.items.len >= max_items) break; try items.append(arena, it); } next = if (items.items.len >= max_items) null else resp.next_link; }
    return .{ .items = items.items, .next_link = if (last) |l| l.next_link else null, .last = last.? };
}
fn collectCheckRunsPages(io: std.Io, arena: std.mem.Allocator, r: Resolved, first_path: []const u8, max_items: usize) !struct { items: []std.json.Value, next_link: ?[]const u8, last: api.Response } {
    var items: std.ArrayList(std.json.Value) = .empty; var next: ?[]const u8 = first_path; var pages: usize = 0; var last: ?api.Response = null;
    while (next) |n| : (pages += 1) { if (pages >= max_pages or items.items.len >= max_items) break; const resp = try doRequest(arena, io, .GET, r, n, null); last = resp; if (resp.status < 200 or resp.status >= 300) return error.ApiStatus; const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return error.BadJson; if (v != .object) return error.BadShape; const runs_v = v.object.get("check_runs") orelse break; if (runs_v != .array) return error.BadShape; for (runs_v.array.items) |it| { if (items.items.len >= max_items) break; try items.append(arena, it); } next = if (items.items.len >= max_items) null else resp.next_link; }
    return .{ .items = items.items, .next_link = if (last) |l| l.next_link else null, .last = last.? };
}
fn collectWorkflowRunsPages(io: std.Io, arena: std.mem.Allocator, r: Resolved, first_path: []const u8, max_items: usize) !struct { items: []std.json.Value, next_link: ?[]const u8, last: api.Response } {
    var items: std.ArrayList(std.json.Value) = .empty; var next: ?[]const u8 = first_path; var pages: usize = 0; var last: ?api.Response = null;
    while (next) |n| : (pages += 1) { if (pages >= max_pages or items.items.len >= max_items) break; const resp = try doRequest(arena, io, .GET, r, n, null); last = resp; if (resp.status < 200 or resp.status >= 300) return error.ApiStatus; const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return error.BadJson; if (v != .object) return error.BadShape; const runs_v = v.object.get("workflow_runs") orelse break; if (runs_v != .array) return error.BadShape; for (runs_v.array.items) |it| { if (items.items.len >= max_items) break; try items.append(arena, it); } next = if (items.items.len >= max_items) null else resp.next_link; }
    return .{ .items = items.items, .next_link = if (last) |l| l.next_link else null, .last = last.? };
}

fn opAuthStatus(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const env = envMap(arena); var host: []const u8 = "github.com"; var owner: []const u8 = ""; var repo_name: []const u8 = ""; var repo_source: []const u8 = "unresolved"; var remote_url: []const u8 = "";
    if (common.getStr(obj, "repo")) |explicit| { const t = std.mem.trim(u8, explicit, " \t\r\n"); if (std.mem.indexOfScalar(u8, t, '/')) |slash| { owner = t[0..slash]; repo_name = t[slash + 1 ..]; if (owner.len == 0 or repo_name.len == 0) return "github auth_status: `repo` must be owner/name"; repo_source = "explicit"; if (context.resolve(arena, io)) |r| { if (std.ascii.eqlIgnoreCase(r.owner, owner) and std.ascii.eqlIgnoreCase(r.repo, repo_name)) { host = r.host; remote_url = r.url; repo_source = "explicit (matches git remote)"; } } } else return "github auth_status: `repo` must be owner/name"; } else if (context.resolve(arena, io)) |r| { host = r.host; owner = r.owner; repo_name = r.repo; remote_url = r.url; repo_source = "git remote"; }
    const auth = api.resolveToken(arena, io, env, host);
    var out: std.ArrayList(u8) = .empty; try out.appendSlice(arena, "github auth status:\n");
    if (owner.len > 0 and repo_name.len > 0) { try out.print(arena, "repo: {s}/{s} (host={s}, source={s})\n", .{ owner, repo_name, host, repo_source }); } else { try out.print(arena, "repo: unresolved (host={s})\n", .{host}); }
    if (remote_url.len > 0) try out.print(arena, "remote: {s}\n", .{remote_url});
    if (context.currentBranch(arena, io)) |b| try out.print(arena, "branch: {s}\n", .{b});
    try out.print(arena, "token: {s}\n", .{if (auth.token != null) "configured" else "not configured"});
    try out.print(arena, "token_source: {s}\n", .{auth.source});
    if (auth.token == null) { try out.appendSlice(arena, "hint: set GITHUB_TOKEN or GH_TOKEN, or save a token in ~/.config/zode/auth.json as \"github\", \"github:<host>\", or \"github.com\".\n"); } else { try out.appendSlice(arena, "note: token value is never shown. Use `whoami` to verify API access.\n"); }
    return out.items;
}

fn opWhoami(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    const env = envMap(arena); const auth = api.resolveToken(arena, io, env, "github.com");
    if (auth.token == null) return "github whoami: no token configured (checked GITHUB_TOKEN, GH_TOKEN, ~/.config/zode/auth.json). Set a token to access authenticated endpoints.";
    const url = try api.buildUrl(arena, api.default_api_base, "/user");
    const resp = api.request(arena, io, .GET, url, auth.token, null) catch |err| return std.fmt.allocPrint(arena, "github whoami: request failed ({s})", .{@errorName(err)}) catch "github whoami: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, true);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github whoami: could not parse response";
    if (v != .object) return "github whoami: unexpected response";
    const u = types.parseUser(v.object);
    if (u.login.len == 0) return "github whoami: authenticated but login not found in response";
    var out: std.ArrayList(u8) = .empty;
    if (u.name.len > 0) { try out.print(arena, "github user: {s} ({s})\nurl: {s}\nauth: {s}\n", .{ u.login, u.name, u.html_url, auth.source }); } else { try out.print(arena, "github user: {s}\nurl: {s}\nauth: {s}\n", .{ u.login, u.html_url, auth.source }); }
    try appendMeta(&out, arena, resp);
    return out.items;
}

fn opRepo(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github repo: `repo` must be owner/name" };
    var path_buf: [512]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}", .{ r.owner, r.repo }) catch return "github repo: path too long";
    const resp = doRequest(arena, io, .GET, r, path, null) catch |err| return std.fmt.allocPrint(arena, "github repo: request failed ({s})", .{@errorName(err)}) catch "github repo: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, r.token != null);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github repo: could not parse response";
    if (v != .object) return "github repo: unexpected response";
    const repo = types.parseRepo(v.object);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "repo: {s}\nhost: {s}\ndefault_branch: {s}\nprivate: {s}\nurl: {s}{s}{s}\n", .{ repo.full_name, r.host, if (repo.default_branch.len > 0) repo.default_branch else "(unknown)", if (repo.private) "yes" else "no", if (repo.html_url.len > 0) repo.html_url else "", if (repo.description.len > 0) "\ndescription: " else "", if (repo.description.len > 0) repo.description else "" });
    try appendMeta(&out, arena, resp);
    return out.items;
}

fn opPrList(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github pr_list: `repo` must be owner/name" };
    const limit = clampLimit(obj, 20, 50); const state = common.getStr(obj, "state") orelse "open"; const head = common.getStr(obj, "head");
    var path_buf: [1024]u8 = undefined;
    const path = if (head) |h| std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls?state={s}&head={s}&per_page={d}", .{ r.owner, r.repo, urlEncode(arena, state), urlEncode(arena, h), @min(limit, @as(usize, 50)) }) catch return "github pr_list: path too long" else std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls?state={s}&per_page={d}", .{ r.owner, r.repo, urlEncode(arena, state), @min(limit, @as(usize, 50)) }) catch return "github pr_list: path too long";
    const collected = collectArrayPages(io, arena, r, path, limit) catch |err| switch (err) { error.ApiStatus => { const resp = doRequest(arena, io, .GET, r, path, null) catch |e| return std.fmt.allocPrint(arena, "github pr_list: request failed ({s})", .{@errorName(e)}) catch "github pr_list: request failed"; return api.errorMessage(arena, resp, r.token != null); }, else => return std.fmt.allocPrint(arena, "github pr_list: request failed ({s})", .{@errorName(err)}) catch "github pr_list: request failed" };
    if (collected.items.len == 0) return "no pull requests found.";
    var out: std.ArrayList(u8) = .empty; try out.print(arena, "pull requests ({d}):\n", .{collected.items.len});
    for (collected.items) |item| { if (item != .object) continue; const pr = types.parsePullRequest(item.object); try out.print(arena, "- #{d} [{s}{s}] {s} ({s} -> {s})", .{ pr.number, pr.state, if (pr.draft) ",draft" else "", pr.title, pr.head_ref, pr.base_ref }); if (pr.html_url.len > 0) try out.print(arena, " {s}", .{pr.html_url}); try out.append(arena, '\n'); }
    if (collected.next_link != null) try out.appendSlice(arena, "more: yes (additional pages available)\n");
    if (collected.last.rate_remaining) |rr| if (rr <= 20) try out.print(arena, "rate_remaining: {d}\n", .{rr});
    return out.items;
}

fn opPrView(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github pr_view: `repo` must be owner/name" };
    const number = common.getInt(obj, "number") orelse return "github pr_view needs `number`.";
    var path_buf: [256]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}", .{ r.owner, r.repo, number }) catch return "github pr_view: path too long";
    const resp = doRequest(arena, io, .GET, r, path, null) catch |err| return std.fmt.allocPrint(arena, "github pr_view: request failed ({s})", .{@errorName(err)}) catch "github pr_view: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, r.token != null);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github pr_view: could not parse response";
    if (v != .object) return "github pr_view: unexpected response";
    const pr = types.parsePullRequest(v.object);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "PR #{d}: {s}\nstate: {s}{s}{s}\nhead: {s} ({s})\nbase: {s}\nauthor: {s}\nurl: {s}", .{ pr.number, pr.title, pr.state, if (pr.draft) " (draft)" else "", if (pr.merged) " (merged)" else "", pr.head_ref, pr.head_sha, pr.base_ref, pr.user_login, pr.html_url });
    if (pr.mergeable_state.len > 0) try out.print(arena, "\nmergeable_state: {s}", .{pr.mergeable_state});
    if (pr.body.len > 0) { const preview_len = @min(pr.body.len, 600); try out.print(arena, "\nbody: {s}{s}", .{ pr.body[0..preview_len], if (pr.body.len > preview_len) "\n...(truncated)" else "" }); }
    try out.append(arena, '\n'); try appendMeta(&out, arena, resp);
    return out.items;
}

fn opPrChecks(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github pr_checks: `repo` must be owner/name" };
    const number = common.getInt(obj, "number") orelse return "github pr_checks needs `number`.";
    var pr_path_buf: [256]u8 = undefined; const pr_path = std.fmt.bufPrint(&pr_path_buf, "/repos/{s}/{s}/pulls/{d}", .{ r.owner, r.repo, number }) catch return "github pr_checks: path too long";
    const pr_resp = doRequest(arena, io, .GET, r, pr_path, null) catch |err| return std.fmt.allocPrint(arena, "github pr_checks: request failed ({s})", .{@errorName(err)}) catch "github pr_checks: request failed";
    if (pr_resp.status < 200 or pr_resp.status >= 300) return api.errorMessage(arena, pr_resp, r.token != null);
    const prv = std.json.parseFromSliceLeaky(std.json.Value, arena, pr_resp.body, .{}) catch return "github pr_checks: could not parse PR response";
    if (prv != .object) return "github pr_checks: unexpected PR response";
    const pr = types.parsePullRequest(prv.object);
    if (pr.head_sha.len == 0) return "github pr_checks: could not determine PR head SHA";
    var path_buf: [512]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/commits/{s}/check-runs?per_page=100", .{ r.owner, r.repo, pr.head_sha }) catch return "github pr_checks: path too long";
    const collected = collectCheckRunsPages(io, arena, r, path, 200) catch |err| switch (err) { error.ApiStatus => { const resp = doRequest(arena, io, .GET, r, path, null) catch |e| return std.fmt.allocPrint(arena, "github pr_checks: request failed ({s})", .{@errorName(e)}) catch "github pr_checks: request failed"; return api.errorMessage(arena, resp, r.token != null); }, else => return std.fmt.allocPrint(arena, "github pr_checks: request failed ({s})", .{@errorName(err)}) catch "github pr_checks: request failed" };
    if (collected.items.len == 0) return std.fmt.allocPrint(arena, "PR #{d} ({s}): no check runs", .{ number, pr.head_sha }) catch "no check runs";
    var passed: usize = 0; var failed: usize = 0; var pending: usize = 0; var other: usize = 0;
    for (collected.items) |item| { if (item != .object) continue; const conclusion = types.getStr(item.object, "conclusion") orelse ""; if (std.ascii.eqlIgnoreCase(conclusion, "success") or std.ascii.eqlIgnoreCase(conclusion, "skipped") or std.ascii.eqlIgnoreCase(conclusion, "neutral")) { passed += 1; } else if (std.ascii.eqlIgnoreCase(conclusion, "failure") or std.ascii.eqlIgnoreCase(conclusion, "timed_out") or std.ascii.eqlIgnoreCase(conclusion, "cancelled") or std.ascii.eqlIgnoreCase(conclusion, "action_required") or std.ascii.eqlIgnoreCase(conclusion, "startup_failure")) { failed += 1; } else if (conclusion.len == 0) { pending += 1; } else { other += 1; } }
    var out: std.ArrayList(u8) = .empty; try out.print(arena, "PR #{d} checks ({s}, {d} runs): passed={d} failed={d} pending={d}", .{ number, pr.head_sha, collected.items.len, passed, failed, pending }); if (other > 0) try out.print(arena, " other={d}", .{other}); try out.append(arena, '\n');
    for (collected.items) |item| { if (item != .object) continue; const o = item.object; const name = types.getStr(o, "name") orelse "(unnamed)"; const status = types.getStr(o, "status") orelse "unknown"; const conclusion = types.getStr(o, "conclusion") orelse ""; const details = types.getStr(o, "details_url") orelse types.getStr(o, "html_url") orelse ""; try out.print(arena, "- {s}: {s}", .{ name, status }); if (conclusion.len > 0) try out.print(arena, "/{s}", .{conclusion}); if (details.len > 0) try out.print(arena, " {s}", .{details}); try out.append(arena, '\n'); }
    if (collected.next_link != null) try out.appendSlice(arena, "more: yes (additional pages available)\n");
    if (collected.last.rate_remaining) |rr| if (rr <= 20) try out.print(arena, "rate_remaining: {d}\n", .{rr});
    return out.items;
}

fn opIssueList(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github issue_list: `repo` must be owner/name" };
    const limit = clampLimit(obj, 20, 50); const state = common.getStr(obj, "state") orelse "open";
    var path_buf: [512]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/issues?state={s}&per_page={d}", .{ r.owner, r.repo, urlEncode(arena, state), @min(limit, @as(usize, 50)) }) catch return "github issue_list: path too long";
    const collected = collectArrayPages(io, arena, r, path, limit) catch |err| switch (err) { error.ApiStatus => { const resp = doRequest(arena, io, .GET, r, path, null) catch |e| return std.fmt.allocPrint(arena, "github issue_list: request failed ({s})", .{@errorName(e)}) catch "github issue_list: request failed"; return api.errorMessage(arena, resp, r.token != null); }, else => return std.fmt.allocPrint(arena, "github issue_list: request failed ({s})", .{@errorName(err)}) catch "github issue_list: request failed" };
    var count: usize = 0; var lines: std.ArrayList(u8) = .empty;
    for (collected.items) |item| { if (item != .object) continue; if (item.object.get("pull_request") != null) continue; const issue = types.parseIssue(item.object); try lines.print(arena, "- #{d} [{s}] {s}", .{ issue.number, issue.state, issue.title }); if (issue.html_url.len > 0) try lines.print(arena, " {s}", .{issue.html_url}); try lines.append(arena, '\n'); count += 1; }
    if (count == 0) return "no issues found.";
    var out: std.ArrayList(u8) = .empty; try out.print(arena, "issues ({d}):\n{s}", .{ count, lines.items });
    if (collected.next_link != null) try out.appendSlice(arena, "more: yes (additional pages available)\n");
    if (collected.last.rate_remaining) |rr| if (rr <= 20) try out.print(arena, "rate_remaining: {d}\n", .{rr});
    return out.items;
}

fn opIssueView(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github issue_view: `repo` must be owner/name" };
    const number = common.getInt(obj, "number") orelse return "github issue_view needs `number`.";
    var path_buf: [256]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/issues/{d}", .{ r.owner, r.repo, number }) catch return "github issue_view: path too long";
    const resp = doRequest(arena, io, .GET, r, path, null) catch |err| return std.fmt.allocPrint(arena, "github issue_view: request failed ({s})", .{@errorName(err)}) catch "github issue_view: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, r.token != null);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github issue_view: could not parse response";
    if (v != .object) return "github issue_view: unexpected response";
    const issue = types.parseIssue(v.object);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "Issue #{d}: {s}\nstate: {s}\nauthor: {s}\nurl: {s}", .{ issue.number, issue.title, issue.state, issue.user_login, issue.html_url });
    if (issue.body.len > 0) { const preview_len = @min(issue.body.len, 800); try out.print(arena, "\nbody: {s}{s}", .{ issue.body[0..preview_len], if (issue.body.len > preview_len) "\n...(truncated)" else "" }); }
    try out.append(arena, '\n'); try appendMeta(&out, arena, resp);
    return out.items;
}

fn opActionsRuns(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github actions_runs: `repo` must be owner/name" };
    const limit = clampLimit(obj, 20, 50); const branch = common.getStr(obj, "branch");
    var path_buf: [1024]u8 = undefined;
    const path = if (branch) |b| std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/actions/runs?per_page={d}&branch={s}", .{ r.owner, r.repo, @min(limit, @as(usize, 50)), urlEncode(arena, b) }) catch return "github actions_runs: path too long" else std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/actions/runs?per_page={d}", .{ r.owner, r.repo, @min(limit, @as(usize, 50)) }) catch return "github actions_runs: path too long";
    const collected = collectWorkflowRunsPages(io, arena, r, path, limit) catch |err| switch (err) { error.ApiStatus => { const resp = doRequest(arena, io, .GET, r, path, null) catch |e| return std.fmt.allocPrint(arena, "github actions_runs: request failed ({s})", .{@errorName(e)}) catch "github actions_runs: request failed"; return api.errorMessage(arena, resp, r.token != null); }, else => return std.fmt.allocPrint(arena, "github actions_runs: request failed ({s})", .{@errorName(err)}) catch "github actions_runs: request failed" };
    if (collected.items.len == 0) return "no workflow runs found.";
    var out: std.ArrayList(u8) = .empty; try out.print(arena, "workflow runs ({d})", .{collected.items.len}); if (branch) |b| try out.print(arena, " branch={s}", .{b}); try out.appendSlice(arena, ":\n");
    for (collected.items) |item| { if (item != .object) continue; const o = item.object; const id = types.getInt(o, "id") orelse 0; const name_w = types.getStr(o, "name") orelse types.getStr(o, "display_title") orelse "(workflow)"; const status = types.getStr(o, "status") orelse "unknown"; const conclusion = types.getStr(o, "conclusion") orelse ""; const head_branch = types.getStr(o, "head_branch") orelse ""; const url = types.getStr(o, "html_url") orelse ""; try out.print(arena, "- #{d} {s} [{s}", .{ id, name_w, status }); if (conclusion.len > 0) try out.print(arena, "/{s}", .{conclusion}); try out.append(arena, ']'); if (head_branch.len > 0) try out.print(arena, " branch={s}", .{head_branch}); if (url.len > 0) try out.print(arena, " {s}", .{url}); try out.append(arena, '\n'); }
    if (collected.next_link != null) try out.appendSlice(arena, "more: yes (additional pages available)\n");
    if (collected.last.rate_remaining) |rr| if (rr <= 20) try out.print(arena, "rate_remaining: {d}\n", .{rr});
    return out.items;
}

fn opPrCreate(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github pr_create: `repo` must be owner/name" };
    if (r.token == null) return "github pr_create requires authentication. Set GITHUB_TOKEN/GH_TOKEN or save a token in ~/.config/zode/auth.json.";
    const title = common.getStr(obj, "title") orelse return "github pr_create needs `title`.";
    const head = common.getStr(obj, "head") orelse blk: { break :blk context.currentBranch(arena, io) orelse return "github pr_create needs `head` (or run from a git branch)."; };
    const base = common.getStr(obj, "base") orelse "main"; const body = common.getStr(obj, "body") orelse ""; const draft = common.getBool(obj, "draft");
    var list_path_buf: [1024]u8 = undefined; const owner_prefix = std.fmt.allocPrint(arena, "{s}:{s}", .{ r.owner, head }) catch head; const list_path = std.fmt.bufPrint(&list_path_buf, "/repos/{s}/{s}/pulls?state=open&head={s}&per_page=10", .{ r.owner, r.repo, urlEncode(arena, owner_prefix) }) catch null;
    if (list_path) |lp| { if (doRequest(arena, io, .GET, r, lp, null)) |resp| { if (resp.status >= 200 and resp.status < 300) { if (std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{})) |v| { if (v == .array and v.array.items.len > 0) { if (v.array.items[0] == .object) { const existing = types.parsePullRequest(v.array.items[0].object); if (existing.number > 0) { return std.fmt.allocPrint(arena, "existing open PR found (idempotent): #{d} {s}\nurl: {s}", .{ existing.number, existing.title, existing.html_url }) catch "existing open PR found"; } } } } else |_| {} } } else |_| {} }
    var path_buf: [512]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls", .{ r.owner, r.repo }) catch return "github pr_create: path too long";
    const Payload = struct { title: []const u8, head: []const u8, base: []const u8, body: []const u8, draft: bool };
    const resp = api.requestJson(arena, io, .POST, try api.buildUrl(arena, r.api_base, path), r.token, Payload{ .title = title, .head = head, .base = base, .body = body, .draft = draft }) catch |err| return std.fmt.allocPrint(arena, "github pr_create: request failed ({s})", .{@errorName(err)}) catch "github pr_create: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, true);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github pr_create: created but could not parse response";
    if (v != .object) return "github pr_create: created (unexpected response shape)";
    const pr = types.parsePullRequest(v.object);
    return std.fmt.allocPrint(arena, "created PR #{d}: {s}\nurl: {s}\nhead: {s} -> base: {s}", .{ pr.number, pr.title, pr.html_url, pr.head_ref, pr.base_ref }) catch "created PR";
}

fn opPrUpdate(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github pr_update: `repo` must be owner/name" };
    if (r.token == null) return "github pr_update requires authentication. Set GITHUB_TOKEN/GH_TOKEN or save a token in ~/.config/zode/auth.json.";
    const number = common.getInt(obj, "number") orelse return "github pr_update needs `number`.";
    const title = common.getStr(obj, "title"); const body = common.getStr(obj, "body"); const base = common.getStr(obj, "base"); const state = common.getStr(obj, "state");
    if (title == null and body == null and base == null and state == null) return "github pr_update needs at least one of: title, body, base, state.";
    var path_buf: [256]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/pulls/{d}", .{ r.owner, r.repo, number }) catch return "github pr_update: path too long";
    var buf = std.Io.Writer.Allocating.init(arena); const w = &buf.writer; try w.writeAll("{"); var first = true;
    if (title) |t| { try w.writeAll("\"title\":"); try std.json.Stringify.value(t, .{}, w); first = false; }
    if (body) |b| { if (!first) try w.writeAll(","); try w.writeAll("\"body\":"); try std.json.Stringify.value(b, .{}, w); first = false; }
    if (base) |b| { if (!first) try w.writeAll(","); try w.writeAll("\"base\":"); try std.json.Stringify.value(b, .{}, w); first = false; }
    if (state) |s| { if (!first) try w.writeAll(","); try w.writeAll("\"state\":"); try std.json.Stringify.value(s, .{}, w); first = false; }
    try w.writeAll("}");
    const resp = api.request(arena, io, .PATCH, try api.buildUrl(arena, r.api_base, path), r.token, buf.written()) catch |err| return std.fmt.allocPrint(arena, "github pr_update: request failed ({s})", .{@errorName(err)}) catch "github pr_update: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, true);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github pr_update: updated but could not parse response";
    if (v != .object) return "github pr_update: updated";
    const pr = types.parsePullRequest(v.object);
    return std.fmt.allocPrint(arena, "updated PR #{d}: {s}\nurl: {s}", .{ pr.number, pr.title, pr.html_url }) catch "updated PR";
}

fn opPrComment(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github pr_comment: `repo` must be owner/name" };
    if (r.token == null) return "github pr_comment requires authentication. Set GITHUB_TOKEN/GH_TOKEN or save a token in ~/.config/zode/auth.json.";
    const number = common.getInt(obj, "number") orelse return "github pr_comment needs `number`."; const body = common.getStr(obj, "body") orelse return "github pr_comment needs `body`.";
    var path_buf: [256]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/issues/{d}/comments", .{ r.owner, r.repo, number }) catch return "github pr_comment: path too long";
    const Payload = struct { body: []const u8 };
    const resp = api.requestJson(arena, io, .POST, try api.buildUrl(arena, r.api_base, path), r.token, Payload{ .body = body }) catch |err| return std.fmt.allocPrint(arena, "github pr_comment: request failed ({s})", .{@errorName(err)}) catch "github pr_comment: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, true);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github pr_comment: posted";
    if (v == .object) { if (types.getStr(v.object, "html_url")) |url| { return std.fmt.allocPrint(arena, "posted comment on #{d}: {s}", .{ number, url }) catch "posted comment"; } }
    return std.fmt.allocPrint(arena, "posted comment on #{d}", .{number}) catch "posted comment";
}

fn opIssueCreate(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github issue_create: `repo` must be owner/name" };
    if (r.token == null) return "github issue_create requires authentication. Set GITHUB_TOKEN/GH_TOKEN or save a token in ~/.config/zode/auth.json.";
    const title = common.getStr(obj, "title") orelse return "github issue_create needs `title`."; const body = common.getStr(obj, "body") orelse "";
    var path_buf: [256]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/issues", .{ r.owner, r.repo }) catch return "github issue_create: path too long";
    const Payload = struct { title: []const u8, body: []const u8 };
    const resp = api.requestJson(arena, io, .POST, try api.buildUrl(arena, r.api_base, path), r.token, Payload{ .title = title, .body = body }) catch |err| return std.fmt.allocPrint(arena, "github issue_create: request failed ({s})", .{@errorName(err)}) catch "github issue_create: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, true);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github issue_create: created but could not parse response";
    if (v != .object) return "github issue_create: created";
    const issue = types.parseIssue(v.object);
    return std.fmt.allocPrint(arena, "created issue #{d}: {s}\nurl: {s}", .{ issue.number, issue.title, issue.html_url }) catch "created issue";
}

fn opIssueComment(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const r = resolveRepo(io, obj, arena) catch |err| switch (err) { error.NoGitHubContext => return noContextMsg(), error.BadArgs => return "github issue_comment: `repo` must be owner/name" };
    if (r.token == null) return "github issue_comment requires authentication. Set GITHUB_TOKEN/GH_TOKEN or save a token in ~/.config/zode/auth.json.";
    const number = common.getInt(obj, "number") orelse return "github issue_comment needs `number`."; const body = common.getStr(obj, "body") orelse return "github issue_comment needs `body`.";
    var path_buf: [256]u8 = undefined; const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/issues/{d}/comments", .{ r.owner, r.repo, number }) catch return "github issue_comment: path too long";
    const Payload = struct { body: []const u8 };
    const resp = api.requestJson(arena, io, .POST, try api.buildUrl(arena, r.api_base, path), r.token, Payload{ .body = body }) catch |err| return std.fmt.allocPrint(arena, "github issue_comment: request failed ({s})", .{@errorName(err)}) catch "github issue_comment: request failed";
    if (resp.status < 200 or resp.status >= 300) return api.errorMessage(arena, resp, true);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return "github issue_comment: posted";
    if (v == .object) { if (types.getStr(v.object, "html_url")) |url| { return std.fmt.allocPrint(arena, "posted comment on issue #{d}: {s}", .{ number, url }) catch "posted comment"; } }
    return std.fmt.allocPrint(arena, "posted comment on issue #{d}", .{number}) catch "posted comment";
}

pub fn subjectOf(obj: std.json.ObjectMap, arena: std.mem.Allocator) ?[]const u8 {
    const op = common.getStr(obj, "operation") orelse return null;
    if (isWriteOp(op)) { return std.fmt.allocPrint(arena, "github.{s}", .{op}) catch "github"; }
    return null;
}

pub fn isWriteOp(op: []const u8) bool {
    return std.ascii.eqlIgnoreCase(op, "pr_create") or std.ascii.eqlIgnoreCase(op, "pr_update") or std.ascii.eqlIgnoreCase(op, "pr_comment") or std.ascii.eqlIgnoreCase(op, "issue_create") or std.ascii.eqlIgnoreCase(op, "issue_comment");
}

pub fn isReadOp(op: []const u8) bool {
    return std.ascii.eqlIgnoreCase(op, "auth_status") or std.ascii.eqlIgnoreCase(op, "whoami") or std.ascii.eqlIgnoreCase(op, "repo") or std.ascii.eqlIgnoreCase(op, "pr_list") or std.ascii.eqlIgnoreCase(op, "pr_view") or std.ascii.eqlIgnoreCase(op, "pr_checks") or std.ascii.eqlIgnoreCase(op, "issue_list") or std.ascii.eqlIgnoreCase(op, "issue_view") or std.ascii.eqlIgnoreCase(op, "actions_runs");
}

/// Is this an operation the gateway knows?
///
/// The answer decides what happens to a name that is NOT in the table: it
/// asks for permission instead of running free. A name nobody recognizes is
/// one the harness cannot reason about, and the direction that is safe to be
/// wrong in is the one that asks.
pub fn isKnownOp(op: []const u8) bool {
    return isReadOp(op) or isWriteOp(op);
}

test "github: isWriteOp/isReadOp classify operations" {
    try std.testing.expect(isReadOp("auth_status"));
    try std.testing.expect(isReadOp("pr_view"));
    try std.testing.expect(isReadOp("WHOAMI"));
    try std.testing.expect(!isReadOp("pr_create"));
    try std.testing.expect(isWriteOp("pr_create"));
    try std.testing.expect(isWriteOp("issue_comment"));
    try std.testing.expect(!isWriteOp("pr_list"));
}

test "github: subjectOf only for write ops" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const read_v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"operation\":\"pr_view\",\"number\":1}", .{});
    try std.testing.expect(subjectOf(read_v.object, a) == null);
    const auth_v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"operation\":\"auth_status\"}", .{});
    try std.testing.expect(subjectOf(auth_v.object, a) == null);
    const write_v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"operation\":\"pr_create\",\"title\":\"x\"}", .{});
    const s = subjectOf(write_v.object, a).?;
    try std.testing.expectEqualStrings("github.pr_create", s);
}

test "github: unknown operation returns helpful message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"operation\":\"explode\"}", .{});
    const out = try toolGithub(std.testing.io, v.object, a);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown github operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "auth_status") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pr_view") != null);
}

test "github: isKnownOp knows every operation the gateway dispatches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ops = [_][]const u8{
        "auth_status", "whoami",           "repo",          "pr_list", "pr_view",
        "pr_checks",  "pr_create",         "pr_update",     "pr_comment", "issue_list",
        "issue_view", "issue_create",      "issue_comment", "actions_runs",
    };
    for (ops) |op| {
        try std.testing.expect(isKnownOp(op));
        const upper = try std.ascii.allocUpperString(a, op);
        try std.testing.expect(isKnownOp(upper));
    }
    try std.testing.expect(!isKnownOp("explode"));
    try std.testing.expect(!isKnownOp(""));
}

test "github: auth_status never prints a token value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"operation\":\"auth_status\"}", .{});
    const out = try toolGithub(std.testing.io, v.object, a);
    // The state is in words ("configured" / "not configured"), never in bytes.
    try std.testing.expect(std.mem.indexOf(u8, out, "token: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "configured") != null);
    // A token has a shape; the output has none.
    try std.testing.expect(std.mem.indexOf(u8, out, "ghp_") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "github_pat_") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "gho_") == null);
}

test "github: urlEncode escapes what a query string cannot carry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("main", urlEncode(a, "main"));
    try std.testing.expectEqualStrings("feature%2Fx", urlEncode(a, "feature/x"));
    try std.testing.expectEqualStrings("a%20b", urlEncode(a, "a b"));
    try std.testing.expectEqualStrings("a%26b%3Dc", urlEncode(a, "a&b=c"));
    try std.testing.expectEqualStrings("%2F", urlEncode(a, "/"));
    try std.testing.expectEqualStrings("owner%3Abranch", urlEncode(a, "owner:branch"));
}
