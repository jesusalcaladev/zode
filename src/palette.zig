const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("lib/theme.zig");
const tui = @import("tui.zig");

const Painter = tui.Painter;

/// Modal palette of commands and models, in the style of opencode.
///
/// Two modes:
///   - `.commands`: grouped list of commands with the shortcut on the right.
///   - `.models`:   TWO COLUMNS. The left one holds the providers (with their
///                  key state) and the right one the models of the highlighted
///                  provider. That is what opencode does: provider -> models.
///
/// The module knows nothing about providers, networking or sessions: whoever
/// opens it passes in the list of `Item` and gets back the selection. That
/// makes it testable without a network and keeps drawing separate from data.
///
/// Important invariant: `sel[c]` indexes `filtered[c]`, NEVER `items`. Before
/// this note existed, the drawing filtered on the fly while the selection
/// counted on the full list, and with any filter the highlight went to the
/// wrong row.
pub const Mode = enum {
    commands,
    models,
    /// Connect modal: providers column + "Connect an integration".
    connect,
    /// Typing a provider's API key.
    key_prompt,
};

pub const Kind = enum {
    command,
    provider,
    model,
    /// "Connect an integration": asks for the key of the provider in the row.
    connect,
};

pub const Item = struct {
    kind: Kind,
    /// Group header index (0 = no group). The value is an index
    /// +1 over `groups`.
    group: u8 = 0,
    label: []const u8 = "",
    /// Right column: keyboard shortcut, "free", price…
    hint: []const u8 = "",
    /// Context window of a model, in tokens (0 = the provider does not publish
    /// it, or this is not a model row).
    ///
    /// It is here because the palette is the ONLY place that ever holds the
    /// downloaded catalogue: the worker builds the items and the draw collects
    /// them, so a `models_mod.Model` never survives long enough to be consulted
    /// later. Without this field `context_length` was computed in
    /// `buildModelItems`, formatted into the hint as "200k" and thrown away —
    /// and the compaction budget had no way to learn it. It is a plain integer
    /// and NOT a pointer into the catalogue, because the items outlive the
    /// worker's arena: same dangling-pointer family the labels would fall into.
    ctx_tokens: u32 = 0,
};

pub const Group = struct {
    name: []const u8,
};

pub const max_query = 64;
pub const max_key = 128;

pub const Palette = struct {
    gpa: std.mem.Allocator,
    active: bool = false,
    mode: Mode = .commands,

    /// Search filter (the modal's "search" line).
    query: [max_query]u8 = undefined,
    query_len: usize = 0,

    /// Active column in models mode: 0 = providers, 1 = models.
    col: u8 = 1,
    sel: [2]usize = .{ 0, 0 },
    scroll: [2]usize = .{ 0, 0 },
    /// Indices (into `items`) that survive the filter, one per column.
    filtered: [2]std.ArrayList(u32) = .{ .empty, .empty },

    /// Data filled in by whoever opens the palette.
    items: []const Item = &.{},
    groups: []const Group = &.{},
    /// Does the palette own `items` (and their strings)? If so, it frees them
    /// when replacing them. `setItemsOwned` sets this.
    owns_items: bool = false,

    /// `.key_prompt` mode.
    key_item: u32 = 0,
    key_return_mode: Mode = .connect,
    key_input: [max_key]u8 = undefined,
    key_len: usize = 0,
    key_msg: [96]u8 = undefined,
    key_msg_len: usize = 0,
    /// Whether `key_msg` is an error, set by whoever set it. See
    /// `keyMessageIsError`.
    key_msg_error: bool = false,
    /// Custom title for models mode (e.g., to show current mode like free-auto, plan, etc.)
    custom_title: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator) Palette {
        return .{ .gpa = gpa };
    }

    test "key prompt escape returns to the palette it came from" {
        var pal = Palette.init(t.allocator);
        defer pal.deinit();
        const items = [_]Item{
            .{ .kind = .provider, .label = "openrouter" },
        };
        pal.mode = .connect;
        pal.active = true;
        pal.setItems(&items, &.{});

        _ = handleKey(&pal, .{ .codepoint = 13 });
        try t.expectEqual(Mode.key_prompt, pal.mode);
        _ = handleKey(&pal, .{ .codepoint = 27 });
        try t.expectEqual(Mode.connect, pal.mode);

        pal.mode = .models;
        pal.key_return_mode = .models;
        pal.mode = .key_prompt;
        _ = handleKey(&pal, .{ .codepoint = 27 });
        try t.expectEqual(Mode.models, pal.mode);
    }

    test "model palette connect item opens the provider connection flow" {
        var pal = Palette.init(t.allocator);
        defer pal.deinit();
        const items = [_]Item{
            .{ .kind = .connect, .label = "+ connect" },
        };
        pal.mode = .models;
        pal.setItems(&items, &.{});
        pal.col = 0;
        try t.expect(std.meta.activeTag(handleKey(&pal, .{ .codepoint = 13 })) == .open_connect);
    }

    pub fn deinit(self: *Palette) void {
        self.filtered[0].deinit(self.gpa);
        self.filtered[1].deinit(self.gpa);
        if (self.custom_title.len > 0) {
            self.gpa.free(self.custom_title);
            self.custom_title = "";
        }
    }

    pub fn queryText(self: *const Palette) []const u8 {
        return self.query[0..self.query_len];
    }
    pub fn keyText(self: *const Palette) []const u8 {
        return self.key_input[0..self.key_len];
    }
    pub fn keyMessage(self: *const Palette) []const u8 {
        return self.key_msg[0..self.key_msg_len];
    }

    pub fn setKeyMessage(self: *Palette, msg: []const u8, is_error: bool) void {
        const n = @min(msg.len, self.key_msg.len);
        @memcpy(self.key_msg[0..n], msg[0..n]);
        self.key_msg_len = n;
        self.key_msg_error = is_error;
    }

    /// Formatted message (the callers come from `agent`, which cannot touch the
    /// palette's buffer directly).
    pub fn setKeyMessagef(self: *Palette, comptime fmt: []const u8, args: anytype, is_error: bool) void {
        const s = std.fmt.bufPrint(&self.key_msg, fmt, args) catch return;
        self.key_msg_len = s.len;
        self.key_msg_error = is_error;
    }

    /// Is the current key message an error? Set by whoever set it.
    pub fn keyMessageIsError(self: *const Palette) bool {
        return self.key_msg_error;
    }

    /// Index (into `items`) of the highlighted provider in the left column, or
    /// null if there is none. Ctrl+A uses it to know who the key is for.
    pub fn providerHighlighted(self: *const Palette) ?u32 {
        if (self.mode != .models) return null;
        const f = self.filtered[0].items;
        if (self.sel[0] >= f.len) return null;
        const idx = f[self.sel[0]];
        if (self.items[idx].kind != .provider) return null;
        return idx;
    }

    /// Item of the current column? In models mode column 0 is providers.
    pub fn column(self: *const Palette) usize {
        return if (self.mode == .models) self.col else 0;
    }

    /// Is it a single-column modal? (commands, connect, key)
    pub fn isSingleColumn(self: *const Palette) bool {
        return self.mode != .models;
    }

    /// Highlighted item of the current column, or null.
    pub fn selected(self: *const Palette) ?Item {
        const c = self.column();
        const f = self.filtered[c].items;
        if (self.sel[c] >= f.len) return null;
        return self.items[f[self.sel[c]]];
    }

    /// Same, by explicit column (for the test and for the drawing).
    pub fn selectedIn(self: *const Palette, c: usize) ?Item {
        const f = self.filtered[c].items;
        if (self.sel[c] >= f.len) return null;
        return self.items[f[self.sel[c]]];
    }

    pub fn countIn(self: *const Palette, c: usize) usize {
        return self.filtered[c].items.len;
    }

    /// Loads a new list and refilters. The caller keeps `items` and `groups`
    /// alive (they are from its arena or the model's allocator).
    pub fn setItems(self: *Palette, items: []const Item, groups: []const Group) void {
        self.setItemsBorrowed(items, groups);
    }

    /// Same as `setItems` but the palette becomes the owner of `items` (and of
    /// their strings) and frees those of the previous list when replacing them.
    ///
    /// Important for the models worker: if it handed over a slice of
    /// `models_mod.Model` and freed the list right after, the `id` of the items
    /// would be dangling pointers and the drawing blew up with
    /// `InvalidStartByte` when painting the models column.
    pub fn setItemsBorrowed(self: *Palette, items: []const Item, groups: []const Group) void {
        self.releaseItems();
        self.items = items;
        self.owns_items = false;
        self.groups = groups;
        self.resetSelection();
    }

    pub fn setItemsOwned(self: *Palette, items: []Item, groups: []const Group) void {
        self.releaseItems();
        self.items = items;
        self.owns_items = true;
        self.groups = groups;
        self.resetSelection();
    }

    fn resetSelection(self: *Palette) void {
        self.sel = .{ 0, 0 };
        self.scroll = .{ 0, 0 };
        // In `.connect` the single list is column 0; in `.models` we start on
        // the models one, which is the one you come to look at.
        self.col = if (self.mode == .models) 1 else 0;
        self.refilter();
    }

    /// Refills both filtered lists. One column, two: in models mode 0 is
    /// providers (`provider`/`connect`) and 1 is `model`. In commands mode
    /// everything goes to column 0.
    pub fn refilter(self: *Palette) void {
        const q = self.queryText();
        // In `.connect` mode EVERYTHING goes to column 0 (it is a single list),
        // so it behaves like `.commands` but with the provider items.
        const single = self.mode == .commands or self.mode == .connect or self.mode == .key_prompt;
        // In two-column mode filter ONLY the focused one. Filtering both left
        // the other blank when searching, which gave the impression that the
        // models list did not exist: you typed "sonnet" and did not see a single
        // model, only "no matches" in both columns.
        const focus = self.column();
        for (0..2) |c| {
            self.filtered[c].clearRetainingCapacity();
            for (self.items, 0..) |it, i| {
                const in_col: bool = if (single)
                    c == 0
                else if (c == 0)
                    (it.kind == .provider or it.kind == .connect)
                else
                    (it.kind == .model);
                if (!in_col) continue;
                if (!single and c != focus and q.len > 0) {
                    self.filtered[c].append(self.gpa, @intCast(i)) catch return;
                    continue;
                }
                if (!matches(it, self.groups, q)) continue;
                self.filtered[c].append(self.gpa, @intCast(i)) catch return;
            }
        }
        for (0..2) |c| {
            if (self.sel[c] >= self.filtered[c].items.len) {
                self.sel[c] = if (self.filtered[c].items.len == 0) 0 else self.filtered[c].items.len - 1;
            }
            if (self.scroll[c] > self.sel[c]) self.scroll[c] = self.sel[c];
        }
    }

    pub fn move(self: *Palette, c: usize, delta: isize) void {
        const n = self.filtered[c].items.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.sel[c]);
        var next = cur + delta;
        if (next < 0) next = 0;
        if (next >= @as(isize, @intCast(n))) next = @as(isize, @intCast(n)) - 1;
        self.sel[c] = @intCast(next);
    }

    /// Keeps the selected row inside the window.
    ///
    /// The scroll is in ROWS (the list is drawn with the group headers inside
    /// it, so an item's row is not its index) and `sel_row` is the row of the
    /// selected item in that space. `total_rows` is how many rows the whole
    /// column has.
    ///
    /// The old version clamped on the ITEM index against a window measured in
    /// rows, and the mismatch showed up as a highlight that vanished one row
    /// before the end of the list.
    pub fn clampScrollRows(self: *Palette, c: usize, total_rows: usize, visible: usize, sel_row: ?usize) void {
        if (visible == 0) return;
        const sr = sel_row orelse return;
        if (sr < self.scroll[c]) self.scroll[c] = sr;
        if (sr >= self.scroll[c] + visible) self.scroll[c] = sr - visible + 1;
        if (total_rows > visible and self.scroll[c] > total_rows - visible) {
            self.scroll[c] = total_rows - visible;
        }
    }

    /// Frees the owned items (labels and hints) and empties the list.
    pub fn releaseItems(self: *Palette) void {
        if (self.owns_items) freeItems(self.gpa, self.items);
        self.items = &.{};
        self.owns_items = false;
    }

    /// Closes the palette for the redraw. Does NOT free the items: it can be
    /// reopened in place (models palette → connect) and then `setItemsOwned`
    /// frees them along with its own. To release the memory, `destroy`.
    pub fn close(self: *Palette) void {
        self.active = false;
        self.mode = .commands;
        self.query_len = 0;
        self.key_len = 0;
        self.key_msg_len = 0;
        self.key_msg_error = false;
        self.custom_title = "";
        self.col = 1;
        self.sel = .{ 0, 0 };
        self.scroll = .{ 0, 0 };
        // CAREFUL: the items are NOT released here. With a bare `items = &.{}`
        // the owned labels were lost (every Ctrl+P that closed was a leak) and
        // on top of that `owns_items` stayed `true` with an empty list, which
        // is worse: it looks like the palette owns something.
        self.filtered[0].clearRetainingCapacity();
        self.filtered[1].clearRetainingCapacity();
    }

    /// Closes the palette and frees whatever is its own. On process exit.
    pub fn destroy(self: *Palette) void {
        self.releaseItems();
        self.deinit();
    }
};

