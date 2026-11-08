//! Diff tokenization and word-diff (facade).
//! Implementation lives in `diff/tokenizer.zig`; this path is kept stable for importers.

const impl = @import("diff/tokenizer.zig");

pub const Token = impl.Token;
pub const tokenizeCode = impl.tokenizeCode;
pub const Match = impl.Match;
pub const max_lcs_cells = impl.max_lcs_cells;
pub const lcsMatches = impl.lcsMatches;
pub const DiffRange = impl.DiffRange;
pub const WordDiff = impl.WordDiff;
pub const change_threshold = impl.change_threshold;
pub const wordDiff = impl.wordDiff;
pub const jaccard = impl.jaccard;
pub const jaccardIn = impl.jaccardIn;

test {
    _ = impl;
}
