//! Cliente de ACP (Agent Client Protocol v1) sobre stdio, para hablar con
//! `opencode acp` sin pasar por su terminal.
//!
//! ## Que es esto
//!
//! `opencode acp` es un AGENTE ACP: el cliente lo lanza como proceso hijo y le
//! habla JSON-RPC delimitado por saltos de linea por stdin/stdout. No es la TUI
//! (esa no tiene API) sino el mismo motor de opencode, y trae lo que nos
//! interesa: sesiones, streaming de texto y tool calls, peticiones de permiso y
//! uso de tokens. Ver <https://opencode.ai/v2/docs/cli/acp/>.
//!
//! Es la "trampa por detras" de verdad: zode no manda teclas a la terminal de
//! opencode, zode le habla a opencode.
//!
//! ## Decisiones que no son obvias
//!
//! - **El proceso hijo es global y vive entre turnos.** La sesion (y su
//!   contexto) esta en el proceso, no en zode: si se creara uno por turno cada
//!   prompt seria una sesion nueva y no habria memoria. Se arranca perezoso la
//!   primera vez y se reutiliza.
//! - **`Client` se aloca en el heap y NUNCA se copia por valor.** El
//!   `Io.File.Reader` guarda un puntero a su buffer, que vive DENTRO del
//!   struct: moverlo deja el puntero colgando (el mismo bug que el `File.Writer`
//!   de `session.zig`).
//! - **Las lineas se leen a mano, sin `takeDelimiter`.** `takeDelimiter` da
//!   `error.StreamTooLong` si la linea no cabe en el buffer del reader, y un
//!   `tool_call_update` con un volcado de 300 KB lo revienta. Aqui se acumula en
//!   un `ArrayList` que crece y no hay limite artificial.
//! - **stderr del hijo = `.ignore`.** Es un hijo dentro de una TUI: si escribiera
//!   en nuestro terminal el banner y el historial se llenarian de logs. Para
//!   diagnosticar esta `opencode --print-logs acp`.
//! - **Se anuncian capacidades de cliente MINIMAS** (sin `fs` ni `terminal`):
//!   opencode ejecuta sus propias tools, no necesita que se las prestemos, y
//!   asi no llega ninguna peticion que no sepamos responder. Aun asi, lo que no
//!   sepamos hacer se responde con "method not found": si no, el turno no acaba.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const config = @import("config.zig");

/// Version del protocolo que hablamos.
pub const protocol_version = 1;

/// El agente se identifica con esto en el `initialize`.
pub const client_name = "zode";
pub const client_version = "0.3";

/// Comando por defecto. Se puede cambiar con `ZODE_ACP_CMD` (palabras
/// separadas por espacios) para probar otro agente ACP.
pub const default_argv = [_][]const u8{ "opencode", "acp" };

/// JSON-RPC "method not found", para lo que no sabemos hacer.
const code_method_not_found = -32601;

