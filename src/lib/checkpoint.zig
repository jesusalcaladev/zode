const std = @import("std");

/// Photos of file contents, per TURN, so that they can be undone.
///
/// ## Why the conversation is not redone
///
/// `/undo` undoes **files**, not messages. The session is an append-only JSONL
/// (see `session.zig`) and rewriting it halfway through a turn is the kind of
/// thing nobody can explain afterwards: the replay, the diff and the context all
/// go away.
///
/// ## Why a fixed-size array
///
/// It lives in the `Model` and `/undo` reads it from the UI thread. An
/// `ArrayList` on the heap forces you to manage the lifetime of every snapshot;
/// with fixed buffers, "undo" is copying from one place to another and freeing
/// nothing else. The price is a cap, and the caps are below on purpose: they are
/// the memory limit of a function that would otherwise swallow a whole repo.
pub const max_checkpoints = 8;
pub const max_files = 24;
pub const path_max = 256;
pub const file_max = 256 * 1024;
/// Cap per checkpoint. A `write` of a 3 MB file cannot be undone (and there is
/// no point in it), but the rest of the turn can.
pub const snapshot_max = 1024 * 1024;
pub const label_max = 60;

pub const FileSnap = struct {
    path: [path_max]u8 = undefined,
    path_len: u8 = 0,
    data: []u8 = &.{},
    /// If the file did NOT exist before, undoing means DELETING it. And "did not
    /// exist" has to be told apart from "could not be read": in the second case
    /// the file is left alone, because deleting it would be worse than not
    /// undoing.
    existed: bool = true,
    /// The content did not fit (or the checkpoint cap was passed): this file
    /// cannot be undone, but the rest of the turn can.
    truncated: bool = false,

    pub fn pathOf(self: *const FileSnap) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const Checkpoint = struct {
    label: [label_max]u8 = undefined,
    label_len: u8 = 0,
    files: [max_files]FileSnap = undefined,
    len: u8 = 0,
    /// Bytes already spent in this checkpoint (for the `snapshot_max` cap).
    bytes: usize = 0,
    /// The budget was passed: some files will not be undoable and the user has
    /// to be told.
    over_budget: bool = false,

    pub fn labelOf(self: *const Checkpoint) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn fileCount(self: *const Checkpoint) u8 {
        return self.len;
    }

    /// How many can really be undone (the truncated ones cannot).
    pub fn undoable(self: *const Checkpoint) u8 {
        var n: u8 = 0;
        for (self.files[0..self.len]) |f| {
            if (!f.truncated) n += 1;
        }
        return n;
    }

    pub fn deinit(self: *Checkpoint, gpa: std.mem.Allocator) void {
        // Only the first `len`: the rest of the array is `undefined`, and
        // freeing that is a crash.
        for (self.files[0..self.len]) |f| {
            gpa.free(f.data);
        }
        self.len = 0;
        self.bytes = 0;
    }

    /// Adds the photo of a file. Reports what was stored, so the caller can warn.
    ///
    /// `content` is caller memory (the turn arena): it is COPIED, because that
    /// arena dies when the turn ends and the photo has to outlive it.
    pub const Added = enum { ok, no_room, too_big, dup };

    pub fn addFile(
        self: *Checkpoint,
        gpa: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
        existed: bool,
    ) Added {
        if (self.len >= max_files) return .no_room;
        if (path.len == 0 or path.len >= path_max) return .no_room;

        // The same file twice in the same turn: only the INITIAL photo matters.
        // If the LAST one were stored, undo would leave the content from after
        // the first edit, which is not the state from before the turn.
        for (self.files[0..self.len]) |f| {
            if (std.mem.eql(u8, f.pathOf(), path)) return .dup;
        }

        var f = FileSnap{ .existed = existed, .data = &.{} };
        @memcpy(f.path[0..path.len], path);
        f.path_len = @intCast(path.len);

        if (!existed) {
            // It did not exist: the photo is "delete it when you undo", 0 bytes.
            self.files[self.len] = f;
            self.len += 1;
            return .ok;
        }

        if (content.len > file_max or self.bytes + content.len > snapshot_max) {
            f.truncated = true;
            self.over_budget = true;
            self.files[self.len] = f;
            self.len += 1;
            return .too_big;
        }

        const copy = gpa.dupe(u8, content) catch {
            f.truncated = true;
            self.over_budget = true;
            self.files[self.len] = f;
            self.len += 1;
            return .too_big;
        };
        f.data = copy;
        self.bytes += copy.len;
        self.files[self.len] = f;
        self.len += 1;
        return .ok;
    }

    /// One line for the history: what is going to be undone and from which turn.
    ///
    /// In caller memory (`arena`) because it goes to the history, which
    /// outlives the turn. A `bufPrint` into a local stack buffer would NOT do:
    /// that dies when the function returns and the history paints garbage (the
    /// classic "pointer to local").
    pub fn summary(self: *const Checkpoint, arena: std.mem.Allocator) []const u8 {
        const n = self.undoable();
        if (self.len == 0) return "nothing to undo: the last turn changed no files";
        if (n == 0) {
            return std.fmt.allocPrint(arena, "nothing to undo: {d} file(s) were too big to restore", .{
                self.len,
            }) catch "nothing to undo";
        }
        if (n == self.len) {
            return std.fmt.allocPrint(arena, "undo: {d} file{s} to undo, from: {s}", .{
                n,
                if (n == 1) "" else "s",
                self.labelOf(),
            }) catch "undo: done";
        }
        return std.fmt.allocPrint(
            arena,
            "undo: {d} of {d} files, from: {s} ({d} too big to restore)",
            .{ n, self.len, self.labelOf(), self.len - n },
        ) catch "undo: done";
    }
};

/// The stack of checkpoints.
///
/// A ring, not a growing list: the goal is "undo the last turn", and with 8
/// turns of history you can already go to git. Growing without a cap is how
/// memory swallows a whole repo.
///
/// `items[0]` is ALWAYS the most recent. That it is an index and not an offset
/// is what makes `begin` a three-line shift.
pub const Stack = struct {
    items: [max_checkpoints]Checkpoint = undefined,
    len: u8 = 0,
    /// Where the photos' memory comes from. The stack carries it so that
    /// `begin`/`deinit` do not have to drag an allocator through their
    /// signature.
    gpa: std.mem.Allocator = undefined,

    pub fn init(gpa: std.mem.Allocator) Stack {
        return .{ .gpa = gpa };
    }

    pub fn isEmpty(self: *const Stack) bool {
        return self.len == 0;
    }

    /// The most recent one, or null. `*Checkpoint` and not `*const` because
    /// `/undo` CONSUMES the checkpoint (it deletes it when undoing) and a
    /// `*const` does not allow that.
    pub fn last(self: *Stack) ?*Checkpoint {
        if (self.len == 0) return null;
        return &self.items[0];
    }

    /// Starts the checkpoint of a turn: the previous one becomes the second.
    pub fn begin(self: *Stack, label: []const u8) void {
        if (self.len == max_checkpoints) {
            // Full: the oldest one is dropped. And it is freed BEFORE being overwritten,
            // or the memory of its photos goes away without a word (a silent
            // leak).
            self.items[max_checkpoints - 1].deinit(self.gpa);
        } else {
            self.len += 1;
        }
        // Shift backwards: what was the most recent becomes the second, and the slot
        // at the end is the one that was just written.
        var i: usize = self.len - 1;
        while (i > 0) : (i -= 1) {
            self.items[i] = self.items[i - 1];
        }
        var cp = Checkpoint{};
        const n = @min(label.len, label_max);
        @memcpy(cp.label[0..n], label[0..n]);
        cp.label_len = @intCast(n);
        self.items[0] = cp;
    }

    /// Drops ALL checkpoints (session change, `/new`).
    pub fn clear(self: *Stack) void {
        for (self.items[0..self.len]) |*cp| cp.deinit(self.gpa);
        self.len = 0;
    }

    pub fn deinit(self: *Stack) void {
        self.clear();
    }
};

// ── tests ─────────────────────────────────────────────────────

test "a snapshot is copied, not referenced: the turn arena dies" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();

    st.begin("crear el fichero");
    // `src` is stack memory: if `addFile` stored it as-is, undo would write
    // garbage.
    var src = [_]u8{ 'h', 'o', 'l', 'a' };
    try std.testing.expectEqual(Checkpoint.Added.ok, st.items[0].addFile(gpa, "a.txt", &src, true));
    src[0] = 'X';
    try std.testing.expectEqualStrings("hola", st.items[0].files[0].data);
}

