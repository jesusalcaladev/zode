//! The tool registry: one table, not four lists.
//!
//! Every fact about a tool lives here:
//!   - `ToolDef` row: name, description, JSON schema, `read_only` /
//!     `parallel_safe` / `destructive` flags, per-tool result cap.
//!   - `defs` is the single source of truth; `needsPermission`,
//!     `isParallelSafe`, `toolsJson` and `toolsJsonReadOnly` are all derived
//!     from it.
//!
//! The table data is pure, so it is tested without the TUI or the network.
//
//! Note on `run`:
//!
//! Zig 0.16 does not allow error sets in function-pointer types, so a `run`
//! field that propagates tool errors cannot be a typed function pointer in a
//! comptime table. Tool dispatch therefore stays in `executeWith` (which calls
//! the tool functions directly and propagates their errors). The registry owns
//! everything else: one table instead of the scattered permission/schema lists.

const std = @import("std");
const common = @import("common.zig");
const resultcap = @import("../lib/resultcap.zig");
const batch_lib = @import("../lib/batch.zig");
const subagent = @import("../lib/subagent.zig");
const pathsafe = @import("../lib/pathsafe.zig");

// Per-tool prompt modules: the JSON schema each tool offers the model.
const read_prompt = @import("prompts/read.zig");
const write_prompt = @import("prompts/write.zig");
const edit_prompt = @import("prompts/edit.zig");
const notebook_edit_prompt = @import("prompts/notebook_edit.zig");
const bash_prompt = @import("prompts/bash.zig");
const glob_prompt = @import("prompts/glob.zig");
const grep_prompt = @import("prompts/grep.zig");
const refs_prompt = @import("prompts/refs.zig");
const rename_prompt = @import("prompts/rename.zig");
const check_prompt = @import("prompts/check.zig");
const git_status_prompt = @import("prompts/git_status.zig");
const git_diff_prompt = @import("prompts/git_diff.zig");
const git_log_prompt = @import("prompts/git_log.zig");
const git_branch_prompt = @import("prompts/git_branch.zig");
const git_add_prompt = @import("prompts/git_add.zig");
const git_commit_prompt = @import("prompts/git_commit.zig");
const git_stash_prompt = @import("prompts/git_stash.zig");
const list_files_prompt = @import("prompts/list_files.zig");
const web_fetch_prompt = @import("prompts/web_fetch.zig");
const web_search_prompt = @import("prompts/web_search.zig");
const think_prompt = @import("prompts/think.zig");
const todo_prompt = @import("prompts/todo.zig");
const task_create_prompt = @import("prompts/task_create.zig");
const task_get_prompt = @import("prompts/task_get.zig");
const task_list_prompt = @import("prompts/task_list.zig");
const task_update_prompt = @import("prompts/task_update.zig");
const task_stop_prompt = @import("prompts/task_stop.zig");
const ask_prompt = @import("prompts/ask.zig");
const lsp_prompt = @import("prompts/lsp.zig");
const skill_prompt = @import("prompts/skill.zig");
const task_prompt = @import("prompts/task.zig");
const review_prompt = @import("prompts/review.zig");
const goal_prompt = @import("prompts/goal.zig");
const bash_output_prompt = @import("prompts/bash_output.zig");
const bash_kill_prompt = @import("prompts/bash_kill.zig");
const sleep_prompt = @import("prompts/sleep.zig");
const batch_prompt = @import("prompts/batch.zig");
const mcp_prompt = @import("prompts/mcp.zig");
const validate = @import("prompts/validate.zig");

// The `mcp` TOOL, for the one thing the registry has to know about it: the
// qualified name of the tool a call is about. It is the name the permission
// rules match on and the name the "always allow" list remembers, and it is
// decided by the arguments of the call, not by the table.
const mcp_tool = @import("mcp.zig");

/// The result cap of a tool, in characters. `0` means UNBOUNDED.
///
/// The rule, which the table's comment used to state two things at once: a row
/// with `max_result_chars = 0` is unbounded, and `read` is the one that is.
///
/// `read` is unbounded ON PURPOSE: it has a line limit of its own (2000 lines
/// by default) and it is the tool that brings content into the context, so a
/// second cap on top of it would only cut a file the model asked for in
/// pieces. The AGGREGATE budget (`resultcap.max_results_per_message_chars`)
/// is the backstop for that, and it is applied where the results of one
/// message are appended.
pub fn resultCap(name: []const u8) usize {
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.max_result_chars;
    }
    // A tool that is not in the table cannot be called, so this is only
    // reachable from a typo: the default cap is the safe answer.
    return resultcap.default_max_result_chars;
}

// ── the table ─────────────────────────────────────────────────────────────
// One row per tool. `read_only == true` means it never asks for permission
// (the inverse of `needsPermission`). `parallel_safe` means it may run in a
// batch alongside other read-only tools. `destructive` means it writes files
// or runs commands. `max_result_chars` is the per-tool result cap (0 =
// unbounded; `read` is the one that is).
pub const ToolDef = struct {
    name: []const u8,
    desc: []const u8,
    schema: []const u8,
    read_only: bool,
    parallel_safe: bool,
    destructive: bool,
    max_result_chars: usize,
};