/// Una siesta de `ms` milisegundos SIN tocar el `Io` compartido.
///
/// Ver el comentario de `waitTurn`: `Io.sleep` secuestra el bucle de eventos y
/// congela la TUI. `nanosleep` es una syscall y no molesta a nadie.
///
/// Es `pub` porque el agente también la usa mientras espera a que el hilo de
/// conexión termine.
pub fn nap(ms: u64) void {
    if (builtin.os.tag != .linux) return;
    const ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// ¿Es `path` un fichero ejecutable?
///
/// `std.posix` no expone `faccessat` en 0.16 y `Io.Dir.access` necesita un
/// `Io` (que aquí no tenemos: `resolveArgv` corre antes de tener el del
/// llamante en la mano). Se llama al `access(2)` de libc, que es exactamente
/// lo mismo y no añade dependencia: `std.c` es parte del std.
fn isExecutable(io: Io, path: []const u8) bool {
    // NO se usa `std.c.access`: eso ata el binario a libc, y zode es libc-free
    // a propósito (permite target musl). Se mira el bit de ejecutable del modo,
    // que es lo mismo que `X_OK` comprueba, y además que sea un fichero: un
    // DIRECTORIO con el nombre del binario tiene el bit de x puesto y no vale.
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (st.kind == .directory) return false;
    // `permissions` es un enum del `mode_t`: los tres bits de ejecutable
    // (dueño, grupo, resto) son 0o111, igual que en `X_OK`.
    const mode: u32 = @intCast(@intFromEnum(st.permissions));
    return mode & 0o111 != 0;
}

/// Rellena `out` con el argv y `argv[0]` resuelto a una ruta ABSOLUTA, y
/// devuelve el slice. Si no se puede resolver, devuelve `argv` tal cual (que
/// alors sea `spawn` el que falle con su propio error).
///
/// `std.process.spawn` busca en el PATH del `Io`, que no tiene por qué ser el
/// entorno de zode: con un `Threaded` hecho a mano sale `FileNotFound` aunque
/// el binario esté en el PATH de la shell (pasó con la sonda). Aquí se busca en
/// el `PATH` del mapa que pasa el llamante y se ejecuta una ruta absoluta, que
/// `spawn` no necesita buscar.
///
/// `out` y `path_buf` son buffers del llamante porque lo que se devuelve son
/// slices a ellos: devolverlos desde aquí sería un puntero al stack de esta
/// función.
fn resolveArgv(
    io: Io,
    env: ?*const std.process.Environ.Map,
    argv: []const []const u8,
    out: [][]const u8,
    path_buf: []u8,
) []const []const u8 {
    if (argv.len == 0 or argv.len > out.len) return argv;
    // Con '/' ya es una ruta: `spawn` la ejecuta tal cual.
    if (std.mem.indexOfScalar(u8, argv[0], '/') != null) return argv;
    const map = env orelse return argv;
    const path_s = map.get("PATH") orelse return argv;

    var it = std.mem.splitScalar(u8, path_s, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(path_buf, "{s}/{s}", .{ dir, argv[0] }) catch continue;
        // Que sea EJECUTABLE, no solo que exista: un directorio con el nombre
        // del binario no vale. `std.posix` no expone `faccessat`, así que se
        // usa el `access(2)` de libc vía `std.c`, que en Linux es lo mismo.
        if (!isExecutable(io, full)) continue;

        @memcpy(out[0..argv.len], argv);
        out[0] = full;
        return out[0..argv.len];
    }
    return argv;
}

pub const Error = error{
    /// El comando no se pudo lanzar (no hay `opencode` en el PATH).
    SpawnFailed,
    /// El agente no respondió al `initialize` o al `session/new`.
    HandshakeFailed,
    /// Se mandó un prompt sin sesión.
    NoSession,
    /// El hijo se cerró en mitad de un turno.
    AgentDied,
} || std.mem.Allocator.Error || Io.Cancelable;

/// Una opción de permiso que ofrece el agente.
pub const PermOption = struct {
    id: []const u8,
    name: []const u8,
    /// `allow_once` | `allow_always` | `reject_once` | `reject_always`.
    kind: []const u8,
};

/// Dónde caen los eventos del turno. Todo tiene no-op por defecto para que un
/// test pueda declarar solo lo que le interesa.
pub const Sink = struct {
    userdata: ?*anyopaque = null,
    onText: *const fn (?*anyopaque, []const u8) void = noopText,
    onThought: *const fn (?*anyopaque, []const u8) void = noopText,
    /// Tool nueva: se pinta su cabecera.
    onTool: *const fn (?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void = noopTool,
    /// La tool cambia de estado (`in_progress`/`completed`/`failed`).
    onToolUpdate: *const fn (?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void = noopToolUpdate,
    /// Una línea del plan del agente.
    onPlan: *const fn (?*anyopaque, []const u8) void = noopText,
    /// Petición de permiso: devuelve el `optionId` elegido o null para cancelar.
    /// Se llama desde el hilo del worker, asi que puede bloquear (el diálogo de
    /// permisos de zode ya bloquea al worker por diseño).
    onPermission: ?*const fn (?*anyopaque, tool: []const u8, detail: []const u8, options: []const PermOption) ?[]const u8 = null,
};

fn noopText(_: ?*anyopaque, _: []const u8) void {}
fn noopTool(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}
fn noopToolUpdate(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}

/// Herramienta recordada por su id: ACP manda el id en las actualizaciones, no
/// el nombre, y sin esto el `pushToolDone` saldría sin saber qué tool cerró.
const ToolMemo = struct {
    id: [64]u8 = undefined,
    id_len: usize = 0,
    name: [48]u8 = undefined,
    name_len: usize = 0,

    fn eqlId(self: ToolMemo, id: []const u8) bool {
        return self.id_len == id.len and std.mem.eql(u8, self.id[0..self.id_len], id);
    }
};

/// Qué respuesta estamos esperando del hijo.
const Wait = enum { none, init, new_session, prompt };

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    child: std.process.Child,
    stdin: Io.File,

    /// Buffer del reader. El `Reader` guarda un puntero a ESTE array, así que
    /// el struct no se puede mover (ver la nota de más arriba).
    out_buf: [64 * 1024]u8 = undefined,
    reader: Io.File.Reader,

    /// Línea en curso. Puede crecer sin límite (ver la nota de más arriba).
    line: std.ArrayList(u8) = .empty,
    /// Buffer para serializar un mensaje antes de mandarlo.
    send_buf: [128 * 1024]u8 = undefined,

    next_id: i64 = 1,
    wait_id: i64 = 0,
    waiting: Wait = .none,

    session: [128]u8 = undefined,
    session_len: usize = 0,
    agent_name: [64]u8 = undefined,
    agent_name_len: usize = 0,
    stop_reason: [32]u8 = undefined,
    stop_len: usize = 0,
    /// Último `error.message` que mandó el agente, para poder enseñarlo.
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,

    /// Escribir al stdin necesita lock (el `Mutex` de Zig no es reentrante y
    /// aquí se coge una sola vez por escritura).
    wlock: std.atomic.Mutex = .unlocked,

    /// La UI ha pedido cortar el turno. Lo pone `cancel()` desde el hilo del
    /// dibujo; lo lee y atiende el worker, que es el único que escribe.
    cancel_requested: std.atomic.Value(bool) = .init(false),
    cancel_sent: bool = false,
    would_block_count: usize = 0,

    tools: [64]ToolMemo = undefined,
    tools_len: usize = 0,

    pub fn sessionId(self: *const Client) []const u8 {
        return self.session[0..self.session_len];
    }

    pub fn agentTitle(self: *const Client) []const u8 {
        if (self.agent_name_len == 0) return "acp";
        return self.agent_name[0..self.agent_name_len];
    }

    pub fn stopReason(self: *const Client) []const u8 {
        return self.stop_reason[0..self.stop_len];
    }

    /// El último error que mandó el agente (vacío si no hubo).
    pub fn lastError(self: *const Client) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    pub fn toolName(self: *const Client, id: []const u8) []const u8 {
        // OJO: con `for (self.tools[0..len]) |memo|` el `memo` es una COPIA del
        // struct, y `memo.name[0..n]` apunta a esa copia de stack: al salir del
        // bucle el slice queda colgando y devuelve basura. Por eso el índice.
        for (self.tools[0..self.tools_len], 0..) |*memo, i| {
            if (memo.eqlId(id)) return self.tools[i].name[0..memo.name_len];
        }
        return "";
    }

    // ── arranque ──────────────────────────────────────────────

    /// Lanza el agente, hace `initialize` y abre una sesión en `cwd`.
    ///
    /// `argv_override` es el resultado de partir `ZODE_ACP_CMD`; si es null se
    /// usa `default_argv`. `env` se usa para resolver el ejecutable por el
    /// PATH (ver `resolveArgv`).
    pub fn start(
        gpa: std.mem.Allocator,
        io: Io,
        argv_override: ?[]const []const u8,
        cwd: []const u8,
        env: ?*const std.process.Environ.Map,
    ) !*Client {
        const argv = argv_override orelse &default_argv;
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .child = undefined,
            .stdin = undefined,
            .reader = undefined,
        };
        errdefer self.line.deinit(gpa);

        // El `Io` resuelve el PATH con SU entorno, que no siempre es el de
        // zode (un `Threaded` de pruebas, por ejemplo, no lo tiene). Con un
        // argv[0] sin '/', `spawn` da FileNotFound aunque el binario esté
        // ahí. Se resuelve aquí contra el mapa que nos pasa el llamante.
        // Los dos buffers son del stack de `start` a PROPÓSITO: `resolveArgv`
        // devuelve slices que apuntan a ellos, y `spawn` los consume antes de
        // que `start` devuelva.
        var resolved_argv: [8][]const u8 = undefined;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const argv_final = resolveArgv(io, env, argv, &resolved_argv, &path_buf);

        self.child = std.process.spawn(io, .{
            .argv = argv_final,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.SpawnFailed;
        // Si algo falla después, el hijo no se puede quedar huérfano.
        errdefer self.child.kill(io);

        self.stdin = self.child.stdin.?;
        // El pipe de lectura va en NO-BLOQUEANTE a propósito: el bucle de `pump`
        // duerma entre mensajes en vez de clavarse, y así puede mirar la
        // bandera de cancelar y mandar `session/cancel` aunque el agente esté
        // en silencio. Un read bloqueante dejaría al worker esperando hasta que
        // el agente hablara, que es justo cuando hace falta poder cortar.
        //
        // OJO: poner `flags.nonblocking = true` en el `File` NO pone el
        // descriptor en O_NONBLOCK. Ese campo solo lo mira la ruta de Windows;
        // en POSIX `read()` se hace tal cual y con el fd bloqueante se queda
        // clavado para siempre (que es lo que pasaba: el turno se colgaba en el
        // segundo read). Hay que hacer el `fcntl` de verdad.
        var out_file = self.child.stdout.?;
        out_file.flags.nonblocking = true;
        if (builtin.os.tag == .linux) {
            // `fcntl` devuelve el resultado crudo: los errores vienen
            // codificados como valores enormes, así que "ha ido bien" es que
            // quepa en 32 bits. (Al revés que un error de return: un GETFL
            // bueno es un número PEQUEÑO, 0x44000 y poco.)
            const fl = std.os.linux.fcntl(out_file.handle, std.posix.F.GETFL, 0);
            if (fl <= std.math.maxInt(u32)) {
                const want = fl | (1 << @bitOffsetOf(std.os.linux.O, "NONBLOCK"));
                _ = std.os.linux.fcntl(out_file.handle, std.posix.F.SETFL, want);
            }
        }
        self.reader = out_file.readerStreaming(io, &self.out_buf);

        try self.sendInitialize();
        try self.awaitHandshake(.init);
        try self.sendNewSession(cwd);
        try self.awaitHandshake(.new_session);
        if (self.session_len == 0) return error.HandshakeFailed;
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.child.kill(self.io);
        self.line.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    // ── envío ─────────────────────────────────────────────────

    fn write(self: *Client, bytes: []const u8) !void {
        // `std.atomic.Mutex` es un SPINLOCK (no tiene `lock`), y no puede
        // reentrarse. Aquí solo se coge para una escritura corta, asi que
        // esperar con `yield` es suficiente.
        while (!self.wlock.tryLock()) std.Thread.yield() catch {};
        defer self.wlock.unlock();
        try self.stdin.writeStreamingAll(self.io, bytes);
    }

    fn takeId(self: *Client) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn sendInitialize(self: *Client) !void {
        self.wait_id = self.takeId();
        self.waiting = .init;
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{" ++
                "\"protocolVersion\":{d},\"clientCapabilities\":{{}}," ++
                "\"clientInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}}}}}}\n",
            .{ self.wait_id, protocol_version, client_name, client_version },
        );
        try self.write(w.buffered());
    }

    fn sendNewSession(self: *Client, cwd: []const u8) !void {
        self.wait_id = self.takeId();
        self.waiting = .new_session;
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/new\",\"params\":{{\"cwd\":",
            .{self.wait_id},
        );
        try config.writeJsonString(&w, undefined, cwd);
        try w.writeAll(",\"mcpServers\":[]}}\n");
        try self.write(w.buffered());
    }

    /// Pide cortar el turno. Se puede llamar desde CUALQUIER hilo (la UI lo hace
    /// con ESC) y NO toca el `Io`: solo pone una bandera.
    ///
    /// OJO: aquí NO se escribe el `session/cancel` directamente. Escribir en el
    /// pipe desde otro hilo mientras el worker está bloqueado leyendo con el
    /// MISMO `Io` lo rompe: el hijo se muere y el turno acaba con AgentDied sin
    /// haber llegado a cancelar nada. El `Io` de Zig no está pensado para que
    /// dos hilos lo usen a la vez. Lo escribe el worker, que es su dueño, al
    /// ver la bandera (ver `pump`).
    pub fn cancel(self: *Client) void {
        self.cancel_requested.store(true, .seq_cst);
    }

    fn sendCancel(self: *Client) void {
        if (self.session_len == 0) return;
        var buf: [256]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":") catch return;
        config.writeJsonString(&w, undefined, self.sessionId()) catch return;
        w.writeAll("}}\n") catch return;
        self.cancel_sent = true;
        self.write(w.buffered()) catch {};
    }

    // ── prompt ────────────────────────────────────────────────

    /// Manda un prompt de texto al agente. Los eventos van saliendo por el
    /// `sink` de `waitTurn`.
    pub fn prompt(self: *Client, text: []const u8) !void {
        if (self.session_len == 0) return error.NoSession;
        self.wait_id = self.takeId();
        self.waiting = .prompt;
        self.stop_len = 0;

        var w = Io.Writer.fixed(&self.send_buf);
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/prompt\",\"params\":{{\"sessionId\":", .{self.wait_id});
        try config.writeJsonString(&w, undefined, self.sessionId());
        try w.writeAll(",\"prompt\":[{\"type\":\"text\",\"text\":");
        try config.writeJsonString(&w, undefined, text);
        try w.writeAll("}]}}\n");
        try self.write(w.buffered());
    }

    /// Lee y reparte hasta que el turno acaba. Devuelve el `stopReason`.
    ///
    /// El pipe de la salida del hijo está en NO-BLOQUEANTE, así que el bucle
    /// duerme un momento entre lecturas. Eso es lo que permite que la UI
    /// cancele el turno sin escribir en el `Io` desde otro hilo (ver `cancel`).
    pub fn waitTurn(self: *Client, sink: *const Sink) ![]const u8 {
        while (self.waiting == .prompt) {
            if (self.cancel_requested.load(.seq_cst) and !self.cancel_sent) self.sendCancel();
            const got = try self.pump(sink);
            if (got == .line) continue;
            if (got == .would_block) {
                // 30 ms es imperceptible y no quema CPU (es el mismo orden que el
                // tick de 40 ms del spinner).
                //
                // OJO: `io.sleep` y no un `std.Thread.sleep` cualquiera. Este
                // proceso tiene UN SOLO `Io` compartido entre el worker y el
                // hilo de la UI, y `Io.sleep` se queda con el bucle de eventos
                // del `Io`: el worker dormido dejaba de disparar el `tick` del
                // spinner y la TUI se congelaba con el reloj clavado (justo lo
                // que se vera en pantalla). Con `nanosleep` es una syscall
                // pelada que no toca el `Io`.
                nap(30);
                continue;
            }
            return error.AgentDied; // el hijo se cerró
        }
        return self.stopReason();
    }

    // ── lectura ───────────────────────────────────────────────

    /// Qué pasó al leer un mensaje del hijo.
    pub const Pump = enum { line, would_block, eof };

    /// Lee mensajes hasta que llega la respuesta que esperamos.
    /// `sink` puede ser null durante el handshake (aun no hay nada que
    /// mostrar).
    pub fn pump(self: *Client, sink: ?*const Sink) !Pump {
        const got = switch (try self.readLine()) {
            .would_block => return .would_block,
            .eof => return .eof,
            .line => |l| l,
        };
        // `defer`, y no un `clear` al final: hay VARIOS `return .line`
        // intermedios (línea vacía, JSON inválido, notificación) y con el
        // clear solo al final `self.line` se quedaba con el texto anterior. La
        // línea siguiente salía con la anterior PEGADA, el parse fallaba, y el
        // bucle se comía su propia cola: cuelgue total tras el primer mensaje.
        //
        // OJO: el `defer` corre al SALIR de pump, después de los callbacks, que
        // es justo cuando el texto deja de hacer falta.
        defer self.line.clearRetainingCapacity();
        var line = got;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) return .line;

        var astate = std.heap.ArenaAllocator.init(self.gpa);
        defer astate.deinit();
        const arena = astate.allocator();

        const val = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return .line;
        if (val != .object) return .line;
        const root = val.object;

        const id = intOf(root.get("id"));

        if (root.get("method")) |mv| {
            const method = strOf(mv);
            // Petición del agente hacia nosotros (permisos, fs, terminal).
            if (id) |req_id| {
                try self.handleRequest(req_id, method, root, sink);
            } else {
                try self.handleNotification(method, root, sink);
            }
            return .line;
        }

        // Respuesta a algo nuestro.
        //
        // OJO: aquí NO vale `root.get("method") orelse return true`. Las
        // respuestas NO llevan `method`, así que ese `orelse` se comía el
        // `initialize` entero y el handshake se quedaba para siempre esperando
        // una respuesta que ya había llegado (y sin pintar nada, que es lo
        // que hace que un deadlock así sea tan difícil de ver).
        if (id) |resp_id| {
            if (resp_id != self.wait_id) return .line;
            if (root.get("error")) |e| {
                // El mensaje del server es lo único útil: "HTTP 500" no dice
                // nada, "model not found" sí.
                var buf: [512]u8 = undefined;
                const msg = blk: {
                    const m = strField(e.object, "message");
                    if (m.len == 0) break :blk "";
                    break :blk std.fmt.bufPrint(&buf, "{s}", .{m}) catch "";
                };
                self.last_error_len = 0;
                if (msg.len > 0) {
                    const n = @min(msg.len, self.last_error.len);
                    @memcpy(self.last_error[0..n], msg[0..n]);
                    self.last_error_len = n;
                }
                self.waiting = .none;
                return error.AgentDied;
            }
            if (root.get("result")) |res| {
                self.takeResult(resp_id, res);
            } else {
                self.waiting = .none;
            }
        }
        return .line;
    }

    /// Espera la respuesta del handshake. El pipe es NO-bloqueante, así que
    /// entre mensajes hay que dormir un poco. Con tope: si el agente no contesta
    /// en ~2 min, mejor un error claro que un cuelgue.
    fn awaitHandshake(self: *Client, kind: Wait) !void {
        var spins: usize = 0;
        while (self.waiting == kind) {
            spins += 1;
            if (spins > 4000) return error.HandshakeFailed;
            switch (try self.pump(null)) {
                .line => {},
                .would_block => nap(30),
                .eof => return error.HandshakeFailed,
            }
        }
    }

    fn takeResult(self: *Client, id: i64, res: std.json.Value) void {
        if (id != self.wait_id) return;
        if (res != .object) {
            self.waiting = .none;
            return;
        }
        switch (self.waiting) {
            .init => {
                // El `initialize` es la unica respuesta con `agentInfo`: nos dice
                // como se llama el agente, que es lo que se enseña en el status.
                if (res.object.get("agentInfo")) |ai| {
                    if (ai == .object) {
                        const nm = strField(ai.object, "name");
                        const n = @min(nm.len, self.agent_name.len);
                        @memcpy(self.agent_name[0..n], nm[0..n]);
                        self.agent_name_len = n;
                    }
                }
            },
            .new_session => {
                const s = strField(res.object, "sessionId");
                if (s.len > 0) {
                    const n = @min(s.len, self.session.len);
                    @memcpy(self.session[0..n], s[0..n]);
                    self.session_len = n;
                }
            },
            .prompt => {
                const r = strField(res.object, "stopReason");
                const n = @min(r.len, self.stop_reason.len);
                @memcpy(self.stop_reason[0..n], r[0..n]);
                self.stop_len = n;
            },
            else => {},
        }
        self.waiting = .none;
    }

    fn handleNotification(self: *Client, method: []const u8, root: std.json.ObjectMap, sink: ?*const Sink) !void {
        if (!std.mem.eql(u8, method, "session/update")) return;
        const s = sink orelse return;
        const params = root.get("params") orelse return;
        const upd = params.object.get("update") orelse return;
        const kind = strOf(upd.object.get("sessionUpdate") orelse return);

        if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            if (textOf(upd.object.get("content") orelse return)) |t| s.onText(s.userdata, t);
        } else if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
            if (textOf(upd.object.get("content") orelse return)) |t| s.onThought(s.userdata, t);
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            const id = strOf(upd.object.get("toolCallId") orelse return);
            const name = strField(upd.object, "name");
            const title = strField(upd.object, "title");
            self.rememberTool(id, name);
            s.onTool(s.userdata, id, name, title);
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const id = strOf(upd.object.get("toolCallId") orelse return);
            const status = strField(upd.object, "status");
            var buf: [4096]u8 = undefined;
            s.onToolUpdate(s.userdata, id, status, updateText(upd.object, &buf));
        } else if (std.mem.eql(u8, kind, "plan")) {
            const entries = upd.object.get("entries") orelse return;
            if (entries != .array) return;
            for (entries.array.items) |e| {
                const c = strField(e.object, "content");
                if (c.len > 0) {
                    if (c.len > 0) s.onPlan(s.userdata, c);
                }
            }
        }
    }

    fn handleRequest(self: *Client, id: i64, method: []const u8, root: std.json.ObjectMap, sink: ?*const Sink) !void {
        if (std.mem.eql(u8, method, "session/request_permission")) {
            try self.handlePermission(id, root, sink);
            return;
        }
        // `fs/*`, `terminal/*`, `elicitation/*`…: no las anunciamos, pero si
        // llegan hay que responder algo o el turno no acaba nunca.
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":", .{
            id,
            code_method_not_found,
        });
        try config.writeJsonString(&w, undefined, method);
        try w.writeAll("}}}\n");
        try self.write(w.buffered());
    }

    fn handlePermission(self: *Client, id: i64, root: std.json.ObjectMap, sink: ?*const Sink) !void {
        const params = root.get("params") orelse return self.respondCancelled(id);
        const pobj = params.object;
        const tc = pobj.get("toolCall");
        const tool: []const u8 = if (tc) |v| strField(v.object, "title") else "";
        const detail: []const u8 = if (tc) |v| rawInputText(v.object.get("rawInput") orelse return self.respondCancelled(id)) else "";

        var opts: [8]PermOption = undefined;
        var n: usize = 0;
        if (pobj.get("options")) |o| {
            if (o == .array) {
                for (o.array.items) |item| {
                    if (n >= opts.len) break;
                    opts[n] = .{
                        .id = strField(item.object, "optionId"),
                        .name = strField(item.object, "name"),
                        .kind = strField(item.object, "kind"),
                    };
                    n += 1;
                }
            }
        }
        const list = opts[0..n];

        const cb = if (sink) |s| s.onPermission else null;
        if (cb) |f| {
            if (f(sink.?.userdata, tool, detail, list)) |choice| {
                return self.respondSelected(id, choice);
            }
            return self.respondCancelled(id);
        }
        // Sin nadie que pregunte (tests, o un turno sin UI): la primera opción
        // "allow" es lo razonable, y si no hay, se cancela.
        for (list) |o| {
            if (std.mem.startsWith(u8, o.kind, "allow")) return self.respondSelected(id, o.id);
        }
        return self.respondCancelled(id);
    }

    fn respondSelected(self: *Client, id: i64, option_id: []const u8) !void {
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":", .{id});
        try config.writeJsonString(&w, undefined, option_id);
        try w.writeAll("}}}}}\n");
        try self.write(w.buffered());
    }

    fn respondCancelled(self: *Client, id: i64) !void {
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"outcome\":{{\"outcome\":\"cancelled\"}}}}}}\n", .{id});
        try self.write(w.buffered());
    }

    fn rememberTool(self: *Client, id: []const u8, name: []const u8) void {
        for (self.tools[0..self.tools_len]) |memo| {
            if (memo.eqlId(id)) return; // ya la conocemos
        }
        if (self.tools_len >= self.tools.len) return;
        var memo = &self.tools[self.tools_len];
        const ni = @min(id.len, memo.id.len);
        @memcpy(memo.id[0..ni], id[0..ni]);
        memo.id_len = ni;
        const nn = @min(name.len, memo.name.len);
        @memcpy(memo.name[0..nn], name[0..nn]);
        memo.name_len = nn;
        self.tools_len += 1;
    }

    /// Resultado de intentar leer una línea del hijo.
    pub const Line = union(enum) {
        /// Línea completa, en `self.line.items` (válida hasta el próximo pump).
        line: []const u8,
        /// No hay datos AHORA MISMO. Es el caso normal entre heartbeats.
        would_block,
        /// El hijo cerró el pipe.
        eof,
    };

    /// Una línea del hijo, acumulada a mano.
    ///
    /// El `readLine` del Reader no vale: da `error.StreamTooLong` si la línea no
    /// cabe en su buffer, y aquí las líneas son updates de tools que pueden
    /// traer un volcado entero. Se lee el buffer a mano y se crece.
    ///
    /// El pipe está en NO-BLOQUEANTE (ver `start`): si no hay datos se devuelve
    /// `would_block` para que el llamante duerma y mire la bandera de cancelar.
    /// Un read bloqueante dejaría al worker clavado y el ESC no podría hacer
    /// nada hasta que el agente volviera a hablar.
    ///
    /// OJO: `self.line` NO se limpia al entrar. Una línea a medias se queda
    /// acumulada entre llamadas, y el que la limpia (al terminar de leerla) es
    /// `pump`. Si se limpiara aquí, un `would_block` a mitad de línea perdería
    /// lo leído y la línea nunca se cerraría.
    fn readLine(self: *Client) !Line {
        while (true) {
            const r = &self.reader.interface;
            const rest = r.buffer[r.seek..r.end];
            if (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
                try self.line.appendSlice(self.gpa, rest[0..i]);
                r.toss(i + 1);
                return .{ .line = self.line.items };
            }
            try self.line.appendSlice(self.gpa, rest);
            r.toss(rest.len);
            const before = r.end;
            r.fillMore() catch |err| switch (err) {
                // El `Reader` de fichero se COME el `WouldBlock` y lo convierte
                // en `ReadFailed`, dejando el error de verdad en
                // `self.reader.err` (el `err` del `Io.Reader` de dentro es otra
                // cosa). Por eso no se mira el error que devuelve, sino el que
                // guardó.
                error.ReadFailed => {
                    if (self.reader.err != null and self.reader.err.? == error.WouldBlock) {
                        return .would_block;
                    }
                    return err;
                },
                else => return err,
            };
            if (r.end == before) {
                // EOF: lo que quedara sin newline se devuelve igual.
                if (self.line.items.len == 0) return .eof;
                return .{ .line = self.line.items };
            }
        }
    }
};

