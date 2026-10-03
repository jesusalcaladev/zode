const std = @import("std");
const plan_mod = @import("lib/plan.zig");
const http = @import("lib/http_client.zig");
const web = @import("lib/web.zig");
const bgproc = @import("bgproc.zig");
const verify_mod = @import("lib/verify.zig");
const readcache = @import("lib/readcache.zig");

pub const max_tool_output = 16 * 1024; // output budget per tool

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
    .{ .name = "ask", .desc = "Ask the user one question when the answer changes what you do" },
    .{ .name = "skill", .desc = "Load a skill's full instructions on demand (cheap: only its name is in your prompt)" },
    .{ .name = "task", .desc = "Send a read-only search to a subagent with its own context, get back a short report" },
    .{ .name = "bash_output", .desc = "New output of a backgrounded command (incremental) plus its exit status" },
    .{ .name = "bash_kill", .desc = "Kill a backgrounded command" },
};

/// Tools that can run at the same time as each other.
///
/// Every one of these only READS: `read`/`grep`/`glob`/`list_files` see the
/// filesystem, `web_*` see the network, and none of them can observe or change
/// another. That is the whole requirement — not "they are cheap", not "they
/// usually do not conflict" — because `execToolCalls` runs a batch of these
/// concurrently and a tool that writes, or that the model expects to see the
/// world after, has to be in the serial part or the result is a race.
///
/// `bash` is NOT here even when it is `cat file`: a `bash` can write, and the
/// model may have asked for two `bash` in a row where the second reads what the
/// first wrote.
pub fn isParallelSafe(name: []const u8) bool {
    return std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "list_files") or
        std.mem.eql(u8, name, "web_fetch") or
        std.mem.eql(u8, name, "web_search");
}

