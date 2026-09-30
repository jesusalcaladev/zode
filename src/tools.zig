const std = @import("std");
const plan_mod = @import("plan.zig");
const http = @import("http_client.zig");
const web = @import("web.zig");

pub const max_tool_output = 16 * 1024; // presupuesto de salida por tool

pub const ToolDef = struct {
    name: []const u8,
    desc: []const u8,
};

pub const defs = [_]ToolDef{
    .{ .name = "read", .desc = "Read a file with line offsets and smart truncation" },
    .{ .name = "write", .desc = "Create or overwrite a file" },
    .{ .name = "edit", .desc = "Exact str_replace editing, single or multi-hunk" },
    .{ .name = "bash", .desc = "Run a shell command with timeout" },
    .{ .name = "glob", .desc = "Find files matching a glob pattern" },
    .{ .name = "grep", .desc = "Search file contents with regex" },
    .{ .name = "list_files", .desc = "List a directory (cheap structure overview)" },
    .{ .name = "web_fetch", .desc = "Fetch a URL and return it as readable text (HTML stripped)" },
    .{ .name = "web_search", .desc = "Search the web: titles, URLs and snippets" },
    .{ .name = "think", .desc = "Private scratchpad to reason before acting (no side effects)" },
    .{ .name = "todo", .desc = "Write the visible task list the user watches (full list, not a diff)" },
};

