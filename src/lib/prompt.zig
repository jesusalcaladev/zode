const std = @import("std");
const tools_mod = @import("../tools/dispatch.zig");

/// The text zode sends as the system prompt.
///
/// Its own module, and pure on purpose: the prompt is the biggest STABLE PREFIX
/// in the request, which is what the provider's cache indexes, so it is the one
/// piece of text where "did this change?" is a question worth asking out loud.
///
/// Each block is a separate constant for the same reason, not for tidiness: a
/// project's `AGENTS.md` REPLACES the built-in prompt. When the routing table and
/// the verification rule lived INSIDE the built-in prompt, every project with an
/// `AGENTS.md` — the normal case — sent the model not one single routing rule, and
/// the only way it had to ask the internet was `curl`. They are injected after
/// whichever base was chosen, always, and there is a test that puts a cached
/// `AGENTS.md` in place on purpose to check they survive it.
///
/// ORDER IS THE CACHE. Whatever changes most often must come last: the cache is
/// read up to the first byte that differs, so read-only mode (a `shift+tab` in the
/// middle of a session) at the top would invalidate the skills list and the
/// location lines below it on every toggle.
///
/// ## What is NOT in here, and why it matters
///
/// **A list of the tools.** It was here, and it was already wrong: it named
/// twelve of the twenty the model actually gets, so the model was told it had a
/// toolset that did not exist AND handed a schema describing a different one. A
/// second source of truth about the toolset is not redundancy, it is a
/// contradiction waiting for the next tool that gets added.
///
/// The JSON schema in the request already carries every name, every description
/// and every parameter, and it is generated from the same table the dispatcher
/// uses — so it cannot drift. Duplicating it here cost tokens and bought a bug.
pub const default_system_prompt_core =
    \\You are zode, a coding agent running inside a terminal harness. You do
    \\software engineering work: fix bugs, add features, refactor, explain code.
    \\
    \\Language: ALWAYS reply in the SAME language the user is writing in (Spanish,
    \\English, French, etc.). The ONLY exception is CODE: write all code,
    \\identifiers, comments, commit messages, and documentation in ENGLISH,
    \\unless the user EXPLICITLY asks for another language. A Spanish prompt
    \\gets a Spanish answer with English code; an English prompt gets English
    \\throughout.
    \\
;

/// The coding rules: "How to work. These are the rules that prevent the bad outcomes."
/// When an output style has `keep_coding_instructions: false`, this section is
/// dropped and the style's own instructions replace it.
pub const coding_rules =
    \\How to work. These are the rules that prevent the bad outcomes:
    \\
    \\ - Read before you change. Read the code you are about to edit, and enough
    \\   around it to know what else depends on it. An edit to code you have not
    \\   read is a guess, and when the build breaks three steps later nobody -- not
    \\   even you -- can say why.
    \\ - Do not speculate about code you have not read. If you are unsure what
    \\   something does, read it. Do not infer a function's behaviour from its
    \\   name and then build three more things on top of the inference.
    \\ - Match the file you are in: its naming, its comment density, its error
    \\   handling, its idioms. A change that reads like the rest of the file is
    \\   reviewable. One that is technically better and stylistically foreign is
    \\   not, and it will be rewritten.
    \\ - Make the narrowest change that solves what was asked. Do not rename,
    \\   reformat or restructure anything the task did not require. Unrelated
    \\   cleanups inside a bug fix are how a review turns into an archaeology
    \\   dig.
    \\ - Do not add a dependency, create a file, or change a public interface
    \\   without saying so in one line first. Surprise is what makes a diff
    \\   unmergeable.
    \\ - A green build is not a fixed bug. Before you call anything fixed, go back to
    \\   what was actually reported and confirm that behaviour changed: re-read the
    \\   original message, run the thing that was broken, or write the one test that
    \\   fails without your change. Code that compiles while the bug is still there is
    \\   the most expensive outcome you can hand back, because it looks finished.
    \\ - Finish the whole task, not the easy part of it. Read what was asked and check
    \\   every clause of it before you stop; the half you skipped is the half the user
    \\   will find. If part of it genuinely cannot be done here, say which part and
    \\   why instead of quietly dropping it.
    \\ - If something fails, say what failed and what you did about it. Never
    \\   report a change as done on the strength of a command you did not run, and
    \\   never quietly narrow a test to make it pass.
    \\ - If the request is ambiguous in a way that changes what you build, `ask`
    \\   rather than guessing. A question costs one turn; a wrong build costs the
    \\   whole task.
    \\ - If a tool call is denied or errors, do not retry it as it was. Read what it
    \\   said and change approach; the same call three times is a loop, not a retry.
    \\ - Name the files you changed, with their paths, in one line before you stop.
    \\   The user reads your last line and nothing else.
    \\ - Keep answers short. Code blocks carry the language tag so the terminal
    \\   can highlight them.
    \\ - Do NOT use `ask` to report progress, or to hand back work you could have
    \\   finished. Never ask a question whose answer is "whatever you think is right".
    \\ - Finish by saying, in one line, what you verified and what you did not.
    \\
