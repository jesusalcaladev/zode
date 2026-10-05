#!/usr/bin/env python3
"""ESC tiene que MATAR el grupo de procesos, no solo poner un flag.

Por que esto NO puede ser un test de Zig: lo que se comprueba es si un proceso
que el agente lanzo SIGUE VIVO en la tabla de procesos del kernel. Eso solo se
puede ver desde fuera, en la pty real, con `zig build` ya hecho.

And why it looks at the GRANDCHILD and not at the shell (this cost a round trip):

`bash` de zode es siempre `/bin/sh -c "lo que pida el modelo"`. Un shell tiene
hijos. Si el fix fuera "matar el pid del shell", la prueba MIRANDO EL SHELL
would pass the same way: the shell dies and the grandchild (`sleep`, `zig`,
`npm`) keeps running with the CPU pinned. The symptom that got reported as
"ESC does not stop the processes" is exactly that, one level lower.

The marker is `sleep 301 & wait`: shell + grandchild, two pids. It looks for
`sleep 301` and only that. With `exec` the shell is replaced, one process is left,
and the test would go green with the fix and without it alike — which is what this
looks at, so that cannot be what it checks.

How the fix was verified: remove the `pgid = 0` from both spawns (foreground and
background) hace que esto falle con el nieto vivo; volver a ponerlo lo hace
pass. Both halves of the contract are in the same test.

Uso:
    zig build
    set -a && source .env && set +a
    python3 tools/esc_kill_pty.py

`HOME` propio: la app escribe `~/.config/zode/auth.json` y `sessions/`, y un
automated script must not touch the real config of whoever runs it.
"""

import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ROWS, COLS = 50, 200
BINARY = "./zig-out/bin/zode"
# Un HOME aparte (el fuzzer de junio guardo una key pegada por error y dejo al
# provider con 401 sin explicacion aparente).
SANDBOX_HOME = "/tmp/opencode/zode-esc-home"
MARKER = "/tmp/opencode/zodeesc/bin/spin"
GRANDCHILD_ARGV = (b"sleep", b"301")
PROMPT = "ejecuta en background el binario /tmp/opencode/zodeesc/bin/spin y sigue"


def strip_ansi(b: bytes) -> str:
    s = b.decode("utf-8", "replace")
    s = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?", "", s)
    s = re.sub(r"\x1b\[[0-9;:?<>!$ ]*[A-Za-z`~]", "", s)
    s = re.sub(r"\x1b[\(\)][B0]|\x1b[=>78MD]", "", s)
    return s


def grandchild_procs():
    """Processes whose argv is EXACTLY the grandchild, and nothing else.

    Matching the exact argv pair and nothing else is what keeps this from
    counting the harness's own shell (which has the marker path in its argv
    because it created the file) or an unrelated `sleep`.
    """
    found = []
    me = os.getpid()
    for p in os.listdir("/proc"):
        if not p.isdigit() or int(p) == me:
            continue
        try:
            raw = open(f"/proc/{p}/cmdline", "rb").read()
        except OSError:
            continue
        argv = [a for a in raw.split(b"\0") if a]
        if len(argv) == 2 and argv[0].endswith(GRANDCHILD_ARGV[0]) \
                and argv[1] == GRANDCHILD_ARGV[1]:
            found.append((int(p), b" ".join(argv).decode("utf-8", "replace")))
    return found


def build_marker() -> None:
    os.makedirs(os.path.dirname(MARKER), exist_ok=True)
    # `sleep & wait` deja a NIETO vivo. Sin `exec` el shell se queda esperando
    # y el nieto es otro proceso con otro pid.
    with open(MARKER, "w") as f:
        f.write("#!/bin/sh\nsleep 301 &\nwait\n")
    os.chmod(MARKER, 0o755)


def check(name: str, ok: bool, extra: str = "") -> bool:
    print(f"  {'OK  ' if ok else 'FAIL'} {name}")
    if not ok and extra:
        print("    " + extra.replace("\n", "\n    ")[:2000])
    return ok


def main() -> int:
    if not os.path.exists(BINARY):
        sys.exit(f"{BINARY} no existe: ejecuta `zig build` primero")
    if "ZODE_OPENCODE_KEY" not in os.environ:
        sys.exit("ZODE_OPENCODE_KEY no esta: `set -a && source .env && set +a`")

    os.makedirs(SANDBOX_HOME, exist_ok=True)
    build_marker()

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(
            TERM="xterm-256color",
            HOME=SANDBOX_HOME,
            ZODE_RESUME="0",
            LINES=str(ROWS),
            COLUMNS=str(COLS),
            ZODE_API_KEY=os.environ["ZODE_OPENCODE_KEY"],
            ZODE_PROVIDER="opencode",
            ZODE_MODEL="space-bunny-free",
        )
        os.execv(BINARY, [BINARY])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    out = bytearray()

    def pump(sec: float) -> None:
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                out.extend(os.read(fd, 1 << 16))
            except OSError:
                pass

    pump(3.0)
    # `/yolo` primero: sin esto `bash` pide permiso y el turno se queda parado en
    # el dialogo, que es un camino distinto del que se quiere probar.
    os.write(fd, b"/yolo\r")
    pump(2.0)
    os.write(fd, PROMPT.encode() + b"\r")

    # Se espera a que el nieto exista (con un tope), no a un tiempo fijo: con un
    # modelo lento el turno puede tardar, y un `sleep` aqui seria un OK falso.
    deadline = time.time() + 45
    while time.time() < deadline and not grandchild_procs():
        pump(1.0)
        if b"Permission required" in out:
            os.write(fd, b"a")

    during = grandchild_procs()
    print(f"  nieto vivo antes de ESC: {len(during)}")
    for p, c in during:
        print(f"    pid {p}: {c}")

    os.write(fd, b"\x1b")
    pump(4.0)
    after = grandchild_procs()
    print(f"  nieto vivo DESPUES de ESC: {len(after)}")
    for p, c in after:
        print(f"    pid {p}: {c}")

    text = strip_ansi(bytes(out))
    os.write(fd, b"\x03")
    time.sleep(0.3)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)

    # Limpieza: si el nieto sobrevivio (o sea, el fix no esta), no se deja
    # un `sleep 301` dando vueltas por la maquina.
    for p, _ in after:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass

    if not during:
        print("  SKIP el nieto nunca llego a arrancar: la prueba no prueba nada")
        print("  (pantalla: " + text[-400:].replace("\n", " ") + ")")
        return 0

    ok = check(
        "ESC mato el grupo de procesos (nada huerfano)",
        len(after) == 0,
        "\n".join(f"pid {p}: {c}" for p, c in after),
    )
    ok &= check("no hay panic", "panic" not in text.lower(), text[-600:])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())