// ── helpers de JSON ──────────────────────────────────────────

/// Campo de texto de un objeto, o "" si no está / no es string.
///
/// OJO: `obj.get(k) orelse ""` NO compila, porque el `orelse` devuelve un
/// `json.Value` y "" es un `[]const u8`. De ahí este helper.
fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return strOf(v);
}

fn strOf(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn intOf(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// Texto de un `ContentBlock`, o null si no es de texto.
fn textOf(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    if (!std.mem.eql(u8, strOf(v.object.get("type") orelse return null), "text")) return null;
    return strOf(v.object.get("text") orelse return null);
}

/// `rawInput` es `unknown`: si es un objeto con `command`/`file_path` se
///Sacale eso, si es una cadena se usa tal cual, y si no, nada.
fn rawInputText(v: std.json.Value) []const u8 {
    switch (v) {
        .string => |s| return s,
        .object => |o| {
            for ([_][]const u8{ "command", "file_path", "path", "pattern" }) |k| {
                const found = strField(o, k);
                if (found.len > 0) return found;
            }
            return "";
        },
        else => return "",
    }
}

/// El texto de una actualización de tool: primero el `content` normal y, si no
/// hay, el `rawOutput`.
fn updateText(upd: std.json.ObjectMap, buf: []u8) []const u8 {
    if (upd.get("content")) |c| {
        if (c == .array) {
            var w = Io.Writer.fixed(buf);
            for (c.array.items) |item| {
                const inner = if (item == .object and
                    std.mem.eql(u8, strField(item.object, "type"), "content"))
                    item.object.get("content")
                else
                    item;
                const t = if (inner) |v| textOf(v) else null;
                if (t) |txt| {
                    if (w.buffered().len > 0) w.writeAll("\n") catch break;
                    w.writeAll(txt) catch break;
                }
            }
            if (w.buffered().len > 0) return w.buffered();
        }
    }
    if (upd.get("rawOutput")) |ro| {
        if (textOf(ro)) |t| return t;
    }
    return "";
}

// ── tests ────────────────────────────────────────────────────

const testing = std.testing;

/// Reparte una línea por el MISMO camino que el cliente real, sin proceso
/// hijo: es lo que permite testear el parseo con updates capturados.
fn feedLine(c: *Client, sink: *const Sink, line: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const val = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    try c.handleNotification(strOf(val.object.get("method") orelse return), val.object, sink);
}

fn testClient() Client {
    return .{ .gpa = testing.allocator, .io = undefined, .child = undefined, .stdin = undefined, .reader = undefined };
}

test "los chunks de texto llegan al sink en orden" {
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    const Ctx = struct {
        fn onText(ud: ?*anyopaque, text: []const u8) void {
            const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ud.?));
            l.appendSlice(testing.allocator, text) catch {};
        }
    };
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = &got, .onText = Ctx.onText };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hola "}}}}
    );
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"mundo"}}}}
    );
    try testing.expectEqualStrings("hola mundo", got.items);
}