pub const defs: []const ToolDef = &[_]ToolDef{
    .{
        .name = "read",
        .desc = "Read a file with line offsets and smart truncation",
        .schema = read_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = 0, // unbounded
    },
    .{
        .name = "write",
        .desc = "Create or overwrite a file",
        .schema = write_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "edit",
        .desc = "Exact str_replace editing, single or multi-hunk",
        .schema = edit_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "notebook_edit",
        .desc = "Edit a Jupyter cell by index, keeping outputs and metadata",
        .schema = notebook_edit_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "bash",
        .desc = "Run a shell command with timeout",
        .schema = bash_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "glob",
        .desc = "Find files matching a glob pattern",
        .schema = glob_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "grep",
        .desc = "Search file contents with regex",
        .schema = grep_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "refs",
        .desc = "Where a symbol is defined and used",
        .schema = refs_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "rename",
        .desc = "Rename a symbol everywhere, in one call",
        .schema = rename_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "check",
        .desc = "Typecheck this project, in the background",
        .schema = check_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "git_status",
        .desc = "Working tree state, machine format",
        .schema = git_status_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "git_diff",
        .desc = "Unified diff of the working tree",
        .schema = git_diff_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "git_log",
        .desc = "Last commits, one line each",
        .schema = git_log_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "git_branch",
        .desc = "list | create | switch: work with branches",
        .schema = git_branch_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "git_add",
        .desc = "Stage changes for the next commit",
        .schema = git_add_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "git_commit",
        .desc = "Commit what is staged, with a message",
        .schema = git_commit_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "git_stash",
        .desc = "push | pop | list: put changes aside and bring them back",
        .schema = git_stash_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "list_files",
        .desc = "List a directory (cheap structure overview)",
        .schema = list_files_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "web_fetch",
        .desc = "Fetch a URL and return it as readable text (HTML stripped)",
        .schema = web_fetch_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "web_search",
        .desc = "Search the web: titles, URLs and snippets",
        .schema = web_search_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "think",
        .desc = "Private scratchpad to reason before acting (no side effects)",
        .schema = think_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "todo",
        .desc = "Write the visible task list the user watches (full list, not a diff)",
        .schema = todo_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "task_create",
        .desc = "Create a task: an id, a status, an owner and dependencies",
        .schema = task_create_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "task_get",
        .desc = "The full record of one task, with both directions of its dependencies",
        .schema = task_get_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "task_list",
        .desc = "Every task in one line: status, owner and what it is waiting on",
        .schema = task_list_prompt.json,
        .read_only = true,
        .parallel_safe = true,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "task_update",
        .desc = "Change a task: start it, finish it, or wire a dependency",
        .schema = task_update_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "task_stop",
        .desc = "Remove a task that is not going to happen, clearing its edges",
        .schema = task_stop_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "ask",
        .desc = "Ask the user one question when the answer changes what you do",
        .schema = ask_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "lsp",
        .desc = "Ask a language server where a symbol is defined, where it is used, its type, the symbols in a file, its call hierarchy or the problems it found",
        .schema = lsp_prompt.json,
        // It asks for NO permission, and this row is where that is decided.
        //
        // The command that gets spawned comes from the table in
        // `lsp/servers.zig` (or from the user's `lsp_servers`), never from the
        // model: there is no argument a model could put an obligation in, which
        // is the same reason `read` asks nothing. It is a READ of the code, and
        // the subagent's read-only toolset has always said so.
        //
        // The two used to disagree: this row said `false` (a dialog for
        // everything) while the tool's own doc said "Permission: none" and
        // `lib/subagent.zig` listed it as read-only. The model got a dialog
        // for a tool nobody thought should ask.
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        // A semantic answer is a location, a signature or a list of problems:
        // short by nature. The formatter's own ceiling is 24 KB, and this cap
        // is the same number, so the tool never builds a megabyte of text that
        // the formatter was going to cut anyway.
        .max_result_chars = 24 * 1024,
    },
    .{
        .name = "skill",
        .desc = "Load a skill's full instructions on demand (cheap: only its name is in your prompt)",
        .schema = skill_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "task",
        .desc = "Send a read-only search to a subagent with its own context, get back a short report",
        .schema = task_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "review",
        .desc = "Read your own diff back with a checklist (the harness requires it before the turn ends)",
        .schema = review_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "goal",
        .desc = "Declare the /goal objective met or blocked, with the evidence (ends the turn)",
        .schema = goal_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "bash_output",
        .desc = "New output of a backgrounded command (incremental) plus its exit status",
        .schema = bash_output_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "bash_kill",
        .desc = "Kill a backgrounded command",
        .schema = bash_kill_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        .name = "sleep",
        .desc = "Wait N seconds without holding a shell (ESC cuts it short)",
        .schema = sleep_prompt.json,
        .read_only = true,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        // `read_only = false` because a CALL can change the world: the tool
        // behind it is the user's own and zode cannot know what it does. The
        // `list` and `search` operations only read the catalogue and do not
        // ask, and that is decided per CALL (`callPermissionTools`), not by
        // the row.
        //
        // It is NOT in the read-only schema either: in plan mode the model is
        // offered the tools that cannot change the machine, and an MCP call
        // can.
        .name = "mcp",
        .desc = "Search and call the tools of an MCP server (deferred: the schemas come with the search)",
        .schema = mcp_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
    .{
        // `read_only = false` because a batch with a `write` or an `edit` step
        // writes. The flag is static and the truth is not: what a batch needs
        // is decided by its STEPS, and `callPermissionTools` is where that is
        // answered. The flag says the safe thing — a batch is never assumed to
        // be free — and the steps say the rest.
        //
        // It is therefore NOT in the read-only schema: in plan mode the model
        // is offered the tools that cannot change the machine, and a batch can.
        .name = "batch",
        .desc = "Run several operations in one round trip",
        .schema = batch_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = true,
        .max_result_chars = resultcap.default_max_result_chars,
    },
};

// ── lookups ───────────────────────────────────────────────────────────────

/// Finds a tool row by name, or null when it is not registered.
pub fn find(name: []const u8) ?ToolDef {
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

/// Does this tool need to ask the user before running it?
pub fn needsPermission(name: []const u8) bool {
    const d = find(name) orelse return true;
    return !d.read_only;
}

/// May this tool run in parallel with other read-only tools?
pub fn isParallelSafe(name: []const u8) bool {
    const d = find(name) orelse return false;
    return d.parallel_safe;
}

/// Does this tool write files or run commands (a destructive action)?
pub fn isDestructive(name: []const u8) bool {
    const d = find(name) orelse return false;
    return d.destructive;
}

/// Per-tool result cap in bytes; `read` is unbounded (`maxInt(usize)`).
pub fn maxResultChars(name: []const u8) usize {
    const d = find(name) orelse return resultcap.default_max_result_chars;
    if (d.max_result_chars == 0) return std.math.maxInt(usize);
    return d.max_result_chars;
}

/// Formats a bash command for the timeline summary, trimming long commands.
fn bashSummarizeLine(arena: std.mem.Allocator, command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len > 60) {
        const shown = trimmed[0..57];
        return std.fmt.allocPrint(arena, "bash({s}…)", .{shown}) catch "bash";
    }
    return std.fmt.allocPrint(arena, "bash({s})", .{trimmed}) catch "bash";
}

/// Formats a rename call for the timeline summary.
fn renameSummarizeLine(arena: std.mem.Allocator, old_name: []const u8, new_name: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "rename({s} → {s})", .{old_name, new_name}) catch "rename";
}

