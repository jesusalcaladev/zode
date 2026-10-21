//! The `ask` tool: the piece that turns a turn from "the model guessed what you
//! wanted" into "the model asked one question and did the right thing".
//!
//! It is deliberately a PURE module (no I/O, no Model, no threads) so the part
//! that is easy to get wrong — the shape of the question and, above all, the
//! text the MODEL reads back — is testable without a TUI and without a network.
//!
//! Why the answer is a tool result and not a new user message: an assistant
//! message that asks something and gets a `user` message back is not a thing
//! any provider accepts (the `user` turn has to follow a `user` turn, not an
//! assistant one with pending `tool_calls`). A tool call parks the turn exactly
//! where the API expects it to be parked, so the wire format does not have to
//! change and every provider accepts it.
//!
//! The wording of the "no answer" results matters more than it looks. A model
//! that asked and got nothing tends to either stall or repeat the question. What
//! it needs is to be told to DECIDE, and to say which way it went, so the answer
//! is a commitment instead of a shrug.

const std = @import("std");

const ask = @This();

/// A multiple-choice question with at most this many options.
///
/// Not 4 like some implementations: the useful cases are "one of these three",
/// "one of these four" and "type it yourself", and a fifth slot is where a
/// model starts inventing options to fill the space. Anything more is a sign the
/// question itself is wrong, and the model is told to ask a different one.
pub const max_options = 5;

/// Above this the question is not a question, it is a paragraph. Truncating
/// would change what was asked, so it is cut at the limit and the model is told.
pub const max_question_len = 600;

/// Options are shown in a one-line picker. Longer than this and the picker row
/// wraps or gets cut, and a cut option is a wrong answer.
pub const max_option_len = 120;

/// Short label for the modal title. Anything longer stops being a label.
pub const max_header_len = 40;

/// Text handed back to the model when the user pressed ESC on the question.
///
/// ESC is NOT "abort the turn": aborting is Ctrl+C. ESC means "I am not going to
/// answer that", and the useful thing for the agent to do with that is to pick
/// the most reasonable option itself, SAY which one it picked, and continue.
pub const declined_text =
    "The user did NOT answer: they closed the question without choosing. They did not say to stop. " ++
    "Pick the most reasonable option yourself, say in one short line which one you picked and why, " ++
    "then continue with the task. Do not ask again.";

/// Same, for the case where nobody answered within the timeout. The difference
/// matters: the user was probably AFK, so the agent should also say plainly that
/// it is proceeding on its own judgement.
pub const timed_out_text =
    "The user did NOT answer: the question timed out (they were probably away). " ++
    "Do not ask again for this task. Pick the most reasonable option yourself, say in one short line " ++
    "which one you picked and why, then continue. If the choice is not reversible, prefer the option " ++
    "that changes the fewest files.";

/// What the model reads when the user DID answer. `buf` is fixed-size on purpose:
/// the caller composes it on the stack and the worker immediately copies it into
/// the session, so there is no ownership to get wrong.
/// Size of `Answered.buf`. A named constant because `Answered{}.buf.len` is not
/// valid as an expression and the number is needed in a computation.
pub const answered_buf_len = max_option_len * 2 + 64;

// ── YOLO: the mode where nobody is asked ─────────────────────────────────
//
// `/yolo` (the "bypass" permission mode) exists for one reason: the app does
// not stop to wait for the human. A QUESTION that opens a dialog stops the
// app exactly as much as a permission dialog does, so in that mode the `ask`
// tool must not open one.
//
// So the question is answered by the harness — with the model's OWN
// recommendation, which the schema tells it to put FIRST, so the first option
// IS the recommendation — or, when there is no option to take, it is left
// OPEN.
//
// And in BOTH cases the model has to SAY it in its final summary: a decision
// the user never saw is a decision the user cannot check, and an open
// question nobody mentions is a question that is lost.

/// The text the model reads when the harness took its recommendation.
pub const yolo_taken_prefix = "Nobody was asked (YOLO mode): I took your own recommendation, ";
pub const yolo_taken_suffix =
    ". Say in ONE short line in your final summary that you chose it yourself and why.";

