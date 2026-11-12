const SummaryBreaker = @import("../lib/summary_breaker.zig").SummaryBreaker;

pub const summary_gap: usize = 6;
pub const summary_max: usize = 3;

pub var summaries_done: usize = 0;
pub var summarized_at_iteration: usize = 0;
var summary_breaker: SummaryBreaker = .{};

pub fn tripped() bool { return summary_breaker.tripped(); }
pub fn noteSuccess() void { summary_breaker.noteSuccess(); }
pub fn resetBreaker() void { summary_breaker.reset(); }

pub fn maySummarize(iteration: usize) bool {
    if (summary_breaker.tripped()) return false;
    if (summaries_done >= summary_max) return false;
    if (summaries_done == 0) return true;
    return iteration >= summarized_at_iteration + summary_gap;
}

pub fn noteSummarized(iteration: usize) void {
    summaries_done += 1;
    summarized_at_iteration = iteration;
    summary_breaker.noteSuccess();
}

pub fn noteFailure() void {
    summary_breaker.noteFailure();
}

pub fn resetSummaries() void {
    summaries_done = 0;
    summarized_at_iteration = 0;
    summary_breaker.reset();
}