/// One timeline line for a tool call: `read(src/x.zig) · 120 lines`.
/// Extracts what the call acts on from its JSON arguments; when it cannot,
/// falls back to just the tool name.
pub fn toolSummarize(
    arena: std.mem.Allocator,
    name: []const u8,
    args_json: []const u8,
) []const u8 {
    const path = extractStringArg(arena, args_json, "path");
    const command = extractStringArg(arena, args_json, "command");
    const pattern = extractStringArg(arena, args_json, "pattern");
    const symbol = extractStringArg(arena, args_json, "symbol");
    const old_name = extractStringArg(arena, args_json, "old_name");
    const new_name = extractStringArg(arena, args_json, "new_name");

    if (std.mem.eql(u8, name, "read")) {
        if (path) |p| return std.fmt.allocPrint(arena, "read({s})", .{p}) catch "read";
        return "read";
    }
    if (std.mem.eql(u8, name, "write")) {
        if (path) |p| return std.fmt.allocPrint(arena, "write({s})", .{p}) catch "write";
        return "write";
    }
    if (std.mem.eql(u8, name, "edit")) {
        if (path) |p| return std.fmt.allocPrint(arena, "edit({s})", .{p}) catch "edit";
        return "edit";
    }
    if (std.mem.eql(u8, name, "bash")) {
        if (command) |c| return bashSummarizeLine(arena, c);
        return "bash";
    }
    if (std.mem.eql(u8, name, "glob")) {
        if (pattern) |p| return std.fmt.allocPrint(arena, "glob({s})", .{p}) catch "glob";
        return "glob";
    }
    if (std.mem.eql(u8, name, "grep")) {
        if (pattern) |p| return std.fmt.allocPrint(arena, "grep({s})", .{p}) catch "grep";
        return "grep";
    }
    if (std.mem.eql(u8, name, "refs")) {
        if (symbol) |s| return std.fmt.allocPrint(arena, "refs({s})", .{s}) catch "refs";
        return "refs";
    }
    if (std.mem.eql(u8, name, "rename")) {
        if (old_name) |old| if (new_name) |new| return renameSummarizeLine(arena, old, new);
        return "rename";
    }
    if (std.mem.eql(u8, name, "lsp")) {
        if (symbol) |s| return std.fmt.allocPrint(arena, "lsp({s})", .{s}) catch "lsp";
        return "lsp";
    }
    if (std.mem.eql(u8, name, "task")) return "task";
    if (std.mem.eql(u8, name, "task_create")) return "task_create";
    if (std.mem.eql(u8, name, "task_get")) return "task_get";
    if (std.mem.eql(u8, name, "task_list")) return "task_list";
    if (std.mem.eql(u8, name, "task_update")) return "task_update";
    if (std.mem.eql(u8, name, "task_stop")) return "task_stop";
    if (std.mem.eql(u8, name, "mcp")) return "mcp";
    if (std.mem.eql(u8, name, "batch")) return "batch";
    if (std.mem.eql(u8, name, "skill")) return "skill";
    if (std.mem.eql(u8, name, "check")) return "check";
    if (std.mem.eql(u8, name, "notebook_edit")) {
        if (path) |p| return std.fmt.allocPrint(arena, "notebook_edit({s})", .{p}) catch "notebook_edit";
        return "notebook_edit";
    }
    if (std.mem.eql(u8, name, "git_status")) return "git status";
    if (std.mem.eql(u8, name, "git_diff")) return "git diff";
    if (std.mem.eql(u8, name, "git_log")) return "git log";
    if (std.mem.eql(u8, name, "git_branch")) return "git branch";
    if (std.mem.eql(u8, name, "git_add")) return "git add";
    if (std.mem.eql(u8, name, "git_commit")) return "git commit";
    if (std.mem.eql(u8, name, "git_stash")) return "git stash";
    if (std.mem.eql(u8, name, "list_files")) return "list_files";
    if (std.mem.eql(u8, name, "web_fetch")) return "web_fetch";
    if (std.mem.eql(u8, name, "web_search")) return "web_search";
    if (std.mem.eql(u8, name, "think")) return "think";
    if (std.mem.eql(u8, name, "ask")) return "ask";
    if (std.mem.eql(u8, name, "bash_kill")) return "bash_kill";
    if (std.mem.eql(u8, name, "sleep")) return "sleep";
    return name;
}

/// Formats a bash command for the activity strip, trimming long commands.
fn bashActivityLine(arena: std.mem.Allocator, command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len > 40) {
        const shown = trimmed[0..37];
        return std.fmt.allocPrint(arena, "Running {s}…", .{shown}) catch "Running";
    }
    return std.fmt.allocPrint(arena, "Running {s}", .{trimmed}) catch "Running";
}

