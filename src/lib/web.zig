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
/// The host part of an `http(s)://` URL, lowercased, without the brackets of an IPv6
/// literal and without userinfo (`http://user:pw@host/`).
///
/// Written by hand instead of with `std.Uri.parse` because this runs on whatever the
/// MODEL typed, and a parser that fails must not turn a blocked host into an allowed
/// one: the fallbacks below are all "treat it as a host and check it".
pub fn urlHost(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..] else return "";
    // Cut at the first delimiter that ends the authority.
    if (std.mem.indexOfAny(u8, rest, "/?#")) |i| rest = rest[0..i];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| rest = rest[i + 1 ..];
    if (rest.len >= 2 and rest[0] == '[') {
        if (std.mem.indexOfScalar(u8, rest, ']')) |i| return rest[1..i];
        return rest[0..];
    }
    // A port is not part of the host. IPv6 literal handled above.
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| rest = rest[0..i];
    return rest;
}

/// Case-insensitive host equality. Hosts are case-insensitive by RFC 3986 and a model
/// writes `LOCALHOST` as readily as `localhost`.
///
/// It is spelled out rather than by lowercasing: `std.ascii.lowerString` needs a
/// MUTABLE output buffer, and the only buffer here is the caller's URL, which belongs
/// to the model. Copying the URL to normalise a comparison is not worth a heap
/// allocation per fetch.
fn hostEql(h: []const u8, literal: []const u8) bool {
    return std.ascii.eqlIgnoreCase(h, literal);
}

/// The host parsed as a dotted quad, or null when it is not one.
///
/// It exists because the blocklists below look at the leading octets, and reading
/// leading LABELS off a string is not the same thing: `169.254.169.254.example.com` is a
/// perfectly public host whose first two labels are "169" and "254", and a check that
/// only looked at those blocked it. A domain name is not an address, and the only way to
/// tell them apart without a full URL parser is to insist on four numeric octets.
fn ipv4(host: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var n: usize = 0;
    while (it.next()) |label| {
        if (n >= 4) return null;
        if (label.len == 0 or label.len > 3) return null;
        for (label) |c| if (!std.ascii.isDigit(c)) return null;
        const v = std.fmt.parseInt(u16, label, 10) catch return null;
        // A leading zero means octal in some resolvers and nothing in others; either
        // way it is not something to guess at, so treat it as "not this range".
        if (label.len > 1 and label[0] == '0') return null;
        if (v > 255) return null;
        out[n] = @intCast(v);
        n += 1;
    }
    if (n != 4) return null;
    return out;
}

/// Is this one of the endpoints that hand out CREDENTIALS?
///
/// `web_fetch` does not ask for permission (see `needsPermission`) while `bash` does,
/// so anything reachable with `web_fetch` is reachable without the user approving
/// anything. That is the whole reason this list exists: it is not a sandbox (a model
/// can always reach the same address with `curl` through `bash`, behind a permission
/// dialog) but it removes the sharpest edge, which is a page the model read saying
/// "also fetch http://169.254.169.254/latest/meta-data/iam/security-credentials/".
///
/// The link-local range covers AWS, GCP, Azure and DigitalOcean, which all serve
/// instance credentials from it. `metadata.google.internal` is GCP's other name for the
/// same thing. `fd00:ec2::254` is the AWS IPv6 endpoint.
///
/// **Loopback is NOT here on purpose.** Fetching your own dev server is a real thing to
/// do, and a rule that broke it would be turned off — which would take the metadata
/// block with it. The broader private ranges are a policy the user chooses, with
/// `ZODE_WEB_ALLOW_LOCAL=1` to allow them.
pub fn isCredentialEndpoint(url: []const u8) bool {
    const h = urlHost(url);
    if (h.len == 0) return false;
    if (hostEql(h, "169.254.169.254")) return true;
    if (hostEql(h, "metadata.google.internal")) return true;
    if (hostEql(h, "fd00:ec2::254")) return true;
    // Any link-local IPv4: 169.254.0.0/16.
    const ip = ipv4(h) orelse return false;
    return ip[0] == 169 and ip[1] == 254;
}

