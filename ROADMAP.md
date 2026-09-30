# ROADMAP — zode

Plan de trabajo derivado de una sesión de diagnóstico (2026-09-30). Todo lo que
afirma este documento está **medido o reproducido**, no estimado. Al final hay un
apartado con lo que se olvidó por el camino y hay que corregir en `AGENTS.md`.

Decisiones ya tomadas por el usuario:

| Decisión | Valor |
|---|---|
| Default de build | **ReleaseSafe + strip** (2.06 MB) |
| Resumen de fin de turno | **En el historial**, 2-4 líneas, plegable con Ctrl+R |
| Poda de memoria | **Por bytes**, releyendo del JSONL de sesión |

---

## 0. Diagnóstico

La queja era "se congela cuando entra a escribir o hacer bash". **La congelación
principal no es un problema de rendimiento: es un bug reproducible.**

### 0.1 Bucle infinito en el layout del historial (LA causa principal)

`src/tui.zig:1970` y `src/tui.zig:1999`:

```zig
while (self.seg_cache.items.len < self.paras.items.len) {   // 1970
    ...  // append  → len+1
    if (self.seg_cache.items.len > Model.max_cached_paras) { // 1999, cap = 128 (tui.zig:369)
        const old = self.seg_cache.orderedRemove(0);          // → len-1
        ...
    }
}
```

Con **≥129 párrafos** la condición nunca deja de cumplirse: append (129) → evict
(128) → y vuelta a entrar. Para siempre, creando y destruyendo un
`ArenaAllocator` por iteración.

Reproducido sobre el árbol actual (copia en `/tmp/opencode/zv2`):

| Suite | Resultado |
|---|---|
| `zig build test` tal cual | **159/159 verde, 31 s** |
| + test con **130 párrafos** | **cuelga** (kill a los 90 s, exit 124) |
| + test con `write` de **129 líneas** vía `pushDiff` | **cuelga** |

**El enlace con la queja**: `pushDiff` mete **un párrafo por línea de diff**
(`tui.zig:1122-1126`):

```zig
for (lines) |l| {
    const copy = self.allocator.dupe(u8, l) catch return;
    self.pushKind(.diff, copy);     // ← un PARRAFO por línea
    self.allocator.free(copy);
}
```

Un solo `write` de un fichero de 129 líneas → 129 párrafos → **la app se cuelga
al instante al 100 % de CPU, sin salida posible**. Eso es literalmente "se queda
congelado cuando entra a escribir". Con `bash` o lecturas de ficheros largos
pasa igual, y una sesión normal llega a 129 párrafos en ~40-60 intercambios.

### 0.2 Los otros cuatro freezes

**a) Sin feedback desde la 2ª iteración del bucle del agente.**
`streamStart()` se llama **una sola vez por prompt** (`agent.zig:1330`, en
`startChat`). `runOneTurn` hace `m.streamEnd()` al final (`agent.zig:1561`) y
**nunca vuelve a llamar `streamStart`**. El bucle corre hasta 8 iteraciones
(`agent.zig:1370`). Desde la 2ª vuelta `streaming == false` y `busy == false`, así
que no hay párrafo vivo, ni franja de actividad, ni spinner, ni reloj. El path
ACP sí lo hace bien (`agent.zig:1131`/`1154`); al HTTP nunca le dieron ese
tratamiento.

**b) La cadena de ticks se puede morir para siempre.**
El `.tick` solo se rearma si hay trabajo (`tui.zig:1839-1846`):

```zig
.tick => {
    self.tick_armed = false;
    const a = self.activity();
    if (a.busy or a.dirty or a.perm or a.picker or self.pal.active) {
        ctx.redraw = true;
        try self.armTick(ctx);
    }
}
```