test "el razonamiento va a su propio callback" {
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    const Ctx = struct {
        fn onThought(ud: ?*anyopaque, text: []const u8) void {
            const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ud.?));
            l.appendSlice(testing.allocator, text) catch {};
        }
    };
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = &got, .onThought = Ctx.onThought };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"voy a leer el fichero"}}}}
    );
    try testing.expectEqualStrings("voy a leer el fichero", got.items);
}

test "una tool nueva se recuerda por id para poder cerrar su linea" {
    const Ctx = struct {
        fn onTool(ud: ?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void {
            const s: *[]const u8 = @ptrCast(@alignCast(ud.?));
            s.* = std.fmt.allocPrint(testing.allocator, "{s}|{s}|{s}", .{ id, name, title }) catch "";
        }
    };
    var seen: []const u8 = "";
    defer testing.allocator.free(seen);
    const seenp: *[]const u8 = &seen;
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = @ptrCast(seenp), .onTool = Ctx.onTool };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","name":"bash","title":"sleep 30","kind":"execute","status":"pending"}}}
    );
    try testing.expectEqualStrings("c1|bash|sleep 30", seen);
    // El id es lo unico que viene en la actualizacion: sin el memo, el
    // `pushToolDone` no sabria que tool se cerro.
    try testing.expectEqualStrings("bash", c.toolName("c1"));
}

