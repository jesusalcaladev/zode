# Walkthrough: run a reusable prompt with a custom slash command (zode)

zode is a terminal agent harness written in pure Zig. This walkthrough covers the
custom slash commands feature: markdown files under `.zode/commands/` (project) or
`~/.config/zode/commands/` (personal) that become prompts, with `$ARGUMENTS`
substituted from what you type after the command. Discovery and expansion live in
`src/lib/usercmds.zig` and are wired into `src/agent.zig`.

No public app URL is available: zode is a local TUI, and cloud runners cannot
reach localhost. Use the manual recording option below instead.

## Steps and expected behavior

Custom slash commands in zode (local TUI).

1. In the project root, create `.zode/commands/review.md` with this test data:
```
---
description: review the diff against the task
---
Review $ARGUMENTS against the task.
```

2. Build and start: `zig build && ./zig-out/bin/zode`.
   Expected: the TUI opens with the prompt at the bottom.

3. Type `/rev`.
   Expected: a popup lists `/review` with the description `review the diff against
   the task`. Matching is by prefix of the command name, and only while the input
   starts with `/` and has no spaces.

4. Press Tab (or Enter) to accept the completion, type ` the last commit`, then
   Enter.
   Expected: the popup closes and the file body is sent as the prompt with every
   `$ARGUMENTS` replaced: `Review the last commit against the task.` A turn starts
   only if a provider key and model are configured.

5. While zode is open, edit `review.md`, then run `/review again`.
   Expected: the new body is used on that run, because bodies are read from disk at
   run time (only the name and description are cached).

## Missing inputs

- A provider API key (`ZODE_API_KEY` or `ZODE_<PROVIDER>_KEY`) and a model
  (`ZODE_MODEL`) are required for step 4 to start a turn. Steps 1-3 are local and
  need no key.
- `.zode/commands/` must exist or be created; it is not tracked in the repository.
- No public app URL was supplied, so no `&url=` was appended to the handoff link.

## Handoff

Cloud runs cannot reach a local TUI. To record it by hand:
https://userill.dev/record?utm_source=freebuff&utm_medium=paid&utm_campaign=rill
To record an existing browser agent:
https://userill.dev/docs/agent-quickstart?utm_source=freebuff&utm_medium=paid&utm_campaign=rill

[Open your walkthrough in Rill](<https://userill.dev/freebuff?utm_source=freebuff&utm_medium=paid&utm_campaign=rill&utm_content=text-ad&bfcid=bfc_1.eyJpZCI6ImE0MjE4ZmQxLWRmZjktNDYwYS04NmFiLWIwODFmNDljYWY2MCIsImMiOiIxNDQyMTUzOS1kYjNiLTQ1YzEtYjQ5OC1hYTMxOTFmNDkxYzAiLCJrIjoiNDU4ODZlNWEtYzkyZC00ZDUxLTg1ZjgtYzc4YTRmMTY3ZWYwIiwiaWF0IjoxNzkxNjUzNjI5fQ.bgNDUvkV9zz4_X98nb14CLc9DmNW2xGf4flGs9agFQg#task=Custom%20slash%20commands%20in%20zode%20(local%20TUI).%0A%0A1.%20In%20the%20project%20root%2C%20create%20%60.zode%2Fcommands%2Freview.md%60%20with%20this%20test%20data%3A%0A---%0Adescription%3A%20review%20the%20diff%20against%20the%20task%0A---%0AReview%20%24ARGUMENTS%20against%20the%20task.%0A%0A2.%20Build%20and%20start%3A%20%60zig%20build%20%26%26%20.%2Fzig-out%2Fbin%2Fzode%60.%0AExpected%3A%20the%20TUI%20opens%20with%20the%20prompt%20at%20the%20bottom.%0A%0A3.%20Type%20%60%2Frev%60.%0AExpected%3A%20a%20popup%20lists%20%60%2Freview%60%20with%20the%20description%20%60review%20the%20diff%20against%20the%20task%60.%20Matching%20is%20by%20prefix%20of%20the%20command%20name%2C%20and%20only%20while%20the%20input%20starts%20with%20%60%2F%60%20and%20has%20no%20spaces.%0A%0A4.%20Press%20Tab%20(or%20Enter)%20to%20accept%20the%20completion%2C%20type%20%60%20the%20last%20commit%60%2C%20then%20Enter.%0AExpected%3A%20the%20popup%20closes%20and%20the%20file%20body%20is%20sent%20as%20the%20prompt%20with%20every%20%60%24ARGUMENTS%60%20replaced%3A%20%60Review%20the%20last%20commit%20against%20the%20task.%60%20A%20turn%20starts%20only%20if%20a%20provider%20key%20and%20model%20are%20configured.%0A%0A5.%20While%20zode%20is%20open%2C%20edit%20%60review.md%60%2C%20then%20run%20%60%2Freview%20again%60.%0AExpected%3A%20the%20new%20body%20is%20used%20on%20that%20run%2C%20because%20bodies%20are%20read%20from%20disk%20at%20run%20time%20(only%20the%20name%20and%20description%20are%20cached).%0A%0AMissing%20inputs%3A%20a%20provider%20API%20key%20(ZODE_API_KEY%20or%20ZODE_%3CPROVIDER%3E_KEY)%20and%20a%20model%20(ZODE_MODEL)%20to%20complete%20step%204%3B%20%60.zode%2Fcommands%2F%60%20must%20exist%20or%20be%20created.%20No%20public%20app%20URL%3A%20zode%20is%20a%20local%20TUI%2C%20so%20cloud%20runners%20cannot%20reach%20it.%0A>)

Your walkthrough is prepared. No recording has been made yet. In Rill, review the steps, add a public app URL, and choose Sign up to run if you need an account. The walkthrough uses Interact mode. Press Run to start it.