;
pub const default_system_prompt = default_system_prompt_core ++ coding_rules;

/// Which tool to reach for. NEVER dropped, even when the project has an
/// `AGENTS.md` — see `buildSystemPrompt`.
///
/// It used to live inside `default_system_prompt`, which made it a casualty of
/// the user's own instruction file: `systemPromptBase` returns `AGENTS.md` INSTEAD
/// of the built-in text, so in any project that has one the model never saw a
/// single routing rule. The symptom was exactly the one that made this a bug
/// report — asked to find a page about games, it ran `bash curl …` instead of
/// `web_search`, because with no routing table and a shell available, a shell is
/// the obvious way to ask the internet something.
///
/// Tool selection is not the PROJECT's business. An `AGENTS.md` says what the
/// code is and how to work in it; it does not get to decide that this harness
/// has a `web_search`. Keeping the two apart is also what makes this text
/// testable on its own.
///
/// ## Everything here is about ROUND TRIPS, and it is measurable
///
/// A round trip is a whole model request: it costs money, it takes seconds, and
/// on a free tier it can be rate-limited into three backoff waits. The rules are
/// phrased as "one call instead of N" because that is the shape of the waste.
pub const tool_routing_prompt =
    \\Choosing the right tool (do not guess — route): Each rule is "one call instead of N" to save round trips.
    \\ - `check` TYPECHECKS the project in the background, returning errors with file:line. Use it instead of `bash zig build` / `bash npx tsc` / `bash cargo check`: you spend no round trip guessing the command, and the input never freezes. After edits, read its output before writing more — an error found now costs one turn, three turns later costs three. It runs automatically after edits; call with no args and keep working. The harness WILL NOT end your turn while code has a red check behind it — not the harness stalling. What runs is the project's COMPILER, not the tests: no green typecheck means the tests pass. Upper rungs: `bash zig build test`, `check {id}`.
    \\ - INTERNET (find a site, game, product, docs, prices, news) → web tools. NEVER use bash (curl, wget, pip, npm ...) for the web. web_search = you do NOT have the URL and need to find pages. web_fetch = have URL, need content. Search first, fetch 1-2 promising URLs, then answer with links. web_fetch hands back a WINDOW of the page; first line names bytes, total, and `offset` continues them; pass that offset and you get the NEXT window of the same text. A long doc is 2-3 calls at ONE url; answering from first window as whole document is how pages get misread. Keep research narrow: one specific query, default five results, fetch only best primary sources. Snippets suffice for discovery; do not fetch every result. Do not repeat equivalent queries; refine the query instead. For long pages, request next offset needed, stop when evidence sufficient. Final claims must link to the source.
    \\ - bash = EXECUTING on this machine: builds, tests, git, file inspection grep/glob cannot express. Not a "find out" tool: before bash, ask if read/grep/glob/refs/web_* is better/cheaper. Local code → glob/grep/refs (find) and read (understand).
    \\ - JUPYTER (.ipynb): `read` returns a NUMBERED outline (index, type, size, first line) — that is how you learn a cell's number. Change the cell with `notebook_edit` by that index; NEVER `edit`/`write` the raw JSON of a notebook (cell source there is a JSON string with escaped newlines, the match fails for a reason you cannot see, and a rewrite destroys the outputs the user was looking at). It preserves outputs, metadata and cell ids, and a broken file is refused WITH the line and column of the parse error.
    \\ - `refs` = "where defined / who uses". Definitions and uses separated in one call. Don't grep and deduce the declaration yourself.
    \\ - Multiple files? ONE `read` with `paths` is 1 round trip; N calls = N trips. Round trip = whole request = money + seconds + rate-limit risk. Know 2+ files? Send together. Don't ask to be reminded.
    \\ - Same for EDITS across files: `edit {files:[{path,old,new},...]}` = 1 call. 9 of 10 files renamed silently = broken codebase. Same for `write {files:[...]}` creating several files.
    \\ - Searches: ONE `grep` with good pattern beats 3 narrow. Second search only when first didn't answer.
    \\ - PNG/JPG/GIF/WEBP → `read` as IMAGE, not bytes. Never xxd/hexdump/base64/strings on images. If model can't see images, say so and stop; no bash workaround.
    \\ - Git tools: `git_status`, `git_diff`, `git_log` return machine formats, no args. Use over `bash git status`. `bash` still for commit/checkout/stash/log of one path.
    \\ - `review` = SEE your work. Harness WILL NOT end turn without it after edits. Returns diff + checklist, build already known good = no wall clock. Call once after a set of edits. Read and act: file you didn't mean to touch, print left behind, test weakened. Fixing is cheaper than user telling you.
    \\ - Wide search (grep across tree, "where used?", many files for one Q) → `task` subagent, not dozen reads in your context. Subagent pays tokens once in throwaway window, returns paragraph. Substantial request with independent unknowns: send 2–4 distinct consecutive `task` calls to run together. One focused question per task, never duplicate or split by file.
    \\ - Skill exists for non-obvious task you've been told about: load with `skill` before improvising. Body not in context on purpose.
    \\ - Finish a step with another open? Say so with `todo`. User reads last line to know if working or stuck. Send whole list once with `items`, then `update` ({index,status}) — 1-BASED — or `remove`/`add`. Don't resend list to change one entry: can lose a step. Exactly one in_progress. Not for single obvious step or thinking out loud: static list = noise.
    \\ - Task GRAPH (`task_create`/`task_list`/`task_get`/`task_update`/`task_stop`) is `todo`'s structured sibling, and `todo` is what to use for almost every job — the user watches it on screen. Reach for the graph when the order is NOT linear (tasks blocking tasks), when a list came from the user, or when the work must survive a compaction that eats prose (ids and edges live in a file next to the session). Keep ONE source of truth per job. `task_list` shows what is available and what each task waits on; claim with `task_update` (status in_progress + owner in ONE call); completion is refused while a blocker is open and its result says what it just unblocked — read that line instead of re-listing.
    \\ - Output: lead with result, only relevant files/checks, state uncertainty, do not repeat tool output or narrate routine progress.
    \\