/// Declara las tools al LLM (formato OpenAI). Estático: 0 allocs por request.
pub fn toolsJson() []const u8 {
    return
    \\[
    \\{"type":"function","function":{"name":"read","description":"Read a file from disk. Optionally read a specific line range with offset/limit.","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"1-indexed start line"},"limit":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write","description":"Create or overwrite a file with the given content.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit","description":"Exact string replacement in a file. Single hunk via old_string/new_string, or several at once via edits:[{old_string,new_string},...] (applied in order, all validated first). old_string must appear exactly once unless allow_multiple is true.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["old_string","new_string"]}},"allow_multiple":{"type":"boolean"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"bash","description":"Run a shell command and get combined stdout+stderr (truncated).","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout_seconds":{"type":"integer"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"glob","description":"Find files matching a glob pattern like src/**/*.zig.","parameters":{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"grep","description":"Search file contents with a regex. Returns path:line:text matches.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"subdir":{"type":"string"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"list_files","description":"List files and directories directly inside a path (non-recursive, cheap).","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch an http(s) URL and return the content as readable text (HTML tags, scripts and styles are stripped, entities decoded). Use it to read documentation, a release page or any URL the user mentions. A non-2xx answer returns the status plus the body, so you can see what the site said. Truncated to a byte budget; ask for a deeper offset if the text is cut.","parameters":{"type":"object","properties":{"url":{"type":"string"},"max_bytes":{"type":"integer","description":"bytes of text to keep (default 16000, max 200000)"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_search","description":"Search the web and get titles, URLs and snippets. Use it when you need something you do not know yet (docs, versions, error messages), then web_fetch the promising URLs.","parameters":{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer","description":"1..20, default 8"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"think","description":"Think privately step by step before acting. Use for planning and complex reasoning. No side effects.","parameters":{"type":"object","properties":{"thought":{"type":"string"}},"required":["thought"]}}},
    \\{"type":"function","function":{"name":"todo","description":"Write the task list the USER SEES on screen, for tasks with more than about two steps. Send the WHOLE list every time (it replaces the previous one), each item {content, status: pending|in_progress|done}. Mark exactly one in_progress while you work on it, and never more than one. Call it again when a step finishes or the plan changes, and send an empty list when everything is done. Do not use it for a single obvious step or for thinking out loud.","parameters":{"type":"object","properties":{"items":{"type":"array","maxItems":20,"items":{"type":"object","properties":{"content":{"type":"string","description":"imperative, short (a single line)"},"status":{"type":"string","enum":["pending","in_progress","done"]}},"required":["content","status"]}}},"required":["items"]}}}
    \\]
    ;
}

/// ¿Esta tool hay que preguntarle al usuario antes de correrla?
///
/// `web_fetch` y `web_search` NO preguntan: son lecturas, no escriben nada, y un
/// diálogo por cada consulta a internet convierte el agent loop en un
/// interrogatorio. Es el mismo criterio que `read` o `grep`.
pub fn needsPermission(name: []const u8) bool {
    return !(std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "list_files") or
        std.mem.eql(u8, name, "web_fetch") or
        std.mem.eql(u8, name, "web_search") or
        std.mem.eql(u8, name, "think") or
        std.mem.eql(u8, name, "todo"));
}

/// Ejecuta una tool con args JSON. Devuelve el resultado (truncado) —
/// memoria de `arena`, válida hasta que la arena se libere.
pub fn execute(io: std.Io, name: []const u8, args_json: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{});
    if (parsed != .object) return error.BadArgs;
    const obj = parsed.object;

    if (std.mem.eql(u8, name, "read")) {
        return toolRead(io, obj, arena);
    } else if (std.mem.eql(u8, name, "write")) {
        return toolWrite(io, obj, arena);
    } else if (std.mem.eql(u8, name, "edit")) {
        return toolEdit(io, obj, arena);
    } else if (std.mem.eql(u8, name, "bash")) {
        return toolBash(io, obj, arena);
    } else if (std.mem.eql(u8, name, "glob")) {
        return toolGlob(io, obj, arena);
    } else if (std.mem.eql(u8, name, "grep")) {
        return toolGrep(io, obj, arena);
    } else if (std.mem.eql(u8, name, "list_files")) {
        return toolListFiles(io, obj, arena);
    } else if (std.mem.eql(u8, name, "web_fetch")) {
        return toolWebFetch(io, obj, arena);
    } else if (std.mem.eql(u8, name, "web_search")) {
        return toolWebSearch(io, obj, arena);
    } else if (std.mem.eql(u8, name, "think")) {
        return toolThink(obj, arena);
    } else if (std.mem.eql(u8, name, "todo")) {
        return toolTodo(obj, arena);
    }
    return error.UnknownTool;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

// ── read ─────────────────────────────────────────────────────
fn toolRead(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse return error.MissingPath;
    const offset: usize = if (getInt(obj, "offset")) |o| (if (o > 0) @intCast(o) else 1) else 1;
    const default_limit: usize = 2000;
    const limit: usize = if (getInt(obj, "limit")) |l| (if (l > 0) @intCast(l) else default_limit) else default_limit;

    var dir = std.Io.Dir.cwd();
    const data = dir.readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(arena, "error reading {s}: {t}", .{ path, err });
    };

    var out: std.ArrayList(u8) = .empty;
    var line_no: usize = 1;
    var lines_shown: usize = 0;
    var truncated = false;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        defer line_no += 1;
        if (line_no < offset) continue;
        if (lines_shown >= limit) {
            truncated = true;
            break;
        }
        // Trunca líneas larguísimas (minified) a 2000 chars.
        const shown = line[0..@min(line.len, 2000)];
        out.print(arena, "{d: >6}│ {s}\n", .{ line_no, shown }) catch break;
        lines_shown += 1;
    }
    if (truncated) {
        out.print(arena, "… (more lines; raise `offset` to {d} to continue)\n", .{line_no}) catch {};
    }
    if (out.items.len == 0) {
        out.appendSlice(arena, "(empty file)") catch {};
    }
    return out.items;
}

// ── write ────────────────────────────────────────────────────
fn toolWrite(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse return error.MissingPath;
    const content = getStr(obj, "content") orelse return error.MissingContent;

    var dir = std.Io.Dir.cwd();
    dir.writeFile(io, .{
        .sub_path = path,
        .data = content,
    }) catch |err| {
        return std.fmt.allocPrint(arena, "error writing {s}: {t}", .{ path, err });
    };
    return std.fmt.allocPrint(arena, "wrote {s} ({d} bytes)", .{ path, content.len });
}

// ── edit: single hunk (compat) o multi-hunk via `edits: [...]` ──
fn toolEdit(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse return error.MissingPath;

    // Recolecta hunks: `edits: [{old_string,new_string},...]` o single par.
    var hunks: std.ArrayList(Hunk) = .empty;
    if (obj.get("edits")) |edits_v| {
        if (edits_v != .array or edits_v.array.items.len == 0) return error.BadArgs;
        for (edits_v.array.items) |ev| {
            if (ev != .object) return error.BadArgs;
            const old_s = getStr(ev.object, "old_string") orelse return error.MissingOldString;
            const new_s = getStr(ev.object, "new_string") orelse return error.MissingNewString;
            try hunks.append(arena, .{ .old = old_s, .new = new_s });
        }
    } else {
        const old_s = getStr(obj, "old_string") orelse return error.MissingOldString;
        const new_s = getStr(obj, "new_string") orelse return error.MissingNewString;
        const allow_multiple = if (obj.get("allow_multiple")) |v| (v == .bool and v.bool) else false;
        try hunks.append(arena, .{ .old = old_s, .new = new_s, .allow_multiple = allow_multiple });
    }

    if (hunks.items.len > max_hunks) return error.TooManyHunks;

    var dir = std.Io.Dir.cwd();
    const data = try dir.readFileAlloc(io, path, arena, .limited(32 * 1024 * 1024));

    // Valida todos los hunks contra el texto ORIGINAL (transacción).
    for (hunks.items) |*h| {
        if (h.old.len == 0) return std.fmt.allocPrint(arena, "error: empty old_string (use write for new files)", .{});
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, pos, h.old)) |idx| {
            count += 1;
            pos = idx + h.old.len;
            if (count > 1 and !h.allow_multiple) break;
        }
        if (count == 0) {
            return std.fmt.allocPrint(arena, "error: old_string not found in {s}: \"{s}\"", .{ path, h.old[0..@min(h.old.len, 80)] });
        }
        if (count > 1 and !h.allow_multiple) {
            return std.fmt.allocPrint(arena, "error: old_string appears {d} times in {s}; be more specific or use allow_multiple", .{ count, path });
        }
        h.occurrences = count;
    }

    // Aplica en orden (el output de un hunk es el input del siguiente).
    var out: []const u8 = data;
    var total: usize = 0;
    for (hunks.items) |h| {
        out = try allocReplace(arena, out, h.old, h.new);
        total += if (h.allow_multiple) h.occurrences else 1;
    }

    var f = try dir.createFile(io, path, .{ .truncate = true });
    {
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(out);
        try w.interface.flush();
        f.close(io);
    }
    return std.fmt.allocPrint(arena, "edited {s}: {d} hunk(s), {d} replacement(s)", .{ path, hunks.items.len, total });
}

