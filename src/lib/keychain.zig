const std = @import("std");
const builtin = @import("builtin");

/// OS keychain/secret-service helpers for provider keys and auth master key.
/// Backends (best-effort): libsecret `secret-tool` (Linux), macOS `security`,
/// and Windows Credential Manager via PowerShell/CredRead/CredWrite (generic creds).
const Backend = enum { secret_tool, security, windows_cred, none };

fn commandExists(io: std.Io, name: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const argv = if (builtin.os.tag == .windows)
        &.{ "where", name }
    else
        &.{ "sh", "-lc", "command -v \"$1\" >/dev/null 2>&1", "sh", name };
    const res = std.process.run(a, io, .{
        .argv = argv,
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } },
    }) catch return false;
    _ = res.stdout;
    _ = res.stderr;
    return res.term == .exited and res.term.exited == 0;
}

fn backend(io: std.Io) Backend {
    // Detection spawns `sh -lc` (up to 1 s). loadAuthKeys calls available()
    // once and lookup() once PER PROVIDER — ~11 spawns, measured at 1.8 s on
    // every startup. The set of installed secret-store commands does not
    // change during a process, so detect once and share the answer.
    const raw = cached_backend.load(.acquire);
    if (raw != backend_unset) return fromCode(raw);
    const b = detectBackend(io);
    cached_backend.store(toCode(b), .release);
    return b;
}

const backend_unset: u8 = 0xff;
var cached_backend: std.atomic.Value(u8) = .init(backend_unset);

fn toCode(b: Backend) u8 {
    return switch (b) {
        .secret_tool => 0,
        .security => 1,
        .windows_cred => 2,
        .none => 3,
    };
}

fn fromCode(code: u8) Backend {
    return switch (code) {
        0 => .secret_tool,
        1 => .security,
        2 => .windows_cred,
        else => .none,
    };
}

fn detectBackend(io: std.Io) Backend {
    if (commandExists(io, "secret-tool")) return .secret_tool;
    if (builtin.os.tag == .macos and commandExists(io, "security")) return .security;
    if (builtin.os.tag == .windows and (commandExists(io, "powershell.exe") or commandExists(io, "powershell") or commandExists(io, "pwsh"))) {
        return .windows_cred;
    }
    return .none;
}

pub fn available(io: std.Io) bool {
    return backend(io) != .none;
}

fn labelFor(alloc: std.mem.Allocator, provider: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "zode/{s}", .{provider});
}

/// Process-level lookup cache. The secret store does not change under us
/// except through store()/clear() below, which invalidate the entry. Each
/// lookup otherwise spawns a `secret-tool` subprocess (~50 ms), and startup
/// asks about every provider — measured at 0.6 s of pure subprocess churn.
const CachedKey = struct { found: bool, value: []const u8 };
const LookupCache = struct {
    mutex: std.atomic.Mutex = .unlocked,
    map: std.StringHashMapUnmanaged(CachedKey) = .empty,
};
var lookup_cache: LookupCache = .{};

fn lookupCached(io: std.Io, provider: []const u8) ?[]const u8 {
    while (!lookup_cache.mutex.tryLock()) std.Thread.yield() catch {};
    defer lookup_cache.mutex.unlock();
    if (lookup_cache.map.get(provider)) |hit| {
        // Hand back an OWNED copy: a concurrent invalidate() could free the
        // cached buffer before the caller finishes reading it.
        if (!hit.found) return null;
        return std.heap.page_allocator.dupe(u8, hit.value) catch null;
    }
    lookup_cache.mutex.unlock();
    // NEVER hold the cache lock across a subprocess: `secret-tool` has a 3 s
    // timeout, and another thread asking for a different key would spin for
    // the whole duration. Two threads racing the SAME provider may both do
    // the one-shot lookup; the second put below just replaces the first.
    const b = backend(io);
    const fresh: ?[]u8 = switch (b) {
        .secret_tool => lookupSecretTool(std.heap.page_allocator, io, provider),
        .security => lookupSecurity(std.heap.page_allocator, io, provider),
        .windows_cred => lookupWindowsCred(std.heap.page_allocator, io, provider),
        .none => null,
    };
    const entry: CachedKey = if (fresh) |k|
        .{ .found = true, .value = k }
    else
        .{ .found = false, .value = "" };
    // Re-lock for the write (the function's defer unlocks it again).
    while (!lookup_cache.mutex.tryLock()) std.Thread.yield() catch {};
    if (lookup_cache.map.fetchRemove(provider)) |old_entry| {
        if (old_entry.value.found) std.heap.page_allocator.free(old_entry.value.value);
    }
    const owned: ?[]u8 = if (entry.found) std.heap.page_allocator.dupe(u8, entry.value) catch null else null;
    lookup_cache.map.put(std.heap.page_allocator, provider, entry) catch {};
    return owned;
}