/// Is the host on loopback or on a private range?
///
/// Separate from `isCredentialEndpoint` because they are different decisions with
/// different costs: the first is a rule with no legitimate exception, the second is a
/// judgement call that `ZODE_WEB_ALLOW_LOCAL` hands to the user.
pub fn isPrivateHost(url: []const u8) bool {
    if (isCredentialEndpoint(url)) return true;
    const h = urlHost(url);
    if (h.len == 0) return false;
    if (hostEql(h, "localhost")) return true;
    if (std.ascii.endsWithIgnoreCase(h, ".localhost")) return true;
    if (hostEql(h, "::1") or hostEql(h, "0:0:0:0:0:0:0:1")) return true;
    if (hostEql(h, "0.0.0.0")) return true;
    const ip = ipv4(h) orelse return false;
    if (ip[0] == 127) return true;
    if (ip[0] == 10) return true;
    if (ip[0] == 192 and ip[1] == 168) return true;
    if (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) return true;
    return false;
}

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
    return renderResults(arena, html, max, "class=\"result__a\"", "class=\"result__snippet\"");
}

/// The same thing from DuckDuckGo's `lite/` endpoint.
///
/// It exists because `html/` is not always there: when it answers 200 with a
/// layout this parser does not know, the honest thing would be to say so, and it
/// does say so — but the tool then has NO results at all for a query the engine
/// answered fine. `lite/` is a different page with different classes, and it is
/// the cheapest way to turn "the scraper broke" into "here are your results".
pub fn liteSearchResults(arena: std.mem.Allocator, html: []const u8, max: usize) []const u8 {
    return renderResults(arena, html, max, "class=\"result-link\"", "class=\"result-snippet\"");
}

/// Parses one of the two shapes and renders the numbered list.
///
/// The one thing this gets right that the original did not: **a snippet belongs to
/// the result it follows**. The snippet was searched for from the end of the title
/// to the end of the DOCUMENT, so a result with no snippet of its own was given
/// the NEXT one's, and the model read a description that had nothing to do with
/// the title above it. Here the search for the next title bounds it.
/// `indexOf` inside a window. `std.mem` has no `indexOfPosPos` in 0.16 and the
/// window is the whole point (a snippet must not come from the next result).
fn indexOfIn(haystack: []const u8, from: usize, to: usize, needle: []const u8) ?usize {
    if (from >= to or to > haystack.len) return null;
    const at = std.mem.indexOfPos(u8, haystack, from, needle) orelse return null;
    return if (at < to) at else null;
}