const max_hunks = 16;

const Hunk = struct {
    old: []const u8,
    new: []const u8,
    allow_multiple: bool = false,
    occurrences: usize = 0,
};

fn allocReplace(a: std.mem.Allocator, data: []const u8, old: []const u8, new: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, old)) |idx| {
        try out.appendSlice(a, data[pos..idx]);
        try out.appendSlice(a, new);
        pos = idx + old.len;
    }
    try out.appendSlice(a, data[pos..]);
    return out.items;
}

// ── bash ─────────────────────────────────────────────────────
fn toolBash(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const command = getStr(obj, "command") orelse return error.MissingCommand;
    const timeout_s: u64 = if (getInt(obj, "timeout_seconds")) |t| (if (t > 0) @intCast(t) else 30) else 30;

    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    const result = std.process.run(arena, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_tool_output),
        .stderr_limit = .limited(max_tool_output),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(@intCast(timeout_s)), .clock = .awake } },
    }) catch |err| {
        return std.fmt.allocPrint(arena, "error running: {t}", .{err});
    };

    var out: std.ArrayList(u8) = .empty;
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal => |sig| blk: {
            out.print(arena, "(señal {d}) ", .{sig}) catch {};
            break :blk @as(u8, @truncate(128 + @intFromEnum(sig)));
        },
        else => 255,
    };
    try out.print(arena, "exit={d}\n", .{exit_code});
    if (result.stdout.len > 0) {
        try out.appendSlice(arena, "--- stdout ---\n");
        try out.appendSlice(arena, result.stdout[0..@min(result.stdout.len, max_tool_output)]);
        try out.appendSlice(arena, "\n");
    }
    if (result.stderr.len > 0) {
        try out.appendSlice(arena, "--- stderr ---\n");
        try out.appendSlice(arena, result.stderr[0..@min(result.stderr.len, max_tool_output)]);
        try out.appendSlice(arena, "\n");
    }
    return out.items;
}

// ── glob ─────────────────────────────────────────────────────
fn toolGlob(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const pattern = getStr(obj, "pattern") orelse return error.MissingPattern;

    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    const max_results = 200;

    var walker = try walkZig(io, arena, ".");
    defer walker.deinit();

    while (walker.next()) |entry_path| {
        defer arena.free(entry_path);
        if (count >= max_results) {
            out.appendSlice(arena, "… (more results omitted)\n") catch {};
            break;
        }
        if (globMatch(pattern, entry_path)) {
            out.print(arena, "{s}\n", .{entry_path}) catch {};
            count += 1;
        }
    }
    if (count == 0) return std.fmt.allocPrint(arena, "no matches: {s}", .{pattern});
    return out.items;
}

// ── grep: rg nativo > grep nativo > fallback interno ─────────
fn toolGrep(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const pattern = getStr(obj, "pattern") orelse return error.MissingPattern;
    const subdir = getStr(obj, "subdir") orelse ".";

    // 1) ripgrep (el mejor: rápido, respeta .gitignore)
    const rg_argv = [_][]const u8{ "rg", "--no-heading", "-n", "--max-count", "5", "--max-columns", "300", pattern, subdir };
    if (nativeGrep(arena, io, &rg_argv)) |out| return out;

    // 2) grep -rn del sistema
    const grep_argv = [_][]const u8{ "grep", "-rn", "--include=*", "-m", "5", pattern, subdir };
    if (nativeGrep(arena, io, &grep_argv)) |out| return out;

    // 3) fallback: motor regex interno
    return fallbackGrep(io, pattern, subdir, arena);
}

