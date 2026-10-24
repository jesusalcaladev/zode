//! Zo's mascot animation system.
//! Every face is 7 ASCII columns: `(`, eye, gap, eye, `)`. Only eyes change.

const std = @import("std");

pub const StatusKind = enum {
    idle,
    thinking,
    tooling,
    done,
    warn,
    err,

    pub fn color(self: StatusKind) u8 {
        return switch (self) {
            .idle => 6, .thinking => 5, .tooling => 4, .done => 2, .warn => 3, .err => 1,
        };
    }
};

pub const Hint = enum { none, jump };

pub const Frame = struct {
    text: []const u8,
    ms: u64,
    hint: Hint = .none,
};

pub const frames = struct {
    pub const idle = [_]Frame{
        .{ .text = "( o o )", .ms = 1800 },
        .{ .text = "( u u )", .ms = 280 },
        .{ .text = "( o o )", .ms = 1200 },
        .{ .text = "( o - )", .ms = 100 },
        .{ .text = "( o o )", .ms = 1100 },
        .{ .text = "( - o )", .ms = 100 },
        .{ .text = "( o o )", .ms = 1000 },
        .{ .text = "( - - )", .ms = 70 },
        .{ .text = "( o o )", .ms = 500 },
        .{ .text = "( u u )", .ms = 350 },
        .{ .text = "( o o )", .ms = 1400 },
    };

    pub const thinking = [_]Frame{
        .{ .text = "( o o )", .ms = 380 },
        .{ .text = "( ? o )", .ms = 260 },
        .{ .text = "( ? ? )", .ms = 400 },
        .{ .text = "( ^ ? )", .ms = 280 },
        .{ .text = "( ^ ^ )", .ms = 520 },
        .{ .text = "( * * )", .ms = 240 },
        .{ .text = "( - - )", .ms = 260 },
        .{ .text = "( o o )", .ms = 200 },
        .{ .text = "( o ? )", .ms = 260 },
        .{ .text = "( ? ? )", .ms = 380 },
        .{ .text = "( ~ ~ )", .ms = 400 },
        .{ .text = "( o o )", .ms = 320 },
    };

    pub const tooling = [_]Frame{
        .{ .text = "( < > )", .ms = 120 },
        .{ .text = "( > < )", .ms = 120 },
        .{ .text = "( < > )", .ms = 120 },
        .{ .text = "( > < )", .ms = 120 },
        .{ .text = "( - - )", .ms = 160 },
        .{ .text = "( < > )", .ms = 100 },
        .{ .text = "( > < )", .ms = 100 },
        .{ .text = "( - - )", .ms = 90 },
        .{ .text = "( o o )", .ms = 220 },
    };

    pub const done = [_]Frame{
        .{ .text = "( ^ ^ )", .ms = 180 },
        .{ .text = "( ^ ^ )", .ms = 120 },
        .{ .text = "( - - )", .ms = 110 },
        .{ .text = "( O O )", .ms = 90, .hint = .jump },
        .{ .text = "( O O )", .ms = 140 },
        .{ .text = "( ^ ^ )", .ms = 80 },
        .{ .text = "( o o )", .ms = 60 },
        .{ .text = "( - - )", .ms = 70 },
        .{ .text = "( ^ ^ )", .ms = 100 },
        .{ .text = "( * * )", .ms = 380 },
        .{ .text = "( ^ ^ )", .ms = 700 },
        .{ .text = "( o o )", .ms = 400 },
    };

    pub const warn = [_]Frame{
        .{ .text = "( ! ! )", .ms = 260 },
        .{ .text = "( ? ! )", .ms = 220 },
        .{ .text = "( ! ! )", .ms = 240 },
        .{ .text = "( ! - )", .ms = 90 },
        .{ .text = "( ! ! )", .ms = 220 },
        .{ .text = "( - ! )", .ms = 90 },
        .{ .text = "( ! ! )", .ms = 240 },
        .{ .text = "( = = )", .ms = 140 },
        .{ .text = "( ! ! )", .ms = 260 },
    };

    pub const err = [_]Frame{
        .{ .text = "( x x )", .ms = 180 },
        .{ .text = "( > < )", .ms = 70 },
        .{ .text = "( x x )", .ms = 170 },
        .{ .text = "( < > )", .ms = 70 },
        .{ .text = "( x x )", .ms = 150 },
        .{ .text = "( @ @ )", .ms = 130 },
        .{ .text = "( x x )", .ms = 120 },
    };

    pub fn forKind(kind: StatusKind) []const Frame {
        return switch (kind) {
            .idle => &idle,
            .thinking => &thinking,
            .tooling => &tooling,
            .done => &done,
            .warn => &warn,
            .err => &err,
        };
    }

    pub fn totalMs(kind: StatusKind) u64 {
        var sum: u64 = 0;
        for (forKind(kind)) |f| sum += f.ms;
        return sum;
    }

    pub fn pickFrame(kind: StatusKind, elapsed_ms: u64) Frame {
        const track = forKind(kind);
        var t = elapsed_ms % totalMs(kind);
        for (track) |f| {
            if (t < f.ms) return f;
            t -= f.ms;
        }
        return track[0];
    }

    pub fn pick(kind: StatusKind, elapsed_ms: u64) []const u8 {
        return pickFrame(kind, elapsed_ms).text;
    }
};

