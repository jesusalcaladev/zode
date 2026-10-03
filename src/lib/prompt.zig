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
pub const default_system_prompt =
    \\You are zode, a coding agent running inside a terminal harness.
    \\You help the user with software engineering tasks: fixing bugs, adding
    \\features, refactoring, and explaining code.
    \\
    \\Environment:
    \\ - You have tools: read, write, edit (str_replace, multi-hunk), bash,
    \\   glob, grep, list_files, web_fetch, web_search, think. Prefer
    \\   grep/glob first, then read only what you need.
    \\ - For edits, use the edit tool with exact old_string/new_string.
    \\ - Keep answers concise. Use markdown. Code blocks must include the
    \\   language tag so the terminal UI can highlight them.
    \\ - If a tool call is denied by the user, do not retry it; adjust approach.
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
pub const tool_routing_prompt =
    \\Choosing the right tool (do not guess — route):
    \\
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
    \\   "find out" tool: before bash, ask if read/grep/glob/web_* would do it
    \\   better and cheaper.
    \\ - Local code questions start with glob/grep (find) and read (understand);
    \\   do not bash your way through what those tools answer directly.
    \\ - A wide search (grep across a big tree, "where is X used?", reading many
    \\   files to answer one question) goes to the `task` subagent, not to a
    \\   dozen reads in your own context.
    \\ - If the request is ambiguous in a way that changes what you build, use
    \\   ask instead of guessing.
    \\
;

/// Composes the system prompt for a request.
///
/// Five pieces, and the ORDER is not cosmetic:
///
/// 1. The project's `AGENTS.md`/`CLAUDE.md` if there is one. It is the user's
///    own instruction file and it wins.
/// 2. Otherwise the built-in one.
/// 3. `tool_routing_prompt` and `verification_prompt`, ALWAYS — see their doc
///    comments. They are the pieces that used to vanish in any project with an
///    `AGENTS.md`, which is how "find me a page about games" turned into
///    `bash curl`, and how a one-line fix turned into a ten-minute task full of
///    verification scripts.
/// 4. Then the ask guidance and the skills section, which are the same for every
///    project and go AFTER the user's file so a project can override them.
/// 5. And the cwd + git line, which is last of all: it is the only piece that
///    changes when zode is started somewhere else, so putting it at the end means
///    changing directory does not invalidate the whole stable prefix.
///
/// The caching here is the AGENTS.md file (it does not change while zode runs,
/// and it is up to 256 KB). The skills section is composed per request into a
/// caller-provided buffer, because the skills on disk CAN change while zode runs
/// and a new one appearing should be usable without a restart (`discoverSkills`
/// re-validates by mtime).
/// How to verify, and what NOT to verify.
///
/// Its own constant, injected after the routing table, for the same reason that
/// one is: a project's `AGENTS.md` REPLACES the built-in prompt, and this is the
/// rule that decides how long a task takes.
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
