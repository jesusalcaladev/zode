#!/usr/bin/env python3
"""Mide RSS y tiempo de arranque de la TUI en una pty real.

Uso: python3 tools/measure.py [binario] [segundos]
Arranca la TUI, lee VmRSS de /proc cada 200 ms, y reporta:
  - tiempo hasta la primera salida no vacia (arranque)
  - RSS de pico y RSS estable (mediana de la segunda mitad)
"""
import os
import pty
import re
import select
import statistics
import struct
import sys
import termios
import time
import fcntl

ROWS, COLS = 50, 200
BINARY = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/zode"
HOLD = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
SANDBOX_HOME = "/tmp/opencode/zode-measure-home"


def main():
    os.makedirs(SANDBOX_HOME, exist_ok=True)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["HOME"] = SANDBOX_HOME
        os.environ["TERM"] = "xterm-256color"
        # sin key de red: el arranque no debe tocar la API
        os.environ.pop("ZODE_API_KEY", None)
        os.environ.pop("ZODE_OPENCODE_KEY", None)
        os.execv(BINARY, [BINARY])
        os._exit(127)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    rss_samples = []
    t0 = time.time()
    first_output_at = None
    total = 0
    deadline = t0 + HOLD
    while time.time() < deadline:
        # leer lo que haya (no bloqueante)
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if chunk:
                total += len(chunk)
                if first_output_at is None and len(chunk) > 0:
                    first_output_at = time.time() - t0
        # RSS del hijo
        try:
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        rss_samples.append(int(line.split()[1]))  # kB
                        break
        except (OSError, FileNotFoundError):
            break
    # cerrar
    try:
        os.write(fd, b"\x03")  # ctrl+c
    except OSError:
        pass
    time.sleep(0.3)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass

    if not rss_samples:
        sys.exit("no se pudieron leer muestras de RSS")
    half = len(rss_samples) // 2
    steady = statistics.median(rss_samples[half:])
    print(f"binario:            {BINARY}")
    print(f"primera salida:     {first_output_at if first_output_at is not None else 'n/a'} s")
    print(f"bytes de salida:    {total}")
    print(f"RSS pico:           {max(rss_samples)/1024:.2f} MB")
    print(f"RSS estable (mediana segunda mitad): {steady/1024:.2f} MB")
    print(f"RSS min:            {min(rss_samples)/1024:.2f} MB")
    print(f"muestras:           {len(rss_samples)}")


if __name__ == "__main__":
    main()
