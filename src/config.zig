const std = @import("std");
const providers = @import("lib/providers.zig");
const chat = @import("chat.zig");
const servers = @import("lsp/servers.zig");
const mcp_servers = @import("mcp/servers.zig");

/// User config: `~/.config/zode/config.json`.
///
/// The provider list used to be compiled into the binary, so pointing at vLLM,
/// LM Studio, Together or any OpenAI-compat endpoint required recompiling.
/// Now they are added without touching code.
///
/// Format:
/// {
///   "provider": "mi-vllm",
///   "providers": [
///     {
///       "id": "mi-vllm",
///       "name": "vLLM local",
///       "base_url": "http://localhost:8000/v1",
///       "models_url": "http://localhost:8000/v1/models",
///       "key_env": "MI_VLLM_KEY",
///       "default_model": "qwen3-coder",
///       "kind": "openai"
///     }
///   ]
/// }
pub const Config = struct {
    /// Default provider (id, must exist in the effective list).
    provider: []const u8 = "",
    /// Global default model (empty = the provider's).
    model: []const u8 = "",
    /// Where SUBAGENTS run, as an override of the main turn's target. Either
    /// may be empty on its own: a provider alone uses its `default_model`, a
    /// model alone runs on the active provider. Both empty = subagents follow
    /// the main turn, which is what has always happened.
    /// (`ZODE_SUBAGENT_PROVIDER` / `ZODE_SUBAGENT_MODEL` are the environment's
    /// spelling of the same two, and config.json beats them.)
    subagent_provider: []const u8 = "",
    subagent_model: []const u8 = "",
    /// User-defined providers (appended to the compiled ones).
    extra: []const providers.ProviderDef = &.{},
    /// Wire format of each extra provider: "openai" (default) or "anthropic".
    anthropic_extra: []const bool = &.{},
    /// The user's own language servers (`lsp_servers`).
    ///
    /// A language for which zode ships no server, or a different binary for
    /// one it does. The command is FIXED here and never chosen by the model:
    /// that is what lets the `lsp` tool run without a permission dialog.
    lsp_servers: []const servers.Server = &.{},
    /// The user's MCP servers (`mcp_servers`).
    ///
    /// USER-level and not per project, on purpose: a server is a PROGRAM, and
    /// a program the project chooses is remote code execution with the user's
    /// credentials. The user's own config is the place where that decision
    /// belongs, and a project that wants a server asks for one to be added.
    ///
    /// The command is FIXED here and never chosen by the model: that is what
    /// lets the `mcp` tool read a server's catalogue without a dialog.
    mcp_servers: []const mcp_servers.Server = &.{},
    /// Config path that was loaded (for diagnostics), or null.
    path: ?[]const u8 = null,
    pub const empty: Config = .{};
};

/// provider_id → use Anthropic's native wire format?
/// Compiled providers are resolved by id; extra ones by their flag.
pub fn isAnthropic(cfg: Config, id: []const u8) bool {
    if (providers.byId(id) != null) return chat.kindForProvider(id) == .anthropic;
    for (cfg.extra, 0..) |d, i| {
        if (std.mem.eql(u8, d.id, id)) return i < cfg.anthropic_extra.len and cfg.anthropic_extra[i];
    }
    return false;
}

/// Path of `~/.config/zode/auth.json` (where the palette stores keys).
pub fn authPath(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const dir = configDir(env, buf) orelse return null;
    return std.fmt.bufPrint(buf[dir.len..], "{s}/auth.json", .{dir}) catch null;
}

fn configPath(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const m = env orelse return null;
    const home = m.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode/config.json", .{home}) catch null;
}

/// Loads `~/.config/zode/config.json`. Best-effort: if it is missing or corrupt
/// it returns `Config.empty` and the app keeps running with the compiled
/// providers. All memory comes from `arena`.
pub fn load(
    arena: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
) Config {
    var path_buf: [1024]u8 = undefined;
    const path = configPath(env, &path_buf) orelse return Config.empty;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch
        return Config.empty;
    return parse(arena, data, path) catch Config.empty;
}

