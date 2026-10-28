//! Subagents: the `task` tool.
//!
//! A subagent is a second agent loop with its OWN context window, a restricted
//! tool set, and a single job: go find this out and tell me a few lines.
//!
//! Why this is the second-biggest hole after `ask`, and why it is a TOKEN fix
//! rather than a feature: everything the main agent reads goes into the main
//! agent's context, and that context is resent on EVERY iteration and billed
//! every time. A `grep -r` that returns 40 KB of matches is 10k tokens in the
//! prompt of iteration 2, 3, 4... and the useful part of it was the two lines
//! that said which function to look at. The subagent pays those 10k tokens ONCE,
//! in a window that is thrown away, and gives the main loop back a paragraph.
//!
//! Design decisions that are not obvious:
//!
//! - **Depth 1.** No nesting. A subagent that could spawn subagents is a way to
//!   spend a hundred times the tokens by accident, and it cannot be budgeted.
//! - **Effort `low` always.** The subagent is doing a bounded search, not
//!   designing. `low` is where the money is saved and where quality is not
//!   lost, because there is no user to impress.
//! - **The subagent does NOT see the conversation.** Only the task prompt, plus
//!   the tool definitions. If it inherited the history it would inherit the
//!   tokens, which is the whole thing we are avoiding.
//! - **Its own tool list, without `ask`.** A subagent that asks the user a
//!   question would need the dialog from a thread that is not the turn's, and
//!   the user cannot tell which of two agents asked. It returns "I need X" as
//!   text and the MAIN agent decides whether to ask.
//!
//! The pure parts (tool list, budget accounting, summary validation) live here
//! and are tested without a network. The loop itself is in `agent.zig`, which
//! owns the HTTP plumbing.

const std = @import("std");

const subagent = @This();

/// Tools a subagent may use. Everything here is a READ.
///
/// Not `write`/`edit`/`bash`: a subagent that changes files cannot be reasoned
/// about from the outside (you cannot see what it did until it reports, and it
/// reports in prose), and its whole value is that it is safe to run without
/// asking you. A subagent that could `rm` something would need the permission
/// dialog, from a thread that is not the turn's.
pub const tool_names = [_][]const u8{
    "read",
    "grep",
    "glob",
    "list_files",
    "web_fetch",
    "web_search",
    "lsp",
};