/// Corre un binario nativo de grep; null si el binario no existe.
fn nativeGrep(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_tool_output),
        .stderr_limit = .limited(2048),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch return null;
    // rg exit 1 = sin matches; exit 127/2 = binario/uso inválido → probar siguiente
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return null,
    };
    if (code == 0 and result.stdout.len > 0) {
        // Trunca a ~80 líneas para no quemar tokens
        return truncateLines(arena, result.stdout, 80);
    }
    if (code == 1) {
        return "no matches";
    }
    return null;
}

fn truncateLines(arena: std.mem.Allocator, data: []const u8, max_lines: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (count >= max_lines) {
            out.appendSlice(arena, "… (truncated)\n") catch {};
            break;
        }
        out.appendSlice(arena, line) catch {};
        out.appendSlice(arena, "\n") catch {};
        count += 1;
    }
    return out.items;
}

/// Fallback puro-Zig para cuando no hay rg ni grep (raro en dev boxes).
fn fallbackGrep(io: std.Io, pattern: []const u8, subdir: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const regex = @import("regex.zig").Regex.compile(pattern);

    var out: std.ArrayList(u8) = .empty;
    var matches: usize = 0;
    const max_matches = 150;

    var walker = try walkZig(io, arena, subdir);
    defer walker.deinit();

    while (walker.next()) |entry_path| {
        defer arena.free(entry_path);
        if (matches >= max_matches) {
            out.appendSlice(arena, "… (more matches omitted)\n") catch {};
            break;
        }
        if (!looksLikeText(entry_path)) continue;
        const data = std.Io.Dir.cwd().readFileAlloc(io, entry_path, arena, .limited(2 * 1024 * 1024)) catch continue;
        defer arena.free(data);

        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (regex.matches(line)) {
                out.print(arena, "{s}:{d}: {s}\n", .{ entry_path, line_no, line[0..@min(line.len, 300)] }) catch {};
                matches += 1;
                if (matches >= max_matches) break;
            }
        }
    }
    if (matches == 0) return std.fmt.allocPrint(arena, "no matches: {s}", .{pattern});
    return out.items;
}

// ── list_files: listing plano del directorio (barato) ────────
fn toolListFiles(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse ".";
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(arena, "error opening {s}: {t}", .{ path, err });
    };
    defer dir.close(io);

    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.name.len > 0 and e.name[0] == '.') continue; // hidden
        const tag: []const u8 = switch (e.kind) {
            .directory => "d",
            .file => "f",
            else => "?",
        };
        out.print(arena, "{s} {s}\n", .{ tag, e.name }) catch {};
        count += 1;
        if (count >= 500) {
            out.appendSlice(arena, "… (truncated)\n") catch {};
            break;
        }
    }
    if (count == 0) return std.fmt.allocPrint(arena, "(empty) {s}", .{path});
    return out.items;
}

// ── web: leer internet (sin permisos: son lecturas) ──────────

/// Tope duro de una respuesta web. 200 KB de texto es de sobra para leer una
/// doc y evita que una página infinita (un listado de 50 000 enlaces) reviente
/// el contexto del turno.
const web_hard_cap = 200 * 1024;

fn browserHeaders() [3]http.Http.ExtraHeader {
    return .{
        .{ .name = "user-agent", .value = web.user_agent },
        .{ .name = "accept", .value = "text/html,application/json,text/plain;q=0.9,*/*;q=0.8" },
        // OJO: `accept-encoding` NO se puede dejar fuera y confiar. `std.http`
        // pone `accept_encoding = .omit` (que es "no mandar el header"), y sin
        // él GitHub y compañía devuelven gzip: el modelo se come 16 KB de
        // bytes ilegibles y no sabe qué dice la página. Se pide `identity`
        // explícitamente, que es la única forma de decir "sin comprimir" con
        // std, que no descomprime de forma transparente.
        .{ .name = "accept-encoding", .value = "identity" },
    };
}

