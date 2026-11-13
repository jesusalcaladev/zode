//! Git workflow command templates and allowlists (Phase 31).
//!
//! Pure data: prompt templates, allow rule sets, and helpers. Command
//! substitution (`` !`cmd` ``) is expanded by `lib/cmdsubst.zig` at run time;
//! the allowlists here define what each git command may execute without
//! prompting (31.2 asymmetry).
//!
//! ## Vocabulary bridge (external spec ↔ internal)
//!
//! External specs / TASKS prose describe command-scoped permissions in forms such
//! as `Bash(git add:*)`, `git status:*`, or "always-allow command rules" (e.g.
//! `alwaysAllowRules.command`-style entries in other agents' specs). zode's
//! internal mapping is:
//! - These entries are **turn-scoped bash allow rules**: `[]const []const u8` of
//!   `Bash(...)` command-prefix patterns (zode style uses space-star, e.g.
//!   `Bash(git add *)`; `:*` is accepted by the matcher for spec compatibility).
//! - Injected per turn as `agent.turn_bash_allow_rules` / `ChatJob.bash_allow_rules`
//!   and checked by `cmdsubst.matchesAllowRules` / `agent.bashAllowedByTurnRules`.
//! - They are **implicit allow, turn lifetime only** — not persisted
//!   `permrules.Rule` entries (`allow/deny/ask` with source precedence). A
//!   persistent "always allow" answer is a different concept: it learns a scoped
//!   rule into `agent.perm_rules` (local) and persists it (see TASKS 33.21/509).

const std = @import("std");

/// 31.2 — `/commit`: stage/status/diff/log/commit only. No push, no PR, no branch ops.
pub const commit_allow_rules = [_][]const u8{
    "Bash(git add *)",
    "Bash(git status *)",
    "Bash(git diff *)",
    "Bash(git log *)",
    "Bash(git show *)",
    "Bash(git commit *)",
    "Bash(git rev-parse *)",
    "Bash(git branch *)",
};

/// 31.2 — `/pr` / commit-push-pr: commit rules plus branch/push/remote/gh pr.
/// The asymmetry is the feature: `/commit` cannot push or create PRs.
pub const pr_allow_rules = [_][]const u8{
    "Bash(git add *)",
    "Bash(git status *)",
    "Bash(git diff *)",
    "Bash(git log *)",
    "Bash(git show *)",
    "Bash(git commit *)",
    "Bash(git rev-parse *)",
    "Bash(git branch *)",
    "Bash(git checkout *)",
    "Bash(git switch *)",
    "Bash(git push *)",
    "Bash(git remote *)",
    "Bash(git merge-base *)",
    "Bash(git fetch *)",
    "Bash(gh pr *)",
    "Bash(gh auth *)",
};

/// 35.4 — `/review`: read-only git context for reviewing changes.
pub const review_allow_rules = [_][]const u8{
    "Bash(git status *)",
    "Bash(git diff *)",
    "Bash(git log *)",
    "Bash(git show *)",
    "Bash(git rev-parse *)",
    "Bash(git branch *)",
    "Bash(git merge-base *)",
    "Bash(git remote *)",
    "Bash(git blame *)",
};

/// 35.4 — `/security-review`: same read-only context, security-focused analysis.
pub const security_review_allow_rules = [_][]const u8{
    "Bash(git status *)",
    "Bash(git diff *)",
    "Bash(git log *)",
    "Bash(git show *)",
    "Bash(git rev-parse *)",
    "Bash(git branch *)",
    "Bash(git merge-base *)",
    "Bash(git remote *)",
    "Bash(git blame *)",
    "Bash(git grep *)",
};