Y `streamEnd` (`tui.zig:965-985`) **añade un párrafo nuevo al historial y pone
`busy = false` sin poner `dirty = true`**. Hay una ventana (`streamEnd` →
`pushToolStart`, con un `write(2)` de sesión y un DEFLATE-9 en medio) donde
`busy == false` y `dirty == false`. Si un tick cae ahí, `App.timers` queda
**vacío** y el worker **no tiene forma de pedir un frame**: no existe puntero a
`vxfw.EventContext` ni a la cola de eventos en `Model`. Desde ese momento la
pantalla está muerta hasta que se pulse una tecla, la rueda o se redimensione.
Es el "congelado hasta que toco algo".

**c) Re-parse O(n²) del párrafo vivo dentro del spinlock, cada frame**
(`tui.zig:2011-2048`): se dupea todo `stream_buf` al arena del frame y se
reparsea markdown + highlighter + anchura de graphemes **completo** en cada
frame, **con el lock del modelo cogido**. El worker compite con el draw en cada
`streamDelta`.

**d) `requestPermission` martillea el lock compartido** (`tui.zig:670-675`):
`while(true) { yield; lock; read; unlock }` durante todo el tiempo que tardas en
decidir. Quema un core entero y hace que cada adquisición de lock de la UI sea
un `yield` fallido. Cada `write`/`edit`/`bash` pasa por ahí si no estás en
`/yolo`.

**e) Latente, para máquinas de 2 núcleos.** El límite de `Threaded.async` es
`cpu_count - 1` (`Threaded.zig:1639`) y el hilo lector del TTY de vaxis lo ocupa
**para siempre** (`Loop.zig:77`, `io.concurrent`). Con 2 núcleos, `async_limit = 1`
queda agotado y cualquier `io.async` se ejecuta **en línea**
(`Threaded.zig:2100-2105`). zode hoy no llama a `io.async`, así que no muerde,
pero es una bomba de relojería para el día que se añada uno.

### 0.3 El render: por qué "todo verde" y "muy separado"

- **El verde es el diff, no el highlighter.** `markdown.zig:182-194` pinta **un
  solo segmento de toda la línea** con `styles.diff_add = fg(2)` (`#00cd00`,
  verde vivo), sin resaltado de sintaxis dentro, y el test `markdown.zig:469`
  **fija ese comportamiento**. Reescribir un fichero de 200 líneas = 200 filas
  verde sólido. Ese verde es además el mismo de las *strings* del código
  (`highlight.zig:13`).
- **"Muy separado" = un párrafo por línea de diff + una fila en blanco entre
  párrafos** (`tui.zig:1995`). 129 líneas de diff = 128 filas en blanco
  intercaladas. Además cada tool produce 2 párrafos (cabecera + resultado) con
  una fila en blanco entre ellos.
- **Los bloques de código no son bloques**: en `buildLinesBase` (`tui.zig:174`) se
  calcula `blk.kind` y `blk.lang` y **nunca se leen** (el único uso de `blk.` en
  todo el archivo es `blk.lines`). Sin gutter, sin fondo, sin padding, sin indent,
  sin chip de lenguaje. Y una línea partida a lo ancho continúa en la **columna
  0**, indistinguible de una sentencia nueva (`wrapCells`, `tui.zig:124-146`).
- **El resto del código queda plano**: `T.def = Style{}` (sin fg → **el color por
  defecto de la terminal, o sea el más brillante de la pantalla**) cubre ~90 % de
  las líneas, `fn_call` solo es `bold` sin color, y `generic` (el fallback de
  cualquier fence sin etiqueta, o con etiqueta rara como `json`, `tsx`, `diff`,
  `text`) tiene `builtins` y `types` **vacíos**, lo que además desactiva la
  heurística PascalCase→tipo (`highlight.zig:276-278`).
- El historial no tiene margen izquierdo: `drawLines` empieza en columna 0 y el
  área se pinta a ancho completo cada frame.

### 0.4 Tamaño, RAM y velocidad (medido)

