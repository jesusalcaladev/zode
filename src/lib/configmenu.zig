//! Catalog of the settings shown in the interactive Settings screen.
//!
//! Pure on purpose: sections, settings, descriptions, option vocabularies and
//! where each setting is persisted are data — testable without a TUI, without
//! env access and without a network. The TUI reads the CURRENT value from the
//! agent globals / config and renders each row.

const std = @import("std");

/// Sections of the Settings screen, in display order. Each is a column of
/// rows on the right; the left column lists the sections themselves.
pub const Section = enum {
    model,
    output_style,
    context_cache,
    agent,
    permissions,
    appearance,
    agents,

    pub fn label(self: Section) []const u8 {
        return switch (self) {
            .model => "Model & reasoning",
            .output_style => "Output style",
            .context_cache => "Context & cache",
            .agent => "Agent behavior",
            .permissions => "Permissions",
            .appearance => "Appearance & input",
            .agents => "Agent definitions",
        };
    }

    pub fn hint(self: Section) []const u8 {
        return switch (self) {
            .model => "Who answers and how much it thinks",
            .output_style => "How answers are phrased",
            .context_cache => "Window, compaction and cache economics",
            .agent => "Iterations, parallelism and verification",
            .permissions => "What the agent may do without asking",
            .appearance => "Presentation (keybindings: /keybinds)",
            .agents => "Reusable agents on disk and the default for task",
        };
    }
};

pub const all_sections = [_]Section{
    .model,
    .output_style,
    .context_cache,
    .agent,
    .permissions,
    .appearance,
    .agents,
};

