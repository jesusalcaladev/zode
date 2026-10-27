//! Zo's mascot animation system.
//!
//! Two layers, and keeping them apart is what makes the whole thing read as one
//! movement instead of two:
//!
//!  * the FRAME TRACK is the narrative: which eyes, and for how long. Every
//!    face is EXACTLY seven ASCII columns with the same silhouette — `(`, eye,
//!    gap, eye, `)` — and only the eyes change.
//!  * the MOTION layer is the pose underneath it: the slow lean of `thinking`,
//!    the twitch of `tooling`, the shake of `warn`/`err`. In the reference
//!    animation this is CSS (`breathe`, `tilt`, `jitter`, `jump`, `shake-*`) at
//!    60 fps; here it is a pure function of the elapsed time, so a renderer
//!    samples it whenever it happens to paint and a skipped paint is not a
//!    missed beat.
//!
//! `poseAt()` is everything a renderer needs: the face, the beat hint, and how
//! many columns it is leaning away from home.
//!
//! # Why these characters and no others
//!
//! Every eye used here (`o - ^ O x < > u * ! ? = @ ~`) is East-Asian
//! **Unambiguous** width, so seven columns are seven columns in every locale.
//! An ambiguous-width glyph (`◕`, `×`) is one column in one terminal and two in
//! another, and a face that changes width shifts everything to the right of it.

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
            .idle => 6, // cyan
            .thinking => 5, // magenta
            .tooling => 4, // blue
            .done => 2, // green
            .warn => 3, // yellow
            .err => 1, // red
        };
    }
};

/// Optional hint for renderers that can do more than text.
/// `.jump` marks the airborne beat of `done`; a terminal flashes the face,
/// an HTML renderer bounces it.
pub const Hint = enum { none, jump };

/// One animation frame: a 7-column face + hold time + optional render hint.
pub const Frame = struct {
    text: []const u8,
    ms: u64,
    hint: Hint = .none,
};

