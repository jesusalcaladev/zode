const std = @import("std");

/// Nerd Font language icons for code block chips.
///
/// The icon is an additive prefix: the language label is ALWAYS shown. When
/// Nerd Font glyphs are unavailable or icons are disabled, the chip renders as
/// the label alone (the previous behavior). Icons use the Nerd Fonts PUA
/// codepoints (Devicons/Seti/Font Awesome subsets commonly bundled in Nerd
/// Fonts v2/v3). The mapping is data, not logic — adjust glyphs here if a
/// font renders one poorly.
///
/// `ZODE_NERD_ICONS` controls rendering: `0`/`off`/`false` disables icons;
/// `1`/`on`/`true` enables them; `auto` or unset enables them (default).

pub const Chip = struct {
    /// UTF-8 Nerd Font glyph, or null when there is no mapping / icons are off.
    icon: ?[]const u8,
    /// Canonical short display label. Always meaningful when the input has a
    /// language; empty only when the fence info string is empty.
    label: []const u8,
};

const Entry = struct {
    aliases: []const []const u8,
    label: []const u8,
    icon: []const u8,
};

// Nerd Fonts PUA glyphs (widely available in Nerd Fonts v2/v3). Unknown
// languages never get a fake icon: the chip falls back to the plain label with
// the existing marker, so meaning is preserved without a Nerd Font.
const table = [_]Entry{
    .{ .aliases = &.{"zig"}, .label = "zig", .icon = "\u{e6a9}" }, // nf-seti-zig
    .{ .aliases = &.{ "c", "h" }, .label = "c", .icon = "\u{e61e}" }, // nf-custom-c
    .{ .aliases = &.{ "cpp", "c++", "cc", "cxx", "hpp", "hxx", "h++" }, .label = "cpp", .icon = "\u{e61d}" }, // nf-custom-cpp
    .{ .aliases = &.{ "csharp", "cs", "c#" }, .label = "c#", .icon = "\u{f81a}" }, // nf-mdi-language_csharp
    .{ .aliases = &.{ "fsharp", "fs", "f#" }, .label = "f#", .icon = "\u{e7a7}" }, // nf-dev-fsharp
    .{ .aliases = &.{ "rust", "rs" }, .label = "rust", .icon = "\u{e7a8}" }, // nf-dev-rust
    .{ .aliases = &.{ "go", "golang" }, .label = "go", .icon = "\u{e626}" }, // nf-seti-go
    .{ .aliases = &.{ "python", "py", "pyw" }, .label = "python", .icon = "\u{e73c}" }, // nf-dev-python
    .{ .aliases = &.{ "javascript", "js", "mjs", "cjs", "node" }, .label = "js", .icon = "\u{e74e}" }, // nf-dev-javascript
    .{ .aliases = &.{ "typescript", "ts", "mts", "cts" }, .label = "ts", .icon = "\u{e628}" }, // nf-seti-typescript
    .{ .aliases = &.{"tsx"}, .label = "tsx", .icon = "\u{e7ba}" }, // nf-dev-react
    .{ .aliases = &.{"jsx"}, .label = "jsx", .icon = "\u{e7ba}" }, // nf-dev-react
    .{ .aliases = &.{ "java" }, .label = "java", .icon = "\u{e738}" }, // nf-dev-java
    .{ .aliases = &.{ "kotlin", "kt", "kts" }, .label = "kotlin", .icon = "\u{e634}" }, // nf-seti-kotlin
    .{ .aliases = &.{ "swift" }, .label = "swift", .icon = "\u{e755}" }, // nf-dev-swift
    .{ .aliases = &.{ "ruby", "rb" }, .label = "ruby", .icon = "\u{e739}" }, // nf-dev-ruby
    .{ .aliases = &.{ "php" }, .label = "php", .icon = "\u{e73d}" }, // nf-dev-php
    .{ .aliases = &.{ "lua" }, .label = "lua", .icon = "\u{e620}" }, // nf-seti-lua
    .{ .aliases = &.{ "dart" }, .label = "dart", .icon = "\u{e798}" }, // nf-dev-dart
    .{ .aliases = &.{ "elixir", "ex", "exs" }, .label = "elixir", .icon = "\u{e62d}" }, // nf-custom-elixir
    .{ .aliases = &.{ "erlang", "erl" }, .label = "erlang", .icon = "\u{e7b1}" }, // nf-dev-erlang
    .{ .aliases = &.{ "haskell", "hs" }, .label = "haskell", .icon = "\u{e777}" }, // nf-dev-haskell
    .{ .aliases = &.{ "scala" }, .label = "scala", .icon = "\u{e737}" }, // nf-dev-scala
    .{ .aliases = &.{ "clojure", "clj", "cljs" }, .label = "clojure", .icon = "\u{e768}" }, // nf-dev-clojure
    .{ .aliases = &.{ "julia", "jl" }, .label = "julia", .icon = "\u{e624}" }, // nf-seti-julia
    .{ .aliases = &.{ "r" }, .label = "r", .icon = "\u{f25d}" }, // nf-fa-registered (R)
    .{ .aliases = &.{ "perl", "pl" }, .label = "perl", .icon = "\u{e769}" }, // nf-dev-perl
    .{ .aliases = &.{ "nim" }, .label = "nim", .icon = "\u{e677}" }, // nf-seti-nim
    .{ .aliases = &.{ "ocaml", "ml" }, .label = "ocaml", .icon = "\u{e67a}" }, // nf-seti-ocaml
    .{ .aliases = &.{ "solidity", "sol" }, .label = "solidity", .icon = "\u{e656}" }, // nf-seti-solidity
    .{ .aliases = &.{ "json", "jsonc", "json5" }, .label = "json", .icon = "\u{e60b}" }, // nf-seti-json
    .{ .aliases = &.{ "yaml", "yml" }, .label = "yaml", .icon = "\u{f481}" }, // nf-oct-file_code
    .{ .aliases = &.{ "toml" }, .label = "toml", .icon = "\u{e6b2}" }, // nf-seti-config
    .{ .aliases = &.{ "xml", "xsl", "plist" }, .label = "xml", .icon = "\u{f121}" }, // nf-fa-code
    .{ .aliases = &.{ "markdown", "md", "mdx" }, .label = "md", .icon = "\u{e73e}" }, // nf-dev-markdown
    .{ .aliases = &.{ "html", "htm" }, .label = "html", .icon = "\u{e736}" }, // nf-dev-html5
    .{ .aliases = &.{ "css", "scss", "sass", "less" }, .label = "css", .icon = "\u{e749}" }, // nf-dev-css3
    .{ .aliases = &.{ "vue" }, .label = "vue", .icon = "\u{e6a0}" }, // nf-seti-vue
    .{ .aliases = &.{ "svelte" }, .label = "svelte", .icon = "\u{e697}" }, // nf-seti-svelte
    .{ .aliases = &.{ "astro" }, .label = "astro", .icon = "\u{e628}" }, // nf-seti-typescript (closest common)
    .{ .aliases = &.{ "graphql", "gql" }, .label = "graphql", .icon = "\u{e662}" }, // nf-seti-graphql
    .{ .aliases = &.{ "proto", "protobuf" }, .label = "proto", .icon = "\u{f121}" }, // nf-fa-code
    .{ .aliases = &.{ "sql" }, .label = "sql", .icon = "\u{e706}" }, // nf-dev-database
    .{ .aliases = &.{ "sh", "bash", "zsh", "shell", "console", "fish", "ksh" }, .label = "sh", .icon = "\u{ebca}" }, // nf-cod-terminal
    .{ .aliases = &.{ "powershell", "ps1", "pwsh" }, .label = "ps", .icon = "\u{ebc7}" }, // nf-cod-terminal_powershell
    .{ .aliases = &.{ "diff", "patch" }, .label = "diff", .icon = "\u{f440}" }, // nf-oct-diff
    .{ .aliases = &.{ "git", "gitignore", "gitattributes" }, .label = "git", .icon = "\u{f1d3}" }, // nf-fa-git
    .{ .aliases = &.{ "dockerfile", "docker", "containerfile" }, .label = "docker", .icon = "\u{f308}" }, // nf-linux-docker
    .{ .aliases = &.{ "makefile", "make", "mk" }, .label = "make", .icon = "\u{e673}" }, // nf-seti-makefile
    .{ .aliases = &.{ "cmake" }, .label = "cmake", .icon = "\u{e673}" }, // nf-seti-makefile
    .{ .aliases = &.{ "nix" }, .label = "nix", .icon = "\u{f313}" }, // nf-linux-nixos
    .{ .aliases = &.{ "terraform", "tf", "hcl" }, .label = "tf", .icon = "\u{e69a}" }, // nf-seti-terraform
    .{ .aliases = &.{ "ini", "conf", "cfg", "config", "properties" }, .label = "conf", .icon = "\u{e615}" }, // nf-seti-config
    .{ .aliases = &.{ "env", "dotenv" }, .label = "env", .icon = "\u{f462}" }, // nf-oct-key
    .{ .aliases = &.{ "vim", "vimrc" }, .label = "vim", .icon = "\u{e62b}" }, // nf-custom-vim
    .{ .aliases = &.{ "csv", "tsv" }, .label = "csv", .icon = "\u{f1c3}" }, // nf-fa-file_excel_o (tabular)
    .{ .aliases = &.{ "log" }, .label = "log", .icon = "\u{f15c}" }, // nf-fa-file_text
    .{ .aliases = &.{ "txt", "text", "plain" }, .label = "text", .icon = "\u{f15c}" }, // nf-fa-file_text
};

