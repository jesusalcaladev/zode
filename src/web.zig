const std = @import("std");

/// What the `web_fetch` / `web_search` tool needs to turn a page
/// into something a model can read: HTML to text, and search results into
/// a list.
///
/// NOTE this is deliberately PURE (no network): the part that always breaks is
/// parsing the HTML the server returns, and that is tested with a fixture, not
/// with the internet. `tools.zig` puts the network on top.
/// Browser User-Agent.
///
/// Without this half the internet returns 403: Cloudflare, GitHub and Wikipedia
/// reject std's default `User-Agent`, which is `zig`, and the response to
/// a 403 says absolutely nothing about what was behind it. A 403 with this
/// header is a problem with the site; without it, it cannot be told apart from a real
/// block.
pub const user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

/// Block tags: closing them (or opening them when they stand alone, like `<br>`)
/// puts a line break in the text.
const block_tags = [_][]const u8{
    "p",       "div",        "br",     "li",    "tr",    "td",     "th",
    "h1",      "h2",         "h3",     "h4",    "h5",    "h6",     "section",
    "article", "header",     "footer", "nav",   "aside", "ul",     "ol",
    "pre",     "blockquote", "form",   "hr",    "main",  "figure", "figcaption",
    "dl",      "dt",         "dd",     "table", "tbody", "thead",  "body",
    "html",    "head",       "title",  "meta",  "link",  "script", "style",
};

/// Tags whose whole content is thrown away (it is not page text).
const drop_tags = [_][]const u8{ "script", "style", "noscript", "svg", "head" };

fn isBlockTag(name: []const u8) bool {
    for (block_tags) |t| {
        if (std.ascii.eqlIgnoreCase(t, name)) return true;
    }
    return false;
}

fn isDropTag(name: []const u8) bool {
    for (drop_tags) |t| {
        if (std.ascii.eqlIgnoreCase(t, name)) return true;
    }
    return false;
}

/// HTML to readable text.
///
/// It is not an HTML parser: it is a "strip what is not text" that survives
/// the HTML the real web returns (minified, with scripts in the middle of the text and
/// with entities). What comes out is for a model to read, not for
/// reconstructing the page: if the site needs a real engine, it does not fit here.
///
/// Rules, in order:
/// 1. `<!--…-->`, `<script>…</script>`, `<style>…</style>` and `<head>…</head>`
///    are dropped.
/// 2. Every block tag (or its closing tag) is a line break.
/// 3. Every other tag disappears, leaving its content.
/// 4. Entities (`&amp;`, `&#39;`, `&hellip;`…) are converted.
/// 5. Runs of spaces are merged into one, and 3+ line breaks into 2.
pub fn htmlToText(arena: std.mem.Allocator, html: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    // Pending space: it is only emitted if real text comes after it. Without this
    // every tag leaves a gap and the text comes out with a space between every word.
    var space_pending = false;
    // Pending breaks, at most 2 (readable text does not carry more).
    var nl_pending: u8 = 0;

    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            // Comment.
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                i = (std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len) + 3;
                space_pending = true;
                continue;
            }
            const end = tagEnd(html, i) orelse {
                // Not a tag: the `<` goes as text (`a < b`).
                space_pending = flushSpace(arena, &out, &nl_pending, space_pending);
                out.append(arena, '<') catch return "";
                i += 1;
                continue;
            };
            const name = tagName(html[i..]);
            if (name.len > 0 and isDropTag(name)) {
                // No closing tag (a loose `<meta …>`): only skip the tag itself.
                i = closingTag(html, i, name) orelse end;
                space_pending = true;
                continue;
            }
            if (isBlockTag(name)) {
                // `<br>`/`<hr>` FORCE a break (two, to leave a blank
                // line). Containers only force it if we are not already
                // at a boundary: `</li><li>` is ONE break, not two, and with the naive
                // rule a blank line came out between every list item.
                const forces = std.ascii.eqlIgnoreCase(name, "br") or std.ascii.eqlIgnoreCase(name, "hr");
                nl_pending = if (forces) 2 else if (nl_pending == 0) 1 else nl_pending;
                space_pending = false;
            }
            i = end;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            space_pending = true;
            i += 1;
            continue;
        }

        // Real text: first the pending breaks, then the text.
        space_pending = flushSpace(arena, &out, &nl_pending, space_pending);
        i += appendEntity(arena, &out, html, i);
    }

    // Closing: no dangling space and no extra breaks.
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    return out.items;
}