/// The text the model reads when the question is left OPEN.
///
/// The question is NOT repeated: the model wrote it, it is in its own context
/// already, and repeating a 600-character question to say "this is still
/// open" is a waste of the user's tokens.
pub const yolo_deferred_text =
    "Nobody was asked (YOLO mode): this question stays OPEN. Decide yourself now and keep going, " ++
    "and MENTION this open question in your final summary so the user can answer it later. " ++
    "Do not ask again this turn.";

/// Size of the buffer for the YOLO texts. They carry an option, so they are
/// bigger than the "answered" one.
pub const yolo_buf_len = max_option_len + 256;

/// What to do with a question, given the permission mode.
pub const Decision = enum {
    /// Ask the user (every mode but YOLO).
    ask,
    /// Nobody is going to answer and there IS a recommendation: take it.
    take_recommendation,
    /// Nobody is going to answer and there is nothing to take: leave it open.
    leave_open,
};

/// The decision, as a function of the mode and of the question.
///
/// It is PURE on purpose: the alternative is a test that opens a dialog and
/// waits for a human that is not there (which hangs), and the rule is the
/// thing worth pinning.
pub fn decide(bypass: bool, has_options: bool) Decision {
    if (!bypass) return .ask;
    if (has_options) return .take_recommendation;
    return .leave_open;
}

/// The text the model reads when the harness took its recommendation.
pub fn formatYoloTaken(buf: []u8, option: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}\"{s}\"{s}", .{ yolo_taken_prefix, option, yolo_taken_suffix }) catch
        "Nobody was asked (YOLO mode): I took your own recommendation. Say it in your final summary.";
}

/// The text the model reads when the question is left open.
pub fn formatYoloDeferred(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}", .{yolo_deferred_text}) catch
        "Nobody was asked (YOLO mode). Mention it in your final summary.";
}

pub const Answered = struct {
    buf: [answered_buf_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Answered) []const u8 {
        return self.buf[0..self.len];
    }
};

/// "The user answered: X".
///
/// The prefix is fixed prose and not the raw answer: the model has to be able
/// to tell a user's sentence from its own text, and "The user answered:" is the
/// cheapest way to make that unambiguous. The user's words are passed through
/// verbatim (trimmed) because paraphrasing what someone said is how agents end
/// up confident about something nobody agreed to.
///
/// If the answer does not fit, it is cut AND the cut is announced
/// ("… (truncated)"). Silently cutting a user's answer is the one thing that
/// must not happen here: the model would then act on half an instruction and be
/// certain about it. The prefix always survives, whatever the input.
pub fn formatAnswered(text: []const u8) Answered {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    // Space left after the prefix and the "(truncated)" marker. Reserving the
    // marker up front (instead of writing it and hoping it fits) is what
    // guarantees the prefix is never the thing that gets cut.
    const marker = "… (truncated)";
    const prefix = "The user answered: ";
    const room = answered_buf_len - prefix.len - marker.len - 1;
    const cut = trimmed.len > room;
    const src = if (cut) trimmed[0..room] else trimmed;

    var a = Answered{};
    const suffix = if (cut) marker else "";
    const written = std.fmt.bufPrint(&a.buf, "{s}{s}{s}", .{ prefix, src, suffix }) catch
        // Unreachable with the reservation above, but a partial prefix would be
        // read as the whole answer, so the fallback is a complete sentence.
        std.fmt.bufPrint(&a.buf, "{s}(no answer captured)", .{prefix}) catch "";
    a.len = written.len;
    return a;
}

/// A parsed question. `options` may be empty: then it is a free-text question
/// and the input box becomes the answer field.
pub const Question = struct {
    header: []const u8 = "",
    question: []const u8,
    options: []const []const u8,
};

pub const ParseError = error{
    OutOfMemory,
    /// No `question`, or it is not a string.
    BadQuestion,
    /// `options` is there but is not an array of strings.
    BadOptions,
    /// More than `max_options`.
    TooManyOptions,
    /// An empty or blank option: a choice the user cannot see is not a choice.
    EmptyOption,
};

