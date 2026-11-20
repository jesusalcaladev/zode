//! TUI draw dispatch, split out of tui.zig (Phase 42.9).
//! Rendering helpers stay in tui.zig; this module only drives the frame.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("tui.zig");
const theme = @import("lib/theme.zig");
const textcap = @import("lib/textcap.zig");
const md = @import("lib/markdown.zig");
const agent = @import("agent.zig");
const palette = @import("palette.zig");

pub fn typeErasedDrawFn(ud: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *tui.Model = @ptrCast(@alignCast(ud));
    // ZODE_CRASH_TEST=1: die with the alternate screen ACTIVE (vaxis owns it
    // by now), so the crash path runs with something real to give back.
    if (self.crash_test) @panic("crash test requested (ZODE_CRASH_TEST)");
    if (!self.boot_painted) {
        self.boot_painted = true;
        tui.firstPaintMark();
    }

    const width: u16 = @intCast(ctx.max.width orelse ctx.min.width);
    const height: u16 = @intCast(ctx.max.height orelse ctx.min.height);
    // The modal's geometry is derived from these, and a mouse event carries no
    // size: the hit test uses what was last painted, which is what the user is
    // pointing at.
    self.frame_w = width;
    self.frame_h = height;
    if (height < 6 or width < 12) {
        // An empty surface in a small split pane looks like a frozen app. Paint
        // one clipped line that says what is wrong, then return — no composer,
        // no modal geometry, no event work until the pane grows.
        if (height == 0 or width == 0) return vxfw.Surface.empty(self.widget());
        const tiny_size: vxfw.Size = .{ .width = width, .height = height };
        var tiny = try vxfw.Surface.init(ctx.arena, self.widget(), tiny_size);
        var tp = tui.Painter{ .surface = &tiny, .arena = ctx.arena, .ctx = ctx, .width = width, .height = height };
        _ = tp.putText(0, 0, "zode: terminal too small (min 12x6)", theme.warn);
        return tiny;
    }

    const size: vxfw.Size = .{ .width = width, .height = height };
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    var p = tui.Painter{
        .surface = &surface,
        .arena = ctx.arena,
        .ctx = ctx,
        .width = width,
        .height = height,
    };

    // ── bottom-up layout ──
    //
    //   row height-1                       the footer's row (the mascot)
    //   rows ..input_top+input_h-1         prompt, no box, grows upward
    //   row  rule_row                      one hairline
    //   rows rule_row-ac..plan             only when relevant
    //   rows 0..history_h                  the conversation, and nothing else
    //
    // The composer is ONE object: the prompt rows and the footer's row share
    // the same sunken surface, and the footer's row is the LAST row of the
    // terminal. There is nothing under the input.
    //
    // This used to be a banner of 5 rows, a rule, a BORDERED input box of 3
    // rows, a blank, a status row and another row for the usage column: eleven
    // rows of furniture before the first word. Six of them were permanent, and
    // the banner was a drawing that never changed and never would.
    const max_input_lines: u16 = 8;
    const text_w: u16 = if (width > 4) width - 4 else 1;

    // The state, read ONCE per frame: it is what the footer's face and legend
    // are painted from, and nothing else paints a state any more.
    //
    // There used to be TWO widgets for it (the activity strip above the
    // hairline and the mascot in the row under the input) and they said the
    // same thing in two places: the row under the input held a face and
    // nothing else, so on screen it read as a stray emoticon in the corner of
    // an otherwise empty row.
    const act = self.activity();
    const queued = self.queuedCount();

    // Keep a compact live summary near the input; the complete checklist is
    // emitted into the scrollable history when the model updates the plan.
    const pl_now = self.planCopy();
    const plan_rows: u16 = if (pl_now.isEmpty()) 0 else 1;

    // Autocompletion popup: only if there are matches.
    const ac_matches: usize = if (self.ac.active) tui.matchCount(self) else 0;
    const ac_rows: u16 = if (ac_matches > 0)
        @as(u16, @intCast(@min(ac_matches, self.ac.max_visible) + 1))
    else
        0;

    // The composer is ONE object: the text rows plus ONE footer row, both
    // inside the same sunken surface. The footer is the mascot, the legend and
    // the session's own numbers; there is no separate status row under the
    // input any more, and nothing under the well at all.
    //
    // `chrome` is the hairline and the optional workspace rows and NOTHING
    // else: the input has no top and no bottom border, so it costs exactly
    // the rows it is using.
    const chrome: u16 = 1 + ac_rows + plan_rows; // hairline, autocomplete, plan
    const avail: u16 = if (height > chrome + 2) height - chrome - 2 else 1;
    const ed_w: u16 = if (text_w > 0) text_w else 1;
    const input_h: u16 = @max(@min(@as(u16, @intCast(@min(self.ed.displayLines(ed_w, tui.editorMeasurer(&p)), max_input_lines))), avail), 1);
    // The footer is ALWAYS reserved, even when it has nothing to say: a row
    // that appears and disappears with the state is a row that makes the input
    // jump, and the input is the one thing the user is looking at.
    const well_h: u16 = input_h + 1;
    const input_top: u16 = if (height > well_h + 1) height - well_h else 1;
    const rule_row: u16 = if (input_top > 0) input_top - 1 else 0;
    const workspace_top = rule_row -| ac_rows -| plan_rows;
    const history_h: u16 = @max(workspace_top, 1);
    // The key handler needs the height to jump a whole page.
    self.hist_rows = history_h;

    // ── drain pending ──
    self.drainPending();
    // The results of the user's own `!` commands. Same rule as everything else
    // that comes from a worker: the UI thread takes them and appends the session
    // message, because the session is not thread-safe.
    self.drainShellOut();

    // Invalidates the cache if the width changed (the lines already come
    // wrapped) or if a paragraph was edited in-place (^R expands a tool
    // result).
    if (self.cache_width != width) {
        self.clearSegCache();
        self.cache_width = width;
        self.cache_from = null;
    } else if (self.cache_from) |from| {
        // Drops the paragraphs from `from` onwards. CAREFUL: `from` is a
        // HISTORY index, not a cache one (the cache is a window, so its
        // indices are offset: that is why we look it up by `para_idx`).
        var i: usize = 0;
        while (i < self.seg_cache.items.len) {
            if (self.seg_cache.items[i].para_idx >= from) {
                self.evictCached(i);
            } else {
                i += 1;
            }
        }
        self.cache_from = null;
    }

    // ── layout of the live paragraph (redone every frame) ──
    //
    // The SNAPSHOT is taken with the lock held and the PARSE OUTSIDE (1.6):
    // before, ALL of `stream_buf` was parsed (markdown + highlighter +
    // grapheme widths) on every frame and with the model lock held, so the
    // worker (which puts a `streamDelta` per token) competed with draw on
    // every token and the lock became a bottleneck. Copying is a memcpy;
    // parsing is not.
    //
    // INVARIANT: whatever `live_src` points at when the lock is released is
    // owned by `ctx.arena` and outlives the frame's parse. The `CellRun`s store
    // the grapheme BY VALUE but with a pointer to its bytes, and painting
    // happens later, so a stack buffer or a model-owned buffer would be read
    // after it died (the `&[_]u8{c}` family AGENTS.md keeps paying for).
    var live_src: []const u8 = &.{};
    var live_is_tool = false;
    var tool_buf: [128]u8 = undefined;
    {
        self.lock();
        defer self.unlock();
        if (self.streaming and self.stream_buf.items.len > 0) {
            // THE COPY IS INSIDE THE CRITICAL SECTION, and that is the whole
            // point of it.
            //
            // It used to be: take a slice under the lock, unlock, and copy ten
            // lines later at the parse site. In between the worker could
            // `stream_buf.appendSlice(...)`, which reallocates and FREES the
            // old buffer — so the copy could read freed memory, and what came
            // out was arbitrary bytes fed to the UTF-8 parser and then to the
            // renderer. Narrow window, but the only path in the history that
            // could put genuinely random bytes on screen.
            live_src = ctx.arena.dupe(u8, self.stream_buf.items) catch "";
        }
        // Feedback for the tool in progress. Without this, a 30s `bash` leaves
        // the last row frozen at `⏺ bash(...)` and there is no way to tell if
        // the process is still alive or if the app has hung: the clock is the
        // only thing that answers "is it stuck?".
        //
        // No need to concatenate with the streaming: they never coexist (a
        // tool runs with the stream closed), so the clock line REPLACES the
        // live paragraph instead of adding to it.
        if (self.tool_run) |tr| {
            // The ELAPSED TIME goes IN THE HEADER LINE, not only in the strip.
            //
            // The strip is one row and it is at most 80 columns: with a long
            // command, a model name and a session counter, its clock was the
            // first thing pushed off the right edge. So the question the user
            // actually asks — "has it been running 4 seconds or is it stuck?" —
            // had to be answered from a row that was not on screen.
            //
            // The argument is clipped for the same reason it is clipped in the
            // header: a `bash` argument is whatever the model wrote.
            //
            // The clock is read under the lock, and it MOVES: `toolRunMillis`
            // takes the lock now (it used to read `self.tool_run` unlocked,
            // which was a use-after-free against `toolRunEnd` and made this
            // number read 0 — see the comment there).
            const ms = self.toolRunMillisLocked();
            var arg_buf: [96]u8 = undefined;
            const arg_shown = textcap.clipInto(tr.arg, 48, &arg_buf);
            const secs = ms / 1000;
            const line = if (ms == 0)
                if (tr.arg.len == 0)
                    std.mem.print(&tool_buf, "*{s}* running", .{tr.name}) catch ""
                else
                    std.mem.print(&tool_buf, "*{s}*({s}) running", .{ tr.name, arg_shown }) catch ""
            else if (tr.arg.len == 0)
                std.mem.print(&tool_buf, "*{s}* running · {d}.{d}s", .{ tr.name, secs, (ms % 1000) / 100 }) catch ""
            else
                std.mem.print(&tool_buf, "*{s}*({s}) running · {d}.{d}s", .{ tr.name, arg_shown, secs, (ms % 1000) / 100 }) catch "";
            // Copied here, while `tool_buf` is certainly alive and `tr.name` /
            // `tr.arg` cannot be freed under us: `toolRunEnd` frees them from
            // the worker thread as soon as it runs.
            live_src = ctx.arena.dupe(u8, line) catch "";
            live_is_tool = true;
        }
    }

    // The footer is the single owner of phase and elapsed time. Do not repeat
    // its clock in the history while waiting for the first token.
    const live_kind: md.Kind = if (live_is_tool) .tool_res else .assistant;
    var live_active = false;
    const hist_margin: u16 = tui.historyMargin(width);
    const wrap_width: u16 = if (width > hist_margin * 2 + 1)
        width - hist_margin * 2 - 1
    else if (width > 1)
        width - 1
    else
        width;

    var live_lines: []const tui.PLine = &.{};
    if (live_src.len > 0) {
        // Streaming text is rebuilt from the current snapshot each frame so
        // incomplete markdown (unclosed fences, partial structures) keeps
        // rendering as it arrives. We force redraw while live content is shown.
        // `live_src` is already frame-arena owned (see the invariant above), so
        // there is nothing to copy here any more.
        // Phase 41.8: reparse ONLY when the text or the wrap width changed.
        // The cached cells point at text copied into the MODEL's arena, never
        // at the frame arena that dies on every tick — otherwise a cached
        // grapheme would be a dangling slice (the exact class memaudit blocks).
        const h = std.hash.Wyhash.hash(0, live_src);
        if (h == self.live_hash and wrap_width == self.live_width and self.live_lines.len > 0) {
            live_lines = self.live_lines;
        } else {
            self.live_lines_arena.deinit();
            self.live_lines_arena = std.heap.ArenaAllocator.init(self.allocator);
            const pa = self.live_lines_arena.allocator();
            const stable_src = pa.dupe(u8, live_src) catch live_src;
            var live_para = tui.Model.Para{
                .kind = live_kind,
                .text = stable_src,
                .lang = if (live_kind == .diff) "zig" else "",
            };
            const query: ?[]const u8 = if (self.search_has_query and self.search_query_len > 0)
                self.search_query_buf[0..self.search_query_len]
            else
                null;
            live_lines = tui.buildLines(pa, ctx, &live_para, wrap_width, self.nerd_icons, query) catch &.{};
            self.live_lines = live_lines;
            self.live_hash = h;
            self.live_width = wrap_width;
        }
        live_active = live_lines.len > 0;
    }

    // ── scroll: 0 = anchored at the bottom ──
    //
    // `layoutFor` leaves the cache window covering what is visible (so deep
    // scrolling re-parses on demand, which is what the old comment claimed and
    // was not true) and returns the visible range already stabilized.
    //
    // Reserve one column for the scrollbar, even while it is inactive, so text
    // never jumps when the history first becomes scrollable.
    self.wrap_w = wrap_width;
    const vis = try self.layoutFor(
        ctx,
        wrap_width,
        if (live_active) live_lines.len else 0,
        history_h,
    );
    const first_visible = vis.first;
    const last_visible = vis.last;
    // Publishes what was painted, so the `↓ N` indicator and the tests read the
    // same numbers the screen shows. `live_h` goes here too: it is the one input
    // `currentMaxOffset` cannot compute on its own, and the key handlers clamp
    // against it (without it, a PageUp before the first frame does nothing).
    self.first_visible = first_visible;
    self.max_offset = vis.max_offset;
    self.live_h = if (live_active) live_lines.len else 0;

    // Clear the transcript area up to the hairline, INCLUDING the rows a plan
    // or autocomplete popup reserves (history_h stops short of `rule_row`
    // there), so no row keeps the previous frame's pixels.
    //
    // On the TERMINAL's background and not on `well_bg`: a panel that is
    // almost black looks like a second, wrong black next to the terminal's
    // own, and on a black terminal the whole transcript read as a gray block
    // with the user's own background nowhere in sight. The history is the
    // page; only a well that MEANS something (a tool result, a code block, a
    // modal) is allowed to be a surface.
    {
        var clear_row: u16 = 0;
        while (clear_row < rule_row) : (clear_row += 1) {
            p.fillRange(0, width, clear_row, " ", .{});
        }
    }

    // ── paints only the visible lines ──
    //
    // `line_cursor` is the ABSOLUTE position of the first line: the window's
    // `.offset` (`cache_lo`) plus what the cached paragraphs before it carry.
    //
    // The `pad` is the opening hero's air. It is measured against the CONTENT's
    // real height and NOT against `last_visible - first_visible`: that range is
    // already clamped to the viewport, so it is `history_h` whenever the
    // content is short, and the first version of this compared the content
    // against itself and always decided there was no room.
    const content_lines = self.heightPrefix(self.paras.items.len) + live_lines.len;
    const hero = tui.heroFrame(self, wrap_width + 2 * hist_margin, history_h, content_lines);
    const pad = hero.pad;
    // ── paint cached paragraphs ──
    // Use `heightPrefix(para_idx)` for the absolute line position of each
    // cached paragraph. This correctly handles gaps in the cache (virtual
    // scroll means not every paragraph is parsed).
    for (self.seg_cache.items) |c| {
        const para_abs_start = self.heightPrefix(c.para_idx);
        if (para_abs_start >= last_visible) break;
        if (para_abs_start + c.height <= first_visible) continue;
        // The cached entry is the WHOLE paragraph (separator row counted in
        // already, see `layoutOne`), so its first line sits exactly at the
        // paragraph's absolute start.
        tui.drawLines(&p, c.lines, para_abs_start, first_visible, history_h, pad, hero.x_off);
    }
    // ── paint live paragraph ──
    // Its absolute position is the total height of all closed paragraphs.
    if (live_active) {
        const live_abs_start = self.heightPrefix(self.paras.items.len);
        tui.drawLines(&p, live_lines, live_abs_start, first_visible, history_h, pad, hero.x_off);
    }

    tui.drawHistoryScrollbar(&p, width, history_h, first_visible, vis.max_offset);
    // ── prompt rail (dots) ── computed every frame so the mouse handler has
    // current data, but only painted when show_prompt_dots is enabled (off by
    // default: not polished enough yet).
    self.refreshPromptDots(width, history_h);
    // The sticky header and the pill go OVER the transcript, and that is the
    // editor's own convention (a sticky line covers the content under it).
    // Reserving a row for them would move the text under the reader's eyes
    // every time they appeared, and the transcript is what they are reading.
    tui.drawStickyHeader(&p, self, width, ctx.arena);
    tui.drawNewMessagesPill(&p, self, width, history_h);
    try self.snapshotSelectableHistory(surface, history_h);
    tui.drawPromptTimeline(&p, self);
    self.paintTextSelection(surface);

    // The session's numbers are NOT painted here any more: they live in the
    // composer's footer, next to the mascot, because there is no row under
    // the input any more.
    //
    // What used to be here was a status row that answered "what model am I
    // talking to" with a face on its left and the model's name glued to its
    // right, and nothing in between: on screen it read as a stray emoticon in
    // the corner of an empty row, which is what the user called ugly. The
    // strip above the hairline said the SAME thing again ("thinking",
    // "streaming"), so the state was in two places and the numbers were in a
    // third.
    //
    // There is now ONE state surface, inside the composer, and it carries all
    // of it: the mascot, the legend and the session's own numbers.

    // ── `ask`: the model asked something ──
    //
    // The picker is opened HERE, on the UI thread, and not by the worker that
    // raised the question. That is not a style choice: the model catalog worker once
    // filled the palette while the UI thread was drawing it, with no lock on the
    // palette's own state, and the app segfaulted. The worker leaves the question
    // in the `Model`; the draw is what turns it into a picker.
    // ── modal picker (opencode style, centered) ──
    if (self.pickerSnapshot(ctx.arena)) |ps| {
        tui.drawPicker(&p, width, height, ps);
    }
    // ── modal diff viewer (33.18) ──
    if (self.diffViewerActive()) {
        tui.drawDiffViewer(&p, self, width, height);
    }
    // ── transcript screen (33.4) ──
    if (self.transcriptViewActive()) {
        tui.drawTranscriptView(&p, self, width, height);
    }
    // ── transcript search bar (33.13) ──
    if (self.transcriptSearchActive()) {
        tui.drawTranscriptSearchBar(&p, self, width, height);
    }

    // ── permission dialog (modal over the history, at the bottom) ──
    var perm_tool: []const u8 = "";
    var perm_detail: []const u8 = "";

    // ── the plan, when there is one ──
    if (plan_rows > 0) {
        tui.drawPlanBlock(&p, workspace_top, width, pl_now);
    }

    // ── `/` autocompletion (directly above the prompt) ──
    if (ac_rows > 0) {
        tui.drawAutocomplete(&p, self, input_top - ac_rows, width, ac_rows, ac_matches);
    }

    // ── the hairline ──
    //
    // ONE row, full width, `line_bright`: it is what replaces the input's box.
    // A box is two extra rows and four more glyphs to say "text goes here", and
    // the thing it is really saying is "this is the boundary of the page" —
    // which is what a rule says, for one row instead of three.
    //
    // It is NOT painted when the permission dialog is up: the modal is a
    // centred box with a clean background, and a full-width rule under it
    // points at a boundary the dialog is ignoring.
    if (!self.permActive()) p.fillRow(rule_row, "─", theme.rule);

    // Determine accent bar color based on state (reuse `act` from layout)
    const bar_style = if (act.ask) theme.warn else if (act.busy) theme.brand else theme.input_bar;

    tui.drawInput(&p, &surface, self, input_top, width, input_h, rule_row, bar_style);

    // ── the footer's row: the ONE state surface ──
    //
    // It is the last row of the composer's own well, so the bottom of the app
    // is ONE object: the sunken surface with the prompt in it and the mascot
    // under it. Nothing hangs below the input any more.
    tui.drawStateFooter(&p, input_top + input_h, width, self, act, queued, ctx.arena);

    // ── permission dialog: centered MODAL ──
    //
    // Before it was 4 lines glued right above the input box, in the middle of
    // the normal flow: with a full history they were half hidden or covered,
    // and the app looked HUNG waiting for something nobody could see. Now it is
    // a centered box with a border, a clean background and big options: there
    // is no way not to see it.
    if (self.permView(&perm_tool, &perm_detail)) {
        tui.drawPermissionModal(
            &p,
            width,
            height,
            perm_tool,
            perm_detail,
            self.permRule(),
            self.permAllowAlways(),
            self.permSandboxAvailable(),
            self.permSuggestion(),
        );
    }

    // ── `ask`: the question itself ──
    //
    // Drawn ABOVE the permission modal and BELOW the palette, and the reason is
    // priority: an `ask` and a permission cannot be open at the same time (a
    // question is asked by the model between tool calls, and the permission for
    // the NEXT tool only comes after the answer), but the palette can be open
    // over a question — you pressed ctrl+p while waiting — and then the palette
    // must win, because it is what you are typing into.
    if (self.askSnapshot(ctx.arena)) |snap| {
        if (!self.pal.active) tui.drawAskPanel(&p, width, history_h, snap, self.askMillis());
    }

    // ── modal palette (Ctrl+P): last, on top of everything ──
    //
    // Before drawing: if the worker left new models, the palette is reloaded
    // with them. This happens HERE, on the UI thread, which is the palette's
    // only owner. Only in models mode: a late catalog worker must not clobber
    // the commands list the user is looking at.
    if (self.pal.active and self.pal.mode == .models) {
        if (self.takePendingItems()) |items| {
            self.pal.setItemsOwned(items, &agent.model_groups);
        }
    } else {
        // Drop stale pending items so they do not leak into the next open.
        if (self.takePendingItems()) |items| {
            palette.freeItems(self.allocator, items);
        }
    }
    if (self.pal.active) {
        palette.draw(&p, &surface, &self.pal, width, height, self.catalogNotice(ctx.arena));
    }

    // ── copy toast: top-right, rounded border, ~2 seconds ──
    var notif_y: u16 = 2;
    if (self.copy_toast_frames > 0) {
        self.copy_toast_frames -= 1;
        tui.drawCopyToast(&p, width, height, self.copy_toast_text);
        notif_y += 4;
    }

    // ── transient notifications (33.9): top-right stack, absolutely positioned ──
    {
        var i: usize = 0;
        while (i < self.notification_len) {
            if (self.notifications[i].frames == 0) {
                // Remove expired: shift left.
                var j = i + 1;
                while (j < self.notification_len) : (j += 1) {
                    self.notifications[j - 1] = self.notifications[j];
                }
                self.notification_len -= 1;
                continue;
            }
            self.notifications[i].frames -= 1;
            tui.drawNotificationToast(&p, width, height, self.notifications[i].slice(), notif_y);
            notif_y +|= 4;
            i += 1;
        }
    }

    // ── Settings screen: FULL-SURFACE, painted last so nothing overlaps it ──
    if (self.settings_active) {
        tui.drawSettingsScreen(&p, self, width, height);
    }

    return surface;
}