pub fn face(kind: StatusKind) []const u8 {
    return frames.forKind(kind)[0].text;
}

pub fn faceFrames(kind: StatusKind, frame: u64) []const u8 {
    const track = frames.forKind(kind);
    return track[frame % track.len].text;
}

pub const Animator = struct {
    kind: StatusKind = .idle,
    state_started_ms: u64 = 0,
    current_frame: Frame = .{ .text = "( o o )", .ms = 0, .hint = .none },

    pub fn init(kind: StatusKind) Animator {
        return .{
            .kind = kind,
            .state_started_ms = 0,
            .current_frame = frames.pickFrame(kind, 0),
        };
    }

    pub fn setKind(self: *Animator, kind: StatusKind, now_ms: u64) void {
        if (self.kind == kind) return;
        self.kind = kind;
        self.state_started_ms = now_ms;
        self.current_frame = frames.pickFrame(kind, 0);
    }

    pub fn tick(self: *Animator, now_ms: u64) Frame {
        const elapsed = if (now_ms >= self.state_started_ms)
            now_ms - self.state_started_ms
        else
            0;
        self.current_frame = frames.pickFrame(self.kind, elapsed);
        return self.current_frame;
    }

    pub fn current(self: *Animator, now_ms: u64) Frame {
        return self.tick(now_ms);
    }

    pub fn face(self: *Animator, now_ms: u64) []const u8 {
        return self.current(now_ms).text;
    }

    pub fn color(self: *Animator) u8 {
        return self.kind.color();
    }

    pub fn jumpHint(self: *Animator, now_ms: u64) bool {
        return self.current(now_ms).hint == .jump;
    }
};

test "mascot color mapping" {
    try std.testing.expect(StatusKind.idle.color() == 6);
    try std.testing.expect(StatusKind.thinking.color() == 5);
    try std.testing.expect(StatusKind.tooling.color() == 4);
    try std.testing.expect(StatusKind.done.color() == 2);
    try std.testing.expect(StatusKind.warn.color() == 3);
    try std.testing.expect(StatusKind.err.color() == 1);
}

test "mascot frames loop correctly" {
    const idle_len = frames.totalMs(StatusKind.idle);
    try std.testing.expect(idle_len > 0);
    const f0 = frames.pick(StatusKind.idle, 0);
    const f1 = frames.pick(StatusKind.idle, idle_len);
    try std.testing.expect(std.mem.eql(u8, f0, f1));
}

test "mascot animator advances" {
    var a = Animator.init(StatusKind.idle);
    const f0 = a.face(0);
    try std.testing.expect(std.mem.eql(u8, f0, "( o o )"));
    const f1 = a.face(2000);
    try std.testing.expect(!std.mem.eql(u8, f1, "( o o )"));
}

test "mascot animator resets on kind change" {
    var a = Animator.init(StatusKind.idle);
    _ = a.face(5000);
    a.setKind(StatusKind.thinking, 10000);
    const f = a.face(10000);
    try std.testing.expect(std.mem.eql(u8, f, "( o o )"));
}

test "mascot done has jump hint" {
    var a = Animator.init(StatusKind.done);
    // Frame 3 "( O O )" with .jump starts at 180+120+110 = 410 ms.
    try std.testing.expect(a.jumpHint(450));
}