//! The `github` tool's schema text.
//!
//! GitHub is a first-class remote integration (like git is for the local repo).
//! One gateway tool keeps the schema stable and cache-prefix friendly while
//! exposing structured operations for repository, PR, issue and checks data.

const validate = @import("validate.zig");

pub const name = "github";

pub const description: []const u8 =
    "Structured GitHub operations for the current repository or an explicit repo. " ++
    "PREFER this over `gh`/`curl` for PRs, issues, checks and repo metadata because results are deterministic and permission-checked per operation. " ++
    "OPERATIONS (read): auth_status, whoami, repo, pr_list, pr_view, pr_checks, issue_list, issue_view, actions_runs. " ++
    "OPERATIONS (write, permission required): pr_create, pr_update, pr_comment, issue_create, issue_comment. " ++
    "Repo resolution: uses git remotes (origin/upstream) unless `repo` (owner/name) is provided. " ++
    "Auth: GITHUB_TOKEN or GH_TOKEN env, else ~/.config/zode/auth.json key `github:<host>`, `github`, or `github.com`. " ++
    "Outputs are compact and actionable (numbers, states, SHAs, URLs, typed errors). Do not guess owner/repo or PR numbers; inspect first when unsure.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"auth_status|whoami|repo|pr_list|pr_view|pr_checks|pr_create|pr_update|pr_comment|issue_list|issue_view|issue_create|issue_comment|actions_runs\"},\"repo\":{\"type\":\"string\",\"description\":\"owner/name; omit to resolve from git remotes\"},\"number\":{\"type\":\"integer\",\"description\":\"PR or issue number for *_view/*_checks/*_comment/*_update\"},\"state\":{\"type\":\"string\",\"description\":\"open|closed|all (list operations)\"},\"head\":{\"type\":\"string\",\"description\":\"pr_list/pr_create: head branch (or owner:branch)\"},\"base\":{\"type\":\"string\",\"description\":\"pr_create/pr_update: base branch\"},\"branch\":{\"type\":\"string\",\"description\":\"actions_runs: filter by head branch\"},\"title\":{\"type\":\"string\",\"description\":\"pr_create/pr_update/issue_create title\"},\"body\":{\"type\":\"string\",\"description\":\"body/comment text\"},\"draft\":{\"type\":\"boolean\",\"description\":\"pr_create: create as draft\"},\"limit\":{\"type\":\"integer\",\"description\":\"max items for list operations (default 20, max 50)\"}},\"required\":[\"operation\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "github: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