/// Parses the tool arguments. Owns nothing: everything points into `arena`.
pub fn parse(arena: std.mem.Allocator, args_json: []const u8) ParseError!Question {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch
        return error.BadQuestion;
    if (root != .object) return error.BadQuestion;
    const obj = root.object;

    const qv = obj.get("question") orelse return error.BadQuestion;
    if (qv != .string) return error.BadQuestion;
    var question = std.mem.trim(u8, qv.string, " \t\r\n");
    if (question.len == 0) return error.BadQuestion;
    // Long questions are cut, not rejected: the model that wrote 700 characters
    // of context before the actual question still deserves to be answered, and
    // the cut point is visible in the modal.
    if (question.len > max_question_len) question = question[0..max_question_len];

    var header: []const u8 = "";
    if (obj.get("header")) |hv| {
        if (hv == .string) {
            const h = std.mem.trim(u8, hv.string, " \t\r\n");
            header = if (h.len > max_header_len) h[0..max_header_len] else h;
        }
    }

    var options: []const []const u8 = &.{};
    if (obj.get("options")) |ov| {
        if (ov != .array) return error.BadOptions;
        if (ov.array.items.len > max_options) return error.TooManyOptions;
        if (ov.array.items.len > 0) {
            const opts = try arena.alloc([]const u8, ov.array.items.len);
            for (ov.array.items, 0..) |it, i| {
                if (it != .string) return error.BadOptions;
                const t = std.mem.trim(u8, it.string, " \t\r\n");
                if (t.len == 0) return error.EmptyOption;
                opts[i] = if (t.len > max_option_len) t[0..max_option_len] else t;
            }
            options = opts;
        }
    }

    return .{ .header = header, .question = question, .options = options };
}

/// What the model is told about the tool, on top of the JSON schema.
///
/// This is the part that decides whether `ask` is useful or is a nuisance. The
/// rules are short and blunt because the failure mode without them is real and
/// was visible in other agents: a model that asks three questions a turn, or
/// asks for something it could have read out of a file, is worse than one that
/// never asks.
pub const guidance =
    \\When to use `ask`:
    \\ - The answer changes what you do next: a choice between approaches, an
    \\   ambiguous request with two readings, a "which one" with real
    \\   consequences. One question, at the moment it matters.
    \\ - The question is not answerable by looking: do NOT ask what you can read
    \\   with read/grep/glob, do not ask for a path you can find, do not ask for
    \\   the output of a command you can run. Read it first, then ask if it is
    \\   still unclear.
    \\ - At most ONE question per step, and no more than three in a whole turn.
    \\   A model that asks everything is as useless as one that assumes
    \\   everything.
    \\ - Do NOT use it to report progress, to say you are done, or to hand back work
    \\   you could have finished. It is for a decision only YOU cannot make; anything
    \\   else is your job, and a user who gets asked to confirm your work learns to
    \\   press enter without reading.
    \\
    \\How to ask:
    \\ - Put your recommendation FIRST and say why in the question text, so the
    \\   user can just press enter.
    \\ - Use `options` when the choices are enumerable (2 to 5). Use no options
    \\   when the answer is free text (a name, a path, a yes/no with a nuance).
    \\ - `header` is a 2-3 word label for the dialog, not the question.
    \\ - Never ask a question whose answer is "whatever you think is right". That is
    \\   the model's own call; asking it hands back the decision it was given.
    \\
    \\After the answer: keep going. Do not ask a follow-up that restates the same
    \\decision, and do not ask anything you have already been told.
;

/// The line the TUI shows above the options, and the ONLY thing the user reads
/// before choosing. It is the question, not the header.
pub fn displayQuestion(q: Question) []const u8 {
    return q.question;
}

/// One-line summary for the history, next to the `ask(...)` header.
pub fn answerSummary(answered_text: []const u8) []const u8 {
    const t = std.mem.trim(u8, answered_text, " \t\r\n");
    return t;
}

