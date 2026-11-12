const std = @import("std");
const tui = @import("../tui.zig");
const resultcap = @import("../lib/resultcap.zig");

pub const TurnCtx = struct {
    m: *tui.Model,
    /// Assistant text of this turn (dumped into the session at the end).
    text: std.ArrayList(u8) = .empty,
    /// Tool calls requested in this turn.
    calls: std.ArrayList(Call) = .empty,
    /// A tool in flight: its header is already painted and the line has to be
    /// closed.
    tool_open: bool = false,
    /// Stream chars, for the tok/s.
    chars: usize = 0,
    /// Moment of the first token (ns). 0 = nothing has arrived yet.
    stream_start_ns: i128 = 0,
    /// Rolling window for the LIVE tok/s.
    tps_win_ns: i128 = 0,
    tps_win_chars: usize = 0,
    /// Finish reason of the request.
    finish: [32]u8 = undefined,
    finish_len: usize = 0,

    pub const Call = struct {
        id: []const u8,
        name: []const u8,
        args_json: []const u8,
    };

    pub fn deinit(self: *TurnCtx) void {
        const gpa = self.m.allocator;
        for (self.calls.items) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
            gpa.free(c.args_json);
        }
        self.calls.deinit(gpa);
        self.text.deinit(gpa);
    }

    pub fn finishSlice(self: *const TurnCtx) []const u8 {
        return self.finish[0..self.finish_len];
    }
};

/// Budget for tool results of one assistant message.
pub const ResultBudget = struct {
    used: usize = 0,

    pub fn capFor(self: *const ResultBudget, per_tool: usize) usize {
        const total = resultcap.max_results_per_message_chars;
        const left = if (self.used < total) total - self.used else 0;
        if (per_tool == 0) return left;
        return @min(per_tool, left);
    }

    pub fn charge(self: *ResultBudget, n: usize) void {
        self.used += n;
    }
};