/// Flushes the pending space/breaks BEFORE writing real text.
///
/// A pending break eats the space that preceded it, and the space is only
/// written if the buffer is not already at the start of a line: that is why the text does
/// not come out with a gap after every tag.
fn flushSpace(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    nl_pending: *u8,
    space_pending: bool,
) bool {
    if (nl_pending.* > 0) {
        var k: u8 = 0;
        while (k < nl_pending.*) : (k += 1) {
            if (out.items.len > 0) out.append(arena, '\n') catch return false;
        }
        nl_pending.* = 0;
        return false;
    }
    if (space_pending and out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        out.append(arena, ' ') catch return false;
    }
    return false;
}

/// Name of the tag that starts in `rest` (which starts with `<`).
fn tagName(rest: []const u8) []const u8 {
    var j: usize = 1; // the '<'
    if (j < rest.len and rest[j] == '/') j += 1;
    const start = j;
    while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '-')) j += 1;
    return rest[start..j];
}

/// End of the tag that starts at `i`, or null if there is no `>` before the next
/// `<` (or before the end of the text).
///
/// CAREFUL with the `null`: `Tom & Jerry <3` is NOT a tag, and treating it as
/// one would eat the rest of the line. A `<` with no `>` before another `<` is text.
fn tagEnd(html: []const u8, i: usize) ?usize {
    var j = i + 1; // the '<' does not count as "the next '<'"
    while (j < html.len) : (j += 1) {
        switch (html[j]) {
            '>' => return j + 1,
            '<' => return null,
            else => {},
        }
    }
    return null;
}

/// ABSOLUTE position (just after the `>`) of the closing tag `name` that
/// follows the opening tag at `open_at`.
///
/// CAREFUL: the index is into the WHOLE html, not into a slice starting at the tag.
/// It used to search over `html[open_at..]` and return that offset, which was
/// then used as absolute: with `<head></head>` the jump landed on the `/` of the
/// closing tag and the whole `</head>` slipped into the text. An index that is not
/// into the buffer being indexed is the worst possible kind of bug: it gives no error, it gives garbage.
fn closingTag(html: []const u8, open_at: usize, name: []const u8) ?usize {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "</{s}", .{name}) catch return null;
    const at = std.mem.indexOfPos(u8, html, open_at + 1, needle) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, html, at, '>') orelse return null;
    return gt + 1;
}

/// Writes the text from `i`, decoding entities. Returns how many bytes
/// of HTML were consumed.
fn appendEntity(arena: std.mem.Allocator, out: *std.ArrayList(u8), html: []const u8, i: usize) usize {
    if (html[i] != '&') {
        out.append(arena, html[i]) catch return html.len - i;
        return 1;
    }
    // A loose `&` (not an entity) is written as is.
    const semi = std.mem.indexOfScalarPos(u8, html, i, ';') orelse {
        out.append(arena, '&') catch {};
        return 1;
    };
    const name = html[i + 1 .. semi];
    if (name.len == 0 or name.len > 10) {
        out.append(arena, '&') catch {};
        return 1;
    }
    // Numeric: &#39; &#x27;
    if (name[0] == '#') {
        const parsed: ?u21 = if (name.len > 1 and (name[1] == 'x' or name[1] == 'X'))
            (std.fmt.parseInt(u21, name[2..], 16) catch null)
        else
            (std.fmt.parseInt(u21, name[1..], 10) catch null);
        if (parsed) |v| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(@min(v, 0x10FFFF)), &buf) catch 0;
            out.appendSlice(arena, buf[0..n]) catch {};
            return (semi - i) + 1;
        }
    }
    const replacement: ?[]const u8 = namedEntity(name);
    if (replacement) |r| {
        out.appendSlice(arena, r) catch {};
        return (semi - i) + 1;
    }
    out.append(arena, '&') catch {};
    return 1;
}