pub const commit_prompt =
    \\You are creating a git commit in the current repository. Follow this protocol exactly.
    \\
    \\## Verified context (collected now; do not guess)
    \\- Current git status:
    \\!`git status --short --branch 2>/dev/null || git status`
    \\- Current git diff (staged + unstaged vs HEAD):
    \\!`git --no-pager diff --no-color HEAD 2>/dev/null || true`
    \\- Staged diff:
    \\!`git --no-pager diff --no-color --cached 2>/dev/null || true`
    \\- Current branch:
    \\!`git branch --show-current 2>/dev/null || true`
    \\- Recent commits (style reference):
    \\!`git --no-pager log --oneline -10 2>/dev/null || true`
    \\
    \\## Git safety protocol (non-negotiable)
    \\- NEVER update git config.
    \\- NEVER skip hooks (`--no-verify`, `--no-gpg-sign`) unless the user explicitly requested it in this conversation.
    \\- ALWAYS create NEW commits. NEVER use `--amend` unless the user explicitly requested it. (Amending rewrites history and can destroy work.)
    \\- NEVER use interactive git (`-i`, `--interactive`, including `rebase -i`); it hangs in a non-TTY harness and is forbidden.
    \\- Do not commit files that likely contain secrets (`.env`, credentials, tokens, private keys). If the user asked to commit them, warn and ask before proceeding.
    \\- No empty commits.
    \\- Prefer not to use `git add -A` / `git add .` blindly when unrelated or sensitive files may be present; stage the specific files that belong to the change.
    \\
    \\## How to commit (31.4)
    \\- The commit message must NEVER go in argv as a fragile inline string. Write it via a heredoc to `git commit -F -` (or `-F <file>`). Example shape (single command):
    \\  git commit -F - <<'EOF'
    \\  subject line
    \\
    \\  why (1-2 sentences)
    \\  EOF
    \\- Stage and create the commit using a single message. Do not use any other tools or send any other text after the commit is done except a short confirmation naming the commit.
    \\- Message style: look at the recent commits for this repo's style; name the nature of the change (add/update/fix/refactor/test/docs); include 1–2 sentences on the **why**.
    \\
    \\If there is nothing to commit, say so clearly and do not create an empty commit.
;

pub const pr_prompt =
    \\You are creating or updating a pull request for the current repository. Follow this protocol exactly.
    \\
    \\## Verified context (collected now; do not guess)
    \\- Current git status:
    \\!`git status --short --branch 2>/dev/null || git status`
    \\- Current branch:
    \\!`git branch --show-current 2>/dev/null || true`
    \\- Default branch (best effort):
    \\!`git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main`
    \\- Merge base against origin default (best effort):
    \\!`(BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main); git merge-base HEAD "origin/$BASE" 2>/dev/null) || git merge-base HEAD HEAD~10 2>/dev/null || true`
    \\- Commits in this PR (all commits since merge base, best effort):
    \\!`(BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main); MB=$(git merge-base HEAD "origin/$BASE" 2>/dev/null || echo HEAD~10); git --no-pager log --oneline "$MB"..HEAD 2>/dev/null) || true`
    \\- Diff for this PR (merge base..HEAD, all PR commits):
    \\!`(BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main); MB=$(git merge-base HEAD "origin/$BASE" 2>/dev/null || echo HEAD~10); git --no-pager diff --no-color "$MB"..HEAD 2>/dev/null) || true`
    \\- Existing PR for current branch (best-effort CLI hint; verify with native tool when possible):
    \\!`gh pr view --json number,url,title 2>/dev/null || true`
    \\- Remote:
    \\!`git remote -v 2>/dev/null | head -n 4 || true`
    \\- Recent commits (style reference):
    \\!`git --no-pager log --oneline -10 2>/dev/null || true`
    \\
    \\## Git safety protocol (non-negotiable)
    \\- NEVER update git config.
    \\- NEVER skip hooks (`--no-verify`, `--no-gpg-sign`) unless the user explicitly requested it.
    \\- ALWAYS create NEW commits. NEVER use `--amend` unless the user explicitly requested it.
    \\- NEVER use interactive git (`-i`, `--interactive`, including `rebase -i`).
    \\- Do not commit/push files that likely contain secrets; warn and ask if requested.
    \\- No empty commits.
    \\
    \\## Preferred tools (native first, CLI fallback)
    \\- PREFER the native `github` tool for remote GitHub operations when supported: `repo`, `pr_list`, `pr_view`, `pr_checks`, `pr_create`, `pr_update`, `pr_comment`, `issue_view/comment/create`, `actions_runs`. Use `gh`/`curl` only when the native operation is unavailable or the CLI is needed for behavior the tool cannot provide.
    \\- `github` resolves owner/repo from git remotes by default; pass `repo` only if needed.
    \\- Mutating `github` operations require permission per operation; read operations do not.
    \\
    \\## Branch and PR rules
    \\- If you are on the default branch and need to open a PR, create a branch with a user prefix: `username/feature` (derive `username` from `git config user.name`/GitHub context when reasonable; use a safe slug).
    \\- The diff you reason about is the merge-base diff: it must cover **all** commits in the PR, not just the latest commit.
    \\- PR title: under 70 characters.
    \\- PR body template (keep it clear and factual):
    \\  ## Summary
    \\  - 1–3 bullets describing what changed and why
    \\
    \\  ## Test plan
    \\  - [ ] checks/tests you ran (be specific)
    \\
    \\  ## Changelog
    \\  <!-- zode:changelog:start -->
    \\  (managed changelog notes, if any)
    \\  <!-- zode:changelog:end -->
    \\- **Idempotent**: first check for an existing open PR for the current branch (prefer `github` `pr_list` with `head` or `pr_view` if number known; fallback `gh pr view --json number,url,title`). If one exists, update it (prefer `github pr_update` and/or comment via `github pr_comment`) and push branch if needed. Do NOT create a second PR.
    \\- If no PR exists, push the branch (set upstream if needed) and create the PR (prefer `github pr_create`; fallback `gh pr create`). Include the full merge-base diff scope in the PR body/summary.
    \\- Commit messages must never be passed as fragile argv strings; use heredoc / `git commit -F -` when committing.
    \\- Return the PR URL when you're done. Use a single clear final message with the URL.