/// Declares the tools to the LLM (OpenAI format). Static: 0 allocs per request.
pub fn toolsJson() []const u8 {
    return
    \\[
    \\{"type":"function","function":{"name":"read","description":"Read a file from disk. Optionally read a specific line range with offset/limit. If you already read that exact range and the file has not changed, this returns a one-line note instead of the text: the content is still in your context, so quote it from there, or pass force:true when you really need the text again (for example after it was elided from the context).","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"1-indexed start line"},"limit":{"type":"integer"},"force":{"type":"boolean","description":"send the text again even if it is unchanged"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write","description":"Create or overwrite a file with the given content.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit","description":"Exact string replacement in a file. Single hunk via old_string/new_string, or several at once via edits:[{old_string,new_string},...] (applied in order, all validated first). old_string must appear exactly once unless allow_multiple is true.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["old_string","new_string"]}},"allow_multiple":{"type":"boolean"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"bash","description":"Run a shell command and get combined stdout+stderr (truncated). By default this BLOCKS until the command finishes, which for anything slow (a build, a test suite, an install) leaves you unable to do anything else while you wait. For those, pass run_in_background: true: it returns a job id immediately and you keep working. Then poll with bash_output when you actually need the result, and bash_kill if you change your mind.","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout_seconds":{"type":"integer","description":"foreground only; default 30"},"run_in_background":{"type":"boolean","description":"return a job id at once instead of waiting"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"glob","description":"Find files matching a glob pattern like src/**/*.zig.","parameters":{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"grep","description":"Search file contents with a regex. Returns path:line:text matches.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"subdir":{"type":"string"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"list_files","description":"List files and directories directly inside a path (non-recursive, cheap).","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch an http(s) URL and return the content as readable text (HTML tags, scripts and styles are stripped, entities decoded). Use it to read documentation, a release page or any URL the user mentions. A non-2xx answer returns the status plus the body, so you can see what the site said. Truncated to a byte budget; ask for a deeper offset if the text is cut.","parameters":{"type":"object","properties":{"url":{"type":"string"},"max_bytes":{"type":"integer","description":"bytes of text to keep (default 16000, max 200000)"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_search","description":"Search the web and get titles, URLs and snippets. Use it when you need something you do not know yet (docs, versions, error messages), then web_fetch the promising URLs.","parameters":{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer","description":"1..20, default 8"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"think","description":"Think privately step by step before acting. Use for planning and complex reasoning. No side effects.","parameters":{"type":"object","properties":{"thought":{"type":"string"}},"required":["thought"]}}},
    \\{"type":"function","function":{"name":"todo","description":"Write the task list the USER SEES on screen, for tasks with more than about two steps. Send the WHOLE list every time (it replaces the previous one), each item {content, status: pending|in_progress|done}. Mark exactly one in_progress while you work on it, and never more than one. Call it again when a step finishes or the plan changes, and send an empty list when everything is done. Do not use it for a single obvious step or for thinking out loud.","parameters":{"type":"object","properties":{"items":{"type":"array","maxItems":20,"items":{"type":"object","properties":{"content":{"type":"string","description":"imperative, short (a single line)"},"status":{"type":"string","enum":["pending","in_progress","done"]}},"required":["content","status"]}}},"required":["items"]}}},
    \\{"type":"function","function":{"name":"ask","description":"Ask the USER one question, and wait for the answer. Use it when the answer changes what you do next: a choice between approaches, an ambiguous request with two real readings, a 'which one'. Do NOT ask what you can find out yourself — read the file, grep, run the command first, and only ask if it is still unclear after that. One question per step, at most three in a whole turn. Put your recommendation first in the question text so the user can just press enter. With 2 to 5 `options` it becomes a menu; with no options the user types free text. If the user does not answer (esc) you must decide on your own, say which option you picked and why, and carry on: do not ask again. `header` is a 2-3 word label for the dialog, not the question.","parameters":{"type":"object","properties":{"question":{"type":"string","description":"the question, with your recommendation and its reason up front"},"header":{"type":"string","description":"2-3 word label for the dialog"},"options":{"type":"array","minItems":2,"maxItems":5,"items":{"type":"string","description":"one choice, on a single line"}}},"required":["question"]}}},
    \\{"type":"function","function":{"name":"skill","description":"Load a skill: a folder of instructions written for a specific kind of task. Your prompt lists only the name and when to use it (the body is not in your prompt, so it costs nothing until you ask). Load one when its description matches what you are about to do, and load none when none of them do.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"the skill's name, exactly as listed"}},"required":["name"]}}},
    \\{"type":"function","function":{"name":"task","description":"Send a read-only investigation to a SUBAGENT that has its own context window, and get back a short report (a few lines with paths and line numbers). Use it when the search is big: grepping across a large tree, tracing where something is used, reading many files to answer one question. Everything the subagent reads is paid for ONCE in a window that is then thrown away, instead of staying in your context and being resent on every remaining step — so for a wide search this is much cheaper than doing it yourself. It cannot write anything and cannot ask the user anything; if it needs a decision only the user can make, it says so in the report and you decide whether to ask. Use it for search; do it yourself when you already know the file to change. You can send SEVERAL task calls in one message when the searches are independent (a different area each one): they run at the same time instead of one after the other, and the reports come back in the order you asked. Do not send two tasks that need the answer of the other, and do not send one task per file when a single grep covers it.","parameters":{"type":"object","properties":{"description":{"type":"string","description":"one line: what to find out"},"prompt":{"type":"string","description":"the full question, including where to look and what to report back"}},"required":["description"]}}},
    \\{"type":"function","function":{"name":"bash_output","description":"Read the NEW output of a command you started with run_in_background, plus whether it is still running or what it exited with. Incremental: you get what appeared since your last call, not the whole buffer, so polling is cheap. Poll once per step, and do not poll in a tight loop — do something else in between.","parameters":{"type":"object","properties":{"id":{"type":"integer","description":"the id bash gave you"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"bash_kill","description":"Kill a backgrounded command. Use it when you no longer need the result, or when it is clearly going the wrong way.","parameters":{"type":"object","properties":{"id":{"type":"integer","description":"the id bash gave you"}},"required":["id"]}}}
    \\]
    ;
}

/// Does this tool need to ask the user before running it?
///
/// `web_fetch` and `web_search` do NOT ask: they are reads, they write nothing, and
/// a dialog for every internet query turns the agent loop into an interrogation.
/// Same criterion as `read` or `grep`.
///
/// The three new ones are in the no-permission group for different reasons, and
/// it is worth being explicit about each:
///
/// - `ask` asks by DESIGN. Putting it behind a permission dialog would be two
///   dialogs for one question, and the second would be a yes/no about the first.
/// - `skill` only reads a file and returns text.
/// - `bash_output`/`bash_kill` only talk to processes THIS TURN started, whose
///   creation already went through the `bash` permission. Asking again would be
///   asking twice about the same command.
///
/// `task` DOES ask: a subagent spends tokens and can read the whole repo, so it
/// goes through the same dialog as `web_fetch` would if we had not decided reads
/// are free. What makes it acceptable is that it cannot write.
pub fn needsPermission(name: []const u8) bool {
    return !(std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "list_files") or
        std.mem.eql(u8, name, "web_fetch") or
        std.mem.eql(u8, name, "web_search") or
        std.mem.eql(u8, name, "think") or
        std.mem.eql(u8, name, "todo") or
        std.mem.eql(u8, name, "ask") or
        std.mem.eql(u8, name, "skill") or
        std.mem.eql(u8, name, "bash_output") or
        std.mem.eql(u8, name, "bash_kill"));
}

/// Runs a tool with JSON args. Returns the (truncated) result —
/// `arena` memory, valid until the arena is freed.
///
/// `bg` is the background-process registry, and it is a PARAMETER rather than a
/// global because it lives in the `Model`: two `Model`s (the real one and the
/// ones the tests build) must not share a list of running processes. `null` means
/// "no registry", which only happens in the tests, and a `bash` that asks to run
/// in the background then gets an error that says exactly that instead of
/// silently running in the foreground (which would look like `run_in_background`
/// works).
///
/// `cache` is the read cache, for the same reason and with the same shape: it
/// lives in the `Model`, `read` runs in parallel with other reads so the lock is
/// inside the cache, and `null` (which is what the tests pass) means every read
/// sends its body as always — the behaviour we want to be able to test both ways.
pub fn execute(
    io: std.Io,
    name: []const u8,
    args_json: []const u8,
    arena: std.mem.Allocator,
    bg: ?*bgproc.Registry,
    cache: ?*readcache.Cache,
) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{});
    if (parsed != .object) return error.BadArgs;
    const obj = parsed.object;

    if (std.mem.eql(u8, name, "read")) {
        return toolRead(io, obj, arena, cache);
    } else if (std.mem.eql(u8, name, "write")) {
        return toolWrite(io, obj, arena);
    } else if (std.mem.eql(u8, name, "edit")) {
        return toolEdit(io, obj, arena);
    } else if (std.mem.eql(u8, name, "bash")) {
        return toolBash(io, obj, arena, bg);
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
    } else if (std.mem.eql(u8, name, "bash_output")) {
        return toolBashOutput(obj, arena, bg);
    } else if (std.mem.eql(u8, name, "bash_kill")) {
        return toolBashKill(obj, arena, bg, io);
    }
    // `ask`, `task` and `skill` are NOT here on purpose: they need the `Model`
    // (the dialog, the worker loop, the loaded skills), which `tools.zig` cannot
    // see without importing `tui.zig`, which imports this. `agent.execToolCalls`
    // intercepts them BEFORE calling `execute`. Reaching here means the
    // interception is missing, and saying so is better than an `UnknownTool`
    // that looks like a typo in the model's arguments.
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

/// `true`, `false`, or absent. A STRING `"true"` counts: models emit both, and
/// rejecting the string form makes `run_in_background` silently false, which
/// looks like the tool ignoring the flag.
fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.ascii.eqlIgnoreCase(s, "true"),
        .integer => |i| i != 0,
        else => false,
    };
}

/// `bash_output`: the new output plus the status.
fn toolBashOutput(obj: std.json.ObjectMap, arena: std.mem.Allocator, reg: ?*bgproc.Registry) ![]const u8 {
    const r = reg orelse return error.NoBackgroundRegistry;
    const id_i = getInt(obj, "id") orelse return error.MissingId;
    if (id_i <= 0) return error.MissingId;
    const id: u32 = @intCast(id_i);

    var out = bgproc.Output{};
    const text = bgproc.read(r, &out, id) catch |err| switch (err) {
        // `NoNewOutput` is NOT reported as an error string: the model would read
        // it as "the command failed". It is the normal answer to "anything new?".
        error.NoNewOutput => return std.fmt.allocPrint(arena, "[job {d}] still running, nothing new yet", .{id}),
        error.UnknownJob => return std.fmt.allocPrint(arena,
            \\no job {d}. Start one with bash and run_in_background: true. (Jobs are
            \\also forgotten when zode restarts.)
            \\
        , .{id}),
    };

    // Tell it what to do next in the same breath, because the common failure is
    // the model polling three times in a row with nothing else happening.
    if (std.mem.eql(u8, bgproc.stateWord(r, id), "running")) {
        return std.fmt.allocPrint(arena, "{s}\n(do something else before polling again)", .{text});
    }
    return text;
}

/// `bash_kill`.
fn toolBashKill(
    obj: std.json.ObjectMap,
    arena: std.mem.Allocator,
    reg: ?*bgproc.Registry,
    io: std.Io,
) ![]const u8 {
    const r = reg orelse return error.NoBackgroundRegistry;
    const id_i = getInt(obj, "id") orelse return error.MissingId;
    if (id_i <= 0) return error.MissingId;
    const id: u32 = @intCast(id_i);
    if (bgproc.kill(r, io, id)) {
        return std.fmt.allocPrint(arena, "killed job {d}. You can still read what it printed with bash_output.", .{id});
    }
    return std.fmt.allocPrint(arena, "job {d} was not running ({s})", .{ id, bgproc.stateWord(r, id) });
}

// ── read ─────────────────────────────────────────────────────

/// Line numbers past this are not worth caching precisely. Nothing real gets
/// there, and the point of the cap is to keep the arithmetic in `usize` until the
/// very last step, not to be right about a 4-million-line generated file.
const read_line_cap: u32 = 1 << 22;

/// `read`, with the cache.
///
/// The shape is: ask the cache with a `stat` first (cheap, no read at all), and
/// only read the bytes when it cannot answer. Three outcomes, and the order
/// matters because each one is cheaper and more certain than the next:
///
/// 1. same inode+mtime+size AND those lines were already sent → the content is
///    in the model's context, so say so in five lines instead of sending it;
/// 2. the cache has seen the file but the stat moved → read it and compare the
///    HASH, because a moved mtime does not mean changed content (`git checkout`,
///    `cp -p`) and an unchanged mtime does not mean unchanged content (same
///    second, same length);
/// 3. otherwise send the body as always.
fn toolRead(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator, cache: ?*readcache.Cache) ![]const u8 {
    const path = getStr(obj, "path") orelse return error.MissingPath;
    const offset: usize = if (getInt(obj, "offset")) |o| (if (o > 0) @intCast(o) else 1) else 1;
    const default_limit: usize = 2000;
    const limit: usize = if (getInt(obj, "limit")) |l| (if (l > 0) @intCast(l) else default_limit) else default_limit;
    // The escape hatch, and it is NOT optional. A cache that says "you already
    // have this" when it is wrong leaves the model with no way to get the file
    // back, and it cannot argue its way out of a tool result. One boolean in the
    // schema is cheaper than a turn lost.
    const force = getBool(obj, "force");

    var dir = std.Io.Dir.cwd();
    const first_line: u32 = @intCast(@min(offset, read_line_cap));
    const last_line: u32 = @intCast(@min(offset + limit, read_line_cap));

    if (cache) |c| {
        if (!force) {
            if (dir.statFile(io, path, .{})) |st| {
                switch (c.check(path, st, first_line, last_line)) {
                    .already_sent => |sent| return unchangedNote(arena, path, sent.lines),
                    .read_then_decide => |prev| {
                        const data = try readAll(arena, io, path);
                        const hash = readcache.hashBytes(data);
                        const lines: u32 = @intCast(@min(lineCount(data), read_line_cap));
                        // Same bytes, different timestamp: the model DOES have
                        // these lines, they are the ones it read before, and only
                        // the stat is stale. So refresh it and answer short.
                        //
                        // `covers` is part of the condition and NOT an
                        // afterthought: the cache is per RANGE. Same content with
                        // a wider request ("I had read lines 1-2, now give me the
                        // whole file") has to send the whole file, and answering
                        // "unchanged" there is a lie about lines the model never
                        // got. The test that pins it is the read-cache one about
                        // a range that was never read.
                        if (prev.in_context and prev.hash == hash and c.coversRangeOf(path, first_line, last_line)) {
                            const saved: usize = @intCast(@min(data.len, readcache.max_saved));
                            c.confirmUnchanged(path, st, first_line, last_line, saved);
                            return unchangedNote(arena, path, lines);
                        }
                        const out = try formatBody(arena, path, data, offset, limit);
                        c.record(path, st, hash, first_line, last_line, lines);
                        return out;
                    },
                }
            } else |_| {
                // No `stat`: no fast path. The read below produces the real error,
                // which says more than a cache miss would.
            }
        }
    }

    const data = try readAll(arena, io, path);
    return formatBody(arena, path, data, offset, limit);
}

fn readAll(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    return dir.readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(arena, "error reading {s}: {t}", .{ path, err });
    };
}

/// The answer when the file is already in the context.
///
/// It says three things, and each one is there because of a specific way this
/// goes wrong without it: that the content is STILL THERE (so the model does not
/// re-read it out of anxiety), that it can get it back anyway (`force`), and what
/// it is being told NO rather than handed nothing.
fn unchangedNote(arena: std.mem.Allocator, path: []const u8, lines: u32) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\unchanged: {s} — {d} lines, byte-identical to the content already in your
        \\context, so it is not repeated here. It is still above you in this
        \\conversation: quote from it, or read it again with {{"force": true}} if you
        \\genuinely need the text again.
    , .{ path, lines });
}

/// The body, numbered, with the truncation notice.
///
/// `path` is only for the error string the caller may return; the body itself
/// says nothing about the file, because the header above it in the history
/// already says it.
fn formatBody(arena: std.mem.Allocator, path: []const u8, data: []const u8, offset: usize, limit: usize) ![]const u8 {
    _ = path;
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
        // Truncate huge (minified) lines to 2000 chars.
        const shown = line[0..@min(line.len, 2000)];
        out.print(arena, "{d: >6}| {s}\n", .{ line_no, shown }) catch break;
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
    // The result is NOT just "wrote X (N bytes)": it carries a PREVIEW of what
    // was written. A tool result that says only "ok" makes you open the file to
    // find out whether the model wrote what you asked for, and in an agent loop
    // that check is exactly the step you skip.
    //
    // The preview is part of the tool result (what the MODEL sees to decide
    // whether it worked), not a UI decoration, so it survives to the session
    // file and to `/resume`. It is capped so a 400-line file does not turn into
    // 400 lines of tool result (which would then be elided by the compaction
    // tier and cost a whole extra request).
    var out: std.ArrayList(u8) = .empty;
    // A file ending in `\n` has N lines, not N+1: counting the newline as a
    // separator would report one more line than there is (and the "N more
    // lines" below would be off by one too). Same rule as `splitLines`.
    const total = lineCount(content);
    out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "wrote {s} ({d} bytes, {d} lines)",
        .{ path, content.len, total },
    )) catch return std.fmt.allocPrint(arena, "wrote {s}", .{path});

    const max_preview = 12;
    out.appendSlice(arena, "\n--- preview ---") catch return out.items;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var shown: usize = 0;
    while (lines.next()) |l| {
        if (shown >= max_preview) break;
        out.append(arena, '\n') catch return out.items;
        out.appendSlice(arena, l) catch return out.items;
        shown += 1;
    }
    if (total > shown) {
        out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "\n\u{2026} {d} more lines",
            .{total - shown},
        )) catch {};
    }
    return out.items;
}