test "parse: question is required and its whitespace is trimmed" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const q = try ask.parse(ast.allocator(),
        \\{"question":"  Which approach?  "}
    );
    try std.testing.expectEqualStrings("Which approach?", q.question);
    try std.testing.expectEqual(@as(usize, 0), q.options.len);
    try std.testing.expectEqualStrings("", q.header);
}

test "parse: options as an array of strings, with a header" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const q = try ask.parse(ast.allocator(),
        \\{"header":"approach","question":"Como lo hacemos?","options":["A"," B ","C"]}
    );
    try std.testing.expectEqualStrings("approach", q.header);
    try std.testing.expectEqual(@as(usize, 3), q.options.len);
    try std.testing.expectEqualStrings("A", q.options[0]);
    // The space is trimmed: an option that paints with a leading space has its
    // text one column off from the others, which is what the picker tests for.
    try std.testing.expectEqualStrings("B", q.options[1]);
}

test "parse: a missing question is BadQuestion, not a crash" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const a = ast.allocator();
    try std.testing.expectError(error.BadQuestion, ask.parse(a, "{}"));
    try std.testing.expectError(error.BadQuestion, ask.parse(a,
        \\{"question":"   "}
    ));
    try std.testing.expectError(error.BadQuestion, ask.parse(a,
        \\{"question":42}
    ));
    try std.testing.expectError(error.BadQuestion, ask.parse(a, "not json"));
    try std.testing.expectError(error.BadQuestion, ask.parse(a, "[]"));
}

test "parse: more than max_options is rejected instead of silently trimmed" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const a = ast.allocator();
    try std.testing.expectError(error.TooManyOptions, ask.parse(a,
        \\{"question":"q","options":["1","2","3","4","5","6"]}
    ));
    // Exactly at the cap is fine.
    const q = try ask.parse(a,
        \\{"question":"q","options":["1","2","3","4","5"]}
    );
    try std.testing.expectEqual(@as(usize, 5), q.options.len);
}

test "parse: an empty option is rejected (an invisible option is not an option)" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    try std.testing.expectError(error.EmptyOption, ask.parse(ast.allocator(),
        \\{"question":"q","options":["a","  ","b"]}
    ));
}

test "parse: options that are not strings is BadOptions" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const a = ast.allocator();
    try std.testing.expectError(error.BadOptions, ask.parse(a,
        \\{"question":"q","options":"nope"}
    ));
    try std.testing.expectError(error.BadOptions, ask.parse(a,
        \\{"question":"q","options":[1,2]}
    ));
}

test "parse: an overlong question is truncated, and the header too" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    // The JSON is assembled by hand instead of with bufPrint: two 4 KB fields do
    // not fit comfortably in a guessed buffer, and a "No space left" here would
    // be a test about the buffer rather than about the cut.
    var hb: [9000]u8 = undefined;
    var w: std.Io.Writer = .fixed(&hb);
    w.writeAll("{\"question\":\"") catch unreachable;
    var i: usize = 0;
    while (i < 4096) : (i += 1) w.writeByte('x') catch unreachable;
    w.writeAll("\",\"header\":\"") catch unreachable;
    i = 0;
    while (i < 4096) : (i += 1) w.writeByte('y') catch unreachable;
    w.writeAll("\"}") catch unreachable;
    const h = w.buffered();
    try std.testing.expect(h.len > 8192);

    const q = try ask.parse(ast.allocator(), h);
    try std.testing.expectEqual(ask.max_question_len, q.question.len);
    try std.testing.expectEqual(ask.max_header_len, q.header.len);
}

test "formatAnswered: the prefix separates the user's voice from the model's" {
    const a = ask.formatAnswered("usa el parser nuevo");
    try std.testing.expectEqualStrings("The user answered: usa el parser nuevo", a.slice());
}

test "formatAnswered: an overlong answer is truncated AND it says so" {
    // The one thing that must not happen here is cutting the user's answer in
    // silence: the model would act on half an instruction and be certain of it.
    var big: [4096]u8 = @splat('z');
    const a = ask.formatAnswered(&big);
    try std.testing.expect(a.slice().len <= a.buf.len);
    try std.testing.expect(std.mem.startsWith(u8, a.slice(), "The user answered: "));
    try std.testing.expect(std.mem.endsWith(u8, a.slice(), "(truncated)"));
}