;

pub const review_prompt =
    \\You are reviewing the current changes in this repository. Use the verified context below; do not guess.
    \\
    \\## Verified context (collected now)
    \\- Current git status:
    \\!`git status --short --branch 2>/dev/null || git status`
    \\- Current branch:
    \\!`git branch --show-current 2>/dev/null || true`
    \\- Default branch (best effort):
    \\!`git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main`
    \\- Merge base against origin default (best effort):
    \\!`(BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main); git merge-base HEAD "origin/$BASE" 2>/dev/null) || git merge-base HEAD HEAD~10 2>/dev/null || true`
    \\- Uncommitted diff (staged + unstaged vs HEAD):
    \\!`git --no-pager diff --no-color HEAD 2>/dev/null || true`
    \\- Staged diff:
    \\!`git --no-pager diff --no-color --cached 2>/dev/null || true`
    \\- Diff since merge base (all branch/PR commits, best effort):
    \\!`(BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main); MB=$(git merge-base HEAD "origin/$BASE" 2>/dev/null || echo HEAD~10); git --no-pager diff --no-color "$MB"..HEAD 2>/dev/null) || true`
    \\- Recent commits:
    \\!`git --no-pager log --oneline -10 2>/dev/null || true`
    \\
    \\## Review instructions
    \\- Prioritize correctness, regressions, missing tests, behavior changes, and maintainability risks.
    \\- Report findings first, ordered by severity (high → medium → low), with concrete file/line references when possible.
    \\- For each finding include: what is wrong/risky, why it matters, and a suggested fix.
    \\- If there are no findings, say so explicitly and mention residual risks or testing gaps.
    \\- Do not make code changes. This is a review, not an implementation turn.
    \\- Keep the summary brief after the findings.
    ;

