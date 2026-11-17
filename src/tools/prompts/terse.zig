//! Short descriptions for the opt-in `terse` output style (Phase 41.1).
//!
//! These are NOT a rewrite of the tool rules: the `terse` output style carries
//! the full guidance in its body, and these strings keep only the trigger and
//! the one fact that changes how the tool is called. The tests at the bottom
//! assert that the critical keywords survive — a shorter description that
//! drops a rule is a regression, not a saving.

const std = @import("std");

pub const Entry = struct { name: []const u8, description: []const u8 };

pub const entries = [_]Entry{
    .{
        .name = "bash",
        .description = "Run a shell command. Pass a one-line `description` of what it is FOR. Blocks until done; slow verifications go to the background automatically. On error fix the CAUSE, do not retry the same line. Use `check` for the project's real gate.",
    },
    .{
        .name = "task",
        .description = "Send a scoped investigation to a SUBAGENT with its own context (it cannot see this conversation). One focused question per call; send independent calls in the SAME message to run them in parallel. `role` = explore|plan|verify. `run_in_background:true` returns an id and notifies when the report lands.",
    },
    .{
        .name = "check",
        .description = "Run the project's REAL verification gate (not a hand-typed npm test/pytest/cargo test). Reports what it actually ran. A green typecheck does not mean the tests pass — verify with this tool and say what was not verified.",
    },
    .{
        .name = "read",
        .description = "Read a file with line numbers, or up to 8 at once with `paths` — ONE round trip, not N. Images arrive as images, never as bytes. USE INSTEAD OF bash cat/head. Files already in context return an unchanged note; pass force:true only when you genuinely need the text again.",
    },
    .{
        .name = "web_fetch",
        .description = "Fetch a URL as readable text (no permission prompt; markup stripped). USE INSTEAD OF bash curl. Returns a WINDOW: pass the `offset` from the truncation note to get the next window of the SAME page — never re-fetch page one. A session cache avoids duplicates; force=true bypasses it.",
    },
    .{
        .name = "notebook_edit",
        .description = "Edit ONE .ipynb cell by the 0-based index from `read`'s numbered outline. `new_source` is the cell TEXT with real newlines, not JSON. USE INSTEAD OF edit/write on a notebook — those destroy outputs. All other cells, outputs and ids are preserved.",
    },
    .{
        .name = "task_update",
        .description = "Update one task in the graph: status, owner, priority or dependencies. Claim work with status=in_progress and owner=your name before editing it. Use task_list first to find the id.",
    },
    .{
        .name = "lsp",
        .description = "Language-server query (definition, references, hover, symbols, diagnostics). The command is FIXED from the server table; you only name a file and position. Ask for no permission.",
    },
    .{
        .name = "batch",
        .description = "Run several independent tool calls in ONE message so they execute in parallel. Each step is a normal tool call with its own permission decision. Use it when the calls do not depend on each other's results.",
    },
    .{
        .name = "grep",
        .description = "Search file CONTENT (rg > git grep > grep > pure fallback). Pairs with `glob` for file names and `refs` for symbol edges. Respects .gitignore; a cut says how much was omitted and how to continue with `offset`.",
    },
    .{
        .name = "todo",
        .description = "Write the numbered implementation plan zode displays in scrollable history. Use it in plan mode to present a plan for approval, and to track progress while working. One concrete step per line.",
    },
    .{
        .name = "sleep",
        .description = "Bounded wait in milliseconds. ESC cuts it. Used for polling a background job without freezing the UI; prefer a completion notification over repeated sleeps.",
    },
    .{
        .name = "send_user_message",
        .description = "Put the answer the user READS here, in markdown, ending with 'done!' — not a play-by-play in the tool log. status=proactive also raises a notification. A missing attachment path is a NAMED error.",
    },
    .{
        .name = "ask",
        .description = "Ask ONE short question only when the answer changes what you do next. Never ask what read/grep/glob can answer. Recommendation FIRST, 2-5 options, one question per step and max 3 per turn. Esc means decide yourself and say what you picked.",
    },
    .{
        .name = "mcp",
        .description = "Use an MCP server: `search`/`list` the catalogue first, then `call` with `server.tool`. The schema of a call is read from the server's catalogue, not from the request.",
    },
    .{
        .name = "config",
        .description = "`get` a setting (free) or `set` one of the seven whitelisted keys (asks per key). Credentials are never reachable through this tool. Unknown keys are refused with the full list.",
    },
    .{
        .name = "github",
        .description = "GitHub API: `auth_status`, PRs and issues. Read operations are free; write operations ask per operation. Token values are never printed; a credential in a remote URL is stripped.",
    },
};

pub fn descriptionFor(name: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.description;
    }
    return null;
}

/// A terse description must stay under this many bytes, or it is not terse.
pub const max_description_len = 480;

test "terse: every curated description stays short" {
    for (entries) |e| {
        try std.testing.expect(e.description.len <= max_description_len);
        try std.testing.expect(e.description.len > 40);
    }
}

test "terse: critical rules survive the shortening" {
    const required = [_]struct { tool: []const u8, word: []const u8 }{
        .{ .tool = "bash", .word = "description" },
        .{ .tool = "bash", .word = "CAUSE" },
        .{ .tool = "task", .word = "SAME message" },
        .{ .tool = "task", .word = "run_in_background" },
        .{ .tool = "check", .word = "REAL verification gate" },
        .{ .tool = "read", .word = "paths" },
        .{ .tool = "web_fetch", .word = "offset" },
        .{ .tool = "notebook_edit", .word = "new_source" },
        .{ .tool = "send_user_message", .word = "done!" },
        .{ .tool = "ask", .word = "Recommendation FIRST" },
    };
    for (required) |r| {
        const d = descriptionFor(r.tool) orelse return error.TestExpectedNotNull;
        try std.testing.expect(std.mem.indexOf(u8, d, r.word) != null);
    }
}