fn renderResults(
    arena: std.mem.Allocator,
    html: []const u8,
    max: usize,
    title_class: []const u8,
    snippet_class: []const u8,
) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    var pos: usize = 0;
    // The same URL twice is not two results, and the second one only makes the
    // model think it has more to read than it does.
    var seen = std.StringHashMap(void).init(arena);
    defer seen.deinit();

    while (n < max) {
        const anchor = std.mem.indexOfPos(u8, html, pos, title_class) orelse break;
        const href_at = std.mem.indexOfPos(u8, html, anchor, "href=\"") orelse break;
        const href_start = href_at + 6;
        const href_end = std.mem.indexOfScalarPos(u8, html, href_start, '"') orelse break;
        const href = html[href_start..href_end];

        // The title sits between the `>` that closes the `<a …>` and its `</a>`.
        const title_start = (std.mem.indexOfScalarPos(u8, html, href_end, '>') orelse break) + 1;
        const title_end = std.mem.indexOfPos(u8, html, title_start, "</a>") orelse break;

        const url = realUrl(arena, href);
        const title = cleanText(arena, html[title_start..title_end]);
        // Where this result ENDS: the next title. The snippet has to be looked for
        // inside that window and nowhere else.
        const next_title = std.mem.indexOfPos(u8, html, title_end, title_class);
        const block_end = next_title orelse html.len;

        pos = title_end;
        if (url.len == 0 or title.len == 0) continue;
        if (seen.contains(url)) continue;
        seen.put(url, {}) catch {};

        n += 1;
        out.print(arena, "{d}. ", .{n}) catch return "";
        out.appendSlice(arena, title) catch return "";
        out.append(arena, '\n') catch return "";
        out.print(arena, "   {s}\n", .{url}) catch return "";

        // The snippet, inside THIS result's block.
        if (indexOfIn(html, title_end, block_end, snippet_class)) |sn| {
            const s_start = (std.mem.indexOfScalarPos(u8, html, sn, '>') orelse sn) + 1;
            const s_end = indexOfIn(html, s_start, block_end, "</a>") orelse block_end;
            const snip = cleanText(arena, html[s_start..@min(s_end, s_start + 400)]);
            if (snip.len > 0) {
                out.print(arena, "   {s}\n", .{snip}) catch return "";
            }
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

// ── one page of a document ───────────────────────────────────────────

/// One window of a document, with everything the model needs to page through it.
///
/// `web_fetch` always returned the BEGINNING of the text, and its truncation
/// note promised "ask for the rest with a deeper request" — a parameter that did
/// not exist anywhere in the schema. That is a promise the model cannot keep:
/// it re-asks, gets the same first 16 KB, and reads that as the whole document.
/// This is the parameter: `offset` is a byte position into THIS text, and the
/// note names the exact `offset` to pass next, so continuing is one copy
/// instead of a guess that usually lands mid-word.
pub fn excerpt(arena: std.mem.Allocator, text: []const u8, offset: usize, max_bytes: usize) []const u8 {
    if (offset >= text.len) {
        return std.fmt.allocPrint(
            arena,
            "offset {d} is past the end: the extracted text is {d} bytes long. Start again with offset 0 (or omit it).",
            .{ offset, text.len },
        ) catch "offset is past the end of the document";
    }
    const rest = text[offset..];
    var out: std.ArrayList(u8) = .empty;
    // Where this page starts, so a mid-document page cannot be mistaken for a
    // document that begins mid-sentence.
    if (offset > 0) {
        out.print(arena, "[continuing at byte {d} of {d}]\n\n", .{ offset, text.len }) catch return "out of memory building the answer";
    }
    if (rest.len <= max_bytes) {
        out.appendSlice(arena, rest) catch return "out of memory building the answer";
        return out.items;
    }
    // Cut at a line boundary: cutting in the middle of a word leaves garbage
    // that the model keeps thinking is the end of the document.
    var cut = max_bytes;
    while (cut > 0 and rest[cut] != '\n') cut -= 1;
    if (cut < max_bytes / 2) cut = max_bytes; // page with no line breaks: hard cut
    out.appendSlice(arena, rest[0..cut]) catch return "out of memory building the answer";
    // The position the NEXT call should pass, absolute in the document: the model
    // never has to do arithmetic on two different coordinate systems.
    const at = offset + cut;
    out.print(arena, "\n\n… (truncated at {d} of {d} bytes; pass offset={d} to continue)", .{ at, text.len, at }) catch {};
    return out.items;
}

// ── Brave (the configured engine) ────────────────────────────────────

/// What a Brave answer body says, in the three things it can say.
///
/// The shape is verified against Brave's own artifacts and not from memory:
/// their official agent skill documents `web.results[]`, their reference Python
/// client models `title: str`, `url: str`, `description: str | None`, and its
/// mock data — a real response, 56 KB — is what the tests below parse.
pub const BraveAnswer = union(enum) {
    /// The numbered list, rendered exactly like the free chain's. Non-empty.
    results: []const u8,
    /// Parsed fine and there was nothing there: an answer from a real index,
    /// not a failure, and it must not be reported as one.
    empty: void,
    /// Not a body this build can act on: not JSON, an `{"error": …}` envelope,
    /// or a shape without `web.results`. The server's own words when it had any —
    /// "SUBSCRIPTION_TOKEN_INVALID: The provided subscription token is invalid."
    /// is what the user needs to read, and "HTTP 422" alone says nothing.
    unusable: ?[]const u8,
};

pub fn braveResults(arena: std.mem.Allocator, body: []const u8, max: usize) BraveAnswer {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return .{ .unusable = null }; // an HTML challenge page, a proxy error, a truncated body
    if (parsed.value != .object) return .{ .unusable = null };
    const root = parsed.value.object;

    if (root.get("error")) |e| {
        const code = strField(e, "code");
        const detail = strField(e, "detail");
        var msg: ?[]const u8 = null;
        if (code != null and detail != null) {
            msg = std.fmt.allocPrint(arena, "{s}: {s}", .{ code.?, detail.? }) catch null;
        } else if (detail != null) {
            msg = detail;
        } else if (code != null) {
            msg = code;
        }
        return .{ .unusable = msg orelse "the server sent an error envelope without a message" };
    }

    const webv = root.get("web") orelse return .{ .unusable = "the answer has no `web` field this build knows" };
    if (webv != .object) return .{ .unusable = "the answer's `web` field is not an object" };
    const arrv = webv.object.get("results") orelse return .{ .unusable = "the answer has no `web.results` this build knows" };
    if (arrv != .array) return .{ .unusable = "`web.results` is not an array" };
    if (arrv.array.items.len == 0) return .{ .empty = {} };

    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (arrv.array.items) |item| {
        if (n >= max) break;
        if (item != .object) continue;
        const title = strField(item, "title") orelse continue;
        const url = strField(item, "url") orelse continue;
        const desc = strField(item, "description"); // `str | None` in Brave's own model
        if (url.len == 0) continue;
        const t = cleanText(arena, title);
        if (t.len == 0) continue;
        n += 1;
        out.print(arena, "{d}. {s}\n   {s}\n", .{ n, t, url }) catch return .{ .unusable = "out of memory rendering the results" };
        if (desc) |d| {
            // `<strong>` highlight marks and `&quot;`/`&#x27;` entities: the same
            // `cleanText` the DuckDuckGo list goes through, so both engines render
            // the same list and the model never has to know which one answered.
            const c = cleanText(arena, d);
            if (c.len > 0) out.print(arena, "   {s}\n", .{c[0..@min(c.len, 400)]}) catch {};
        }
        out.append(arena, '\n') catch {};
    }
    if (n == 0) return .{ .empty = {} };
    return .{ .results = out.items };
}

/// A string field of a JSON object value, or null when it is absent or not a string.
fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .string) return null;
    return f.string;
}

