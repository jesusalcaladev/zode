# zode — AGENTS.md

Harness de código en Zig puro (sin C deps), estilo Claude Code, con enfoque en velocidad y ahorro de tokens.

## Principios del proyecto

1. **Zig std puro** — sin dependencias C, sin libc obligatoria (target musl posible). Única dep externa: libvaxis (Zig puro).
2. **Ahorro de tokens por diseño**: el contexto es el recurso caro. Todo lo que entre al LLM debe ganarse su lugar.
3. **Simplicidad radical**: preferir código directo y legible sobre abstracciones prematuras.

## Zig 0.16 — trampas conocidas

- **`main` recibe `std.process.Init`**: `init.gpa`, `init.io`, `init.environ_map`, `init.arena`, `init.minimal.args`.
- **Args**: `std.process.Args.Iterator.init(init.minimal.args)` + `.next()`.
- **Env**: `init.environ_map.get("KEY")` (NO `std.posix.getenv`).
- **Mutex**: `std.atomic.Mutex` (spinlock `tryLock`/`unlock`); `std.Thread.Mutex` ya no existe. Para locks largos con yield: `while (!m.tryLock()) std.Thread.yield() catch {}`.
- **HTTP client**: flujo `client.request()` → `sendBodyComplete(body)` / `sendBodiless()` → `receiveHead(&redirect_buf)` → `response.reader(&transfer_buf)` (buffer ≥16KB para streaming) → `allocRemaining()`.
- **`sendBodyComplete` pide `[]u8` mutable** — los bodies JSON se construyen en buffers de stack y se pasan con `@constCast`.
- **Compresión**: pedir `.headers = .{ .accept_encoding = .omit }` — std HTTP no descomprime transparente.
- **JSON**: `std.json.parseFromSliceLeaky(std.json.Value, arena, ...)` con arena por-request.
- **Writers**: `var w: std.Io.Writer = .fixed(buf)`; `std.io.fixedBufferStream` ya no existe. Salida headless: `std.Io.File.stdout().writer(io, &buf)` + `.interface.print(...)` + `flush()`.
- **vaxis 0.6**: `App.init(io, gpa, environ_map, tty_buffer)`; widgets vxfw con `userdata/eventHandler/drawFn`; `Surface.children` es slice (asignar, no append); `Cell` es struct con `.default`, no union.
- **Tiempo**: `std.time.timestamp()` NO existe. Usar `std.Io.Timestamp.now(io, .real).toSeconds()`. Durations: `Io.Duration.fromSeconds(x)`; los `Timeout` de procesos piden `Clock.Duration` = `.{ .raw = .fromSeconds(n), .clock = .awake }` (`.awake`, no `.monotonic`).
- **Child.Term**: tags en minúscula (`.exited`, `.signal`); `signal` es enum `std.posix.SIG` → `@intFromEnum` + truncate a u8.
- **Dirs**: NO hay `makePath`; usar `dir.createDirPath(io, path)` (mkdir -p). Para iterar un dir: `openDir(io, path, .{ .iterate = true })` — sin el flag, iterar es Illegal Behavior (EBADF panic en debug). `dir.iterate()` devuelve `Iterator` que lleva su propio buffer; `Iterator.next(io)`.
- **File.Writer**: `file.writer(io, &buf)` devuelve struct con `.interface: *Writer` estable; guarda el struct completo, no el puntero.
- **process.run**: `std.process.run(gpa, io, .{ .argv, .stdout_limit, .stderr_limit, .timeout })` → `RunResult{ .term, .stdout, .stderr }`. No existe `std.regex` (hay mini-motor propio en `src/regex.zig`).
- **Escritura directa de archivos**: `dir.writeFile(io, .{ .sub_path, .data })` para crear/ sobreescribir entero.
- **grep tool**: usa `rg` nativo → `grep -rn` nativo → fallback regex propio (en ese orden). Respeta .gitignore via rg.
- **graphemes NUNCA con `&[_]u8{c}`**: `vxfw.Surface.writeCell` guarda la `Cell` POR VALOR, pero vaxis lee los BYTES de `char.grapheme` en `Vaxis.render()`, es decir DESPUÉS de que `drawFn` haya retornado. Un puntero a temporal de stack llega al renderer como basura (NULs) → pantalla en blanco salvo los literales. Usar SIEMPRE `Painter.putText` (copia al arena del frame) o `putStable` (literal/arena propia del párrafo). Tests en `tui.zig` lo cubren.
- **`ArrayList.clearRetainingCapacity` hace `@memset(items, undefined)`**: no se puede conservar un slice de `items` y luego limpiar. Consumir la línea ANTES de limpiar (ver `StreamCtx.feed`).
- **`std.ArrayList` de Zig 0.16 es UNMANAGED**: `append(gpa, item)`, `insertSlice(gpa, i, s)`, `replaceRange(gpa, start, len, s)`.

## Comandos

```bash
zig build                        # debug
zig build -Doptimize=ReleaseSafe # release (binario ~8.5MB, 1.6MB stripped)
zig test src/chat.zig            # tests del parser SSE
./zig-out/bin/zode --models      # lista modelos (headless, para probar sin TTY)
./zig-out/bin/zode --chat "txt"  # chat streaming headless
./zig-out/bin/zode               # TUI
```

## Config (env)

- `ZODE_BASE_URL` (default: `https://opencode.ai/inference/openai/v1`)
- `ZODE_MODELS_URL` (default: `https://opencode.ai/inference/v1/models`)
- `ZODE_API_KEY`
- `ZODE_MODEL` (default: `kimi-k2.6`), `ZODE_EFFORT` (low|medium|high)
- Cargar con `set -a && source .env && set +a` (el `.env` está gitignored)

## Estado y roadmap

**Hecho**: HTTP/TLS std puro verificado contra la API real; modelos multi-provider (opencode/openrouter/anthropic/openai/groq/deepseek/local); **streaming SSE incremental de verdad** (chunks del socket → `StreamCtx.feed` → eventos al instante, con ESC cortando la conexión); chat con tool_calls fragmentados (OpenAI y Anthropic); compaction 2 tiers; sessions JSONL con zjsonl; agent loop con 8 tools; permisos con allowlist persistida; TUI con markdown+syntax highlighting, scroll, spinner, tok/s, pickers modales; highlighter universal; **89 tests**; binario 10MB (1.9MB stripped).

**Siguiente (orden sugerido)**:
1. Skills (directorios de instrucciones cargables).
2. MCP over stdio.
3. E2E real contra Anthropic con key propia (wire format ya testeado unitariamente; OpenRouter sirve Claude vía OpenAI-compat).

## Mascota: Zo

- `mascot.zig`: Zo. Cara 1-línea por mood (idle/thinking/tooling/done/warn) en el status bar y en la franja de actividad. El banner de arranque es SOLO el wordmark `ZODE`: una mascota de 18 filas se probó (Houston, Astro Boy) y se rechazó por llenar la vista.
- El agent la usa vía `setStatusWithZo(m, .mood, "text")`.

## Cache stats (provider-agnóstico)

- `chat.Usage` normaliza OpenAI (`prompt_tokens_details.cached_tokens`) y Anthropic (`cache_read_input_tokens`); llega por SSE con `stream_options:{include_usage:true}`.
- `cache_stats.zig` acumula por sesión: `hitRatePct()`, reqs con hit, tokens prompt/cached/completion.
- `/cache` en la TUI lo muestra. El headless agent imprime `[cache] X% hit-rate` al final.
- Nota: los modelos free de OpenRouter no reportan cache; la métrica brilla con Anthropic/DeepSeek/OpenAI.

## Tools actuales (10)

read, write, edit (multi-hunk), bash, glob, grep (rg nativo), list_files (listing plano barato), **web_fetch**, **web_search**, think (scratchpad sin efectos para planificar). No piden permiso: read, glob, grep, list_files, think, web_fetch, web_search.

## Tools de web: `web_fetch` y `web_search`

- `web_fetch {url, max_bytes?}`: GET con `user-agent` de navegador y
  `accept-encoding: identity`. El HTML se convierte a texto con `web.zig`; un
  JSON o un texto plano pasan intactos. Un 4xx/5xx devuelve status + cuerpo
  (que es donde está el motivo real).
- `web_search {query, max_results?}`: endpoint `html/` de DuckDuckGo (sin key).
  Es un scrape: `web.searchResults` saca título, URL y snippet por posición de
  sus clases. Cuando el HTML cambie devuelve un mensaje que lo dice, NUNCA una
  lista vacía (que el modelo leería como "no hay resultados").
- `max_tool_output` (16 KB) es el presupuesto por defecto; tope duro 200 KB.

Cuatro cosas que costaron y hay que saber:

1. **`accept-encoding: identity` explícito.** `openRequest` pone
   `accept_encoding = .omit`, que es "no mandar el header", y sin él GitHub y
   compañía responden gzip: el modelo se come 16 KB de bytes ilegibles. std no
   descomprime de forma transparente. Además `looksCompressed` (magic gzip/zstd +
   heuristic de binario) es la red de seguridad para cuando un servidor ignora
   la cabecera: mejor "vino comprimido" que basura.
2. **El `content-type` NO se puede devolver en `JsonResult`.** Los headers
   viven en el buffer de redirects de `receiveHead`, que es de STACK y muere al
   salir de `request`. El tipo se deduce del body (`looksLikeHtml`).
3. **El resultado se COPIA a memoria propia de la arena.** Devolver una vista
   del buffer del HTTP es una bomba: el `defer freeBody` la suelta al salir y el
   ArenaAllocator reutiliza esa memoria en la siguiente allocación. Se vio
   como `0xAA` donde debía estar el JSON, y solo con arena, por eso los tests
   de red (que se saltan sin internet) son los que lo cazan.
4. **El art no puede usar `*` ni `~`** (mismo motivo que el banner:
   `markedSegments` los come como marcas de estilo). El iris es `=` y la pupila
   `o`.

`web.zig` es PURO (sin red) a propósito: lo que falla siempre es parsear el
HTML, y eso se testea con fixtures.

## Compaction de contexto (80% del límite)