pub fn parse(arena: std.mem.Allocator, data: []const u8, path: []const u8) !Config {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch
        return error.BadConfig;
    if (parsed != .object) return error.BadConfig;
    const root = parsed.object;

    var cfg = Config{ .path = try arena.dupe(u8, path) };
    if (root.get("provider")) |v| {
        if (v == .string) cfg.provider = try arena.dupe(u8, v.string);
    }
    if (root.get("model")) |v| {
        if (v == .string) cfg.model = try arena.dupe(u8, v.string);
    }
    // The subagent's model, parsed where the active one is: an unparsed field
    // is a setting that reads back as "not configured" forever.
    if (root.get("subagent_provider")) |v| {
        if (v == .string) cfg.subagent_provider = try arena.dupe(u8, v.string);
    }
    if (root.get("subagent_model")) |v| {
        if (v == .string) cfg.subagent_model = try arena.dupe(u8, v.string);
    }
    // The user's language servers. A malformed entry is SKIPPED, not an error:
    // one bad row must not take the whole config (and with it the provider
    // that was working) down.
    if (root.get("lsp_servers")) |v| {
        if (v == .array) {
            var list: std.ArrayList(servers.Server) = .empty;
            for (v.array.items) |item| {
                if (item != .object) continue;
                const s = parseServer(arena, item.object) catch continue;
                try list.append(arena, s);
            }
            cfg.lsp_servers = list.items;
        }
    }
    // The user's MCP servers. Same rule as the language servers: a malformed
    // entry is SKIPPED and not an error, because one bad row must not take the
    // whole config (and with it the provider that was working) down.
    if (root.get("mcp_servers")) |v| {
        if (v == .array) {
            var list: std.ArrayList(mcp_servers.Server) = .empty;
            for (v.array.items) |item| {
                if (item != .object) continue;
                const s = parseMcpServer(arena, item.object) catch continue;
                try list.append(arena, s);
            }
            cfg.mcp_servers = list.items;
        }
    }

    const pv = root.get("providers") orelse return cfg;
    if (pv != .array) return cfg;

    var list: std.ArrayList(providers.ProviderDef) = .empty;
    var kinds: std.ArrayList(bool) = .empty;
    for (pv.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;

        const id_v = o.get("id") orelse continue;
        if (id_v != .string or id_v.string.len == 0) continue;
        const id = try arena.dupe(u8, id_v.string);
        if (providers.byId(id) != null) continue; // do not shadow compiled ones

        // base_url is mandatory: without it there is nowhere to send the request.
        const base_v = o.get("base_url") orelse continue;
        if (base_v != .string) continue;
        const base = try arena.dupe(u8, base_v.string);

        const name = if (o.get("name")) |v|
            (if (v == .string) try arena.dupe(u8, v.string) else id)
        else
            id;

        const models_url = if (o.get("models_url")) |v|
            (if (v == .string) try arena.dupe(u8, v.string) else base)
        else
            base;

        const model = if (o.get("default_model")) |v|
            (if (v == .string) try arena.dupe(u8, v.string) else "")
        else
            "";

        // key_env accepts a string or an array of strings.
        var keys: std.ArrayList([]const u8) = .empty;
        if (o.get("key_env")) |kv| {
            switch (kv) {
                .string => |s| if (s.len > 0) try keys.append(arena, try arena.dupe(u8, s)),
                .array => |arr| for (arr.items) |k| {
                    if (k == .string and k.string.len > 0) {
                        try keys.append(arena, try arena.dupe(u8, k.string));
                    }
                },
                else => {},
            }
        }

        const note = if (o.get("note")) |v|
            (if (v == .string) try arena.dupe(u8, v.string) else "")
        else
            "";

        const kind_anthropic = blk: {
            const kv = o.get("kind") orelse break :blk false;
            break :blk kv == .string and std.mem.eql(u8, kv.string, "anthropic");
        };

        try list.append(arena, .{
            .id = id,
            .name = name,
            .base_url = base,
            .models_url = models_url,
            .key_env = keys.items,
            .default_model = model,
            .note = note,
            // The same `kind` that says the chat path is the Anthropic Messages
            // API says how its CATALOGUE expects the key: an anthropic proxy
            // with `kind: "anthropic"` and no Bearer would list nothing.
            .key_style = if (kind_anthropic) .x_api_key else .bearer,
        });
        try kinds.append(arena, kind_anthropic);
    }

    cfg.extra = list.items;
    cfg.anthropic_extra = kinds.items;
    return cfg;
}