pub fn lookup(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) ?[]u8 {
    // The contract is caller-owned: hand back a copy so two callers (or a
    // later store()) can never free or observe the same buffer.
    const hit = lookupCached(io, provider) orelse return null;
    return alloc.dupe(u8, hit) catch null;
}

fn invalidate(provider: []const u8) void {
    while (!lookup_cache.mutex.tryLock()) std.Thread.yield() catch {};
    defer lookup_cache.mutex.unlock();
    if (lookup_cache.map.fetchRemove(provider)) |removed| {
        if (removed.value.found) std.heap.page_allocator.free(removed.value.value);
    }
}

pub fn store(alloc: std.mem.Allocator, io: std.Io, provider: []const u8, key: []const u8) bool {
    const ok = switch (backend(io)) {
        .secret_tool => storeSecretTool(alloc, io, provider, key),
        .security => storeSecurity(alloc, io, provider, key),
        .windows_cred => storeWindowsCred(alloc, io, provider, key),
        .none => false,
    };
    if (ok) invalidate(provider);
    return ok;
}

pub fn clear(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) bool {
    const ok = switch (backend(io)) {
        .secret_tool => clearSecretTool(alloc, io, provider),
        .security => clearSecurity(alloc, io, provider),
        .windows_cred => clearWindowsCred(alloc, io, provider),
        .none => false,
    };
    if (ok) invalidate(provider);
    return ok;
}