/// Named entities. Only the ones that really show up in the text of a
/// page; a table of 250 names does not pay off: whatever is not here stays
/// as is (`&foo;`), which is what you see in the source.
fn namedEntity(name: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{
        .{ "amp", "&" },    .{ "lt", "<" },   .{ "gt", ">" },
        .{ "quot", "\"" },  .{ "apos", "'" }, .{ "nbsp", " " },
        .{ "hellip", "…" },
        .{ "mdash", "—" },
        .{ "ndash", "–" },
        .{ "laquo", "«" },
        .{ "raquo", "»" },
        .{ "ldquo", "“" },
        .{ "rdquo", "”" },
        .{ "lsquo", "‘" },
        .{ "rsquo", "’" },
        .{ "copy", "©" },
        .{ "reg", "®" },
        .{ "trade", "™" },
        .{ "deg", "°" },
        .{ "middot", "·" },
        .{ "bull", "•" },
        .{ "times", "×" },
        .{ "euro", "€" },
        .{ "pound", "£" },
        .{ "frac12", "½" },
        .{ "larr", "←" },
        .{ "rarr", "→" },
        .{ "harr", "↔" },
        .{ "darr", "↓" },
        .{ "uarr", "↑" },
        .{ "infin", "∞" },
        .{ "ne", "≠" },
        .{ "le", "≤" },
        .{ "ge", "≥" },
        .{ "auml", "ä" },
        .{ "ouml", "ö" },
        .{ "uuml", "ü" },
        .{ "szlig", "ß" },
        .{ "ntilde", "ñ" },
        .{ "aacute", "á" },
        .{ "eacute", "é" },
        .{ "iacute", "í" },
        .{ "oacute", "ó" },
        .{ "uacute", "ú" },
        .{ "agrave", "à" },
        .{ "egrave", "è" },
        .{ "ccedil", "ç" },
        .{ "shy", "" },     .{ "ensp", " " }, .{ "emsp", " " },
        .{ "thinsp", " " },
    };
    for (pairs) |p| {
        if (std.ascii.eqlIgnoreCase(p[0], name)) return p[1];
    }
    return null;
}

/// Extracts search results from DuckDuckGo's HTML (`html/` endpoint).
///
/// Returns text with the results numbered: title, URL and snippet. If it finds
/// none it returns a message saying what to do (and not an
/// opaque error), because this scraper breaks the day they change one of the HTML classes.
pub fn searchResults(arena: std.mem.Allocator, html: []const u8, max: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    var pos: usize = 0;
    while (n < max) {
        const anchor = std.mem.indexOfPos(u8, html, pos, "class=\"result__a\"") orelse break;
        const href_at = std.mem.indexOfPos(u8, html, anchor, "href=\"") orelse break;
        const href_start = href_at + 6;
        const href_end = std.mem.indexOfScalarPos(u8, html, href_start, '"') orelse break;
        const href = html[href_start..href_end];

        // The title sits between the `>` that closes the `<a …>` and its `</a>`.
        const title_start = (std.mem.indexOfScalarPos(u8, html, href_end, '>') orelse break) + 1;
        const title_end = std.mem.indexOfPos(u8, html, title_start, "</a>") orelse break;

        pos = title_end;

        n += 1;
        out.print(arena, "{d}. ", .{n}) catch return "";
        out.appendSlice(arena, cleanText(arena, html[title_start..title_end])) catch return "";
        out.append(arena, '\n') catch return "";

        const url = realUrl(arena, href);
        if (url.len > 0) {
            out.print(arena, "   {s}\n", .{url}) catch return "";
        }

        // The snippet comes after the title, in another `<a>`.
        if (std.mem.indexOfPos(u8, html, pos, "class=\"result__snippet\"")) |sn| {
            const s_start = (std.mem.indexOfScalarPos(u8, html, sn, '>') orelse sn) + 1;
            const s_end = std.mem.indexOfPos(u8, html, s_start, "</a>") orelse html.len;
            const snip = cleanText(arena, html[s_start..@min(s_end, s_start + 400)]);
            if (snip.len > 0) {
                out.print(arena, "   {s}\n", .{snip}) catch return "";
            }
            pos = s_end;
        }
        out.append(arena, '\n') catch return "";
    }
    if (n == 0) return "";
    return out.items;
}

