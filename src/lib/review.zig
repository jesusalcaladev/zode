//! The review step: what the model is told to look for in its own diff.
//!
//! ## Why a LIST and not a paragraph
//!
//! A review is the one part of an agent's work that does not have a command behind it.
//! The exit gate can read an exit code and decide; nothing can read a diff and say "this
//! is wrong". So the harness cannot JUDGE the change — all it can do is hand the model
//! its own work back and be explicit about the handful of things worth looking at, which
//! is what a senior engineer does when they say "have you looked at this?".
//!
//! Which means the list is the product. A vague "review your work" produces a rubber
//! stamp, because there is nothing to fail at. Every entry below is something that has
//! actually gone wrong in a diff, and each one is checkable by reading one hunk.
//!
//! ## Why it is pure
//!
//! The same reason as the exit gate: two runners exist (`zode` and `zode --chat`) and a
//! rule that lives in one of them drifts from the other. This text is asserted with no
//! TUI, no network and no terminal.

const std = @import("std");

/// One thing to look for, and WHY it is on the list.
///
/// `why` is not a comment: it goes in the text the model reads, and the reason is the
/// part that makes a checklist actionable. "no debug prints left behind" is a rule to
/// obey; "a print you added is the most common thing in a diff that was never meant to
/// ship" is a reason to go looking.
pub const Item = struct {
    what: []const u8,
    why: []const u8,
};

/// The checklist. Ordered by how often it catches something real.
pub const items = [_]Item{
    .{
        .what = "A change in a file the task did not mention",
        .why = "the edit went somewhere you did not intend, and it compiles anyway",
    },
    .{
        .what = "A leftover debug print, a commented-out block, or a TODO you added",
        .why = "these are in nearly every diff that was never re-read",
    },
    .{
        .what = "A function whose name no longer matches what it does",
        .why = "the edit changed the behaviour and the name is now a lie the next reader has to catch",
    },
    .{
        .what = "A test that was weakened, deleted, or made to accept anything",
        .why = "a red test fixed this way is a bug that comes back, and the diff is the only place it shows",
    },
    .{
        .what = "The same logic written twice instead of once",
        .why = "two copies of a rule is one copy that gets updated and one that does not",
    },
    .{
        .what = "An error swallowed, ignored, or downgraded to a warning",
        .why = "this is how a red build gets made to look green, and it is invisible to the compiler",
    },
    .{
        .what = "A change wider than the task asked for",
        .why = "unrelated edits inside a fix are how a review turns into an archaeology dig",
    },
    .{
        .what = "The original report, and whether the behaviour actually changed",
        .why = "code that compiles while the bug is still there is the most expensive thing to hand back",
    },
};

/// The text the model reads after its own diff.
///
/// It says what the harness has ALREADY done, so the model does not re-run a check the
/// harness ran twenty seconds ago, and it says what the harness CANNOT do, so the model
/// does not assume that being handed a diff is the same as having reviewed it.
pub fn checklist(gpa: std.mem.Allocator, files: []const []const u8, bytes: usize) ![]u8 {
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(gpa);
    try w.print(gpa, "You asked to review your own change. {d} file(s) you changed this turn, about {d} bytes of diff, are above.\n\n", .{ files.len, bytes });

    try w.print(gpa, "The harness has ALREADY checked that this compiles, and it will not end the turn over a red build. Do not spend this call re-running the compiler. What it cannot check is you:\n\n", .{});

    for (items, 0..) |it, i| {
        try w.print(gpa, " {d}. {s}\n    ({s})\n", .{ i + 1, it.what, it.why });
    }

    try w.print(gpa,
        \\
        \\Then answer in a few lines, in this order:
        \\ - anything on the list you found, with file and line;
        \\ - what you changed in response, or why you are leaving it;
        \\ - anything you are still unsure about.
        \\
        \\If you found nothing, say so in one line and name what you looked at. "Nothing
        \\to report" after a real read is a useful answer; it is only worthless when it
        \\is what you would have said without reading.
        \\
    , .{});
    return w.items;
}

/// The gate's line when the review is missing.
///
/// It names the count of uncovered edits because that is the number that tells the model
/// whether it is one file behind or five, and it says what to do and not only what is
/// wrong.
pub fn missingText(gpa: std.mem.Allocator, unreviewed: u32) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\Your turn cannot end yet: {d} file edit(s) you made have not been reviewed.
        \\Call `review` and read your own diff. It is one call and it costs no wall
        \\clock: the harness already knows whether the code compiles, and the review is
        \\about whether it is the change you meant to make.
    , .{unreviewed});
}