/// `ask` is deliberately absent (see the header): a subagent that asked from a
/// thread that is not the turn's would leave the user not knowing which of two
/// agents is talking to them.
pub fn allowsTool(name: []const u8) bool {
    for (tool_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Validates a forked skill's declared `allowed_tools` JSON array: every named
/// tool must be in the subagent's read-only set (`tool_names`). A skill cannot
/// escalate beyond read-only tools.
///
/// Returns the validated tool names (slices into `allowed_json`, which the
/// caller must keep alive for the duration of the run) or an error. An empty
/// array is valid and means "use the default read-only set" — but that case is
/// handled by the caller before calling this.
pub fn skillAllowedTools(arena: std.mem.Allocator, allowed_json: []const u8) !std.ArrayList([]const u8) {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, allowed_json, .{}) catch return error.InvalidAllowedTools;
    if (root != .array) return error.InvalidAllowedTools;
    var out: std.ArrayList([]const u8) = .empty;
    for (root.array.items) |v| {
        if (v != .string) return error.InvalidAllowedTools;
        const name = v.string;
        var ok = false;
        for (tool_names) |tn| {
            if (std.mem.eql(u8, tn, name)) { ok = true; break; }
        }
        if (!ok) return error.ToolNotReadOnly;
        try out.append(arena, name);
    }
    return out;
}

/// Iterations a subagent gets. Lower than the main loop on purpose: a search
/// that needs 10 steps is a search that should have been two greps.
pub const max_iterations = 8;

/// Context budget for the subagent, in tokens. It has to be SMALL: the point is
/// that it gets thrown away, and a subagent allowed 100k will fill it with grep
/// output and then summarise badly.
///
/// A constant and not `ZODE_CONTEXT_LIMIT`-derived on purpose. The main loop's
/// budget is the user's model window; this one is a THROWAWAY window whose only
/// job is to hold a search. Deriving it from the user's limit would make it 100k+
/// for someone with a big window, and the subagent would then hold 40 KB of grep
/// output and summarise it worse than with 8 KB.
pub const budget_tokens = 24_000;

/// Per-tool-result cap inside the subagent. Tighter than the main one because a
/// 16 KB grep result in a 24k budget is two thirds of the window in one call.
pub const max_tool_output = 4 * 1024;

/// A longer answer than this is cut with a notice: the main agent asked for a
/// report, not for the file.
pub const max_report = 8 * 1024;

/// What a capped result says at the cut. Without it the model cannot tell
/// "that was everything" from "that was the first 4 KB", and it reads a fragment
/// as the whole answer — the exact failure this replaces.
pub const cut_notice =
    "\n… (the tool's output was cut at the subagent's 4 KB budget; ask for a narrower result to get the rest)\n";

/// Caps a tool result for the subagent's window.
///
/// The old code was `res_text[0..max_tool_output]`, and three things were wrong
/// with it in one line:
///
/// 1. **It cut mid-line**, so a fragment looked exactly like a complete answer.
///    Every other cut in this repo reserves room for a notice (`bgproc`,
///    `git diff`, `bash`), because a silent cut is the failure it exists for.
/// 2. **It could cut mid-UTF-8**: byte `N` of a multi-byte grapheme is a
///    continuation byte, and the message then carries invalid UTF-8 into the
///    wire format.
/// 3. **It ate the tail of every "continue with X" note**, `web_fetch`'s
///    `pass offset=N` among them. The fix for that one is in `web.excerpt`
///    (the instruction now also rides at the TOP of the window, which is what
///    every cap preserves); the fix for the first two is here.
///
/// Text under the cap comes back as the SAME slice: no copy, no allocation, and
/// the common case pays nothing.
pub fn capResult(arena: std.mem.Allocator, text: []const u8) []const u8 {
    if (text.len <= max_tool_output) return text;
    // The notice is inside the budget, not on top of it: the cap is the cap.
    const room: usize = if (cut_notice.len < max_tool_output)
        max_tool_output - cut_notice.len
    else
        0;
    var cut = room;
    // A line boundary, so the fragment ends where a line ended. Kept only if it
    // leaves a worthwhile amount — a 100 KB single-line JSON would otherwise be
    // cut at byte 0.
    if (std.mem.lastIndexOfScalar(u8, text[0..room], '\n')) |nl| {
        if (nl + 1 >= room / 2) cut = nl + 1;
    }
    // And a UTF-8 boundary: if the byte we stopped on is a continuation byte we
    // are in the middle of a character, so walk back until it is not.
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ text[0..cut], cut_notice }) catch text[0..cut];
}

/// The tool definitions sent to the subagent, built from the main list.
///
/// Built from `tools.toolsJson()` by filtering on the name, rather than kept as a
/// second hand-written copy of the schemas: a second copy is a second thing to
/// update, and the day someone changes `read`'s schema the subagent keeps sending
/// the old one and the model calls it wrong.
pub const Json = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Json) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Extracts the subagent's tool array out of the full `toolsJson()`.
///
/// The input is a JSON array of function objects. This walks it and keeps the
/// objects whose `"name"` is in `tool_names`. It is a small scanner instead of a
/// real parser because the input is OUR OWN string, and a parse+reserialize per
/// subagent would be 4 KB of garbage for nothing.
pub fn filterTools(all: []const u8, out: *Json) []const u8 {
    var w: std.Io.Writer = .fixed(&out.buf);
    w.writeByte('[') catch return "";
    var i: usize = 0;
    var kept: usize = 0;
    // One pass over the top-level array elements: a `{` at depth 0 that follows
    // a `,` starts an object; its matching `}` (tracking strings and escapes) ends
    // it. Inside that span we look for `"name":"X"` and keep the span if X is one
    // of ours.
    while (i < all.len) {
        if (all[i] != '{') {
            i += 1;
            continue;
        }
        // An object that never closes means the input was truncated. `break` and
        // not `return ""`: whatever was already kept is still valid JSON once
        // closed, and returning an empty array would silently turn a parsing
        // problem into "the subagent has no tools", which the model answers by
        // making things up.
        const end = matchObject(all, i) orelse break;
        const name = nameOf(all[i..end]) orelse {
            i = end;
            continue;
        };
        if (allowsTool(name)) {
            if (kept > 0) w.writeByte(',') catch {};
            w.writeAll(all[i..end]) catch {};
            kept += 1;
        }
        i = end;
    }
    w.writeByte(']') catch {};
    out.len = w.buffered().len;
    return out.slice();
}

