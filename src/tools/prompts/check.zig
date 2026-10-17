//! The `check` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const std = @import("std");
const validate = @import("validate.zig");

pub const name = "check";

pub const description: []const u8 =
    "Typecheck THIS project in the background and report errors with a file and a line. You do not have to know the command: build.zig means zig build, Cargo.toml means cargo check, tsconfig.json means tsc --noEmit, go.mod means go build, pyproject/setup.py means a Python syntax check, etc. Pass subdir to check a project that lives in a subdirectory — a monorepo has several, and this looks in one place at a time. USE IT WHEN: you have edited code and want to know whether it compiles before writing more. USE INSTEAD OF: bash zig build — it saves the round trip of guessing the command, never blocks your input, and you keep working while it runs. EFFICIENCY: starts in the background; call it with no arguments, keep going, then read it with check id (or bash_output). It reports type errors you cannot see by reading. LIMITS: if the project has no known marker file, it tells you to run the project's own checker with bash. A failed exit with no diagnostics is reported as a failure with the output tail — it never lies and says no type errors on a broken build. ON ERROR: no typecheck is known -> use bash with the project's command.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"the job id a previous call returned\"},\"subdir\":{\"type\":\"string\",\"description\":\"where to look for the project's marker files; default: the current directory, use it for a subproject in a monorepo\"}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "check: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}

test "check: subdir is declared, so the capability is reachable" {
    // The gap this closes: `toolCheck` reads `subdir` (default `.`) to find a
    // monorepo's subproject, a dispatcher test already exercised it, and the schema
    // never declared it. Nothing was broken — the capability was invisible.
    try std.testing.expect(std.mem.indexOf(u8, description, "subdir") != null);
    try std.testing.expect(std.mem.indexOf(u8, parameters, "\"subdir\"") != null);
}