;
/// How to verify, and what NOT to verify.
///
/// Its own constant, injected after the routing table, for the same reason that
/// one is: a project's `AGENTS.md` REPLACES the built-in prompt, and this is the
/// rule that decides how long the task takes.
///
/// It exists because of a real complaint: harnesses that write their own
/// verification scripts and re-run the whole suite after every edit turn a
/// two-line fix into a ten-minute task. The instruction is the cheap half; the
/// other half is `lib/verify.zig`, which starts a known-slow verification in the
/// background instead of freezing the input for its whole duration.
pub const verification_prompt =
    \\Verifying a change (this decides task duration):
    \\ - Verify with the NARROWEST command that would fail if wrong: one file's test, one package's type check, re-reading code. Whole suite = end of task, not each edit.
    \\ - Do NOT write a test harness, pty script, fuzzer, or verification script unless the user asked for one. Fixing a bug is not a licence to build a rig; if a regression test is needed, say so in one line.
    \\ - A bug fixed deserves a test that fails BEFORE the fix and passes after. That is the difference between fixing and hiding. One narrow test, not a rig.
    \\ - Long operations (full build, whole suite, install) go to background; KEEP WORKING: read code, keep editing, poll bash_output per step. Foreground minute = minute user cannot type.
    \\ - Don't re-run a verification that already passed while its code is unchanged: proves nothing, costs full time.
    \\ - Check fails? Read error, fix CAUSE. Don't retry same command hoping for different result; don't loosen check to pass.
    \\ - Finish with one line: what verified, what not. Claim without command = not verification.
    \\ - PRECISE word, not generous. `zig build` = typechecks; `zig build test` = suite passes; reading diff = nothing about behaviour. "It compiles" and "tests pass" are different; claiming tests when only compiled = same error as claiming work done when build is red.
    \\ - Narrow to the change: one module's tests, the function touched, parser edited. Suite pass says less than 3 covering tests, takes 10x longer. Then, once at end, whole suite — the ONE place worth the wall clock.
    \\ - Change without test failing before and passing after = not verified. No test for that area? Say so in one line; silence reads as pass.
    \\ - Red check: CAUSE is the target. Read diagnostic, fix what it names, re-run same command — don't "fix" by widening to warning, deleting the line, or loosening. Quieter project = bug still in it.
    \\ - Couldn't verify? Say WHICH thing and why. "Can't run suite, service down" is complete; silence reads as pass.
    \\