/// ¿El body viene comprimido? (zstd, gzip, brotli…)
///
/// Red de seguridad para cuando un servidor ignora `accept-encoding: identity`:
/// mejor un mensaje que diga "vino comprimido" que 16 KB de binario que el
/// modelo se lee como texto.
fn looksCompressed(body: []const u8) ?[]const u8 {
    if (body.len < 2) return null;
    // gzip 1f 8b, zstd 28 b5 2f fd, brotli (sin magic fijo: muchos sitios lo
    // sirven sin cabecera reconocible, y se detecta por UTF-8 inválido abajo).
    if (body[0] == 0x1f and body[1] == 0x8b) return "gzip";
    if (body[0] == 0x28 and body[1] == 0xb5 and body.len >= 4 and body[2] == 0x2f and body[3] == 0xfd) return "zstd";
    // Binario genérico: muchos NUL o bytes de control sueltos.
    var ctrl: usize = 0;
    const probe = body[0..@min(body.len, 512)];
    for (probe) |b| {
        if (b < 0x09 or (b > 0x0d and b < 0x20)) ctrl += 1;
    }
    if (probe.len > 32 and ctrl * 4 > probe.len) return "binary";
    return null;
}

/// `web_fetch`: GET a una URL y el contenido como texto legible.
///
/// El cuerpo se pasa SIEMPRE por `web.htmlToText` cuando parece HTML, porque
/// modelar 300 KB de etiquetas es tirar el contexto. Un JSON o un texto plano
/// pasan intactos.
fn toolWebFetch(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const url = getStr(obj, "url") orelse
        return "error: web_fetch needs a `url` (http:// or https://)";
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (!isHttpUrl(trimmed)) {
        return std.fmt.allocPrint(arena, "error: only http:// and https:// URLs can be fetched, got: {s}", .{trimmed});
    }

    var max_bytes: usize = max_tool_output;
    if (getInt(obj, "max_bytes")) |mb| {
        if (mb > 0) max_bytes = @min(@as(usize, @intCast(mb)), web_hard_cap);
    }

    var h = http.Http.init(arena, io);
    defer h.deinit();

    const res = h.getWithHeaders(trimmed, &browserHeaders()) catch |err| {
        return std.fmt.allocPrint(arena, "error fetching {s}: {t}", .{ trimmed, err });
    };
    defer h.freeBody(res.body);

    const body = res.body;
    // Un cuerpo comprimido no es texto: decirlo es infinitamente mejor que
    // devolver binario y que el modelo se lo lea como si fueran palabras.
    if (looksCompressed(body)) |kind| {
        return std.fmt.allocPrint(arena, "{s} answered with {s}-encoded content that zode cannot decode. Try a different URL (a .json or .txt endpoint usually works).", .{ trimmed, kind });
    }
    // Un 4xx/5xx también es información: se devuelve el status y lo que dijo el
    // server, que es donde está el motivo real ("Model access is disabled").
    if (res.status < 200 or res.status >= 300) {
        return std.fmt.allocPrint(arena, "HTTP {d} {s}\n{s}", .{
            res.status,
            trimmed,
            body[0..@min(body.len, 2000)],
        });
    }

    const is_html = looksLikeHtml(body);
    const text = if (is_html) web.htmlToText(arena, body) else body;

    if (text.len == 0) return "(empty body)";

    // OJO: el resultado se COPIA a memoria propia de la arena. Devolver un slice
    // del buffer del HTTP es una bomba de relojería: el `defer freeBody` de más
    // arriba lo suelta al salir de esta función, y el ArenaAllocator REUTILIZA
    // esa memoria en la siguiente allocación (la del pool de `client.deinit`, la
    // del propio growth del buffer…). El llamante leía `0xAA` donde debería
    // estar el JSON. Pasa por el truncado y por el camino corto, y solo con
    // arena: por eso no salió en los tests de red.
    var out: std.ArrayList(u8) = .empty;
    if (text.len <= max_bytes) {
        out.appendSlice(arena, text) catch return "out of memory building the answer";
    } else {
        // Se corta en un límite de línea: cortar a mitad de una palabra deja
        // una basura que el modelo se queda pensando que es el final del
        // documento.
        var cut = max_bytes;
        while (cut > 0 and text[cut] != '\n') cut -= 1;
        if (cut < max_bytes / 2) cut = max_bytes; // página sin saltos: corte seco
        out.appendSlice(arena, text[0..cut]) catch return "out of memory building the answer";
        out.print(arena, "\n\n… (truncated at {d} of {d} bytes; ask for the rest with a deeper request)", .{ cut, text.len }) catch {};
    }
    return out.items;
}