/// The sentence for a project with no git, where there is no diff to review.
///
/// Same direction as `cannot_verify`: say the truth and let the turn go. A harness that
/// refuses to end a turn it cannot review is a harness that never ends a turn in a
/// project that is not a git repository, and that is a lot of projects.
pub const notARepoText =
    "This is not a git repository, so there is no diff to review and the harness cannot " ++
    "require one. Review your own work by reading back the files you changed.";

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "every checklist entry says WHY, because the reason is the actionable half" {
    // A list of imperatives ("no debug prints") is a rule to obey and nothing to fail
    // at, which is how "review your work" becomes a rubber stamp. Each `why` is what
    // sends the model looking at the diff, so an entry without one does not work.
    for (items, 0..) |it, i| {
        if (it.what.len < 10) {
            std.debug.print("entry {d} says nothing checkable: {s}\n", .{ i, it.what });
            return error.EntryTooVague;
        }
        if (it.why.len < 20) {
            std.debug.print("entry {d} has no reason: {s}\n", .{ i, it.what });
            return error.EntryHasNoWhy;
        }
        // And it must not be the entry's own `what` restated, which is the failure mode
        // of a rule dressed up as a reason.
        if (std.mem.indexOf(u8, it.why, it.what) != null) {
            std.debug.print("entry {d}'s reason just repeats the rule: {s}\n", .{ i, it.why });
            return error.EntryWhyEchoesWhat;
        }
    }
}

test "the checklist is long enough to be worth a call, and short enough to be read" {
    // Below four it is a gesture. Above about a dozen the model skims the bottom of it,
    // and a skimmed checklist is a worse use of a round trip than no checklist at all.
    try t.expect(items.len >= 4);
    try t.expect(items.len <= 12);
}

test "the checklist tells the model what the harness already did, so it does not redo it" {
    var st = std.heap.ArenaAllocator.init(t.allocator);
    defer st.deinit();
    const a = st.allocator();

    const files = [_][]const u8{ "src/a.zig", "src/b.zig" };
    const out = try checklist(a, &files, 4096);

    // Every item is in there, in order, numbered from one.
    for (items, 0..) |it, i| {
        var needle: [96]u8 = undefined;
        const n = try std.fmt.bufPrint(&needle, "{d}. {s}", .{ i + 1, it.what });
        try t.expect(std.mem.indexOf(u8, out, n) != null);
    }
    // The reason travels with the item, because the reason is the part that works.
    try t.expect(std.mem.indexOf(u8, out, items[0].why) != null);

    // It says the build is already done — otherwise the model spends its one review call
    // re-running a compiler the harness ran twenty seconds ago.
    try t.expect(std.mem.indexOf(u8, out, "ALREADY checked") != null);
    try t.expect(std.mem.indexOf(u8, out, "re-running the compiler") != null);
    // And it refuses the cheap answer, which is the whole failure mode of a step the
    // model can satisfy by saying "looks good".
    try t.expect(std.mem.indexOf(u8, out, "without reading") != null);
    // And the counts are real numbers, not placeholders.
    try t.expect(std.mem.indexOf(u8, out, "2 file(s)") != null);
    try t.expect(std.mem.indexOf(u8, out, "4096 bytes") != null);
}

test "the missing-review line says what to do, not only what is wrong" {
    var st = std.heap.ArenaAllocator.init(t.allocator);
    defer st.deinit();
    const a = st.allocator();

    const msg = try missingText(a, 3);
    try t.expect(std.mem.indexOf(u8, msg, "3 file edit(s)") != null);
    // It names the call. A refusal without an exit is a dead end, and the model's only
    // remaining move would be to give up.
    try t.expect(std.mem.indexOf(u8, msg, "`review`") != null);
    try t.expect(std.mem.indexOf(u8, msg, "costs no wall") != null);
}

test "a project with no git is told so, and is NOT blocked forever" {
    // The direction that is safe to be wrong in: a harness that cannot review must say
    // so and let the turn go. One that waits forever for a review it can never obtain
    // never ends a turn in a non-git project, and that is a lot of projects.
    try t.expect(std.mem.indexOf(u8, notARepoText, "cannot require one") != null);
    try t.expect(std.mem.indexOf(u8, notARepoText, "not a git repository") != null);
}