/// Lines in `text`, ignoring the final newline: "a\nb\n" is 2 lines, not 3.
///
/// `std.mem.splitScalar` would report the empty string after the last `\n` as a
/// line, and every count derived from it (the header, the "N more lines") would
/// be one too high.
fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    const n = std.mem.count(u8, text, "\n");
    return if (std.mem.endsWith(u8, text, "\n")) n else n + 1;
}

// ── edit: single hunk (compat) or multi-hunk via `edits: [...]` ─
fn toolEdit(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse return error.MissingPath;

    // Collect hunks: `edits: [{old_string,new_string},...]` or a single pair.
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

    // Validate every hunk against the ORIGINAL text (transaction).
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

    // Apply in order (the output of one hunk is the input of the next).
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
/// Runs a command in the FOREGROUND and collects its output, publishing the pid
/// so ESC can kill it.
///
/// This is `std.process.run` with one difference that matters: the child is
/// spawned HERE and its pid published, because `run` keeps the `Child` in its own
/// frame and returns only the output. Without the pid, ESC had nothing to kill and
/// a 30 s build ran to the end of its timeout while the UI said it had been
/// cancelled.
///
/// The timeout is applied on the READ (like `run` does) rather than by killing
/// the child: a command whose output pipe is full is stuck writing, not stuck
/// running, and reading with a timeout is the only way to notice that.
pub fn runForeground(
    gpa: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    timeout_s: u64,
    out_limit: usize,
) !std.process.RunResult {
    var argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    defer child.kill(io);

    if (child.id) |pid| setForeground(pid);

    var mr_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    const timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .fromSeconds(@intCast(timeout_s)), .clock = .awake },
    };
    const stdout_reader = mr.reader(0);
    const stderr_reader = mr.reader(1);

    while (mr.fill(4096, timeout)) |_| {
        // Same rule as `run`: over the limit is an error, not a silent cut. A tool
        // result that stops mid-line looks to the model like the output ended.
        if (stdout_reader.buffered().len > out_limit) return error.StreamTooLong;
        if (stderr_reader.buffered().len > out_limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return error.Timeout,
        else => |e| return e,
    }

    const term = try child.wait(io);
    clearForeground();

    const stdout_slice = try mr.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);
    const stderr_slice = try mr.toOwnedSlice(1);
    errdefer gpa.free(stderr_slice);

    return .{ .term = term, .stdout = stdout_slice, .stderr = stderr_slice };
}

