//! TUI event dispatch, split out of tui.zig (Phase 42.9).
//! The Model and all its rendering helpers stay in tui.zig; this module only
//! routes key/mouse/focus events to them. Every helper is reached through the
//! `tui.` namespace, so the boundary is explicit.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("tui.zig");
const agent = @import("agent.zig");
const commands = @import("commands.zig");
const chat = @import("chat.zig");
const diag_mod = @import("lib/diag.zig");
const palette = @import("palette.zig");

pub fn typeErasedEventHandler(ud: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *tui.Model = @ptrCast(@alignCast(ud));
    // `/copy`: a text waiting for the clipboard leaves through the RENDER.
    // It is flushed at the TOP of every event, so it goes out with the next
    // tick even if the user does not touch anything (a tick is an event, and
    // it carries an EventContext).
    self.flushCopyPending(ctx);
    switch (event) {
        .key_press => |key| {
            // Between `paste_start` and `paste_end` a key is CONTENT, not a
            // command: no submit, no shortcut, no modal navigation.
            // Escape is the escape hatch: a lost `paste_end` (11-line pastes
            // left the TUI swallowing every key, Ctrl+P included) would
            // otherwise trap all input in the paste buffer forever.
            if (self.pasting) {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.pasting = false;
                    tui.insertIntoInput(self, self.paste_buf.items);
                    self.paste_buf.clearRetainingCapacity();
                    ctx.redraw = true;
                    return;
                }
                tui.capturePasteKey(self, key);
                return;
            }
            // A rejected-input note refers to the buffer as it was; once the
            // user presses another key it is stale.
            self.input_too_long = false;
            self.input_err = "";
            // Ctrl+C: first clears the draft, the second press exits (so
            // half-typed text or a staged image is never lost in one go).
            if (key.matches('c', .{ .ctrl = true })) {
                // A modal owns Ctrl+C too: closing it is the expected action.
                // With empty input this branch used to QUIT the app from inside
                // a picker or the palette, losing the work on screen.
                if (self.anyModalActive()) {
                    if (try self.closeTopModal(ctx)) return;
                }
                if (self.hasDraft()) {
                    self.ed.clear();
                    tui.resetAutocomplete(self);
                    // The draft dies whole: an image staged for a discarded
                    // message must not ride on the next one.
                    self.draft_images.clear(self.allocator);
                    ctx.redraw = true;
                } else {
                    ctx.quit = true;
                }
                return;
            }
            // Ctrl+D DOES NOT QUIT, and it used to.
            //
            // With an empty input it was EOF (`ctx.quit = true`), and the empty
            // input is the NORMAL state when you scroll: you scroll up to read
            // something, press ctrl+d to come back down, and zode exits. `/help`
            // documents "ctrl+u / ctrl+d = scroll half a page" and the status bar
            // says "ctrl+c exits", so the app contradicted itself and the cheapest
            // way out was a key advertised as a scroll.
            //
            // Ctrl+C is the exit, which is what both places say.
            // Transcript screen (33.4): captures input while open.
            if (self.transcriptViewActive()) {
                if (self.transcriptViewHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Modal diff viewer (33.18): captures input while open.
            if (self.diffViewerActive()) {
                if (self.diffViewerHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Transcript search bar (33.13): captures input while typing query.
            if (self.transcriptSearchActive()) {
                if (self.searchBarHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Ctrl+, — the Settings screen (internal config). Distinct from
            // Ctrl+P/T so it cannot be mistaken for the model picker again.
            if (key.matches(',', .{ .ctrl = true })) {
                if (self.settings_active) {
                    self.settingsClose();
                } else {
                    self.settingsOpen();
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // The Settings screen captures every key while it is open.
            if (self.settings_active) {
                if (self.settingsHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Modal picker active: captures ALL input (before global shortcuts so
            // session-picker chords like Ctrl+A/B/V/S work; Ctrl+C quit is above).
            if (self.pickerActive()) {
                if (self.pickerHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Ctrl+P: command palette (commands and models in two columns).
            // Toggle: pressing it while the commands palette is open closes it,
            // so a stuck-open palette is escapable with the same key.
            if (key.matches('p', .{ .ctrl = true })) {
                if (self.pal.active and self.pal.mode == .commands) {
                    self.closePalette();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                agent.openCommandPalette(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (key.matches('t', .{ .ctrl = true })) {
                if (self.pal.active and self.pal.mode == .models) {
                    self.closePalette();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                agent.openModelPaletteAsync(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // An open palette OWNS its keys. Dispatch here, BEFORE the global
            // shortcuts below: otherwise Ctrl+R expands a tool instead of
            // refreshing the model catalog, and Ctrl+L wipes the transcript
            // behind the modal. Both are documented palette keys (44.1/44.2).
            if (self.pal.active) {
                if (try self.paletteKey(ctx, key)) {
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Ctrl+A: connect a provider only with an empty composer. With text
            // in the buffer Ctrl+A is `moveHome` (see editorKey): stealing it
            // here made the caret jump to the start of a typed prompt and opened
            // a palette on top of work in progress.
            if (key.matches('a', .{ .ctrl = true }) and self.ed.isEmpty()) {
                agent.openConnectPalette(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+L: clear the view.
            if (key.matches('l', .{ .ctrl = true })) {
                self.clearHistory();
                ctx.redraw = true;
                return;
            }
            // Ctrl+R: expand/collapse the last tool's result.
            if (key.matches('r', .{ .ctrl = true }) and !self.pal.active) {
                if (self.toggleLastTool()) {
                    ctx.redraw = true;
                } else {
                    self.cache_from = 0;
                    ctx.redraw = true;
                }
                return;
            }
            // 49.8: expand/collapse the tool result under the view instead of
            // always the last one. Works on any result still in scrollback.
            if (key.matches('r', .{ .alt = true }) and !self.pal.active) {
                const first = self.first_visible;
                if (self.paraAtVisibleRow(first)) |idx| {
                    if (self.toggleToolAt(idx)) ctx.redraw = true;
                }
                return;
            }
            // Phase 3: hunk navigation on the last diff (alt+] next, alt+[ prev).
            if (key.matches(']', .{ .alt = true })) {
                if (self.navigateLastDiffHunk(1)) ctx.redraw = true;
                return;
            }
            if (key.matches('[', .{ .alt = true })) {
                if (self.navigateLastDiffHunk(-1)) ctx.redraw = true;
                return;
            }
            // Ctrl+S: stash the current draft (text + staged images) and free
            // the composer; press it again on an empty box to get it back.
            if (key.matches('s', .{ .ctrl = true })) {
                if (self.hasDraft()) {
                    _ = self.stashDraft();
                } else {
                    _ = self.restoreDraft();
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+V: stage the clipboard's IMAGE for the next message.
            if (key.matches('v', .{ .ctrl = true })) {
                agent.attachClipboardImage(self);
                ctx.redraw = true;
                return;
            }
            // Ctrl+G: edit the current prompt in $VISUAL/$EDITOR.
            if (key.matches('g', .{ .ctrl = true })) {
                agent.openExternalEditor(self);
                tui.syncAutocomplete(self);
                ctx.redraw = true;
                return;
            }
            // Ctrl+F: transcript search (33.13).
            if (key.matches('f', .{ .ctrl = true })) {
                if (self.transcriptSearchActive()) self.closeTranscriptSearch() else self.openTranscriptSearch();
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+/: search past prompts. Ctrl+R is already "expand last tool
            // result", so history search uses the slash chord instead. The
            // picker's own filter box does the incremental search.
            if (key.matches('/', .{ .ctrl = true })) {
                self.openHistoryPicker();
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+O: transcript screen (33.4).
            if (key.matches('o', .{ .ctrl = true })) {
                self.toggleTranscriptView();
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // An open palette owns its keys; the only handler above that can
            // OPEN one is Ctrl+A (Connect). Its key was already consumed by
            // the palette gate at the top, so there is nothing to re-dispatch.
            // An open question WITH options: the panel is the menu, so the arrows
            // move the panel's own highlight and Enter takes it.
            //
            // It has to sit here, above the editor and above the `/` and `@`
            // popups: with a question open those popups mean nothing (there is no
            // prompt being written) and, worse, Enter with the `@` popup open
            // would accept a completion instead of answering the question. ESC is
            // handled further down and means "you decide".
            if (self.askNeedsChoice()) {
                if (key.matches(vaxis.Key.up, .{})) {
                    self.askMove(-1);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.askMove(1);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.codepoint >= '1' and key.codepoint <= '5') {
                    if (self.askAnswerIndex(key.codepoint - '1')) {
                        ctx.redraw = true;
                        try self.armTick(ctx);
                        return;
                    }
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    _ = self.askAnswerSelected();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // `/` autocompletion or `@` file completion open: navigate and accept.
            if (self.ac.active and tui.matchCount(self) > 0) {
                if (key.matches(vaxis.Key.up, .{})) {
                    if (self.ac.sel > 0) self.ac.sel -= 1;
                    tui.recomputeMatches(self);
                    ctx.redraw = true;
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    const n = tui.matchCount(self);
                    if (self.ac.sel + 1 < n) self.ac.sel += 1;
                    tui.recomputeMatches(self);
                    ctx.redraw = true;
                    return;
                }
                // Tab and Enter (no modifiers) accept the highlight: with the
                // popup open, sending a bare "mod" is not what the user wants,
                // they want /model.
                //
                // BUT if what is typed is already a COMPLETE command, Enter
                // SENDS it instead of completing again. Before it didn't:
                // "/help" + Enter only rewrote "/help " and sent nothing, so
                // you had to press it twice and it looked like the scroll had
                // nothing to show. And the other way round didn't either:
                // "/model" completed to a different command because the popup
                // sorted that one first and the match was only looked for there.
                //
                // In FILE mode Enter always accepts (a path is never "complete
                // enough to send": it is a mention inside a sentence).
                const plain_enter = key.matches(vaxis.Key.enter, .{}) and
                    !key.mods.shift and !key.mods.alt and !key.mods.ctrl;
                if (key.matches(vaxis.Key.tab, .{}) or plain_enter) {
                    // If what is typed is exactly the command, Enter SENDS.
                    // The popup is closed and it leaves the block WITHOUT
                    // `return` so the key keeps going down to the editor, which
                    // does the submit. With `return` it was lost: "/help" +
                    // Enter only rewrote "/help " and sent nothing.
                    if (plain_enter and tui.isExactMatch(self)) {
                        tui.resetAutocomplete(self);
                        ctx.redraw = true;
                    } else {
                        if (tui.acceptAutocomplete(self)) {
                            ctx.redraw = true;
                            try self.armTick(ctx);
                        }
                        return;
                    }
                } else {
                    // Escape closes the popup without deleting what was typed.
                    if (key.matches(vaxis.Key.escape, .{})) {
                        tui.setAcMode(self, .none, 0);
                        ctx.redraw = true;
                        return;
                    }
                }
            }

            // Per-message targeting (33.12): Shift+↑/↓ targets previous/next message.
            if (key.codepoint == vaxis.Key.up and key.mods.shift and !key.mods.ctrl and !key.mods.alt) {
                if (self.targetPrevMessage()) {
                    self.pushInfo("Targeted message · Shift+↑/↓ move, y copy, Esc clear");
                } else {
                    self.pushInfo("No previous message to target");
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (key.codepoint == vaxis.Key.down and key.mods.shift and !key.mods.ctrl and !key.mods.alt) {
                if (self.targetNextMessage()) {
                    self.pushInfo("Targeted message · Shift+↑/↓ move, y copy, Esc clear");
                } else {
                    self.pushInfo("No next message to target");
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Copy targeted message action (33.12).
            if (self.message_target_para != null and !self.hasInput() and !key.mods.ctrl and !key.mods.alt) {
                if (key.codepoint == 'y' or key.codepoint == 'c') {
                    if (self.targetedMessageText()) |text| {
                        commands.copyTargetedText(self, text);
                    } else {
                        self.pushInfo("Nothing to copy");
                    }
                    self.clearMessageTarget();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }

            // With an empty editor, the arrows belong to the history rather
            // than to an invisible cursor. Ask choices and open pickers have
            // already consumed their own arrows above.
            if (!self.hasInput() and !self.permActive()) {
                if (key.matches(vaxis.Key.up, .{})) {
                    self.scrollBy(1);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.scrollBy(-1);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.home, .{})) {
                    self.scrollBy(1_000_000);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.end, .{})) {
                    self.scrollBy(-1_000_000);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }

            // ESC. Three things it can mean, and the ORDER is the whole design:
            //
            // 1. an open QUESTION -> "I am not answering that", the agent decides
            //    on its own and the turn carries on. Not a cancel.
            // 2. a foreground tool -> kill the child process. Before, ESC only
            //    set the HTTP cancel flag, which does nothing to a `zig build`
            //    already running inside `process.run`: the worker stayed blocked
            //    for the rest of `timeout_seconds` and the command kept using the
            //    CPU. This is the single most misleading thing ESC did.
            // 3. otherwise -> abort the turn's stream.
            if (key.matches(vaxis.Key.escape, .{})) {
                if (self.askActive()) {
                    self.declineAsk();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (self.message_target_para != null) {
                    self.clearMessageTarget();
                    self.pushInfo("Message target cleared");
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                const killed = agent.killForeground();
                if (self.permActive()) self.answerPermission(.deny);
                if (killed > 0) {
                    agent.setStatusWithZoFmt(self, .warn, "Killed {d} running command{s}", .{
                        killed,
                        if (killed == 1) @as([]const u8, "") else @as([]const u8, "s"),
                    });
                }
                chat.cancel_current.store(true, .seq_cst);
                if (self.session) |sp| sp.bumpEscs();
                // The face follows the fact: a cancelled turn is `warn`, not
                // `done`. Set here (the UI thread) and cleared by the next
                // `streamStart`, so the mark belongs to THIS turn.
                self.cancelled = true;
                // Background jobs go too: ESC means "stop", and leaving a build
                // running in the background after the user pressed ESC is how you
                // get a laptop that is warm for the next ten minutes. Before,
                // ESC only MARKED the jobs (`requestKillAll`) and the kill ran
                // at app exit, so the build kept burning CPU for the whole
                // session — "ESC did nothing", one level down. `killNow` marks
                // and kills in one pass, on this thread, which is the one
                // allowed to touch `Child.kill`.
                const bg_killed = if (self.io_ready) self.bg.killNow(self.io) else self.bg.requestKillAll();
                if (bg_killed > 0) {
                    agent.setStatusWithZoFmt(self, .warn, "Killed {d} background command{s}", .{
                        bg_killed,
                        if (bg_killed == 1) @as([]const u8, "") else @as([]const u8, "s"),
                    });
                }
                // Nothing to kill but a turn in flight: the legend says the ESC
                // landed, so the key never looks like it did nothing.
                if (killed == 0 and bg_killed == 0 and self.isBusyFlag()) {
                    agent.setStatusWithZo(self, .warn, "Stopping\u{2026}");
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Permission dialog active: y/s/a/n decide, rest ignored.
            if (self.permActive()) {
                const cp = key.codepoint;
                // A long command is wrapped and capped in the dialog. Let the
                // user read ALL of it before deciding — approving unseen text
                // is not informed consent. These keys only move a presentation
                // offset; the decision still goes through answerPermission.
                if (key.matches(vaxis.Key.page_up, .{})) {
                    self.perm_detail_scroll -|= 2;
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.page_down, .{})) {
                    self.perm_detail_scroll = @min(self.perm_detail_scroll + 2, 64);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (cp == 'y' or cp == 'Y') {
                    self.answerPermission(.allow);
                } else if (cp == 's' or cp == 'S') {
                    // Phase 25: run a flagged bash command in a sandbox, when
                    // one is available. Not the only answer — an alternative
                    // to granting full permissions.
                    if (self.permSandboxAvailable()) self.answerPermission(.allow_sandbox);
                } else if (cp == 'a' or cp == 'A') {
                    // Only when the option is on the table. A question that
                    // must not become a standing permission does not show it,
                    // and a key that answers an invisible option is a trap.
                    if (self.permAllowAlways()) self.answerPermission(.allow_always);
                } else if (cp == 'n' or cp == 'N') {
                    self.answerPermission(.deny);
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Shift+Tab cycles the visible Build / accept-edits / Plan modes.
            //
            // Chosen because it is the key nothing else in a terminal uses, and
            // because every other coding agent already uses it for this, so it
            // does not have to be learned twice.
            //
            // It works with text in the input on purpose: you often decide to
            // switch AFTER typing the prompt ("actually, look first"), and a mode
            // you can only enter with an empty box is a mode you use once.
            if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                agent.cyclePermMode(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }

            // ── history scroll ──
            // PageUp/PageDown move a PAGE (the whole window, minus one line so
            // you can see what came before and what comes after). Before they
            // moved 5 fixed rows, which in a 40-row terminal did not feel like
            // scrolling.
            // Ctrl+U / Ctrl+D do half a page, like in less, but ONLY when the
            // composer is empty. While typing they are Emacs line-kill keys
            // (`deleteToStart` / `deleteAfter` in editorKey): the global scroll
            // branch used to swallow them, so both advertised editor commands
            // were unreachable. PageUp/PageDown and Shift+K/J always scroll.
            const k = key;
            const page: usize = @max(3, self.hist_rows -| 1);
            const half: usize = @max(2, self.hist_rows / 2);
            const editing = !self.ed.isEmpty();
            if (k.matches(vaxis.Key.page_up, .{}) or
                (k.codepoint == 'k' and k.mods.shift) or
                (k.matches('u', .{ .ctrl = true }) and !editing))
            {
                const step = if (k.matches('u', .{ .ctrl = true })) half else page;
                self.scrollBy(@intCast(step));
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (k.matches(vaxis.Key.page_down, .{}) or k.codepoint == 6 or
                (k.codepoint == 'j' and k.mods.shift) or
                (k.matches('d', .{ .ctrl = true }) and !editing))
            {
                const step = if (k.matches('d', .{ .ctrl = true })) half else page;
                self.scrollBy(-@as(isize, @intCast(step)));
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }

            // Everything else goes to the input editor.
            if (try tui.editorKey(self, ctx, k)) {
                try self.armTick(ctx);
                return;
            }
            ctx.redraw = true;
        },
        .tick => {
            // The tick always rearms (1.5).
            //
            // Before it only rearmed "if there is work", and `busy`/`dirty`
            // have windows where both are false (e.g. between `streamEnd` and
            // `pushToolStart`, with a session write(2) and a DEFLATE-9 in
            // between). A tick landing there left `App.timers` EMPTY, and since
            // the worker has neither a pointer to the `EventContext` nor to
            // the event queue, there was no way to request a frame: the screen
            // stayed dead until a key was pressed, the wheel moved or the
            // window was resized.
            //
            // The cost of always rearming is one timer every 120 ms at idle,
            // which only repaints if something changed; the alternative is an
            // app that goes dead with no explanation.
            self.tick_armed = false;
            self.motion_tick_count +%= 1;
            // Phase 37: sample RSS about once per second (the tick fires every
            // ~120 ms). The ring is fixed and allocation-free, so this is safe
            // from the UI thread and gives /diag a growth history.
            if (self.motion_tick_count % 8 == 0 and self.io_ready) {
                self.diag_seq +%= 1;
                var s = diag_mod.sample(self.io);
                s.seq = self.diag_seq;
                self.diag_monitor.push(s);
            }
            // Phase 19: a parked turn may need a scheduled prompt or a periodic
            // check-in even when no model iteration is running. The same door
            // (appendHarnessPrompt) is used; both are suppressed while busy.
            agent.drainScheduleNotifications(self);
            const a = self.activity();
            const asked = self.redraw_requested.swap(false, .seq_cst);
            // `mascotMoved` and not "there is an animation": at rest the face
            // changes once every couple of seconds, and the tick fires eight
            // times a second in between. The face is the ONLY thing that moves
            // when the app is otherwise idle, so without this the idle track
            // (blinks, exhale, yawn) was only ever painted when a key happened
            // to arrive — which is why it read as a frozen glyph.
            // Phase 4: mascot motion repaints are disabled by reduced/no animation.
            const mascot_moved = self.mascotMoved();
            if (mascot_moved) self.mascot_motion_repaints +%= 1;
            // Phase 32.1: advance the three-way count pill by +1 per tick so it
            // animates toward the target like the tps rolling window.
            const verify_moved = self.verify_counter.tick();
            if (verify_moved) self.dirty = true;
            if (asked or a.busy or a.dirty or a.perm or a.picker or self.pal.active or mascot_moved or verify_moved) {
                ctx.redraw = true;
            }
            // The queue is drained here and not by the worker: `startChat`
            // enqueues when busy, and the worker thread has no `EventContext`
            // to start the next turn with, so until now a queued prompt was
            // shown in the footer and never ran. The tick is the UI thread
            // waking up anyway, and the turn has just ended by then.
            if (self.takeQueuedWhenIdle()) |turn| {
                agent.startTurn(self, turn.text, turn.mode, turn.bash_allow_rules, turn.expand_cmdsubst) catch |err| {
                    self.pushInfoFmt("Error: {t}", .{err});
                };
                self.allocator.free(turn.text);
                ctx.redraw = true;
            }
            // The model catalogue on disk refreshes itself, quietly, about
            // every quarter hour — only while idle, by the worker that already
            // does the startup warmup. The palette never waits on the network
            // for a list the user expected to be current.
            agent.maybeRefreshCatalog(self);
            agent.maybeRefreshModelPalette(self);
            try self.armTick(ctx);
        },
        .init => {
            ctx.redraw = true; // first frame without waiting for a key
            try self.armTick(ctx);
        },
        .focus_in => {
            self.focused = true;
            ctx.redraw = true;
            try self.armTick(ctx);
        },
        // Losing focus ends any gesture. Both flags had exactly ONE exit, a
        // `.release` that reaches this handler, and three ways to not get one:
        // the window losing focus (the release goes to the window you clicked),
        // the pointer leaving the surface (vaxis's `mouse_leave` carries no
        // coordinates), and a release that vxfw drops before it reaches us
        // because it landed outside the PREVIOUS frame's surface.
        //
        // A stranded `scrollbar_dragging` is the loud one: the flag makes every
        // later `.drag` in the history `return` early after a `scrollTo`, so a
        // text drag could never start a selection again and the first drag
        // anywhere jumped the scroll to wherever the pointer happened to be.
        .focus_out => {
            self.focused = false;
            self.cancelMouseGestures();
            ctx.redraw = true;
        },
        .mouse_leave => {
            self.cancelMouseGestures();
            ctx.redraw = true;
        },
        .paste_start => {
            self.pasting = true;
            self.paste_buf.clearRetainingCapacity();
        },
        .paste_end => {
            self.pasting = false;
            // Route bracketed paste to the active key prompt (provider connect),
            // otherwise insert into the composer. Newlines/control chars are
            // filtered by the key buffer so a pasted API key stays valid.
            if (self.pal.active and self.pal.mode == .key_prompt) {
                self.pal.appendKeyText(self.paste_buf.items);
            } else {
                tui.insertIntoInput(self, self.paste_buf.items);
            }
            self.paste_buf.clearRetainingCapacity();
            ctx.redraw = true;
        },
        .paste => |data| {
            // OSC-52 clipboard paste (the terminal already aggregated it).
            if (self.pal.active and self.pal.mode == .key_prompt) {
                self.pal.appendKeyText(data);
            } else {
                tui.insertIntoInput(self, data);
            }
            ctx.redraw = true;
        },
        .mouse => |m| {
            // A modal owns the mouse while it is open: every event goes to it
            // and the transcript behind it does not scroll, select or drag.
            // Before, the wheel fell through to the history and the modal just
            // sat there while the text behind it moved.
            if (self.pal.active) {
                const r = palette.handleMouse(&self.pal, self.frame_w, self.frame_h, m);
                if (r.changed) ctx.redraw = true;
                if (std.meta.activeTag(r.action) != .none) try self.applyPaletteAction(ctx, r.action);
                return;
            }
            // The prompt rail's hover. It is read on motion only (not on drag:
            // a drag belongs to the gesture in progress) and it fills the dot
            // under the pointer, which is the only thing saying it is clickable.
            // Skip while overlays own the surface so hover never gets stranded.
            if (m.type == .motion and !self.scrollbar_dragging and !self.selecting_text and
                !self.pal.active and !self.askActive() and !self.permActive())
            {
                const hot: ?usize = if (self.promptDotAt(m)) |d| d.para else null;
                if (hot != self.prompt_dot_hover) {
                    self.prompt_dot_hover = hot;
                    ctx.redraw = true;
                }
                return;
            }
            if (m.type == .motion and self.prompt_dot_hover != null and
                (self.pal.active or self.askActive() or self.permActive()))
            {
                self.prompt_dot_hover = null;
                ctx.redraw = true;
                return;
            }
            if (self.scrollbar_dragging) {
                switch (m.type) {
                    .drag => {
                        if (m.row >= 0 and @as(usize, @intCast(m.row)) < self.hist_rows) {
                            self.scrollTo(tui.scrollbarOffset(
                                @intCast(m.row),
                                self.hist_rows,
                                self.max_offset,
                            ));
                        }
                        ctx.redraw = true;
                        return;
                    },
                    .release => {
                        if (m.row >= 0 and @as(usize, @intCast(m.row)) < self.hist_rows) {
                            self.scrollTo(tui.scrollbarOffset(
                                @intCast(m.row),
                                self.hist_rows,
                                self.max_offset,
                            ));
                        }
                        self.scrollbar_dragging = false;
                        ctx.redraw = true;
                        return;
                    },
                    else => {},
                }
            }
            if (self.selecting_text) {
                switch (m.type) {
                    .drag => {
                        if (self.clampedSelectionPoint(m)) |point| self.selection_end = point;
                        ctx.redraw = true;
                        return;
                    },
                    .release => {
                        if (self.clampedSelectionPoint(m)) |point| self.selection_end = point;
                        self.selecting_text = false;
                        try self.copySelectedText(ctx);
                        ctx.redraw = true;
                        return;
                    },
                    else => {},
                }
            }
            if (m.type == .press and m.button == .left and
                !self.pal.active and !self.askActive() and !self.permActive())
            {
                // The rail comes FIRST: its column is inside the selectable
                // area, and a click there has to jump to a prompt instead of
                // starting a text selection of one character.
                if (self.promptDotAt(m)) |d| {
                    self.jumpToPrompt(d);
                    ctx.redraw = true;
                    return;
                }
                if (self.max_offset > 0 and m.col >= 0 and m.row >= 0 and
                    @as(usize, @intCast(m.col)) == self.selectable_width -| 1 and
                    @as(usize, @intCast(m.row)) < self.hist_rows)
                {
                    self.scrollbar_dragging = true;
                    self.scrollTo(tui.scrollbarOffset(
                        @intCast(m.row),
                        self.hist_rows,
                        self.max_offset,
                    ));
                    ctx.redraw = true;
                    return;
                }
                // A click inside the composer places the caret. The row map
                // was published by drawInput from the SAME wrap the painter
                // used, so no rendered string has to be parsed to find the
                // byte offset. Tag rows (staged images) map to cursor 0.
                if (m.col >= 3 and m.row >= 0 and
                    @as(u16, @intCast(m.row)) >= self.input_top_row)
                {
                    const rel: usize = @intCast(@as(u16, @intCast(m.row)) - self.input_top_row);
                    if (rel < self.input_rows) {
                        const start = self.input_row_starts[rel];
                        const end = self.input_row_ends[rel];
                        const col: usize = @as(usize, @intCast(m.col)) - 3;
                        const off = @min(start + col, end);
                        const bytes = self.ed.text();
                        var pos = @min(off -| self.input_text_start, bytes.len);
                        while (pos > 0 and (bytes[pos] & 0xC0) == 0x80) pos -= 1;
                        self.ed.setCursor(pos);
                        ctx.redraw = true;
                        return;
                    }
                }
                if (self.selectionPoint(m)) |point| {
                    self.selection_start = point;
                    self.selection_end = point;
                    self.selecting_text = true;
                    ctx.redraw = true;
                    return;
                }
            }
            // The wheel arrives as button 64/65 with type=press.
            if (m.type != .press) return;
            if (m.button == .left and
                m.row >= 0 and @as(u16, @intCast(m.row)) == self.scroll_bottom_row and
                m.col >= 0 and @as(u16, @intCast(m.col)) >= self.scroll_bottom_start and
                @as(u16, @intCast(m.col)) < self.scroll_bottom_end)
            {
                self.scrollBy(-1_000_000);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            switch (m.button) {
                // CAREFUL: `self.scroll` is a usize. `self.scroll -= 3` with
                // the scroll at 0 underflows and brings the app down (integer
                // overflow -> panic), which is what happened scrolling down
                // with the wheel while at the very top. `scrollBy` is what
                // saturates at 0.
                .wheel_up => self.scrollBy(3),
                .wheel_down => self.scrollBy(-3),
                else => return,
            }
            ctx.redraw = true;
        },
        .winsize => ctx.redraw = true,
        else => {},
    }
}
