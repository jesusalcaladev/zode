//! Internal diagnostics for millimetre-level runtime control (Phase 37).
//!
//! Pure on purpose: reading `/proc` and computing deltas needs no TUI, no
//! allocator and no network — it is testable with injected text. The harness
//! owns the clock; this module only turns samples into an honest picture.
//!
//! What it answers:
//!   - How much memory is the process using RIGHT NOW (VmRSS, VmSize, VmPeak)?
//!   - Is it GROWING across samples (a leak), or flat (normal)?
//!   - Did the last turn / tool / subagent cost a measurable chunk?
//!
//! On Linux, `/proc/self/status` has `VmPeak`, `VmSize`, `VmRSS` in kB.
//! `/proc/self/statm` has resident pages and total pages. Both are parsed as
//! text so the tests can feed fixtures without touching the real process.

const std = @import("std");

pub const Sample = struct {
    /// Kilobytes, as reported by /proc (already parsed, no unit conversion).
    vm_peak_kb: usize = 0,
    vm_size_kb: usize = 0,
    vm_rss_kb: usize = 0,
    /// Monotonic sequence number assigned by the caller.
    seq: usize = 0,

    pub fn residentMiB(self: Sample) f64 {
        return @as(f64, @floatFromInt(self.vm_rss_kb)) / 1024.0;
    }
};

pub const max_samples: usize = 16;

/// A fixed ring of recent samples. No allocator, so it can live in the Model
/// and be read from the UI thread while the worker appends.
pub const Monitor = struct {
    samples: [max_samples]Sample = undefined,
    len: usize = 0,
    head: usize = 0,

    pub fn push(self: *Monitor, s: Sample) void {
        self.samples[self.head] = s;
        self.head = (self.head + 1) % max_samples;
        if (self.len < max_samples) self.len += 1;
    }

    pub fn at(self: *const Monitor, i: usize) ?Sample {
        if (i >= self.len) return null;
        const start = (self.head + max_samples - self.len) % max_samples;
        return self.samples[(start + i) % max_samples];
    }

    pub fn last(self: *const Monitor) ?Sample {
        if (self.len == 0) return null;
        return self.at(self.len - 1);
    }

    /// Growth between the oldest and newest samples, in kB. A sustained
    /// positive delta across many samples is the leak signal; a single jump
    /// is just a big allocation (an image, a model catalogue).
    pub fn growthKb(self: *const Monitor) isize {
        if (self.len < 2) return 0;
        const first = self.at(0).?.vm_rss_kb;
        const latest = self.last().?.vm_rss_kb;
        return @as(isize, @intCast(latest)) - @as(isize, @intCast(first));
    }

    /// True when RSS grew on every one of the last `n` samples — stronger
    /// evidence than a single delta, and the rule the pill uses.
    pub fn growingFor(self: *const Monitor, n: usize) bool {
        if (self.len < n or n < 2) return false;
        var prev = self.at(self.len - n).?.vm_rss_kb;
        var i: usize = self.len - n + 1;
        while (i < self.len) : (i += 1) {
            const cur = self.at(i).?.vm_rss_kb;
            if (cur <= prev) return false;
            prev = cur;
        }
        return true;
    }
};

/// Read the current process's memory from `/proc/self/status`.
///
/// procfs reports st_size == 0, so `readFileAlloc`/`allocRemaining` return an
/// EMPTY slice with no error. Read with `readSliceShort` over a fixed buffer —
/// the same shape `bgproc.procPgrp` uses. Returns `.{}` off Linux or on any
/// read failure: diagnostics must never take the app down.
pub fn sample(io: std.Io) Sample {
    if (@import("builtin").os.tag != .linux) return .{};
    var f = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{}) catch return .{};
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var r = f.reader(io, &buf);
    const n = r.interface.readSliceShort(&buf) catch return .{};
    return parseStatus(buf[0..n]);
}

/// Parse the relevant lines of /proc/self/status. Values are in kB.
pub fn parseStatus(text: []const u8) Sample {
    var s = Sample{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmPeak:")) s.vm_peak_kb = valueKb(line) orelse continue;
        if (std.mem.startsWith(u8, line, "VmSize:")) s.vm_size_kb = valueKb(line) orelse continue;
        if (std.mem.startsWith(u8, line, "VmRSS:")) s.vm_rss_kb = valueKb(line) orelse continue;
    }
    return s;
}

fn valueKb(line: []const u8) ?usize {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(usize, tok, 10) catch null;
}

/// A one-line summary for the activity strip / `/diag` panel.
pub fn formatLine(gpa: std.mem.Allocator, s: Sample, growth: isize) ![]const u8 {
    return std.fmt.allocPrint(gpa,
        "rss {d:.1} MiB · size {d:.1} MiB · peak {d:.1} MiB · Δ {s}{d} KiB",
        .{
            s.residentMiB(),
            @as(f64, @floatFromInt(s.vm_size_kb)) / 1024.0,
            @as(f64, @floatFromInt(s.vm_peak_kb)) / 1024.0,
            if (growth >= 0) "+" else "-",
            @abs(growth),
        },
    );
}

test "diag: parse /proc/self/status fields" {
    const text = "Name:\tzode\nVmPeak:\t123456 kB\nVmSize:\t120000 kB\nVmRSS:\t45678 kB\nThreads:\t5\n";
    const s = parseStatus(text);
    try std.testing.expectEqual(@as(usize, 123456), s.vm_peak_kb);
    try std.testing.expectEqual(@as(usize, 120000), s.vm_size_kb);
    try std.testing.expectEqual(@as(usize, 45678), s.vm_rss_kb);
}

test "diag: monitor ring, growth and sustained growth" {
    var m = Monitor{};
    for (0..4) |i| m.push(.{ .vm_rss_kb = 1000 + i * 100, .seq = i });
    try std.testing.expectEqual(@as(usize, 4), m.len);
    try std.testing.expectEqual(@as(isize, 300), m.growthKb());
    try std.testing.expect(m.growingFor(4));
    try std.testing.expect(!m.growingFor(5)); // not enough samples

    // A dip breaks the sustained-growth signal.
    m.push(.{ .vm_rss_kb = 1200, .seq = 4 });
    try std.testing.expect(!m.growingFor(5));
    try std.testing.expectEqual(@as(usize, 1200), m.last().?.vm_rss_kb);
}

test "diag: ring wraps at max_samples and keeps the newest" {
    var m = Monitor{};
    for (0..max_samples + 3) |i| m.push(.{ .vm_rss_kb = i, .seq = i });
    try std.testing.expectEqual(@as(usize, max_samples), m.len);
    try std.testing.expectEqual(@as(usize, max_samples + 2), m.last().?.seq);
    try std.testing.expectEqual(@as(usize, 3), m.at(0).?.seq);
}

test "diag: format line shows sign and units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = try formatLine(arena.allocator(), .{ .vm_rss_kb = 1024, .vm_size_kb = 2048, .vm_peak_kb = 4096 }, -128);
    try std.testing.expect(std.mem.indexOf(u8, line, "rss 1.0 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-128 KiB") != null);
}