/// Foreground command in flight, for ESC to kill. Re-exported from `bgproc`
/// because that is where the pid lives (a `pid` and its process group are the same
/// subject) and this module is what spawns the command.
const setForeground = bgproc.setForeground;
const clearForeground = bgproc.clearForeground;

/// `bash` — foreground by default, background when asked.
///
/// The schema advertises `run_in_background`, and it is on the tool rather than as
/// a separate tool on purpose: the model decides *this command* is long, not that
/// it wants to be in a different mode. A `bash_background` tool would have to be
/// discovered and remembered, and would be wrong for the common mode.
///
/// ...and the harness overrides it for the commands it KNOWS are slow. See the
/// block below and `lib/verify.zig`.

/// Whether a known-slow verification is started in the background even when the
/// model asked for the foreground.
///
/// A module global, like the rest of the state this dispatcher needs before it
/// has a `Model` (`cancel_current` in `chat.zig` is the same shape), and set once
/// from the environment at startup: `ZODE_AUTO_BG=0` turns it off for someone who
/// would rather watch a build than have it disappear into a job.
pub var auto_background: bool = true;

pub fn setAutoBackground(v: bool) void {
    auto_background = v;
}

/// The rule that makes this foreground `bash` a background job anyway, or null
/// to run it in the foreground.
///
/// Split out of `toolBash` because that one needs an `Io` and a live registry and
/// this is the whole DECISION, which is what has to be tested.
pub fn autoBackgroundRule(obj: std.json.ObjectMap, command: []const u8) ?[]const u8 {
    if (getBool(obj, "run_in_background")) return null;
    if (!auto_background) return null;
    // An explicit `timeout_seconds` means the model decided what it wanted from
    // this command. Overriding that would be overriding a decision, not a
    // default.
    if (getInt(obj, "timeout_seconds") != null) return null;
    const v = verify_mod.classify(command);
    if (v.kind != .slow_verify) return null;
    return v.matched;
}
fn toolBash(
    io: std.Io,
    obj: std.json.ObjectMap,
    arena: std.mem.Allocator,
    reg: ?*bgproc.Registry,
) ![]const u8 {
    const command = getStr(obj, "command") orelse return error.MissingCommand;
    const timeout_s: u64 = if (getInt(obj, "timeout_seconds")) |t| (if (t > 0) @intCast(t) else 30) else 30;

    // THE HARNESS DECIDES, for the slow verifications.
    //
    // `run_in_background` already existed and the model already had to remember
    // to use it, which is the whole problem: a model that forgets to sets the
    // input on the floor for the length of a full build, once per edit. So a
    // command that `verify.classify` recognises as a slow verification goes to
    // the background EVEN IF the model asked for the foreground.
    //
    // Two escapes, both deliberate: an explicit `timeout_seconds` means the model
    // knows what it is doing (it set a number for this command), and
    // `ZODE_AUTO_BG=0` turns the whole thing off for someone who would rather
    // see it hang than have it disappear into a job.
    if (autoBackgroundRule(obj, command)) |rule| {
        {
            const r = reg orelse return error.NoBackgroundRegistry;
            const id = try bgproc.spawn(r, arena, io, command);
            return std.fmt.allocPrint(arena,
                \\started in the background as job {d}, because `{s}` is a slow verification
                \\
                \\The command is running NOW and you are not blocked. Do something else
                \\while it runs: read a file, grep the code you just changed, keep
                \\editing. Then call bash_output with id {d} for the result.
                \\
                \\One poll per step, never a polling loop.
                \\
            , .{ id, rule, id });
        }
    }

    if (getBool(obj, "run_in_background")) {
        const r = reg orelse return error.NoBackgroundRegistry;
        const id = try bgproc.spawn(r, arena, io, command);
        return std.fmt.allocPrint(arena,
            \\started in the background as job {d}
            \\
            \\It is running NOW and you are not blocked. Keep working: read a file,
            \\grep the error, ask the user something — anything. When you need the
            \\result, call bash_output with id {d}: it gives you the output that
            \\appeared since your last call plus whether it is still running.
            \\
            \\Do not poll in a loop. Do one poll per step.
            \\
        , .{ id, id });
    }

    const result = try runForeground(arena, io, command, timeout_s, max_tool_output);

    var out: std.ArrayList(u8) = .empty;
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal => |sig| blk: {
            out.print(arena, "(signal {d}) ", .{sig}) catch {};
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

// ── grep: native rg > native grep > internal fallback ────────
fn toolGrep(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const pattern = getStr(obj, "pattern") orelse return error.MissingPattern;
    const subdir = getStr(obj, "subdir") orelse ".";

    // 1) ripgrep (the best: fast, respects .gitignore)
    const rg_argv = [_][]const u8{ "rg", "--no-heading", "-n", "--max-count", "5", "--max-columns", "300", pattern, subdir };
    if (nativeGrep(arena, io, &rg_argv)) |out| return out;

    // 2) the system's grep -rn
    const grep_argv = [_][]const u8{ "grep", "-rn", "--include=*", "-m", "5", pattern, subdir };
    if (nativeGrep(arena, io, &grep_argv)) |out| return out;

    // 3) fallback: internal regex engine
    return fallbackGrep(io, pattern, subdir, arena);
}

/// Runs a native grep binary; null if the binary does not exist.
fn nativeGrep(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_tool_output),
        .stderr_limit = .limited(2048),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch return null;
    // rg exit 1 = no matches; exit 127/2 = bad binary/usage → try the next one
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return null,
    };
    if (code == 0 and result.stdout.len > 0) {
        // Truncate to ~80 lines to not burn tokens
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

/// Pure-Zig fallback for when there is neither rg nor grep (rare on dev boxes).
fn fallbackGrep(io: std.Io, pattern: []const u8, subdir: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const regex = @import("lib/regex.zig").Regex.compile(pattern);

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

// ── list_files: plain directory listing (cheap) ──────────────
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

// ── web: read the internet (no permissions: reads only) ──────

/// Hard cap on a web response. 200 KB of text is plenty to read a doc and
/// keeps an endless page (a listing of 50 000 links) from blowing up the turn's
/// context.
const web_hard_cap = 200 * 1024;

fn browserHeaders() [3]http.Http.ExtraHeader {
    return .{
        .{ .name = "user-agent", .value = web.user_agent },
        .{ .name = "accept", .value = "text/html,application/json,text/plain;q=0.9,*/*;q=0.8" },
        // CAREFUL: you cannot leave `accept-encoding` out and trust things. `std.http`
        // sets `accept_encoding = .omit` (meaning "don't send the header"), and without
        // it GitHub and friends reply gzip: the model eats 16 KB of unreadable bytes
        // and has no idea what the page says. We ask for `identity`
        // explicitly, which is the only way to say "uncompressed" with
        // std, which does not decompress transparently.
        .{ .name = "accept-encoding", .value = "identity" },
    };
}

/// Did the body come compressed? (zstd, gzip, brotli…)
///
/// Safety net for when a server ignores `accept-encoding: identity`:
/// a message saying "it came compressed" is infinitely better than 16 KB of
/// binary that the model reads as text.
fn looksCompressed(body: []const u8) ?[]const u8 {
    if (body.len < 2) return null;
    // gzip 1f 8b, zstd 28 b5 2f fd, brotli (no fixed magic: many sites serve it
    // without a recognizable header, and it is detected by invalid UTF-8 below).
    if (body[0] == 0x1f and body[1] == 0x8b) return "gzip";
    if (body[0] == 0x28 and body[1] == 0xb5 and body.len >= 4 and body[2] == 0x2f and body[3] == 0xfd) return "zstd";
    // Generic binary: many NULs or stray control bytes.
    var ctrl: usize = 0;
    const probe = body[0..@min(body.len, 512)];
    for (probe) |b| {
        if (b < 0x09 or (b > 0x0d and b < 0x20)) ctrl += 1;
    }
    if (probe.len > 32 and ctrl * 4 > probe.len) return "binary";
    return null;
}

/// `web_fetch`: GET a URL and return the content as readable text.
///
/// The body ALWAYS goes through `web.htmlToText` when it looks like HTML, because
/// spending context on 300 KB of tags is throwing it away. JSON or plain text
/// pass through untouched.
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
    // A compressed body is not text: saying so is infinitely better than
    // returning binary and letting the model read it as if it were words.
    if (looksCompressed(body)) |kind| {
        return std.fmt.allocPrint(arena, "{s} answered with {s}-encoded content that zode cannot decode. Try a different URL (a .json or .txt endpoint usually works).", .{ trimmed, kind });
    }
    // A 4xx/5xx is information too: return the status and whatever the
    // server said, which is where the real reason is ("Model access is disabled").
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

    // CAREFUL: the result is COPIED into memory owned by the arena. Returning a slice
    // of the HTTP buffer is a time bomb: the `defer freeBody` above
    // releases it when this function returns, and the ArenaAllocator REUSES
    // that memory in the next allocation (the one from `client.deinit`'s pool, the
    // buffer's own growth…). The caller read `0xAA` where the JSON
    // should have been. It goes through the truncation and the short path, and only with
    // an arena: that is why it never showed up in the network tests.
    var out: std.ArrayList(u8) = .empty;
    if (text.len <= max_bytes) {
        out.appendSlice(arena, text) catch return "out of memory building the answer";
    } else {
        // Cut at a line boundary: cutting in the middle of a word leaves
        // garbage that the model keeps thinking is the end of the
        // document.
        var cut = max_bytes;
        while (cut > 0 and text[cut] != '\n') cut -= 1;
        if (cut < max_bytes / 2) cut = max_bytes; // page with no line breaks: hard cut
        out.appendSlice(arena, text[0..cut]) catch return "out of memory building the answer";
        out.print(arena, "\n\n… (truncated at {d} of {d} bytes; ask for the rest with a deeper request)", .{ cut, text.len }) catch {};
    }
    return out.items;
}

/// `web_search`: DuckDuckGo results (`html/` endpoint, no API key).
///
/// It is a scrape, and it will break the day they change one of the HTML classes.
/// When that happens, the error says so (with the alternative) instead of returning an
/// empty list, which the model would interpret as "there are no results".
fn toolWebSearch(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const query = getStr(obj, "query") orelse
        return "error: web_search needs a `query`";
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return "error: empty query";

    var max_results: usize = 8;
    if (getInt(obj, "max_results")) |mr| {
        if (mr > 0) max_results = @min(@as(usize, @intCast(mr)), 20);
    }

    // DDG's `html/` endpoint is the one that asks for neither JS nor a key. The query goes
    // percent-encoded with `std.Uri`'s encoder (by hand people forget the `&` and
    // the `+`, and the search reaches the server in pieces).
    var url_buf: [1024]u8 = undefined;
    var uw: std.Io.Writer = .fixed(&url_buf);
    uw.writeAll("https://html.duckduckgo.com/html/?q=") catch return "error: query too long";
    // CAREFUL: `std.Uri.Writer` is NOT `pub` in 0.16, so the query component
    // encoder cannot be used from here. We percent-encode by
    // hand, which for a query is four characters.
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

    if (web.searchResults(arena, res.body, max_results).len > 0) {
        return web.searchResults(arena, res.body, max_results);
    }
    h.freeBody(res.body);

    // SECOND ENDPOINT, and this is the whole improvement: `html/` answering 200
    // with a layout we do not know used to be the end of the road, and the model
    // was told the engine had no results for a query it HAD answered. `lite/` is
    // a different page of the same engine with different classes (`lib/web.zig`
    // parses both), so a layout change on one is a retry, not a failure.
    var url2_buf: [1024]u8 = undefined;
    var lite_w: std.Io.Writer = .fixed(&url2_buf);
    lite_w.writeAll("https://lite.duckduckgo.com/lite/?q=") catch return searchFailed(arena, q);
    percentEncodeQuery(q, &lite_w) catch return searchFailed(arena, q);
    const url2 = lite_w.buffered();

    const res2 = h.getWithHeaders(url2, &browserHeaders()) catch |err| {
        return std.fmt.allocPrint(arena, "error searching \"{s}\": {t} (and the fallback endpoint could not be reached either)", .{ q, err });
    };
    defer h.freeBody(res2.body);
    if (res2.status < 200 or res2.status >= 300) return searchFailed(arena, q);

    if (web.liteSearchResults(arena, res2.body, max_results).len > 0) {
        return web.liteSearchResults(arena, res2.body, max_results);
    }
    return searchFailed(arena, q);
}

/// What the model is told when neither endpoint could be parsed.
///
/// It says what happened AND what to do, because "no results parsed" reads as
/// "nothing exists on the internet about this", and the model then tells the user
/// that.
fn searchFailed(arena: std.mem.Allocator, q: []const u8) []const u8 {
    return std.fmt.allocPrint(
        arena,
        "no results could be parsed for \"{s}\". Both search endpoints answered, and their HTML did not match what this build knows how to read. Do NOT read that as \"there is nothing about this\": rephrase the query, or fetch a URL you already know with web_fetch.",
        .{q},
    ) catch "the search could not be read; rephrase the query or fetch a URL you know";
}

/// Percent-encoding of a query string, by hand.
///
/// `std.Uri.Writer` (which does know how) is not `pub` in 0.16, and `std.Uri`
/// only exposes the encoder internally. There are four reserved characters and it is one
/// line; what matters is that `&` and `+` are accounted for: without them, "zod & mcp"
/// reaches the server as two different searches.
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

/// Is the body HTML?
///
/// It is deduced from the body and NOT from `content-type`: that header lives in
/// `receiveHead`'s redirect buffer, which dies when the request returns (see the note in
/// `http_client.JsonResult`). A server can also send `text/plain` with
/// HTML inside, or the other way round, so the header was not to be trusted either.
///
/// It looks at the start of the document for `<!doctype html`, `<html`, `<head` or
/// `<body`, which is where any template puts them, and rejects what starts
/// with `{` or `[` (JSON) or with `#!` (a gist's shebang).
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

// ── think: scratchpad with no side effects (planning) ────────
fn toolThink(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const thought = getStr(obj, "thought") orelse return error.MissingPath;
    return std.fmt.allocPrint(arena, "noted ({d} chars). Continue with your plan.", .{thought.len});
}

// ── todo: the plan the user sees on screen ─────────────────────
//
// It asks for NO permission. It touches neither disk nor network: it only stores
// a list in the session, which is exactly what `think` does, except that instead
// of telling the model it shows it to the user.

/// Applies the list and returns what has to be told to the model.
///
/// CAREFUL about memory ownership: what comes out of here goes into the
/// `tool_result` of the history (which is long-lived) and into the on-screen
/// plan. The text is a copy in `arena`, never a slice of `Item`'s fixed buffers,
/// because the next call overwrites those.
fn toolTodo(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    // `fromValue` and not `parseItems`: the JSON is already parsed (`execute`
    // does it for every tool), and re-parsing 4 KB to pull out 20 strings is
    // throwing work away.
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

// ── recursive walker skipping binary/vendored dirs ───────────
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

    /// Returns the path of the next file (caller frees with arena.free)
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
            // Next entry of the current dir
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
                // Dir exhausted
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

// ── recursive glob matcher ( *, **, ? ) ──────────────────────
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globHere(pattern, path);
}

fn globHere(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;

    // '**' = anything, including '/'
    if (p.len >= 2 and p[0] == '*' and p[1] == '*') {
        var rest = p[2..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        // ** consumes 0 chars:
        if (globHere(rest, s)) return true;
        // ** consumes 1 char and keeps going:
        if (s.len > 0) return globHere(p, s[1..]);
        return false;
    }

    // '*' = anything except '/'
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globHere(p[1..], s[i..])) return true;
            if (i < s.len and s[i] == '/') return false;
        }
        return false;
    }

    // '?' = one char (not '/')
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

test "list_files lists this src" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "list_files", "{\"path\":\"src\"}", arena_state.allocator(), null, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "f main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "f tools.zig") != null);
}