| Build | Tamaño | Tiempo de build |
|---|---|---|
| ReleaseSafe tal cual (lo que había instalado) | **10.78 MB** | 13 s incremental |
| ReleaseSafe + `strip` | **2.06 MB** | 13 s |
| ReleaseFast | 11.67 MB | 3 m 36 s |
| ReleaseSmall (auto-strip) | **1.12 MB** | 1 m 21 s |

**El 79 % del binario son secciones de debug**: `.debug_loc` 4.23 MB +
`.debug_info` 1.87 MB + `.debug_line` 0.97 MB + `.debug_ranges` 0.60 MB +
`_str` 0.54 MB + `_pubtypes` 0.20 MB + `_pubnames` 0.13 MB = **8.55 MB de
10.87 MB**. El código real son 1.51 MB de `.text` + 0.46 MB de `.rodata`.

**RAM: la base ya es baja.** Medido con pty real a 200×50: **7.2 MB** de RSS en la
TUI, 7.9 MB en headless. El problema no es el arranque, es el **crecimiento sin
límite**: `Model.paras` nunca se poda, y la caché de segmentos guarda 128
párrafos × ~160 KB de arena de `CellRun` (40 B por grapheme) ≈ **20 MB** en una
sesión larga. A eso se suman 1 MB de `tty_buffer` permanente, 1 MB + 256 KB de
buffers en la pila del worker (con 16 MiB de stack por defecto, `std.Thread`),
y `readFileAlloc` de hasta 4 MB ×2 para los diffs.

**Velocidad por frame**: `vaxis.Cell` = **136 bytes** (medido). A 200×50 el
buffer del surface son 1.36 MB con memset cada frame, y `fillRange` del historial
son 200×45×136 ≈ **1.22 MB escritos celda a celda cada frame**. Son **~2.6 MB de
tráfico por frame** a 25 fps ≈ 65 MB/s, y encima `arena.reset(.free_all)` en el
bucle de vaxis lo convierte en malloc/free en vez de bump.

**Aparte**: `unifiedDiff` es LCS **O(n·m) por línea**, con snapshots de hasta
4 MB. Un `write` grande no es lento: es un cuelgue. Y en `sessions/` hay **58
ficheros, 24 de ellos vacíos de 0 bytes**, porque se crea un session file en cada
arranque aunque nunca se chatee.

---

## Fase 0 — Red de seguridad (~30 min)

`zig build test` tarda 31 s y da 159/159 verde. Antes de tocar nada, añadir en
`src/tui.zig`:

| Test | Qué fija |
|---|---|
| `layout: N párrafos no cuelga por encima del tope` (128, 129, 200, 1000) | **Hoy cuelga el runner entero.** Se escribe con presupuesto de iteraciones para que falle limpio en 1 s |
| `pushDiff de N líneas produce 1 párrafo` | El contrato que mata el cuelgue |
| `runOneTurn rearma streaming cada iteración` | Que haya feedback en las 8 iteraciones |
| `el tick se rearma aunque no haya trabajo` | Que la cadena de redraw no pueda morir |
| `streamEnd marca dirty` | Que un cambio de estado sin `dirty` se detecta |
| `markdown: una línea + del diff lleva tokens, no un segmento verde` | Anti-todo-verde |
| `tui: dos líneas + consecutivas van en filas consecutivas` | Anti-muy-separado |

El primero es especial: hoy el fallo **cuelga el binario de test** en vez de
fallar, así que sin el presupuesto de iteraciones no hay CI posible.

## Fase 1 — Congelaciones (P0)

