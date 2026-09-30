# zode

Harness de código agéntico en **Zig puro** (estilo Claude Code / OpenCode): binario mínimo, RAM mínima, 100% código.

## Estado actual

- ✅ HTTP/TLS con `std.http.Client` (sin C deps) — verificado contra la API de OpenCode
- ✅ Listado de modelos (`--models`): 44 modelos, detección de free
- ✅ Chat streaming SSE con parser testeado (unit tests sin red)
- ✅ Esfuerzo low/medium/high (`max_tokens` 1k/4k/16k)
- ✅ TUI con libvaxis (vxfw): historial anclado abajo, statusbar, input, chat en hilo de fondo
- ✅ Binario: **1.6MB stripped** en ReleaseSafe/ReleaseFast

## Build & uso

```bash
zig build -Doptimize=ReleaseSafe
cp .env.example .env   # edita con tu key
set -a && source .env && set +a

./zig-out/bin/zode --models        # lista modelos
./zig-out/bin/zode --chat "hola"   # chat headless
./zig-out/bin/zode                 # TUI
```

## Config

| Variable | Default |
|---|---|
| `ZODE_BASE_URL` | `https://opencode.ai/inference/openai/v1` |
| `ZODE_MODELS_URL` | `https://opencode.ai/inference/v1/models` |
| `ZODE_API_KEY` | — |
| `ZODE_MODEL` | `kimi-k2.6` |
| `ZODE_EFFORT` | `medium` |

## Arquitectura

```
src/
├── main.zig         CLI: --models / --chat / TUI
├── tui.zig          TUI vxfw (historial, statusbar, input, cola thread-safe)
├── agent.zig        Router de comandos + chat en hilo de fondo
├── chat.zig         Cliente chat streaming SSE + parser (testeado)
├── models.zig       Listado de modelos (formato OpenAI)
├── provider.zig     Config multi-provider via env
└── http_client.zig  HTTP JSON sobre std.http.Client
```

Provider OpenAI-compat: funciona con OpenCode, OpenRouter, Groq, Ollama/LM Studio local cambiando `ZODE_BASE_URL`.

Ver `AGENTS.md` para convenciones del código y roadmap.