test "think returns OK with no effects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "think", "{\"thought\":\"plan: read file first\"}", arena_state.allocator(), null, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "noted") != null);
}

test "toolsJson is valid JSON and has one entry per tool" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), toolsJson(), .{}) catch {
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(v == .array);
    // The count comes from `defs`, not from a hand-written number: adding a tool
    // without declaring it in the JSON (or the other way round) fails here instead of leaving
    // the model with a tool that does not exist.
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

test "the web tools ask for no permissions (they are reads)" {
    // Asking for confirmation on every internet query turns the agent loop into
    // an interrogation. Same criterion as read/grep.
    try std.testing.expect(!needsPermission("web_fetch"));
    try std.testing.expect(!needsPermission("web_search"));
    try std.testing.expect(needsPermission("write"));
}

test "web_fetch and web_search appear in the JSON with their description" {
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "\"web_fetch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "\"web_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "html.duckduckgo.com") == null); // the endpoint lives in the code, not in the prompt
}

test "web_fetch rejects non-http(s) without touching the network" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_fetch", "{\"url\":\"file:///etc/passwd\"}", arena_state.allocator(), null, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "only http:// and https://") != null);
}

test "web_fetch without url says so" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_fetch", "{}", arena_state.allocator(), null, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "needs a `url`") != null);
}

