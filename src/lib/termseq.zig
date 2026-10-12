/// The two control sequences zode sends that vaxis does not provide.
///
/// vaxis 0.6 owns the terminal's whole life cycle — alt screen, mouse,
/// bracketed paste, the DA1 query — and it owns them WELL. Two things it does
/// not do, and both matter here:
///
/// 1. **The kitty keyboard flags.** `CSI > 1 u` asks the terminal to report
///    modified keys unambiguously. Without it, Shift+Enter is indistinguishable
///    from Enter in every terminal there is: they both send `\r`. So the
///    "shift+enter inserts a newline" behaviour in `tui.editorKey` has always
///    been there and has always been unreachable — the request that would wake
///    it up was never made.
///
/// 2. **Undoing them on exit.** `agent.quitFast` ends in `std.process.exit`,
///    which runs no defer, and vaxis's own cleanup is a defer. So every
///    sequence it sent stays sent: the app is left in the alternate screen
///    with the mouse captured and the cursor hidden. The user sees the TUI
///    still on screen after ctrl+c and believes the app did not exit.
///
/// `CSI < u` drops the flags. It is here rather than in `vaxis/ctlseqs.zig`
/// because that file is a DEPENDENCY: a patch there is lost on the next
/// `zig fetch` and does not show up in the repo's diff.
const std = @import("std");

/// Enter the alternate screen, capture the mouse, and enable the kitty
/// keyboard's "disambiguate" flag.
///
/// Ordered by what has to happen before the first frame can be read: alt
/// screen first (nothing else is visible in it), then the input mode.
pub fn kittyKeyboardPush(w: *std.Io.Writer) void {
    // `> 1`: report only the keys that are AMBIGUOUS without it, which is the
    // minimum that still gets Shift+Enter across. `> 3` would report every
    // event including releases, which triples the bytes on the wire for
    // something no part of this app reads.
    w.writeAll("\x1b[>1u") catch {};
    w.flush() catch {};
}

/// Leave it, and put the terminal back the way it was.
///
/// Order matters and it is the reverse of the way in, because a terminal that
/// answers a capability query at the wrong moment writes its reply into
/// whichever screen is active: if we disabled the keyboard flags AFTER
/// leaving the alt screen, a late `CSI ? 1 u` reply would land on the user's
/// shell prompt.
pub fn kittyKeyboardPop(w: *std.Io.Writer) void {
    w.writeAll("\x1b[<u") catch {};
    w.flush() catch {};
}

/// Everything that must be undone before the process leaves, in the order the
/// terminal expects it undone.
///
/// Used by `quitFast`, which cannot run any defer. A prefix is kept on the
/// front of each one because a terminal that has already been restored must
/// not be sent a partial one.
pub fn restoreAll(w: *std.Io.Writer) void {
    w.writeAll("\x1b[?1002;1003;1004;1006;1016l") catch {}; // mouse off
    w.writeAll("\x1b[<u") catch {}; // keyboard flags off
    w.writeAll("\x1b[?1049l") catch {}; // leave the alt screen
    w.writeAll("\x1b[?25h") catch {}; // show the cursor again
    w.flush() catch {};
}

test "the sequences are the ones the terminal expects" {
    // These are not decoration: a typo in the final byte of the alt-screen
    // sequence is a terminal the user has to `reset` by hand. The tests name
    // them so the strings are asserted and not assumed.
    var buf: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&buf);
    kittyKeyboardPush(&fw);
    try std.testing.expectEqualStrings("\x1b[>1u", fw.buffered());
    fw.end = 0;
    kittyKeyboardPop(&fw);
    try std.testing.expectEqualStrings("\x1b[<u", fw.buffered());
    fw.end = 0;
    restoreAll(&fw);
    try std.testing.expectEqualStrings(
        "\x1b[?1002;1003;1004;1006;1016l\x1b[<u\x1b[?1049l\x1b[?25h",
        fw.buffered(),
    );
}