/// First token of a fence info string, trimmed. Fences may carry attributes
/// (`rust,no_run`, `python title=...`); the language is the leading token.
pub fn infoToken(raw: []const u8) []const u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return "";
    var end: usize = 0;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (c == ' ' or c == '\t' or c == ',' or c == '{') break;
    }
    return s[0..end];
}

fn eqlLowerAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != bc) return false;
    }
    return true;
}

/// Resolve an icon and display label for a fence language. `nerd_icons` gates
/// the icon only; the label is always derived from the info string.
pub fn lookup(raw: []const u8, nerd_icons: bool) Chip {
    const tok = infoToken(raw);
    if (tok.len == 0) return .{ .icon = null, .label = "" };
    for (&table) |*e| {
        for (e.aliases) |a| {
            if (eqlLowerAscii(tok, a)) {
                return .{ .icon = if (nerd_icons) e.icon else null, .label = e.label };
            }
        }
    }
    // Unknown language: show the raw token as the label (trimmed), no icon.
    // The chip must stay readable even without a mapping.
    return .{ .icon = null, .label = tok };
}

/// Whether Nerd Font icons are enabled. Default is enabled (`auto`/unset = on)
/// because the label is always rendered alongside the icon, so a missing font
/// degrades to a replacement glyph + readable label rather than hiding meaning.
pub fn nerdIconsEnabled(env: ?*const std.process.Environ.Map) bool {
    const m = env orelse return true;
    const v = m.get("ZODE_NERD_ICONS") orelse return true;
    const s = std.mem.trim(u8, v, " \t\r\n");
    if (s.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(s, "0") or std.ascii.eqlIgnoreCase(s, "off") or
        std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no"))
        return false;
    if (std.ascii.eqlIgnoreCase(s, "1") or std.ascii.eqlIgnoreCase(s, "on") or
        std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "yes") or
        std.ascii.eqlIgnoreCase(s, "auto"))
        return true;
    return true;
}