// ── tests ─────────────────────────────────────────────────────

test "htmlToText removes script, style and tags" {
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

test "htmlToText: block breaks leave no gaps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<li>one</li><li>two</li><br><p>three</p>");
    // Neither loose spaces next to the tags nor 5 breaks in a row.
    try std.testing.expectEqualStrings("one\ntwo\n\nthree", text);
}

test "htmlToText decodes entities, including the numeric ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<p>a &lt; b &#39;c&#39; caf&eacute;</p>");
    try std.testing.expectEqualStrings("a < b 'c' café", text);
}

test "htmlToText invents no text out of a lone &" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<p>Tom & Jerry <3</p>");
    try std.testing.expectEqualStrings("Tom & Jerry <3", text);
}

test "htmlToText: an empty <head></head> leaves no closing tag in the text" {
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

test "searchResults pulls out title, URL and snippet" {
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

test "searchResults with no results returns empty (no garbage text)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = searchResults(arena_state.allocator(), "<html><body>no results here</body></html>", 8);
    try std.testing.expectEqualStrings("", out);
}

// ── search result parsing ──────────────────────────────────────

const search_html_fixture =
    \\<div class="result results_links results_links_deep web-result">
    \\  <h2 class="result__title"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example%2Fone">One &amp; only</a></h2>
    \\  <a class="result__snippet" href="#">The snippet of the FIRST result.</a>
    \\</div>
    \\<div class="result results_links results_links_deep web-result">
    \\  <h2 class="result__title"><a class="result__a" href="https://b.example/two">Two</a></h2>
    \\  <a class="result__snippet" href="#">The snippet of the SECOND result.</a>
    \\</div>
;

test "searchResults: the snippet belongs to the result above it" {
    // The regression: the snippet was searched for from the end of the title to
    // the END OF THE DOCUMENT, so a result without a snippet of its own got the
    // next one's, and the model read a description that had nothing to do with the
    // title above it.
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const out = searchResults(a.allocator(), search_html_fixture, 8);
    try std.testing.expect(std.mem.indexOf(u8, out, "One & only") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "snippet of the FIRST") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "snippet of the SECOND") != null);
    // And the URL of the redirect wrapper is unwrapped: `//duckduckgo.com/l/?uddg=…`
    try std.testing.expect(std.mem.indexOf(u8, out, "https://a.example/one") != null);
    // The `&amp;` is a real entity in the title, not text the model should read.
    try std.testing.expect(std.mem.indexOf(u8, out, "One & only") != null);
}