pub const frames = struct {
    /// ~7.9s loop. Breathing rhythm: long rests separated by short blinks,
    /// one soft "cozy exhale" (`u u`) and a small yawn — a cloud at rest,
    /// not a robot blinking on a schedule.
    pub const idle = [_]Frame{
        .{ .text = "( o o )", .ms = 1800 }, // rest
        .{ .text = "( u u )", .ms = 280 }, // cozy exhale
        .{ .text = "( o o )", .ms = 1200 }, // rest
        .{ .text = "( o - )", .ms = 100 }, // blink L
        .{ .text = "( o o )", .ms = 1100 }, // rest
        .{ .text = "( - o )", .ms = 100 }, // blink R
        .{ .text = "( o o )", .ms = 1000 }, // rest
        .{ .text = "( - - )", .ms = 70 }, // double blink (rare)
        .{ .text = "( o o )", .ms = 500 }, // settle
        .{ .text = "( u u )", .ms = 350 }, // yawn
        .{ .text = "( o o )", .ms = 1400 }, // rest
    };

    /// ~3.9s loop. A tiny narrative of weighing something:
    ///   puzzled → look up → idea forming → EUREKA → "no, not that" →
    ///   reconsider from the other side → annoyed processing → reset.
    /// The mid-cycle `( * * )` eureka beat is what turns this from
    /// "idle but harder" into "actually thinking".
    pub const thinking = [_]Frame{
        .{ .text = "( o o )", .ms = 380 }, // neutral
        .{ .text = "( ? o )", .ms = 260 }, // puzzled L
        .{ .text = "( ? ? )", .ms = 400 }, // both puzzled
        .{ .text = "( ^ ? )", .ms = 280 }, // look up L, still puzzled R
        .{ .text = "( ^ ^ )", .ms = 520 }, // both up: idea forming
        .{ .text = "( * * )", .ms = 240 }, // EUREKA
        .{ .text = "( - - )", .ms = 260 }, // hmm, not quite
        .{ .text = "( o o )", .ms = 200 }, // reset
        .{ .text = "( o ? )", .ms = 260 }, // now R is puzzled (reconsider)
        .{ .text = "( ? ? )", .ms = 380 }, // both puzzled again
        .{ .text = "( ~ ~ )", .ms = 400 }, // annoyed processing
        .{ .text = "( o o )", .ms = 320 }, // reset
    };

    /// ~1.2s loop. Fast rhythmic type-type, a focus beat, two quick strokes
    /// and a breath — busy hands, not a metronome.
    pub const tooling = [_]Frame{
        .{ .text = "( < > )", .ms = 120 }, // left
        .{ .text = "( > < )", .ms = 120 }, // right
        .{ .text = "( < > )", .ms = 120 }, // left
        .{ .text = "( > < )", .ms = 120 }, // right
        .{ .text = "( - - )", .ms = 160 }, // focus beat
        .{ .text = "( < > )", .ms = 100 }, // quick
        .{ .text = "( > < )", .ms = 100 }, // quick
        .{ .text = "( - - )", .ms = 90 }, // type-type
        .{ .text = "( o o )", .ms = 220 }, // breather
    };

    /// ~2.4s loop. The jump, in beats:
    ///   anticipate (crouch) → launch (eyes wide) → peak → fall → land →
    ///   squash → spring → sparkle → celebrate.
    /// The `( O O )` frame carries `hint = .jump` so the renderer can time its
    /// own airborne effect to the same beat the eyes go wide.
    pub const done = [_]Frame{
        .{ .text = "( ^ ^ )", .ms = 180 }, // happy, grounded
        .{ .text = "( ^ ^ )", .ms = 120 }, // hold
        .{ .text = "( - - )", .ms = 110 }, // CROUCH
        .{ .text = "( O O )", .ms = 90, .hint = .jump }, // LAUNCH
        .{ .text = "( O O )", .ms = 140 }, // PEAK
        .{ .text = "( ^ ^ )", .ms = 80 }, // FALLING
        .{ .text = "( o o )", .ms = 60 }, // LAND
        .{ .text = "( - - )", .ms = 70 }, // SQUASH
        .{ .text = "( ^ ^ )", .ms = 100 }, // SPRING
        .{ .text = "( * * )", .ms = 380 }, // SPARKLE
        .{ .text = "( ^ ^ )", .ms = 700 }, // celebrate
        .{ .text = "( o o )", .ms = 400 }, // neutral
    };

    /// ~1.8s loop. A pulse of alarm broken up by bracing beats and a final
    /// scrunch — reads as "something's wrong, I'm bracing", not a flat siren.
    /// The `( ? ! )` beat makes the cloud feel like it's reacting to a
    /// surprise, not just beeping.
    pub const warn = [_]Frame{
        .{ .text = "( ! ! )", .ms = 260 }, // alarm pulse
        .{ .text = "( ? ! )", .ms = 220 }, // confused alarm
        .{ .text = "( ! ! )", .ms = 240 }, // alarm
        .{ .text = "( ! - )", .ms = 90 }, // brace L
        .{ .text = "( ! ! )", .ms = 220 }, // alarm
        .{ .text = "( - ! )", .ms = 90 }, // brace R
        .{ .text = "( ! ! )", .ms = 240 }, // alarm pulse
        .{ .text = "( = = )", .ms = 140 }, // scrunch: full brace
        .{ .text = "( ! ! )", .ms = 260 }, // alarm
    };

    /// ~0.9s loop. Fast panic with a dazed beat: distress → squeeze one eye →
    /// distress → squeeze the other → distress → dazed (`@ @`) → recover.
    pub const err = [_]Frame{
        .{ .text = "( x x )", .ms = 180 }, // distress
        .{ .text = "( > < )", .ms = 70 }, // squeeze L
        .{ .text = "( x x )", .ms = 170 }, // distress
        .{ .text = "( < > )", .ms = 70 }, // squeeze R
        .{ .text = "( x x )", .ms = 150 }, // distress
        .{ .text = "( @ @ )", .ms = 130 }, // dazed
        .{ .text = "( x x )", .ms = 120 }, // recover
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

    /// Index of the frame that `elapsed_ms` falls in (0-based, wraps).
    pub fn indexAt(kind: StatusKind, elapsed_ms: u64) usize {
        const track = forKind(kind);
        var t = elapsed_ms % totalMs(kind);
        for (track, 0..) |f, i| {
            if (t < f.ms) return i;
            t -= f.ms;
        }
        return 0;
    }

    /// Milliseconds left in the frame `elapsed_ms` falls in.
    ///
    /// This is what a renderer schedules its next paint with: a beat ENDS when
    /// it ends, and sampling 90 ms beats with a 120 ms metronome is how an
    /// animation loses the frames it was drawn for.
    pub fn remainingMs(kind: StatusKind, elapsed_ms: u64) u64 {
        const track = forKind(kind);
        const i = indexAt(kind, elapsed_ms);
        var t = elapsed_ms % totalMs(kind);
        var k: usize = 0;
        while (k < i) : (k += 1) t -= track[k].ms;
        return track[i].ms - t;
    }

    /// The frame at `elapsed_ms` since the state started. The track loops.
    pub fn pickFrame(kind: StatusKind, elapsed_ms: u64) Frame {
        return forKind(kind)[indexAt(kind, elapsed_ms)];
    }

    /// Text-only convenience (same as `pickFrame(kind, ms).text`).
    pub fn pick(kind: StatusKind, elapsed_ms: u64) []const u8 {
        return pickFrame(kind, elapsed_ms).text;
    }
};

/// The pose under the eye track — the reference animation's CSS layer.
pub const Motion = enum {
    /// The swell of a resting cloud. Invisible at seven cells with no
    /// fractions, so the idle track's slow blinks carry it here.
    breathe,
    /// The slow lean of something being weighed.
    tilt,
    /// Busy hands: a fast, even twitch.
    jitter,
    /// Vertical, and the face is one row tall: the frame's `hint` carries it.
    jump,
    /// Something is wrong and the face braces against it.
    shake_warn,
    /// Panic, at panic speed.
    shake_err,
};

pub fn motion(kind: StatusKind) Motion {
    return switch (kind) {
        .idle => .breathe,
        .thinking => .tilt,
        .tooling => .jitter,
        .done => .jump,
        .warn => .shake_warn,
        .err => .shake_err,
    };
}

/// Whether the face actually moves sideways in this state. `breathe` and
/// `jump` do not (see `leanDx`), so a renderer can keep its slow clock there
/// and its fast one only where there is something to animate.
pub fn moves(kind: StatusKind) bool {
    return switch (motion(kind)) {
        .breathe, .jump => false,
        .tilt, .jitter, .shake_warn, .shake_err => true,
    };
}

// The motion layer's periods, in milliseconds. Same numbers as the reference
// CSS, so whatever was tuned by eye there is not re-tuned by guesswork here.

pub const tilt_period_ms: u64 = 2400;
pub const jitter_period_ms: u64 = 140;
pub const shake_warn_period_ms: u64 = 160;
pub const shake_err_period_ms: u64 = 70;

/// The widest lean, in columns. One is as much as a seven-cell face takes: a
/// second column starts to read as the face leaving its slot.
pub const lean_max: u8 = 1;

/// How far the face leans `t` milliseconds into its state, in columns, in
/// [0, `lean_max`].
///
/// The face never leans LEFT. Its home is the footer's left margin, flush with
/// the prompt on the row above it, and the column to the left of that margin is
/// the app's: a mascot that covers it makes the whole composer look shifted. So
/// the lean is a nudge to the right and back — one cell is a seventh of the
/// face, which is more than the reference CSS asks for (`2px` on a `64px`
/// glyph) and is exactly what a terminal can draw.
///
/// `breathe` and `jump` are 0 on purpose: the reference's `breathe` is
/// `scale(1.015)` — under two percent, and a cell has no fractions — and the
/// jump is vertical in a row that is one cell tall. The frame's `hint` is what
/// a renderer with more room acts on.
pub fn leanDx(kind: StatusKind, t: u64) u8 {
    return switch (motion(kind)) {
        .breathe, .jump => 0,
        .tilt => blk: {
            const pos = t % tilt_period_ms;
            const phase = @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(tilt_period_ms));
            const s = @sin(phase * 2.0 * std.math.pi);
            // A dead band: the face RESTS between leans instead of sliding
            // through the middle, which is what a pure sine looks like at
            // seven cells.
            break :blk if (s > 0.5) 1 else 0;
        },
        .jitter => if (t % jitter_period_ms < jitter_period_ms / 2) 0 else 1,
        .shake_warn => if (t % shake_warn_period_ms < shake_warn_period_ms / 2) 0 else 1,
        .shake_err => if (t % shake_err_period_ms < shake_err_period_ms / 2) 0 else 1,
    };
}

