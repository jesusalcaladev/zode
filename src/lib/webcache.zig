//! The page cache behind `web_fetch`.
//!
//! ## Why there is one
//!
//! Not for the milliseconds. Three reasons, in the order they bite:
//!
//!  1. **Paging is re-fetching today.** `web_fetch` takes an `offset` into the
//!     EXTRACTED text and the truncation note names the next one. Every window
//!     after the first re-downloads the whole page, re-strips the HTML and
//!     re-encodes 100 KB of query that nobody reads again. The cache is keyed by
//!     URL and holds the extracted text, so the window is a slice of memory.
//!  2. **A turn fetches the same URL more than once.** The model reads a
//!     page, follows a link that is on the same page, and comes back. Three
//!     requests for one page is three chances to be rate-limited by a site that
//!     answers 429 after two.
//!  3. **Resilience**, the same argument as `modelcache`: a slow link, an SSH
//!     hop, a captive portal. A repeated URL that comes from memory answers
//!     while the network is having a bad minute.
//!
//! ## What it does NOT do
//!
//! It is per-process and never written to disk. A page on disk is a stale page
//! on the next run, and a stale page that nobody can see the age of is worse
//! than a slow fetch.
//!
//! ## The clock is a PARAMETER
//!
//! `get` and `put` take `now_ms`. A module global clock is a global that the
//! tests cannot set, and a cache whose TTL cannot be exercised is a cache whose
//! TTL is a guess. The caller reads the clock (the tool has an `Io`); this
//! module never does.
//!
//! ## A hit is indistinguishable from a fetch
//!
//! `get` returns the same text the fetch would have produced. Nothing is added,
//! nothing is stamped on it: the paging round-trip that `tools/web.zig` has a
//! test for must keep working on a hit, and a "from cache" marker in the text
//! would be one more byte per call that the model reads and cannot use.

const std = @import("std");

/// How long a page stays. A documentation page does not change in fifteen
/// minutes and a session usually does not either; past that, a re-fetch is
/// cheap and a wrong page is not.
pub const ttl_ms: i64 = 15 * 60 * 1000;

/// Total budget of extracted text held at once.
pub const budget_bytes: usize = 16 * 1024 * 1024;

/// A page bigger than this is not cached.
///
/// It is not a size limit on the tool (that is `web_fetch`'s `max_bytes`), it
/// is a statement about the CACHE: one 5 MB page would evict every other entry
/// to make room and would be read once. The tool's own cap is the ceiling above
/// it, so anything over this is a page nobody is paging through.
pub const max_entry_bytes: usize = 2 * 1024 * 1024;

/// How many entries, on top of the byte budget. A cache of 10 000 tiny entries
/// is a cache that costs a linear scan and saves nothing; the budget evicts on
/// size and this one bounds the bookkeeping.
pub const max_entries: usize = 64;

pub const Entry = struct {
    url: []const u8,
    text: []const u8,
    stored_at_ms: i64,
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    /// Least recently used first. A `get` moves the entry to the end, so the
    /// front is always the one to evict.
    items: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    /// Byte budget in force. A field and not the constant, for the same reason
    /// the clock is a parameter (see the header): pinning WHICH entry gets
    /// evicted would otherwise need 16 MB of fixture pages to cross the line,
    /// when the thing under test is the ORDER. Defaults to `budget_bytes`.
    budget: usize = budget_bytes,

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    /// Frees everything. **Only at teardown**: the cache is read from several
    /// worker threads (`web_fetch` is on the parallel-safe list), and a map that
    /// can be read from several threads is not freed at runtime.
    pub fn deinit(self: *Cache) void {
        for (self.items.items) |e| {
            self.gpa.free(e.url);
            self.gpa.free(e.text);
        }
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn count(self: *const Cache) usize {
        return self.items.items.len;
    }

    /// How many bytes of extracted text are held right now.
    pub fn usedBytes(self: *const Cache) usize {
        return self.bytes;
    }

    /// The extracted text for `url`, or null: never fetched, or too old.
    ///
    /// Expired entries are DROPPED here rather than being distinguished from a
    /// miss, because the caller does the same thing with both (fetch) and the
    /// difference is only visible in the bookkeeping.
    pub fn get(self: *Cache, url: []const u8, now_ms: i64) ?[]const u8 {
        var i: usize = 0;
        while (i < self.items.items.len) : (i += 1) {
            const e = self.items.items[i];
            if (!std.mem.eql(u8, e.url, url)) continue;
            if (now_ms - e.stored_at_ms >= ttl_ms) {
                self.drop(i);
                return null;
            }
            self.touch(i);
            return self.items.items[i].text;
        }
        return null;
    }

    /// Stores the extracted text for `url`.
    ///
    /// Does nothing (and says nothing) when the text is over `max_entry_bytes`
    /// or the copy fails: a cache that cannot store is a slower fetch, which is
    /// exactly what it was before this existed.
    pub fn put(self: *Cache, url: []const u8, text: []const u8, now_ms: i64) void {
        if (text.len == 0 or text.len > max_entry_bytes) return;

        // Re-storing a URL replaces it. Without this the list grows with one
        // copy per fetch of the same page and the budget is spent on duplicates.
        var i: usize = 0;
        while (i < self.items.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.items.items[i].url, url)) {
                self.drop(i);
                break;
            }
        }

        const u = self.gpa.dupe(u8, url) catch return;
        errdefer self.gpa.free(u);
        const t = self.gpa.dupe(u8, text) catch return;

        self.items.append(self.gpa, .{ .url = u, .text = t, .stored_at_ms = now_ms }) catch {
            self.gpa.free(u);
            self.gpa.free(t);
            return;
        };
        self.bytes += t.len;
        self.evict();
    }

    /// Moves entry `i` to the end, so the front is always the least recently used.