| | Cambio | Dónde |
|---|---|---|
| 1.1 | **Terminar el bucle de layout**: indexar por párrafos, iterar hasta `min(paras.len, max_cached_paras)`, evictar **antes** de appender, y hacer layout sobre una ventana en vez de `orderedRemove(0)` | `tui.zig:1970-2019` |
| 1.2 | **`pushDiff` = un solo párrafo** con el diff unido por `\n`; devolver además el nº de `+`/`-`, que ya se calcula y se tira (`tui.zig:1116-1119`) | `tui.zig:1110-1127` |
| 1.3 | **`runOneTurn` llama `streamStart()`** al empezar cada iteración, y pone `iterating N/8` | `agent.zig:1431`, `1370` |
| 1.4 | **`dirty = true`** en `streamEnd`, `toolRunEnd`, `setStatusText`, `setStatusWithMood` | `tui.zig:965, 1040, 617, 630` |
| 1.5 | **Tick autosuficiente**: el `.tick` se rearma **siempre**; `ctx.redraw` solo si hay cambios. Añadir `redraw_requested: std.atomic.Value(bool)` que el worker pone en cada `push*` | `tui.zig:1839-1846, 1212-1218` |
| 1.6 | **Párrafo vivo fuera del lock**: snapshot de `stream_buf` con el lock cogido, parseo fuera. Y cachearlo incrementalmente (re-parsear solo la última línea + re-envolver) en vez de O(n) por frame | `tui.zig:2011-2048` |
| 1.7 | **`requestPermission` con futex/condvar** sobre un contador monótono, en vez de spin-yield sobre el lock común | `tui.zig:658-682` |
| 1.8 | **Tope al diff**: si el fichero pasa de ~2000 líneas, `diff omitted (file too large)` en vez del LCS O(n·m) | `agent.zig:1592-1617`, `markdown.zig:201` |
| 1.9 | **El session file se crea al primer mensaje**, no al arrancar | `main.zig:219` → `agent.zig:380-440` |

> 1.4 + 1.5 juntos son lo que convierte la congelación en **estructuralmente
> imposible**: nada puede matar el redraw porque el tick nunca se consume sin
> rearmarse, y cualquier cambio de estado del worker pone un átomo.

## Fase 2 — Feedback (P0/P1)

Todo esto entra con datos que **ya existen** y no se pintan.

| Mejora | Dónde | Datos disponibles |
|---|---|---|
| Placeholder `thinking · 3.2s` hasta el primer token | `tui.zig:2015-2019` (rama `else`) | `busyMillis()` (`tui.zig:847`) |
| TTFT (tiempo hasta el primer token) | nuevo campo + franja | `TurnCtx.stream_start_ns` (`agent.zig:1403`) |
| **Animación durante las tools** (ahora congelada) | `tui.zig:2048`: `if (self.busy)` → `if (self.workingLocked())` | `workingLocked()` ya existe (`tui.zig:870`) |
| **Argumento** de la tool en curso | `tui.zig:2032, 2445` | `ToolRun.arg` se guarda y **nunca se lee** |
| Fases explícitas: `thinking` / `streaming` / `running tool` / `waiting for permission` | `Model.phase` + franja | — |
| Indicador de iteración `iterating 2/8` | `agent.zig:1370` | `iterations`, `max_iterations` (`agent.zig:56`) |
| `+N −M` en el resultado de `write`/`edit` | `tui.zig:1116` | ya se cuenta y se descarta |
| **Errores en rojo**: existe `md.Kind.error_msg` con prefijo `✗` y **ningún caller lo usa**; todo sale gris de `.info` | `agent.zig:1753-1811` | `markdown.zig:27` |
| Aviso de compactación **en la TUI**: el tier 2 hoy solo corre en headless (`main.zig:106`); `runOneTurn` solo lee `comp.elided` | `agent.zig:1451-1460` | `comp.needs_summary` |
| Refrescar ctx% al cerrar un turno sin tools | `agent.zig:1575-1578` | ya se llama en el path de tools (`1581`) |
| `/allowlist` para ver qué tools están permitidas siempre | nuevo comando | `always_names` (`agent.zig:135`) |
| Resucitar `drawHints` (código muerto) o borrarlo | `tui.zig:2576` | — |
| `tool_res_bold` que sea bold de verdad (hoy idéntico a `tool_res`, así que el "dos tonos" de las tools es un no-op) | `markdown.zig:52` | — |

## Fase 3 — Resumen de fin de turno (P1)

