//! The `worktree` tool's schema (Phase 18): enter/exit an isolated git
//! worktree, and show the current one. ONLY call this when the user ASKS for
//! an isolated worktree — a branch is what a branch is for.
const validate = @import("validate.zig");

pub const name = "worktree";

pub const description: []const u8 =
    "Work in an isolated git worktree under .zode/worktrees. ONLY call this when the USER explicitly asks to work in an isolated worktree — never proactively; a branch is what a branch is for. operation=enter with a name creates a worktree and switches this session's cwd to it (a second enter is refused until you exit). operation=exit keeps the tree by default, or removes it with remove=true; removing a DIRTY tree is refused with the list of changes unless discard=true is explicit. operation=status reports the active worktree. Outside a git repository the call is a clear no-op. Switching resets project instructions, skills, agent definitions, permissions, plan and session caches so two trees never mix.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"enter|exit|status\"},\"name\":{\"type\":\"string\",\"description\":\"worktree name, for enter\"},\"remove\":{\"type\":\"boolean\",\"description\":\"on exit, remove the tree instead of keeping it\"},\"discard\":{\"type\":\"boolean\",\"description\":\"allow removing a dirty tree (explicit; lists what is lost)\"}},\"required\":[\"operation\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "worktree: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