/// One activity phrase for the strip: `Reading src/x.zig`.
pub fn toolActivity(
    arena: std.mem.Allocator,
    name: []const u8,
    args_json: []const u8,
) []const u8 {
    const path = extractStringArg(arena, args_json, "path");
    const command = extractStringArg(arena, args_json, "command");
    const pattern = extractStringArg(arena, args_json, "pattern");
    const symbol = extractStringArg(arena, args_json, "symbol");

    if (std.mem.eql(u8, name, "read")) {
        if (path) |p| return std.fmt.allocPrint(arena, "Reading {s}", .{p}) catch "Reading";
        return "Reading";
    }
    if (std.mem.eql(u8, name, "write")) {
        if (path) |p| return std.fmt.allocPrint(arena, "Writing {s}", .{p}) catch "Writing";
        return "Writing";
    }
    if (std.mem.eql(u8, name, "edit")) {
        if (path) |p| return std.fmt.allocPrint(arena, "Editing {s}", .{p}) catch "Editing";
        return "Editing";
    }
    if (std.mem.eql(u8, name, "bash")) {
        if (command) |c| return bashActivityLine(arena, c);
        return "Running";
    }
    if (std.mem.eql(u8, name, "glob")) {
        if (pattern) |p| return std.fmt.allocPrint(arena, "Finding files {s}", .{p}) catch "Finding files";
        return "Finding files";
    }
    if (std.mem.eql(u8, name, "grep")) {
        if (pattern) |p| return std.fmt.allocPrint(arena, "Searching {s}", .{p}) catch "Searching";
        return "Searching";
    }
    if (std.mem.eql(u8, name, "refs")) {
        if (symbol) |s| return std.fmt.allocPrint(arena, "Finding references {s}", .{s}) catch "Finding references";
        return "Finding references";
    }
    if (std.mem.eql(u8, name, "rename")) return "Renaming";
    if (std.mem.eql(u8, name, "lsp")) {
        if (symbol) |s| return std.fmt.allocPrint(arena, "Inspecting {s}", .{s}) catch "Inspecting";
        return "Inspecting";
    }
    if (std.mem.eql(u8, name, "task")) return "Running subagent";
    if (std.mem.eql(u8, name, "task_create")) return "Creating task";
    if (std.mem.eql(u8, name, "task_get")) return "Reading task";
    if (std.mem.eql(u8, name, "task_list")) return "Listing tasks";
    if (std.mem.eql(u8, name, "task_update")) return "Updating task";
    if (std.mem.eql(u8, name, "task_stop")) return "Stopping task";
    if (std.mem.eql(u8, name, "mcp")) return "Calling MCP";
    if (std.mem.eql(u8, name, "batch")) return "Running batch";
    if (std.mem.eql(u8, name, "skill")) return "Loading skill";
    if (std.mem.eql(u8, name, "check")) return "Typechecking";
    if (std.mem.eql(u8, name, "notebook_edit")) {
        if (path) |p| return std.fmt.allocPrint(arena, "Editing notebook {s}", .{p}) catch "Editing notebook";
        return "Editing notebook";
    }
    if (std.mem.eql(u8, name, "git_status")) return "Checking git status";
    if (std.mem.eql(u8, name, "git_diff")) return "Showing git diff";
    if (std.mem.eql(u8, name, "git_log")) return "Viewing git history";
    if (std.mem.eql(u8, name, "git_branch")) return "Managing git branch";
    if (std.mem.eql(u8, name, "git_add")) return "Staging changes";
    if (std.mem.eql(u8, name, "git_commit")) return "Committing changes";
    if (std.mem.eql(u8, name, "git_stash")) return "Stashing changes";
    if (std.mem.eql(u8, name, "list_files")) return "Listing files";
    if (std.mem.eql(u8, name, "web_fetch")) return "Fetching URL";
    if (std.mem.eql(u8, name, "web_search")) return "Searching web";
    if (std.mem.eql(u8, name, "think")) return "Thinking";
    if (std.mem.eql(u8, name, "ask")) return "Asking user";
    if (std.mem.eql(u8, name, "bash_kill")) return "Killing command";
    if (std.mem.eql(u8, name, "sleep")) return "Waiting";
    return name;
}

/// Extracts a string argument from a JSON object by key. Returns null on any
/// parse failure or missing key, so callers always have a fallback.
fn extractStringArg(arena: std.mem.Allocator, json: []const u8, key: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return null;
    if (parsed != .object) return null;
    const obj = parsed.object;
    const val = obj.get(key) orelse return null;
    return val.string;
}

// ── the batch, whose permission set depends on its arguments ───
//
// `batch` is a call to SEVERAL tools at once, so the static flag in the table
// cannot answer whether it needs permission: a batch of reads must not ask,
// and a batch that writes must ask exactly what the write would have asked.
//
// The answer is the UNION of the tools its steps are calls to. A batch is a
// way of doing several things in ONE round trip, never a way of doing one of
// them without asking: that is the whole safety argument of the tool, and it
// is one function.