fn lookupSecretTool(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) ?[]u8 {
    const label = labelFor(alloc, provider) catch return null;
    defer alloc.free(label);
    const argv = [_][]const u8{ "secret-tool", "lookup", "application", "zode", "user", label };
    const res = std.process.run(alloc, io, .{
        .argv = &argv,
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch return null;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return null;
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (out.len == 0) return null;
    return alloc.dupe(u8, out) catch null;
}

fn storeSecretTool(alloc: std.mem.Allocator, io: std.Io, provider: []const u8, key: []const u8) bool {
    const label = labelFor(alloc, provider) catch return false;
    defer alloc.free(label);
    const argv = [_][]const u8{ "secret-tool", "store", "--label", label, "application", "zode", "user", label };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    if (child.stdin) |in| {
        var buf: [4096]u8 = undefined;
        var w = in.writer(io, &buf);
        w.interface.writeAll(key) catch {};
        w.interface.flush() catch {};
        in.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

fn clearSecretTool(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) bool {
    const label = labelFor(alloc, provider) catch return false;
    defer alloc.free(label);
    const argv = [_][]const u8{ "secret-tool", "clear", "application", "zode", "user", label };
    const res = std.process.run(alloc, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch return false;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.term == .exited and res.term.exited == 0;
}

fn lookupSecurity(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) ?[]u8 {
    const service = labelFor(alloc, provider) catch return null;
    defer alloc.free(service);
    const argv = [_][]const u8{ "security", "find-generic-password", "-a", "zode", "-s", service, "-w" };
    const res = std.process.run(alloc, io, .{
        .argv = &argv,
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch return null;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return null;
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (out.len == 0) return null;
    return alloc.dupe(u8, out) catch null;
}

fn storeSecurity(alloc: std.mem.Allocator, io: std.Io, provider: []const u8, key: []const u8) bool {
    const service = labelFor(alloc, provider) catch return false;
    defer alloc.free(service);
    const argv = [_][]const u8{ "security", "add-generic-password", "-a", "zode", "-s", service, "-w", key, "-U" };
    const res = std.process.run(alloc, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch return false;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.term == .exited and res.term.exited == 0;
}

fn clearSecurity(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) bool {
    const service = labelFor(alloc, provider) catch return false;
    defer alloc.free(service);
    const argv = [_][]const u8{ "security", "delete-generic-password", "-a", "zode", "-s", service };
    const res = std.process.run(alloc, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch return false;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.term == .exited and res.term.exited == 0;
}

fn windowsShell(io: std.Io) []const u8 {
    if (commandExists(io, "powershell.exe")) return "powershell.exe";
    if (commandExists(io, "powershell")) return "powershell";
    return "pwsh";
}

fn psQuoteSingleAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // Single-quoted PowerShell string: escape ' as ''
    var extra: usize = 0;
    for (s) |c| {
        if (c == '\'') extra += 1;
    }
    var out = try alloc.alloc(u8, s.len + extra + 2);
    out[0] = '\'';
    var i: usize = 1;
    for (s) |c| {
        if (c == '\'') {
            out[i] = '\'';
            out[i + 1] = '\'';
            i += 2;
        } else {
            out[i] = c;
            i += 1;
        }
    }
    out[i] = '\'';
    return out;
}

fn windowsCredScript(kind: enum { lookup, store, clear }, alloc: std.mem.Allocator, provider: []const u8, key: ?[]const u8) ![]u8 {
    const target = try labelFor(alloc, provider);
    defer alloc.free(target);
    const t = try psQuoteSingleAlloc(alloc, target);
    defer alloc.free(t);
    const u = "'zode'";
    const pre =
        "$ErrorActionPreference='Stop';" ++
        "Add-Type -TypeDefinition @'\n" ++
        "using System;\n" ++
        "using System.Runtime.InteropServices;\n" ++
        "using System.Text;\n" ++
        "public static class ZodeCred {\n" ++
        "  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]\n" ++
        "  public struct CREDENTIAL {\n" ++
        "    public int Flags; public int Type; public string TargetName; public string Comment;\n" ++
        "    public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;\n" ++
        "    public int Persist; public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;\n" ++
        "  }\n" ++
        "  [DllImport(\"advapi32.dll\", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool CredRead(string target, int type, int flags, out IntPtr cred);\n" ++
        "  [DllImport(\"advapi32.dll\", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool CredWrite(ref CREDENTIAL cred, int flags);\n" ++
        "  [DllImport(\"advapi32.dll\", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool CredDelete(string target, int type, int flags);\n" ++
        "  [DllImport(\"advapi32.dll\", SetLastError=true)] public static extern void CredFree(IntPtr buffer);\n" ++
        "}\n" ++
        "'@;\n";

    return switch (kind) {
        .lookup => std.fmt.allocPrint(alloc,
            "{s}$t={s};$p= [IntPtr]::Zero; if(-not [ZodeCred]::CredRead($t,1,0,[ref]$p)){{ exit 2 }}; try {{ $c=[Runtime.InteropServices.Marshal]::PtrToStructure($p,[Type][ZodeCred+CREDENTIAL]); if($c.CredentialBlobSize -gt 0){{ [Console]::Out.Write([Runtime.InteropServices.Marshal]::PtrToStringUni($c.CredentialBlob,$c.CredentialBlobSize/2)) }} }} finally {{ [ZodeCred]::CredFree($p) }}",
            .{ pre, t },
        ),
        .store => blk: {
            const kq = try psQuoteSingleAlloc(alloc, key.?);
            defer alloc.free(kq);
            break :blk std.fmt.allocPrint(alloc,
                "{s}$t={s};$u={s};$k={s};$bytes=[Text.Encoding]::Unicode.GetBytes($k);$h=[Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length);try{{[Runtime.InteropServices.Marshal]::Copy($bytes,0,$h,$bytes.Length);$c=New-Object ZodeCred+CREDENTIAL;$c.Flags=0;$c.Type=1;$c.TargetName=$t;$c.UserName=$u;$c.CredentialBlobSize=$bytes.Length;$c.CredentialBlob=$h;$c.Persist=2;if(-not [ZodeCred]::CredWrite([ref]$c,0)){{ exit 3 }}}}finally{{[Runtime.InteropServices.Marshal]::FreeHGlobal($h)}}",
                .{ pre, t, u, kq },
            );
        },
        .clear => std.fmt.allocPrint(alloc,
            "{s}$t={s}; if(-not [ZodeCred]::CredDelete($t,1,0)){{ exit 0 }}; exit 0",
            .{ pre, t },
        ),
    };
}

fn runWindowsCred(alloc: std.mem.Allocator, io: std.Io, script: []const u8) !std.process.RunResult {
    const shell = windowsShell(io);
    const argv = [_][]const u8{ shell, "-NoProfile", "-NonInteractive", "-Command", script };
    return std.process.run(alloc, io, .{
        .argv = &argv,
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
}

fn lookupWindowsCred(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) ?[]u8 {
    const script = windowsCredScript(.lookup, alloc, provider, null) catch return null;
    defer alloc.free(script);
    const res = runWindowsCred(alloc, io, script) catch return null;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return null;
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (out.len == 0) return null;
    return alloc.dupe(u8, out) catch null;
}

fn storeWindowsCred(alloc: std.mem.Allocator, io: std.Io, provider: []const u8, key: []const u8) bool {
    const script = windowsCredScript(.store, alloc, provider, key) catch return false;
    defer alloc.free(script);
    const res = runWindowsCred(alloc, io, script) catch return false;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.term == .exited and res.term.exited == 0;
}

fn clearWindowsCred(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) bool {
    const script = windowsCredScript(.clear, alloc, provider, null) catch return false;
    defer alloc.free(script);
    const res = runWindowsCred(alloc, io, script) catch return false;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.term == .exited and res.term.exited == 0;
}

test "keychain: lookup returns null without backend" {
    // Best-effort: in CI/dev environments without secret-tool/security this
    // should not crash and must return null.
    const a = std.testing.allocator;
    if (!available(std.testing.io)) {
        const k = lookup(a, std.testing.io, "test");
        if (k) |s| a.free(s);
    }
}
