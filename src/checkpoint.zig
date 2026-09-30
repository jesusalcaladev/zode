const std = @import("std");

/// Las fotos del contenido de los archivos, por TURNO, para poder deshacer.
///
/// ## Por qué no se rehace la conversación
///
/// `/undo` deshace **archivos**, no mensajes. La sesión es un JSONL append-only
/// (ver `session.zig`) y reescribirla a mitad de un turno es la clase de cosa
/// que luego nadie sabe explicar: se pierde el replay, el diff y el contexto.
///
/// ## Por qué un array de tamaño fijo
///
/// Vive en el `Model` y lo consulta el `/undo` desde el hilo de la UI. Un
/// `ArrayList` con heap obliga a gestionar la vida de cada snapshot; con buffers
/// fijos, "deshacer" es copiar de un sitio a otro y nada más que liberar. El
/// precio es un tope, y los topes están aquí abajo a propósito: son el límite de
/// memoria de una función que si no se traga un repo entero.
pub const max_checkpoints = 8;
pub const max_files = 24;
pub const path_max = 256;
pub const file_max = 256 * 1024;
/// Tope por checkpoint. Un `write` de un fichero de 3 MB no se puede deshacer
/// (y no tiene sentido), pero el resto del turno sí.
pub const snapshot_max = 1024 * 1024;
pub const label_max = 60;

pub const FileSnap = struct {
    path: [path_max]u8 = undefined,
    path_len: u8 = 0,
    data: []u8 = &.{},
    /// Si el archivo NO existía antes, deshacer es BORRARLO. Y hay que poder
    /// distinguir "no existía" de "no se pudo leer": en el segundo caso no se
    /// toca el archivo, porque borrarlo sería peor que no deshacer.
    existed: bool = true,
    /// El contenido no cabía (o se pasó el tope del checkpoint): este archivo no
    /// se puede deshacer, pero el resto del turno sí.
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
    /// Bytes ya gastados en este checkpoint (para el tope de `snapshot_max`).
    bytes: usize = 0,
    /// Se pasó el presupuesto: hay archivos que no se van a poder deshacer y el
    /// usuario tiene que saberlo.
    over_budget: bool = false,

    pub fn labelOf(self: *const Checkpoint) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn fileCount(self: *const Checkpoint) u8 {
        return self.len;
    }

    /// Cuántos se pueden deshacer de verdad (los truncados no).
    pub fn undoable(self: *const Checkpoint) u8 {
        var n: u8 = 0;
        for (self.files[0..self.len]) |f| {
            if (!f.truncated) n += 1;
        }
        return n;
    }

    pub fn deinit(self: *Checkpoint, gpa: std.mem.Allocator) void {
        // Solo los `len` primeros: el resto del array está `undefined` y
        // liberar eso es un crash.
        for (self.files[0..self.len]) |f| {
            gpa.free(f.data);
        }
        self.len = 0;
        self.bytes = 0;
    }

    /// Añade la foto de un archivo. Dice qué se guardó, para poder avisar.
    ///
    /// `content` es memoria del llamante (la arena del turno): se COPIA, porque
    /// esa arena muere al acabar el turno y la foto tiene que vivir más.
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

        // El mismo archivo dos veces en el mismo turno: solo importa la foto
        // INICIAL. Si se guardara la última, deshacer dejaría el contenido de
        // después de la primera edición, que no es el estado de antes del turno.
        for (self.files[0..self.len]) |f| {
            if (std.mem.eql(u8, f.pathOf(), path)) return .dup;
        }

        var f = FileSnap{ .existed = existed, .data = &.{} };
        @memcpy(f.path[0..path.len], path);
        f.path_len = @intCast(path.len);

        if (!existed) {
            // No existía: la foto es "bórralo cuando deshagas", 0 bytes.
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

    /// Una línea para el historial: qué se va a deshacer y de qué turno.
    ///
    /// En memoria del llamante (`arena`) porque va al historial, que sobrevive
    /// al turno. Con `bufPrint` en un stack local NO: eso se muere al salir de
    /// la función y el historial pinta basura (el clásico "pointer to local").
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

/// La pila de checkpoints.
///
/// Un anillo y no una lista que crece: el objetivo es "deshacer el último turno",
/// y con 8 turnos de historial ya se puede ir a git. Crecer sin tope es como se
/// traga la memoria un repo entero.
///
/// `items[0]` es SIEMPRE el más reciente. Que sea un índice y no un
/// desplazamiento es lo que hace que `begin` sea un shift de tres líneas.
pub const Stack = struct {
    items: [max_checkpoints]Checkpoint = undefined,
    len: u8 = 0,
    /// De dónde sale la memoria de las fotos. Lo lleva la pila para que
    /// `begin`/`deinit` no arrastren un allocator por firma.
    gpa: std.mem.Allocator = undefined,

    pub fn init(gpa: std.mem.Allocator) Stack {
        return .{ .gpa = gpa };
    }

    pub fn isEmpty(self: *const Stack) bool {
        return self.len == 0;
    }

    /// El más reciente, o null. `*Checkpoint` y no `*const` porque `/undo`
    /// CONSUME el checkpoint (lo borra al deshacer) y un `*const` no lo permite.
    pub fn last(self: *Stack) ?*Checkpoint {
        if (self.len == 0) return null;
        return &self.items[0];
    }

    /// Empieza el checkpoint de un turno: el anterior pasa a ser el segundo.
    pub fn begin(self: *Stack, label: []const u8) void {
        if (self.len == max_checkpoints) {
            // Lleno: el más viejo se cae. Y se libera ANTES de pisarlo, o la
            // memoria de sus fotos se pierde sin avisar (leak silencioso).
            self.items[max_checkpoints - 1].deinit(self.gpa);
        } else {
            self.len += 1;
        }
        // Desplaza hacia atrás: lo que era el más reciente pasa a ser el
        // segundo, y el hueco del final es el que se acaba de escribir.
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

    /// Descarta TODOS los checkpoints (cambio de sesión, `/new`).
    pub fn clear(self: *Stack) void {
        for (self.items[0..self.len]) |*cp| cp.deinit(self.gpa);
        self.len = 0;
    }

    pub fn deinit(self: *Stack) void {
        self.clear();
    }
};

// ── tests ─────────────────────────────────────────────────────

test "una foto se copia, no se apunta: la arena del turno muere" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();

    st.begin("crear el fichero");
    // `src` es memoria de stack: si `addFile` lo guardara tal cual, el undo
    // escribiría basura.
    var src = [_]u8{ 'h', 'o', 'l', 'a' };
    try std.testing.expectEqual(Checkpoint.Added.ok, st.items[0].addFile(gpa, "a.txt", &src, true));
    src[0] = 'X';
    try std.testing.expectEqualStrings("hola", st.items[0].files[0].data);
}

test "el mismo archivo dos veces en un turno: gana la foto INICIAL" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();
    st.begin("tres edits");

    _ = st.items[0].addFile(gpa, "a.txt", "v1", true);
    try std.testing.expectEqual(Checkpoint.Added.dup, st.items[0].addFile(gpa, "a.txt", "v2", true));
    try std.testing.expectEqual(@as(u8, 1), st.items[0].len);
    // Si se guardara la última, deshacer dejaría "v2", que no es el estado de
    // antes del turno.
    try std.testing.expectEqualStrings("v1", st.items[0].files[0].data);
}

test "un archivo que no existía se deshace BORRANDOLO" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();
    st.begin("crear");

    try std.testing.expectEqual(Checkpoint.Added.ok, st.items[0].addFile(gpa, "nuevo.txt", "", false));
    try std.testing.expect(!st.items[0].files[0].existed);
    // Y cuenta como deshacible: borrar es deshacer.
    try std.testing.expectEqual(@as(u8, 1), st.items[0].undoable());
}