const search_html_no_snippet_first =
    \\<a class="result__a" href="https://a.example/one">One</a>
    \\<a class="result__a" href="https://b.example/two">Two</a>
    \\<a class="result__snippet" href="#">ONLY the second result has one.</a>
;

test "searchResults: a result with no snippet does NOT borrow the next one's" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const out = searchResults(a.allocator(), search_html_no_snippet_first, 8);
    // The snippet is only inside the second result's block, so only the second
    // entry gets it.
    const first = out[0 .. std.mem.indexOf(u8, out, "2. ") orelse out.len];
    try std.testing.expect(std.mem.indexOf(u8, first, "ONLY the second") == null);
    const rest = out[std.mem.indexOf(u8, out, "2. ") orelse 0 ..];
    try std.testing.expect(std.mem.indexOf(u8, rest, "ONLY the second") != null);
}

test "searchResults: the same URL twice is one result" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const dup =
        \\<a class="result__a" href="https://same.example/x">Same</a>
        \\<a class="result__a" href="https://same.example/x">Same again</a>
        \\<a class="result__a" href="https://other.example/y">Other</a>
    ;
    const out = searchResults(a.allocator(), dup, 8);
    // ONE line with that URL, not two: it appears once per result kept.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "https://same.example/x"));
    try std.testing.expect(std.mem.indexOf(u8, out, "2. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3. ") == null);
}

test "liteSearchResults reads the OTHER endpoint's classes" {
    // `lite/` is a different page: different class names. Without this the tool
    // has NO results whenever `html/` changes its layout, for a query the engine
    // answered perfectly well.
    const lite =
        \\<a class="result-link" href="https://lite.example/one">Lite one</a>
        \\<td class="result-snippet">A lite snippet.</td>
        \\<a class="result-link" href="https://lite.example/two">Lite two</a>
        \\<td class="result-snippet">Another lite snippet.</td>
    ;
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const out = liteSearchResults(a.allocator(), lite, 8);
    try std.testing.expect(std.mem.indexOf(u8, out, "Lite one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://lite.example/one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A lite snippet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Lite two") != null);
}

test "searchResults: nothing to parse is an empty string, never a half result" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("", searchResults(a.allocator(), "<html>changed</html>", 8));
    try std.testing.expectEqualStrings("", liteSearchResults(a.allocator(), "<html>changed</html>", 8));
}

test "urlHost takes the authority, the port, the brackets and the userinfo off" {
    try std.testing.expectEqualStrings("example.com", urlHost("https://example.com/a/b?c=1"));
    try std.testing.expectEqualStrings("example.com", urlHost("https://example.com:8443/x"));
    try std.testing.expectEqualStrings("example.com", urlHost("https://user:pw@example.com/x"));
    // NOT lowercased: there is no buffer to lower into that is ours (see `hostEql`).
    try std.testing.expectEqualStrings("EXAMPLE.com", urlHost("https://EXAMPLE.com/x"));
    try std.testing.expectEqualStrings("::1", urlHost("http://[::1]:8080/x"));
    try std.testing.expectEqualStrings("example.com", urlHost("https://example.com"));
    // Not a URL at all: an EMPTY host, not the whole string. A host that comes back as
    // the URL itself would be compared against "169.254" and never match anything.
    try std.testing.expectEqualStrings("", urlHost("not a url"));
}