/// One `lsp_servers` entry.
///
/// `name`, `command` and `extensions` are required: without an extension the
/// server is never picked, and without a command there is nothing to run.
/// `language_id` defaults to the name, which is right for most servers (the
/// name IS the language id in the table zode ships).
fn parseServer(arena: std.mem.Allocator, o: std.json.ObjectMap) !servers.Server {
    const name_v = o.get("name") orelse return error.BadServer;
    if (name_v != .string or name_v.string.len == 0) return error.BadServer;
    const name = try arena.dupe(u8, name_v.string);

    const lang = if (o.get("language_id")) |lv|
        (if (lv == .string and lv.string.len > 0) try arena.dupe(u8, lv.string) else name)
    else
        name;

    const cmd_v = o.get("command") orelse return error.BadServer;
    if (cmd_v != .array or cmd_v.array.items.len == 0) return error.BadServer;
    var cmd: std.ArrayList([]const u8) = .empty;
    for (cmd_v.array.items) |c| {
        if (c != .string or c.string.len == 0) return error.BadServer;
        try cmd.append(arena, try arena.dupe(u8, c.string));
    }

    const ext_v = o.get("extensions") orelse return error.BadServer;
    if (ext_v != .array or ext_v.array.items.len == 0) return error.BadServer;
    var ext: std.ArrayList([]const u8) = .empty;
    for (ext_v.array.items) |e| {
        if (e != .string or e.string.len == 0) continue;
        try ext.append(arena, try arena.dupe(u8, e.string));
    }
    if (ext.items.len == 0) return error.BadServer;

    return .{
        .name = name,
        .language_id = lang,
        .command = cmd.items,
        .extensions = ext.items,
    };
}

/// One MCP server, as the user wrote it.
///
/// The shape is the obvious one:
///
///     { "name": "github", "command": ["npx", "-y", "server-github"],
///       "env": { "GITHUB_TOKEN": "..." } }
///
/// `env` is an OBJECT (a name and a value), and also accepts an array of
/// `{name, value}` objects, because both are what people write and the second
/// one is what a generator emits.
fn parseMcpServer(arena: std.mem.Allocator, o: std.json.ObjectMap) !mcp_servers.Server {
    const name_v = o.get("name") orelse return error.BadServer;
    if (name_v != .string or name_v.string.len == 0) return error.BadServer;
    const name = try arena.dupe(u8, name_v.string);

    const cmd_v = o.get("command") orelse return error.BadServer;
    if (cmd_v != .array or cmd_v.array.items.len == 0) return error.BadServer;
    var cmd: std.ArrayList([]const u8) = .empty;
    for (cmd_v.array.items) |c| {
        if (c != .string or c.string.len == 0) return error.BadServer;
        try cmd.append(arena, try arena.dupe(u8, c.string));
    }

    var envs: std.ArrayList(mcp_servers.EnvVar) = .empty;
    if (o.get("env")) |ev| {
        switch (ev) {
            .object => |map| {
                var it = map.iterator();
                while (it.next()) |kv| {
                    const v = kv.value_ptr.*;
                    if (v != .string) continue;
                    // `Environ.Map.put` ASSERTS on a name with an `=` in it, and
                    // an assert in the user's own configuration is a crash the
                    // user cannot do anything about.
                    if (!mcp_servers.validEnvName(kv.key_ptr.*)) continue;
                    try envs.append(arena, .{
                        .name = try arena.dupe(u8, kv.key_ptr.*),
                        .value = try arena.dupe(u8, v.string),
                    });
                }
            },
            .array => |items| {
                for (items.items) |item| {
                    if (item != .object) continue;
                    const n = item.object.get("name") orelse continue;
                    const v = item.object.get("value") orelse continue;
                    if (n != .string or v != .string) continue;
                    if (!mcp_servers.validEnvName(n.string)) continue;
                    try envs.append(arena, .{
                        .name = try arena.dupe(u8, n.string),
                        .value = try arena.dupe(u8, v.string),
                    });
                }
            },
            else => {},
        }
    }

    return .{
        .name = name,
        .command = cmd.items,
        .env = envs.items,
    };
}

/// All providers: compiled + the ones from config.json.
pub fn allDefs(arena: std.mem.Allocator, cfg: Config) []const providers.ProviderDef {
    const n = providers.defs.len + cfg.extra.len;
    const out = arena.alloc(providers.ProviderDef, n) catch return &providers.defs;
    @memcpy(out[0..providers.defs.len], &providers.defs);
    @memcpy(out[providers.defs.len..], cfg.extra);
    return out;
}