/// Every setting row. `cache_stats` and `permission_rules` are read-only
/// information rows that surface `/cache` and `/permissions` inside the screen.
pub const Setting = enum {
    model,
    provider,
    effort,
    output_style,
    context_limit,
    compaction,
    read_cache_size,
    prompt_cache,
    cache_stats,
    task_parallel,
    max_iter,
    auto_check,
    permission_mode,
    permission_rules,
    web_allow_local,
    color_palette,
    vim_mode,
    nerd_icons,
    active_agent,
    new_agent,
    terse_tools,
    no_animation,
    reduced_motion,

    pub fn label(self: Setting) []const u8 {
        return switch (self) {
            .model => "Model",
            .provider => "Provider",
            .effort => "Reasoning effort",
            .output_style => "Style",
            .context_limit => "Context limit",
            .compaction => "Compaction tier",
            .read_cache_size => "Read cache size",
            .prompt_cache => "Prompt caching",
            .cache_stats => "Cache verdict",
            .task_parallel => "Parallel subagents",
            .max_iter => "Max iterations",
            .auto_check => "Automatic checks",
            .permission_mode => "Permission mode",
            .permission_rules => "Permission rules",
            .web_allow_local => "Web allow local",
            .color_palette => "Diff colors",
            .vim_mode => "Vim input mode",
            .nerd_icons => "Nerd Font icons",
            .active_agent => "Default agent",
            .new_agent => "New agent…",
            .terse_tools => "Terse tool schemas",
            .no_animation => "No animation",
            .reduced_motion => "Reduced motion",
        };
    }

    pub fn description(self: Setting) []const u8 {
        return switch (self) {
            .model => "Which model answers. Opens the model palette with the cached catalog.",
            .provider => "Which provider serves the model (needs its key).",
            .effort => "How much the model thinks; clamped to what it supports.",
            .output_style => "Instruction block injected at the end of the system prompt.",
            .context_limit => "Token window used for the compaction budget (auto = model's own).",
            .compaction => "off (never) · elide (cheap) · full (summarize old turns).",
            .read_cache_size => "Per-tool output cap in bytes (K/M/G suffixes).",
            .prompt_cache => "One cache_control breakpoint on the stable prompt prefix.",
            .cache_stats => "Live hit-rate and the reason behind it (read-only).",
            .task_parallel => "Subagent requests in flight at once (1-8).",
            .max_iter => "Tool/answer iterations per turn before the ceiling (attempts).",
            .auto_check => "Start the project's own check after code edits.",
            .permission_mode => "build · accept-edits · plan (read-only) · bypass (yolo).",
            .permission_rules => "Active rules and allowlist (read-only; manage with /permissions).",
            .web_allow_local => "Let web_fetch reach loopback/private ranges.",
            .color_palette => "default (green/red) or daltonized (blue/orange).",
            .vim_mode => "Vim-like keybindings in the composer.",
            .nerd_icons => "Language glyph before code-block labels (auto = detect).",
            .active_agent => "Used by task when no definition is named (Enter to cycle).",
            .new_agent => "Create .zode/agents/<name>.md from a template, then edit it with !.",
            .terse_tools => "Short tool schemas (≈15% fewer request tokens); /style can override it.",
            .no_animation => "Render the final state immediately: no mascot motion, no fades.",
            .reduced_motion => "Keep status changes but drop continuous motion (ZODE_REDUCED_MOTION).",
        };
    }

    pub fn section(self: Setting) Section {
        return switch (self) {
            .model, .provider, .effort => .model,
            .output_style => .output_style,
            .context_limit, .compaction, .read_cache_size, .prompt_cache, .cache_stats => .context_cache,
            .task_parallel, .max_iter, .auto_check => .agent,
            .permission_mode, .permission_rules, .web_allow_local => .permissions,
            .color_palette, .vim_mode, .nerd_icons => .appearance,
            .active_agent => .agents,
            .new_agent => .agents,
            .terse_tools => .context_cache,
            .no_animation, .reduced_motion => .appearance,
        };
    }

    /// How the screen applies (or displays) a row.
    pub fn kind(self: Setting) Kind {
        return switch (self) {
            .model, .provider => .palette,
            .cache_stats, .permission_rules => .info,
            .output_style, .effort, .context_limit, .compaction,
            .read_cache_size, .task_parallel, .max_iter, .color_palette,
            .nerd_icons => .picker,
            .prompt_cache, .auto_check, .web_allow_local, .vim_mode,
            .terse_tools, .no_animation, .reduced_motion => .toggle,
            .permission_mode => .picker,
            .active_agent => .picker,
            .new_agent => .action,
        };
    }

    /// True when the value is written to ~/.config/zode/config.json. Info rows
    /// and the two palette rows are not persisted here (model/provider already
    /// have their own persistence path).
    pub fn persisted(self: Setting) bool {
        // These three are runtime switches from the environment, not config
        // fields; showing "saved" for them would be a lie.
        if (self == .terse_tools or self == .no_animation or self == .reduced_motion) return false;
        return switch (self.kind()) {
            .info, .action, .palette => false,
            .picker, .toggle => self != .model and self != .provider,
        };
    }
};

pub const Kind = enum {
    /// Opens the main command palette in a specific mode.
    palette,
    /// Cycles/picks among `optionsFor(self)`.
    picker,
    /// Two-choice on/off.
    toggle,
    /// Read-only information row; Enter does nothing.
    info,
    /// Runs an action (e.g. create a new agent file) on Enter.
    action,
};

pub fn settingsFor(section: Section) []const Setting {
    return switch (section) {
        .model => &.{ .model, .provider, .effort },
        .output_style => &.{.output_style},
        .context_cache => &.{ .context_limit, .compaction, .read_cache_size, .prompt_cache, .terse_tools, .cache_stats },
        .agent => &.{ .task_parallel, .max_iter, .auto_check },
        .permissions => &.{ .permission_mode, .permission_rules, .web_allow_local },
        .appearance => &.{ .color_palette, .vim_mode, .nerd_icons, .no_animation, .reduced_motion },
        .agents => &.{ .active_agent, .new_agent },
    };
}