test "web_search without query says so" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_search", "{}", arena_state.allocator(), null, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "needs a `query`") != null);
}

test "percentEncodeQuery escapes what breaks a URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try percentEncodeQuery("zod & mcp/nuevo+1", &w);
    try std.testing.expectEqualStrings("zod+%26+mcp%2Fnuevo%2B1", w.buffered());
}

// ── network tests (skipped without internet) ─────────────────
//
// These are the only ones that can catch the most expensive class of bug in this
// file: returning a VIEW of the HTTP buffer instead of a copy. With an
// arena, `freeBody` (which sits in a `defer`) releases the memory when the tool
// returns and the ArenaAllocator reuses it in the next allocation; the
// caller read `0xAA` where the JSON should have been. There is no way to reproduce it
// without the network, and without the network the bug sneaks in.

/// `true` if the error is a network error (and the test is skipped) instead of a real failure.
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

test "web_fetch for real: the HTML arrives as text, not as tags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "web_fetch", "{\"url\":\"https://example.com/\"}", arena_state.allocator(), null, null) catch |err| {
        if (isNetError(err)) return error.SkipZigTest;
        return err;
    };
    // CAREFUL: example.com changes its text every so often; the test checks the
    // SHAPE (no tags, sentences with spaces) and not the exact sentence. A
    // test that fails because a site changed its copy is worthless.
    try std.testing.expect(out.len > 40);
    // The readable text carries no tags: if the HTTP buffer had been
    // released, fill bytes (`0xAA`) would show up here instead of the sentence.
    try std.testing.expect(std.mem.indexOf(u8, out, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<div") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "documentation examples") != null);
}

test "web_search for real: returns results with a URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "web_search", "{\"query\":\"zig programming language\",\"max_results\":3}", arena_state.allocator(), null, null) catch |err| {
        if (isNetError(err)) return error.SkipZigTest;
        return err;
    };
    // If the scraper changes, this fails and warns: that is exactly what it is for.
    try std.testing.expect(std.mem.indexOf(u8, out, "1. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http") != null);
}

// ── integration tests with testing.io ──
test "the read tool reads this file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const args = "{\"path\":\"src/tools.zig\"}";
    const out = try execute(std.testing.io, "read", args, arena_state.allocator(), null, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "toolRead") != null);
}

test "glob finds the zigs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "glob", "{\"pattern\":\"src/*.zig\"}", arena_state.allocator(), null, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src/main.zig") != null);
}

test "native grep finds the pattern" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "grep", "{\"pattern\":\"toolGrep\",\"subdir\":\"src\"}", arena_state.allocator(), null, null) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest; // no rg/grep in PATH
        return err;
    };
    try std.testing.expect(std.mem.indexOf(u8, out, "toolGrep") != null);
}