// ── filtering ────────────────────────────────────────────────

/// Does the item survive the filter?
///
/// This is a search palette, not `/` autocomplete: here the SUBSTRING is what
/// is wanted. With a strict prefix, typing "mod" did not find "/model" (which
/// starts with a slash) and the search looked broken. Order: prefix first (the
/// usual and cheap case), then the label's substring, then the hint and
/// finally the group name, so that "model" brings out the whole group.
pub fn matches(item: Item, groups: []const Group, q: []const u8) bool {
    if (q.len == 0) return true;
    if (startsWithIgnoreCase(item.label, q)) return true;
    if (containsIgnoreCase(item.label, q)) return true;
    if (item.hint.len > 0 and containsIgnoreCase(item.hint, q)) return true;
    // The group name is one MORE way to find, never a veto: with a
    // `return containsIgnoreCase(...)` the group vetoed the match, and searching
    // "sonnet" did not find "claude-sonnet-4" (it lives in the "Models" group,
    // which does not contain "sonnet"). On top of that, pressing Enter with an
    // empty filtered list ended up applying a model that was not the
    // highlighted one.
    for (groups, 0..) |g, i| {
        if (i + 1 == item.group and containsIgnoreCase(g.name, q)) return true;
    }
    // The FUZZY fallback: the query as a subsequence of the label.
    //
    // It is what the reference implementation's picker does, and it is the
    // difference between a search box and a search box that forgives: "cs4"
    // finds "claude-sonnet-4-5".
    //
    // It is LAST, on purpose: an exact match always wins, so the item the
    // user meant is never pushed down by a lucky subsequence.
    var buf: [64]u32 = undefined;
    if (fuzzyMatch(item.label, q, &buf) != null) return true;
    return false;
}

// ── fuzzy matching ────────────────────────────────────────────

/// How much wider than the query the matched window may be.
///
/// The rule exists because a subsequence match with no width limit matches
/// almost everything: "abc" is a subsequence of half a model catalogue, and a
/// filter that returns half the list is a filter that does not filter.
///
/// The window is generous (three times the query, plus eight) because what
/// is searched is a model id with a provider prefix and a version suffix:
/// "cs4" has to reach "claude-sonnet-4-5" and that is 15 characters wide.
pub const fuzzy_window_slack: usize = 8;

/// Matches the query as a SUBSEQUENCE of the label and says WHICH
/// characters matched.
///
/// The positions are BYTE offsets into the label, written into `buf`; the
/// return value is how many there are, or null when the query is not a
/// subsequence of the label.
///
/// Two decisions that are not obvious:
///
/// * **Leftmost.** The scan starts where the previous match ended, so a
///   scattered match never beats an earlier one. The user typed the
///   characters in an order and the first place they appear is the one they
///   meant.
/// * **Runs win.** A run of consecutive characters is taken whole, and it is
///   the substring when there is one. "bc" in "a-xbc" highlights "bc" and
///   not "b" alone with a lonely "c" four columns away.
pub fn fuzzyMatch(label: []const u8, q: []const u8, buf: []u32) ?usize {
    if (q.len == 0) return 0;
    if (q.len > buf.len) return null;
    var n: usize = 0;
    var li: usize = 0;
    var qi: usize = 0;
    while (qi < q.len) {
        // The first occurrence of this character at or after the last match.
        var j = li;
        while (j < label.len) : (j += 1) {
            if (std.ascii.toLower(label[j]) == std.ascii.toLower(q[qi])) break;
        }
        if (j >= label.len) return null;
        // And the run that starts there, taken whole.
        var run: usize = 1;
        while (qi + run < q.len and j + run < label.len and
            std.ascii.toLower(label[j + run]) == std.ascii.toLower(q[qi + run])) : (run += 1)
        {}
        for (0..run) |k| {
            buf[n] = @intCast(j + k);
            n += 1;
        }
        li = j + run;
        qi += run;
    }
    // The WINDOW: the matched characters have to fit in a span that is not
    // much wider than the query. Without it the fuzzy fallback is noise.
    const span = buf[n - 1] - buf[0] + 1;
    if (span > q.len * 3 + fuzzy_window_slack) return null;
    return n;
}