test "the credential endpoints are refused, and a public host is not" {
    // The four real ones, plus the shape they share.
    for ([_][]const u8{
        "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
        "https://169.254.169.254/computeMetadata/v1/",
        "http://169.254.1.1/x",
        "http://metadata.google.internal/computeMetadata/v1/",
        "http://[fd00:ec2::254]/latest/",
    }) |u| {
        try std.testing.expect(isCredentialEndpoint(u));
    }
    // What must NOT be caught: a normal host, and one that merely MENTIONS the numbers.
    for ([_][]const u8{
        "https://example.com/",
        "https://169.254.169.254.example.com/",
        "https://example.com/?ip=169.254.169.254",
        "https://169.example.com/",
    }) |u| {
        try std.testing.expect(!isCredentialEndpoint(u));
    }
}

test "loopback is private but is NOT a credential endpoint" {
    // The distinction is the whole design: the metadata block has no legitimate
    // exception, and a rule that blocked your own dev server would be switched off
    // entirely, taking the metadata block with it.
    try std.testing.expect(isPrivateHost("http://127.0.0.1:3000/"));
    try std.testing.expect(isPrivateHost("http://localhost:8080/api"));
    try std.testing.expect(isPrivateHost("http://app.localhost/"));
    try std.testing.expect(isPrivateHost("http://10.1.2.3/"));
    try std.testing.expect(isPrivateHost("http://192.168.1.1/"));
    try std.testing.expect(isPrivateHost("http://172.16.0.1/"));
    try std.testing.expect(isPrivateHost("http://172.31.255.1/"));
    try std.testing.expect(!isPrivateHost("http://172.32.0.1/"));
    try std.testing.expect(!isPrivateHost("https://example.com/"));

    try std.testing.expect(!isCredentialEndpoint("http://127.0.0.1:3000/"));
    try std.testing.expect(!isCredentialEndpoint("http://localhost:8080/"));
    try std.testing.expect(!isCredentialEndpoint("http://192.168.1.1/"));
}

test "excerpt: a page that fits is the text itself, verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("hello world", excerpt(arena, "hello world", 0, 100));
}

test "excerpt: the truncation note names the exact offset to continue" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "line one\nline two\nline three\n"; // 29 bytes
    const got = excerpt(arena, text, 0, 10);
    // Cut at the line boundary: 10 bytes would end mid-word ("line o|ne" would
    // actually land inside "line two"), so the note's number is the byte the
    // page really stopped at — 8, right after "line one".
    try std.testing.expect(std.mem.startsWith(u8, got, "line one"));
    try std.testing.expect(std.mem.indexOf(u8, got, "truncated at 8 of 29 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "pass offset=8 to continue") != null);
    // The old note promised "a deeper request", a parameter that did not exist.
    try std.testing.expect(std.mem.indexOf(u8, got, "deeper request") == null);
}

test "excerpt: a mid-document page says where it starts and continues without a gap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "line one\nline two\nline three\n";
    const got = excerpt(arena, text, 8, 100);
    // A page starting mid-document must not read like a document that begins
    // mid-sentence.
    try std.testing.expect(std.mem.indexOf(u8, got, "[continuing at byte 8 of 29]") != null);
    // Byte 8 is the newline that closed "line one": nothing lost, nothing repeated.
    try std.testing.expect(std.mem.indexOf(u8, got, "\nline two\nline three\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "line one") == null);
}

test "excerpt: an offset past the end says so instead of panicking" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = excerpt(arena, "abc", 99, 10);
    try std.testing.expect(std.mem.indexOf(u8, got, "offset 99 is past the end") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "3 bytes long") != null);
    // And what to do about it, or the model retries the same number.
    try std.testing.expect(std.mem.indexOf(u8, got, "offset 0") != null);
}

test "excerpt: a page with no line breaks is hard-cut, still at a whole offset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = excerpt(arena, "0123456789abcdef", 0, 8);
    try std.testing.expect(std.mem.startsWith(u8, got, "01234567"));
    try std.testing.expect(std.mem.indexOf(u8, got, "pass offset=8 to continue") != null);
}

// The Brave fixtures below are TRIMMED FROM A REAL RESPONSE: the reference
// client's `mock_data/web.json` (56 KB, 20 results), fetched 2026-10-08. The
// shape was verified three ways before a line of this was written — Brave's
// official agent skill (`web.results[]`), their reference Python client's
// models (`title: str`, `url: str`, `description: str | None`), and that
// response itself.