test "write returns a PREVIEW of the file, not an opaque OK" {
    // A tool result that only says "ok" forces opening the file to find out
    // whether the model wrote what it was asked to write, and in an agentic loop
    // that is exactly the step that gets skipped.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"path\":\"/tmp/opencode/preview-test.txt\",\"content\":\"");
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "linea {d}\\n", .{i}));
    }
    try body.appendSlice(arena, "\"}");

    const out = try execute(std.testing.io, "write", body.items, arena, null, null);

    // The header says what and how much.
    try std.testing.expect(std.mem.indexOf(u8, out, "preview-test.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "30 lines") != null);
    // And the preview follows.
    try std.testing.expect(std.mem.indexOf(u8, out, "preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "linea 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "linea 11") != null);
    // But NOT the whole file: it is cut, and it says how many lines are missing.
    try std.testing.expect(std.mem.indexOf(u8, out, "linea 12\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "more lines") != null);
}

// ── the read cache, tested through the tool ──────────────────
//
// The cache lives in `readcache.zig` and the table is tested over there. These
// tests are of a different kind: they check that the TOOL answers short, that the
// text the model receives is the text it can use, and that `force` exists. A
// well-tested module that the tool does not wire the cache into saves not a
// single token.

fn writeTmp(arena: std.mem.Allocator, path: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"path":"{s}","content":"{s}"}}
    , .{ path, body });
}

test "read: the SECOND read of the same thing does not repeat the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache: readcache.Cache = .{};

    const path = "/tmp/opencode/readcache-test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "primera linea\nsegunda linea\ntercera linea\n",
    });

    var args = try writeTmp(arena, path, "");
    args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});

    const first = try execute(std.testing.io, "read", args, arena, null, &cache);
    // The first one sends the body: that is the one that puts it in the context.
    try std.testing.expect(std.mem.indexOf(u8, first, "primera linea") != null);
    try std.testing.expectEqual(@as(usize, 0), cache.stats.hits);

    const second = try execute(std.testing.io, "read", args, arena, null, &cache);
    // The second one does NOT: it says nothing changed and it is still up there.
    try std.testing.expect(std.mem.indexOf(u8, second, "unchanged") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "primera linea") == null);
    // And it says it in a USABLE way: where it is and how to ask for it again.
    try std.testing.expect(std.mem.indexOf(u8, second, path) != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "force") != null);
    // And those are four lines the model does not pay for twice.
    try std.testing.expect(second.len < 400);
    try std.testing.expectEqual(@as(usize, 1), cache.stats.hits);
    try std.testing.expect(cache.stats.saved > 0);
}

test "read: if the file changes, it is sent whole again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache: readcache.Cache = .{};

    const path = "/tmp/opencode/readcache-change-test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "version uno\n",
    });
    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});
    _ = try execute(std.testing.io, "read", args, arena, null, &cache);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "version dos, y es distinto\n",
    });
    const after = try execute(std.testing.io, "read", args, arena, null, &cache);
    try std.testing.expect(std.mem.indexOf(u8, after, "version dos") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "unchanged") == null);
}

test "read: the same content with another timestamp is NOT resent" {
    // A `touch` or a `git checkout` moves the mtime without touching the content.
    // If the body were re-sent here, the cache would only serve the easy case.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache: readcache.Cache = .{};

    const path = "/tmp/opencode/readcache-touch-test.txt";
    const body = "contenido estable\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = body });
    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});
    _ = try execute(std.testing.io, "read", args, arena, null, &cache);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = body });
    // With the new mtime the fast path no longer hits, so it reads and compares
    // the hash: and this is where the second turn is won.
    const again = try execute(std.testing.io, "read", args, arena, null, &cache);
    try std.testing.expect(std.mem.indexOf(u8, again, "unchanged") != null);
    try std.testing.expect(std.mem.indexOf(u8, again, "contenido estable") == null);
}

test "read: force:true returns it all even if nothing changed" {
    // The escape hatch. Without it, a false cache hit leaves the model with no
    // way to get the file, and it cannot argue its way out of a tool result.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache: readcache.Cache = .{};

    const path = "/tmp/opencode/readcache-force-test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "contenido que se quiere otra vez\n",
    });
    const plain = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});
    _ = try execute(std.testing.io, "read", plain, arena, null, &cache);

    const forced = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"force\":true}}", .{path});
    const out = try execute(std.testing.io, "read", forced, arena, null, &cache);
    try std.testing.expect(std.mem.indexOf(u8, out, "contenido que se quiere otra vez") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unchanged") == null);
}

test "read: a range that was never read IS sent" {
    // The cache is of RANGES, not of files: having read 1-100 says nothing about
    // 500-600, and sending "unchanged" there would be a lie.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache: readcache.Cache = .{};

    const path = "/tmp/opencode/readcache-range-test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "uno\ndos\ntres\n" });
    const first = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"limit\":1}}", .{path});
    _ = try execute(std.testing.io, "read", first, arena, null, &cache);

    const wide = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});
    const out = try execute(std.testing.io, "read", wide, arena, null, &cache);
    try std.testing.expect(std.mem.indexOf(u8, out, "tres") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unchanged") == null);
}

test "read: invalidate sends the new content even if the stat did not move" {
    // What `write`/`edit` do behind the scenes: without this, editing a file
    // and reading it back would give the old text behind an "unchanged".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache: readcache.Cache = .{};

    const path = "/tmp/opencode/readcache-invalidate-test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "antes de editar\n" });
    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});
    _ = try execute(std.testing.io, "read", args, arena, null, &cache);

    cache.invalidate(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "despues de editar\n" });
    const out = try execute(std.testing.io, "read", args, arena, null, &cache);
    try std.testing.expect(std.mem.indexOf(u8, out, "despues de editar") != null);
}

test "read: markDroppedAt undoes the cache when compaction takes the result away" {
    // The end of the story: compaction can remove a `read` result from the wire.
    // If the cache did not find out, the model would get "unchanged, you already
    // have it" about content it no longer has.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache: readcache.Cache = .{};

    const path = "/tmp/opencode/readcache-dropped-test.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "contenido que se perdio\n" });
    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});
    _ = try execute(std.testing.io, "read", args, arena, null, &cache);
    cache.setMessageIndex(path, 9);
    try std.testing.expectEqual(@as(usize, 1), cache.liveEntries());

    // Compaction takes message 9 away.
    cache.markDroppedAt(9);
    const out = try execute(std.testing.io, "read", args, arena, null, &cache);
    try std.testing.expect(std.mem.indexOf(u8, out, "contenido que se perdio") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unchanged") == null);
}

// ── the slow-verification rule ─────────────────────────────────

/// A JSON object for the tool arguments, with everything freed.
///
/// `parseFromSliceLeaky` needs an arena and the map has to outlive it, so the two
/// go together in a struct instead of being two things a test has to remember.
const Args = struct {
    state: std.heap.ArenaAllocator,
    obj: std.json.ObjectMap,

    fn parse(json: []const u8) !Args {
        var self: Args = .{ .state = std.heap.ArenaAllocator.init(std.testing.allocator), .obj = .{} };
        errdefer self.state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.state.allocator(), json, .{});
        self.obj = parsed.object;
        return self;
    }

    fn deinit(self: *Args) void {
        self.state.deinit();
    }
};