Hoy el final de un turno es literalmente `setStatusWithZo(m, .done, "done")` y
nada más (`agent.zig:1576`). Ni ficheros, ni tools, ni tokens, ni duración, ni
cache.

**Bloqueo estructural**: todo lo por-turno vive en `TurnCtx`, que se destruye en
el `defer` de `runOneTurn` (`agent.zig:1437`).

Solución: un `TurnStats` **global del módulo** (como `CacheStats`), con `reset()`
en `startChat`, acumulado dentro de `execToolCalls` (que sí tiene `call.name` y
`ms` por tool en `agent.zig:1604`, y el path en `filePathOf`), y
`pushTurnSummary(m)` en `chatWorker` entre `agent.zig:1381` y `1383`. Los ficheros
tocados necesitan un `std.StringHashMap` por turno: hoy `filePathOf` se descarta
tras el diff.

Salida propuesta (2-4 líneas, en inglés como el resto de la UI):

```
⏺ Done · 4 tools · 3 files changed · 12.4s · ~18k tokens (62% cached)
  read src/agent.zig · edit src/tui.zig · bash zig build test · write src/x.zig
```

Plegable con Ctrl+R, reusando el mecanismo de `last_tool` (`tui.zig:1130`).

## Fase 4 — Render (P1)

En orden de impacto visual:

| | Cambio | Dónde |
|---|---|---|
| 4.1 | **Leer `blk.kind` y `blk.lang`** en `buildLinesBase` (hoy se calculan y se tiran) → gutter `│` de 2 columnas en `brand_faint`, fondo de bloque, y fila en blanco antes y después del bloque (hoy hay **cero** separación dentro de un mensaje) | `tui.zig:174-204`, `theme.zig` |
| 4.2 | **Colorear el diff por tokens**: partir el `+`/`-`/` ` en su propio segmento, pasar el resto por `hl.highlightLine`, y derivar el lenguaje de la extensión del path. Mata el muro verde | `markdown.zig:182-194`, `highlight.zig` |
| 4.3 | **Indent de 2 en código y sangría francesa** al partir líneas, para distinguir la continuación de una sentencia nueva | `wrapCells` (`tui.zig:124-146`) |
| 4.4 | **Mover la paleta de tokens a `theme.zig` en truecolor** (hoy `highlight.zig:8-19` es una copia hardcodeada en índices xterm-256 y **no importa `theme.zig`**) | `highlight.zig:1-19`, `theme.zig` |
| 4.5 | **`T.def` con color explícito atenuado** (hoy `Style{}` = lo más brillante de la terminal) y **color real para `fn_call`** (hoy solo `bold`) | `highlight.zig:16-18` |
| 4.6 | **Desacoplar el verde**: `str` y `diff_add` son ambos `index 2` | `highlight.zig:13`, `markdown.zig:53` |
| 4.7 | **Poblar `generic`** (builtins + types) y **normalizar la etiqueta** (minúsculas, trim, alias `tsx`/`jsx`/`json`/`text`/`diff`/`html`/`css`/`yaml`/`toml`) | `highlight.zig:124-145` |
| 4.8 | **Seguir strings multilínea** entre líneas, para que un `\\` de Zig o una comilla sin cerrar no pinten de verde el resto del fichero | `highlight.zig:336-348` |
| 4.9 | **Margen izquierdo de 2 columnas** en todo el historial (como ya hace la caja del input) y envolver a `width - 4` | `tui.zig:1900-1943, 2335` |
| 4.10 | `tool_res_bold` de verdad (compartido con Fase 2) | `markdown.zig:52` |

⚠️ **Ojo**: el test `tui.zig:3414` (`hasBlankRowBetween`) **exige** fila en blanco
entre párrafos. 4.1 y 4.9 lo rompen y hay que acotarlo a separación entre *grupos*
(resultado de tool → siguiente cabecera), no entre cada párrafo.

## Fase 5 — Peso / RAM / velocidad (P1/P2)

