//! The MCP servers zode is allowed to talk to.
//!
//! A TABLE, not a discovery mechanism: the command that gets spawned is fixed
//! here and is never chosen by the model. That is the property that lets the
//! `mcp` tool run without a dialog for the parts that only READ (a server's
//! catalogue is the user's own configuration, and looking at it changes
//! nothing), and it is the same property that makes `lsp` permission-free.
//!
//! The servers come from the USER's `~/.config/zode/config.json` and not from
//! the repository. A `.mcp.json` inside a project is a file the project
//! controls, and a server is a program: honouring one from a clone is remote
//! code execution with the user's credentials. zode already treats
//! `.mcp.json` as a file the model must not write (`lib/pathsafe.zig`), and
//! the honest reading of that is that the harness is the one that decides
//! which servers run — so the decision is the user's, in their own config.
//!
//! Pure: no process, no clock, no filesystem.

const std = @import("std");

/// One MCP server, as the user configured it.
pub const Server = struct {
    /// The name the model uses to address it (`mcp_call` names it).
    name: []const u8,
    /// The argv to run. `command[0]` is looked up in `PATH`.
    command: []const []const u8,
    /// Extra environment variables for the server.
    env: []const EnvVar = &.{},
};

/// One environment variable for a server.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// Is this an environment variable name a process can be given?
///
/// `Environ.Map.put` ASSERTS on a name with an `=` in it and on an empty
/// name, and an assert in a server's configuration is a crash the user cannot
/// do anything about, so the check happens here, where a bad entry can be
/// skipped with a message.
pub fn validEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c == '=' or c == 0) return false;
    }
    return true;
}

/// The default number of tools a search returns.
///
/// Five is the number the reference implementation uses, and the reason is
/// not politeness: a search that returns forty tools is a list the model has
/// to read before it can choose, and the schemas are the expensive part. The
/// count of what was NOT shown is in the answer, so the model knows to search
/// again with a different word instead of assuming it saw everything.
pub const max_search_results: usize = 5;
