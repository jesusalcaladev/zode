//! Session search (facade).
//! Implementation lives in `session/search.zig`; this path is kept stable for importers.

const impl = @import("session/search.zig");

pub const crop_window = impl.crop_window;
pub const crop_threshold = impl.crop_threshold;
pub const SessionHit = impl.SessionHit;
pub const sessionProse = impl.sessionProse;
pub const searchTitle = impl.searchTitle;
pub const searchTranscript = impl.searchTranscript;
pub const rankHits = impl.rankHits;
pub const searchSessions = impl.searchSessions;

test {
    _ = impl;
}