/// The positions to HIGHLIGHT in the label, for the given query.
///
/// It prefers the contiguous substring (the common case, and the one the eye
/// reads as "the match") and falls back to the fuzzy positions.
pub fn highlightPositions(label: []const u8, q: []const u8, buf: []u32) ?usize {
    if (q.len == 0) return null;
    if (label.len > 0 and startsWithIgnoreCase(label, q)) {
        for (q, 0..) |_, i| buf[i] = @intCast(i);
        return q.len;
    }
    if (containsIgnoreCase(label, q)) {
        const at = indexOfIgnoreCase(label, q) orelse return null;
        for (q, 0..) |_, i| buf[i] = @intCast(at + i);
        return q.len;
    }
    return fuzzyMatch(label, q, buf);
}

/// The first position of `needle` in `hay`, ignoring the case.
///
/// `std.mem` has no case-insensitive index in this Zig version, and writing
/// it here is four lines: the ASCII comparison is the same one
/// `containsIgnoreCase` already uses.
pub fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn startsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (needle, 0..) |nc, i| {
        if (std.ascii.toLower(hay[i]) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "matches: prefix, substring, hint and group name" {
    // The group names are what the USER SEES in the palette, so they are English
    // like the rest of the UI. They used to be "Modelo"/"Sesión" in Spanish,
    // which made this test a search for "ses" matching "Sesión" by accident of
    // the accent being absent. It still proves the same thing in English.
    const groups = [_]Group{ .{ .name = "Model" }, .{ .name = "Session" } };

    // Group "Model": searching "model" brings out the whole item.
    const it = Item{ .kind = .command, .group = 1, .label = "/model" };
    try t.expect(matches(it, &groups, "")); // empty filter keeps everything
    try t.expect(matches(it, &groups, "/mo")); // prefix
    try t.expect(matches(it, &groups, "/model"));
    try t.expect(matches(it, &groups, "mod")); // substring: without this it does not show
    try t.expect(matches(it, &groups, "model")); // and by the group name

    // Group "Session": "mod" must NOT sneak in (neither by label nor by group).
    const it2 = Item{ .kind = .command, .group = 2, .label = "/new" };
    try t.expect(!matches(it2, &groups, "mod"));
    try t.expect(matches(it2, &groups, "sess")); // yes by the group name

    // A hint matches even when the label does not (the "free" price).
    const it3 = Item{ .kind = .model, .label = "sonnet", .hint = "free" };
    try t.expect(matches(it3, &groups, "free"));
    try t.expect(matches(it3, &groups, "sonnet"));
    try t.expect(!matches(it3, &groups, "gpt"));
}

test "matches: the group does NOT veto a label match" {
    // Regression: the group was checked with `return containsIgnoreCase(...)`,
    // that is, as a veto. Searching "sonnet" did not find "claude-sonnet-4",
    // because it lives in the "Models" group and "sonnet" does not appear
    // there. With the filtered list empty, Enter ended up applying a model
    // that was not the highlighted one.
    const groups = [_]Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Models" } };
    const m = Item{ .kind = .model, .group = 3, .label = "anthropic/claude-sonnet-4" };
    try t.expect(matches(m, &groups, "sonnet"));
    try t.expect(matches(m, &groups, "claude"));
    // And searching by the group name still works.
    try t.expect(matches(m, &groups, "model"));
    try t.expect(!matches(m, &groups, "gpt"));
}

test "refilter: in two columns it only filters the one with the focus" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.mode = .models;
    const groups = [_]Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Models" } };
    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "openrouter" },
        .{ .kind = .provider, .group = 1, .label = "groq" },
        .{ .kind = .model, .group = 3, .label = "claude-sonnet-4" },
        .{ .kind = .model, .group = 3, .label = "gpt-5" },
    };
    pal.setItems(&items, &groups);
    try t.expectEqual(@as(u8, 1), pal.col); // focus on models

    @memcpy(pal.query[0..6], "sonnet");
    pal.query_len = 6;
    pal.refilter();
    // Only the focused column is filtered: 1 model and the 2 providers intact.
    try t.expectEqual(@as(usize, 1), pal.countIn(1));
    try t.expectEqual(@as(usize, 2), pal.countIn(0));

    // When the focus moves to providers, now that one is filtered and not the
    // other.
    pal.col = 0;
    pal.refilter();
    try t.expectEqual(@as(usize, 0), pal.countIn(0));
    try t.expectEqual(@as(usize, 2), pal.countIn(1));
}

test "refilter: two columns, providers and models do not mix" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.mode = .models;
    const items = [_]Item{
        .{ .kind = .provider, .label = "opencode" },
        .{ .kind = .provider, .label = "openrouter" },
        .{ .kind = .connect, .label = "Connect an integration" },
        .{ .kind = .model, .label = "deepseek-chat" },
        .{ .kind = .model, .label = "gpt-5" },
    };
    pal.setItems(&items, &.{});

    try t.expectEqual(@as(usize, 3), pal.countIn(0)); // 2 providers + connect
    try t.expectEqual(@as(usize, 2), pal.countIn(1)); // 2 models

    // The filter is applied ONLY to the column with the focus (here the models
    // one, col=1): "gpt" leaves 1 model and the providers column intact, so it
    // stays as context instead of disappearing.
    @memcpy(pal.query[0..3], "gpt");
    pal.query_len = 3;
    pal.refilter();
    try t.expectEqual(@as(usize, 1), pal.countIn(1));
    try t.expectEqual(@as(usize, 3), pal.countIn(0));
}

test "refilter: the selection is trimmed to the size of the filtered list" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    const items = [_]Item{
        .{ .kind = .command, .label = "/help" },
        .{ .kind = .command, .label = "/model" },
        .{ .kind = .command, .label = "/context" },
    };
    pal.setItems(&items, &.{});
    try t.expectEqual(@as(usize, 3), pal.countIn(0));
    pal.sel[0] = 2; // "/context"

    @memcpy(pal.query[0..3], "mod");
    pal.query_len = 3;
    pal.refilter();
    // Only "/model" survives: the selection cannot stay at index 2.
    try t.expectEqual(@as(usize, 1), pal.countIn(0));
    try t.expectEqual(@as(usize, 0), pal.sel[0]);
    try t.expectEqualStrings("/model", pal.selected().?.label);
}

test "move: does not go past the ends" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    const items = [_]Item{
        .{ .kind = .command, .label = "a" },
        .{ .kind = .command, .label = "b" },
    };
    pal.setItems(&items, &.{});

    pal.move(0, -1);
    try t.expectEqual(@as(usize, 0), pal.sel[0]);
    pal.move(0, 5);
    try t.expectEqual(@as(usize, 1), pal.sel[0]);
    pal.move(0, 1);
    try t.expectEqual(@as(usize, 1), pal.sel[0]);
    pal.move(0, -2);
    try t.expectEqual(@as(usize, 0), pal.sel[0]);
}

test "the selected row is always visible, even with a group header in the window" {
    // The scroll is in ROWS and the window is in ROWS, because the list is
    // drawn with the group headers inside it: an item's row is not its index.
    // The old version clamped the ITEM index against a window measured in
    // rows, and the highlight vanished one row before the end of the list.
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    var items: [10]Item = undefined;
    for (&items, 0..) |*it, i| {
        // Two groups: the header and the blank line before it take two rows
        // that are not items.
        it.* = .{ .kind = .command, .label = "x", .group = if (i < 5) 1 else 2 };
    }
    pal.setItems(&items, &.{.{ .name = "one" }, .{ .name = "two" }});
    pal.refilter();

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const rows = try columnRows(&pal, 0, arena_state.allocator());
    // 10 items + 2 headers + 1 blank between the groups = 13 rows.
    try t.expectEqual(@as(usize, 13), rows.len);

    const visible: usize = 5;
    // The LAST item: with the item-index clamp it landed on a row the
    // headers had pushed out of the window.
    pal.sel[0] = 9;
    pal.clampScrollRows(0, rows.len, visible, selectedRow(&pal, 0, rows));
    const sel_row = selectedRow(&pal, 0, rows).?;
    try t.expect(sel_row >= pal.scroll[0]);
    try t.expect(sel_row < pal.scroll[0] + visible);

    // And back to the top: the selection is visible again. The scroll is not
    // necessarily ZERO (the group's header is a row of its own and the window
    // starts on the item), so the assertion is the INVARIANT and not a number.
    pal.sel[0] = 0;
    pal.clampScrollRows(0, rows.len, visible, selectedRow(&pal, 0, rows));
    const top_row = selectedRow(&pal, 0, rows).?;
    try t.expect(top_row >= pal.scroll[0]);
    try t.expect(top_row < pal.scroll[0] + visible);
}

// ── drawing ───────────────────────────────────────────────────

/// Width in COLUMNS of a text (model ids carry `/` and `·`, which are 1, but
/// emoji and `▸` are not). Counting bytes misaligns the right column, which is
/// aligned by real width.
fn displayWidth(text: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        _ = cp;
        n += 1;
    }
    return n;
}