test "el resumen de un tool_call_update sale de content" {
    const Ctx = struct {
        fn onUpd(ud: ?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void {
            const s: *[]const u8 = @ptrCast(@alignCast(ud.?));
            s.* = std.fmt.allocPrint(testing.allocator, "{s}:{s}:{s}", .{ id, status, text }) catch "";
        }
    };
    var seen: []const u8 = "";
    defer testing.allocator.free(seen);
    const seenp: *[]const u8 = &seen;
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = @ptrCast(seenp), .onToolUpdate = Ctx.onUpd };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"exit=0"}}]}}}
    );
    try testing.expectEqualStrings("c1:completed:exit=0", seen);
}

test "las entradas del plan salen una a una" {
    const Ctx = struct {
        fn onPlan(ud: ?*anyopaque, text: []const u8) void {
            const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ud.?));
            l.appendSlice(testing.allocator, text) catch {};
            l.appendSlice(testing.allocator, "\n") catch {};
        }
    };
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = &got, .onPlan = Ctx.onPlan };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"plan","entries":[{"content":"mirar el test","status":"pending"},{"content":"arreglarlo","status":"pending"}]}}}
    );
    try testing.expectEqualStrings("mirar el test\narreglarlo\n", got.items);
}

/// Agente ACP de mentira para los tests: un `sh` que lee una request por
/// linea y contesta con JSON-RPC. Es mas fiel que un mock porque ejercita los
/// pipes, el buffer del reader y el framing de lineas de verdad.
const fake_agent_script =
    \\while IFS= read -r line; do
    \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"initialize"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentInfo":{"name":"fake-agent"}}}\n' "$id" ;;
    \\    *'"session/new"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"sess_fake"}}\n' "$id" ;;
    \\    *'"session/prompt"'*)
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hola "}}}}\n'
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"echo","kind":"execute","status":"in_progress"}}}\n'
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"exit=0"}}]}}}\n'
    \\      big=$(head -c 100000 /dev/zero | tr '\0' 'x')
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$big"
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id" ;;
    \\    *)
    \\      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"nope"}}\n' "$id" ;;
    \\  esac
    \\done
