// TEMPORARY aggregator so the lsp modules can be built and tested on their own.
// Folded into src/test_all.zig once the layout is stable.
pub const protocol = @import("lsp/protocol.zig");
pub const servers = @import("lsp/servers.zig");
pub const format = @import("lsp/format.zig");
pub const client = @import("lsp/client.zig");
pub const process = @import("lsp/process.zig");
pub const manager = @import("lsp/manager.zig");
pub const lsp_tool = @import("tools/lsp.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