- `compaction.zig`: `budgetTokens(env)` = 80% de `ZODE_CONTEXT_LIMIT` (default 128k → 102k budget).
- **Tier 1 (gratis, wired)**: `elideTier()` reemplaza tool results viejos (>256B, fuera de la ventana `recent_window=8`) por `[tool result elided: N bytes — re-run the tool if you need it]`. Es una VISTA del wire: la sesión JSONL conserva todo el historial.
- Aplicada en `chatWorker` (TUI) y `runChat` (headless) antes de `buildBodyMessages`. El headless imprime `· N tool results elided` junto a `[cache]`.
- `/context` en la TUI: tokens estimados vs budget y elided acumulado de la sesión.
- **Tier 2 (wired, verificado E2E)**: si `needs_summary`, `agent.summarizeTurns()` hace UNA llamada LLM con `summaryPrompt()` y reemplaza `msgs[after system..summary_upto]` por una nota user `[earlier conversation summarized to fit the context budget]`. Best-effort: si falla, se sigue sin resumen. Cuenta para cache_stats.
- Prueba E2E real (con `ZODE_CONTEXT_LIMIT=6000` y 8 reads): dispara `summarizing old turns…` en iteraciones sucesivas y el agente se auto-repara re-leyendo lo resumido cuando lo necesita. Caveat: con contextos muy chicos el límite de iteraciones (6/8) puede alcanzarse antes de terminar.
- `estimateTokens`: ~4 chars/token + overhead JSON por mensaje.

## Pickers modales (estilo opencode)

- `tui.zig`: `openPicker(tag, title, items, cb)` (thread-safe, el worker puede abrirlo), `pickerHandleKey` captura TODO el input mientras está abierto (up/down/enter/esc/backspace + filtro case-insensitive en vivo, scroll de 10 visibles), `closePicker` libera los labels gpa-owned.
- Dibujo: `drawPicker` box centrado con bordes, título, línea de filtro, items con selección resaltada y footer `up/down · enter · esc (n/total)`. Snapshot por frame (`pickerSnapshot`) copia ≤10 items a la arena del frame.
- Comandos: `/model` (lista async del provider, free primero + desc "free"), `/provider` (con estado de key y default model), `/effort` sin args (low/medium/high). `/use` y `/effort <arg>` siguen funcionando.
- Callback: `fn(*Model, tag, label)`; el label es copia heap liberada tras el callback.
- FIX: `cur_model` ahora vive en `cur_model_buf` estático (`setModel()`) — antes un `/use <model>` con string efímero del input dejaba un slice colgante.

## Contador de tokens (tok/s)

- `TextSink` mide chars del stream por turno y `updateTps()` calcula tok/s (~4 chars/token) con `Io.Timestamp.now(io_global, .real)` — solo streaming, sin tool execs ni permisos.
- `agent.tps_live` (en curso) lo pinta el status bar como `⚡ N tok/s` mientras `busy`; `tps_last` queda para `/context`.

## /context (gauge y breakdown)

- Línea 1: gauge de 20 celdas `[████░░…]` + `~used / limit tokens (P% of limit)`.
- Línea 2: `system ~N · history ~N · N turns · budget N (P% used)`.
- Línea 3: `elided this session: N tool results · last stream: N tok/s`.

## Anthropic nativo (Messages API + prompt caching)

- `chat.ProviderKind{openai, anthropic}` + `kindForProvider(provider_id)`; provider `anthropic` en providers.zig (`ZODE_ANTHROPIC_KEY`, base `https://api.anthropic.com/v1`, default model `claude-sonnet-4-5`).
- `buildBodyAnthropic`: `system` top-level, tools con `input_schema` (acepta formato OpenAI anidado o plano), `tool_calls` OpenAI → bloques `tool_use`, runs de role=tool → UN mensaje user con bloques `tool_result` (Anthropic no tiene role "tool"). Mensajes de contenido vacío se saltan (Anthropic los rechaza).
- **3 breakpoints `cache_control:{type:"ephemeral"}`**: última tool, system y último bloque del último mensaje → el prefijo estable (tools+system+historial) se sirve de la cache del server cada turno (la técnica que usa Claude Code para el ~90% de hit-rate).
- SSE Anthropic parseado en `dispatchEvents`: `message_start` (usage input+cache_read), `content_block_start`/`content_block_delta` (`text_delta`, `input_json_delta`), `message_delta` (output_tokens, stop_reason `tool_use`→`tool_calls`). `last_usage` ahora hace MERGE por campo (Anthropic reparte el usage entre eventos).
- Auth vía `postJsonWithHeaders` (x-api-key + `anthropic-version: 2023-06-01`); OpenAI sigue con Bearer en `streamRaw`.
- TRAMPA: `postJsonWithHeaders` NO envía Bearer — en `streamRaw` la elección de método/auth es por `ctx.kind`.
- `models.zig` tolera `data` anidado (proxies).

## Arquitectura de sesiones comprimidas (zjsonl)

- Cada línea JSONL cuyo content >= 512 bytes se comprime con DEFLATE raw level 9 y se marca con prefijo `z` + base64 (JSON-safe, byte-exact). Ratio típico: 90-97% de ahorro.
- Al cargar, las líneas `z` se descomprimen transparentemente. Round-trip testeado byte a byte.
- Session.create/resumePath devuelven `*Session` heap: el File.Writer referencia write_buf dentro del struct (moverlo por valor = use-after-free).
- El File.Writer de Zig 0.16 es posicional: para append usar `Writer.initStreaming` (el modo posicional crea holes de 0xFF).

## Highlighter universal (v2)

- `highlight.zig`: token scanner genérico de una línea (no por lenguaje): strings con escapes y prefijos r/b/f, comentarios de línea y bloque, números (hex/floats), keywords vs control-flow (2 estilos), builtins (zig `@fn`, rust `macro!`), tipos (+ heurística PascalCase), llamadas fn (`word(`), decoradores `@` (JS/TS).
- Lenguajes con tabla: zig, js, ts, py, sh, c/cpp, rust, go, sql + fallback `generic` seguro para cualquier fence tag.
- Invariante testeado: la concatenación de segmentos == línea original (no se pierde texto jamás).

## Render incremental (TUI)

- Cada párrafo cerrado se parsea UNA vez a segmentos y se cachea con su propia arena (max 128; LIFO eviction). Solo el párrafo en streaming se re-parsea por frame.
- La caché se invalida al cambiar el ancho de la terminal.

## Headless agent

- `zode --chat "..."` es un agente completo sin UI: system prompt + tools + loop de hasta 6 iteraciones con yolo implícito. Ideal para probar end-to-end sin TTY.

## Flujo de permisos

- Worker de tool llama `model.requestPermission(tool, detail)` → **bloquea el hilo del worker** (spin + yield) hasta que la UI responda.
- UI: cuando `permActive()`, el event handler captura `y/a/n/Esc` y llama `answerPermission(.allow/.allow_always/.deny)`; el draw pinta el diálogo modal (buffers fijos en el Model, cero allocs por frame).
- Prioridad: `/yolo` (global) > allowlist "siempre permitir" (persistida en `~/.config/zode/permissions.json`) > diálogo.
- Respuesta denegada se alimenta al LLM como tool_result `"denied: permission required"` para que re-planifique.
- Los ticks (`ctx.redraw` en `.tick`) repintan solo mientras hay diálogo o streaming — 0 CPU en idle.

## Sesiones y resume

- JSONL append-only en `./sessions/zode-<id>.jsonl` (1 write por evento; tool_calls como JSON crudo para replay fiel).
- `zode --resume` o `ZODE_RESUME=1` carga la sesión más reciente (por mtime) y la reabre: reescribe el historial una vez (truncate) y sigue appendeando.
- `/resume` en la TUI reanuda la última; `/new` crea otra.
- FIX IMPORTANTE: la respuesta final del asistente SÍ se persiste (TextSink acumula deltas en arena del turno).

## System prompt

- `systemPrompt()` lee `AGENTS.md` (o `CLAUDE.md`) del CWD del proyecto del usuario, lo cachea una vez, y lo inyecta como primer mensaje `system` en cada request → prefijo estable cacheable por el provider.

## Gotchas del provider OpenCode

- Los modelos `-free` solo funcionan desde el cliente oficial de OpenCode (gate server-side, respeta el gate).
- Modelos pago requieren créditos en opencode.ai/console.
- Chat: `POST {ZODE_BASE_URL}/chat/completions`; modelos: `GET /inference/v1/models`.

## Streaming SSE (incremental de verdad)

- `http_client.streamPost()` entrega el body POR TROZOS (`response.reader` con buffer de 64KB) en vez de bufferearlo entero con `allocRemaining`. Antes la TUI se quedaba congelada hasta que el modelo acababa.
- `StreamCtx.feed(chunk)` acumula en `line_buf` y despacha cada `data:` en cuanto su línea queda completa. `scanSse` usa el MISMO parser alimentándolo entero (tests y paths sin socket).
- OJO: `clearRetainingCapacity` hace `@memset(items, undefined)` → consumir la línea ANTES de limpiar.
- `chat.cancel_current` es `std.atomic.Value(bool)`; ESC lo pone y el `on_chunk` devuelve `error.Cancelled`, que corta la conexión. El texto ya recibido se conserva (`result.partial`).
- Headers de streaming: `accept: text/event-stream` + `cache-control: no-cache` (varios gateways renegocian el stream según esto).

## Tool calls: no colgarse

- El trigger histórico era "el último byte de los args es `}`". Si el stream se cortaba antes, o el modelo mandaba argumentos vacíos, el tool call NUNCA se emitía y el agent loop se quedaba esperando para siempre.
- Ahora `tryEmitTool` valida JSON real, y `flushPendingTools()` (llamado en `finish`) fuerza la emisión de los que sí son ejecutables. Un tool sin argumentos se trata como `{}`.
- Tests: "tool call cortado a mitad de args se emite al finish" y "tool sin argumentos".

## Retries y errores

- 429/5xx → `error.RateLimited` / `error.Overloaded` / `error.ServerError`, reintentados con backoff exponencial + jitter (3 intentos, 500ms/1s/2s). Se respeta `Retry-After` si el server lo manda.
- 401/403 → `error.AuthFailed`, NO se reintenta (la key está mal; insistir no ayuda).
- `Retry.wait()` duerme en trozos vía `io.sleep` y aborta pronto si hay ESC.

## Parámetros por familia de modelo

- `chat.familyForModel(model)` detecta o-series/gpt-5 → `max_completion_tokens` + `reasoning_effort` (y nada de `temperature`, que ahí da 400). El resto usa `max_tokens`.
- Anthropic: `max_tokens` es obligatorio, y si se manda `thinking.budget_tokens` tiene que ser ESTRICTAMENTE menor (si no, 400).
- Tests: "buildBodyOpenAI: o-series usa max_completion_tokens + reasoning_effort".

## Config por usuario (~/.config/zode/config.json)

- Antes los providers estaban compilados: apuntar a vLLM/LM Studio/Together exigía recompilar. Ahora `src/config.zig` los carga de disco.
- `provider`, `model` y `providers[]` (id, name, base_url, models_url, key_env string o array, default_model, kind, note).
- No se puede shadowear un provider compilado (el id gana el built-in).
- `key_env` es una lista: se usa la primera no vacía. `ZODE_API_KEY` es el fallback genérico.