test "formatAnswered: an answer that fits carries no marker" {
    // The truncation marker is noise if there was no truncation: the model
    // could read "truncated" as one of its own instructions.
    const a = ask.formatAnswered("vale, vamos con el parser nuevo");
    try std.testing.expect(std.mem.indexOf(u8, a.slice(), "truncated") == null);
}

test "formatAnswered: surrounding whitespace is dropped" {
    const a = ask.formatAnswered("  sí, con el parser  \n");
    try std.testing.expectEqualStrings("The user answered: sí, con el parser", a.slice());
}

test "decline and timeout tell the model to decide, not to stop" {
    // The two phrases have to do two things: they do not say "stop" (which the
    // model would read as permission to give up) and they DO contain the
    // instruction to choose, which is the only useful thing to do with a no.
    try std.testing.expect(std.mem.indexOf(u8, ask.declined_text, "Pick the most reasonable") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask.timed_out_text, "Pick the most reasonable") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask.declined_text, "Do not ask again") != null);
}

test "guidance: forbids asking what can be read" {
    // It is the rule that gives the most value and the easiest to lose in a rewrite.
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "do NOT ask what you can read") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "three in a whole turn") != null);
}

test "guidance: `ask` is for decisions, not for progress reports or sign-off" {
    // The two failure modes that turn `ask` from useful into a nuisance, and both are
    // invisible to a model that has only been told what `ask` is FOR.
    //
    // The second one is the worse of the two and it took a rule to say out loud: a
    // model that asks "does this look right?" before finishing hands the work back to
    // the user, and a user who gets asked to confirm learns to press enter without
    // reading. The question then means nothing and costs a turn to mean nothing.
    //
    // The third rule is the same idea one level in: "whatever you think is right" is
    // the model's own decision, and asking it gives the decision away instead of
    // taking it.
    //
    // Each needle is a fragment that does NOT cross a `\\` line break, which is the
    // trap this file has already documented: the continuation joins the lines but KEEPS
    // the next line's indentation, so a phrase written across two lines is not in the
    // string at all — it is "hand back\n   work". The first version of this test
    // searched for "you could have finished" and failed on a rule that was present.
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "Do NOT use it to report progress") != null);
    // "anything else is your job" is split across the wrap above ("…; anything" /
    // "else is your job…"), so the needle is the half that is really in the string.
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "else is your job") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "press enter without reading") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "whatever you think is right") != null);
}

test "the YOLO texts: the taken one names the option, the open one names the summary" {
    var buf: [ask.yolo_buf_len]u8 = undefined;

    // The taken one: the option is IN the text (the model has to know what
    // was taken) and the summary is asked for.
    const taken = ask.formatYoloTaken(&buf, "postgres (recommended)");
    try std.testing.expect(std.mem.indexOf(u8, taken, "postgres (recommended)") != null);
    try std.testing.expect(std.mem.indexOf(u8, taken, "Nobody was asked") != null);
    try std.testing.expect(std.mem.indexOf(u8, taken, "final summary") != null);

    // The open one: the question is NOT repeated. The model wrote it, it is in
    // its context already, and repeating 600 characters to say "still open" is
    // the user's tokens for nothing.
    const open = ask.formatYoloDeferred(&buf);
    try std.testing.expect(std.mem.indexOf(u8, open, "stays OPEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "final summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "Do not ask again") != null);
}

test "the decision: only YOLO skips the question, and only with options is there something to take" {
    try std.testing.expectEqual(ask.Decision.ask, ask.decide(false, true));
    try std.testing.expectEqual(ask.Decision.ask, ask.decide(false, false));
    // With options there IS a recommendation to take (the schema tells the
    // model to put it first).
    try std.testing.expectEqual(ask.Decision.take_recommendation, ask.decide(true, true));
    // Without options there is nothing to take: the question stays open.
    try std.testing.expectEqual(ask.Decision.leave_open, ask.decide(true, false));
}
