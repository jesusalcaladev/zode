const std = @import("std");
const vaxis = @import("vaxis");
const styles = @import("styles.zig");
const config = @import("config.zig");

// ── scanner state BETWEEN lines ────────────────────────────────
//
// Without this, a trailing `\\` in Zig or an unclosed quote made the
// next line get painted ENTIRELY green: the scanner had no way of knowing it
// was still inside a string. It is the classic bug of
// line-by-line highlighters, and it shows badly in an `edit` of
// a file with multiline strings.
pub const StrStart = struct { end: usize, open: bool = false, quote: u8 = '"' };
	pub const Segment = struct {
		text: []const u8,
		style: vaxis.Style,
	};


/// Scanner helpers ──────────────────────────────────────────────

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn lineCommentAt(line: []const u8, at: usize, prefixes: []const []const u8) ?usize {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line[at..], p)) return p.len;
    }
    return null;
}

/// Returns the end index (exclusive) of the string that STARTS at `at`,
/// or null if no string starts there.
pub fn stringStart(line: []const u8, at: usize, cfg: config.Cfg) ?StrStart {
    if (line[at] != '"' and line[at] != '\'' and line[at] != '`') return null;
    if (line[at] == '`' and !cfg.template_literal) return null;
    // prefixes r"…" b'…' f"…": only if the previous char is part of a
    // short identifier-like prefix (python/rust); in practice it is enough
    // to accept it if the previous char is not another delimiter.
    if (cfg.string_prefixes and at > 0 and isIdentChar(line[at - 1])) {
        // could be the end of a regular identifier ("foo"x is not valid),
        // but accepting the string avoids false negatives with r"/b'/f".
        return scanString(line, at);
    }
    if (at > 0 and isIdentChar(line[at - 1]) and !cfg.string_prefixes) {
        // e.g.: 12"abc" or foo"bar": not treated as a string (JS allows it;
        // an acceptable false negative to keep the scanner simple).
        return null;
    }
    return scanString(line, at);
}

fn scanString(line: []const u8, open: usize) ?StrStart {
    const quote = line[open];
    var j = open + 1;
    while (j < line.len) : (j += 1) {
        if (line[j] == '\\' and j + 1 < line.len) {
            j += 1;
            continue;
        }
        if (line[j] == quote) return .{ .end = j + 1 };
    }
    // String not closed in the line: it is painted to the end AND remembered
    // (`open = true`) so the next line keeps being string.
    return .{ .end = line.len, .open = true, .quote = quote };
}

/// End index (exclusive) of the string that is still OPEN since `from`, or null
/// if it does not close in this line. `quote` is the delimiter.
pub fn findStrEnd(line: []const u8, from: usize, quote: u8) ?usize {
    var j = from;
    while (j < line.len) : (j += 1) {
        if (line[j] == '\\' and j + 1 < line.len) {
            j += 1;
            continue;
        }
        if (line[j] == quote) return j + 1;
    }
    return null;
}
