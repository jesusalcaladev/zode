//! Cache-break detection: compare the stable prefix actually sent with the
//! previous one, and report which block changed.
//!
//! Pure on purpose: no I/O, no TUI, no network. The blocks that compose the
//! system prompt are compared one by one, and the first one that differs is
//! reported with its name and byte position in the composed prefix.

const std = @import("std");

/// The eight blocks of the stable prefix, in composition order.
pub const Blocks = struct {
    base: []const u8,
    routing: []const u8,
    verification: []const u8,
    ask_guidance: []const u8,
    skills: []const u8,
    location: []const u8,
    mode_note: []const u8,
    style: []const u8,

    /// Returns the index of the first block that differs, or null if identical.
    pub fn firstDiff(self: *const Blocks, other: *const Blocks) ?usize {
        const a = &[_][]const u8{
            self.base, self.routing, self.verification, self.ask_guidance,
            self.skills, self.location, self.mode_note, self.style,
        };
        const b = &[_][]const u8{
            other.base, other.routing, other.verification, other.ask_guidance,
            other.skills, other.location, other.mode_note, other.style,
        };
        for (a, 0..) |block, i| {
            if (!std.mem.eql(u8, block, b[i])) return i;
        }
        return null;
    }
};

/// Names of the blocks, in composition order, for reporting.
pub const block_names = [_][]const u8{
    "base",
    "routing",
    "verification",
    "ask_guidance",
    "skills",
    "location",
    "mode_note",
    "style",
};

/// Compare two block snapshots and return the name of the first differing block,
/// or null if they are identical.
pub fn describeBreak(prev: *const Blocks, curr: *const Blocks) ?[]const u8 {
    const idx = prev.firstDiff(curr) orelse return null;
    return block_names[idx];
}

/// FNV-1a 64-bit hash of a block, for cheap change detection without storing
/// the full content.
pub fn hashBlock(data: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (data) |b| {
        h ^= @intCast(b);
        h ^= h << 13;
        h ^= h >> 7;
        h ^= h << 17;
    }
    return h;
}

/// Computes the byte offset of each block in the composed prefix.
///
/// The composition format is:
///   base\nrouting\nverificationask_guidancesectionlocation\nmode_note\nstyle
/// (verification, ask_guidance, skills and location are concatenated without
/// separators between them).
pub fn blockOffsets(blocks: *const Blocks) [8]usize {
    var offs: [8]usize = undefined;
    var pos: usize = 0;
    offs[0] = pos;
    pos += blocks.base.len + 1; // base + \n
    offs[1] = pos;
    pos += blocks.routing.len + 1; // routing + \n
    offs[2] = pos;
    pos += blocks.verification.len;
    offs[3] = pos;
    pos += blocks.ask_guidance.len;
    offs[4] = pos;
    pos += blocks.skills.len;
    offs[5] = pos;
    pos += blocks.location.len + 1; // location + \n
    offs[6] = pos;
    pos += blocks.mode_note.len + 1; // mode_note + \n
    offs[7] = pos;
    return offs;
}

// ── tests ─────────────────────────────────────────────────────

test "cachebreak: identical blocks report no break" {
    const b = Blocks{
        .base = "base",
        .routing = "routing",
        .verification = "verification",
        .ask_guidance = "ask",
        .skills = "skills",
        .location = "location",
        .mode_note = "mode",
        .style = "style",
    };
    try std.testing.expect(b.firstDiff(&b) == null);
    try std.testing.expect(describeBreak(&b, &b) == null);
}

test "cachebreak: change in the skills block reports skills" {
    var a = Blocks{
        .base = "base",
        .routing = "routing",
        .verification = "verification",
        .ask_guidance = "ask",
        .skills = "skills v1",
        .location = "location",
        .mode_note = "mode",
        .style = "style",
    };
    var b = Blocks{
        .base = "base",
        .routing = "routing",
        .verification = "verification",
        .ask_guidance = "ask",
        .skills = "skills v2",
        .location = "location",
        .mode_note = "mode",
        .style = "style",
    };
    const idx = a.firstDiff(&b) orelse return;
    try std.testing.expectEqual(@as(usize, 4), idx);
    try std.testing.expect(std.mem.eql(u8, block_names[4], "skills"));
}

test "cachebreak: change in the base block reports base" {
    var a = Blocks{
        .base = "base v1",
        .routing = "routing",
        .verification = "verification",
        .ask_guidance = "ask",
        .skills = "skills",
        .location = "location",
        .mode_note = "mode",
        .style = "style",
    };
    var b = Blocks{
        .base = "base v2",
        .routing = "routing",
        .verification = "verification",
        .ask_guidance = "ask",
        .skills = "skills",
        .location = "location",
        .mode_note = "mode",
        .style = "style",
    };
    try std.testing.expectEqual(@as(usize, 0), a.firstDiff(&b) orelse @as(usize, 99));
}

test "cachebreak: blockOffsets computes positions" {
    const b = Blocks{
        .base = "hello",
        .routing = "route",
        .verification = "verify",
        .ask_guidance = "ask",
        .skills = "skills",
        .location = "loc",
        .mode_note = "mode",
        .style = "style",
    };
    const offs = blockOffsets(&b);
    try std.testing.expectEqual(@as(usize, 0), offs[0]); // base at 0
    try std.testing.expectEqual(@as(usize, 6), offs[1]); // "hello\n" = 6
    try std.testing.expectEqual(@as(usize, 12), offs[2]); // "route\n" = 6 more
    try std.testing.expectEqual(@as(usize, 18), offs[3]); // "verify" ends at 18
    try std.testing.expectEqual(@as(usize, 21), offs[4]); // "ask" ends at 21
    try std.testing.expectEqual(@as(usize, 27), offs[5]); // "skills" ends at 27
    try std.testing.expectEqual(@as(usize, 31), offs[6]); // "loc\n" ends at 31
    try std.testing.expectEqual(@as(usize, 36), offs[7]); // "mode\n" = 5 more
}

test "cachebreak: hashBlock is deterministic and differs for different content" {
    try std.testing.expectEqual(hashBlock("abc"), hashBlock("abc"));
    try std.testing.expect(hashBlock("abc") != hashBlock("abd"));
    try std.testing.expect(hashBlock("") != hashBlock("a"));
}