## Metadatos de modelo

- `models.zig` parsea `context_length` y `pricing.{prompt,completion}` de OpenRouter (los precios llegan como strings decimales → `jsonNumber` los convierte; nunca devuelve NaN).

## Bugs de userdata / casts cruzados (verificados en pty)

- Los 3 callbacks de un turno (`onDelta`, `onToolCall`, `onFinish`) reciben el MISMO `?*anyopaque`. Cada uno lo castea a su vista, así que hace falta un struct con nombre propio (`TurnCtx{ text, tools }`), no pasar `&tool_sink` y que `onDelta` lo castee a `*TextSink`: eso es "incorrect alignment" en cuanto llega el primer token, y en ReleaseFast es UB silencioso (lee campos de otro tipo).
- `ZODE_PROVIDER` se ignoraba en la TUI (`cur_provider_id` hardcodeado a "opencode") → mandaba la key de un provider al endpoint de otro y salía 403. Ahora la precedencia es config.json > ZODE_PROVIDER > opencode.

## Verificación sin TTY real

Capturas en pty con `pty.openpty()` + `TIOCSWINSZ` y un emulador de pantalla mínimo (CUP/ED/EL/ED) para replay. Es la única forma fiable de ver la TUI desde un agente: `script` no fija tamaño de ventana y vaxis hace `width_pix / width` → división por cero con tamaño 0.

## Input: editor propio (`editor.zig`)

- `vxfw.TextField` es de UNA línea y sin historial → se sustituyó por `editor.Editor`: buffer con cursor, graphemes (no bytes), Shift/Alt+Enter = salto de línea, historial con ↑/↓ (con borrador), Ctrl+A/E/U/K/W, Ctrl+←/→ y Alt+B/F por palabra, y tope de 256 KB para que un pegado no tumbe la TUI.
- La caja se dibuja a mano (`drawInput`): bordes `╭─╮│╰─╯`, prompt `❯`, placeholder, y el **cursor del terminal anclado** en la posición real (`surface.cursor`). Crece hasta 8 líneas y se recorta si no cabe.
- Layout de abajo hacia arriba: status(height-2) · borde inf · input · borde sup · separador · historial. Se calcula ANTES de layoutear el historial porque `history_h` depende de la altura del input.
- `doc` de layout en el propio código: si tocas esas filas, mira los comentarios de `typeErasedDrawFn`.

## Autocompletado de `/`

- Se ofrece solo si el input empieza por `/` y NO tiene espacios (si no, ya es un comando con argumentos).
- El match es por **prefijo del nombre del comando sin la barra** (`/use <prov> [model]` → `use`). Con la línea entera, `/mod` casaba con `/use ... [model]`.
- Tab **y Enter** aceptan el resaltado; Esc cierra sin borrar; ↑/↓ navegan.

## Diff de write/edit

- `markdown.unifiedDiff` = LCS por líneas (O(n*m)), prefija ` ` / `+` / `-`. `splitLines` ignora el salto final para no generar una línea espuria.
- `diffSegments` colorea por prefijo: +verde, -rojo, contexto gris, `@@` como heading.
- El agent fotografía el archivo ANTES de ejecutar la tool y lo vuelve a leer después (`filePathOf` + `readFileAlloc`); si no cambia, no se añade nada al historial.

## Bugs de autocompletado ya arreglados (no reintroducir)

- `containsIgnoreCase` es *substring*, no prefijo: usarlo para comandos daba falsos positivos.
- El prefijo del input va SIN la barra; las claves de `agent.commands` van CON ella. Hay que quitar la barra de un lado.


## Ejemplo end-to-end: `examples/platformer`

Juego de plataformas en Zig 0.16 puro, construido para poner el harness a
prueba. `zig build test` → 34 tests, `zig build run` → jugar.

- `src/game.zig` — simulación pura (sin I/O, por eso testeable sin terminal).
- `src/render.zig` — dibuja el estado. Solo lee.
- `src/main.zig` — bucle: input, paso fijo, salida.

### Lo que el harness NO sabe hacer (revisado a mano)

Al pedirle un juego completo, el modelo produjo un esqueleto plausible que no
compilaba. Errores concretos que aparecieron:

- **API de Zig 0.11 mezclada con la de 0.16**: `std.ArrayList(T).init(gpa)`
  (en 0.16 `ArrayList` es *unmanaged*: `.empty` + `append(gpa, x)`),
  `std.io.getStdIn()`, `std.time.sleep(nanos)`.
- **Ficheros con APIs cruzadas**: `main.zig` llamaba `Game.init()` sin
  allocator mientras `game.zig` definía `Game.init(allocator)`, y
  `game.update()` vs `game.step()`. Iteraba `game.platforms` como si fuera un
  slice cuando es un `ArrayList`.
- **`build.zig` inexistente** y `build.zig.zon` con un fingerprint inventado.
- **TODOs** en el código, pese a que el `AGENTS.md` del proyecto los prohíbe.

Conclusión práctica: para trabajo que abarque varios ficheros, el prompt tiene
que fijar el contrato entre ellos (firma de `init`, nombres de las funciones
públicas) y hay que compilar tras cada paso. El harness es bueno editando un
fichero que ya compila; para uno que tiene que inventarse entero, conviene
fijar el contrato y dale una vuelta al resultado.

### Bugs del propio zode que sacó el ejemplo

- **`takeDelimiter` y `StreamTooLong`**: si una línea SSE no cabe en el buffer
  de transferencia (un tool call enorme, un delta gigante), el stream moría a
  mitad de respuesta con `error.StreamTooLong`. Ahora el buffer es de 256 KB y,
  si aun así no cabe, se entrega el buffer lleno tal cual y se sigue (el parser
  reensambla parciales). Test: "una línea SSE más grande que cualquier buffer
  se reensambla".
- **Fuga en el path de error**: `streamChatCtx` usaba `errdefer gpa.destroy(ctx)`,
  que no libera `parts` ni `line_buf` → fuga en cada 429/5xx. Ahora
  `errdefer ctx.destroy()`.

### Trampas de terminal que costaron un rato (útiles para cualquier TUI)

- **`std.Io.Timestamp.durationTo(from, to)` es `to - from`**. Escribir
  `now.durationTo(last)` da NEGATIVO siempre; con un `@max(0, …)` el elapsed
  se queda en 0 y la simulación no avanza nunca (pero el render sí, así que
  parece que funciona: se repinta un frame estático a 200 fps).
- **Modo canónico**: sin `tcsetattr` quitando `ICANON`/`ECHO`, la terminal no
  entrega ni un byte hasta el Enter. Y leer de una TTY es bloqueante aunque
  esté en raw, así que hace falta un hilo aparte.
- **No hay evento de "tecla soltada"** en modo raw. Se usa el auto-repeat del
  terminal: si dejan de llegar bytes durante ~120 ms, la tecla se suelta.
- **`Writer.fixed` no escribe en la terminal**: compone en su buffer. Hay que
  volcarlo a un `File.Writer` y hacer `flush()`.
- **Una secuencia ANSI por celda** son ~350 KB/s. Agrupar celdas contiguas del
  mismo color en un tramo lo baja a ~40 KB/s.
- **Al verificar con pty hay que drenar siempre**: si el proceso hijo llena el
  buffer de la pty (~64 KB) y el padre no lee, se queda bloqueado en `write` y
  parece un deadlock del programa. No es un bug del programa.


## Paleta modal de Ctrl+P (`palette.zig`)

Modal al estilo opencode/Claude Code, con dos modos:

- **Ctrl+P** — comandos, agrupados (Sugerido · Modelo · Sesión) con el atajo
  a la derecha. Enter **pone el comando en el input** en vez de ejecutarlo:
  `/use` necesita argumentos y el usuario quiere ver qué va a pasar.
- **Ctrl+T** (y `/model`) — dos columnas: providers a la izquierda (con su
  estado de key) y los modelos del provider activo a la derecha (con `free` o
  la ventana de contexto). `Tab` / `←→` cambian de columna. Abajo,
  `Connect an integration` + `ctrl+a` para escribir la API key.

Decisiones que no son obvias:

- **El filtro es por SUBCADENA, no por prefijo.** Es una caja de búsqueda, no
  el autocompletado de `/`: con prefijo estricto escribir "mod" no encontraba
  `/model` (que empieza por barra) y parecía roto. Ojo: esto es justo lo
  contrario de lo que hace el autocompletado de `/`, que sí es por prefijo.
- **`sel[c]` indexa `filtered[c]`, NUNCA `items`.** Cada columna tiene su
  lista filtrada. Con una sola lista el dibujo filtraba sobre la marcha
  mientras la selección contaba sobre la lista completa, y con cualquier
  filtro la barra de resaltado iba a la fila equivocada.
- **La fila de un item se calcula DESPUÉS del bloque de encabezado de grupo.**
  Calculada antes, la etiqueta salía una fila por encima y el encabezado se
  comía su sitio: la lista parecía desordenada.
- **`items` y `groups` se copian al allocator del modelo, no a una arena de
  frame.** La palette vive entre frames; si apuntaran al arena del frame se
  quedarían colgando al redibujar por el streamer. Es la MISMA trampa que
  avisa el punto de graphemes, y costó dos crashes.
- **Toda tecla consumida por la palette pone `ctx.redraw = true`**, incluso
  las que no cambian nada de la acción. Sin eso, escribir en el buscador
  mutaba el estado pero la pantalla se quedaba igual (y Esc "no cerraba").
- **Los modelos se descargan en un worker**; la modal se abre igual solo con la
  columna de providers (que es local) para no dejar una espera en blanco.
- **Las keys van a `~/.config/zode/auth.json` con permisos 0600**, nunca a
  `config.json` (que la gente versiona). Se escribe en un temporal y se
  renombra, para que un fallo a mitad no deje media key en un 0644.
- `{f}` **no formatea** `json.ObjectMap` ni `json.Array` en el writer de 0.16:
  hay serializadores a mano en `config.zig` (`writeStringMap`, `writeJsonString`).

## Scroll

- PageUp/PageDown mueven una **página** (la ventana, menos una línea), no 5
  fijas. `hist_rows` se publica desde el draw (el único sitio que sabe el alto).
- **Ctrl+U / Ctrl+D** = media página, como en less y en Claude Code.
- Indicador `↓ N` en el status cuando el historial no está anclado abajo: sin
  él se pierde la noción de "por qué no baja solo".
- `ctx_used`/`ctx_pct` están **cacheados en el agente** y se refrescan al
  cerrar cada turno: el status bar los lee en cada frame y recorrer el
  historial 60 veces por segundo es trabajo tirado.

## Estado