/// Index of the `}` that closes the object starting at `start`, respecting
/// strings and escapes. `null` if it never closes (malformed input).
fn matchObject(s: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

/// The `"name":"..."` value inside one function object's span.
fn nameOf(span: []const u8) ?[]const u8 {
    const key = "\"name\"";
    const at = std.mem.indexOf(u8, span, key) orelse return null;
    var i = at + key.len;
    while (i < span.len and (span[i] == ' ' or span[i] == ':')) i += 1;
    if (i >= span.len or span[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfScalarPos(u8, span, i, '"') orelse return null;
    return span[i..end];
}

/// The system prompt of a subagent.
///
/// Short ON PURPOSE. Every token here is paid on every one of the subagent's
/// iterations, and the main agent's task prompt already says what to do; what
/// the subagent needs from the system prompt is only the parts of the contract
/// that are NOT in the task: what it may use, what to return, and that returning
/// "I could not find it" is a valid and useful answer.
pub const system_prompt =
    \\You are a subagent of a coding agent. You have ONE job and you finish it
    \\by answering, not by asking.
    \\
    \\- Your tools are read-only. You cannot change anything and you should not
    \\  try to: if the task needs a change, say what the change should be.
    \\- Search before you conclude. Prefer grep/glob to reading whole files, and
    \\  read only the lines that matter.
    \\- You CANNOT ask the user anything. If you need something only they can
    \\  decide, say so plainly in your report and the agent that sent you will
    \\  ask them.
    \\- Your final message IS the deliverable: a short report of what you found,
    \\  with the file paths and line numbers that back it up. Quote the two or
    \\  three lines that matter, not the whole function.
    \\- "I did not find it", with what you searched, is a complete and useful
    \\  answer. Guessing is not: a wrong path costs the caller another round trip.
;

/// The task for `task`, and the reason it is bounded.
pub const Task = struct {
    /// What to find out, in the caller's words.
    description: []const u8,
    /// Longer instructions, if the caller has any.
    prompt: []const u8 = "",
    /// A forked skill's declared `allowed_tools` (JSON array). Each named tool
    /// must be read-only: a skill cannot escalate beyond the subagent's
    /// read-only set. Empty = the default read-only set.
    allowed_tools: []const u8 = "",
    /// The skill's declared model, or empty to use the default subagent target.
    model: []const u8 = "",
    /// The skill's declared effort, or empty to use `low`.
    effort: []const u8 = "",
    /// Name of an agent definition from `.zode/agents/` or
    /// `~/.config/zode/agents/`. When set, the definition's tools/model/effort
    /// override the defaults (the definition's tools must still be read-only).
    definition: []const u8 = "",
};

pub const ParseError = error{
    OutOfMemory,
    BadDescription,
    /// The skill's `allowed_tools` was not a JSON array of strings.
    InvalidAllowedTools,
    /// The skill's `allowed_tools` named a tool outside the read-only set: a
    /// skill cannot escalate.
    ToolNotReadOnly,
};

/// Reads the `task` arguments.
pub fn parseTask(arena: std.mem.Allocator, args_json: []const u8) ParseError!Task {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch
        return error.BadDescription;
    if (root != .object) return error.BadDescription;
    const obj = root.object;

    var description: []const u8 = "";
    if (obj.get("description")) |v| {
        if (v == .string) description = std.mem.trim(u8, v.string, " \t\r\n");
    }
    if (description.len == 0) return error.BadDescription;

    var prompt: []const u8 = "";
    if (obj.get("prompt")) |v| {
        if (v == .string) prompt = std.mem.trim(u8, v.string, " \t\r\n");
    }

    var definition: []const u8 = "";
    if (obj.get("definition")) |v| {
        if (v == .string) definition = std.mem.trim(u8, v.string, " \t\r\n");
    }

    return .{ .description = description, .prompt = prompt, .definition = definition };
}

/// What the subagent's final message becomes, for the main agent.
///
/// The wrapper is what makes the main agent's next decision better: the subagent
/// is saying "this is a summary, trust it as such, do not go and re-read the
/// files". Without it the main agent tends to verify, which doubles the cost of
/// having used a subagent at all.
pub const Report = struct {
    // head (~117) + note (~400) + body (`max_report`) + truncation notice (~86):
    // the sizes are added up here because the writer is FIXED and a fixed writer
    // that runs out of room silently drops the END of the report. Feeling out the
    // slack instead of computing it is how the note would have started eating
    // report content.
    buf: [max_report + 640]u8 = undefined,
    len: usize = 0,
    /// Why this subagent ran differently from what was configured (or on what it
    /// is running, when everything is as configured). Own copy: callers build it
    /// on a stack buffer, which is dead by the time the report is read.
    note_buf: [400]u8 = undefined,
    note_len: usize = 0,

    pub fn slice(self: *const Report) []const u8 {
        return self.buf[0..self.len];
    }

    /// The note, rendered IN FRONT of whatever this report ends up being — the
    /// report or the refusal, because a pick that did not work is exactly as
    /// important when the subagent could not run at all.
    ///
    /// It copies, and that is the whole point of the field: the note is composed
    /// where the reason is known (a stack buffer inside the call) and read where
    /// the report is consumed, later.
    pub fn setNote(self: *Report, text: []const u8) void {
        const n = @min(text.len, self.note_buf.len);
        @memcpy(self.note_buf[0..n], text[0..n]);
        self.note_len = n;
    }

    pub fn note(self: *const Report) []const u8 {
        return self.note_buf[0..self.note_len];
    }
};

/// Wraps the subagent's report for the main agent.
pub fn formatReport(text: []const u8, out: *Report) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const notice = "\n… (subagent report truncated; ask it again with a narrower task if you need the rest)";
    const head = "Subagent report (its own context, now discarded — take this as the answer, do not re-read the files to verify it):\n";
    const room = max_report;
    var w: std.Io.Writer = .fixed(&out.buf);
    w.writeAll(head) catch {};
    if (out.note().len > 0) {
        w.writeAll(out.note()) catch {};
        w.writeByte('\n') catch {};
    }
    if (trimmed.len <= room) {
        w.writeAll(trimmed) catch {};
    } else {
        w.writeAll(trimmed[0..room]) catch {};
        w.writeAll(notice) catch {};
    }
    out.len = w.buffered().len;
    return out.slice();
}

/// The refusal when a subagent cannot run (no key, provider down, budget spent).
/// Said as a tool RESULT so the turn continues: a failed search is information.
///
/// The note goes in front here too: when the configured model was the reason it
/// could not run, that is the first thing the reader needs.
pub fn refused(reason: []const u8, out: *Report) []const u8 {
    var w: std.Io.Writer = .fixed(&out.buf);
    if (out.note().len > 0) {
        w.writeAll(out.note()) catch {};
        w.writeByte('\n') catch {};
    }
    w.print("The subagent could not run ({s}). Answer from what you already know, or do the search yourself with the tools you have.\n", .{reason}) catch {};
    out.len = w.buffered().len;
    return out.slice();
}

/// Running out of iterations is a NORMAL ending for a subagent, not an error.
///
/// The report it managed to write is usually good enough, and the alternative —
/// treating it as a failure — would make the main agent throw away a working
/// answer because the search did not finish.
pub fn iterationLimitText(out: *Report) []const u8 {
    var w: std.Io.Writer = .fixed(&out.buf);
    w.writeAll("(the subagent ran out of steps; the report above is what it found before that)\n") catch {};
    out.len = w.buffered().len;
    return out.slice();
}

test "allowsTool: read-only only, and `ask` left out on purpose" {
    try std.testing.expect(allowsTool("read"));
    try std.testing.expect(allowsTool("grep"));
    try std.testing.expect(!allowsTool("write"));
    try std.testing.expect(!allowsTool("edit"));
    try std.testing.expect(!allowsTool("bash"));
    // `ask` is the reason this list exists: a subagent that asks from a thread
    // that is not the turn's leaves the user not knowing who is asking.
    try std.testing.expect(!allowsTool("ask"));
}

test "skillAllowedTools: a read-only list passes through" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const allowed = try skillAllowedTools(a, "[\"read\", \"grep\", \"glob\"]");
    try std.testing.expectEqual(@as(usize, 3), allowed.items.len);
    try std.testing.expectEqualStrings("read", allowed.items[0]);
    try std.testing.expectEqualStrings("grep", allowed.items[1]);
    try std.testing.expectEqualStrings("glob", allowed.items[2]);
}

test "skillAllowedTools: an empty list is valid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const allowed = try skillAllowedTools(a, "[]");
    try std.testing.expectEqual(@as(usize, 0), allowed.items.len);
}

