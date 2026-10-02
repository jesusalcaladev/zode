# zode

Un agente de código en el terminal, escrito en **Zig puro** (sin libc, sin
dependencias de C; la única externa es libvaxis). Binario de **1.29 MB**, RAM
de ~6 MB, todo el código en un directorio.

No es un wrapper de otro agente: habla HTTP con el provider, ejecuta las tools
en tu máquina y decide por su cuenta qué tool llamar.

```
$ zode
######  ####  ####   ######
##  ## ##  ## ##  ## ##
   ##  ##  ## ##  ## ##
  ##   ##  ## ##  ## ##
######  ####  ####   ######
────────────────────────────────────────
❯ lee src/tui.zig y dime por qué el scroll no baja solo
```

## Qué trae

- **Agente con tools**: lee, escribe, edita, compila, busca, y usa git. El
  bucle de agente decide por su cuenta (con `ask` cuando la respuesta cambia lo
  que hace, y en modo read-only investiga y te pregunta).
- **Tools en paralelo** para las que solo leen, **bash en segundo plano** con
  salida incremental, y **ESC mata el grupo de procesos** (el nieto también).
- **Subagentes**: una búsqueda ancha va a un subagente con su propia ventana, que
  se tira después. Lo que lee se paga **una vez**, no en cada iteración.
- **Skills**: carpetas de instrucciones que se cargan **solo cuando hacen falta**.
  El prompt lleva el nombre y cuándo usarlo; el cuerpo, no.
- **Compactación de contexto** en dos niveles: se eliden resultados viejos sin
  perder el historial, y si no cabe se pide un resumen.
- **Cache de ficheros**: un `read` de algo que no ha cambiado no se vuelve a
  enviar. Es el ahorro de tokens más directo que hay.
- **ACP**: `/acp` delega el turno a otro agente (`opencode acp`) por JSON-RPC.
- **Providers**: OpenCode, OpenRouter, Anthropic (API nativa con prompt caching),
  OpenAI, Groq, DeepSeek, y local (Ollama/LM Studio). Se conectan desde la propia
  TUI, sin tocar ficheros.
- **`/free-auto`**: reparte los turnos entre los modelos free que publica cada
  provider y, cuando uno se queda sin cuota, **sigue solo** con el siguiente.

## Instalar

Coge el binario y ya está. No hay nada que instalar de más.

```bash
./zode
```

## Compilar desde fuente

Necesitas **Zig 0.16.0**.

```bash
zig build                    # release stripped, 1.29 MB (ReleaseSmall)
zig build test               # 400+ tests unitarios, en Debug
zig build -Doptimize=Debug   # con símbolos, para cuando algo peta
```

Ayudas de `zig build`:

| Paso | Qué hace |
|---|---|
| `zig build` | El binario de siempre |
| `zig build debug` | Igual pero **sin strip**, con traza de pila legible |
| `zig build test` | Los tests (`-- <filtro>` corre solo los que Chitnen el filtro) |
| `zig build tool-test -- "orden"` | Las tools headless, para probar una sin abrir la TUI |
| `zig build roster-probe` | Qué providers tienes con key y cuántos modelos free publica cada uno |
| `zig build acp-probe -- "prompt"` | El tráfico JSON-RPC contra un agente ACP real |

## Primeros pasos

1. `./zode` y pulsa **Ctrl+T** para elegir provider y modelo, o **Ctrl+A** para
   pegar la key del provider (se guarda en `~/.config/zode/auth.json` con
   permisos 0600).
2. También vale por entorno, que es lo que usarán los guiones:
   `ZODE_OPENCODE_KEY=… ./zode`.

Modo sin TUI, para probar sin terminal y para scripts:

```bash
./zode --models              # lista los modelos del provider
./zode --chat "busca mis TODOs y dime cuales son urgentones"
./zode --resume             # reabre la última sesión
```

### No hay modelo por defecto

Un nombre de modelo escrito en el código es una bomba de relojería: el día que
el provider lo retira, **todas** las peticiones pasan a fallar con un 403 que no
explica nada. Por eso los providers no traen modelo, y zode **no adivina**:

- si hay `ZODE_MODEL` o lo elegiste con `/model`, se usa ese;
- si no, zode **pregunta al provider** cuál es el catálogo y elige el primero
  gratis, y dice en pantalla cuál ha elegido y por qué;