/// What the renderer paints: the face, the beat hint, the lean.
///
/// It is a value and not a state: `poseAt` is a pure function of the elapsed
/// time, so a stalled frame is not a missed beat — the next paint is whatever
/// the clock says it is.
pub const Pose = struct {
    /// The seven-column face.
    text: []const u8,
    /// The beat a richer renderer can act on beyond the glyphs.
    hint: Hint = .none,
    /// Columns to nudge the face right of its home, in [0, `lean_max`].
    dx: u8 = 0,
};

/// The pose `elapsed_ms` after the state started. The track loops forever.
pub fn poseAt(kind: StatusKind, elapsed_ms: u64) Pose {
    const f = frames.pickFrame(kind, elapsed_ms);
    return .{ .text = f.text, .hint = f.hint, .dx = leanDx(kind, elapsed_ms) };
}

/// Static face (frame 0). Kept for callers that just want "the face".
pub fn face(kind: StatusKind) []const u8 {
    return frames.forKind(kind)[0].text;
}

/// Frame at index `frame` (wraps). Kept for callers that drive a tick.
pub fn faceFrames(kind: StatusKind, frame: u64) []const u8 {
    const track = frames.forKind(kind);
    return track[frame % track.len].text;
}

/// The clock of one state. `started_ms` is the instant its track began, in
/// MILLISECONDS: a seconds-based clock rounds every beat of these tracks
/// (70 ms, 90 ms, 100 ms) to the same instant, and the animation the tracks
/// describe then never actually runs.
///
/// `started` is what makes a track begin at its FIRST beat. Without it the
/// elapsed time was measured from `started_ms = 0`, i.e. from 1970, so the
/// track began at whatever beat the wall clock happened to land on: launching
/// the app at 12:00:03.7 started the resting face with a double blink and no
/// rest at all (observed in a pty), which reads as a glitch, not as a mascot
/// waking up.
pub const Animator = struct {
    kind: StatusKind = .idle,
    started_ms: u64 = 0,
    started: bool = false,

    /// Not started yet: the first `setKind` is what starts the track, so it
    /// always opens on its first beat.
    pub fn init(kind: StatusKind) Animator {
        return .{ .kind = kind };
    }

    /// Starts the state's track from its first beat. Same kind is a no-op: a
    /// state that is re-entered (two tools in a row) must not restart the loop
    /// it is already in the middle of.
    pub fn setKind(self: *Animator, kind: StatusKind, now_ms: u64) void {
        if (self.started and self.kind == kind) return;
        self.started = true;
        self.kind = kind;
        self.started_ms = now_ms;
    }

    pub fn elapsed(self: *const Animator, now_ms: u64) u64 {
        if (!self.started) return 0;
        return if (now_ms >= self.started_ms) now_ms - self.started_ms else 0;
    }

    pub fn pose(self: *const Animator, now_ms: u64) Pose {
        return poseAt(self.kind, self.elapsed(now_ms));
    }

    pub fn face(self: *const Animator, now_ms: u64) []const u8 {
        return self.pose(now_ms).text;
    }

    /// The `.jump` beat (the airborne frame of `done`).
    pub fn isJump(self: *const Animator, now_ms: u64) bool {
        return self.pose(now_ms).hint == .jump;
    }
};

