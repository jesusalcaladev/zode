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
const validate = @import("prompts/validate.zig");

// ── the table ─────────────────────────────────────────────────────────────
// One row per tool. `read_only == true` means it never asks for permission
// (the inverse of `needsPermission`). `parallel_safe` means it may run in a
// batch alongside other read-only tools. `destructive` means it writes files
// or runs commands. `max_result_chars` is the per-tool result cap (0 = use
// `resultcap.default_max_result_chars`; `read` is unbounded).
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
        .desc = "Ask a language server goToDefinition, findReferences, hover, documentSymbol, workspaceSymbol, goToImplementation, prepareCallHierarchy, incomingCalls, outgoingCalls",
        .schema = lsp_prompt.json,
        .read_only = false,
        .parallel_safe = false,
        .destructive = false,
        .max_result_chars = resultcap.default_max_result_chars,
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

// ── schema generation (derived from the table, not hand-maintained) ──
// `toolsJson` lists every registered tool; `toolsJsonReadOnly` lists only the
// read-only ones. Both are built once at comptime from `defs`, so they can
// never drift from the permission table.

pub const toolsJsonBlob: []const u8 = "["
    ++ defs[0].schema
    ++ ","
    ++ defs[1].schema
    ++ ","
    ++ defs[2].schema
    ++ ","
    ++ defs[3].schema
    ++ ","
    ++ defs[4].schema
    ++ ","
    ++ defs[5].schema
    ++ ","
    ++ defs[6].schema
    ++ ","
    ++ defs[7].schema
    ++ ","
    ++ defs[8].schema
    ++ ","
    ++ defs[9].schema
    ++ ","
    ++ defs[10].schema
    ++ ","
    ++ defs[11].schema
    ++ ","
    ++ defs[12].schema
    ++ ","
    ++ defs[13].schema
    ++ ","
    ++ defs[14].schema
    ++ ","
    ++ defs[15].schema
    ++ ","
    ++ defs[16].schema
    ++ ","
    ++ defs[17].schema
    ++ ","
    ++ defs[18].schema
    ++ ","
    ++ defs[19].schema
    ++ ","
    ++ defs[20].schema
    ++ ","
    ++ defs[21].schema
    ++ ","
    ++ defs[22].schema
    ++ ","
    ++ defs[23].schema
    ++ ","
    ++ defs[24].schema
    ++ ","
    ++ defs[25].schema
    ++ ","
    ++ defs[26].schema
    ++ ","
    ++ defs[27].schema
    ++ ","
    ++ defs[28].schema
    ++ ","
    ++ defs[29].schema
    ++ ","
    ++ defs[30].schema
    ++ ","
    ++ defs[31].schema
    ++ ","
    ++ defs[32].schema
    ++ ","
    ++ defs[33].schema
    ++ ","
    ++ defs[34].schema
    ++ ","
    ++ defs[35].schema
    ++ "]";

pub const toolsJsonReadOnlyBlob: []const u8 = "["
    ++ defs[0].schema
    ++ ","
    ++ defs[5].schema
    ++ ","
    ++ defs[6].schema
    ++ ","
    ++ defs[7].schema
    ++ ","
    ++ defs[10].schema
    ++ ","
    ++ defs[11].schema
    ++ ","
    ++ defs[12].schema
    ++ ","
    ++ defs[17].schema
    ++ ","
    ++ defs[18].schema
    ++ ","
    ++ defs[19].schema
    ++ ","
    ++ defs[20].schema
    ++ ","
    ++ defs[21].schema
    ++ ","
    ++ defs[22].schema
    ++ ","
    ++ defs[23].schema
    ++ ","
    ++ defs[24].schema
    ++ ","
    ++ defs[25].schema
    ++ ","
    ++ defs[26].schema
    ++ ","
    ++ defs[27].schema
    ++ ","
    ++ defs[29].schema
    ++ ","
    ++ defs[31].schema
    ++ ","
    ++ defs[32].schema
    ++ ","
    ++ defs[33].schema
    ++ ","
    ++ defs[34].schema
    ++ ","
    ++ defs[35].schema
    ++ "]";

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
    // Unknown tools are conservative: they need permission.
    try std.testing.expect(needsPermission("no_such_tool"));
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