pub fn find(cfg: Config, id: []const u8) ?*const providers.ProviderDef {
    if (providers.byId(id)) |d| return d;
    for (cfg.extra) |*d| {
        if (std.mem.eql(u8, d.id, id)) return d;
    }
    return null;
}

// ── tests ─────────────────────────────────────────────────────

test "parse: a complete extra provider" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"provider":"vllm","model":"qwen","providers":[
        \\ {"id":"vllm","name":"vLLM","base_url":"http://localhost:8000/v1",
        \\  "key_env":"VLLM_KEY","default_model":"qwen3-coder","kind":"openai"}
        \\]}
    ;
    const cfg = try parse(arena, json, "/tmp/cfg.json");

    try std.testing.expectEqualStrings("vllm", cfg.provider);
    try std.testing.expectEqualStrings("qwen", cfg.model);
    try std.testing.expectEqual(@as(usize, 1), cfg.extra.len);
    try std.testing.expectEqualStrings("vllm", cfg.extra[0].id);
    try std.testing.expectEqualStrings("http://localhost:8000/v1", cfg.extra[0].base_url);
    try std.testing.expectEqualStrings("qwen3-coder", cfg.extra[0].default_model);
    // key_env as a lone string → slice of 1
    try std.testing.expectEqual(@as(usize, 1), cfg.extra[0].key_env.len);
    try std.testing.expect(!isAnthropic(cfg, "vllm"));
}

test "parse: key_env accepts an array" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"providers":[{"id":"x","base_url":"http://h/v1","key_env":["A_KEY","B_KEY"]}]}
    ;
    const cfg = try parse(arena, json, "/tmp/c.json");
    try std.testing.expectEqual(@as(usize, 2), cfg.extra[0].key_env.len);
    try std.testing.expectEqualStrings("A_KEY", cfg.extra[0].key_env[0]);
    try std.testing.expectEqualStrings("B_KEY", cfg.extra[0].key_env[1]);
}

test "parse: kind anthropic marks the wire format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"providers":[{"id":"proxy","base_url":"http://h/v1","kind":"anthropic"}]}
    ;
    const cfg = try parse(arena, json, "/tmp/c.json");
    try std.testing.expect(isAnthropic(cfg, "proxy"));
    // Compiled providers win by id.
    try std.testing.expect(isAnthropic(cfg, "anthropic"));
    try std.testing.expect(!isAnthropic(cfg, "openrouter"));
}

test "parse: a provider without base_url is ignored, it does not break the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"providers":[{"id":"roto"},{"id":"ok","base_url":"http://h/v1"}]}
    ;
    const cfg = try parse(arena, json, "/tmp/c.json");
    try std.testing.expectEqual(@as(usize, 1), cfg.extra.len);
    try std.testing.expectEqualStrings("ok", cfg.extra[0].id);
}

test "parse: a built-in provider cannot be shadowed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"providers":[{"id":"openrouter","base_url":"http://evil/v1"}]}
    ;
    const cfg = try parse(arena, json, "/tmp/c.json");
    try std.testing.expectEqual(@as(usize, 0), cfg.extra.len);
    // And the lookup still resolves to the compiled one.
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", find(cfg, "openrouter").?.base_url);
}

test "parse: the subagent's model is parsed where the active one is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"subagent_provider":"groq","subagent_model":"llama-3.3-70b-versatile"}
    ;
    const cfg = try parse(arena, json, "/tmp/cfg.json");
    try std.testing.expectEqualStrings("groq", cfg.subagent_provider);
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", cfg.subagent_model);

    // Absent means "subagents follow the main turn", which is the default and
    // has to stay it: a field that parsed to something else would silently move
    // every subagent off the model the user picked.
    const bare = try parse(arena, "{}", "/tmp/cfg.json");
    try std.testing.expectEqual(@as(usize, 0), bare.subagent_provider.len);
    try std.testing.expectEqual(@as(usize, 0), bare.subagent_model.len);

    // A non-string is ignored like every other malformed field, not an error:
    // one bad value must not take the whole config down.
    const weird = try parse(arena, "{\"subagent_model\":42}", "/tmp/cfg.json");
    try std.testing.expectEqual(@as(usize, 0), weird.subagent_model.len);
}