test "mascot color mapping" {
    try std.testing.expectEqual(@as(u8, 6), StatusKind.idle.color());
    try std.testing.expectEqual(@as(u8, 5), StatusKind.thinking.color());
    try std.testing.expectEqual(@as(u8, 4), StatusKind.tooling.color());
    try std.testing.expectEqual(@as(u8, 2), StatusKind.done.color());
    try std.testing.expectEqual(@as(u8, 3), StatusKind.warn.color());
    try std.testing.expectEqual(@as(u8, 1), StatusKind.err.color());
}

test "every frame of every track is seven ASCII columns" {
    // The face lives in a footer whose width is computed from `face_width`, and
    // the whole reason for the ASCII set is that its width is the same
    // everywhere. A byte count is not a column count in general, so ASCII is
    // what makes them the same: seven ASCII bytes are seven columns in every
    // terminal there is.
    for ([_]StatusKind{ .idle, .thinking, .tooling, .done, .warn, .err }) |kind| {
        const track = frames.forKind(kind);
        try std.testing.expect(track.len > 0);
        for (track) |f| {
            try std.testing.expectEqual(@as(usize, 7), f.text.len);
            for (f.text) |c| try std.testing.expect(c >= 0x20 and c < 0x7f);
            try std.testing.expect(f.ms > 0);
            // The silhouette: `(`, two eyes, `)`, and the spacing that keeps it
            // inside seven cells.
            try std.testing.expect(f.text[0] == '(' and f.text[6] == ')');
        }
    }
}

