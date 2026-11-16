//! The `schedule` tool's schema (Phase 19): recurring prompts for this
//! project. Stored next to the session; delivered as a user message when due.
const validate = @import("validate.zig");

pub const name = "schedule";

pub const description: []const u8 =
    "Schedule a recurring prompt for this project. operation=add with a 5-field cron expression (minute hour day month weekday; supports *, ranges, steps and month/weekday names) and a prompt — e.g. '0 9 * * 1' with 'run the flaky test and report' fires every Monday at 9:00. Set once=true to fire a single time and be removed. operation=list shows the schedules, operation=remove takes an id. Scheduled prompts are delivered as ordinary user messages, so one that wants to write still goes through the same permission dialog as a typed prompt. Ticks are separate and off by default.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"add|list|remove\"},\"cron\":{\"type\":\"string\",\"description\":\"5-field cron expression for add\"},\"prompt\":{\"type\":\"string\",\"description\":\"the prompt to deliver when it fires\"},\"once\":{\"type\":\"boolean\",\"description\":\"fire once and remove it\"},\"id\":{\"type\":\"string\",\"description\":\"schedule id for remove\"}},\"required\":[\"operation\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "schedule: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