;

const fake_agent_argv = [_][]const u8{ "/bin/sh", "-c", fake_agent_script };

/// Agente que heartbeatea un rato y ATIENDE `session/cancel`.
///
/// El corazón se queda CORTO a propósito: un `sh` no puede leer de su stdin
/// mientras duerme, así que si esperase mucho no vería el cancel hasta que ya
/// no hiciese falta. Con 8 ticks vuelve al bucle de lectura y lo ve.
const fake_cancel_script =
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"fake-cancel"}}}\n' ;;
    \\    *'"session/new"'*) printf '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess_c"}}\n' ;;
    \\    *'"session/prompt"'*)
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_c","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"trabajando"}}}}\n'
    \\      i=0
    \\      while [ $i -lt 8 ]; do
    \\        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_c","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"."}}}}\n'
    \\        sleep 0.1
    \\        i=$((i+1))
    \\      done ;;
    \\    *EOF*) printf '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n' ;;
    \\    *'"session/cancel"'*) printf '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}\n' ;;
    \\  esac
    \\done
;
const fake_cancel_argv = [_][]const u8{ "/bin/sh", "-c", fake_cancel_script };

test "cancel() corta el turno: el agente recibe session/cancel y responde cancelled" {
    // Lo que hace de verdad el ESC en la TUI, pero sin la UI: `cancel()` solo
    // pone una bandera y es el worker (dueño del `Io`) el que escribe. Si
    // `cancel()` escribiera desde este hilo, el `Io` se usaría desde dos a la
    // vez y el turno moriría con AgentDied sin llegar a cancelar nada.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const c = try Client.start(testing.allocator, io, &fake_cancel_argv, "/tmp", null);
    defer c.deinit();

    try c.prompt("haz algo lentisimo");
    c.cancel();

    const sink = Sink{};
    const reason = try c.waitTurn(&sink);
    try testing.expectEqualStrings("cancelled", reason);
}