test "bash: a full build is started in the background even in the foreground" {
    // The complaint this answers: a harness that blocks on the whole suite after
    // every edit. `run_in_background` existed, but the model has to REMEMBER to
    // use it, and a model that forgets costs the user the length of a build.
    defer setAutoBackground(true);

    var args = try Args.parse("{\"command\":\"zig build test\"}");
    defer args.deinit();
    try std.testing.expectEqualStrings("zig build", autoBackgroundRule(args.obj, "zig build test").?);

    // Quick and unknown commands stay in the foreground.
    var quick = try Args.parse("{\"command\":\"ls\"}");
    defer quick.deinit();
    try std.testing.expect(autoBackgroundRule(quick.obj, "ls") == null);
    var commit = try Args.parse("{\"command\":\"git commit -m x\"}");
    defer commit.deinit();
    try std.testing.expect(autoBackgroundRule(commit.obj, "git commit -m x") == null);
}

test "bash: asking for the background explicitly is not 'auto', and a timeout is an override" {
    defer setAutoBackground(true);

    // Already backgrounded: nothing to decide.
    var bg = try Args.parse("{\"command\":\"zig build\",\"run_in_background\":true}");
    defer bg.deinit();
    try std.testing.expect(autoBackgroundRule(bg.obj, "zig build") == null);

    // An explicit timeout means the model knows what it is doing.
    var t = try Args.parse("{\"command\":\"zig build\",\"timeout_seconds\":600}");
    defer t.deinit();
    try std.testing.expect(autoBackgroundRule(t.obj, "zig build") == null);
}

test "bash: ZODE_AUTO_BG=0 turns the automatic backgrounding off" {
    setAutoBackground(false);
    defer setAutoBackground(true);

    var args = try Args.parse("{\"command\":\"zig build test\"}");
    defer args.deinit();
    try std.testing.expect(autoBackgroundRule(args.obj, "zig build test") == null);
}

// ── what the model is told when a tool fails ─────────────────────

/// The text a failed tool call sends BACK to the model.
///
/// It used to be the Zig error name (`allocPrint("{t}", .{err})`), so the model
/// received the literal string `"BadArgs"` or `"UnknownTool"` with nothing else.
/// A model cannot recover from that: it does not know which argument was wrong,
/// whether the tool exists, or what the schema wants. The cost is a whole extra
/// round trip to find out something the harness already knew.
///
/// Every message here says what happened AND what to do about it, and none of them
/// asks the model to guess.
pub fn describeError(arena: std.mem.Allocator, err: anyerror, name: []const u8, args_json: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "bash")) {
        return switch (err) {
            error.Cancelled => "the command was interrupted (ESC) before it finished; nothing ran to the end.",
            error.NoBackgroundRegistry => "run_in_background was asked for but there is no background registry in this mode. Run it in the foreground, or split it into steps.",
            error.MissingCommand => "the bash call needs a \"command\" argument with the command line to run.",
            error.FileNotFound => "the command was not found by the shell (exit 127 usually). Use a path that exists, or a binary that is installed.",
            error.StreamTooLong => "the output was longer than the cap, so the read stopped. Re-run it with something narrower: a pipe through head, or a smaller scope.",
            else => "the command failed. Its exit status and output are above; fix the cause instead of retrying the same line.",
        };
    }
    if (err == error.UnknownTool) {
        return std.fmt.allocPrint(
            arena,
            "there is no tool called \"{s}\". The tools you have are: read, write, edit, bash, glob, grep, list_files, web_fetch, web_search, think, todo, ask, skill, task, bash_output, bash_kill. Use one of those names exactly.",
            .{name},
        ) catch "there is no tool with that name.";
    }
    if (err == error.BadArgs or err == error.BadJson) {
        return std.fmt.allocPrint(
            arena,
            "the arguments of `{s}` were not a JSON object, so nothing ran. What arrived was: {s}. Send a JSON object with the arguments the schema lists.",
            .{ name, clipForError(arena, args_json) },
        ) catch "the arguments were not valid JSON.";
    }
    if (err == error.MissingPath or err == error.MissingCommand or err == error.MissingQuery or err == error.MissingUrl) {
        return std.fmt.allocPrint(
            arena,
            "`{s}` needs its required argument and it was not there. Check the schema: the first property of `parameters.required` is the one that was missing.",
            .{name},
        ) catch "the tool call was missing a required argument.";
    }
    return switch (err) {
        error.FileNotFound => "the path does not exist. Check it with glob or list_files; a path that is not there cannot be read.",
        error.AccessDenied => "the file is there but not readable by this process.",
        error.IsDir => "that path is a directory. Use list_files on it, or a file inside it.",
        error.NotDir => "a path component of that is not a directory.",
        error.Cancelled => "the turn was interrupted (ESC). Nothing finished.",
        error.StreamTooLong => "the result was longer than the cap. Narrow the request: fewer matches, a smaller range, or a more specific pattern.",
        error.TooManyHunks => "too many hunks in one edit. Split it into two edits.",
        error.TooManyOptions => "too many options in that call. Fewer, and put the recommendation first.",
        error.EmptyOption => "one of the options was an empty string.",
        error.BadQuestion => "the question was empty. Ask something with content in it.",
        error.OutOfMemory => "there was not enough memory to answer that. Ask for less at once.",
        else => "the call failed with an internal error. Do not retry it unchanged: simplify what you asked for.",
    };
}

/// A short, safe excerpt of what the model actually sent.
fn clipForError(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const n = @min(s.len, 200);
    const out = arena.alloc(u8, n) catch return "(could not be shown)";
    @memcpy(out, s[0..n]);
    if (s.len > n) @memcpy(out[n - 3 ..], "...");
    return out;
}

test "describeError: no message is a bare Zig error name" {
    // The bug: `allocPrint("{t}", .{err})` sent the model the string "BadArgs".
    // It cannot act on that, so the fix is a whole extra round trip to learn
    // something the harness already knew.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cases = [_]struct { err: anyerror, name: []const u8, must: []const u8 }{
        .{ .err = error.UnknownTool, .name = "serch", .must = "there is no tool called" },
        .{ .err = error.BadArgs, .name = "read", .must = "not a JSON object" },
        .{ .err = error.MissingPath, .name = "read", .must = "required argument" },
        .{ .err = error.FileNotFound, .name = "read", .must = "glob or list_files" },
        .{ .err = error.StreamTooLong, .name = "grep", .must = "Narrow the request" },
    };
    for (cases) |c| {
        const msg = describeError(a, c.err, c.name, "{\"path\":\"x\"}");
        try std.testing.expect(std.mem.indexOf(u8, msg, c.must) != null);
        // And it is never the identifier.
        try std.testing.expect(std.mem.indexOf(u8, msg, @errorName(c.err)) == null);
        // And it is never empty.
        try std.testing.expect(msg.len > 20);
    }
}

test "describeError: the unknown tool lists the tools that DO exist" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const msg = describeError(arena_state.allocator(), error.UnknownTool, "serch", "{}");
    // The single most useful thing in that message: the name was wrong, and here
    // is the vocabulary.
    for ([_][]const u8{ "grep", "read", "task", "web_search" }) |t| {
        try std.testing.expect(std.mem.indexOf(u8, msg, t) != null);
    }
}

test "describeError: the bad-arguments message shows what actually arrived" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const msg = describeError(arena_state.allocator(), error.BadArgs, "read", "path=src/main.zig");
    try std.testing.expect(std.mem.indexOf(u8, msg, "path=src/main.zig") != null);
}