/// The real URL behind the DuckDuckGo link (`//duckduckgo.com/l/?uddg=…`).
fn realUrl(arena: std.mem.Allocator, href: []const u8) []const u8 {
    if (std.mem.indexOf(u8, href, "uddg=")) |at| {
        var rest = href[at + 5 ..];
        if (std.mem.indexOfScalar(u8, rest, '&')) |amp| rest = rest[0..amp];
        const buf = arena.dupe(u8, rest) catch return "";
        return std.Uri.percentDecodeInPlace(buf);
    }
    if (std.mem.startsWith(u8, href, "//")) {
        return std.fmt.allocPrint(arena, "https:{s}", .{href}) catch "";
    }
    return href;
}

/// Text of a chunk of HTML: strips tags and decodes entities.
fn cleanText(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '<') {
            i = (std.mem.indexOfScalarPos(u8, raw, i, '>') orelse raw.len) + 1;
            continue;
        }
        i += appendEntity(arena, &out, raw, i);
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
}

// ── tests ─────────────────────────────────────────────────────

test "htmlToText quita script, style y etiquetas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const html =
        \\<html><head><title>T</title><style>body{color:red}</style></head>
        \\<body><script>var a = 1 < 2;</script>
        \\<h1>Title</h1><p>Hello &amp; <b>bye</b>.</p></body></html>
    ;
    const text = htmlToText(arena_state.allocator(), html);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello & bye") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "var a") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "color:red") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Title") != null);
}

test "htmlToText: los saltos de bloque no dejan huecos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<li>one</li><li>two</li><br><p>three</p>");
    // Neither loose spaces next to the tags nor 5 breaks in a row.
    try std.testing.expectEqualStrings("one\ntwo\n\nthree", text);
}

test "htmlToText decodifica entidades, incluidas las numéricas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<p>a &lt; b &#39;c&#39; caf&eacute;</p>");
    try std.testing.expectEqualStrings("a < b 'c' café", text);
}

test "htmlToText no inventa texto con un & suelto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<p>Tom & Jerry <3</p>");
    try std.testing.expectEqualStrings("Tom & Jerry <3", text);
}

test "htmlToText: <head></head> vacío no deja el cierre en el texto" {
    // Regression: the jump to the closing tag was computed over `html[i..]` and
    // used as an index into the whole HTML. With an empty `<head></head>` the jump
    // landed on the `/` of the closing tag and the whole `</head>` came out in the text.
    // The worst part of the bug is that it gives no error: it gives garbage, and the loop may not
    // advance (the suite would hang).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<html><head></head><p>a</p></html>");
    try std.testing.expectEqualStrings("a", text);
}

test "searchResults saca título, URL y snippet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const html =
        \\<div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2F&amp;rut=abc">Zig Language</a>
        \\<a class="result__snippet" href="#">Fast and <b>readable</b></a></div>
        \\<div class="result"><a class="result__a" href="https://example.com/x">Second</a></div>
    ;
    const out = searchResults(arena_state.allocator(), html, 8);
    try std.testing.expect(std.mem.indexOf(u8, out, "1. Zig Language") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://ziglang.org/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Fast and readable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2. Second") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.com/x") != null);
}

test "searchResults sin resultados devuelve vacío (no texto basura)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = searchResults(arena_state.allocator(), "<html><body>no results here</body></html>", 8);
    try std.testing.expectEqualStrings("", out);
}