test "skillAllowedTools: a non-read-only tool refuses the run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `write` is not in the subagent's read-only set: the skill cannot escalate.
    const err = skillAllowedTools(a, "[\"read\", \"write\"]") catch |err| err;
    try std.testing.expectEqual(subagent.ParseError.ToolNotReadOnly, err);
}

test "skillAllowedTools: a non-array is invalid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const err = skillAllowedTools(a, "\"read\"") catch |err| err;
    try std.testing.expectEqual(subagent.ParseError.InvalidAllowedTools, err);
}

test "skillAllowedTools: malformed JSON is invalid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const err = skillAllowedTools(a, "[\"read\",") catch |err| err;
    try std.testing.expectEqual(subagent.ParseError.InvalidAllowedTools, err);
}

test "filterTools: keeps the read ones and drops the rest" {
    const all =
        \\[
        \\{"type":"function","function":{"name":"read","parameters":{}}},
        \\{"type":"function","function":{"name":"write","parameters":{}}},
        \\{"type":"function","function":{"name":"grep","parameters":{}}},
        \\{"type":"function","function":{"name":"bash","parameters":{}}},
        \\{"type":"function","function":{"name":"ask","parameters":{}}}
        \\
    ;
    var out = Json{};
    const kept = subagent.filterTools(all, &out);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"grep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"write\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"bash\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"ask\"") == null);
    try std.testing.expectEqualStrings("[", kept[0..1]);
    try std.testing.expectEqualStrings("]", kept[kept.len - 1 ..]);
}