/// `web_search`: resultados de DuckDuckGo (endpoint `html/`, sin API key).
///
/// Es un scrape, y se romperá el día que cambien una clase del HTML. Cuando
/// pasa, el error lo dice (con la alternativa) en vez de devolver una lista
/// vacía, que el modelo interpretaría como "no hay resultados".
fn toolWebSearch(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const query = getStr(obj, "query") orelse
        return "error: web_search needs a `query`";
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return "error: empty query";

    var max_results: usize = 8;
    if (getInt(obj, "max_results")) |mr| {
        if (mr > 0) max_results = @min(@as(usize, @intCast(mr)), 20);
    }

    // El endpoint `html/` de DDG es el que no pide JS ni key. La query va
    // percent-encoded con el encoder de `std.Uri` (a mano se olvidan los `&` y
    // el `+`, y la búsqueda se va al servidor en pieces).
    var url_buf: [1024]u8 = undefined;
    var uw: std.Io.Writer = .fixed(&url_buf);
    uw.writeAll("https://html.duckduckgo.com/html/?q=") catch return "error: query too long";
    // OJO: `std.Uri.Writer` NO es `pub` en 0.16, así que el encoder del
    // componente de query no se puede usar desde aquí. Se percent-encoded a
    // mano, que para una query son cuatro caracteres.
    percentEncodeQuery(q, &uw) catch return "error: query too long";
    const url = uw.buffered();

    var h = http.Http.init(arena, io);
    defer h.deinit();

    const res = h.getWithHeaders(url, &browserHeaders()) catch |err| {
        return std.fmt.allocPrint(arena, "error searching \"{s}\": {t}", .{ q, err });
    };
    defer h.freeBody(res.body);

    if (res.status < 200 or res.status >= 300) {
        return std.fmt.allocPrint(arena, "HTTP {d} from the search engine for \"{s}\"", .{ res.status, q });
    }

    const results = web.searchResults(arena, res.body, max_results);
    if (results.len == 0) {
        return std.fmt.allocPrint(arena, "no results parsed for \"{s}\" (the search engine changed its HTML; try web_fetch on the page directly, or rephrase)", .{q});
    }
    return results;
}

/// Percent-encoding de una query string a mano.
///
/// `std.Uri.Writer` (que sí lo sabe hacer) no es `pub` en 0.16, y `std.Uri`
/// solo expone el encoder por dentro. Son cuatro caracteres reserved y es una
/// línea; lo importante es que `&` y `+` accounted: sin ellos, "zod & mcp"
/// llega al servidor como dos búsquedas distintas.
fn percentEncodeQuery(raw: []const u8, w: *std.Io.Writer) !void {
    for (raw) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try w.writeByte(c);
        } else if (c == ' ') {
            try w.writeByte('+');
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn isHttpUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "http://")) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    return false;
}

/// ¿El body es HTML?
///
/// Se deduce del body y NO del `content-type`: ese header vive en el buffer de
/// redirects de `receiveHead`, que muere al salir del request (ver el aviso en
/// `http_client.JsonResult`). Un servidor puede además mandar `text/plain` con
/// HTML dentro, o al revés, así que la cabecera tampoco era de fiar.
///
/// Mira el principio del documento por `<!doctype html`, `<html`, `<head` o
/// `<body`, que es donde los pone cualquier plantilla, y descarta lo que empieza
/// por `{` o `[` (JSON) o por `#!` (shebang de un gist).
fn looksLikeHtml(body: []const u8) bool {
    const head = body[0..@min(body.len, 1024)];
    if (head.len == 0) return false;
    if (head[0] == '{' or head[0] == '[') return false;
    const trimmed = std.mem.trimStart(u8, head, " \t\r\n\u{feff}");
    if (std.mem.startsWith(u8, trimmed, "#!")) return false;
    return std.ascii.indexOfIgnoreCase(trimmed, "<!doctype html") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "<html") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "<head") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "<body") != null;
}

// ── think: scratchpad sin efectos (mejora planificación) ─────
fn toolThink(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const thought = getStr(obj, "thought") orelse return error.MissingPath;
    return std.fmt.allocPrint(arena, "noted ({d} chars). Continue with your plan.", .{thought.len});
}

// ── todo: el plan que el usuario ve en pantalla ────────────────
//
// NO pide permiso. No toca el disco ni la red: solo guarda una lista en la
// sesión, que es exactamente lo mismo que hace `think` pero en vez deirselo al
// modelo se lo enseña al usuario.

/// Aplica la lista y devuelve lo que hay que contarle al modelo.
///
/// OJO con la propiedad de la memoria: lo que sale de aquí va al `tool_result`
/// del historial (que es de largo plazo) y al plan de la pantalla. El texto es
/// una copia en `arena`, nunca un slice de los buffers fijos de `Item`, porque
/// esos los pisa la siguiente llamada.
fn toolTodo(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    // `fromValue` y no `parseItems`: el JSON ya está parseado (lo parsea
    // `execute` para todas las tools), y volver a parsear 4 KB para sacar 20
    // strings es tirar trabajo.
    const parsed = plan_mod.fromValue(.{ .object = obj }, &items) catch |err| switch (err) {
        error.TooManyItems => return error.TooManyPlanItems,
        error.BadPlan => return error.BadPlan,
    };
    if (parsed.len == 0) return error.EmptyPlan;
    return std.fmt.allocPrint(arena, "plan recorded ({d} step{s}). Keep it updated as you go.", .{
        parsed.len,
        if (parsed.len == 1) "" else "s",
    });
}