test "parse: the user's language servers are parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"lsp_servers":[
        \\ {"name":"my-zls","language_id":"zig","command":["my-lsp","--stdio"],"extensions":[".zig",".zon"]},
        \\ {"name":"txtlsp","command":["txtlsp"],"extensions":[".txt"]}
        \\]}
    ;
    const cfg = try parse(arena, json, "/tmp/cfg.json");
    try std.testing.expectEqual(@as(usize, 2), cfg.lsp_servers.len);
    try std.testing.expectEqualStrings("my-zls", cfg.lsp_servers[0].name);
    try std.testing.expectEqualStrings("zig", cfg.lsp_servers[0].language_id);
    try std.testing.expectEqual(@as(usize, 2), cfg.lsp_servers[0].command.len);
    try std.testing.expectEqualStrings("my-lsp", cfg.lsp_servers[0].command[0]);
    try std.testing.expectEqual(@as(usize, 2), cfg.lsp_servers[0].extensions.len);
    // The language id defaults to the name: for most servers they are the same.
    try std.testing.expectEqualStrings("txtlsp", cfg.lsp_servers[1].language_id);

    // No servers configured is not an error and not an empty list of garbage.
    const bare = try parse(arena, "{}", "/tmp/cfg.json");
    try std.testing.expectEqual(@as(usize, 0), bare.lsp_servers.len);
}

test "parse: a malformed language server is skipped, and the rest survives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"provider":"vllm","lsp_servers":[
        \\ {"name":"no-command","extensions":[".zig"]},
        \\ {"name":"no-extensions","command":["x"]},
        \\ {"command":["x"],"extensions":[".zig"]},
        \\ {"name":"ok","command":["x"],"extensions":[".zig"]}
        \\]}
    ;
    const cfg = try parse(arena, json, "/tmp/cfg.json");
    // One bad row must not take the whole config (and with it the provider)
    // down, and must not take the good row with it.
    try std.testing.expectEqual(@as(usize, 1), cfg.lsp_servers.len);
    try std.testing.expectEqualStrings("ok", cfg.lsp_servers[0].name);
    // The provider is still there: that is the point of skipping.
    try std.testing.expectEqualStrings("vllm", cfg.provider);
}

test "parse: the user's MCP servers are parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"mcp_servers":[
        \\ {"name":"github","command":["npx","-y","server-github"],"env":{"GITHUB_TOKEN":"abc"}},
        \\ {"name":"fs","command":["mcp-fs","/tmp"],"env":[{"name":"MODE","value":"ro"}]}
        \\]}
    ;
    const cfg = try parse(arena, json, "/tmp/cfg.json");
    try std.testing.expectEqual(@as(usize, 2), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("github", cfg.mcp_servers[0].name);
    try std.testing.expectEqual(@as(usize, 3), cfg.mcp_servers[0].command.len);
    try std.testing.expectEqualStrings("npx", cfg.mcp_servers[0].command[0]);
    // The environment is an object, and also an array: both are what people
    // write, and the second one is what a generator emits.
    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers[0].env.len);
    try std.testing.expectEqualStrings("GITHUB_TOKEN", cfg.mcp_servers[0].env[0].name);
    try std.testing.expectEqualStrings("abc", cfg.mcp_servers[0].env[0].value);
    try std.testing.expectEqualStrings("MODE", cfg.mcp_servers[1].env[0].name);

    // No servers configured is not an error and not an empty list of garbage.
    const bare = try parse(arena, "{}", "/tmp/cfg.json");
    try std.testing.expectEqual(@as(usize, 0), bare.mcp_servers.len);
}

test "parse: a malformed MCP server is skipped, and the rest survives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"provider":"vllm","mcp_servers":[
        \\ {"name":"no-command"},
        \\ {"name":"empty-command","command":[]},
        \\ {"command":["x"]},
        \\ {"name":"ok","command":["x"],"env":{"BAD=NAME":"v"}}
        \\]}
    ;
    const cfg = try parse(arena, json, "/tmp/cfg.json");
    // One bad row must not take the whole config (and with it the provider)
    // down, and must not take the good row with it.
    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("ok", cfg.mcp_servers[0].name);
    // And an environment variable whose NAME is not a name is dropped, not
    // asserted on: `Environ.Map.put` asserts, and an assert in the user's own
    // configuration is a crash the user cannot do anything about.
    try std.testing.expectEqual(@as(usize, 0), cfg.mcp_servers[0].env.len);
    // The provider is still there: that is the point of skipping.
    try std.testing.expectEqualStrings("vllm", cfg.provider);
}

