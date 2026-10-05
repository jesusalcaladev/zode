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
    \\ - If something fails, say what failed and what you did about it. Never
    \\   report a change as done on the strength of a command you did not run, and
    \\   never quietly narrow a test to make it pass.
    \\ - If the request is ambiguous in a way that changes what you build, `ask`
    \\   rather than guessing. A question costs one turn; a wrong build costs the
    \\   whole task.
    \\ - If a tool call is denied, do not retry it. Change approach.
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
    \\ - Anything on the INTERNET (find a site, look up a game, a product, docs,
    \\   prices, news) belongs to web_search / web_fetch. NEVER use bash (curl,
    \\   wget, pip, npm ...) to reach the web: it is slower, un-asked-for and
    \\   cannot show results as links.
    \\   web_search = you do NOT have the URL and need to find pages.
    \\   web_fetch  = you HAVE a URL and need its content. A natural flow is
    \\   search first, fetch the 1-2 promising URLs, then answer with links.
    \\   If the user names a site ("find a games site"), web_search is the first
    \\   tool to call, before any bash, and you answer with real links.
    \\ - bash is for EXECUTING things on this machine: builds, tests, git, file
    \\   inspection that grep/glob cannot express. It is not a general-purpose
    \\   "find out" tool: before bash, ask if read/grep/glob/refs/web_* would do
    \\   it better and cheaper.
    \\ - Local code questions start with glob/grep/refs (find) and read
    \\   (understand); do not bash your way through what those tools answer
    \\   directly.
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
    \\ - A wide search (grep across a big tree, "where is X used?", reading many
    \\   files to answer one question) goes to the `task` subagent, not to a
    \\   dozen reads in your own context. A subagent pays for those tokens once,
    \\   in a window that is thrown away, and hands you back a paragraph.
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
    \\ - If the request is ambiguous in a way that changes what you build, use
    \\   ask instead of guessing.
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
        "report a change as done", // honest reporting
        "language tag", // the UI needs it
    };
    for (rules) |r| {
        if (std.mem.indexOf(u8, default_system_prompt, r) == null) {
            std.debug.print("the prompt lost the rule: {s}\n", .{r});
            return error.RuleMissing;
        }
    }
}

test "the routing table is about ROUND TRIPS, and says so" {
    // Every rule in it is "one call instead of N". If a future rewrite turns it
    // into prose about tools in general it has lost the reason it exists.
    for ([_][]const u8{ "paths", "files", "refs", "round trip", "task", "git_status", "check", "todo" }) |k| {
        if (std.mem.indexOf(u8, tool_routing_prompt, k) == null) {
            std.debug.print("the routing table lost: {s}\n", .{k});
            return error.RuleMissing;
        }
    }
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