test "lookup: known aliases map to canonical label and icon" {
    const zig = lookup("zig", true);
    try std.testing.expectEqualStrings("zig", zig.label);
    try std.testing.expect(zig.icon != null);

    const js = lookup("javascript", true);
    try std.testing.expectEqualStrings("js", js.label);
    try std.testing.expect(js.icon != null);

    const py = lookup("py", true);
    try std.testing.expectEqualStrings("python", py.label);

    const cpp = lookup("c++", true);
    try std.testing.expectEqualStrings("cpp", cpp.label);

    const sh = lookup("bash", true);
    try std.testing.expectEqualStrings("sh", sh.label);

    const rs = lookup("rs", true);
    try std.testing.expectEqualStrings("rust", rs.label);

    const cs = lookup("c#", true);
    try std.testing.expectEqualStrings("c#", cs.label);
    try std.testing.expect(cs.icon != null);

    const env = lookup("dotenv", true);
    try std.testing.expectEqualStrings("env", env.label);
}

test "lookup: info string attributes are ignored" {
    const r = lookup("rust,no_run", true);
    try std.testing.expectEqualStrings("rust", r.label);
    try std.testing.expect(r.icon != null);

    const p = lookup("python title=demo", true);
    try std.testing.expectEqualStrings("python", p.label);

    const c = lookup("  ts  ", true);
    try std.testing.expectEqualStrings("ts", c.label);
}

test "lookup: unknown language keeps its label and has no icon" {
    const u = lookup("brainfuck", true);
    try std.testing.expectEqualStrings("brainfuck", u.label);
    try std.testing.expect(u.icon == null);

    const empty = lookup("", true);
    try std.testing.expectEqualStrings("", empty.label);
    try std.testing.expect(empty.icon == null);
}

test "lookup: disabled icons keep the label" {
    const z = lookup("zig", false);
    try std.testing.expectEqualStrings("zig", z.label);
    try std.testing.expect(z.icon == null);
}

test "nerdIconsEnabled: default/auto/on and explicit off" {
    var m = std.process.Environ.Map.init(std.testing.allocator);
    defer m.deinit();

    try std.testing.expect(nerdIconsEnabled(null));
    try std.testing.expect(nerdIconsEnabled(&m));

    try m.put("ZODE_NERD_ICONS", "auto");
    try std.testing.expect(nerdIconsEnabled(&m));
    try m.put("ZODE_NERD_ICONS", "1");
    try std.testing.expect(nerdIconsEnabled(&m));
    try m.put("ZODE_NERD_ICONS", "true");
    try std.testing.expect(nerdIconsEnabled(&m));
    try m.put("ZODE_NERD_ICONS", "0");
    try std.testing.expect(!nerdIconsEnabled(&m));
    try m.put("ZODE_NERD_ICONS", "off");
    try std.testing.expect(!nerdIconsEnabled(&m));
    try m.put("ZODE_NERD_ICONS", "false");
    try std.testing.expect(!nerdIconsEnabled(&m));
}