test "braveResults: the real shape renders exactly like the free chain's list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"type":"search","query":"hello world","web":{"type":"search","family_friendly":true,"results":[
        \\{"title":"\"Hello, World!\" program - Wikipedia",
        \\ "url":"https://en.wikipedia.org/wiki/%22Hello,_World!%22_program",
        \\ "description":"A &quot;Hello, World!&quot; program is <strong>usually a simple computer program that emits a message.</strong> It illustrates a language&#x27;s basic syntax.",
        \\ "page_age":"2024-12-27T15:49:55","profile":{"name":"Wikipedia"},"is_live":false,
        \\ "deep_results":{"buttons":[{"type":"button_result","title":"History","url":"https://example.com/h"}]}},
        \\{"title":"Hello World Computer Science","url":"https://www.helloworldcs.org/",
        \\ "description":null,"thumbnail":{"src":"https://cdn.example.com/x.png"}}
        \\]}}
    ;
    const got = braveResults(arena, body, 8);
    try std.testing.expect(got == .results);
    const out = got.results;

    // The same numbered list the DuckDuckGo chain produces: the model must not
    // have to know which engine answered.
    try std.testing.expect(std.mem.indexOf(u8, out, "1. \"Hello, World!\" program - Wikipedia\n   https://en.wikipedia.org/wiki/%22Hello,_World!%22_program") != null);
    // `<strong>` marks stripped and the entities decoded — the two things the
    // live description is full of.
    try std.testing.expect(std.mem.indexOf(u8, out, "<strong>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "&quot;") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "usually a simple computer program") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "language's basic syntax") != null);
    // `description: null` loses the snippet line, not the result.
    try std.testing.expect(std.mem.indexOf(u8, out, "2. Hello World Computer Science\n   https://www.helloworldcs.org/") != null);
    // Exactly two URLs: no phantom entries out of the ignored fields.
    var urls: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "   https://")) urls += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), urls);
}

test "braveResults: zero results is an answer from a real index, not a failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = braveResults(arena, "{\"type\":\"search\",\"web\":{\"type\":\"search\",\"family_friendly\":true,\"results\":[]}}", 8);
    try std.testing.expect(got == .empty);
}

test "braveResults: the error envelope keeps the server's own words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The real 422 body, captured from api.search.brave.com on 2026-10-08.
    const body =
        \\{"error":{"code":"SUBSCRIPTION_TOKEN_INVALID","detail":"The provided subscription token is invalid.","meta":{"component":"authentication"},"status":422},"type":"ErrorResponse"}
    ;
    const got = braveResults(arena, body, 8);
    try std.testing.expect(got == .unusable);
    const msg = got.unusable orelse return error.ExpectedMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "SUBSCRIPTION_TOKEN_INVALID") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "The provided subscription token is invalid.") != null);
}

test "braveResults: an HTML challenge page is unusable, never results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = braveResults(arena, "<!doctype html><html><body>Just a moment…</body></html>", 8);
    try std.testing.expect(got == .unusable);
    try std.testing.expect(got.unusable == null);
    // No message means "this is not JSON", which is all we can honestly say.
}

test "braveResults: a shape without web.results says which field is missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = braveResults(arena, "{\"type\":\"search\",\"web\":{\"type\":\"search\"}}", 8);
    try std.testing.expect(got == .unusable);
    const msg = got.unusable orelse return error.ExpectedMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "web.results") != null);
}

test "braveResults: max caps the list at whole results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"web":{"results":[
        \\{"title":"one","url":"https://a.example/","description":"d1"},
        \\{"title":"two","url":"https://b.example/","description":"d2"},
        \\{"title":"three","url":"https://c.example/","description":"d3"}]}}
    ;
    const got = braveResults(arena, body, 2);
    try std.testing.expect(got == .results);
    try std.testing.expect(std.mem.indexOf(u8, got.results, "2. two") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.results, "three") == null);
    try std.testing.expect(std.mem.indexOf(u8, got.results, "3.") == null);
}