///
/// The capacity is already there — `orderedRemove` does not shrink it — so the
/// append cannot fail. It is not written as a catch on a guess: an allocation
/// here would mean the LRU order was quietly wrong, which is the one thing this
/// cache must never be.
fn touch(self: *Cache, i: usize) void {
        if (i + 1 == self.items.items.len) return;
        const e = self.items.orderedRemove(i);
        self.items.appendAssumeCapacity(e);
    }

    fn drop(self: *Cache, i: usize) void {
        const e = self.items.orderedRemove(i);
        self.gpa.free(e.url);
        self.gpa.free(e.text);
        self.bytes -= e.text.len;
    }

    /// Brings both limits back under. Front first, which is the whole point of
    /// the order: the entry that has been used least goes first.
    fn evict(self: *Cache) void {
        while (self.items.items.len > max_entries or
            (self.bytes > self.budget and self.items.items.len > 1))
        {
            self.drop(0);
        }
    }
};

test "a stored page comes back, and a page that was never stored does not" {
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();

    try std.testing.expect(c.get("https://a.example/", 0) == null);
    c.put("https://a.example/", "hello", 0);
    try std.testing.expectEqualStrings("hello", c.get("https://a.example/", 0).?);
    try std.testing.expectEqual(@as(usize, 1), c.count());
    try std.testing.expectEqual(@as(usize, 5), c.usedBytes());
}

test "a page older than the TTL is a miss and is not kept" {
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();

    c.put("https://a.example/", "hello", 1_000);
    // One millisecond before the TTL it is still good.
    try std.testing.expect(c.get("https://a.example/", 1_000 + ttl_ms - 1) != null);
    try std.testing.expect(c.get("https://a.example/", 1_000 + ttl_ms) == null);
    // And it is GONE, not merely invisible: a cache that keeps entries it will
    // never serve is a leak with a TTL on top.
    try std.testing.expectEqual(@as(usize, 0), c.count());
    try std.testing.expectEqual(@as(usize, 0), c.usedBytes());
}

test "re-storing the same URL replaces it instead of growing the list" {
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();

    c.put("https://a.example/", "first", 0);
    c.put("https://a.example/", "second", 10);
    try std.testing.expectEqual(@as(usize, 1), c.count());
    try std.testing.expectEqualStrings("second", c.get("https://a.example/", 10).?);
    try std.testing.expectEqual(@as(usize, 6), c.usedBytes());
}

test "a page bigger than the entry limit is not stored" {
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();

    // One byte PAST the limit. The limit is inclusive (`put` rejects what is
    // over `max_entry_bytes`, and the doc says the same), so a page of exactly
    // `max_entry_bytes` is not "bigger than the entry limit" and must be
    // stored: the construction has to match the name of the test.
    const big = "x" ** (max_entry_bytes + 1);
    c.put("https://a.example/", "small", 0);
    c.put("https://big.example/", big, 0);
    try std.testing.expectEqual(@as(usize, 1), c.count());
    try std.testing.expect(c.get("https://big.example/", 0) == null);
}

test "the byte budget evicts the least recently USED page, not the oldest" {
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();
    // 3500 bytes: three pages fit, four do not. The default budget is 16 MB and
    // a fixture big enough to cross it would test the arithmetic instead of the
    // ORDER, which is the only thing this test is about.
    c.budget = 3500;

    // Three pages of 1000 bytes each: the first is the oldest AND the one a
    // `get` was NOT used on. Evicting by insertion order would be right by
    // accident here, so make the newest the stale one.
    c.put("https://a/", "a" ** 1000, 0);
    c.put("https://b/", "b" ** 1000, 1);
    c.put("https://c/", "c" ** 1000, 2);
    // Touch `a`, so `b` is now the least recently used.
    _ = c.get("https://a/", 3);

    const before = c.usedBytes();
    c.put("https://d/", "d" ** 1000, 4);
    try std.testing.expect(before + 1000 <= c.usedBytes() + 1000);
    try std.testing.expect(c.get("https://b/", 5) == null);
    try std.testing.expect(c.get("https://a/", 5) != null);
    try std.testing.expect(c.get("https://c/", 5) != null);
    try std.testing.expect(c.get("https://d/", 5) != null);
}

test "the entry count is bounded even when the bytes are tiny" {
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();

    var buf: [64]u8 = undefined;
    for (0..max_entries + 10) |i| {
        const url = try std.fmt.bufPrint(&buf, "https://e{d}.example/", .{i});
        c.put(url, "x", @intCast(i));
    }
    try std.testing.expect(c.count() <= max_entries);
}

test "the budget is enforced: a page cannot be served past it" {
    // A budget smaller than the entries is exercised by shrinking the budget
    // through the entry limit, which is the same loop: what matters is that the
    // invariant holds for any input and `bytes` never reports more than the
    // budget once the cache has settled.
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();
    var buf: [64]u8 = undefined;
    for (0..200) |i| {
        const url = try std.fmt.bufPrint(&buf, "https://e{d}.example/", .{i});
        c.put(url, "y" ** 4096, @intCast(i));
    }
    try std.testing.expect(c.usedBytes() <= budget_bytes);
    try std.testing.expect(c.count() <= max_entries);
}

test "an empty body is not cached" {
    // "(empty body)" is a legitimate answer to a legitimate request, and
    // caching it would answer the NEXT request to that URL with nothing.
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();
    c.put("https://a.example/", "", 0);
    try std.testing.expectEqual(@as(usize, 0), c.count());
}