/// Frees a list of items along with their strings. Each `label`/`hint` is an
/// owned copy (dup), not a slice from the caller's allocator: if they were, the
/// free would leave dangling pointers in the palette.
pub fn freeItems(gpa: std.mem.Allocator, items: []const Item) void {
    for (items) |it| {
        gpa.free(it.label);
        gpa.free(it.hint);
    }
    gpa.free(@constCast(items));
}

/// Modal geometry. Computed once and used by both the drawing and
/// `clampScroll`, so that the two cannot diverge.
pub const Box = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    /// Width of the left column (models mode).
    col_w: u16,
    /// Rows usable for items, without title, search or footer.
    list_rows: usize,
    /// Row of the first item line.
    list_top: u16,
};

/// Computes the modal's size. Models mode: two columns; commands: one.
pub fn boxFor(pal: *const Palette, width: u16, height: u16) Box {
    // The modal was 76 columns wide and the model ids are 40: the names were
    // cut, the "openrouter · free" hints collided with them, and the whole
    // thing looked cramped on a wide terminal. It takes what the terminal has
    // (minus a margin) up to 110 columns, which is where a model id and its
    // hint fit side by side.
    const w: u16 = @min(width -| 4, 110);
    const h: u16 = @min(height -| 4, 24);
    // The key prompt needs more height: it has a field, a message and two hints.
    const hh: u16 = if (pal.mode == .key_prompt) @min(height -| 4, 12) else h;
    const two_cols = pal.mode == .models and pal.countIn(0) > 0;
    // The providers column is a third: it holds short names and a key state,
    // and the models column is the one that has to fit a 40-character id.
    const col_w: u16 = if (two_cols) @max(18, w / 3) else w;
    // h = border(1) + title(1) + search(1) + items + footer(1) + border(1)
    const list_rows: usize = if (hh > 7) @as(usize, hh) - 5 else 1;
    return .{
        .x = (width -| w) / 2,
        .y = @max(1, (height -| hh) / 4),
        .w = w,
        .h = hh,
        .col_w = col_w,
        .list_rows = list_rows,
        .list_top = 0, // `draw` sets it (depends on key_prompt mode)
    };
}

/// Draws the whole modal. The history behind it is cleared with a space: the
/// vaxis surface already carries the history text, and without clearing, the
/// modal's items would show through on top of it.
pub fn draw(
    p: *Painter,
    surface: *vxfw.Surface,
    pal: *Palette,
    width: u16,
    height: u16,
    notice: []const u8,
) void {
    const box = boxFor(pal, width, height);
    if (box.w < 24 or box.h < 8) return;

    // ── background and borders ──
    //
    // The wide cells of the row are split FIRST: a cell that claims many
    // columns (the rule under the hero is one) makes the renderer skip the
    // columns it covers, and the modal would be EATEN by the history behind
    // it: the border disappears and the interior shows the rule.
    var y: u16 = 0;
    while (y < box.h) : (y += 1) {
        tui.expandWideCells(p.surface, box.y + y, width);
        p.fillRange(box.x, box.x + box.w, box.y + y, " ", .{});
    }
    p.fillRange(box.x + 1, box.x + box.w - 1, box.y, "─", theme.brand_faint);
    p.fillRange(box.x + 1, box.x + box.w - 1, box.y + box.h - 1, "─", theme.brand_faint);
    var yy: u16 = 1;
    while (yy < box.h - 1) : (yy += 1) {
        p.putStable(box.x, box.y + yy, "│", 1, theme.brand_faint);
        p.putStable(box.x + box.w - 1, box.y + yy, "│", 1, theme.brand_faint);
    }
    p.putStable(box.x, box.y, "╭", 1, theme.brand_faint);
    p.putStable(box.x + box.w - 1, box.y, "╮", 1, theme.brand_faint);
    p.putStable(box.x, box.y + box.h - 1, "╰", 1, theme.brand_faint);
    p.putStable(box.x + box.w - 1, box.y + box.h - 1, "╯", 1, theme.brand_faint);

    // ── title (left) and "esc" (right) ──
    const title = switch (pal.mode) {
        .commands => "Commands",
        .models => if (pal.custom_title.len > 0) pal.custom_title else "Choose a model",
        .connect => "Connect a provider",
        .key_prompt => "Add API key",
    };
    var tb: [128]u8 = undefined;
    const t1 = std.fmt.bufPrint(&tb, " {s}", .{title}) catch " ";
    _ = p.putText(box.x + 2, box.y + 1, t1, theme.brand_bold);
    _ = p.putText(box.x + box.w - 4, box.y + 1, "esc", theme.brand_soft);

    if (pal.mode == .key_prompt) {
        drawKeyPrompt(p, pal, box);
        drawFooter(p, pal, box, notice);
        surface.cursor = .{
            .row = box.y + 4,
            .col = box.x + 3 + @as(u16, @intCast(pal.key_len)),
        };
        return;
    }

    // ── search line, with the cursor at the end of what was typed ──
    const sy = box.y + 2;
    _ = p.putText(box.x + 2, sy, "▌", theme.brand_bold);
    const q = pal.queryText();
    const placeholder: []const u8 = switch (pal.mode) {
        .commands => "search commands",
        .models => if (pal.column() == 0) "filter providers" else "filter models",
        .connect => "filter providers",
        .key_prompt => "",
    };
    if (q.len > 0) {
        _ = p.putText(box.x + 3, sy, q, theme.brand);
    } else {
        _ = p.putText(box.x + 3, sy, placeholder, theme.brand_faint);
    }
    surface.cursor = .{ .row = sy, .col = box.x + 3 + @as(u16, @intCast(q.len)) };

    // ── list ──
    if (pal.mode == .models and pal.countIn(0) > 0) {
        // Providers column + separator + models column.
        var ry: u16 = 3;
        while (ry < box.h - 2) : (ry += 1) {
            p.putStable(box.x + box.col_w, box.y + ry, "│", 1, theme.brand_faint);
        }
        // The models column keeps ONE column for the scrollbar: the list is
        // cut (464 models, 19 rows) and a cut list with no sign that it goes
        // on is a list that looks COMPLETE — the user reads "these are the
        // models" and stops.
        const r0 = drawColumn(p, pal, box, 0, box.x + 1, box.col_w - 1, "");
        const r1 = drawColumn(p, pal, box, 1, box.x + box.col_w + 1, box.w - box.col_w - 3, notice);
        drawColumnScrollbar(p, pal, box, box.x + box.w - 2, if (pal.column() == 0) r0 else r1);
    } else {
        // One column less: the scrollbar has its own column, so the hint on
        // the right of a row is not painted under it.
        const r0 = drawColumn(p, pal, box, 0, box.x + 1, box.w - 3, "");
        drawColumnScrollbar(p, pal, box, box.x + box.w - 2, r0);
    }

    // ── footer ──
    drawFooter(p, pal, box, notice);
}

/// One row of a column: an item, a group header, or the blank line between
/// two groups.
const Row = struct {
    kind: enum { item, group, blank },
    /// The index into `filtered[c].items` (only for `.item`).
    item: usize,
    /// The group (only for `.group`).
    group: u8,
};

/// The rows of a column, with the group headers and the blank lines between
/// them.
///
/// The scroll is measured in ROWS and not in items, and that is the whole
/// point: the list is drawn with the headers INSIDE it, so an item's row is
/// not its index. A scroll measured in items left the selected row BELOW
/// the last visible one as soon as a header was in the window — the list
/// looked cut and the highlight was nowhere.
fn columnRows(pal: *const Palette, c: usize, arena: std.mem.Allocator) ![]Row {
    const filtered = pal.filtered[c].items;
    var rows: std.ArrayList(Row) = .empty;
    var last_group: u8 = 0;
    for (filtered, 0..) |item_ix, i| {
        const it = pal.items[item_ix];
        if (it.group != 0 and it.group != last_group) {
            last_group = it.group;
            // A blank line between the groups (like opencode), and the header
            // itself.
            if (rows.items.len > 0) try rows.append(arena, .{ .kind = .blank, .item = 0, .group = 0 });
            try rows.append(arena, .{ .kind = .group, .item = 0, .group = it.group });
        }
        try rows.append(arena, .{ .kind = .item, .item = i, .group = 0 });
    }
    return rows.toOwnedSlice(arena);
}

/// The row of the selected item of a column, or null when there is none.
fn selectedRow(pal: *const Palette, c: usize, rows: []const Row) ?usize {
    const sel = pal.sel[c];
    for (rows, 0..) |r, i| {
        if (r.kind == .item and r.item == sel) return i;
    }
    return null;
}

