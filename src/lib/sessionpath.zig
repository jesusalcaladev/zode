//! Session path resolution and project scoping (facade).
//! Implementation lives in `session/path.zig`; this path is kept stable for importers.

const impl = @import("session/path.zig");

pub const legacy_sessions_dir = impl.legacy_sessions_dir;
pub const sessions_dir_mode = impl.sessions_dir_mode;
pub const session_mode = impl.session_mode;
pub const OsTag = impl.OsTag;
pub const currentOs = impl.currentOs;
pub const stateDir = impl.stateDir;
pub const stateDirFor = impl.stateDirFor;
pub const projectHash = impl.projectHash;
pub const projectSessionsDir = impl.projectSessionsDir;
pub const resolveSessionsDir = impl.resolveSessionsDir;
pub const isSessionFile = impl.isSessionFile;
pub const sessionBelongsToProject = impl.sessionBelongsToProject;

test {
    _ = impl;
}