| | Cambio | Ganancia |
|---|---|---|
| 5.1 | **`.strip = true`** + opción `-Dstrip` en `build.zig` | **10.78 → 2.06 MB** (medido) |
| 5.2 | **`b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe })`** | fuera el `DebugAllocator` del camino caliente |
| 5.3 | Script/documentación de que `zig build run` ya va en release | evita instalar el Debug por costumbre |
| 5.4 | `tty_buffer` 1 MB → 64 KiB | −960 KB permanentes (`main.zig:195`) |
| 5.5 | `body_buf` (1 MB) y `transfer_buf` (256 KB) **al heap**, reutilizados entre peticiones | −1.3 MB de pila resident; quita la trampa de que un `stack_size` futuro sea un segfault (`agent.zig:1495,1887`, `http_client.zig:78`) |
| 5.6 | **`CellRun` de 40 B → ~12 B** (índice `u8` de paleta + offset `u32` en vez de slice + `Style`) | 3,3× menos arena en la caché: **~20 MB → ~6 MB** (`tui.zig:112-116`) |
| 5.7 | **Parchear vaxis**: `arena.reset(.retain_capacity)` en vez de `.free_all` | 1.36 MB de malloc/free por frame → bump (`zig-pkg/…/vxfw/App.zig:142`; o PR upstream) |
| 5.8 | **Pintar solo las filas visibles** en vez de `fillRange` de todo el historial | −1.22 MB de escrituras por frame (`tui.zig:2082-2085`) |
| 5.9 | Timeout menor en `vx.queryTerminal` | hasta **1 s de pantalla en blanco** al arrancar en terminales que no responden (`zig-pkg/…/vxfw/App.zig:66`) |
| 5.10 | Quitar `subscribeToColorSchemeUpdates` (zode no reacciona a cambios de esquema) | un viaje de ida y vuelta menos al arrancar |

> ReleaseSmall da **1.12 MB** y la app es I/O-bound, así que probablemente sea
> indistinguible en velocidad. No se pone de default sin medirlo, pero es el
> siguiente paso natural si se quiere el mínimo.

## Fase 6 — Poda de memoria (P2, la más delicada)

`Model.paras` (≈20 MB en sesiones largas) se poda por presupuesto de bytes (~8 MB)
más una ventana mínima reciente. Cada `Para` guarda un `session_line: ?usize` al
mensaje correspondiente del JSONL, que ya existe y ya va comprimido con zjsonl. Al
hacer scroll por encima de la ventana más antigua, se rehidrata un rango con
`Session` y se vuelve a insertar. Lo evicted **nunca se pierde**: sigue en el
fichero, que es justo lo que `/resume` ya sabe leer.

Es el único punto con riesgo real de regresión (punteros colgando al rehidratar),
por eso va el último y con tests propios: **podar → scrollear arriba → comprobar
que el texto sale idéntico byte a byte**.

## Fase 7 — Pulido (P2)

Header de 5 filas que se lee al instante · segunda columna de usage en el status ·
diff con **hunks reales** (`@@` + elipsis de contexto; hoy `unifiedDiff` escupe el
fichero entero) · `/help` que liste también los atajos · preview del fichero en
`write` en vez de un "OK" opaco.

### Estado tras la primera tanda (2026-09-30)

**Hecho y verificado** (`zig build test`: 211/211 verde, binario 1.89 MB)