test "un archivo demasiado grande se marca, no se traga la memoria" {
    const gpa = std.testing.allocator;
    var st = Stack.init(gpa);
    defer st.deinit();
    st.begin("reescribir un fichero enorme");

    const big = [_]u8{'x'} ** (file_max + 1);
    try std.testing.expectEqual(Checkpoint.Added.too_big, st.items[0].addFile(gpa, "enorme.txt", &big, true));
    try std.testing.expect(st.items[0].files[0].truncated);
    try std.testing.expectEqual(@as(u8, 0), st.items[0].undoable());
    try std.testing.expect(st.items[0].over_budget);
    // Y el resto del turno sigue siendo deshacible.
    _ = st.items[0].addFile(gpa, "otro.txt", "peque", true);
    try std.testing.expectEqual(@as(u8, 1), st.items[0].undoable());
}

test "el tope de archivos corta, y el de bytes avisa" {
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
    // Ni un archivo más: el array es fijo.
    try std.testing.expectEqual(Checkpoint.Added.no_room, st.items[0].addFile(gpa, "uno-mas.txt", "x", true));
    try std.testing.expectEqual(@as(u8, max_files), st.items[0].len);
    // Los que cupieron en el presupuesto de bytes están enteros; el resto está
    // marcado, y el checkpoint lo dice.
    try std.testing.expect(st.items[0].undoable() > 0);
    try std.testing.expect(st.items[0].over_budget);
    // El presupuesto por checkpoint es el que manda: 24 x 200 KB no caben en
    // 1 MB, así que los últimos tienen que estar truncados sí o sí.
    try std.testing.expect(st.items[0].undoable() < max_files);
}

test "el anillo: el último es el más reciente, y al llenarse se cae el viejo" {
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
    // El tope manda: no crece.
    try std.testing.expectEqual(@as(u8, max_checkpoints), st.len);
    // Y el más reciente es el turno nuevo, no el viejo.
    try std.testing.expect(std.mem.indexOf(u8, st.last().?.labelOf(), "turno 9") != null);
    // Y el ÚLTIMO del anillo es el más viejo que se conserva (turno 2).
    try std.testing.expect(std.mem.indexOf(u8, st.items[st.len - 1].labelOf(), "turno 2") != null);
    // Que el que se cayó liberara sus fotos lo vigila el allocator de testing:
    // si se hubiera pisado sin liberar, saltaría un "memory address leaked" al
    // salir del test.
}

test "resumen: cuántos ficheros, de qué turno, y lo que no se puede deshacer" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var st = Stack.init(std.testing.allocator);
    defer st.deinit();

    // Nada: el mensaje tiene que decirlo, no fallar en silencio.
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

    // Con un archivo que no cabe, el resumen lo dice en vez de prometer un undo
    // que dejaría el repo a medias.
    const big = [_]u8{'x'} ** (file_max + 1);
    _ = st.items[0].addFile(std.testing.allocator, "enorme.txt", &big, true);
    const s2 = st.last().?.summary(arena);
    try std.testing.expect(std.mem.indexOf(u8, s2, "undo: 1 of 2 files") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "1 too big") != null);
}

test "clear tira los checkpoints (cambio de sesión) sin dejar memoria" {
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
    // Y `last()` sobre una pila vacía no es un crash: es null.
    st.deinit();
}