test "the loops are the lengths the comments claim" {
    // A comment with the wrong number in it is a comment nobody trusts, and
    // these numbers are the animation's actual period.
    try std.testing.expectEqual(@as(u64, 7900), frames.totalMs(.idle)); // ~7.9s
    try std.testing.expectEqual(@as(u64, 3900), frames.totalMs(.thinking)); // ~3.9s
    try std.testing.expectEqual(@as(u64, 1150), frames.totalMs(.tooling)); // ~1.2s
    try std.testing.expectEqual(@as(u64, 2430), frames.totalMs(.done)); // ~2.4s
    try std.testing.expectEqual(@as(u64, 1760), frames.totalMs(.warn)); // ~1.8s
    try std.testing.expectEqual(@as(u64, 890), frames.totalMs(.err)); // ~0.9s
}

test "a beat lasts exactly its own duration, and the track wraps" {
    for ([_]StatusKind{ .idle, .thinking, .tooling, .done, .warn, .err }) |kind| {
        const track = frames.forKind(kind);
        const total = frames.totalMs(kind);
        var start: u64 = 0;
        for (track, 0..) |f, i| {
            // Inside the beat: this index, this remainder.
            try std.testing.expectEqual(i, frames.indexAt(kind, start));
            try std.testing.expectEqual(f.ms, frames.remainingMs(kind, start));
            try std.testing.expectEqualStrings(f.text, frames.pick(kind, start));
            // One millisecond before it ends it is still this beat, with one
            // millisecond left.
            try std.testing.expectEqual(i, frames.indexAt(kind, start + f.ms - 1));
            try std.testing.expectEqual(@as(u64, 1), frames.remainingMs(kind, start + f.ms - 1));
            start += f.ms;
        }
        // The loop is seamless: the last millisecond belongs to the last beat,
        // the modulo lands back on the first.
        try std.testing.expectEqual(track.len - 1, frames.indexAt(kind, total - 1));
        try std.testing.expectEqual(@as(usize, 0), frames.indexAt(kind, total));
        try std.testing.expectEqual(track[0].ms, frames.remainingMs(kind, total));
    }
}

test "the pose is a function of the clock, not of how often it is asked" {
    // Two renderers that painted different numbers of frames for the same
    // instant must show the same thing: no interpolation state, no drift.
    for ([_]StatusKind{ .idle, .thinking, .tooling, .done, .warn, .err }) |kind| {
        const total = frames.totalMs(kind);
        var t: u64 = 0;
        while (t < total * 2) : (t += 17) {
            const a = poseAt(kind, t);
            const b = poseAt(kind, t + total);
            try std.testing.expectEqualStrings(a.text, b.text);
            try std.testing.expectEqual(a.hint, b.hint);
        }
        // The lean has its own period, which is not the track's: it repeats on
        // ITS clock and nowhere else.
        const period = motionPeriodMs(kind);
        if (period > 0) {
            t = 0;
            while (t < period * 2) : (t += 11) {
                try std.testing.expectEqual(leanDx(kind, t), leanDx(kind, t + period));
            }
        }
    }
}

/// The lean's own period, in ms (0 when the face does not move sideways).
fn motionPeriodMs(kind: StatusKind) u64 {
    return switch (motion(kind)) {
        .breathe, .jump => 0,
        .tilt => tilt_period_ms,
        .jitter => jitter_period_ms,
        .shake_warn => shake_warn_period_ms,
        .shake_err => shake_err_period_ms,
    };
}

test "lean: inside its one cell, and moving where it should" {
    for ([_]StatusKind{ .idle, .thinking, .tooling, .done, .warn, .err }) |kind| {
        var t: u64 = 0;
        while (t < 6000) : (t += 7) {
            try std.testing.expect(leanDx(kind, t) <= lean_max);
        }
    }

    // The resting face does not drift: the idle track is what moves it.
    try std.testing.expectEqual(@as(u8, 0), leanDx(.idle, 0));
    try std.testing.expectEqual(@as(u8, 0), leanDx(.idle, 1900));
    // `done` leans nowhere: its jump is the frame's hint.
    try std.testing.expectEqual(@as(u8, 0), leanDx(.done, 300));

    // Tilt: a lean and a rest, not a vibration — the face is out at the peak
    // of the wave and home in between, for a third of the period each way.
    try std.testing.expectEqual(@as(u8, 1), leanDx(.thinking, tilt_period_ms / 4));
    try std.testing.expectEqual(@as(u8, 0), leanDx(.thinking, tilt_period_ms / 2));
    try std.testing.expectEqual(@as(u8, 0), leanDx(.thinking, tilt_period_ms * 3 / 4));

    // Shakes alternate on their own period, not on the frame's.
    try std.testing.expectEqual(@as(u8, 0), leanDx(.err, 0));
    try std.testing.expectEqual(@as(u8, 1), leanDx(.err, shake_err_period_ms / 2));
    try std.testing.expectEqual(@as(u8, 0), leanDx(.err, shake_err_period_ms));
    try std.testing.expectEqual(@as(u8, 0), leanDx(.warn, 0));
    try std.testing.expectEqual(@as(u8, 1), leanDx(.warn, shake_warn_period_ms / 2));
    try std.testing.expectEqual(@as(u8, 0), leanDx(.tooling, 0));
    try std.testing.expectEqual(@as(u8, 1), leanDx(.tooling, jitter_period_ms / 2));

    // The lean is a layer of its own: `thinking` moves while its frames hold.
    try std.testing.expectEqual(@as(u8, 1), poseAt(.thinking, tilt_period_ms / 4).dx);
}