/// A column of items, with group header, scroll and highlight.
fn drawColumn(p: *Painter, pal: *Palette, box: Box, c: usize, x0: u16, w: u16, notice: []const u8) usize {
    const filtered = pal.filtered[c].items;
    if (filtered.len == 0) {
        const msg: []const u8 = if (pal.mode == .connect)
            "no providers"
        else if (pal.mode == .models and c == 1 and notice.len > 0 and pal.queryText().len == 0)
            notice
        else
            "no matches";
        _ = p.putClipped(x0 + 2, box.y + 3, msg, w -| 4, theme.hint);
        return 0;
    }
    const rows = columnRows(pal, c, p.arena) catch return 0;
    pal.clampScrollRows(c, rows.len, box.list_rows, selectedRow(pal, c, rows));

    for (rows, 0..) |r, ri| {
        if (ri < pal.scroll[c]) continue;
        const shown = ri - pal.scroll[c];
        if (shown >= box.list_rows) break;
        const row = box.y + 3 + @as(u16, @intCast(shown));
        switch (r.kind) {
            .blank => {},
            .group => {
                const gname = groupName(pal, r.group);
                if (gname.len > 0 and w > 2) {
                    _ = p.putText(x0 + 1, row, gname, theme.group);
                }
            },
            .item => {
                const it = pal.items[filtered[r.item]];

                // Only the FOCUSED column really highlights. Before, both
                // painted their selection alike and there was no way to know
                // which one was active: you pressed the arrows and the models
                // list did not move, which is exactly what makes you think
                // the list does not exist.
                const is_sel = r.item == pal.sel[c];
                const focused = c == pal.column();
                if (is_sel and focused) p.fillRange(x0, x0 + w, row, " ", theme.selected);
                // In the unfocused column, the chosen row is marked with a ▸ in
                // dim blue: you can see which one it is without it looking
                // focused.
                if (is_sel and !focused) _ = p.putText(x0, row, "\u{25b8}", theme.brand_soft);
                putLabelHighlighted(
                    p,
                    x0 + 1,
                    row,
                    it.label,
                    pal.queryText(),
                    if (is_sel) theme.item_sel else if (focused) theme.item else theme.dim,
                    if (is_sel) theme.brand_bold else theme.brand,
                );

                // Right column aligned to the edge: shortcut, "free", price…
                //
                // Only if both LABEL and hint fit with a gap in between.
                // Before, only whether the hint itself fit was checked, and in
                // the narrow providers column the hint was painted ON TOP of
                // the label and you read "anthrclaude-sonnet-4-5". The label
                // wins: that is what you select.
                const label_w = displayWidth(it.label);
                const hint_w = displayWidth(it.hint);
                if (hint_w > 0 and label_w + hint_w + 3 <= w) {
                    _ = p.putText(
                        x0 + w - 1 - @as(u16, @intCast(hint_w)),
                        row,
                        it.hint,
                        if (is_sel) theme.item_sel else theme.brand_faint,
                    );
                }
            },
        }
    }
    return rows.len;
}

/// Paints a label with the MATCHED characters in the accent colour.
///
/// This is the reference implementation's "the matched characters are
/// highlighted" (its fuzzy picker), and it is the half of the fuzzy search
/// that the user actually sees: the list says WHICH part of
/// "anthropic/claude-sonnet-4-5" answered the query.
///
/// The positions are BYTE offsets and the painting walks GRAPHEMES, so the
/// two meet at the grapheme's first byte: a match that lands inside a
/// multi-byte character highlights the whole character, which is the only
/// thing that can be painted.
fn putLabelHighlighted(
    p: *Painter,
    col: u16,
    row: u16,
    label: []const u8,
    query: []const u8,
    base: vaxis.Style,
    hl: vaxis.Style,
) void {
    if (label.len == 0) return;
    var positions: [64]u32 = undefined;
    const n = highlightPositions(label, query, &positions) orelse 0;
    if (n == 0) {
        _ = p.putText(col, row, label, base);
        return;
    }
    // The label is copied into the frame arena, like `putText` does: a pointer
    // to a stack temporary reaches the renderer as garbage.
    const stable = p.arena.dupe(u8, label) catch {
        _ = p.putText(col, row, label, base);
        return;
    };
    var it = vaxis.unicode.graphemeIterator(stable);
    var c = col;
    var off: usize = 0;
    while (it.next()) |g| {
        const b = g.bytes(stable);
        const gw = p.measure(b);
        if (c + gw > p.width) break;
        // Is the grapheme's first byte one of the matched ones?
        var matched = false;
        for (positions[0..n]) |pos| {
            if (pos == off) {
                matched = true;
                break;
            }
        }
        p.putStable(c, row, b, gw, if (matched) hl else base);
        c += gw;
        off += b.len;
    }
}

/// The scrollbar of the column that has the focus, on the right edge of the
/// modal.
///
/// The list is CUT: 464 models do not fit in 19 rows, and the only sign that
/// there are more is the scrollbar. Without it the list looks complete, and
/// "complete" is a lie the user cannot see through.
fn drawColumnScrollbar(p: *Painter, pal: *const Palette, box: Box, x: u16, total_rows: usize) void {
    const c = pal.column();
    const visible = box.list_rows;
    // Everything fits: no scrollbar, and no thumb that lies about there being
    // more.
    if (total_rows <= visible) return;
    const max_offset = total_rows - visible;
    const metrics = tui.scrollbarThumb(visible, max_offset);
    const first = @min(pal.scroll[c], max_offset);
    const thumb_top = if (metrics.travel == 0)
        0
    else
        metrics.travel * first / max_offset;
    var row: usize = 0;
    while (row < visible) : (row += 1) {
        const in_thumb = row >= thumb_top and row < thumb_top + metrics.size;
        p.putStable(
            x,
            box.y + 3 + @as(u16, @intCast(row)),
            if (in_thumb) "\u{2588}" else "\u{2502}",
            1,
            if (in_thumb) theme.brand else theme.rule,
        );
    }
}

fn drawFooter(p: *Painter, pal: *const Palette, box: Box, notice: []const u8) void {
    const fy = box.y + box.h - 2;
    const hint: []const u8 = switch (pal.mode) {
        .commands => "↑↓ move · enter run · esc close",
        .models => "↑↓ move · tab switch · enter select · ctrl+r refresh",
        .connect => "↑↓ move · enter add / replace key",
        .key_prompt => "",
    };
    const hint_width: u16 = @intCast(displayWidth(hint));
    const hint_x = box.x + box.w - 2 -| hint_width;
    if (hint.len > 0 and hint_width + 4 < box.w) {
        _ = p.putText(hint_x, fy, hint, theme.brand_soft);
    }
    // How far down the list we are, and how many there are. The scrollbar
    // says "there is more"; this says "how much", and a number is what makes
    // a cut list legible instead of mysterious.
    {
        const c = pal.column();
        const total = pal.filtered[c].items.len;
        if (total > 0) {
            var cb: [32]u8 = undefined;
            const counter = std.fmt.bufPrint(&cb, "{d}/{d}", .{ pal.sel[c] + 1, total }) catch "";
            const cw: u16 = @intCast(displayWidth(counter));
            if (cw > 0 and cw + 2 < box.w) {
                const cx = if (hint_x > cw + 2) hint_x - cw - 2 else box.x + 2;
                _ = p.putText(cx, fy, counter, theme.hint);
            }
        }
    }
    if (pal.mode == .models) {
        // Shortcut to connect without having to reach the item at the bottom.
        const left = "ctrl+a connect";
        if (left.len + 4 < box.w) {
            _ = p.putText(box.x + 2, fy, left, theme.brand);
            const notice_x = box.x + 2 + @as(u16, @intCast(displayWidth(left))) + 2;
            if (notice.len > 0 and hint_x > notice_x + 1) {
                _ = p.putClipped(notice_x, fy, notice, hint_x - notice_x - 1, theme.hint);
            }
        }
    }
}

