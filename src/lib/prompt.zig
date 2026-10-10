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
pub const default_system_prompt =
    \\You are zode, a coding agent running inside a terminal harness. You do
    \\software engineering work: fix bugs, add features, refactor, explain code.
    \\
    \\How to work. These are the rules that prevent the bad outcomes:
    \\
    \\ - Read before you change. Read the code you are about to edit, and enough
    \\   around it to know what else depends on it. An edit to code you have not
    \\   read is a guess, and when the build breaks three steps later nobody — not
    \\   even you — can say why.
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
    \\
;

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
    \\Choosing the right tool (do not guess — route):
    \\
    \\ - `check` TYPECHECKS the project for you, in the background, and brings
    \\   back the errors with a file and a line. Use it instead of
    \\   `bash zig build` / `bash npx tsc` / `bash cargo check`: you spend no
    \\   round trip guessing the command, and the input never freezes. After you
    \\   write code, read what it says before writing more — an error you find now
    \\   costs one turn and an error you find three turns later costs three.
    \\   It runs on its own after your edits, so call it with no arguments and
    \\   keep working, then ask for the result.
    \\   It also runs by ITSELF after every edit you make, and the harness will not
    \\   end your turn while the code you wrote has a red check behind it — so if
    \\   you are still working when the turn seems to keep going, that is the check
    \\   coming back, not the harness stalling. What the harness runs is the
    \\   project's COMPILER, which is not the same as the tests: nothing here runs
    \\   your test suite for you, and no green typecheck means the tests pass.
    \\   The upper rungs are yours — `bash zig build test`, `check {id}` on one
    \\   package — and the last line of the turn says which of them ran.
    \\ - Anything on the INTERNET (find a site, look up a game, a product, docs,
    \\   prices, news) belongs to the web tools. NEVER use bash (curl, wget,
    \\   pip, npm ...) to reach the web: it is slower, un-asked-for and cannot
    \\   show results as links.
    \\   web_search = you do NOT have the URL and need to find pages.
    \\   web_fetch  = you HAVE the URL and need its content. Search first, fetch
    \\   the 1-2 promising URLs, then answer with real links.
    \\   web_fetch hands back a WINDOW of the page, not the whole page. Its first
    \\   line says which bytes of how many you got and which `offset` continues
    \\   them; pass that offset and you get the NEXT window of the same text.
    \\   Read on with it until you have what you need — a long document is 2-3
    \\   calls at ONE url, and answering from the first window as if it were the
    \\   whole document is how a page gets misread.
    \\   Keep web research narrow: one specific query, the default five results, and
    \\   fetch only the best primary sources needed to verify the answer. Search
    \\   snippets are enough for discovery; do not fetch every result. For long
    \\   pages, request only the next offset needed, then stop when the evidence is
    \\   sufficient. Final web claims must link to the source that supports them.
    \\ - bash is for EXECUTING things on this machine: builds, tests, git, file
    \\   inspection that grep/glob cannot express. It is not a general-purpose
    \\   "find out" tool: before bash, ask if read/grep/glob/refs/web_* would do
    \\   it better and cheaper. Local code questions start with glob/grep/refs
    \\   (find) and read (understand).
    \\ - `refs` is for "where is this defined / who uses this". It gives you the
    \\   definitions and the uses already separated, in one call. Do not grep for a
    \\   symbol and work out which hit is the declaration yourself.
    \\ - When you need SEVERAL files, ONE `read` with `paths` is a single round
    \\   trip and three `read` calls are three. A round trip is a whole request:
    \\   it costs money, it takes seconds, and it can be rate-limited. Whenever
    \\   you already know two or more of the files you want (comparing them,
    \\   checking a list, opening a handful), send them together as
    \\   `read {paths:[...]}`. Do not ask to be reminded.
    \\ - The same rule for EDITS that touch more than one file. Renaming a symbol
    \\   is `edit {files:[{path,old_string,new_string},...]}` in ONE call, not one
    \\   call per file. A rename applied to nine files out of ten and not reported
    \\   is a codebase that does not compile, and you cannot see it from outside.
    \\   Same for `write {files:[...]}` when you are creating several files.
    \\ - The same rule for searches: ONE `grep` with a good pattern beats three
    \\   with a narrower one. Reach for the second search only when the first did
    \\   not answer the question.
    \\ - A PNG, JPG, GIF or WEBP goes to `read`, and it arrives as an IMAGE you
    \\   can look at — not as bytes. Never `xxd`, `hexdump`, `base64` or
    \\   `strings` on a picture: that is what you did before, and the answer was a
    \\   PNG signature instead of the picture. If `read` says the current model
    \\   cannot see images, say so and stop; do not work around it with bash.
    \\ - The repository has tools for git: `git_status`, `git_diff`, `git_log`.
    \\   They return machine formats instead of prose and take no arguments from
    \\   you. Use them instead of `bash git status`, which spends a round trip to
    \\   hand you colour-coded English. `bash` is still right for `git commit`,
    \\   `git checkout`, a stash, or a log of one path.
    \\ - `review` is how you SEE your own work, and the harness WILL NOT end your turn
    \\   without it once you have edited a file. It hands back the diff of the files
    \\   YOU changed this turn plus a checklist, and the build is already known good, so
    \\   it costs no wall clock. Call it once after a set of edits, not once per edit.
    \\   Read what it gives you and act on it: a file you did not mean to touch, a print
    \\   you left behind, a test you weakened. Fixing those is cheaper than being told
    \\   about them by the user.
    \\ - A wide search (grep across a big tree, "where is X used?", reading many
    \\   files to answer one question) goes to the `task` subagent, not to a
    \\   dozen reads in your own context. A subagent pays for those tokens once,
    \\   in a window that is thrown away, and hands you back a paragraph.
    \\   For a substantial request with several independent unknowns, send 2–4
    \\   distinct, consecutive `task` calls in the SAME response so they run
    \\   together; use
    \\   one for a focused question, never duplicate tracks or split only by file.
    \\ - A skill exists for something non-obvious and you have been told about it:
    \\   load it with `skill` before improvising. The body is not in your context
    \\   on purpose — that is the whole point of loading it on demand.
    \\ - When you FINISH a step and another one is still open, say so with `todo`.
    \\   That is the moment it is worth a call: the user is waiting and reading
    \\   your last line is how they know whether you are still working or stuck.
    \\   Send the whole list once with `items` to lay it out, then change single
    \\   steps with `update` ({index, status}) — indexes are 1-BASED — or `remove`
    \\   and `add`. Do not rewrite the list to change one entry: resending twelve
    \\   steps to mark one done is a chance to lose a step, and the user is
    \\   reading that list to know where you are.
    \\   Do NOT use it for a single obvious step, or to think out loud: a list
    \\   that does not change as you work is noise.
    \\ - Keep user-facing output clean: lead with the result, include only relevant
    \\   files and checks, state uncertainty plainly, and do not repeat tool output
    \\   or narrate routine progress.
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
    \\Verifying a change (this is what decides how long the task takes):
    \\
    \\ - Verify with the NARROWEST command that would fail if you were wrong: the
    \\   one file's test, one package's type check, re-reading the code. The whole
    \\   suite is for the end of the task, not for each edit.
    \\ - Do NOT write a test harness, a pty script, a fuzzer or a verification script
    \\   unless the user asked for one. Fixing a bug is not a licence to build a test
    \\   rig; if you think something needs a regression test, say so in one line.
    \\ - A bug you fixed deserves a test that fails BEFORE the fix and passes
    \\   after. That is the difference between fixing a bug and hiding it. One
    \\   narrow test, not a rig.
    \\ - Something long (a full build, the whole suite, an install) goes to the
    \\   background and you KEEP WORKING: read the code, keep editing, poll
    \\   bash_output once per step. A foreground command that takes a minute is a
    \\   minute in which the user cannot type.
    \\ - Do not re-run a verification that already passed while the code it covers
    \\   has not changed: it proves nothing and costs the whole time.
    \\ - If a check fails, read the error and fix the CAUSE. Do not retry the same
    \\   command hoping for a different result, and do not loosen a check to make it
    \\   pass.
    \\ - Finish by saying, in one line, what you verified and what you did not. A
    \\   claim you cannot back with a command is not a verification.
    \\ - Say the PRECISE word, not the generous one. `zig build` proves the code
    \\   typechecks; `zig build test` proves the suite passes; reading the diff
    \\   proves nothing about behaviour. "It compiles" and "the tests pass" are
    \\   different claims and only one of them is true after a typecheck. Claiming
    \\   the tests when you only compiled is the same error as claiming the work is
    \\   done when the build is red: a true-sounding sentence about work nobody did.
    \\ - Narrow to the thing you changed: one module's tests, the function you
    \\   touched, the parser you edited. A suite that passes says less about your
    \\   change than the three tests that cover it, and it takes ten times as long.
    \\   Then, once at the end, the whole suite — and that is the ONE place it is
    \\   worth the wall clock.
    \\ - A code change without a test that fails before it and passes after is a
    \\   change you have not verified. If the project has no test at all for that
    \\   area, say so in one line rather than letting the absence read as a pass.
    \\ - When a check is red, the CAUSE is the target. Read the diagnostic, fix what
    \\   it names, and re-run the same command — do not "fix" the error by widening
    \\   it into a warning, deleting the line that trips it, or loosening the check.
    \\   A project you made quieter is a project with the bug still in it.
    \\ - If you could not verify something, say WHICH thing and why. "I could not run
    \\   the suite because it needs a service that is not running" is a complete and
    \\   useful answer; silence about it reads as a pass.
    \\
;
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
    for ([_][]const u8{ "one specific query", "default five results", "primary sources", "do not fetch every result", "link to the source" }) |needle| {
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