/// The tools one call needs permission for.
///
/// For every tool but `batch` it is the tool itself. For `batch` it is the
/// union of the tools its steps are calls to. A batch whose arguments do not
/// parse answers with the tool ITSELF, because a batch nobody can reason
/// about is the one that has to ask.
pub fn callPermissionTools(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const []const u8 {
    if (!std.mem.eql(u8, name, "batch")) {
        // The `mcp` tool's permission set depends on the OPERATION: a `list`
        // or a `search` only reads the catalogue and asks for nothing, and a
        // `call` asks about the qualified name of the tool it is about.
        //
        // The name that goes into the set is `server.tool` and not `mcp`: the
        // answer the user gives is about THAT tool, and a rule that remembers
        // `mcp` would cover every server the user ever configures.
        if (std.mem.eql(u8, name, "mcp")) {
            const q = mcp_tool.qualifiedOf(parseObject(arena, args_json) orelse return &.{}, arena) orelse return &.{};
            const one = arena.alloc([]const u8, 1) catch return &.{};
            one[0] = q;
            return one;
        }
        return oneTool(arena, name);
    }
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch {
        return oneTool(arena, name);
    };
    if (parsed != .object) {
        return oneTool(arena, name);
    }
    const b = batch_lib.parse(arena, parsed.object) catch {
        return oneTool(arena, name);
    };
    const set = batch_lib.permissionTools(arena, b) catch {
        return oneTool(arena, name);
    };
    if (set.len == 0) {
        return oneTool(arena, name);
    }
    return set;
}

/// A one-element set, in the ARENA.
///
/// Not a local array: returning a slice of a local is a dangling pointer the
/// moment the function returns, and this is read a few lines later, by a
/// different function, on another stack frame. It is the `&[_]u8{c}` family
/// again, with a bigger blast radius.
fn oneTool(arena: std.mem.Allocator, name: []const u8) []const []const u8 {
    const one = arena.alloc([]const u8, 1) catch return &.{};
    one[0] = name;
    return one;
}

/// The arguments of a call as an object, or null when they are not one.
///
/// The `mcp` tool's permission set depends on the OPERATION and on the tool
/// it names, and both live in the arguments. A call whose arguments do not
/// parse gets no subject, which means no rule can match it and it asks: the
/// direction that is safe to be wrong in.
fn parseObject(arena: std.mem.Allocator, args_json: []const u8) ?std.json.ObjectMap {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
    if (parsed != .object) return null;
    return parsed.object;
}

/// Does this call change a file?
///
/// For `batch` it is whether any of its steps does. A batch whose arguments
/// do not parse counts as writing: the safe direction is the one that asks.
///
/// For `mcp` it is whether the call is a CALL: an MCP tool can change the
/// world (the tool behind it is the user's own and zode cannot know what it
/// does), while `list` and `search` only read the catalogue. The decision is
/// per CALL and not per TOOL, because the same tool does both.
pub fn callWrites(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) bool {
    if (std.mem.eql(u8, name, "mcp")) {
        const obj = parseObject(arena, args_json) orelse return true;
        const op = obj.get("operation") orelse return true;
        if (op != .string) return true;
        return std.ascii.eqlIgnoreCase(op.string, "call");
    }
    if (!std.mem.eql(u8, name, "batch")) return false;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return true;
    if (parsed != .object) return true;
    const b = batch_lib.parse(arena, parsed.object) catch return true;
    for (b.steps) |s| {
        if (s.op.writes()) return true;
    }
    return false;
}

/// The files one call would write or edit.
///
/// For every tool but `batch` it is the one path the arguments name. For
/// `batch` it is every path its writing steps name, in order and without
/// repeats: the permission dialog names the files, because a dialog that
/// says "batch" and nothing else is a dialog about nothing.
pub fn callTouchedPaths(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const []const u8 {
    if (!std.mem.eql(u8, name, "batch")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return &.{};
        if (parsed != .object) return &.{};
        if (parsed.object.get("files")) |fv| {
            // The MULTI-FILE form of `edit`: `files: [{path, …}, …]`.
            //
            // It was not here, and the permission dialog therefore named NO
            // file for a call that touches eight: the user was asked to
            // approve "edit" and the set of files was the whole question.
            if (fv != .array) return &.{};
            var out: std.ArrayList([]const u8) = .empty;
            for (fv.array.items) |item| {
                if (item != .object) continue;
                const p = item.object.get("path") orelse continue;
                if (p != .string or p.string.len == 0) continue;
                out.append(arena, p.string) catch return &.{};
            }
            if (out.items.len > 0) return out.items;
            return &.{};
        }
        const v = parsed.object.get("path") orelse parsed.object.get("notebook_path") orelse return &.{};
        if (v != .string or v.string.len == 0) return &.{};
        const one = arena.alloc([]const u8, 1) catch return &.{};
        one[0] = v.string;
        return one;
    }
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    const b = batch_lib.parse(arena, parsed.object) catch return &.{};
    return batch_lib.touchedPaths(arena, b) catch &.{};
}

/// The subjects a PERMISSION RULE is matched against.
///
/// A rule is `Tool(pattern)`, and the pattern is over the thing the call
/// acts on: the PATH for a file tool, the COMMAND for `bash`. A call that
/// touches four files has four subjects, and a rule that matches one of them
/// is about that one.
pub fn callSubjects(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const []const u8 {
    if (std.mem.eql(u8, name, "bash")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return &.{};
        if (parsed != .object) return &.{};
        const cmd = parsed.object.get("command") orelse return &.{};
        if (cmd != .string or cmd.string.len == 0) return &.{};
        const one = arena.alloc([]const u8, 1) catch return &.{};
        one[0] = cmd.string;
        return one;
    }
    // The `mcp` tool's subject is the qualified name of the tool it calls:
    // `github.create_issue`. It is the name the model typed, the name the
    // rules match on and the name the "always allow" list remembers, and one
    // spelling for all three is what makes the rule legible.
    if (std.mem.eql(u8, name, "mcp")) {
        const obj = parseObject(arena, args_json) orelse return &.{};
        const q = mcp_tool.qualifiedOf(obj, arena) orelse return &.{};
        const one = arena.alloc([]const u8, 1) catch return &.{};
        one[0] = q;
        return one;
    }
    return callTouchedPaths(name, args_json, arena);
}

/// The paths of a call that the SENSITIVE-PATH rule would refuse.
///
/// It is the PURE check, and it is asked about BEFORE the call runs: the
/// dispatcher is the one that can open the dialog, and the tool cannot.
///
/// The result is what the user is asked about, so it is only the paths that
/// are actually a problem: a call that touches four files and one of them
/// is inside `.git/` asks about ONE path.
pub fn riskyPaths(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const []const u8 {
    const all = callTouchedPaths(name, args_json, arena);
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |p| {
        if (pathsafe.checkWrite(p) != .ok) out.append(arena, p) catch return &.{};
    }
    return out.items;
}

/// The sentence the permission dialog shows for a batch.
///
/// It says WHAT the batch would do and TO WHICH FILES: the user is being
/// asked to approve a set of writes, and the set is the whole of the
/// question.
pub fn batchPermissionDetail(args_json: []const u8, arena: std.mem.Allocator) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch
        return "batch";
    if (parsed != .object) return "batch";
    const b = batch_lib.parse(arena, parsed.object) catch return "batch";
    const paths = batch_lib.touchedPaths(arena, b) catch return "batch";
    if (paths.len == 0) return "batch";
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, "batch") catch return "batch";
    for (paths) |p| {
        out.append(arena, ' ') catch return "batch";
        out.appendSlice(arena, p) catch return "batch";
    }
    return out.items;
}

// ── schema generation (derived from the table, not hand-maintained) ──
// `toolsJson` lists every registered tool; `toolsJsonReadOnly` lists only the
// read-only ones. Both are built once at comptime from `defs`, so they can
// never drift from the permission table.

/// The JSON array of the tools, composed at COMPILE TIME from `defs`.
///
/// It used to be a hand-written list of INDICES (`defs[0].schema ++ "," ++
/// defs[1].schema ++ ...`), and a hand-written list of indices is a list that
/// goes stale the day a tool is added in the middle: the entry that moves is
/// simply not offered, and nothing says so. The `lsp` tool was in the table
/// and in the model's schema, and the read-only copy had not caught up — the
/// two said different things about the same tool and the test that compares
/// them was the only thing that noticed.
fn blob(comptime read_only_only: bool) []const u8 {
    var out: []const u8 = "[";
    var first = true;
    inline for (defs) |d| {
        if (read_only_only and !d.read_only) continue;
        if (!first) out = out ++ ",";
        out = out ++ d.schema;
        first = false;
    }
    return out ++ "]";
}

/// Every registered tool, in `defs` order.
pub const toolsJsonBlob: []const u8 = blob(false);

/// Only the tools that ask for no permission: the schema of read-only mode.
pub const toolsJsonReadOnlyBlob: []const u8 = blob(true);

pub fn toolsJson() []const u8 {
    return toolsJsonBlob;
}

pub fn toolsJsonReadOnly() []const u8 {
    return toolsJsonReadOnlyBlob;
}
test "needsPermission" {
    try std.testing.expect(needsPermission("bash"));
    try std.testing.expect(needsPermission("check"));
    try std.testing.expect(needsPermission("rename"));
    try std.testing.expect(needsPermission("task"));
    try std.testing.expect(!needsPermission("refs"));
    try std.testing.expect(!needsPermission("grep"));
    try std.testing.expect(!needsPermission("glob"));
    try std.testing.expect(!needsPermission("web_search"));
    try std.testing.expect(!needsPermission("task_list"));
    try std.testing.expect(!needsPermission("ask"));
    try std.testing.expect(!needsPermission("skill"));
    try std.testing.expect(!needsPermission("sleep"));
    try std.testing.expect(!needsPermission("review"));
    try std.testing.expect(!needsPermission("goal"));
    // The language server asks for nothing: the command that gets spawned is
    // fixed by a table, never chosen by the model, so there is no argument a
    // model could put an obligation in. It used to ask (a dialog for every
    // question about the code) while its own doc said "Permission: none".
    try std.testing.expect(!needsPermission("lsp"));
    // `batch` can write, so it is not on the free list. WHAT it needs is
    // decided by its steps — see the test below.
    try std.testing.expect(needsPermission("batch"));
    // Unknown tools are conservative: they need permission.
    try std.testing.expect(needsPermission("no_such_tool"));
}

test "every tool a subagent may use is read-only in this table" {
    // The subagent's list is a POLICY about this table, and the two used to
    // disagree: `lsp` was in the subagent's read-only list and `read_only =
    // false` here. The model got a permission dialog for a tool nobody
    // thought should ask, and the read-only schema did not carry it.
    //
    // The other direction matters too: a tool in the subagent's list that
    // needs permission would put a dialog in front of a thread that is not
    // the turn's — and nobody would be there to answer it.
    for (subagent.tool_names) |n| {
        if (needsPermission(n)) {
            std.debug.print("the subagent may use `{s}`, which asks for permission\n", .{n});
            return error.SubagentToolAsks;
        }
    }
}

test "a batch of reads asks for nothing, and a batch that writes asks for the write" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The read-only default: a batch that only reads needs no permission.
    // This is the property that makes the tool usable at all — a dialog for
    // every batch would be a dialog per round trip saved.
    const reads = callPermissionTools(
        "batch",
        \\{"steps":[{"op":"read","path":"a.zig"},{"op":"grep","pattern":"x"},{"op":"count"}]}
    ,
        arena,
    );
    try std.testing.expect(reads.len > 0);
    for (reads) |t| {
        try std.testing.expect(!needsPermission(t));
    }

    // A batch with a write step needs exactly what the write would have
    // needed — and NOT the tool "batch", which would be a hole.
    const writes = callPermissionTools(
        "batch",
        \\{"steps":[{"op":"read","path":"a.zig"},{"op":"write","path":"out.md"}]}
    ,
        arena,
    );
    try std.testing.expectEqual(@as(usize, 2), writes.len);
    try std.testing.expectEqualStrings("read", writes[0]);
    try std.testing.expectEqualStrings("write", writes[1]);
    try std.testing.expect(needsPermission(writes[1]));

    // A batch whose arguments do not parse asks: the safe direction is the
    // one that asks.
    const broken = callPermissionTools("batch", "{\"steps\":", arena);
    try std.testing.expectEqual(@as(usize, 1), broken.len);
    try std.testing.expectEqualStrings("batch", broken[0]);
    try std.testing.expect(needsPermission(broken[0]));
}

test "a batch writes only when one of its steps writes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(!callWrites("batch", "{\"steps\":[{\"op\":\"read\",\"path\":\"a\"}]}", arena));
    try std.testing.expect(!callWrites("batch", "{\"steps\":[{\"op\":\"grep\",\"pattern\":\"x\"},{\"op\":\"map\",\"field\":\"lines\"}]}", arena));
    try std.testing.expect(callWrites("batch", "{\"steps\":[{\"op\":\"read\",\"path\":\"a\"},{\"op\":\"write\",\"path\":\"o.md\"}]}", arena));
    try std.testing.expect(callWrites("batch", "{\"steps\":[{\"op\":\"edit\",\"path\":\"a\",\"old_string\":\"x\",\"new_string\":\"y\"}]}", arena));
    // An unreadable batch counts as writing: the safe direction is the one
    // that asks.
    try std.testing.expect(callWrites("batch", "not json", arena));

    // The files it would touch are named, and only the writing ones.
    const paths = callTouchedPaths(
        "batch",
        \\{"steps":[{"op":"read","path":"a.zig"},{"op":"write","path":"out.md"},{"op":"edit","path":"a.zig","old_string":"x","new_string":"y"}]}
    ,
        arena,
    );
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("out.md", paths[0]);
    try std.testing.expectEqualStrings("a.zig", paths[1]);
}