fn looksLikeText(path: []const u8) bool {
    const skip_dirs = [_][]const u8{ ".zig-cache/", "zig-out/", ".git/", "node_modules/" };
    for (skip_dirs) |d| {
        if (std.mem.indexOf(u8, path, d) != null) return false;
    }
    return true;
}

// ── walker recursivo con skip de dirs binarias/vendidas ──────
const Walker = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    stack: std.ArrayList([]const u8),
    current_dir: ?std.Io.Dir = null,
    current_iter: ?std.Io.Dir.Iterator = null,
    current_base: []const u8 = "",

    fn deinit(self: *Walker) void {
        for (self.stack.items) |p| self.arena.free(p);
        self.stack.deinit(self.arena);
    }

    /// Devuelve ruta del siguiente archivo (caller libera con arena.free)
    fn next(self: *Walker) ?[]const u8 {
        while (true) {
            if (self.current_dir == null) {
                const next_dir = self.stack.pop() orelse return null;
                self.current_base = next_dir;
                self.current_dir = std.Io.Dir.cwd().openDir(self.io, next_dir, .{ .iterate = true }) catch {
                    self.arena.free(next_dir);
                    continue;
                };
                self.current_iter = self.current_dir.?.iterate();
                continue;
            }
            // Siguiente entry del dir actual
            const entry = self.current_iter.?.next(self.io) catch null;
            if (entry) |e| {
                const full = if (std.mem.eql(u8, self.current_base, "."))
                    (self.arena.dupe(u8, e.name) catch continue)
                else
                    (std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.current_base, e.name }) catch continue);
                switch (e.kind) {
                    .directory => {
                        if (isSkippable(e.name)) {
                            self.arena.free(full);
                            continue;
                        }
                        self.stack.append(self.arena, full) catch self.arena.free(full);
                    },
                    .file => return full,
                    else => {
                        self.arena.free(full);
                        continue;
                    },
                }
            } else {
                // Dir agotado
                if (self.current_base.len > 0) self.arena.free(self.current_base);
                self.current_dir.?.close(self.io);
                self.current_dir = null;
                self.current_iter = null;
            }
        }
    }

    fn isSkippable(name: []const u8) bool {
        const skip = [_][]const u8{ ".git", "node_modules", ".zig-cache", "zig-out", ".cache", "target", "dist", "build" };
        for (skip) |s| {
            if (std.mem.eql(u8, name, s)) return true;
        }
        return name.len > 0 and name[0] == '.';
    }
};

fn walkZig(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Walker {
    var w = Walker{
        .io = io,
        .arena = arena,
        .stack = .empty,
    };
    const root_copy = try arena.dupe(u8, root);
    try w.stack.append(arena, root_copy);
    return w;
}

// ── glob matcher ( *, **, ? ) recursivo ──────────────────────
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globHere(pattern, path);
}

fn globHere(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;

    // '**' = cualquier cosa, incluyendo '/'
    if (p.len >= 2 and p[0] == '*' and p[1] == '*') {
        var rest = p[2..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        // ** consume 0 chars:
        if (globHere(rest, s)) return true;
        // ** consume 1 char y sigue:
        if (s.len > 0) return globHere(p, s[1..]);
        return false;
    }

    // '*' = cualquier cosa excepto '/'
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globHere(p[1..], s[i..])) return true;
            if (i < s.len and s[i] == '/') return false;
        }
        return false;
    }

    // '?' = un char (no '/')
    if (p[0] == '?') {
        if (s.len == 0 or s[0] == '/') return false;
        return globHere(p[1..], s[1..]);
    }

    if (s.len == 0 or p[0] != s[0]) return false;
    return globHere(p[1..], s[1..]);
}

// ── tests ────────────────────────────────────────────────────
test "glob matcher" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(globMatch("**/*.zig", "src/deep/x.zig"));
    try std.testing.expect(globMatch("src/*.zig", "src/main.zig"));
    try std.testing.expect(!globMatch("src/*.zig", "src/deep/x.zig"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(globMatch("**", "x/y/z"));
}

test "needsPermission" {
    try std.testing.expect(!needsPermission("read"));
    try std.testing.expect(needsPermission("write"));
    try std.testing.expect(needsPermission("bash"));
}

test "list_files lista este src" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "list_files", "{\"path\":\"src\"}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "f main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "f tools.zig") != null);
}