**Hecho**: TUI con editor multilínea propio, autocompletado `/`, diff de
write/edit, paleta Ctrl+P (comandos + modelos a dos columnas), connect de
providers, scroll por página, status bar segmentado con la info de sesión, y
azul de marca (truecolor) en cabecera, bordes y status.

**Siguiente**: Skills, MCP over stdio, E2E contra Anthropic con key propia, y
`@file` mentions (aplazado).

## Bugs de junio 2026: los que costaron horas (todos verificados)

Estos no son hipotéticos: salieron todos durante una sesión de depuración real.
tienen ya un test que los caza; **no reintroducirlos**:

### `drainPending` reseteaba el scroll en CADA frame
`self.scroll = 0` estaba al final de `drainPending`, que se llama en cada draw
aunque no haya nada nuevo. Resultado: `scrollBy` ponía 17 y el siguiente frame lo
borraba. **PageUp no movía nada y parecía que el scroll no funcionaba.** Ahora
solo re-ancla si `pending.items.len > 0` **y** `scroll == 0` (sticky bottom: si
estás leyendo arriba, el texto nuevo no te tira de vuelta).

### Enter no mandaba si el autocompletado estaba abierto
`acceptAutocomplete` se llevaba la tecla y reescribía `/help` como `/help ` sin
enviar. Había que pulsar Enter dos veces, y como tampoco se enviaba nada, la
vista se quedaba vacía y el scroll "no tenía nada que enseñar". Ahora
`isExactMatch` detecta que lo escrito ES el comando y deja caer la tecla hasta
el editor.

### `streamChat` recibía la base URL, no la URL
`runOneTurn` pasaba `def.base_url` tal cual; `streamChat` espera la URL **completa**
(`{base}/chat/completions` o `{base}/messages` para Anthropic). Todas las
peticiones de la TUI eran un 404. El runner headless de `main.zig` sí añade el
path, por eso ahí funcionaba y era invisible en los tests.

### `writeFileSecure` llamaba a `configDir(null, …)`
`configDir` devuelve null sin entorno, así que "Connect an integration" **nunca**
podía guardar: siempre "no se pudo escribir auth.json". El `env` es un parámetro
de la función, se le pasa `m.environ`.

### La key guardada no se usaba
`providers.keyFor` solo miraba variables de entorno, así que conectar un provider
guardaba la key y luego se ignoraba. Ahora hay un `saved_keys` en memoria
(cargado de `auth.json` al arrancar, actualizado al guardar) que **gana** al
entorno, y `reloadUserConfig` + `loadAuthKeys` lo refrescan. Con test de orden de
precedencia.

### `std.atomic.Mutex` no es reentrante
`pushHeader` cogía el lock y dentro llamaba a `pushKind`, que lo vuelve a coger:
la app se quedaba esperando un mutex que ella misma tenía y se colgaba **antes
del primer frame** (pantalla en blanco, 0 bytes escritos). Envolver en un
`pushPending` que encola con el lock ya cogido una sola vez.

### El hint de la paleta se pintaba encima de la etiqueta
Solo se comprobaba que el hint cupiera, no que cupieran hint **y** etiqueta: en la
columna estrecha de providers se leía `anthrclaude-sonnet-4-5`. Ahora se mide en
columnas (`displayWidth`, no bytes) y si no caben los dos, el hint se omite: la
etiqueta es lo que se selecciona.

## Errores de red: el mensaje del server es lo único útil

`StreamCtx` guarda los primeros 512 bytes del body (`noteRaw`) porque en un 4xx/5xx
es el JSON de error, y `setServerMessage` saca el texto de `"message":"…"`.
"HTTP 403" no dice nada; *"Model access is disabled"* sí.

Cada status tiene su error propio porque la **acción** que toca es distinta:

| status | error        | reintenta | mensaje                                        |
|--------|--------------|-----------|------------------------------------------------|
| 401    | AuthFailed   | no        | key rechazada, revisa `ZODE_<P>_KEY`           |
| 402    | NoCredits    | **no**    | sin créditos → modelo `-free` o `/provider`    |
| 403    | Forbidden    | no        | el MODELO no está disponible para tu cuenta     |
| 404    | ModelNotFound| no        | el modelo no existe → `/model`                 |
| 429    | RateLimited  | **sí**    | reintento con backoff                          |
| 503    | Overloaded   | **sí**    | reintento con backoff                          |

El 402 se reintentaba 3 veces como si fuera un 5xx: tres esperas de backoff para un
error que no se arregla solo. Y el 403 se reportaba como "key mala" cuando casi
siempre es el modelo.

**El default model de un provider es una bomba de relojería**: `kimi-k2.6` desapareció
de la lista de opencode y TODAS las peticiones dieron 403 hasta cambiarlo. Cuando
un provider retire un modelo hay que cambiar `default_model` en `providers.zig`.

## Módulos yStreamCtx: `deinit` que se destruye a sí mismo

`StreamCtx.deinit` hacía `gpa.destroy(self)`. Renombrado a **`destroy`** porque
un `defer ctx.deinit()` sobre un StreamCtx del stack revienta con *Invalid free*.
Solo se usa con los que salen de `gpa.create`.

## Marcadores de la cabecera: `*…*` y `~…~`

La cabecera tiene DOS tipos de marca porque el logo es fijo y el color de Zo no:

- `*…*` → `brand_hi` (#c0caf5): el wordmark y el tagline, un tono por encima del
  búho para que el logo se lea encendido contra el arte.
- `~…~` → el estilo que **pasa el llamante**: la carita de Zo, con el color de su
  mood (que hasta ahora `Mood.color()` no se usaba para nada visible).

Las marcas se QUITAN del texto: quien llama ve el texto limpio, el dibujo sale con
varios colores. Una marca sin pareja es texto normal (nunca se pierde un byte).
El invariante está testeado contra el `mascot.banner` real, no contra una cadena
escrita a mano, para que el test siga siendo válido si se edita el arte.

## Conectar providers (Ctrl+T → Ctrl+A)

- **Ctrl+T** abre la paleta de modelos a dos columnas (providers | modelos).
- **Ctrl+A** abre el prompt de key del provider **resaltado en la columna
  izquierda** (o el activo si no hay ninguno). El pie lo anunciaba y no hacía
  nada, que es peor que no anunciarlo.
- El prompt muestra a qué provider va la key, enmascara con los 3 últimos
  caracteres visibles, y al guardar vuelve a la paleta con el estado actualizado.
- La key se serializa desde el mapa entero ya actualizado: si además se añadiera a
  mano, salía duplicada (`{"a":"x","a":"x"}`).
- `auth.json` con 0600, escrito en temporal y renombrado.

## Estado

**Hecho**: color de marca en cabecera/bordes/status, status bar segmentado con
`modelo · provider (effort) · ctx% · tok/s`, scroll por página con Ctrl+U/D y
sticky bottom, paleta Ctrl+P (comandos agrupados) y Ctrl+T (providers | modelos a
dos columnas), conectar providers con Ctrl+A, errores de red con mensaje del
server, banner nuevo con la mascota en color de marca.

**Siguiente**: Skills, MCP over stdio, `@file` mentions (aplazado), y lo que acordemos al final de esta sesión.

## Bugs de la ronda de fuzzing (2026-06-29)

Todos aparecieron con `fuzz.py` (secuencias aleatorias de teclas contra la TUI
real, con red y hilos) y tienen ya un test. **La lección: una TUI no se prueba
pulsando cuatro teclas**; hace falta bombardearla.

### La rueda del raton tumbaba la app
`self.scroll` es `usize` y la rueda hacia `self.scroll -= 3`: con el scroll en 0
eso desborda -> panic. Lo minimice a dos `\x1b[<65;...M` seguidos. Ahora la rueda
usa `scrollBy`, que satura en 0. **Cualquier aritmetica de scroll pasa por
`scrollBy`; nada toca `self.scroll` a pelo.**

### `key[1..]` sobre una key vacia
En Zig 0.16 un slice `0..1` sobre un `[]const u8` de len 0 es un panic, no un
slice vacio. `cmdGroup` quitaba la barra sin mirar. Ahora quita la barra solo si
la hay, y hay test con key vacia y sin barra.

### `/model` se mandaba como `/models`
El autocompletado aceptaba con Enter comparando la coincidencia exacta SOLO
contra el item resaltado, y el popup ordenaba `/models` antes que `/model`.
Escribiendo `/model` + Enter se acababa mandando `/models` (otro comando).
Ahora: **si lo escrito es un comando completo se manda; si es parcial, se
completa.** Tab siempre acepta.

### Un crash al salir por literales en la paleta
`freeItems` liberaba `label`/`hint` de la paleta, pero el item `+ connect` traia
**literales** (`"+ connect"`, `"ctrl+a"`). `gpa.free` sobre `.rodata` es un
*Invalid free* que solo salia al salir de la app, con la paleta ya a medio
destruir: atribuirlo al item causante es casi imposible. **Todos los label/hint
de la paleta son copias propias; `buildModelItems` es el unico constructor.**

### Los punteros colgantes de la columna de modelos
El worker entregaba un `[]models_mod.Model` y acto seguido liberaba la lista: los
`id` de los items quedaban colgando y el dibujo reventaba con `InvalidStartByte`.
Ahora el worker construye los **items** (strings propios) y los deja en
`pending_items`; el draw los recoge. `Palette.setItemsOwned` pasa a ser duena y
libera los anteriores, asi que tampoco crece la memoria.

### La paleta se modificaba desde dos hilos
El worker de modelos rellenaba la paleta mientras el hilo de la UI la dibujaba
**sin lock** (el lock solo cubre el historial) -> segfault. El worker ya no toca
la paleta: deja los items y el draw los aplica.

### Workers desacoplados + `io` destruido = use-after-free
Los hilos se lanzan con `detach`: nadie los une. Al salir, `app.deinit()`
destruia el `Io` mientras un worker seguia dentro de `io.async`
(`Threaded.cancelThreads` -> segfault). Ahora hay un contador atomico de workers
y `runTui` hace `model.waitWorkers(2000)` **antes** de que corran los `defer`, con
tope de tiempo para no colgarse si un worker esta atascado en red. La espera
cuenta vueltas con `yield`, no con el reloj: durante el apagado consultar la hora
a traves del `Io` es justo lo que no se debe.

### Recargar el config liberaba la arena de las keys
Conectar un provider llama a `reloadUserConfig`, que liberaba la arena del
config. Pero las keys de `auth.json` vivian ahi, y un worker de modelos
descargando la lista estaba leyendo `saved_keys` por `providers.hasKey` en ese
mismo instante: uso despues de liberar, sin que nada lo delate (solo pasa si el
worker cae justo en esa linea).

Ahora las keys tienen **arena propia que no se destruye hasta salir del proceso**
(`keys_arena_state`): recargar solo reasigna el puntero, que es atomico, y el
mapa viejo sigue siendo memoria valida hasta el teardown.

**Regla: un mapa que se puede leer desde varios hilos no se libera nunca en
runtime; se reasigna el puntero y se tira todo en el teardown, cuando ya no
queda nadie leyendo.**

## Filtrado de la paleta: el grupo veta y las dos columnas se vacian

Dos bugs que hacen que la lista de modelos parezca vacia:

1. **El nombre del grupo VETABA la coincidencia.** En `matches` el grupo se
   comprobaba con `return containsIgnoreCase(g.name, q)`, o sea "si el grupo no
   coincide, el item no existe". Buscar `sonnet` no encontraba
   `claude-sonnet-4`, porque vive en el grupo "Models" y ahi no aparece
   "sonnet". Con la lista filtrada vacia, Enter acababa aplicando un modelo que
   **no** era el resaltado (parecia que si, porque la eleccion por indice caia
   en el primero). El grupo es una via MAS para encontrar, nunca un veto.
2. **Filtraban las dos columnas.** Con foco en Modelos, escribir `sonnet`
   vaciaba tambien la columna de providers y se veia "no matches" en las dos:
   la sensacion de que la lista de modelos no existe. Ahora **solo filtra la
   columna con el foco**, y la otra se queda de contexto. Al cambiar de columna
   (`Tab`, flechas) se vuelve a filtrar.

Y el mas tonto de todos: `openModelPalette` fijaba el modo **despues** de
`setItemsOwned`, y `resetSelection` calcula la columna activa a partir del
modo. Con el modo viejo se quedaba en providers: las flechas no movian los
modelos. **El modo va antes que `setItemsOwned`.**

Ademas, las dos columnas resaltaban su fila y no se sabia cual tenia el foco.
Ahora solo resalta la enfocada; la otra marca la fila elegida con `>` en azul
apagado (se ve cual es sin parecer que tiene el foco).

## El slime: tres formas fallidas antes de acertar

El ascii art de una mascota es cuestion de gusto, y el de zode paso por tres
versiones que estaban mal y que dejan en claro lo que hace que algo "se lea":

1. **Cuadrado simetrico** (el primero): no tiene silueta. Es un cojin.
2. **Cúpula + base que se derrama**: la forma correcta de una gota de agua, no
   de un slime. Con los anchos subiendo y bajando, parecia un champinon.
3. **Gota con chorreon arriba**: parecia una gota de agua con burbujas, no un bicho.
4. **Slime de Minecraft** (el que hay): cubo de esquinas redondeadas MAS ALTO
   QUE ANCHO, con los dos ojos ovalados y la boca ancha del sprite del juego.

**Lo que importa es la proporcion, no el adorno.** El slime del juego es alto y
estrecho; cualquier cosa cuadrada lee como caja. Y los ojos y la boca van
**rellenos** de `█` porque en el sprite son manchas oscuras, no contornos.

Los anchos se calculan centrando cada fila sobre la mas ancha con un script, no
a ojo: a mano queda torcido en la tercera fila siempre.

## EL FUZZER ESCRIBE EN TU CONFIG REAL

`fuzz.py` teclea teclas pseudoaleatorias, entre ellas `ctrl+a` y `enter`, que
abren el prompt de "connect" y **guardan una key en `~/.config/zode/auth.json`**.
En una ronda guardo `"opencode": "pasted texthelpoommxllmm"`, que como la key
guardada tiene prioridad sobre el entorno, tapaba la key buena del `.env` y dejo
el provider con 401 "Invalid credential" sin explicacion apparent.

- **El fuzzer corre con `HOME` propio** (`/tmp/opencode/fuzzhome`). No tocar
  nunca la config real con pruebas automaticas.
- `normalizeKey` rechaza keys con espacios o demasiado cortas, que es lo que
  atrapa un texto pegado por error. Con test.

## El default de opencode

Solo `space-bunny-free` responde; el resto del free tier de opencode da 403
("can only be used from within OpenCode") porque esta gateado al cliente
oficial. Los de pago dan 402 sin creditos. Asi que el default es ese, y el
`note` del provider lo dice para no perder tiempo probando los otros.

## La cache de Zig sirve artefactos rancios

`zig build` con el fuente limpio seguia instalando un binario con un `print` de
depuracion que ya no existia, y `touch` no lo arreglaba. **Si una traza o un
cambio "no aparece", borra `zig-out/bin/zode` y reconstruye** antes de perder
media hora creyendose loco. Comprobar con `strings zig-out/bin/zode | grep <texto>`
es el fastest check.

## Liberar un LITERAL desde el worker: `[]const u8` no lo dice

`execToolCalls` devolvia el literal `"Continue with el tool results above."` con
el tipo `?[]const u8`, y `chatWorker` lo liberaba porque asumia que todo lo que
devolvia `runOneTurn` era suyo. Liberar `.rodata` con el allocator del proceso
es un **"reached unreachable code"** en ReleaseSafe: cualquier turno que usara
una tool tumbaba la app, siempre.

El arreglo de fondo no es el `dupe` (que arregla el síntoma), sino el **tipo**:
las funciones que devuelven memoria propiedad del llamante devuelven `[]u8`, y
los literales de Zig son `[]const u8`, asi que el compilador IMPIDE devolver uno
por ahi. Mismo criterio que `setItemsOwned` en la paleta: la propiedad tiene que
estar en la firma, no en un comentario.

## El agent loop de la TUI estaba ROTO con tools (y en silencio)

Un turno con tool en la TUI: la tool se ejecutaba y **la respuesta final nunca
llegaba**. Sin error visible, porque el aviso del API se quedaba en `pending`
y hacía falta pulsar una tecla para verlo. Dos bugs encadenados:

1. **El mensaje del asistente se guardaba SIN sus `tool_calls`**
   (`appendAssistant(text, null)`). El mensaje de tool lleva `tool_call_id`, así
   que no casaba con nada y el API devolvía 400 `invalid_request_error` en el
   turno SIGUIENTE. Ahora `toolCallsJsonFromCalls` reconstruye el JSON (el
   MISMO formato que `chat.StreamCtx.toolCallsJson`, que es el que usa el
   runner headless: si divergen, uno de los dos clientes manda una conversación
   que el otro no puede leer). Con test que fija el formato literal.
2. **Nadie abría el párrafo en vivo de las iteraciones.** `streamEnd` solo fijaba
   el párrafo `if (streaming)`, y tras la tool no se llamaba a `streamStart`: los
   deltas de la respuesta se acumulaban en `stream_buf` sin dueño y se
   descartaban. Ahora cada iteración abre párrafo con `streamStartIteration`
   (que NO resetea el reloj de la franja, a diferencia de `streamStart`: un reloj
   que salta a 0 en cada iteración no sirve para distinguir "lento" de
   "colgado"), y `streamEnd` tiene `or stream_buf.len > 0` para no perder texto.

Y el tercero, ya de paso: **el system prompt se reinsertaba en cada iteración**
(`items[0].role != .system` con el user ya appendado, así que `items[0]` era
`user`). El segundo turno salía como `[user, system, tool, system]`. Ahora se
busca el system en TODA la lista.

Cómo se encontró: la tool nueva (`web_fetch`) prompts, el turno se quedaba en
"thinking" para siempre, y el primer impulso fue "es la tool nueva". Con el
`[DBG]` puesto en el bucle salió `iter 1 ERROR ServerError` en un `bash` de
`echo hola`: no tenía nada que ver con la web.

## `Io.sleep` desde un worker CONGELA la TUI (y ya lo ha hecho dos veces)

`Retry.wait` y `chat.sleepMs` usaban `io_global.sleep`, y eso se lleva por
delante el event loop del `Io` compartido con la UI: durante el backoff se
paran los redraws, el reloj de la franja se congela y los avisos de reintento se
quedan en `pending` sin pintar (hay que pulsar una tecla para verlos). Es
exactamente el problema que el ACP resolvió con `nap()`, y la solución es la
misma: un `nanosleep` pelado, sin tocar el `Io`. `Retry.wait` duerme a trozos de
50 ms para que ESC corte, y respeta `retry-after` del server (que se leía en
`chat.retry_after_secs` y **no lo leía nadie**: un 429 con `retry-after: 30`
esperaba 1 s y se comía el rate limit entero, tres veces). Techo de 30 s.

## Los mensajes del status tienen que decir POR QUÉ, no solo QUÉ

- La etiqueta de la franja de actividad es la FASE: `thinking` / `streaming` /
  `running <tool>` / `waiting for your permission` / `queued`. Antes era
  "working" siempre, y 40 s de "working" no distinguen pensar de escribir de un
  `bash` colgado.
- `pushRetryNotice` dice el error en palabras (`errPhrase`), el texto del server
  y cuánto falta: `rate limited: Too many requests · retrying in 1.0s (attempt
  2/3)`. `@errorName` da identificadores (`RateLimited`), no mensajes.
- `execToolCalls` acaba con `3 tools · 1.2s` (+ `· denied` si hubo) en vez de
  "tools done", y el turno con `done · 12.4s`.
- El backoff era `1 << (attempt -| 1)`, que satura a 0: la serie real era
  500/500/1000 ms, no los 500/1000/2000 que decía el comentario. Ahora `1 <<
  attempt`, con test.
- Los tok/s del status bar solo se pintan **mientras hay stream**: `tps_live` es
  el del último stream y no se borra, así que con un `bash` de 30 s la fila
  seguía anunciando "⚡ 42 tok/s" sin llegar ni un token.

## Prompts en cola

`startChat` no comprobaba si habia un turno en curso, asi que mandar un segundo
prompt lanzaba OTRO worker y los dos peleaban por la sesion y por el estado de
streaming: el input se freezeaba, el historial se entrecortaba y no se tenia ni
idea de si estaba trabajando o colgado.

- `Model.queue` con `enqueuePrompt` / `takeQueued` / `queuedCount` / `clearQueue`,
  todo bajo lock.
- El worker, al terminar sus turnos, **saca el siguiente de la cola y sigue** en
  vez de terminar y que otro worker compita.
- `deinit` libera la cola Y su buffer: `clearQueue` conserva la capacidad (bien
  para no reasignar en cada prompt), asi que `queue.deinit` va aparte o fuga.

## Franja de actividad: la mascotita es el indicador de "trabajando"

Una fila encima de la caja del input, que **solo aparece si hay algo que decir**
(en reposo no ocupa nada):

- La carita **anima** entre dos fotogramas (`mascot.faceFrames`): ojos abiertos
  y entornados. Un icono estatico no distingue "pensando" de "colgado".
- El estado: `working` / `queued` / `waiting for your permission`.
- **Los segundos transcurridos**: es lo unico que responde a "¿se ha pegado?".
  Ojo con las unidades: el valor son **milisegundos** y se imprimen como
  `{ms/1000}.{(ms%1000)/100}s`; tratado como decimas salia "153.3s" con 1.5s.
- La cola: cuantos y cual es el siguiente.

El reloj usa el `Io` que se pasa con `Model.attachIo` y un flag `io_ready`: los
tests construyen un Model sin app, y leer un `Io` sin inicializar es usar
basura como tabla de vtable.

## Limpiar el historial antes de pintar

El parrafo en vivo se re-envuelve en cada frame y al ENCOGER (cada vez que el
modelo respira entre tokens) las celdas sobrantes conservaban el texto viejo: se
veia la misma respuesta **dos veces, partida y mezclada** ("deSsyftware:tcorregir").
Se limpia el area del historial con un `fillRange` antes de pintar los bloques.

## Separacion entre parrafos

Una fila en blanco entre bloques, para que el historial no sea un muro de texto.
Dos cosas que costaron un rato:

- La fila se **anade al array de lineas** (un `PLine` vacio al principio), no se
  suma solo al alto: `drawLines` recorre `c.lines`, asi que si el alto dice mas
  de lo que hay, se pierde el ultimo bloque.
- Va **delante**, no detras: puesta al final el hueco salia despues de cada
  parrafo y no separaba nada.

Los tests de render buscaban filas concretas (0, 1, 2) y se rompian con cada
cambio de layout. Ahora usan `findRow` / `hasBlankRowBetween`, que buscan por
**contenido**.

## Flujos de la UI (los que pidio el usuario)

- **Ctrl+P** -> paleta de comandos agrupados (Connect · Suggested · Model ·
  Session). `Enter` **ejecuta** el comando elegido (ver "La paleta EJECUTA, no
  rellena"). La excepción es `/use`, que necesita argumentos.
- **Ctrl+P -> Connect -> provider -> key** es la via corta para conectar: el item
  `Connect` de la cabecera abre un modal con todos los providers y su estado de
  key; `Enter` en uno abre el campo de la key. Al guardar se vuelve a esa misma
  lista con el estado ya actualizado (a "key ok"), que es donde se ve que ha
  funcionado. Tirar al usuario a la paleta de modelos le deja con una columna
  vacia sin saber por que.
- **Ctrl+T** o **/model** -> "Switch model" a dos columnas (providers | modelos).
  **Abre al instante** con la columna de providers (que es local) y los modelos se
  rellenan cuando llegan de la red: antes no se abria nada hasta que el provider
  respondia y con uno lento parecia que el comando no hacia nada.
- **Ctrl+A** abre el modal de conectar directamente.
- La franja de actividad va encima del input, y los bloques del historial van
  separados con una fila en blanco. Los tokens y el ctx% salen SIEMPRE en el
  status bar (antes el ctx% solo aparecia tras un turno entero, y al empezar no
  se veia nada, que parecia que el contador no existia).
- Las keys van a `~/.config/zode/auth.json` con 0600, nunca a `config.json`.
  `providers.keyFor` mira primero las guardadas y luego el entorno, para que
  conectar de verdad sirva para algo.

## UI en ingles

La UI visible esta en ingles, el system prompt del agente tambien (los modelos
responden mejor) y **los comentarios del codigo tambien**. Se cambio en
septiembre de 2026: el codigo lo lee gente que no es quien lo escribe, y dos
idiomas en el mismo fichero hacen que las_cauciones se lean a medias.

Los NOMBRES DE TEST siguen en espanol a proposito: son el indice de lo que
cubre la suite, y el nombre entero es lo que diria "esto se rompio" si se
quitara el test.

## La paleta EJECUTA, no rellena

Elegir un comando de la lista con `Enter` lo **ejecuta**. Antes ponia la
etiqueta en el input y hacia falta un `Enter` mas, y como la paleta se cerraba
antes de escribir, el comando se quedaba a medias hasta la siguiente tecla: se
leia como "esto no hace nada".

- `agent.runPaletteCommand` decide y devuelve `done` / `needs_args` / `quit`.
  `/use` es el UNICO que necesita argumentos (vuelve al input con la barra
  puesta); `/quit` lo atiende la TUI porque es quien tiene el `ctx.quit`.
- El comando hace eco en el historial como `.user`, igual que si se hubiera
  tecleado, para que se vea QUE se ejecuto y no solo que paso algo.
- La paleta se cierra **antes** de despachar: algunos comandos la reabren con
  otro contenido (`/model` -> paleta de modelos) y si siguiera activa, esa se
  dibujaria encima y el `esc` de la nueva no cerraria la vieja.
- El pie de la paleta dice `enter run`, no `enter insert`.

De paso, dos bugs que salieron al tocar esto:

- **`Palette.close` soltaba los items sin liberarlos.** Hacia `items = &.{}` a
  pelo, asi que cada Ctrl+P cerrado era una fuga de las etiquetas, y `owns_items`
  se quedaba en `true` sobre una lista vacia (la paleta parecia dueña de algo
  que ya no tenia). Ahora `close` NO toca los items: se liberan en el siguiente
  `setItemsOwned` o en `destroy` (que es lo que llama `Model.deinit`). Con
  test.
- **`/effort` sin argumentos contestaba "unknown effort"**. `it.rest()` devuelve
  `""`, no `null`, para "/effort", y el `else` de "low|medium|high" se comia el
  caso: el picker no se abria nunca. En `submit` ahora un resto vacio es un
  `null` de verdad. Con test.

## El banner: ZODE en letras de bloque, y por que NO un bicho dibujado a mano

Tres versiones de criatura (cuadrado simetrico, cupula con base derramada, gota
con chorreon) salieron mal por la misma razon, y merece escrito porque se va a
repetir en cuanto alguien quiera "un mascotito mas bonito":

**`▀` y `▄` pintan MEDIA celda.** `▀` es la mitad de ABAJO, `▄` la de ARRIBA, y
`█` la entera. Dibujar un contorno con medias celdas deja los bordes a media
altura: el resultado no es una silueta, es un monton de barras sueltas. Se
intentó arreglar conservando y perdiendo mitades y no funciono, porque el
problema no es cual mitad se conserva sino que el dibujo depende de que la
terminal alinee filas y columnas con exactitud milimetrica.

**Con caracteres de cajetin (`█ ╗ ╝ ═ ║`) todas las celdas se pintan enteras**
y la forma es la que uno cree. El ASCII art con cajas es engañosamente
fragil; el de cajetin no.

Por eso el banner es el nombre en letras de bloque (figlet "big"), 6 lineas, y
la mascota se queda como **una carita de una linea** para la franja de
actividad y el status bar, que es donde tiene que ser legible sin ocupar filas.

## La fila de status va por SEGMENTOS, y la carita en el color de su mood

La queja fue "esto ni se nota por el color". El motivo: la fila se componia
como **una sola string** pintada entera con `brand_soft` (el azul apagado), asi
que la carita salia del mismo gris apagado que el texto. `Mood.color()` no se
usaba para nada visible.

- La fila se compone como `[]InfoSeg` y se pinta celda a celda: la carita con
  `Mood.vaxisColor()` en negrita, el texto en `brand_soft`, el spinner aparte.
- El mood lo pone quien compone el status (`setStatusWithMood(mood, texto)`), no
  se deduce de `busy`: el agente sabe si esta pensando, esperando permiso o
 colgado, y el estado de la TUI solo sabe dos de esas tres cosas.
- `setStatusWithZo` YA NO mete la carita en el texto. Antes la metia, y como
  la fila tambien la pintaba, salian **dos** (una en la franja y otra en el
  texto) y la segunda en gris. Si se cambia uno, hay que cambiar el otro.

## `putText` devuelve la COLUMNA FINAL, no el ancho

`p.putText(col, row, text, style) u16` devuelve la columna en la que acaba. Asi
que **`col += p.putText(col, ...)` esta mal** (suma dos posiciones absolutas) y
`col = p.putText(col, ...)` es lo correcto. Ese bug mando la "A" de "always
allow" a la columna 92 de un panel de 68, fuera de la caja, y hacia fallar el
test de las cuatro opciones. Solo se haFixed en dos sitios; cualquier bucle
nuevo que encadene textos tiene que hacerlo asi.

## El dialogo de permisos es un MODAL centrado, no cuatro lineas

Antes eran cuatro lineas pegadas justo encima de la caja del input, en medio
del flujo normal: con el historial lleno se veian a medias o las tapaba el
caja, y la app parecia **colgada** esperando algo que nadie veia. Ahora es
`drawPermissionModal`: caja centrada, fondo limpio (si no, el historial se
transparentia debajo), borde en amarillo, tool y argumentos, y las cuatro
opciones con su tecla resaltada. Se dibuja **encima de todo**, justo antes que
la paleta.

Y la captura de verificacion tiene que **esperar a que el modal aparezca** antes
de mandar la tecla: mandarla a los 6 s cuando el dialogo tarda 12 s no prueba
nada, la `n` se va al input y parece que el atajo no funciona.

## Las tools se marcan para que el parser las pinte en dos tonos

`pushToolStart` compone `*write*(hola.js)`: el nombre marcado con `*…*` para que
`markdown.markedSegments` lo pinte en el color fuerte de la tool y el argumento
en el apagado. Sin la marca, `write` y `hola.js` salian del mismo cyan y no se
distinguian de un vistazo. El resultado de la tool usa el mismo truco
(`*resumen* · Nms`) con `tool_res_bold`.

**Sin espacio antes del parentesis**: los tests buscan `read(src/tui.zig)`, y un
espacio los rompe. Los marcadores se quitan al pintar: la fila nunca los
muestra (test).

## La cabecera NO lleva separador de parrafos

La separacion de parrafos (una fila en blanco) partia el ASCII art en trozos:
una fila en blanco entre letras y el logo deja de leerse. `prev_banner` en el
bucle de la cache de segmentos desactiva el separador alrededor de `.banner`.

## Detalle al escribir tests de dibujo

- Una carita son **varios graphemes** en celdas distintas (`◔◕`): comparar la
  string entera contra `cell.char.grapheme` no casa nunca. Hay que recorrer con
  `vaxis.unicode.graphemeIterator`, como hace el painter.
- Buscar lineas de arte por un **trozo** es fragil: `█████╗` (linea 3) es
  subcadena de `███████╗` (linea 1), asi que `findRow` devuelve la fila 0 y el
  test compara una linea consigo misma. Comparar la fila **completa**.
- La carita sale **tanto en la franja de actividad como en el status**: `findRow`
  encuentra la primera, y el test acaba comprobando la fila equivocada. Para el
  status hay que leer `s.readCell(col, height - 2)` directamente.

## Estado

**Hecho**: tools de web (`web_fetch` con HTML→texto, `web_search` por
DuckDuckGo, sin permisos) + `web.zig` puro con tests, **agent loop de la TUI
arreglado** (el mensaje del asistente llevaba `null` en vez de sus
`tool_calls` y mataba el turno con 400 silencioso; y el párrafo de la
iteración post-tool no se abría, así que la respuesta final se perdía),
franja de actividad con la FASE (`thinking`/`streaming`/`running <tool>`) en
vez de "working", mensajes de reintento con el motivo y la espera, cabecera con
**solo el wordmark ZODE** (5 filas de ASCII puro, sin mascota ni línea de saludo
ni línea de atajos: Houston se probó y se rechazó, ver "v4"), la paleta de
Ctrl+P **ejecuta** el comando elegido en vez de dejarlo en el input, dialogo de
permisos como modal centrado, fila de status por
segmentos con la carita en el color de su mood, tools en dos tonos, UI en
ingles, Ctrl+T (/model instantaneo a dos columnas), Ctrl+A (conectar), scroll
por pagina con Ctrl+U/D y sticky bottom, errores de red con el mensaje del
server, y los crashes del fuzzing.

**Siguiente**: Skills, MCP over stdio, `@file` mentions (aplazado), permisos
selectivos (que las tools inocuas corran sin preguntar en vez de solo con
`/yolo` global), `web_fetch` con budget por rango (ahora solo lee el principio
del documento) y un buscador de verdad detrás de `web_search`, y lo que
acordemos al final de esta sesion.

## El banner: tres versiones, y la que se quedó

**v1 (cajetín, figlet "big")** — filas desalineadas, se leía "diec FERE". El
problema de fondo: un art de cajetín es un **mapa de celdas**, y si las filas no
caen en las mismas columnas no hay nada que leer. Además el test que lo vigilaba
medía con `.len`, que son BYTES (la fila 0 "medía" 101 columnas), así que
pasaba siempre.

**v2 (cajetín, composed en comptime)** — bien alineado y bien en la pty de
pruebas. En la terminal del usuario era **ilegible**: un manchurrón con relieve
que no se leía como nada. Motivo: un art de `█ ╗ ╝ ═ ║` depende de cómo dibuja
la fuente el bloque completo, y con doble ancho o sustituto los trazos se
ensanchan y se solapan.

**v3 (ASCII puro, el que hay)** — `#` y espacio, 5 filas, cuatro cajas de 6
columnas. Se lee igual en cualquier terminal y `O` y `D` se distinguen de una
vez (que era el otro fallo: se leía "ZOOE").

Lo que quedó:

```
######  ####  ####   ######
##  ## ##  ## ##  ## ##
   ##  ##  ## ##  ## ##
  ##   ##  ## ##  ## ##
######  ####  ####   ######
```

Dos cosas que costaron y hay que saber:

- **`#` choca con el markdown.** Toda fila que empieza por `##` es un
  ENCABEZADO, y el parser se come los `#`: el logo salía como
  "####  ####  *zode*". El arreglo de fondo es que `parseBase` no busque
  estructura en `kind == .banner`: el banner es un dibujo, no prosa. Hay un
  test en `markdown.zig` que lo fija, y otro que comprueba que el resto de tipos
  SIGUE interpretando encabezados (el arreglo no es desactivar el parser).
- **El texto (`zode` / `a code agent` / `in your terminal`) se quitó.** Pedido
  explícito: solo el ASCII.

El art se compone en comptime con `bannerRow()` desde la tabla de glifos, porque
en figlet las letras miden distinto y el relleno a la derecha se pierde cuando
un editor recorta los espacios del final de la línea. `banner_art_width` es la
aserción y la comprueba el test del TUI, midiendo en COLUMNAS (`plainColumns`).

## v4: Houston (Astro Boy) — PROBADO Y RECHAZADO

Se hizo la mascota que se pidió (Houston de Astro Boy, cúpula maciza, dos ojos
con anillo/iris/pupila, rejilla de la boca, cuerpo con brazos) y quedó **fuera a
la primera**, con un "es horrible, solo ZODE y quita eso, me rabia tanta basura en
la vista".

El fallo no era el dibujo, y conviene escribirlo porque se va a repetir:

**Una cabecera de TUI se lee en la primera media segundo, y 20 filas de ASCII art
son 20 filas de nada.** Medía 18 de robot + 1 de saludo + 1 de atajos = 20 filas
antes de la primera palabra de la conversación. En una terminal de 30 filas
quedaban 10, y el art es justo lo que se ve mientras "carga". Un robot dibujado
bien no compite con el texto: lo aplasta.

Lo que se quedó es lo de antes: **cinco filas con `ZODE`** y nada más. Ni
mascota, ni "zo the code robot says: hi!…", ni la línea de atajos
`/help · /model · ctrl+p…` (que ya están en la paleta de Ctrl+P y en `/help`).

Detalles que sirvieron y siguen vivos:

- **El art no puede usar `*` ni `~`.** `markedSegments` (`markdown.zig`) quita
  del banner los `*…*` y los `~…~` porque son MARCAS de estilo: un ojo
  dibujado con `***` se quedaba sin borde, y con un número impar de filas los
  asteriscos de una se emparejaban con los de otra.
- **Las dos mitades se componían por separado** (`robotRow` rellenaba a
  `robot_art_width`, `bannerRow` componía el wordmark desde la tabla de glifos,
  `bannerLine` las pegaba con dos columnas de aire y centraba el wordmark en la
  vertical de la cabeza). El wordmark pegado a la fila 0 se leía a la altura de
  la cúpula y parecía un rótulo suelto. Para volver a poner una mascota al lado
  del nombre, ese es el reparto que funciona.
- **`banner` se armaba con un bucle dentro de un `blk` de comptime**, porque
  `bannerLine` pide una fila de COMPTIME: con un `for` normal en runtime el
  índice no lo es y no compila.

El test de `tui.zig` sigue fijando que debajo del art **no hay nada**: si alguien
vuelve a colgar una línea (o una mascota) en la cabecera, `zig build test` falla.

## Loading de las tools: "working" no dice si esta vivo

Con un `bash` de 30s la ultima fila se quedaba congelada en `⏺ bash(...)`: no
hay forma de saber si el proceso sigue o si la app se cuelga. Ahora:

- `Model.tool_run` (`?ToolRun`): lo pone `pushToolStart`, lo quita
  `pushToolDone` (via `toolRunEnd`). Copias **propias** del nombre y el arg: el
  arg viene de la arena del worker, que se libera al final del turno.
- Una linea `⎿  bash running · 21.4s` bajo la cabecera de la tool, **repintada
  cada frame** desde el bloque de "parrafo en vivo" (el mismo mecanismo que el
  streaming). Reemplaza al parrafo vivo en vez de anadirse: nunca coexisten.
- La franja de actividad y el status bar **nombran la tool** (`working bash
  7.6s`, y el status pone el argumento), porque "working" a secas no dice si
  esta trabajando o colgado.
- `Model.workingLocked()` cuenta `tool_run` como trabajo. Sin eso, entre
  `streamEnd` y `pushToolDone` hay una ventana en la que `busy` ya esta a
  false: sin spinner, sin reloj y con la franja diciendo "queued".

Dos trampas que salieron por el camino:

- **`toolRunEnd` se llama ANTES del `lock()` de `pushToolDone`**: el
  `std.atomic.Mutex` no es reentrante y cogerse con el suyo cuelga la app.
- **El texto de la linea va copiado al arena del frame**, no a un buffer de
  stack: los `CellRun` guardan el grapheme por valor pero con puntero a sus
  bytes, y el pintado ocurre DESPUES del bloque. Es el bug de `&[_]u8{c}` de
  mas arriba, y sale como fila llena de NULs.

## ACP:Implemented, with `/acp`

`src/acp.zig` is a full **ACP v1 client**: it launches `opencode acp` as a child
process and speaks newline-delimited JSON-RPC over its stdin/stdout. This is
the "trick behind the scenes" in its purest form — zode does not poke opencode's
terminal, it talks to opencode's engine.

- `zig build acp-probe -- "prompt"` shows the traffic against a real agent.
  `ZODE_ACP_CMD` points it at another agent (or a fake) without recompiling,
  and `CANCEL=1` exercises the cancellation path.
- In the TUI: `/acp` on, `/acp off` back, `/acp <cmd>` to use another command.
  The status bar says `acp: OpenCode` so it is never a mystery who answered.
- **The connection is opened in the background the moment you type `/acp`**, not
  on the first prompt: `opencode acp` boots a private server and that takes
  several seconds, which used to land on the first prompt with the input
  frozen. The connect thread registers itself as a worker (`beginWorker`) so
  `waitWorkers` waits for it at shutdown, and it pushes the "ACP connected" line
  itself — the UI thread never has to poll for it.
- `pushInfoOwned` takes OWNERSHIP of the text; `pushInfo` copies it. Using the
  first with a string you then free paints a row of `�`.

What is wired: `initialize` (agent name), `session/new`, `session/prompt`,
`session/cancel`, and on the way in: `agent_message_chunk`,
`agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`, and
`session/request_permission` (mapped to the existing y/a/n/Esc dialog, or
answered automatically under `/yolo`). Anything else (`fs/*`, `terminal/*`) is
answered with "method not found" — if you stay silent the turn never ends.

**There is no tool loop in ACP mode.** The agent runs its own tools; zode only
draws the `⏺ tool(...)` header and its result. That is why `AcpTurn` has no
`calls` list and why a turn is one prompt.

### Traps, all of them found by testing

1. **`File.flags.nonblocking = true` does NOT set O_NONBLOCK.** That field is
   only consulted on Windows; on POSIX the `read()` goes out as-is, and with a
   blocking fd the turn hangs forever on the second read. You have to do the
   `fcntl(F_SETFL)` yourself, and note that `fcntl` returns the flags raw: a
   *successful* `GETFL` is a SMALL number (0x44000), errors are huge, so the
   "did it work" check is `fl <= maxInt(u32)` — the other way round skips the
   whole block without a word.
2. **`Io.sleep` from a worker FREEZES the whole TUI.** This is the one that
   really hurt, because it looks like a hang: the clock in the activity strip
   stopped dead while a turn was in flight, and the input still worked, so the
   app looked half-alive. `agent.io_global` and the model share ONE `Io`, and
   `Io.sleep` takes the `Io`'s event loop with it, so the vaxis `tick` that
   drives the redraw stopped firing. Now everything that waits inside a worker
   uses `acp.nap()`, a plain `nanosleep` syscall that does not touch the `Io`.
   (Using the same `Io` from two threads for *work* is normal here — the HTTP
   path does it on every request. It is `sleep` specifically that is the trap.)
3. **`cancel()` only sets a flag.** Writing `session/cancel` from the UI thread
   would be the obvious thing and it is wrong twice over: a blocking read in
   the worker would not see it until the agent happened to speak, and the write
   would race the worker's use of the `Io`. So the pipe is non-blocking, the
   worker polls every 30 ms, and it is the worker — the only thread that writes
   — who sends the notification when it sees the flag. The status then says
   "cancelling…", because the turn does not stop on the spot: the agent has to
   answer with a `stopReason`.
4. **The `File.Reader` eats `WouldBlock` and returns `ReadFailed`**, keeping
   the real error in `reader.err`. Look there, not at what `fillMore` returned.
5. **`pump` has several early `return .line`s, so the line buffer must be
   cleared with `defer`, not at the end.** Otherwise the next line comes out
   glued to the previous one, the JSON does not parse, and the loop eats its own
   queue: the turn froze after the very first message.
6. **Responses have no `method` field.** `root.get("method") orelse return`
   silently swallows the `initialize` response and the handshake waits forever
   for something that already arrived.
7. **In ACP the agent interleaves text and tools.** The streaming paragraph
   must be closed on every tool (`onTool`/`onToolUpdate`), because the live
   paragraph is always painted last: otherwise the tool header lands *above* the
   text that preceded it and its result *below* the closing sentence.
8. **`std.process.spawn` resolves argv[0] with the PATH of the `Io`**, which is
   not zode's environment: a hand-made `Threaded` has none and the spawn fails
   with `FileNotFound` although the binary is right there. `resolveArgv` looks it
   up in the `Environ.Map` and spawns an absolute path. (`statFile` needs a real
   `Io`; `std.posix` has no `faccessat`; and `std.c.access` would tie the binary
   to libc, which zode is careful not to do.)
9. **A `sh` fake agent is not a good test double for a blocking turn**: it
   cannot read its stdin while it sleeps, and its stdout is block-buffered. It
   needs short heartbeat batches (`stdbuf -o0` for the buffering) or it will
   look like a broken client.

### How it was actually verified

- Unit: parse of each `sessionUpdate` variant, the 100 KB line that does not fit
  in the reader's 64 KB buffer, and the full handshake → prompt → stop round trip
  against a `sh` agent that speaks real JSON-RPC over real pipes.
- End to end against the **real** `opencode acp`: handshake OK
  (`agente = OpenCode`, session created), the prompt goes out, and the error
  text the server sends comes back verbatim
  («Insufficient account funds» — the account, not the wire).
- In the TUI under tmux: streaming, interleaved tool with its clock, result and
  closing text, in the right order. **Use tmux, not a homemade pty emulator**:
  vaxis does differential redraws and a small emulator loses half of it (that
  is what made a working turn look frozen).

### What is NOT done

- `session/load` / `session/resume` / `session/list`: zode creates a fresh ACP
  session and keeps it for the life of the process. Resuming would mean
  mapping zode's JSONL sessions to opencode's ids.
- The ACP history is opencode's, not zode's. zode still appends what the agent
  said to its own session file so `/resume` and the diffs keep making sense.
- `current_mode_update` and `config_option_update` (model/effort/mode) are
  parsed nowhere yet: `/model` and `/effort` still talk to the HTTP provider.

**Decision pending**: the other route — talking HTTP to the *shared* service
(`opencode service status` → `127.0.0.1:<port>`, which asks for Basic auth) —
is what would let zode see and drive the sessions of the TUI that is already
running. ACP is the clean one; HTTP is the one that shares state.

## La congelacion de septiembre 2026: NO era rendimiento

Diagnostico completo en `ROADMAP.md`. Lo que hay que retenue, porque las tres
cosas que lo causaban son invisibles en un perfil de CPU:

1. **El bucle del layout no terminaba.** Era
   `while (seg_cache.len < paras.len)` + `orderedRemove(0)` al pasar del tope de
   128: append (129) -> evict (128) -> volver a entrar, para siempre. Con
   `pushDiff` metiendo un PARRAFO POR LINEA de diff, un solo `write` de un
   fichero de 129 lineas colgaba la app al instante. Ahora la cache es una
   VENTANA (`layoutWindow`) con `para_idx` por entrada y `para_heights` por
   parrafo, y hay un presupuesto de iteraciones (`layout_iters` /
   `layout_overflow`) para que una regresion FUTURA falle un test en 1 s en vez
   de colgar el proceso. Ese presupuesto no es decorativo: sin el, el test
   cuelga el runner entero y no hay CI posible.

2. **La cadena de ticks se podia morir para siempre.** El `.tick` solo se
   rearmaba "si hay trabajo", y `busy`/`dirty` tienen ventanas en las que los
   dos son falsos (entre `streamEnd` y `pushToolStart` hay un `write(2)` de
   sesion y un DEFLATE-9 en medio). Un tick ahi dejaba `App.timers` VACIO, y el
   worker no tiene ni puntero al `EventContext` ni a la cola de eventos: no
   habia forma de pedir un frame. El tick se rearma SIEMPRE ahora.

3. **`requestPermission` hacia spin-yield sobre el lock del HISTORIAL** durante
   los 30 s que tardas en decidir: quemaba un core y hacia que cada adquisicion
   de lock de la UI fuera un `yield` fallado. Ahora tiene lock PROPIO y espera
   dormida con `nanosleep` y backoff 1->20 ms.

## Correccion: el diagnostico delACP sobre `Io.sleep` era erroneo

`acp.zig` decia (y este documento lo repetia) que "`Io.sleep` secuestra el bucle
de eventos de vaxis". **En Linux es falso**, y conviene corregirlo para que
nadie vuelva a investigarlo:

- `Io.sleep` es una llamada a la vtable. `Threaded.sleep` va a `sleepPosix`
  porque `use_parking_sleep` solo es true en Windows/NetBSD/illumos.
- `sleepPosix` es un `clock_nanosleep` en el hilo que llama, con un `Syscall`
  por hilo que **no toca `t.mutex`**.
- El tick de vaxis es una entrada normal en `App.timers` que evalua
  `App.checkTimers` en el hilo de la UI.

El reloj se congelaba por los puntos 1 y 2 de arriba, no por el sleep. Por eso
`acp.nap` (un `nanosleep` pelado) es igualmente lo correcto: es lo que se usa en
`Retry.wait` y en la espera del dialogo de permisos, pero por robustez, no
porque `Io.sleep` fuera un problema.

## Correccion: la capacidad de la cache de segmentos

El comentario de `max_cached_paras` decia "el scroll profundo re-parsea on
demand". **No lo hacia**, y esa suposicion es justo lo que hacia que el bucle
de `tui.zig` no terminara. Ahora si lo hace: `layoutWindow` elige la ventana
que contiene las lineas visibles y `layoutFor` itera hasta que el rango se
estabiliza (las alturas empiezan estimadas y se corrigen al parsear).

## Trampas de Zig 0.16 que costaron una tarde

- **`gpa.free(list.items)` es `Invalid free`.** En 0.16 `items` es el slice de
  LONGITUD y la capacidad va aparte. Para liberar hay que usar
  `allocatedSlice()`. Peta en `pushDiff` con "Invalid free".
- **`clearRetainingCapacity` hace `@memset(items, undefined)`.** Si se llama en
  `deinit` DESPUES de `deinit` de esa misma lista, es un memset de `undefined`
  sobre memoria liberada -> GPF.
- **`std.Thread.Mutex` ya no existe.** `std.Io.Mutex` / `std.Io.Condition` lo
  tienen, pero necesitan un `Io` (y los tests construyen el `Model` sin app).
  Para el dialogo de permisos: `std.atomic.Mutex` propio + espera dormida.
- **`ArrayList` unmanaged pide capacidad exacta**: un `FixedBufferAllocator` de
  128 B falla al pedir 128 B para 8 punteros. Los tests de `TurnStats` usan 512.
- **Devolver un slice a un temporal de pila** (`normalizeLang` lo hacia) se lee
  DESPUES de que la funcion retorne: tres tests rojos seguidos hasta que se
  cayera.
- **`rowText` devuelve BYTES, no columnas**: `◆` son 3 bytes para 2 columnas y
  `─` 3 bytes para 1. Comparar bytes contra columnas da un test rojo con el
  layout correcto.

## `tools/pty_smoke.py`: la unica verificacion que de verdad vale

Los tests de `drawTest` leen el surface y comprueban el texto y los estilos, pero
**no** comprueban lo que mas se rompe: el render de vaxis es DIFERENCIAL y hace
consultas al terminal (color, capacidades, tamaño). Un emulador casero se pierde
la mitad del redraw, que es justo lo que hace que un turno que funciona parezca
congelado.

Asi que hay un smoke test en pty de verdad (`pty.fork` + `TIOCSWINSZ` a 200x50):
arranque, banner, caja del input, status, eco del prompt, **Ctrl+P abriendo y
cerrando la paleta**, Ctrl+L, scroll, y que no haya panic ni `Invalid free`.

```
zig build && python3 tools/pty_smoke.py
```

Dos cosas que hace bien y que hay que mantener:

- **`HOME` propio** (`/tmp/opencode/zode-smoke-home`). La app escribe
  `~/.config/zode/auth.json` y `sessions/`, y un script automatico no debe tocar
  la config real de quien lo ejecuta. El fuzzer de junio guardo una key pegada
  por error y dejo el provider con 401 sin explicacion apparent.
- **`TIOCSWINSZ` antes de nada**: sin tamano de ventana vaxis hace
  `width_pix / width` y sale con division por cero. `script` NO fija el tamano.

## vaxis NO se parchea en el arbol (5.7 y 5.9)

El ROADMAP propone dos parches sobre `zig-pkg/vaxis-…/src/vxfw/App.zig`:

- **5.7** `arena.reset(.free_all)` -> `.retain_capacity`, para que el frame sea
  bump en vez de 1.36 MB de malloc/free por frame.
- **5.9** bajar el timeout de `vx.queryTerminal` (`.fromSeconds(1)`), que son
  hasta **1 s de pantalla en blanco** al arrancar en terminales que no
  responden.

No se hacen aqui porque `zig-pkg/` es una cache de dependencia: un parche en
ese directorio se pierde en el siguiente `zig fetch` y no se ve en el diff del
repo (es la peor combinacion: un fix que parece estar y no esta). Si se
quieren, el camino es **PR upstream a vaxis** o un `patch` declarado en
`build.zig.zon` que se aplique de forma visible y reproducible.

**5.10** (quitar `subscribeToColorSchemeUpdates`) tampoco se toca por lo mismo:
esta DENTRO de `App.run`, asi que tampoco se puede desde fuera sin lo anterior.
Y aunque se pudiera, el ahorro es un viaje de ida y vuelta al arrancar.