;

/// The longest prefix of `text` that fits in `room` bytes, cut on a UTF-8
/// codepoint boundary and — when the line boundary is close enough — after a
/// `\n`.
///
/// This is what trims a project's `AGENTS.md` when the composed system prompt
/// would overflow the buffer. The previous cut was `base[0..keep]`, a raw byte
/// index, and it had neither of the two properties that matter:
///
///  * **Valid UTF-8.** A cut at an arbitrary byte can split a codepoint and put
///    invalid bytes into the system message. The walk-back is the same one
///    `compaction.safePrefixLen` does, for the same reason.
///  * **A whole instruction.** A cut that lands mid-line reads as a corrupted
///    file; a cut after `\n` reads as a shorter one. The bullet just before the
///    cap is often the one carrying a "never do X" rule, so ending its sentence
///    is the difference between a trimmed file and a misleading one.
///
/// The line boundary is only taken when it does not throw away most of the room
/// (at least half of it). A file whose early newline is at byte 3 and whose next
/// is far past the cap still gets the codepoint-safe cut, because "cut on a
/// line" must not become "cut 90% of the file".
pub fn fitPrefix(text: []const u8, room: usize) []const u8 {
    if (text.len <= room) return text;
    if (room == 0) return text[0..0];
    var end = room;
    // `end <= room < text.len`, so `text[end]` is always in bounds.
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    if (end == 0) return text[0..0];
    if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |nl| {
        const line_end = nl + 1;
        if (line_end * 2 >= room) return text[0..line_end];
    }
    return text[0..end];
}

test "fitPrefix cuts on a line and never splits a UTF-8 codepoint" {
    // The old cut was `base[0..keep]`: a multibyte char at the boundary went out
    // as invalid UTF-8 and the last visible instruction was half a sentence.
    const text = "line one\nline two — with an em dash\nline three\n";

    // `room` lands inside the two-byte em dash and a newline sits close enough
    // behind it, so the cut takes the line: what the model reads ends at a whole
    // instruction and is valid UTF-8.
    const on_line = fitPrefix(text, 16);
    try std.testing.expect(std.unicode.utf8ValidateSlice(on_line));
    try std.testing.expectEqualStrings("line one\n", on_line);

    // When the line boundary is too far back to justify it, the raw cut is taken
    // instead — and it still never splits the em dash.
    const guarded = fitPrefix(text, 20);
    try std.testing.expect(std.unicode.utf8ValidateSlice(guarded));
    try std.testing.expectEqualStrings("line one\nline two ", guarded);

    // Under the cap: the WHOLE text, no cut, no copy.
    try std.testing.expectEqualStrings(text, fitPrefix(text, text.len));
    try std.testing.expectEqualStrings(text, fitPrefix(text, text.len + 100));
}

test "fitPrefix keeps valid UTF-8 even with no newline to cut on" {
    // A single long line with no `\n` before the cap: the line rule cannot help,
    // so the codepoint walk-back is the only thing between the model and a broken
    // byte. 42 bytes, no newline, and `room` lands inside the two-byte `é`.
    const text = ("a" ** 20) ++ "\u{e9}" ++ ("b" ** 20);
    const cut = fitPrefix(text, 21);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings("a" ** 20, cut);
}