test "parse: corrupt JSON returns an error, not a panic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.BadConfig, parse(arena, "{no json", "/tmp/c.json"));
    try std.testing.expectError(error.BadConfig, parse(arena, "[1,2,3]", "/tmp/c.json"));
}

test "allDefs: the config ones come after the built-in ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parse(
        arena,
        \\{"providers":[{"id":"vllm","base_url":"http://h/v1"}]}
    ,
        "/tmp/c.json",
    );
    const all = allDefs(arena, cfg);
    try std.testing.expectEqual(providers.defs.len + 1, all.len);
    try std.testing.expectEqualStrings("opencode", all[0].id);
    try std.testing.expectEqualStrings("vllm", all[all.len - 1].id);
}

// ── writing (auth.json) ───────────────────────────────────────

/// Path of `~/.config/zode`, or null when there is no HOME.
///
/// Exported because storing a provider's key (the palette's "Connect an
/// integration") needs the same directory as reading the config, and
/// duplicating `configPath`'s logic would just invite them to drift apart.
pub fn configDir(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const m = env orelse return null;
    const home = m.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode", .{home}) catch null;
}

/// Writes a file with 0600 permissions.
///
/// 0600 and not 0644 on purpose: the file holds API keys in cleartext and
/// `config.json` is meant to be versioned while this one is not. `writeFile`
/// cannot set permissions, so it is written to a temp file and renamed.
pub fn writeFileSecure(
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    path: []const u8,
    data: []const u8,
) !void {
    var dir_buf: [1024]u8 = undefined;
    const dir_path = configDir(env, &dir_buf) orelse return error.NoHome;
    // `Dir.createDirPath` is mkdir -p: the user may not have ~/.config/zode yet.
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    var tmp_buf: [1200]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

    var file = try std.Io.Dir.cwd().createFile(io, tmp, .{
        .truncate = true,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(io);
    // `permissions` above only applies when the file is CREATED. A
    // `auth.json.tmp` left behind by a crashed write keeps whatever mode it had
    // — and if that one was written 0644 (by an older zode, or by hand), the
    // rename publishes it as `auth.json` at 0644 with the keys readable by every
    // user on the machine. So the mode is set on the OPEN file, every time.
    file.setPermissions(io, @enumFromInt(0o600)) catch {};
    // `File` has no writeAll in 0.16: build a writer with its own buffer.
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.interface.writeAll(data);
    try fw.interface.flush();
    // The temp file is renamed to its final name: writing in place would leave
    // half of the key in a 0644 file if it failed midway.
    try std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
}

/// Tightens an existing file to 0600 if it is looser.
///
/// The private mode is applied when zode WRITES `auth.json`, so a file written
/// by an older zode, restored from a backup, or created with `echo … > auth.json`
/// stays 0644 forever: the keys are readable by every user on the machine, and
/// every start of the app reads them and does nothing about it. This is the
/// check that makes "the file is 0600" a property of the FILE and not of the
/// writer that happened to create it.
///
/// Best-effort, and deliberately silent: no file yet (nobody connected a
/// provider), a read-only mount or a file owned by somebody else are not
/// reasons to refuse to start. The caller keeps going, with or without keys.
pub fn tightenPermissions(io: std.Io, path: []const u8) void {
    if (path.len == 0) return;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    const st = file.stat(io) catch return;
    // 0o077 is group+other: anything in there is someone else's read (or write).
    if (@intFromEnum(st.permissions) & 0o077 == 0) return;
    file.setPermissions(io, @enumFromInt(0o600)) catch {};
}

// ── minimal hand-written JSON ─────────────────────────────────

/// Writes a flat object `{ "k": "v", ... }` to `out`.
///
/// By hand and not with `{f}` because the 0.16 writer does not format
/// `json.ObjectMap` or `json.Array`, and the file we write (auth.json) is a
/// handful of string→string pairs: serializing it here is 20 lines and keeps
/// the key format under control (and free of odd quoting).
pub fn writeStringMap(out: *std.Io.Writer, gpa: std.mem.Allocator, pairs: []const [2][]const u8) !void {
    try out.writeAll("{");
    for (pairs, 0..) |kv, i| {
        if (i > 0) try out.writeAll(",");
        try writeJsonString(out, gpa, kv[0]);
        try out.writeAll(":");
        try writeJsonString(out, gpa, kv[1]);
    }
    try out.writeAll("}");
}

/// Writes a string array `["a","b"]`.
pub fn writeStringArray(out: *std.Io.Writer, gpa: std.mem.Allocator, items: []const []const u8) !void {
    try out.writeAll("[");
    for (items, 0..) |it, i| {
        if (i > 0) try out.writeAll(",");
        try writeJsonString(out, gpa, it);
    }
    try out.writeAll("]");
}

/// JSON string with minimal escaping (quote, backslash, control, UTF-8 as-is).
pub fn writeJsonString(out: *std.Io.Writer, gpa: std.mem.Allocator, s: []const u8) !void {
    try out.writeAll("\"");
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        const e = esc orelse continue;
        if (i > start) try out.writeAll(s[start..i]);
        try out.writeAll(e);
        start = i + 1;
    }
    if (start < s.len) try out.writeAll(s[start..]);
    _ = gpa;
    try out.writeAll("\"");
}

test "writeFileSecure: creates the directory and writes with 0600" {
    // The full flow: mkdir -p of the directory, temp file, and rename. This is
    // what "Connect an integration" uses, and if it fails you end up with no key.
    // An environment with its own HOME: `writeFileSecure` needs it to know
    // where ~/.config/zode is, so the test CANNOT pass null.
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const home: [:0]const u8 = "HOME=/tmp/zode-test-home\x00";
    try env_map.putPosixBlock(.{ .slice = &.{home} });

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/zode-test-home/.config/zode/auth.json";
    std.Io.Dir.cwd().deleteTree(io, "/tmp/zode-test-home") catch {};

    try writeFileSecure(io, &env_map, path, "{\"a\":\"b\"}");

    const got = std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(4096)) catch |err| {
        std.debug.print("no se pudo leer: {t}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"a\":\"b\"}", got);
    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(io, path));
}