test "an MCP call asks about the TOOL, and a search asks about nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A `search` and a `list` only read the user's own catalogue: they ask
    // for nothing, and a dialog for every search would be a dialog per
    // round trip saved.
    const searching = callPermissionTools("mcp", "{\"operation\":\"search\",\"query\":\"issue\"}", arena);
    try std.testing.expectEqual(@as(usize, 0), searching.len);
    const listing = callPermissionTools("mcp", "{\"operation\":\"list\"}", arena);
    try std.testing.expectEqual(@as(usize, 0), listing.len);

    // A CALL asks about the QUALIFIED name of the tool, and not about `mcp`:
    // the answer the user gives is about that one tool, and a rule that
    // remembered `mcp` would cover every server the user ever configures.
    const calling = callPermissionTools(
        "mcp",
        "{\"operation\":\"call\",\"server\":\"github\",\"tool\":\"create_issue\"}",
        arena,
    );
    try std.testing.expectEqual(@as(usize, 1), calling.len);
    try std.testing.expectEqualStrings("github.create_issue", calling[0]);
    // And an unknown name asks: the direction that is safe to be wrong in.
    try std.testing.expect(needsPermission(calling[0]));

    // The subject is the same name: the rules match on it.
    const subjects = callSubjects(
        "mcp",
        "{\"operation\":\"call\",\"server\":\"github\",\"tool\":\"create_issue\"}",
        arena,
    );
    try std.testing.expectEqual(@as(usize, 1), subjects.len);
    try std.testing.expectEqualStrings("github.create_issue", subjects[0]);

    // A call whose arguments do not parse has no subject and asks.
    const broken = callPermissionTools("mcp", "not json", arena);
    try std.testing.expect(needsPermission("mcp"));
    try std.testing.expect(broken.len == 0 or needsPermission(broken[0]));
}