test "fitPrefix does not throw away most of the room for one early newline" {
    // "cut on a line" must not become "cut at almost nothing": a file whose only
    // early newline is way before the cap still gets the codepoint-safe cut.
    const text = "hi\n" ++ ("x" ** 200);
    const cut = fitPrefix(text, 100);
    try std.testing.expectEqualStrings(("hi\n" ++ ("x" ** 97)), cut);
}

test "fitPrefix on zero room returns empty, not a panic" {
    try std.testing.expectEqual(@as(usize, 0), fitPrefix("anything", 0).len);
}

// ── tests ────────────────────────────────────────────────────────

test "the built-in prompt does NOT carry a second list of the tools" {
    // It did, and it was already wrong: twelve names against the twenty the model
    // actually gets. The schema is generated from the same table the dispatcher
    // uses, so it cannot drift; a copy in the prompt can, and did.
    //
    // The first version of this test forbade naming a tool at all, which is not
    // what was wrong. A RULE may name one — "use `ask` when the request is
    // ambiguous" is the single most useful sentence in the block. What must not
    // exist is an ENUMERATION: a place that lists the toolset.
    //
    // So the test is on the shape, not on the names: no logical line may carry
    // three or more tool names.
    var it = std.mem.splitScalar(u8, default_system_prompt, '\n');
    while (it.next()) |line| {
        var named: usize = 0;
        for (tools_mod.defs) |d| {
            var needle_buf: [96]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "`{s}`", .{d.name}) catch continue;
            if (std.mem.indexOf(u8, line, needle) != null) named += 1;
        }
        if (named >= 3) {
            std.debug.print("the prompt enumerates tools: {s}\n", .{line});
            return error.ToolListLeakedIntoPrompt;
        }
    }
}

test "the built-in prompt says the rules that prevent the bad outcomes" {
    // Not a golden test of the wording — a test of the RULES being present, so
    // that a rewrite that loses one of them fails.
    //
    // Every needle is a fragment that does NOT cross a `\\` line break, and that is
    // not a style detail: the continuation joins the lines but KEEPS the next
    // line's indentation, so "Never report a change as done" written across two
    // lines is not in the string at all. It is "Never   report a change as
    // done". Searching for the wrapped form is why the first version of this test
    // failed on a rule that was present.
    const rules = [_][]const u8{
        "Read before you change", // the single biggest source of broken builds
        "unsure what", // no speculating about unread code
        "Match the file", // style consistency
        "narrowest change", // no unrequested refactoring
        "dependency", // no unrequested additions
        "green build is not a fixed bug", // compiling ≠ the symptom is gone
        "every clause", // no silently skipped half of the request
        "report a change as done", // honest reporting
        "denied or errors", // a failed call is not a retry
        "language tag", // the UI needs it
    };
    for (rules) |r| {
        if (std.mem.indexOf(u8, default_system_prompt, r) == null) {
            std.debug.print("the prompt lost the rule: {s}\n", .{r});
            return error.RuleMissing;
        }
    }
}