- si el catálogo no se puede descargar, **no manda nada**: te lo dice y te abre
  el selector, en vez de gastarse un turno en un 403.

## Comandos

Se escriben con `/` y se autocompletan con **Tab**. **Ctrl+P** los abre en una
paleta que los **ejecuta**.

| | |
|---|---|
| `/help` | esta lista |
| `/model` | selector de modelo (modal, dos columnas: providers \| modelos) |
| `/provider` | selector de provider |
| `/providers` | lista los providers y si tienen key |
| `/models` | modelos del provider activo |
| `/use <provider> [modelo]` | cambia provider y modelo de una vez |
| `/effort [low\|medium\|high\|…]` | esfuerzo de razonamiento (sin argumento: selector) |
| `/free-auto [on\|off\|status]` | rota entre modelos free cuando uno agota cuota |
| `/plan` | borra la lista de tareas visible |
| `/undo` | devuelve los ficheros al estado anterior a un turno |
| `/clean [yes]` | purga restos de zode (simula por defecto) |
| `/yolo` | permisos automáticos |
| `/allowlist` | tools que siempre se permiten (persistido) |
| `/ask [on\|off]` | modo read-only (también **Shift+Tab**) |
| `/skills` | qué skills hay y de dónde |
| `/acp [on\|off\|<cmd>]` | delega el turno a un agente ACP |
| `/bg [list\|kill <id>\|killall]` | comandos en segundo plano |
| `/new` · `/resume` | sesión nueva / reabrir la última |
| `/context` | tokens usados contra el presupuesto |
| `/bench` | números de la sesión: turnos, iteraciones, primer token |
| `/cache` | hit-rate de la cache del provider |
| `/session` | id, fichero y mensajes de la sesión |
| `/quit` | salir |

### Atajos

| | |
|---|---|
| `Ctrl+P` | paleta de comandos |
| `Ctrl+T` | paleta de modelos |
| `Ctrl+A` | conectar un provider |
| `Ctrl+L` | limpiar la vista (el fichero de sesión no se toca) |
| `Ctrl+R` | plegar/desplegar el último resultado |
| `Ctrl+U` / `Ctrl+D` | media página de scroll |
| `PageUp` / `PageDown` | una página |
| `Shift+Enter` | salto de línea (Enter manda) |
| `Shift+Tab` | modo read-only |
| `Esc` | parar el turno, matar el comando, o responder "decídelo tú" |
| `Tab` | completar un comando `/` |
| `↑` / `↓` | historial de prompts |

## Config

**Por entorno.** Solo hace falta la key si no usas Ctrl+A:

| Variable | Para qué |
|---|---|
| `ZODE_<PROVIDER>_KEY` | key de ese provider (`ZODE_ANTHROPIC_KEY`, `ZODE_GROQ_KEY`, …) |
| `ZODE_API_KEY` | key genérica, la última recurso |
| `ZODE_PROVIDER` | provider inicial |
| `ZODE_MODEL` | modelo inicial |
| `ZODE_EFFORT` | `low` \| `medium` \| `high` |
| `ZODE_BASE_URL` / `ZODE_MODELS_URL` | endpoints, para providers o gateways propios |
| `ZODE_CONTEXT_LIMIT` | tokens de contexto (por defecto 128k; el presupuesto de compactación es el 80%) |
| `ZODE_MAX_ITER` | iteraciones del bucle de agente por turno (12) |
| `ZODE_FREE_AUTO` | `1` arranca con `/free-auto on` |
| `ZODE_RESUME` | `1` reabre la última sesión |
| `ZODE_ACP_CMD` | comando del agente ACP, en vez de `opencode acp` |
| `ZODE_DBG_ERR` | `1` vuelca a stderr el status y el cuerpo de cada respuesta |
| `ZODE_YES` | `1` hace que `/clean` aplique sin confirmar (para cuando lo ejecuta el modelo) |

**Por fichero**, en `~/.config/zode/`:

- `config.json` — providers propios (id, base_url, models_url, `key_env`,
  `default_model`, `kind`), y `provider`/`model` por defecto. Los providers
  compilados no se pueden shadowear: gana el built-in.
- `auth.json` — las keys que pegas con Ctrl+A. **0600**, escrito en temporal y
  renombrado. Nunca en `config.json`, que la gente versiona.
- `skills/<nombre>/SKILL.md` — tus skills.