test "an MCP call counts as a write in plan mode, and a search does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A CALL can change the world: the tool behind it is the user's own and
    // zode cannot know what it does.
    try std.testing.expect(callWrites("mcp", "{\"operation\":\"call\",\"server\":\"g\",\"tool\":\"t\"}", arena));
    // The `list` and `search` operations only read the catalogue, and a plan
    // written without looking is a plan written in the dark.
    try std.testing.expect(!callWrites("mcp", "{\"operation\":\"search\",\"query\":\"x\"}", arena));
    try std.testing.expect(!callWrites("mcp", "{\"operation\":\"list\"}", arena));
    // And a call whose arguments do not parse counts as a write.
    try std.testing.expect(callWrites("mcp", "not json", arena));
}

test "the permission dialog is told WHICH FILES a batch would touch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const detail = batchPermissionDetail(
        \\{"steps":[{"op":"read","path":"a.zig"},{"op":"write","path":"out.md"},{"op":"edit","path":"src/b.zig","old_string":"x","new_string":"y"}]}
    ,
        arena,
    );
    try std.testing.expect(std.mem.indexOf(u8, detail, "out.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "src/b.zig") != null);
    // And it does NOT name a file the batch only reads.
    try std.testing.expect(std.mem.indexOf(u8, detail, "a.zig") == null);
}

test "isParallelSafe mirrors the table" {
    try std.testing.expect(isParallelSafe("read"));
    try std.testing.expect(isParallelSafe("grep"));
    try std.testing.expect(isParallelSafe("glob"));
    try std.testing.expect(isParallelSafe("refs"));
    try std.testing.expect(isParallelSafe("list_files"));
    try std.testing.expect(isParallelSafe("web_fetch"));
    try std.testing.expect(isParallelSafe("git_status"));
    try std.testing.expect(isParallelSafe("task_list"));
    try std.testing.expect(!isParallelSafe("write"));
    try std.testing.expect(!isParallelSafe("bash"));
    try std.testing.expect(!isParallelSafe("check"));
    try std.testing.expect(!isParallelSafe("rename"));
    try std.testing.expect(!isParallelSafe("task_create"));
    try std.testing.expect(!isParallelSafe("task"));
}

test "isDestructive flags writers and runners" {
    try std.testing.expect(isDestructive("write"));
    try std.testing.expect(isDestructive("edit"));
    try std.testing.expect(isDestructive("bash"));
    try std.testing.expect(isDestructive("rename"));
    try std.testing.expect(isDestructive("git_add"));
    try std.testing.expect(isDestructive("git_commit"));
    try std.testing.expect(isDestructive("git_stash"));
    try std.testing.expect(!isDestructive("read"));
    try std.testing.expect(!isDestructive("grep"));
    try std.testing.expect(!isDestructive("check"));
    try std.testing.expect(!isDestructive("task_list"));
}

test "toolsJson is valid JSON and has one entry per tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, toolsJson(), .{}) catch {
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(v == .array);
    // The count comes from `defs`, not from a hand-written number: adding a tool
    // without declaring it in the JSON (or the other way round) fails here.
    try std.testing.expectEqual(defs.len, v.array.items.len);
    for (v.array.items) |item| {
        const function_obj = item.object.get("function").?.object;
        const fname = function_obj.get("name").?.string;
        var found = false;
        for (defs) |d| {
            if (std.mem.eql(u8, d.name, fname)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "the read-only schema is exactly the tools that do not ask for permission" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ro = std.json.parseFromSliceLeaky(std.json.Value, arena, toolsJsonReadOnly(), .{}) catch {
        return error.BadSchema;
    };
    if (ro != .array) return error.BadSchema;
    for (defs) |d| {
        var in_readonly = false;
        for (ro.array.items) |item| {
            const function_obj = item.object.get("function").?.object;
            const n = function_obj.get("name").?.string;
            if (std.mem.eql(u8, n, d.name)) in_readonly = true;
        }
        // in_readonly must be the opposite of needsPermission: read-only schema
        // == !needsPermission. Drift (they agree) is an error.
        if (in_readonly == needsPermission(d.name)) {
            std.debug.print(
                "{s}: the read-only schema and the permission table disagree (in the schema: {}, asks permission: {})\n",
                .{ d.name, in_readonly, needsPermission(d.name) },
            );
            return error.ReadOnlySchemaDrift;
        }
    }
}

test "each row's schema is valid JSON and matches its tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (defs) |d| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, d.schema, .{}) catch {
            std.debug.print("bad schema for {s}\n", .{d.name});
            return error.BadSchema;
        };
        if (v != .object) return error.BadSchema;
        const fn_value = v.object.get("function") orelse return error.BadSchema;
        if (fn_value != .object) return error.BadSchema;
        const f = fn_value.object;
        const name_value = f.get("name") orelse return error.BadSchema;
        if (name_value != .string) return error.BadSchema;
        if (!std.mem.eql(u8, name_value.string, d.name)) {
            std.debug.print("name mismatch for {s}: got {s}\n", .{ d.name, name_value.string });
            return error.SchemaNameMismatch;
        }
        const params_value = f.get("parameters") orelse return error.BadSchema;
        if (params_value != .object) return error.BadSchema;
        if (params_value.object.get("type") == null) return error.BadSchema;
    }
}