test "filterTools: respects the braces INSIDE the parameters" {
    // A `}` from a badly closed `properties`, or a brace inside a schema, would
    // make the scanner cut the object in half and hand invalid JSON to the
    // model.
    const all =
        \\[{"type":"function","function":{"name":"read","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}},
        \\{"type":"function","function":{"name":"write","parameters":{}}}]
    ;
    var out = Json{};
    const kept = subagent.filterTools(all, &out);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"properties\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"write\"") == null);
    // And what comes out must still be parseable JSON.
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, kept, .{});
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 1), v.value.array.items.len);
}

test "filterTools: malformed input does not break it, it returns empty" {
    var out = Json{};
    const kept = subagent.filterTools("[{\"name\":\"read\"", &out);
    try std.testing.expectEqualStrings("[]", kept);
    const empty = subagent.filterTools("nonsense", &out);
    try std.testing.expectEqualStrings("[]", empty);
}

test "parseTask: description is required, prompt is optional" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const a = ast.allocator();
    const t = try subagent.parseTask(a, "{\"description\":\" donde vive el parser \",\"prompt\":\"busca en src/\"}");
    try std.testing.expectEqualStrings("donde vive el parser", t.description);
    try std.testing.expectEqualStrings("busca en src/", t.prompt);

    const t2 = try subagent.parseTask(a, "{\"description\":\"x\"}");
    try std.testing.expectEqualStrings("", t2.prompt);
}

