const std = @import("std");
const tui = @import("../tui.zig");
const agent_types = @import("types.zig");
const chat_dispatch = @import("chat_dispatch.zig");

pub const ChatJob = agent_types.ChatJob;

pub fn startChatImplEx(
    m: *tui.Model,
    input: []const u8,
    mode: ChatJob.Mode,
    bash_allow_rules: []const []const u8,
    expand_cmdsubst: bool,
    comptime worker: fn (*ChatJob) void,
    comptime set_thinking: fn (*tui.Model) void,
) !void {
    const full_input = input;
    const copy = try m.allocator.dupe(u8, full_input);
    errdefer m.allocator.free(copy);
    return chat_dispatch.startQueuedOrSpawn(
        ChatJob,
        m,
        copy,
        mode,
        bash_allow_rules,
        expand_cmdsubst,
        worker,
        set_thinking,
    );
}