test "maxResultChars: read is unbounded, others use the default cap" {
    try std.testing.expectEqual(std.math.maxInt(usize), maxResultChars("read"));
    try std.testing.expectEqual(resultcap.default_max_result_chars, maxResultChars("write"));
    try std.testing.expectEqual(resultcap.default_max_result_chars, maxResultChars("bash"));
    try std.testing.expectEqual(resultcap.default_max_result_chars, maxResultChars("grep"));
}

test "the registry: every tool but read has a result cap" {
    // A row that forgets its cap is unbounded, and an unbounded result is a
    // megabyte in a message. `read` is the ONE exception, and it is deliberate.
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, "read")) {
            try std.testing.expectEqual(@as(usize, 0), d.max_result_chars);
            continue;
        }
        try std.testing.expect(d.max_result_chars > 0);
    }
    // And the accessor agrees with the table.
    try std.testing.expectEqual(@as(usize, 0), resultCap("read"));
    try std.testing.expectEqual(@as(usize, resultcap.default_max_result_chars), resultCap("write"));
    try std.testing.expectEqual(@as(usize, resultcap.default_max_result_chars), resultCap("a-tool-that-does-not-exist"));
}

test "riskyPaths: only the paths the rule would refuse, and the multi-file form too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One ordinary file: nothing to ask about.
    const none = riskyPaths("write", "{\"path\":\"src/main.zig\"}", arena);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // One inside `.git/`: that is the question.
    const one = riskyPaths("write", "{\"path\":\".git/hooks/pre-commit\"}", arena);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings(".git/hooks/pre-commit", one[0]);

    // The MULTI-FILE form of `edit`: the question is about the ONE file that
    // is a problem, and the other three are not part of it.
    const many = riskyPaths(
        "edit",
        "{\"files\":[{\"path\":\"src/a.zig\"},{\"path\":\".git/config\"},{\"path\":\"src/b.zig\"}]}",
        arena,
    );
    try std.testing.expectEqual(@as(usize, 1), many.len);
    try std.testing.expectEqualStrings(".git/config", many[0]);
}

test "toolSummarize: read names the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = toolSummarize(arena, "read", "{\"path\":\"src/x.zig\"}");
    try std.testing.expectEqualStrings("read(src/x.zig)", s);
}

test "toolSummarize: bash trims long commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = toolSummarize(arena, "bash", "{\"command\":\"npm test\"}");
    try std.testing.expectEqualStrings("bash(npm test)", s);
    const s2 = toolSummarize(arena, "read", "{\"path\":\"src/x.zig\"}");
    try std.testing.expectEqualStrings("read(src/x.zig)", s2);
}

test "toolSummarize: unknown tool returns its name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = toolSummarize(arena, "nonexistent_tool", "{}");
    try std.testing.expectEqualStrings("nonexistent_tool", s);
}

test "toolActivity: read names the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = toolActivity(arena, "read", "{\"path\":\"src/x.zig\"}");
    try std.testing.expectEqualStrings("Reading src/x.zig", s);
}

test "toolActivity: bash shows the command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = toolActivity(arena, "bash", "{\"command\":\"npm test\"}");
    try std.testing.expectEqualStrings("Running npm test", s);
}

test "toolActivity: grep names the pattern" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = toolActivity(arena, "grep", "{\"pattern\":\"TODO\"}");
    try std.testing.expectEqualStrings("Searching TODO", s);
}

test "toolActivity: unknown tool returns its name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = toolActivity(arena, "nonexistent_tool", "{}");
    try std.testing.expectEqualStrings("nonexistent_tool", s);
}
