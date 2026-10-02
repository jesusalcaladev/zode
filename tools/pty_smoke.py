#!/usr/bin/env python3
"""Smoke test de la TUI en una pty REAL.

Por que una pty y no los tests de `drawTest`: el render de vaxis es
 DIFERENCIAL y hace consultas al terminal (color, tamaño, capacidades). Un
 emulador casero se pierde la mitad del redraw, que es exactamente lo que hace
 que un turno que funciona parezca congelado. Ademas `pty.fork` + `TIOCSWINSZ`
 es la unica forma de darle a la app un tamaño de ventana de verdad.

Uso:
    zig build                       # o `zig build -Doptimize=ReleaseSafe`
    python3 tools/pty_smoke.py

Devuelve 0 si todo lo que se comprueba esta, 1 si algo falla. Imprime el
volcado plano si algo falla, para poder mirar que se ve.

OJO: `HOME` se apunta a un directorio propio. La app escribe
`~/.config/zode/auth.json` y `sessions/`, y un script automatico no debe tocar
la config real de la persona que lo ejecuta (el fuzzer de junio guardo una key
pegada por error y luego el provider con 401 sin explicacion apparent).
"""

import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

ROWS, COLS = 50, 200
BINARY = "./zig-out/bin/zode"
# Un HOME aparte: `auth.json` y `sessions/` son de la persona, no del smoke.
SANDBOX_HOME = "/tmp/opencode/zode-smoke-home"


def strip_ansi(b: bytes) -> str:
    """Texto plano de lo que salió por la pty.

    Hay que quitar tambien el SGR truecolor con dos puntos
    (`ESC [ [38:2:122:162:247m`), que el regex habitual no cubre y que el
    banner emite entero: sin esto el ASCII art sale partido y no se puede
    buscar ni una sola cadena.
    """
    s = b.decode("utf-8", "replace")
    s = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?", "", s)  # OSC
    s = re.sub(r"\x1b\[[0-9;:?<>!$ ]*[A-Za-z`~]", "", s)  # CSI (incl. SGR)
    s = re.sub(r"\x1b[\(\)][B0]|\x1b[=>78MD]", "", s)  # charset designators
    return s


def drive(keys, budget: float = 8.0):
    """Arranca la TUI, manda `keys` espaciados, y devuelve (salida, texto)."""
    if not os.path.exists(BINARY):
        sys.exit(f"{BINARY} no existe: ejecuta `zig build` primero")

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(
            TERM="xterm-256color",
            HOME=SANDBOX_HOME,
            ZODE_RESUME="0",
            LINES=str(ROWS),
            COLUMNS=str(COLS),
        )
        os.execv(BINARY, [BINARY])

    # Sin esto el proceso hijo no tiene una ventana y vaxis hace `width_pix /
    # width`, que con tamano 0 es division por cero.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    out = b""
    t0 = time.time()
    slots = len(keys) + 1
    for i, key in enumerate([None] + list(keys)):
        due = t0 + (i + 1) * (budget / slots)
        while time.time() < due:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(fd, 1 << 16)
            except OSError:
                chunk = b""
            if not chunk:
                break
            out += chunk
        if key is None:
            continue
        try:
            os.write(fd, key)
        except OSError:
            break

    os.write(fd, b"\x03")  # ctrl+c: el camino de salida del propio prompt
    time.sleep(0.3)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)
    return out, strip_ansi(out)


def check(name: str, ok: bool, text: str) -> bool:
    print(f"  {'OK  ' if ok else 'FAIL'} {name}")
    return ok


def main() -> int:
    os.makedirs(SANDBOX_HOME, exist_ok=True)

    # 1) Arranque: banner, caja del input, status, y que no se rompa nada.
    out, t = drive([b"hola mundo", b"\r"])
    ok = True
    print(f"smoke: {len(out)} bytes por la pty")
    ok &= check("banner: primera fila del wordmark", "######  ####  ####   ######" in t, t)
    ok &= check("banner: tercera fila", "   ##  ##  ## ##  ## ##" in t, t)
    ok &= check("input box (bordes ╭ ╰)", "╭" in t and "╰" in t, t)
    ok &= check("status bar", "esc interrupts" in t, t)
    ok &= check("el prompt del usuario se hace eco", "hola mundo" in t, t)
    ok &= check("no hay panic", "panic" not in t.lower(), t)
    ok &= check("no hay 'Invalid free'", "invalid free" not in t.lower(), t)

    # 2) Ctrl+P: la paleta modal tiene que abrir Y cerrarse. Este es el camino
    #    que mas se rompio (items colgando, doble liberacion del allocator).
    out2, t2 = drive([b"\x10", b"esc"])
    ok &= check("ctrl+p abre la paleta", "Switch model" in t2 or "Connect" in t2, t2)
    ok &= check("esc cierra la paleta", "Switch model" not in t2, t2)

    # 3) Ctrl+L (limpiar) y scroll: no deben tumbar la app.
    out3, t3 = drive([b"hola", b"\r", b"\x0c", b"\x1b[B", b"\x1b[B"])
    ok &= check("ctrl+l + scroll no rompen nada", "panic" not in t3.lower(), t3)

    # 4) `/clean`: un comando de limpieza que se ejecuta en la TUI sin pedir
    #    nada tiene que salir bien SIEMPRE, y sin `yes` no puede borrar. Se
    #    comprueba el texto del dry run, no que se borre: en el HOME del smoke
    #    puede no haber ni una sesion vacia, y un test que depende de que haya
    #    basura que borrar solo verifica el caso-afortunado.
    out4, t4 = drive([b"/clean", b"\r"])
    ok &= check("/clean responde (dry run)", "/clean" in t4 and "dry run" in t4, t4)
    ok &= check("/clean ofrece el 'yes'", "/clean yes" in t4, t4)
    ok &= check("/clean no rompe nada", "panic" not in t4.lower(), t4)

    # 5) `/context` dice DONDE se esta trabajando. Es la linea que responde a
    #    "de verdad esta leyendo los ficheros de aqui?", y no aparece en ningun
    #    otro sitio de la pantalla.
    # DOS enters: el primero lo acepta el autocompletado (que esta abierto
    # porque `/context` es un prefijo de comando) y el segundo lo manda. Con uno
    # solo el comando se queda en el input y el test passaria/fallaria por el
    # popup, no por `/context`.
    out5, t5 = drive([b"/context", b"\r", b"\r"], budget=9.0)
    ok &= check("/context dice el cwd", "cwd" in t5, t5)
    ok &= check("/context no rompe nada", "panic" not in t5.lower(), t5)

    if not ok:
        print("\n--- texto plano (recortado) ---")
        for line in t.splitlines()[:40]:
            if line.strip():
                print("  |", line[:100])
    else:
        print("\nsmoke: OK")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())