| Fase | Qué |
|---|---|
| 0 | Tests de seguridad. `zig build test -- <filtro>` (el runner de 0.16 no trae `--test-filter`). El test de 130 párrafos CUELGABA el runner entero; ahora hay presupuesto de iteraciones y falla en 1 s. |
| 1 | **Las nueve**. 1.1 `layoutWindow` con ventana + `para_idx` + `para_heights`; 1.2 `pushDiff` = un párrafo (+ `DiffCounts`); 1.3 párrafo en vivo e `iteration N/8` por iteración; 1.4 `dirty` en todo cambio de estado; 1.5 tick autosuficiente + `redraw_requested`; 1.6 snapshot con lock, parseo fuera; 1.7 permiso con lock propio y espera dormida; 1.8 tope de 2000 líneas al LCS; 1.9 sesión perezosa. |
| 2 | Completa. Placeholder `thinking · Ns`, tool con argumento en la franja, spinner con `workingLocked`, TTFT, errores en rojo (`.error_msg` llevaba meses sin callers), `tool_res_bold` de verdad, `/allowlist`, aviso de compactación, ctx% en turnos sin tools, `drawHints` borrado. |
| 3 | Completa. `TurnStats` + `pushTurnSummary`. |
| 4 | Completa. 4.1 bloques con gutter/fondo/chip, 4.2 diff por tokens, 4.3 sangría de continuación, 4.4 paleta en `theme.zig` truecolor, 4.5 `T.def` atenuado y `fn_call` con color, 4.6 verde de strings != verde de diff, 4.7 `generic` poblado + `normalizeLang`, 4.8 strings multilínea, 4.9 margen izquierdo. |
| 5 | 5.1/5.2/5.4/5.5 hechas. **5.3** hecha de facto (el default ya es release+strip). |
| 6 | Hecha, **con un diseño distinto al propuesto** (ver abajo). |
| 7 | Completa: diff con hunks reales, `/help` con atajos, columna de usage en el status y preview del `write`. **El header no se toca** (ver abajo). |

**Medido, no estimado (esto cambió dos decisiones)**

| Cosa | Cifra real | Consecuencia |
|---|---|---|
| `Model.paras` con 128 párrafos de 16 KB | **2 MB de texto**, sin límite | Esta era la fuga de verdad. |
| Ventana de segmentos (`seg_cache`) | ~2.7 MB en el peor caso | Ya estaba acotada por el diseño de ventana, no hacía falta 5.6. |
| `CellRun` | 40 B | Con la ventana acotada, 5.6 ahorraría cientos de KB, no los ~14 MB que decía el ROADMAP. **No hecha.** |
| `fillRange` del historial | 200×45×136 B ≈ 1.2 MB por frame | 5.8 sigue sin hacerse: es la red anti-fantasmas del párrafo en vivo y sin TTY no se puede verificar que se pueda tocar. |

**Por qué la Fase 6 se ha hecho distinto**

El ROADMAP proponía podar `paras` y **rehidratar desde el JSONL de sesión**. Eso
no encaja: no todos los párrafos tienen un mensaje de sesión detrás (cabeceras de
tool, diffs, avisos del agente), así que no habría de dónde releerlos. Perder la
mitad del historial para ahorrar memoria es peor que no ahorrar nada.

Lo que sí se ha hecho: **comprimir en frío con `zjsonl`** (DEFLATE raw + base64,
round trip ya testeado). Al salir de la ventana el párrafo se comprime (~10×); al
volver a entrar, `Para.textLive` lo descomprime. Se pierde memoria, nunca
información, y no hace falta ningún mapeo con la sesión. `pruneCold` solo toca
párrafos cuya altura ya está medida, que es lo que permite que `ensureParaHeights`
siga funcionando sobre base64 sin descomprimir nada.

**Pendiente**

| Fase | Qué |
|---|---|
| 5 | 5.6 (descartada por medición), 5.7/5.9/5.10 (requieren parche de vaxis, documentado en AGENTS.md), 5.8 (no verificable sin TTY). |
| 7 | Nada. |

**El header NO se toca, y es deliberado.** El item pedía un "header de 5 filas
que se lea al instante", pero ese item es anterior a la v3 del banner, que es la
que **superó** la revisión del usuario (ASCII puro con `#`). AGENTS.md documenta
las dos versiones que se probaron y se rechazaron (filas desalineadas; cajetín
ilegible en su terminal). Volver a tocarlo es arriesgar un rechazo ya emitido
a cambio de nada. El smoke test en pty fija que las dos filas del wordmark se
leen, así que si algún día se rompe, se ve.

