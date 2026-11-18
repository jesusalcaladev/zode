//! The `bash` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const std = @import("std");
const validate = @import("validate.zig");

pub const name = "bash";

pub const description: []const u8 =
    "Run a shell command; returns stdout+stderr and the exit code. USE WHEN: a named suite, git, a script, or anything with no dedicated tool; use check for typechecking (never hand-type zig build / npx tsc / cargo check - check knows the command and reports file:line). SHELL: fresh each call - cd, export and variables do not carry over; chain dependent steps in ONE call with && (or ; when a later step must run even if an earlier one fails). NO PROMPTS: stdin is /dev/null and there is no terminal, so interactive flags, pagers, editors or password prompts hang until the timeout - pass non-interactive flags. SAFETY: git config is never modified; destructive git (reset --hard, checkout ., clean -f, push --force, branch -D) is never run unless the user asked this turn; hooks are never skipped (--no-verify); quote paths with spaces. Pass a one-line description of what the command is FOR - the user reads it next to the tool name instead of a clipped pipeline. EFFICIENCY: blocks by default; slow builds, suites and installs freeze input - pass run_in_background: true and poll bash_output once per step (slow verifications auto-background anyway). Do not sleep between commands or retry a failing one in a loop: read the error. timeout_seconds defaults to 30 and is a hard override (setting it disables auto-background); a command still running at the deadline is killed. LIMITS: output is cut at 16 KB and the command is stopped - the notice says so; re-run through head or a narrower scope for the rest. ON ERROR: exit code and stderr are shown; fix the cause instead of retrying the same line.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"description\":{\"type\":\"string\",\"description\":\"one line saying what the command is FOR, shown to the user in the timeline (e.g. running the test suite)\"},\"timeout_seconds\":{\"type\":\"integer\",\"description\":\"foreground only; default 30; setting it means you decided, so auto-background does not apply\"},\"run_in_background\":{\"type\":\"boolean\",\"description\":\"return a job id at once instead of waiting\"},\"sandbox\":{\"type\":\"boolean\",\"description\":\"run it inside a sandbox (bubblewrap or firejail) when one is installed: the filesystem is read-only except the project, and /tmp is empty. Use it for a command that deletes or changes things you are not sure about. It breaks the commands that need the network or a writable home, and no sandbox is installed everywhere\"}},\"required\":[\"command\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "bash: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}

test "bash: the schema offers a description field, and it is optional" {
    // A capability that is not in the schema does not get used (the lesson the
    // `task` tool taught): the timeline feature exists only if the model can
    // SEE the field. And `description` must stay optional — the whole point of
    // `required` is that a call with just a command still runs.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{});
    const params = v.object.get("function").?.object.get("parameters").?.object;
    const props = params.get("properties").?.object;
    const d = props.get("description") orelse {
        std.debug.print("bash's parameters have no description field\n", .{});
        return error.TestExpectedEqual;
    };
    // The property is a schema OBJECT (`{"type":"string", ...}`), not a bare
    // string: what is asserted is that it describes a string.
    if (d != .object or d.object.get("type") == null or
        !std.mem.eql(u8, d.object.get("type").?.string, "string"))
    {
        std.debug.print("bash's description field is not declared as a string\n", .{});
        return error.TestExpectedEqual;
    }
    for (params.get("required").?.array.items) |r| {
        try std.testing.expect(!std.mem.eql(u8, r.string, "description"));
    }
}