test "think devuelve OK sin efectos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "think", "{\"thought\":\"plan: read file first\"}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "noted") != null);
}

test "toolsJson es JSON válido y tiene una entrada por tool" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), toolsJson(), .{}) catch {
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(v == .array);
    // El número sale de `defs`, no de un número escrito a mano: añadir una tool
    // sin declararla en el JSON (o al revés) falla aquí en vez de dejar al
    // modelo con una tool que no existe.
    try std.testing.expectEqual(defs.len, v.array.items.len);
    for (v.array.items) |item| {
        const fname = item.object.get("function").?.object.get("name").?.string;
        var found = false;
        for (defs) |d| {
            if (std.mem.eql(u8, d.name, fname)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "las tools de web no piden permiso (son lecturas)" {
    // Pedir confirmación por cada consulta a internet convierte el agent loop en
    // un interrogatorio. Mismo criterio que read/grep.
    try std.testing.expect(!needsPermission("web_fetch"));
    try std.testing.expect(!needsPermission("web_search"));
    try std.testing.expect(needsPermission("write"));
}

test "web_fetch y web_search aparecen en el JSON con su descripción" {
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "\"web_fetch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "\"web_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "html.duckduckgo.com") == null); // el endpoint va en el código, no en el prompt
}

test "web_fetch rechaza lo que no es http(s) sin tocar la red" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_fetch", "{\"url\":\"file:///etc/passwd\"}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "only http:// and https://") != null);
}

test "web_fetch sin url lo dice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_fetch", "{}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "needs a `url`") != null);
}

test "web_search sin query lo dice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_search", "{}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "needs a `query`") != null);
}

test "percentEncodeQuery escapa lo que rompe una URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try percentEncodeQuery("zod & mcp/nuevo+1", &w);
    try std.testing.expectEqualStrings("zod+%26+mcp%2Fnuevo%2B1", w.buffered());
}

// ── tests de red (se saltan si no hay internet) ──────────────
//
// Estos son los únicos que pueden cazar la clase de bug más cara de este
// archivo: devolver una VISTA del buffer del HTTP en vez de una copia. Con
// arena, `freeBody` (que está en un `defer`) suelta la memoria al salir de la
// tool y el ArenaAllocator la reutiliza en la siguiente allocación; el
// llamante leía `0xAA` donde debería estar el JSON. No hay forma de reproducirlo
// sin red, y sin red el bug se cuela.

/// `true` si el error es de red (y el test se salta) en vez de un fallo real.
fn isNetError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.HostLackingDnsResolver,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.UnknownHostName,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.SocketNotConnected,
        => true,
        else => false,
    };
}

test "web_fetch real: el HTML llega como texto, no como etiquetas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "web_fetch", "{\"url\":\"https://example.com/\"}", arena_state.allocator()) catch |err| {
        if (isNetError(err)) return error.SkipZigTest;
        return err;
    };
    // OJO: example.com cambia su texto cada tanto; el test comprueba la
    // FORMA (sin etiquetas, con frases con espacios) y no la frase exacta. Un
    // test que falla porque una web cambió de copy no vale para nada.
    try std.testing.expect(out.len > 40);
    // El texto legible no lleva etiquetas: si el buffer del HTTP se hubiera
    // soltado, aquí aparecerían bytes de relleno (`0xAA`) en vez de la frase.
    try std.testing.expect(std.mem.indexOf(u8, out, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<div") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "documentation examples") != null);
}

test "web_search real: devuelve resultados con URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "web_search", "{\"query\":\"zig programming language\",\"max_results\":3}", arena_state.allocator()) catch |err| {
        if (isNetError(err)) return error.SkipZigTest;
        return err;
    };
    // Si el scraper cambia, esto falla y avisa: es lo que se busca.
    try std.testing.expect(std.mem.indexOf(u8, out, "1. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http") != null);
}

// ── tests de integración con testing.io ──
test "tool read lee este archivo" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const args = "{\"path\":\"src/tools.zig\"}";
    const out = try execute(std.testing.io, "read", args, arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "toolRead") != null);
}

test "glob encuentra zigs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "glob", "{\"pattern\":\"src/*.zig\"}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "src/main.zig") != null);
}

test "grep nativo encuentra patrón" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "grep", "{\"pattern\":\"toolGrep\",\"subdir\":\"src\"}", arena_state.allocator()) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest; // sin rg/grep en PATH
        return err;
    };
    try std.testing.expect(std.mem.indexOf(u8, out, "toolGrep") != null);
}