test "parseTask: without description it is BadDescription" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const a = ast.allocator();
    try std.testing.expectError(error.BadDescription, subagent.parseTask(a, "{}"));
    try std.testing.expectError(error.BadDescription, subagent.parseTask(a, "{\"description\":\"  \"}"));
    try std.testing.expectError(error.BadDescription, subagent.parseTask(a, "[]"));
    try std.testing.expectError(error.BadDescription, subagent.parseTask(a, "no json"));
}

test "formatReport: the wrapper says there is no need to re-verify" {
    var out = Report{};
    const r = subagent.formatReport("esta en src/tui.zig:1234", &out);
    try std.testing.expect(std.mem.indexOf(u8, r, "src/tui.zig:1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "do not re-read") != null);
}

test "formatReport: a huge report is truncated AND it warns" {
    var big: [40_000]u8 = @splat('r');
    var out = Report{};
    const r = subagent.formatReport(&big, &out);
    try std.testing.expect(r.len <= out.buf.len);
    try std.testing.expect(std.mem.indexOf(u8, r, "truncated") != null);
}

test "formatReport: a short report does NOT carry the truncation notice" {
    var out = Report{};
    const r = subagent.formatReport("corto", &out);
    try std.testing.expect(std.mem.indexOf(u8, r, "truncated") == null);
}

test "the note rides in front of the report, and in front of the refusal too" {
    // The note is why the subagent ran on a different model than the developer
    // configured. It is the first thing the reader needs, and a refusal is
    // exactly when it matters most: "could not run" without "your pick is why"
    // sends the developer debugging the wrong thing.
    var out = Report{};
    out.setNote("[subagent note: this search runs on x/y (config.json).]");
    // The body must NOT be a phrase that also appears in the head ("take this
    // as the answer") or the index finds it before the note and the assertion
    // proves nothing about the order.
    const r = subagent.formatReport("the bug is at src/x.zig:42", &out);
    const note_at = std.mem.indexOf(u8, r, "[subagent note:").?;
    const ans_at = std.mem.indexOf(u8, r, "src/x.zig:42").?;
    try std.testing.expect(note_at < ans_at);

    var out2 = Report{};
    out2.setNote("[subagent note: this search runs on x/y (config.json).]");
    const r2 = subagent.refused("no key", &out2);
    const note_at2 = std.mem.indexOf(u8, r2, "[subagent note:") orelse
        return error.TestUnexpectedResult;
    const could_at = std.mem.indexOf(u8, r2, "could not run").?;
    try std.testing.expect(note_at2 < could_at);

    // And with no note nothing changes: the note costs nothing when there is
    // nothing to say.
    var out3 = Report{};
    const r3 = subagent.formatReport("plain", &out3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "[subagent note:") == null);
}

test "setNote copies: the caller's stack buffer is dead before the report is read" {
    var out = Report{};
    {
        const note_text = "[subagent note: built on the stack]";
        var stack: [note_text.len]u8 = undefined;
        @memcpy(&stack, note_text);
        out.setNote(&stack);
    }
    try std.testing.expectEqualStrings("[subagent note: built on the stack]", out.note());
    // An over-long note is cut, not rejected: a note that fails to store is a
    // silent note, and the report must still render.
    var out2 = Report{};
    var too_long: [1000]u8 = @splat('x');
    out2.setNote(&too_long);
    try std.testing.expectEqual(out2.note_buf.len, out2.note().len);
}

test "refused and iterationLimit are text, not errors" {
    var out = Report{};
    const r = subagent.refused("no key", &out);
    try std.testing.expect(std.mem.indexOf(u8, r, "no key") != null);
    // It says the other one can do it: a subagent that fails cannot leave the
    // turn without an exit.
    try std.testing.expect(std.mem.indexOf(u8, r, "yourself") != null);

    var o2 = Report{};
    const l = subagent.iterationLimitText(&o2);
    try std.testing.expect(std.mem.indexOf(u8, l, "report above") != null);
}

test "the system prompt explicitly says it cannot ask" {
    try std.testing.expect(std.mem.indexOf(u8, subagent.system_prompt, "CANNOT ask the user") != null);
    // And that "I did not find it" is a good answer: without this the subagent
    // invents a path and the caller pays another round trip for it.
    try std.testing.expect(std.mem.indexOf(u8, subagent.system_prompt, "complete and useful") != null);
}

test "capResult: under the cap it is the SAME slice, no copy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const small = "short result";
    const got = subagent.capResult(arena, small);
    // Identity, not equality: the common case must not allocate.
    try std.testing.expect(got.ptr == small.ptr);
}