fn drawKeyPrompt(p: *Painter, pal: *const Palette, box: Box) void {
    const top = box.y + 3;
    const label = if (pal.key_item < pal.items.len) pal.items[pal.key_item].label else "provider";

    // Explain which provider the key is for BEFORE the field: otherwise there
    // is no way to know whether you are connecting the highlighted one or the
    // active one.
    _ = p.putText(box.x + 3, top, "Connecting", theme.brand_soft);
    _ = p.putText(box.x + 3 + 11, top, label, theme.brand_bold);

    var pb: [96]u8 = undefined;
    const prompt = std.fmt.bufPrint(&pb, "API key for {s}", .{label}) catch "API key";
    _ = p.putText(box.x + 3, top + 1, prompt, theme.brand);

    // Masked, like a password field. The last 3 characters stay visible so you
    // can check that you did not paste something truncated.
    const typed = pal.keyText();
    const masked_len: usize = if (typed.len > 3) typed.len - 3 else 0;
    var w: u16 = 0;
    var x = box.x + 3;
    while (w < masked_len) : (w += 1) {
        _ = p.putStable(x, top + 3, "*", 1, theme.brand_soft);
        x += 1;
    }
    if (typed.len > masked_len) {
        const tail = typed[masked_len..];
        _ = p.putText(x, top + 3, tail, theme.brand);
        x += @as(u16, @intCast(tail.len));
    }
    // Cursor at the end of the field (underlined, so you can see where to
    // type).
    _ = p.putStable(x, top + 3, "_", 1, theme.brand_bold);

    const msg = pal.keyMessage();
    const my = top + 5;
    if (msg.len > 0) {
        // Whether the message is an ERROR is a PROPERTY OF THE MESSAGE, not
        // something the drawing code re-derives by grepping Spanish words out of
        // it.
        //
        // That is what this used to do: `indexOf(msg, "no se pudo") or
        // indexOf(msg, "vacía")`. Every caller of `setKeyMessage` had meanwhile
        // been translated to English ("could not write auth.json", "too many
        // stored keys", ...), so the flag could never be true and a FAILED key
        // save was painted in the same calm blue as a successful one. Grepping a
        // user-facing string for a word in a particular language is the bug: add
        // one error message in a new language and it silently stops being an
        // error.
        _ = p.putText(box.x + 3, my, msg, if (pal.keyMessageIsError()) theme.err else theme.brand_soft);
    }

    const hint = "enter saves · esc cancels";
    if (hint.len + 6 < box.w) {
        _ = p.putText(box.x + box.w - 2 - @as(u16, @intCast(hint.len)), my, hint, theme.brand_faint);
    }
    if (my + 1 < box.y + box.h - 1) {
        const hint2 = "saved to ~/.config/zode/auth.json (0600), never to config.json";
        if (hint2.len + 6 < box.w) {
            _ = p.putText(box.x + 3, my + 1, hint2, theme.brand_faint);
        }
    }
}

const palette_max_key_plus = max_key + 8;

fn groupName(pal: *const Palette, group: u8) []const u8 {
    if (group == 0) return "";
    const i: usize = @as(usize, group) - 1;
    if (i >= pal.groups.len) return "";
    return pal.groups[i].name;
}

// ── input ─────────────────────────────────────────────────────

/// What to do with the closed palette. The model decides (it is the one that
/// knows the providers and the agent), so here we only report the intent.
pub const Action = union(enum) {
    none,
    /// Run this agent command (e.g. "model", "new", "context").
    run_command: []const u8,
    /// Switch to this provider.
    set_provider: []const u8,
    /// Open the guided provider connection list.
    open_connect,
    /// Switch to this model, with its context window in tokens.
    ///
    /// A struct, not a bare `[]const u8`, because the window is what makes the
    /// compaction budget right for this model instead of a fixed 128k — and a
    /// bare string had no room for it, so the number that `buildModelItems` read
    /// out of the catalogue had nowhere to go.
    set_model: struct { id: []const u8, ctx_tokens: u32 },
    /// Connect a provider with this key. Both slices point at the palette's own
    /// buffers: whoever receives the action must copy them BEFORE closing the
    /// palette.
    connect: struct { provider: []const u8, key: []const u8 },
    /// Refresh the model list (invalidate cache and re-fetch).
    refresh_models,
    /// Close.
    close,
};

/// Translates a key into the corresponding action.
///
/// The caller passes the key already filtered by the modal (Ctrl+P must not
/// open the palette while a plain "p" is being typed, so the TUI's handler
/// decides which keys are passed in).
pub fn handleKey(pal: *Palette, key: vaxis.Key) Action {
    // ── key prompt ──
    if (pal.mode == .key_prompt) {
        if (key.matches(vaxis.Key.escape, .{})) {
            pal.mode = pal.key_return_mode;
            pal.key_len = 0;
            pal.key_msg_len = 0;
            return .{ .none = {} };
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            const provider = if (pal.key_item < pal.items.len) pal.items[pal.key_item].label else "";
            // The slices are returned WITHOUT clearing: the caller copies them
            // (saving the key is I/O) and then calls `close`.
            return .{ .connect = .{ .provider = provider, .key = pal.keyText() } };
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (pal.key_len > 0) pal.key_len -= 1;
            return .{ .none = {} };
        }
        if (key.text) |txt| {
            if (txt.len > 0 and pal.key_len < max_key) {
                @memcpy(pal.key_input[pal.key_len .. pal.key_len + txt.len], txt);
                pal.key_len += txt.len;
            }
        }
        return .{ .none = {} };
    }

    const c = pal.column();

    // ── navigation ──
    if (key.matches(vaxis.Key.up, .{})) {
        pal.move(c, -1);
        return .{ .none = {} };
    }
    if (key.matches(vaxis.Key.down, .{})) {
        pal.move(c, 1);
        return .{ .none = {} };
    }
    if (key.matches(vaxis.Key.page_up, .{})) {
        pal.move(c, -8);
        return .{ .none = {} };
    }
    if (key.matches(vaxis.Key.page_down, .{})) {
        pal.move(c, 8);
        return .{ .none = {} };
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        pal.close();
        return .{ .close = {} };
    }

    // In models mode, Tab / ←→ switch column (providers <-> models).
    if (pal.mode == .models) {
        if (key.matches(vaxis.Key.tab, .{})) {
            pal.col = if (pal.col == 0) 1 else 0;
            pal.refilter(); // the column gaining focus starts filtering
            return .{ .none = {} };
        }
        if (key.matches(vaxis.Key.left, .{}) and pal.col == 1) {
            pal.col = 0;
            pal.refilter();
            return .{ .none = {} };
        }
        if (key.matches(vaxis.Key.right, .{}) and pal.col == 0) {
            pal.col = 1;
            pal.refilter();
            return .{ .none = {} };
        }
        // Ctrl+R: refresh model list
        if (key.matches('r', .{ .ctrl = true })) {
            return .{ .refresh_models = {} };
        }
    }

    // ── search ──
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (pal.query_len > 0) {
            // Backspace deletes one grapheme, not one byte: accents and emoji
            // are multi-byte and splitting them leaves stray bytes.
            pal.query_len = backOneGrapheme(pal.query[0..pal.query_len]);
        }
        pal.sel = .{ 0, 0 };
        pal.scroll = .{ 0, 0 };
        pal.refilter();
        return .{ .none = {} };
    }
    if (key.text) |txt| {
        // Only printable text: keys with a modifier have already been filtered.
        if (txt.len > 0 and !key.mods.ctrl and !key.mods.alt) {
            const n = @min(txt.len, max_query - pal.query_len);
            @memcpy(pal.query[pal.query_len .. pal.query_len + n], txt[0..n]);
            pal.query_len += n;
            pal.sel = .{ 0, 0 };
            pal.scroll = .{ 0, 0 };
            pal.refilter();
        }
        return .{ .none = {} };
    }

    // ── confirm ──
    if (key.matches(vaxis.Key.enter, .{})) {
        const filtered_index = if (pal.sel[c] < pal.filtered[c].items.len)
            pal.filtered[c].items[pal.sel[c]]
        else
            return Action{ .none = {} };
        const it = pal.items[filtered_index];
        return switch (it.kind) {
            // "Connect" comes out as `run_command` and the model handles it, as
            // it is the one that knows how to open the providers list. If it
            // were resolved here (switching `mode` to `.connect` without
            // changing `items`) the list would still be the commands one with
            // the Connect title.
            .command => .{ .run_command = it.label },
            .provider => blk: {
                if (pal.mode == .connect) {
                    pal.key_item = filtered_index;
                    pal.key_return_mode = .connect;
                    pal.mode = .key_prompt;
                    pal.key_len = 0;
                    pal.key_msg_len = 0;
                    pal.setKeyMessage("paste the key and press enter", false);
                    break :blk Action{ .none = {} };
                }
                break :blk Action{ .set_provider = it.label };
            },
            .model => .{ .set_model = .{ .id = it.label, .ctx_tokens = it.ctx_tokens } },
            .connect => .open_connect,
        };
    }
    return .{ .none = {} };
}

/// Index of the last complete UTF-8 character before `len`.
fn backOneGrapheme(s: []const u8) usize {
    if (s.len == 0) return 0;
    var i = s.len - 1;
    while (i > 0) {
        // A UTF-8 continuation byte is 10xxxxxx.
        if ((s[i] & 0xC0) != 0x80) break;
        i -= 1;
    }
    return i;
}

// ── tests ─────────────────────────────────────────────────────