**En el proyecto**, desde donde lo lances:

- `AGENTS.md` (o `CLAUDE.md`) — instrucciones del proyecto. Se busca en el
  directorio actual y, si no hay, en la raíz del repositorio.
- `.zode/skills/<nombre>/SKILL.md` — skills del harness.
- `.agents/skills/<nombre>/SKILL.md` — skills, en el convenio compartido con
  otros agentes.
- `sessions/zode-*.jsonl` — las sesiones. Comprimidas: las líneas grandes van
  en DEFLATE y en base64.

## Skills

Una skill es una carpeta con un `SKILL.md` y frontmatter de `name` y
`description`. El prompt lleva **solo** nombre y descripción; el cuerpo se lee
cuando el modelo decide que la necesita, con la tool `skill`.

```markdown
---
name: pty-tests
description: después de tocar el dibujo de tui.zig
---

Verifica los cambios de TUI en una pty de verdad: `python3 tools/pty_smoke.py`.
```

La `description` tiene que decir **cuándo** usarla, no qué contiene: "después de
tocar el dibujo de tui.zig" decide bien; "notas sobre pty" obliga al modelo a
adivinar. Los skills de un proyecto tapan a los globales en vez de mezclarse:
medio skill de otro proyecto es peor que no tenerlo.

`/skills` dice cuáles hay y de dónde.

## Sesiones

Cada turno se escribe en `sessions/zode-<id>.jsonl` (una línea por evento, con
`tool_calls` en crudo para que el replay sea fiel). `/resume` reabre la última y
`/undo` devuelve **ficheros**, no mensajes: la sesión es append-only y
reescribirla a mitad de un turno no tiene explicación.

## Desarrollo

```bash
zig build test                              # unit tests
zig build && python3 tools/pty_smoke.py     # smoke en pty de verdad
python3 tools/measure.py ./zig-out/bin/zode # arranque y RSS
python3 tools/esc_kill_pty.py               # ESC mata al nieto, no al shell
```

`tools/pty_smoke.py` usa un `HOME` propio a propósito: la app escribe
`~/.config/zode/auth.json` y `sessions/`, y una prueba automática no debe tocar
la config de quien la ejecuta.

## Arquitectura

```
src/
├── main.zig          CLI: --models / --chat / TUI / --resume
├── tui.zig           la TUI (vxfw): dibujo, input, scroll, paletas
├── agent.zig         bucle de agente, comandos, permisos, turnos
├── tools.zig         las 16 tools (puro: sin TUI ni red)
├── chat.zig          cliente streaming SSE + parser + Anthropic
├── http_client.zig   HTTP JSON sobre std.http.Client
├── providers.zig     providers compilados + keys (env > auth.json)
├── config.zig        config.json de usuario
├── models.zig        catálogo de modelos y sus metadatos
├── skills.zig        formato de un SKILL.md (puro)
├── skillstore.zig    descubrimiento de skills en disco
├── project.zig       cwd, raíz del repo y rama de git
├── compaction.zig    presupuesto de contexto, elisión y resumen
├── roster.zig        pool de modelos free (puro)
├── subagent.zig      la tool `task`
├── bgproc.zig        comandos en segundo plano
├── ask.zig           la tool `ask` (puro)
├── session.zig       sesiones JSONL comprimidas
├── markdown.zig      markdown + diff unificado (puro)
├── highlight.zig     resaltado de sintaxis universal (puro)
├── palette.zig       paleta modal de Ctrl+P / Ctrl+T
└── acp.zig           cliente ACP v1 por JSON-RPC
```

Lo que no depende de la TUI ni de la red está en módulos **puros** con sus
tests: `tools`, `chat`, `markdown`, `highlight`, `skills`, `roster`, `plan`,
`mentions`, `ask`, `project`, `compaction`, `web`. Lo que sí la depende (el
agente, la TUI) se prueba en `@import` directo contra la superficie real.

Provider OpenAI-compatible: funciona con OpenCode, OpenRouter, Groq, DeepSeek y
cualquier gateway que hable el mismo formato, cambiando el `base_url`.

`AGENTS.md` tiene las convenciones del código y **por qué** cada decisión rare
salió cara (qué trampas de Zig 0.16 ya se pagaron, qué bugs de memoria hay, y
qué NO se debe hacer). Es el fichero que hay que leer antes de tocar nada.