/// Mode bits of `path`, for the tests below. Read through an open file because
/// `statFile` wants its own options struct and this is the same code either way.
fn modeOf(io: std.Io, path: []const u8) !u32 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    // `Permissions` carries the file-type bits too (0100644 for a regular
    // file), so only the mode itself is interesting here.
    return @intFromEnum(st.permissions) & 0o7777;
}

test "writeFileSecure: a leftover 0644 temp file does not publish auth.json at 0644" {
    // The hole this covers: `createFile(.permissions = 0o600)` only sets the
    // mode when it CREATES. A `.tmp` from a crashed run kept its old mode, the
    // rename published it under the real name, and the keys ended up readable by
    // every user on the machine.
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const home: [:0]const u8 = "HOME=/tmp/zode-test-tmp-home\x00";
    try env_map.putPosixBlock(.{ .slice = &.{home} });

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/zode-test-tmp-home/.config/zode/auth.json";
    std.Io.Dir.cwd().deleteTree(io, "/tmp/zode-test-tmp-home") catch {};
    try std.Io.Dir.cwd().createDirPath(io, "/tmp/zode-test-tmp-home/.config/zode");

    // A pre-existing temp file, forced to 0644 so the test does not depend on
    // the umask of whoever runs it.
    const tmp = path ++ ".tmp";
    const stale = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
    stale.setPermissions(io, @enumFromInt(0o644)) catch {};
    stale.close(io);
    try std.testing.expectEqual(@as(u32, 0o644), try modeOf(io, tmp));

    try writeFileSecure(io, &env_map, path, "{\"k\":\"v\"}");

    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(io, path));
}

test "tightenPermissions: a 0644 auth.json becomes 0600, a private one is left alone" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "/tmp/zode-test-perms";
    const path = dir ++ "/auth.json";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // No file: not an error, nothing to do (nobody connected a provider yet).
    tightenPermissions(io, path);
    tightenPermissions(io, "");

    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    f.setPermissions(io, @enumFromInt(0o644)) catch {};
    f.close(io);
    try std.testing.expectEqual(@as(u32, 0o644), try modeOf(io, path));

    tightenPermissions(io, path);
    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(io, path));

    // Idempotent: calling it again cannot fail or change anything.
    tightenPermissions(io, path);
    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(io, path));
}