test "jump hint belongs to the launch beat of done, and to nothing else" {
    const launch = poseAt(.done, 180 + 120 + 110); // after the crouch
    try std.testing.expectEqual(Hint.jump, launch.hint);
    try std.testing.expectEqualStrings("( O O )", launch.text);
    // The beat is 90 ms long, so the hint does not leak into the peak.
    try std.testing.expectEqual(Hint.none, poseAt(.done, 180 + 120 + 110 + 90).hint);

    for ([_]StatusKind{ .idle, .thinking, .tooling, .warn, .err }) |kind| {
        const total = frames.totalMs(kind);
        var t: u64 = 0;
        while (t < total) : (t += 5) {
            try std.testing.expectEqual(Hint.none, poseAt(kind, t).hint);
        }
    }
}

test "animator: millisecond beats are observable" {
    // The bug this guards against: a clock in seconds. Every one of these
    // beats is shorter than a second, so a seconds-based clock returns the same
    // frame for all of them.
    var a = Animator.init(.err);
    a.setKind(.err, 1000); // the first `setKind` is what starts the clock
    try std.testing.expectEqual(@as(u8, 0), a.pose(1000).dx);
    try std.testing.expectEqual(@as(u8, 1), a.pose(1000 + 40).dx);

    a.setKind(.thinking, 5000);
    try std.testing.expectEqual(@as(u64, 0), a.elapsed(5000));
    try std.testing.expectEqualStrings("( o o )", a.face(5000));
    try std.testing.expectEqualStrings("( ? o )", a.face(5390));
}

test "animator: a track opens on its first beat, not on a random one" {
    // Measured in a pty: with the clock measured from 1970 the resting face
    // began mid-loop, so the first thing the app did was a double blink with
    // no rest before it.
    for ([_]StatusKind{ .idle, .thinking, .tooling, .done, .warn, .err }) |kind| {
        var a = Animator.init(kind);
        // Before the first `setKind` there is no clock at all, and the pose is
        // the track's opening beat.
        try std.testing.expectEqual(@as(u64, 0), a.elapsed(123_456_789));
        try std.testing.expectEqualStrings(frames.forKind(kind)[0].text, a.face(123_456_789));

        // The moment it starts, wherever in the wall clock that is, is beat 0.
        a.setKind(kind, 987_654_321);
        try std.testing.expectEqual(@as(u64, 0), a.elapsed(987_654_321));
        try std.testing.expectEqualStrings(frames.forKind(kind)[0].text, a.face(987_654_321));
        // …and the second beat arrives exactly when the first one ends.
        const first_ms = frames.forKind(kind)[0].ms;
        try std.testing.expectEqual(frames.forKind(kind)[1].text, a.face(987_654_321 + first_ms));
    }
}

test "animator: re-entering the same state does not restart its loop" {
    var a = Animator.init(.tooling);
    a.setKind(.tooling, 9000); // the first one starts the clock
    a.setKind(.tooling, 9100); // same kind: the elapsed time keeps running
    try std.testing.expectEqual(@as(u64, 9000), a.started_ms);
    try std.testing.expectEqual(@as(u64, 100), a.elapsed(9100));
    try std.testing.expectEqualStrings("( > < )", a.face(9120));

    a.setKind(.done, 1000);
    try std.testing.expectEqual(@as(u64, 1000), a.started_ms);
    try std.testing.expectEqualStrings("( ^ ^ )", a.face(1000));
    try std.testing.expect(a.isJump(1000 + 180 + 120 + 110));
    try std.testing.expect(!a.isJump(1000));
}