test "the same file twice in one turn: the INITIAL snapshot wins" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();
    st.begin("tres edits");

    _ = st.items[0].addFile(gpa, "a.txt", "v1", true);
    try std.testing.expectEqual(Checkpoint.Added.dup, st.items[0].addFile(gpa, "a.txt", "v2", true));
    try std.testing.expectEqual(@as(u8, 1), st.items[0].len);
    // If the last one were stored, undo would leave "v2", which is not the state
    // from before the turn.
    try std.testing.expectEqualStrings("v1", st.items[0].files[0].data);
}

test "a file that did not exist is undone by DELETING it" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();
    st.begin("crear");

    try std.testing.expectEqual(Checkpoint.Added.ok, st.items[0].addFile(gpa, "nuevo.txt", "", false));
    try std.testing.expect(!st.items[0].files[0].existed);
    // And it counts as undoable: deleting is undoing.
    try std.testing.expectEqual(@as(u8, 1), st.items[0].undoable());
}

test "an oversized file is flagged, it does not swallow the memory" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();
    st.begin("reescribir un fichero enorme");

    const big = [_]u8{'x'} ** (file_max + 1);
    try std.testing.expectEqual(Checkpoint.Added.too_big, st.items[0].addFile(gpa, "enorme.txt", &big, true));
    try std.testing.expect(st.items[0].files[0].truncated);
    try std.testing.expectEqual(@as(u8, 0), st.items[0].undoable());
    try std.testing.expect(st.items[0].over_budget);
    // And the rest of the turn is still undoable.
    _ = st.items[0].addFile(gpa, "otro.txt", "peque", true);
    try std.testing.expectEqual(@as(u8, 1), st.items[0].undoable());
}

