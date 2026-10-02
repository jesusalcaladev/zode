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
    \\
    \\How to ask:
    \\ - Put your recommendation FIRST and say why in the question text, so the
    \\   user can just press enter.
    \\ - Use `options` when the choices are enumerable (2 to 5). Use no options
    \\   when the answer is free text (a name, a path, a yes/no with a nuance).
    \\ - `header` is a 2-3 word label for the dialog, not the question.
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

test "parse: question obligatoria y con espacios limpios" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const q = try ask.parse(ast.allocator(),
        \\{"question":"  Which approach?  "}
    );
    try std.testing.expectEqualStrings("Which approach?", q.question);
    try std.testing.expectEqual(@as(usize, 0), q.options.len);
    try std.testing.expectEqualStrings("", q.header);
}

test "parse: options como array de strings, con header" {
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

test "parse: sin question es BadQuestion, no un crash" {
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

test "parse: mas de max_options se rechaza en vez de recortar en silencio" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    const a = ast.allocator();
    try std.testing.expectError(error.TooManyOptions, ask.parse(a,
        \\{"question":"q","options":["1","2","3","4","5","6"]}
    ));
    // Justo el tope entra.
    const q = try ask.parse(a,
        \\{"question":"q","options":["1","2","3","4","5"]}
    );
    try std.testing.expectEqual(@as(usize, 5), q.options.len);
}

test "parse: option vacia se rechaza (una opcion invisible no es una opcion)" {
    var ast = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast.deinit();
    try std.testing.expectError(error.EmptyOption, ask.parse(ast.allocator(),
        \\{"question":"q","options":["a","  ","b"]}
    ));
}

test "parse: options que no son strings es BadOptions" {
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

test "parse: question larguisima se corta y header tambien" {
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

test "formatAnswered: el prefijo separa la voz del usuario de la del modelo" {
    const a = ask.formatAnswered("usa el parser nuevo");
    try std.testing.expectEqualStrings("The user answered: usa el parser nuevo", a.slice());
}

test "formatAnswered: una respuesta larguisima se corta Y se dice" {
    // Lo unico que no puede pasar aqui es cortar la respuesta del usuario en
    // silencio: el modelo actua sobre media instruccion y queda seguro de ella.
    var big: [4096]u8 = @splat('z');
    const a = ask.formatAnswered(&big);
    try std.testing.expect(a.slice().len <= a.buf.len);
    try std.testing.expect(std.mem.startsWith(u8, a.slice(), "The user answered: "));
    try std.testing.expect(std.mem.endsWith(u8, a.slice(), "(truncated)"));
}

test "formatAnswered: una respuesta que cabe no lleva marcador" {
    // El marcador de corte es ruido si no hubo corte: el modelo podria leer
    // "truncated" como una instruccion suya.
    const a = ask.formatAnswered("vale, vamos con el parser nuevo");
    try std.testing.expect(std.mem.indexOf(u8, a.slice(), "truncated") == null);
}

test "formatAnswered: espacios alrededor se van" {
    const a = ask.formatAnswered("  sí, con el parser  \n");
    try std.testing.expectEqualStrings("The user answered: sí, con el parser", a.slice());
}

test "decline y timeout le dicen al modelo que decida, no que pare" {
    // Las dos frases tienen que cumplir dos cosas: no dicen "stop" (que el
    // modelo interpretaria como permiso para abandonar) y si contienen la
    // instruccion de elegir, que es lo unico util que puede hacer con un no.
    try std.testing.expect(std.mem.indexOf(u8, ask.declined_text, "Pick the most reasonable") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask.timed_out_text, "Pick the most reasonable") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask.declined_text, "Do not ask again") != null);
}

test "guidance: prohibe preguntar lo que se puede leer" {
    // Es la regla que mas valor da y la mas facil de perder en una reescritura.
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "do NOT ask what you can read") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "three in a whole turn") != null);
}