test "backOneGrapheme: deletes a grapheme, not a byte" {
    // "ñ" is 2 bytes and "🙂" is 4: with a plain `len - 1` stray bytes were
    // left behind and the search accumulated invalid UTF-8 garbage.
    try t.expectEqual(@as(usize, 0), backOneGrapheme(""));
    try t.expectEqual(@as(usize, 0), backOneGrapheme("a"));
    try t.expectEqual(@as(usize, 1), backOneGrapheme("ab"));
    // "añ"
    try t.expectEqual(@as(usize, 1), backOneGrapheme("a\xc3\xb1"));
    // "🙂" (4 bytes)
    try t.expectEqual(@as(usize, 0), backOneGrapheme("\xf0\x9f\x99\x82"));
    // "🙂ñ" -> leaves "🙂"
    try t.expectEqual(@as(usize, 4), backOneGrapheme("\xf0\x9f\x99\x82\xc3\xb1"));
}

test "handleKey: typing filters and enter returns the action" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    const items = [_]Item{
        .{ .kind = .command, .label = "/help" },
        .{ .kind = .command, .label = "/model" },
        .{ .kind = .command, .label = "/context" },
    };
    pal.setItems(&items, &.{});
    pal.active = true;

    // Typing "mod" leaves only /model.
    // A real vaxis Key carries `.text`; the code point alone would not be
    // enough (and the test would not notice if `text` were null).
    for ([_]vaxis.Key{
        .{ .codepoint = 'm', .text = "m" },
        .{ .codepoint = 'o', .text = "o" },
        .{ .codepoint = 'd', .text = "d" },
    }) |k| {
        _ = handleKey(&pal, k);
    }
    try t.expectEqual(@as(usize, 1), pal.countIn(0));
    try t.expectEqualStrings("mod", pal.queryText());

    // Enter returns run_command with the item's label (not the prefix).
    const act = handleKey(&pal, .{ .codepoint = 13 });
    try t.expectEqualStrings("/model", act.run_command);
}

test "handleKey: esc closes" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.active = true;
    const act = handleKey(&pal, .{ .codepoint = 27 });
    try t.expect(!pal.active);
    try t.expect(act == .close);
}

test "close does NOT drop the owned items: the next setItemsOwned frees them" {
    // `close` is called on every Esc and on every executed command, and the
    // palette can be reopened IN PLACE (models → connect). Before, `close` did
    // `items = &.{}` without freeing: every closed Ctrl+P was a leak of the
    // labels, and on top of that `owns_items` stayed `true` over an empty list
    // (the palette looked like the owner of something it no longer had).
    var pal = Palette.init(t.allocator);
    // `destroy` and not `deinit`: the items belong to the test allocator and
    // only it frees them (that is what `Model.deinit` → `destroyPalette` does).
    defer pal.destroy();

    const owned = t.allocator.alloc(Item, 2) catch unreachable;
    owned[0] = .{ .kind = .command, .label = t.allocator.dupe(u8, "/help") catch unreachable };
    owned[1] = .{ .kind = .command, .label = t.allocator.dupe(u8, "/new") catch unreachable };
    pal.setItemsOwned(owned, &.{});
    pal.active = true;

    pal.close();
    try t.expect(!pal.active);
    // The items are still there: they can be reused or freed afterwards.
    try t.expectEqual(@as(usize, 2), pal.items.len);
    try t.expectEqualStrings("/help", pal.items[0].label);

    // And when repopulating, the old ones are really freed (the test allocator
    // fails if not).
    const next = t.allocator.alloc(Item, 1) catch unreachable;
    next[0] = .{ .kind = .command, .label = t.allocator.dupe(u8, "/cache") catch unreachable };
    pal.setItemsOwned(next, &.{});
    try t.expectEqualStrings("/cache", pal.items[0].label);
}

test "handleKey: models mode, tab switches column" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.mode = .models;
    const items = [_]Item{
        .{ .kind = .provider, .label = "opencode" },
        .{ .kind = .model, .label = "sonnet" },
    };
    pal.setItems(&items, &.{});
    pal.active = true;

    try t.expectEqual(@as(u8, 1), pal.col);
    _ = handleKey(&pal, .{ .codepoint = 9 }); // tab
    try t.expectEqual(@as(u8, 0), pal.col);
    _ = handleKey(&pal, .{ .codepoint = 9 });
    try t.expectEqual(@as(u8, 1), pal.col);
}

test "handleKey: the key prompt accumulates masked text" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.mode = .key_prompt;
    pal.active = true;

    for ([_]vaxis.Key{
        .{ .codepoint = 'a', .text = "a" },
        .{ .codepoint = 'b', .text = "b" },
    }) |k| {
        _ = handleKey(&pal, k);
    }
    try t.expectEqualStrings("ab", pal.keyText());
    _ = handleKey(&pal, .{ .codepoint = 127 }); // backspace
    try t.expectEqualStrings("a", pal.keyText());
}

// ── drawing tests ─────────────────────────────────────────────

test "draw: the modal paints title, search and the highlighted item" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    // CAREFUL: the palette that draws the frame is the MODEL's one. Setting up
    // a local one would not change anything on screen.
    const items = [_]Item{
        .{ .kind = .command, .label = "/help" },
        .{ .kind = .command, .label = "/model" },
    };
    m.pal.setItems(&items, &.{});
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 80, 24);
    const all = tui.allText(s);
    try t.expect(std.mem.indexOf(u8, all, "Commands") != null);
    try t.expect(std.mem.indexOf(u8, all, "search") != null);
    try t.expect(std.mem.indexOf(u8, all, "/help") != null);
    try t.expect(std.mem.indexOf(u8, all, "/model") != null);
}

test "draw: the groups come out with their header and in order" {
    // Regression: each item's row was computed BEFORE the group block, so the
    // label came out one row too high and the header landed on top of the next
    // label. The list looked out of order.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    const groups = [_]Group{ .{ .name = "AAA" }, .{ .name = "BBB" } };
    const items = [_]Item{
        .{ .kind = .command, .group = 1, .label = "uno" },
        .{ .kind = .command, .group = 2, .label = "dos" },
    };
    m.pal.setItems(&items, &groups);
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 80, 24);
    var i_a: ?usize = null;
    var i_uno: ?usize = null;
    var i_b: ?usize = null;
    var i_dos: ?usize = null;
    var line: [256]u8 = undefined;
    var row: u16 = 0;
    while (row < s.size.height) : (row += 1) {
        const r = tui.rowText(s, row, &line);
        if (std.mem.indexOf(u8, r, "AAA") != null) i_a = row;
        if (std.mem.indexOf(u8, r, "uno") != null) i_uno = row;
        if (std.mem.indexOf(u8, r, "BBB") != null) i_b = row;
        if (std.mem.indexOf(u8, r, "dos") != null) i_dos = row;
    }
    try t.expect(i_a != null and i_uno != null and i_b != null and i_dos != null);
    // The header goes exactly BEFORE its first item, and in order.
    try t.expect(i_uno.? > i_a.?);
    try t.expect(i_dos.? > i_b.?);
    try t.expect(i_b.? > i_uno.?);
}

test "draw: models mode paints both columns and the footer" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    m.pal.mode = .models;
    const groups = [_]Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Models" } };
    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "openrouter", .hint = "activo" },
        .{ .kind = .connect, .group = 2, .label = "+ connect" },
        .{ .kind = .model, .group = 3, .label = "deepseek-chat", .hint = "free" },
    };
    m.pal.setItems(&items, &groups);
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 90, 26);
    const all = tui.allText(s);
    try t.expect(std.mem.indexOf(u8, all, "Choose a model") != null);
    try t.expect(std.mem.indexOf(u8, all, "openrouter") != null);
    try t.expect(std.mem.indexOf(u8, all, "deepseek-chat") != null);
    try t.expect(std.mem.indexOf(u8, all, "free") != null);
    // The footer announces the connect shortcut, which is the short way.
    try t.expect(std.mem.indexOf(u8, all, "ctrl+a connect") != null);
}

test "draw: the hint does not overlap the label" {
    // Regression: in the narrow providers column, the default hint was painted
    // on top of the label and you read "anthrclaude-sonnet-4-5".
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    m.pal.mode = .models;
    const groups = [_]Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Models" } };
    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "anthropic", .hint = "claude-sonnet-4-5" },
        .{ .kind = .connect, .group = 2, .label = "+ connect" },
        .{ .kind = .model, .group = 3, .label = "x", .hint = "free" },
    };
    m.pal.setItems(&items, &groups);
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 90, 26);
    const all = tui.allText(s);
    // The label reads WHOLE: with no hint on top of it.
    try t.expect(std.mem.indexOf(u8, all, "anthropic") != null);
    // And the long hint, not fitting alongside the label, does not show at all.
    try t.expect(std.mem.indexOf(u8, all, "claude-sonnet-4-5") == null);
    // The short hint does fit and is visible.
    try t.expect(std.mem.indexOf(u8, all, "+ connect") != null);
}

test "displayWidth: counts columns, not bytes" {
    // Model ids carry "/" and "·" (1 column, 1-2 bytes). Counting bytes threw
    // the hint's right column off center.
    try t.expectEqual(@as(usize, 9), displayWidth("anthropic"));
    try t.expectEqual(@as(usize, 3), displayWidth("a/b"));
    try t.expectEqual(@as(usize, 0), displayWidth(""));
}