test "el turno entero pasa por un agente de mentira: handshake, updates y stop" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const c = try Client.start(testing.allocator, io, &fake_agent_argv, "/tmp", null);
    defer c.deinit();
    // El `initialize` se queda con el nombre que dijo el agente.
    try testing.expectEqualStrings("fake-agent", c.agentTitle());
    try testing.expectEqualStrings("sess_fake", c.sessionId());

    const Ctx = struct {
        text: std.ArrayList(u8) = .empty,
        tool: []const u8 = "",
        done: []const u8 = "",
        fn onText(ud: ?*anyopaque, s: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ud.?));
            p.text.appendSlice(testing.allocator, s) catch {};
        }
        fn onTool(ud: ?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ud.?));
            p.tool = std.fmt.allocPrint(testing.allocator, "{s}|{s}|{s}", .{ id, name, title }) catch "";
        }
        fn onUpd(ud: ?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ud.?));
            p.done = std.fmt.allocPrint(testing.allocator, "{s}|{s}|{s}", .{ id, status, text }) catch "";
        }
    };
    var ctx = Ctx{};
    defer {
        ctx.text.deinit(testing.allocator);
        if (ctx.tool.len > 0) testing.allocator.free(ctx.tool);
        if (ctx.done.len > 0) testing.allocator.free(ctx.done);
    }
    const sink = Sink{ .userdata = &ctx, .onText = Ctx.onText, .onTool = Ctx.onTool, .onToolUpdate = Ctx.onUpd };

    try c.prompt("hola");
    try testing.expectEqualStrings("end_turn", try c.waitTurn(&sink));

    try testing.expect(std.mem.startsWith(u8, ctx.text.items, "hola "));
    // El chunk de 100 KB tiene que llegar ENTERO: el `readLine` del std daría
    // StreamTooLong con una linea mas grande que su buffer de 64 KB.
    try testing.expect(ctx.text.items.len > 100_000);
    try testing.expectEqualStrings("t1|bash|echo", ctx.tool);
    try testing.expectEqualStrings("t1|completed|exit=0", ctx.done);
    try testing.expectEqualStrings("bash", c.toolName("t1"));
}