pub const security_review_prompt =
    \\You are performing a security review of the current changes in this repository. Use the verified context below; do not guess.
    \\
    \\## Verified context (collected now)
    \\- Current git status:
    \\!`git status --short --branch 2>/dev/null || git status`
    \\- Current branch:
    \\!`git branch --show-current 2>/dev/null || true`
    \\- Default branch (best effort):
    \\!`git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main`
    \\- Merge base against origin default (best effort):
    \\!`(BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main); git merge-base HEAD "origin/$BASE" 2>/dev/null) || git merge-base HEAD HEAD~10 2>/dev/null || true`
    \\- Uncommitted diff (staged + unstaged vs HEAD):
    \\!`git --no-pager diff --no-color HEAD 2>/dev/null || true`
    \\- Staged diff:
    \\!`git --no-pager diff --no-color --cached 2>/dev/null || true`
    \\- Diff since merge base (all branch/PR commits, best effort):
    \\!`(BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main); MB=$(git merge-base HEAD "origin/$BASE" 2>/dev/null || echo HEAD~10); git --no-pager diff --no-color "$MB"..HEAD 2>/dev/null) || true`
    \\- Recent commits:
    \\!`git --no-pager log --oneline -10 2>/dev/null || true`
    \\
    \\## Security review instructions
    \\- Focus on vulnerabilities and security-relevant regressions: injection, authn/authz flaws, secrets exposure, unsafe deserialization/parsing, path traversal, SSRF, command execution, memory/unsafe behavior, insecure defaults, crypto misuse, and data leakage.
    \\- Treat user-controlled input, untrusted files, network data, and tool/command arguments as attack surfaces.
    \\- Report findings first, ordered by severity (high → medium → low), with concrete file/line references when possible.
    \\- For each finding include: the issue, exploit/impact scenario, why it is reachable in this codebase, and a concrete remediation.
    \\- If no security findings are present, say so explicitly and note any assumptions, blind spots, or areas needing deeper verification.
    \\- Do not make code changes. This is a security review, not an implementation turn.
    ;

/// Returns the content length for a dynamic prompt. 31.5: a getter, not a
/// static constant, so substituted/expanded prompts report the correct length.
pub fn contentLength(text: []const u8) usize {
    return text.len;
}

test "gitcmds: contentLength is a getter over dynamic text" {
    const a = "short";
    const b = "a longer dynamic prompt body";
    try std.testing.expectEqual(a.len, contentLength(a));
    try std.testing.expectEqual(b.len, contentLength(b));
    try std.testing.expect(contentLength(b) != contentLength(a));
}

test "gitcmds: commit/pr allowlist asymmetry is pinned" {
    try std.testing.expect(@import("cmdsubst.zig").matchesAllowRules("git commit -F -", &commit_allow_rules));
    try std.testing.expect(!@import("cmdsubst.zig").matchesAllowRules("git push origin main", &commit_allow_rules));
    try std.testing.expect(!@import("cmdsubst.zig").matchesAllowRules("gh pr create", &commit_allow_rules));
    try std.testing.expect(!@import("cmdsubst.zig").matchesAllowRules("git checkout -b feat", &commit_allow_rules));

    try std.testing.expect(@import("cmdsubst.zig").matchesAllowRules("git push -u origin feat", &pr_allow_rules));
    try std.testing.expect(@import("cmdsubst.zig").matchesAllowRules("git checkout -b user/feat", &pr_allow_rules));
    try std.testing.expect(@import("cmdsubst.zig").matchesAllowRules("gh pr view --json number 2>/dev/null || true", &pr_allow_rules));
    try std.testing.expect(@import("cmdsubst.zig").matchesAllowRules("gh pr edit 1 --body x", &pr_allow_rules));
}

test "gitcmds: prompts include required git safety and PR idempotence markers" {
    try std.testing.expect(std.mem.indexOf(u8, commit_prompt, "NEVER use `--amend`") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit_prompt, "NEVER update git config") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit_prompt, "--no-verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit_prompt, "git commit -F -") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit_prompt, "!`git status") != null);

    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "merge-base") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "gh pr view --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "github pr_update") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "github pr_create") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "Return the PR URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "## Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "## Test plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "zode:changelog:start") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "under 70 characters") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_prompt, "PREFER the native `github` tool") != null);
}