test "draw: the Connect modal lists the providers" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    m.pal.mode = .connect;
    const items = [_]Item{
        .{ .kind = .provider, .label = "opencode", .hint = "no key" },
        .{ .kind = .provider, .label = "openrouter", .hint = "active" },
    };
    m.pal.setItems(&items, &.{});
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 90, 26);
    const all = tui.allText(s);
    try t.expect(std.mem.indexOf(u8, all, "Connect") != null);
    try t.expect(std.mem.indexOf(u8, all, "opencode") != null);
    try t.expect(std.mem.indexOf(u8, all, "openrouter") != null);
    try t.expect(std.mem.indexOf(u8, all, "no key") != null);
}

test "freeItems: all the strings are owned copies" {
    // Regression: the "+ connect" item carried LITERALS ("+ connect", "ctrl+a")
    // and `freeItems` freed them. `gpa.free` on .rodata text is an
    // "Invalid free" that only showed on app exit, with the palette half
    // destroyed and the allocator's canary blowing up: very hard to attribute
    // to the item that caused it.
    //
    // This test builds the items exactly like the worker and destroys them: if
    // someone puts a literal back in, it blows up here and not on exit.
    const gpa = std.testing.allocator;
    const items = gpa.alloc(Item, 2) catch return error.OutOfMemory;
    items[0] = .{
        .kind = .provider,
        .label = gpa.dupe(u8, "opencode") catch return error.OutOfMemory,
        .hint = gpa.dupe(u8, "no key") catch return error.OutOfMemory,
    };
    items[1] = .{
        .kind = .connect,
        .label = gpa.dupe(u8, "+ connect") catch return error.OutOfMemory,
        .hint = gpa.dupe(u8, "ctrl+a") catch return error.OutOfMemory,
    };
    freeItems(gpa, items);
}

test "setItemsOwned: replaces and frees the previous one" {
    const gpa = std.testing.allocator;
    var pal = Palette.init(gpa);
    defer pal.deinit();

    const mk = struct {
        fn build(g: std.mem.Allocator, name: []const u8) []Item {
            const it = g.alloc(Item, 1) catch unreachable;
            it[0] = .{
                .kind = .command,
                .label = g.dupe(u8, name) catch unreachable,
                .hint = g.dupe(u8, "hint") catch unreachable,
            };
            return it;
        }
    };

    pal.setItemsOwned(mk.build(gpa, "uno"), &.{});
    try t.expectEqualStrings("uno", pal.items[0].label);
    // Replacing must free the previous one: otherwise memory grows every time
    // the palette is opened (and `testing.allocator` would detect it as a leak).
    pal.setItemsOwned(mk.build(gpa, "dos"), &.{});
    try t.expectEqualStrings("dos", pal.items[0].label);
    pal.releaseItems();
    try t.expectEqual(@as(usize, 0), pal.items.len);
    try t.expect(!pal.owns_items);
}

test "models mode: the models column is the one with the focus" {
    // Regression: `openModelPalette` set the mode AFTER `setItemsOwned`, and
    // `resetSelection` computes the active column from the mode. With the old
    // mode it stayed on the providers column: the arrows did not move the
    // models list and it looked like there was nothing to choose.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "openrouter" },
        .{ .kind = .model, .group = 3, .label = "sonnet" },
        .{ .kind = .model, .group = 3, .label = "gpt-5" },
    };
    m.pal.mode = .models;
    m.pal.setItems(&items, &model_groups_test);
    m.pal.active = true;

    try t.expectEqual(@as(u8, 1), m.pal.col);
    try t.expectEqualStrings("sonnet", m.pal.selected().?.label);
    m.pal.move(1, 1);
    try t.expectEqualStrings("gpt-5", m.pal.selected().?.label);
}

const model_groups_test = [_]Group{
    .{ .name = "Providers" },
    .{ .name = "" },
    .{ .name = "Models" },
};

test "draw: only the focused column is highlighted" {
    // Both columns highlighted their row and there was no way to know which one
    // had the focus. The one that does not marks with ▸ and dimmed.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "openrouter" },
        .{ .kind = .model, .group = 3, .label = "sonnet" },
    };
    m.pal.mode = .models;
    m.pal.setItems(&items, &model_groups_test);
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 90, 26);
    const all = tui.allText(s);
    // The chosen provider is marked with ▸ (unfocused) and the focused model
    // with the highlight bar, which in plain text is only visible as the whole
    // row.
    try t.expect(std.mem.indexOf(u8, all, "▸") != null);
}

test "the key message carries whether it is an error, instead of the drawing guessing it" {
    // Regression. The drawing used to decide whether the "connect a provider"
    // message was an error by grepping the string for SPANISH words:
    //
    //     const bad = indexOf(msg, "no se pudo") != null or indexOf(msg, "vacía") != null;
    //
    // Every caller had meanwhile been translated to English ("could not write
    // auth.json", "too many stored keys", "auth.json is too large"), so `bad`
    // could never be true: a FAILED key save was painted in the same calm blue
    // as a successful one, and the only thing that said it had failed was reading
    // the sentence.
    //
    // Grepping a user-facing string for a word in one particular language is the
    // bug itself: add one error message in another language and it silently stops
    // being an error. So the flag travels WITH the message now.
    var pal = Palette.init(std.testing.allocator);
    defer pal.destroy();

    pal.setKeyMessage("paste the key and press enter", false);
    try t.expect(!pal.keyMessageIsError());

    pal.setKeyMessage("could not write auth.json", true);
    try t.expect(pal.keyMessageIsError());
    try t.expectEqualStrings("could not write auth.json", pal.keyMessage());

    // Formatting keeps the flag too.
    pal.setKeyMessagef("saved: {s}", .{"opencode"}, false);
    try t.expect(!pal.keyMessageIsError());
    try t.expectEqualStrings("saved: opencode", pal.keyMessage());

    // And closing the palette clears it, so a stale error does not colour the
    // next message.
    pal.close();
    try t.expect(!pal.keyMessageIsError());
    try t.expectEqualStrings("", pal.keyMessage());
}

test "fuzzy: the query is a subsequence of the label, and the positions say which" {
    var buf: [64]u32 = undefined;

    // The ordinary case: a model id with a provider prefix and a version.
    const n = fuzzyMatch("anthropic/claude-sonnet-4-5", "cs4", &buf).?;
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 8), buf[0]); // the 'c' of "claude"
    try std.testing.expectEqual(@as(u32, 17), buf[1]); // the 's' of "sonnet"
    try std.testing.expectEqual(@as(u32, 24), buf[2]); // the '4'

    // Case does not matter: it is a search box, not a compiler.
    try std.testing.expect(fuzzyMatch("Claude-Sonnet", "son", &buf) != null);

    // Not a subsequence: no match, and the caller has to say so.
    try std.testing.expect(fuzzyMatch("claude-sonnet", "zzz", &buf) == null);
}

test "fuzzy: a run of consecutive characters wins over a scattered one" {
    // "bc" in "a-xbc": the highlight has to be the RUN, because a "b" alone
    // with a lonely "c" four columns away does not read as a match.
    var buf: [64]u32 = undefined;
    const n = fuzzyMatch("a-xbc", "bc", &buf).?;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 3), buf[0]);
    try std.testing.expectEqual(@as(u32, 4), buf[1]);
}

test "fuzzy: the window keeps the fallback from matching everything" {
    // Without a width limit, "abc" is a subsequence of half a catalogue, and
    // a filter that returns half the list is a filter that does not filter.
    var buf: [64]u32 = undefined;
    try std.testing.expect(fuzzyMatch("a-very-long-label-that-goes-on-and-on", "abc", &buf) == null);
    // …and the same query on a tight label does match.
    try std.testing.expect(fuzzyMatch("abc", "abc", &buf) != null);
}

test "matches: the fuzzy fallback finds what the substring does not" {
    const groups = [_]Group{.{ .name = "Models" }};
    const item = Item{ .kind = .command, .label = "anthropic/claude-sonnet-4-5" };

    // The substring finds it.
    try std.testing.expect(matches(item, &groups, "sonnet"));
    // The fuzzy finds the abbreviation.
    try std.testing.expect(matches(item, &groups, "cs4"));
    // And something that is not there at all does not.
    try std.testing.expect(!matches(item, &groups, "qqq"));
}

test "highlightPositions: the substring is preferred over the fuzzy positions" {
    var buf: [64]u32 = undefined;
    // "sonnet" in "claude-sonnet-4-5": the CONTIGUOUS run, not the first
    // scattered one.
    const n = highlightPositions("claude-sonnet-4-5", "sonnet", &buf).?;
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(u32, 7), buf[0]);
    try std.testing.expectEqual(@as(u32, 12), buf[5]);
}