/// Options for a picker/toggle. Empty for palette/info rows.
pub fn optionsFor(s: Setting) []const []const u8 {
    return switch (s) {
        .effort => &.{ "none", "minimal", "low", "medium", "high", "xhigh", "max" },
        .output_style => &.{ "default", "concise", "explanatory", "learning", "off" },
        .permission_mode => &.{ "build", "accept-edits", "plan", "bypass" },
        .compaction => &.{ "off", "elide", "full" },
        .read_cache_size => &.{ "64K", "256K", "1M", "4M", "10M" },
        .prompt_cache, .auto_check, .web_allow_local, .vim_mode,
        .terse_tools, .no_animation, .reduced_motion => &.{ "on", "off" },
        .task_parallel => &.{ "1", "2", "3", "4", "5", "6", "7", "8", "auto" },
        .max_iter => &.{ "8", "12", "20", "40", "80", "200" },
        .context_limit => &.{ "auto", "32k", "64k", "128k", "200k", "1M" },
        .color_palette => &.{ "default", "daltonized" },
        .nerd_icons => &.{ "auto", "on", "off" },
        // `active_agent` gets its options from the discovered definitions at
        // runtime; the catalog cannot know them at comptime.
        .model, .provider, .cache_stats, .permission_rules, .new_agent, .active_agent => &.{},
    };
}

pub fn hasOption(s: Setting, value: []const u8) bool {
    for (optionsFor(s)) |o| {
        if (std.mem.eql(u8, o, value)) return true;
    }
    return false;
}

pub fn optionIndex(s: Setting, value: []const u8) ?usize {
    for (optionsFor(s), 0..) |o, i| {
        if (std.mem.eql(u8, o, value)) return i;
    }
    return null;
}

test "configmenu: every setting belongs to a section and has a label" {
    for (all_sections) |sec| {
        for (settingsFor(sec)) |s| {
            try std.testing.expectEqual(sec, s.section());
            try std.testing.expect(s.label().len > 0);
            try std.testing.expect(s.description().len > 0);
        }
    }
}

test "configmenu: sections are unique and cover every setting once" {
    for (all_sections, 0..) |a, i| {
        for (all_sections[0..i]) |b| try std.testing.expect(a != b);
    }
    var count: usize = 0;
    for (all_sections) |sec| count += settingsFor(sec).len;
    try std.testing.expectEqual(@as(usize, @typeInfo(Setting).@"enum".field_names.len), count);
}

test "configmenu: picker/toggle rows have options, palette/info rows do not" {
    for (all_sections) |sec| {
        for (settingsFor(sec)) |s| {
            switch (s.kind()) {
                .palette, .info, .action => try std.testing.expectEqual(@as(usize, 0), optionsFor(s).len),
                .picker, .toggle => {
                    // active_agent is a dynamic picker: options come from disk.
                    if (s == .active_agent) continue;
                    try std.testing.expect(optionsFor(s).len > 0);
                },
            }
        }
    }
}

test "configmenu: concise is offered as an output style" {
    try std.testing.expect(hasOption(.output_style, "concise"));
    try std.testing.expect(hasOption(.output_style, "explanatory"));
}

test "configmenu: only real settings are marked persisted" {
    try std.testing.expect(Setting.compaction.persisted());
    try std.testing.expect(Setting.prompt_cache.persisted());
    try std.testing.expect(!Setting.cache_stats.persisted());
    try std.testing.expect(!Setting.new_agent.persisted());
    try std.testing.expect(Setting.active_agent.persisted());
    try std.testing.expect(!Setting.model.persisted());
    // Environment-backed switches are visible in the screen but are not
    // config.json fields; they must never show a "saved" badge.
    try std.testing.expect(!Setting.terse_tools.persisted());
    try std.testing.expect(!Setting.no_animation.persisted());
    try std.testing.expect(!Setting.reduced_motion.persisted());
}

test "configmenu: option lookup" {
    try std.testing.expectEqual(@as(?usize, 2), optionIndex(.compaction, "full"));
    try std.testing.expect(optionIndex(.model, "kimi-k2.6") == null);
}