test "the file cap truncates, and the byte cap warns" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();
    st.begin("muchos ficheros");

    const chunk = [_]u8{'y'} ** (200 * 1024);
    var i: u8 = 0;
    while (i < max_files) : (i += 1) {
        var name: [32]u8 = undefined;
        const nm = std.fmt.bufPrint(&name, "f{d}.txt", .{i}) catch unreachable;
        _ = st.items[0].addFile(gpa, nm, &chunk, true);
    }
    // Not one more file: the array is fixed.
    try std.testing.expectEqual(Checkpoint.Added.no_room, st.items[0].addFile(gpa, "uno-mas.txt", "x", true));
    try std.testing.expectEqual(@as(u8, max_files), st.items[0].len);
    // The ones that fit in the byte budget are whole; the rest are flagged, and
    // the checkpoint says so.
    try std.testing.expect(st.items[0].undoable() > 0);
    try std.testing.expect(st.items[0].over_budget);
    // The per-checkpoint budget is what rules: 24 x 200 KB do not fit in 1 MB, so
    // the last ones have to be truncated one way or another.
    try std.testing.expect(st.items[0].undoable() < max_files);
}

test "the ring: the last one is the most recent, and when full the old one is dropped" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();

    var n: usize = 0;
    while (n < max_checkpoints + 2) : (n += 1) {
        var buf: [16]u8 = undefined;
        const lbl = std.fmt.bufPrint(&buf, "turno {d}", .{n}) catch unreachable;
        st.begin(lbl);
        _ = st.items[0].addFile(gpa, "a.txt", "contenido", true);
    }
    // The cap rules: it does not grow.
    try std.testing.expectEqual(@as(u8, max_checkpoints), st.len);
    // And the most recent is the new turn, not the old one.
    try std.testing.expect(std.mem.indexOf(u8, st.last().?.labelOf(), "turno 9") != null);
    // And the LAST of the ring is the oldest one kept (turn 2).
    try std.testing.expect(std.mem.indexOf(u8, st.items[st.len - 1].labelOf(), "turno 2") != null);
    // That the dropped one freed its photos is watched by the testing allocator:
    // if it had been overwritten without freeing, a "memory address leaked"
    // would pop at the end of the test.
}

test "summary: how many files, from which turn, and what cannot be undone" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var st = Stack.init(std.testing.allocator);
    defer st.deinit();

    // Nothing: the message has to say so, not fail silently.
    var vacio = Checkpoint{};
    try std.testing.expectEqualStrings(
        "nothing to undo: the last turn changed no files",
        vacio.summary(arena),
    );

    st.begin("crear el fichero");
    _ = st.items[0].addFile(std.testing.allocator, "a.txt", "hola", true);
    const s = st.last().?.summary(arena);
    try std.testing.expect(std.mem.indexOf(u8, s, "undo: 1 file to undo") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "crear el fichero") != null);

    // With a file that does not fit, the summary says so instead of promising an
    // undo that would leave the repo half-done.
    const big = [_]u8{'x'} ** (file_max + 1);
    _ = st.items[0].addFile(std.testing.allocator, "enorme.txt", &big, true);
    const s2 = st.last().?.summary(arena);
    try std.testing.expect(std.mem.indexOf(u8, s2, "undo: 1 of 2 files") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "1 too big") != null);
}

test "clear drops the checkpoints (session change) without leaking memory" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    st.begin("a");
    _ = st.items[0].addFile(gpa, "a.txt", "hola", true);
    st.begin("b");
    _ = st.items[0].addFile(gpa, "b.txt", "adios", true);
    try std.testing.expectEqual(@as(u8, 2), st.len);
    st.clear();
    try std.testing.expect(st.isEmpty());
    try std.testing.expect(st.last() == null);
    // And `last()` on an empty stack is not a crash: it is null.
    st.deinit();
}