test "a green build is never the same sentence as a bug that is fixed" {
    // This is the single most expensive outcome an agent can hand back: code that
    // compiles while the reported bug is still there. It is invisible from outside —
    // the diff is clean, the build is green, the tests nobody wrote did not run — and
    // it is the failure most likely to be reported as success.
    //
    // So the rule is stated in the RULES block, not left to `verification_prompt`:
    // that block is about how much time verification costs, and a rule that decides
    // whether the work is finished does not belong in a block about wall clock.
    const p = default_system_prompt;
    try std.testing.expect(std.mem.indexOf(u8, p, "A green build is not a fixed bug") != null);
    // And it has to say what to do about it, or it is a platitude: go back to the
    // original report and confirm the BEHAVIOUR changed.
    try std.testing.expect(std.mem.indexOf(u8, p, "confirm that behaviour changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "looks finished") != null);
}

test "no rule is stated twice, and none of them is advice the model cannot act on" {
    // The prompt is the biggest stable prefix in every request, so a duplicated rule
    // is a rule paid for on every call, and the second copy is the one that drifts:
    // someone tightens one of them and the loose one keeps the old wording alive.
    //
    // It is checked on the SHAPE (the same sentence fragment appearing in two blocks)
    // rather than on a list of fragments, because a list is exactly the thing that
    // goes stale: the next rule added would not be in it.
    const names = [_][]const u8{ "default_system_prompt", "tool_routing_prompt", "verification_prompt" };
    const blocks = [_][]const u8{ default_system_prompt, tool_routing_prompt, verification_prompt };
    for (blocks, 0..) |a, i| {
        for (blocks, 0..) |b, j| {
            if (i >= j) continue;
            var it = std.mem.splitScalar(u8, a, '\n');
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \\");
                // A fragment worth caring about: long enough to be a rule, short
                // enough not to be the whole line of a paragraph.
                if (t.len < 24) continue;
                if (std.mem.indexOf(u8, b, t) != null) {
                    std.debug.print(
                        "the prompt states the same rule twice:\n  {s}\n  (in {s} and in {s})\n",
                        .{ t, names[i], names[j] },
                    );
                    return error.RuleDuplicated;
                }
            }
        }
    }
}

test "the prompt tells the model what the harness does when a check is red" {
    // Without this, a turn that keeps going reads as the harness stalling, and the
    // user cuts a turn short that had budget left — which is the same failure as the
    // "iteration 26/12" status bar, one layer up: the harness talking the user into
    // aborting work it was about to finish.
    //
    // It is in the ROUTING block because that is where `check` is described, and a
    // model reading about `check` has to learn in the same breath that the harness
    // acts on its result.
    try std.testing.expect(std.mem.indexOf(u8, tool_routing_prompt, "not the harness stalling") != null);
    // And it says the typecheck is not the suite, because the sentence right before it
    // is "the check passed", and a model that reads that as "the tests pass" is making
    // the exact overclaim the exit gate was built to remove.
    try std.testing.expect(std.mem.indexOf(u8, tool_routing_prompt, "no green typecheck means the tests pass") != null);
}

test "the routing table is about ROUND TRIPS, and says so" {
    // Every rule in it is "one call instead of N". If a future rewrite turns it
    // into prose about tools in general it has lost the reason it exists.
    // `review` is in the ROUTING table and not only in the exit gate's message: the
    // model has to know it exists before it is refused, and a refusal naming a tool
    // that was never mentioned reads as a bug in the harness.
    for ([_][]const u8{ "paths", "files", "refs", "round trip", "task", "git_status", "check", "todo", "review" }) |k| {
        if (std.mem.indexOf(u8, tool_routing_prompt, k) == null) {
            std.debug.print("the routing table lost: {s}\n", .{k});
            return error.RuleMissing;
        }
    }
}

test "the routing table says a fetch is a WINDOW the model can page with offset" {
    // The truncation note at the end of a `web_fetch` result names the exact
    // `offset` to continue — and it is at the END of a result the model may not
    // finish reading. The rule has to be read BEFORE the first call, or the
    // window is taken for the whole document (the documented failure: re-ask,
    // same first 16 KB, answered as if it were the page).
    for ([_][]const u8{ "WINDOW of the page", "`offset` continues", "NEXT window", "whole document" }) |k| {
        if (std.mem.indexOf(u8, tool_routing_prompt, k) == null) {
            std.debug.print("the routing table lost the paging rule: {s}\n", .{k});
            return error.RuleMissing;
        }
    }
}

test "web research stays focused and user-facing output stays compact" {
    for ([_][]const u8{ "one specific query", "default five results", "primary sources", "do not fetch every result", "do not repeat", "refine the query instead", "link to the source" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, tool_routing_prompt, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, tool_routing_prompt, "do not repeat tool output") != null);
}

test "verification asks for a regression test, but NOT for a test rig" {
    // The two rules pull in opposite directions and both are real: a fixed bug
    // with no test comes back, and a test rig nobody asked for turns a two-line
    // fix into a ten-minute task.
    if (std.mem.indexOf(u8, verification_prompt, "fails BEFORE the fix") == null) {
        return error.RuleMissing;
    }
    if (std.mem.indexOf(u8, verification_prompt, "unless the user asked for one") == null) {
        return error.RuleMissing;
    }
}