test "capResult: a cut result says so, ends at a line boundary and fits the cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1000 lines of 40 bytes: a line boundary always exists inside the room.
    var text: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try text.appendSlice(arena, "0123456789012345678901234567890123456789\n");
    }
    const got = subagent.capResult(arena, text.items);
    // The budget is the budget, notice included.
    try std.testing.expect(got.len <= subagent.max_tool_output);
    // The notice is the LAST thing: anything after it reads as part of the output.
    try std.testing.expect(std.mem.endsWith(u8, got, subagent.cut_notice));
    // A fragment that looks complete is the failure this replaces.
    try std.testing.expect(std.mem.indexOf(u8, got, "cut at the subagent's 4 KB budget") != null);
    // Cut at a whole line: the last byte of content before the notice is a newline.
    const body = got[0 .. got.len - subagent.cut_notice.len];
    try std.testing.expect(body.len > 0);
    try std.testing.expect(body[body.len - 1] == '\n');
}

test "capResult: never cuts mid-UTF-8, and a single giant line still gets a notice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // "ñ" is 2 bytes (0xC3 0xB1): a byte cut at an odd position lands between
    // them and the message then carries invalid UTF-8 onto the wire.
    var multibyte: std.ArrayList(u8) = .empty;
    while (multibyte.items.len < subagent.max_tool_output + 100) {
        try multibyte.appendSlice(arena, "añ\n");
    }
    const got = subagent.capResult(arena, multibyte.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));

    // One line, 64 KB, no newline anywhere: the line-boundary cut cannot find
    // one, so it hard-cuts — but the notice still has to be there, because a
    // silent cut is the bug, not the cut.
    const oneline = try arena.alloc(u8, 64 * 1024);
    @memset(oneline, 'x');
    const got2 = subagent.capResult(arena, oneline);
    try std.testing.expect(std.mem.endsWith(u8, got2, subagent.cut_notice));
    try std.testing.expect(got2.len <= subagent.max_tool_output);
}

test "capResult: web_fetch's promise to continue SURVIVES the cap" {
    // The composition this all exists for: `web.excerpt` puts `pass offset=N` at
    // the TOP of the window and the cap keeps the head. Before either change the
    // note was at the tail of a 16 KB result capped to 4 KB — always cut, so a
    // subagent re-fetched the same first window forever and reported the page as
    // read when it had seen 4 KB of it.
    const web = @import("web.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const page = try arena.alloc(u8, 40 * 1024);
    @memset(page, 'a');
    @memcpy(page[0..9], "line one\n");

    const window = web.excerpt(arena, page, 0, 16 * 1024);
    const capped = subagent.capResult(arena, window);
    try std.testing.expect(window.len > subagent.max_tool_output);
    try std.testing.expect(std.mem.indexOf(u8, capped, "pass offset=") != null);
}