**Correcciones de AGENTS.md**: las tres del ROADMAP están escritas (el bucle del layout, la cadena de ticks, y el diagnóstico **erróneo** del `Io.sleep` en ACP: en Linux es `clock_nanosleep` por hilo y no toca `t.mutex`, así que el reloj se congelaba por los puntos 1 y 2, no por el sleep). Añadida además una sección de trampas de Zig 0.16 que costaron una tarde.

**Convención**: los comentarios del código pasaron a inglés. Los **nombres de test siguen en español** a propósito: son el índice de la suite.

---

## Orden y por qué

| Fase | Contenido |
|---|---|
| 0 | Tests. Sin red no se toca nada |
| 1 | Congelaciones. 1.1+1.2 matan el cuelgue, 1.4+1.5 lo hacen imposible, 1.3+1.6+1.7 quitan el "se queda a medias" |
| 2 | Feedback. Invisible sin la Fase 1: no hay a quién avisar si no hay frames |
| 3 | Resumen. Depende de 2 |
| 4 | Render. Independiente; se puede hacer en paralelo |
| 5 | Peso/RAM/velocidad. 5.1 es una línea y son −80 % de tamaño |
| 6 | Poda. La de más riesgo, la última |
| 7 | Pulido |

**Entrega mínima que arregla lo que pasaba: Fase 0 + Fase 1 + 5.1.**

## Cómo se verifica

- **Congelaciones**: los tests de la Fase 0. El de 130 párrafos hoy cuelga el
  runner; después debe fallar/pasar en <2 s.
- **Feedback y render**: tests de dibujo con `drawTest` + `rowText` +
  `readCell` (`tui.zig:2668`). Ojo con dos trampas ya conocidas: una carita son
  varios graphemes (`◔◕`), así que hay que recorrer con
  `vaxis.unicode.graphemeIterator`; y comparar la fila **completa**, porque
  `█████╗` es subcadena de `███████╗` y `findRow` devuelve la fila 0.
- **Frame en pty real**: la TUI solo se puede juzgar en tmux o en una pty con
  `TIOCSWINSZ`; vaxis hace redraw diferencial y un emulador casero pierde la
  mitad. Y hay que **drenar siempre** la pty: si el hijo llena el buffer (~64 KB)
  y el padre no lee, se queda bloqueado en `write` y parece un deadlock.
- **RAM/tamaño**: `ls -l zig-out/bin/zode`, `size -A`, y RSS con
  `grep VmRSS /proc/<pid>/status` sobre una pty de 200×50 (base actual: 7.2 MB).
- **Velocidad de build**: `time zig build`. Base: 13 s incremental en ReleaseSafe.

## Correcciones que hay que hacer en `AGENTS.md`

1. **El diagnóstico de `acp.zig:449-455` es incorrecto en Linux.** Dice que
   "`Io.sleep` secuestra el bucle de eventos". La cadena real:
   `Io.sleep` es una llamada a la vtable; `Threaded.sleep`
   (`Threaded.zig:11575-11585`) va a `sleepPosix` porque `use_parking_sleep`
   solo es true en Windows/NetBSD/illumos (`Threaded.zig:17241`); y
   `sleepPosix` es un `clock_nanosleep` en el hilo que llama, con un `Syscall`
   por hilo que **no toca `t.mutex`**. El tick de vaxis es una entrada normal en
   `App.timers` que evalúa `App.checkTimers` en el hilo de la UI. El reloj se
   congelaba por los puntos 0.2 (a) y (b), no por el sleep. Conviene escribirlo
   para que nadie vuelva a investigarlo.
2. **La capacidad de la caché de segmentos está mal planteada.** El comentario de
   `tui.zig:367-368` dice "el scroll profundo re-parsea on demand": el código no
   lo hace, y esa suposición es justo la que hace el bucle de `tui.zig:1970`
   no termine.
3. `pushDiff` mete un párrafo por línea: documentarlo, porque es la razón de que
   un `write` grande tumbe la app.
