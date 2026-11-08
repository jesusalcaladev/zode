//! Session index/metadata scanning (facade).
//! Implementation lives in `session/index.zig`; this path is kept stable for importers.

const impl = @import("session/index.zig");

pub const Meta = impl.Meta;
pub const Entry = impl.Entry;
pub const usablePrompt = impl.usablePrompt;
pub const TitleHints = impl.TitleHints;
pub const titleHints = impl.titleHints;
pub const metaPath = impl.metaPath;
pub const readMeta = impl.readMeta;
pub const parseMeta = impl.parseMeta;
pub const writeMeta = impl.writeMeta;
pub const writeMetaTitles = impl.writeMetaTitles;
pub const scan = impl.scan;
pub const ageLabel = impl.ageLabel;

test {
    _ = impl;
}
