#!/usr/bin/env python3
"""Record the demo as an asciicast, and render it to a GIF with agg.

Why this exists rather than a VHS tape or an asciinema recording:

    VHS          `vhs validate` passes and `vhs hack/demo.tape` exits 0
                 printing "Creating ...gif", but writes no file on Windows.
                 Reproduced on a minimal tape.
    PowerSession panics on Windows -- it resolves `bash` to WSL's missing
                 /bin/bash, and needs a real console handle that a piped
                 stdout does not provide.

So this script assembles the asciicast itself. What it does NOT do is invent
output: every frame below is the real stdout of the real command, run against
the live clusters at record time. Only the typing animation and the pauses are
synthesised -- which is exactly what a VHS tape does too.

Usage:
    python hack/record-demo.py [--out docs/assets/showdown.gif] [--cast FILE]

Requires `agg` (https://github.com/asciinema/agg) on PATH.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

COLS, ROWS = 132, 26
TYPE_DELAY = 0.035  # per character
AFTER_PROMPT = 0.45  # between the typed line and its output
READ_PAUSE = 4.8  # after output, long enough to actually read it
COMMENT_PAUSE = 1.6

GREEN, CYAN, BOLD, DIM, RESET = "\x1b[32m", "\x1b[36m", "\x1b[1m", "\x1b[2m", "\x1b[0m"


def versions() -> dict[str, str]:
    env = {}
    for line in (REPO_ROOT / "hack" / "versions.env").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            env[key] = value
    return env


class Cast:
    """An asciicast v2 recording, built up event by event."""

    def __init__(self) -> None:
        self.t = 0.0
        self.events: list[list] = []

    def emit(self, text: str) -> None:
        self.events.append([round(self.t, 4), "o", text])

    def wait(self, seconds: float) -> None:
        self.t += seconds

    def type_line(self, text: str) -> None:
        """Type a line out one character at a time, as a person would."""
        for char in text:
            self.emit(char)
            self.wait(TYPE_DELAY)
        self.emit("\r\n")

    def write_block(self, text: str) -> None:
        # asciicast expects CRLF; captured output has bare LF.
        self.emit(text.replace("\n", "\r\n"))

    def dump(self, path: pathlib.Path) -> None:
        header = {
            "version": 2,
            "width": COLS,
            "height": ROWS,
            "timestamp": int(time.time()),
            "env": {"TERM": "xterm-256color", "SHELL": "/bin/bash"},
        }
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(header) + "\n")
            for event in self.events:
                handle.write(json.dumps(event) + "\n")


def find_bash() -> str:
    """Locate a real bash.

    On Windows, `shutil.which("bash")` usually finds C:\\Windows\\System32\\bash.exe,
    which forwards to WSL. If no WSL distribution provides /bin/bash, every command
    silently records `execvpe(/bin/bash) failed` instead of its output -- a GIF full
    of error messages that still renders perfectly. Prefer Git Bash explicitly.
    """
    candidates = [
        os.environ.get("SHELL", ""),
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        "/bin/bash",
    ]
    for candidate in candidates:
        if candidate and "system32" not in candidate.lower() and pathlib.Path(candidate).exists():
            return candidate
    found = shutil.which("bash")
    if found and "system32" not in found.lower():
        return found
    raise SystemExit("no usable bash found (System32's WSL shim does not count)")


BAD_OUTPUT = ("execvpe(", "command not found", "No such file or directory")


def run(command: str, shell: str) -> str:
    """Run a command for real and return its combined output."""
    print(f"  running: {command}", file=sys.stderr)
    result = subprocess.run(
        [shell, "-c", command],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=300,
        check=False,  # a non-zero exit is still output worth recording
    )
    out = (result.stdout or "") + (result.stderr or "")
    if not out.strip():
        raise SystemExit(f"'{command}' produced no output (exit {result.returncode})")
    # Refuse to record a broken environment. A GIF of error messages renders
    # exactly as well as a GIF of the demo, so this has to be checked, not assumed.
    for marker in BAD_OUTPUT:
        if marker in out:
            raise SystemExit(
                f"'{command}' looks like it failed to execute:\n{out[:400]}\n"
                "Put make/helm/kubectl/flux on PATH before recording."
            )
    return out


def build(cast: Cast, ver: dict[str, str], shell: str) -> None:
    cast.emit("\x1b[2J\x1b[H")
    cast.emit(
        f"\r\n  {BOLD}gitops-showdown{RESET}  {DIM}Argo CD {ver['ARGOCD_VERSION']} "
        f"vs Flux {ver['FLUX_VERSION']} on Kubernetes {ver['K8S_VERSION']}{RESET}\r\n\r\n"
    )
    cast.wait(2.2)

    steps = [
        ("One application. Two GitOps engines. One identical Helm chart.",
         "make status"),
        ("Both engines serve the same commit. So what actually differs?",
         "make diverge"),
        ("Flux ran a real helm upgrade, so a release exists -- with history.",
         f"helm history ticketflow --kube-context kind-{ver['CLUSTER_FLUX']} -n ticketflow"),
        ("Argo CD rendered the chart itself. There is no Helm release at all.",
         f"helm list --kube-context kind-{ver['CLUSTER_ARGOCD']} -n ticketflow"),
        ("Every trade-off is written down: measured here, or sourced upstream.",
         "ls docs docs/adr"),
    ]

    for comment, command in steps:
        cast.emit(f"{CYAN}# {comment}{RESET}\r\n")
        cast.wait(COMMENT_PAUSE)
        cast.emit(f"{GREEN}${RESET} ")
        cast.type_line(command)
        cast.wait(AFTER_PROMPT)
        cast.write_block(run(command, shell))
        cast.wait(READ_PAUSE)
        # No clear between steps. The terminal accumulates and scrolls like a
        # real session, which keeps the frame full instead of showing two
        # lines of typing against an empty screen.
        cast.emit(chr(13) + chr(10))  # blank line between steps

    cast.emit(
        f"\r\n  {BOLD}Same chart. Same commit. Same application.{RESET}\r\n"
        f"  {DIM}docs/comparison.md  |  docs/adr/  |  docs/runbook.md{RESET}\r\n\r\n"
    )
    cast.wait(3.5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="docs/assets/showdown.gif")
    parser.add_argument("--cast", default="docs/assets/showdown.cast")
    args = parser.parse_args()

    if shutil.which("agg") is None:
        print("agg is not on PATH -- see https://github.com/asciinema/agg", file=sys.stderr)
        return 1

    ver = versions()
    shell = find_bash()
    print(f"  shell: {shell}", file=sys.stderr)
    cast = Cast()
    build(cast, ver, shell)

    cast_path = REPO_ROOT / args.cast
    gif_path = REPO_ROOT / args.out
    gif_path.parent.mkdir(parents=True, exist_ok=True)
    cast.dump(cast_path)
    print(f"  wrote {cast_path} ({cast_path.stat().st_size} bytes)", file=sys.stderr)

    result = subprocess.run(
        ["agg", "--font-size", "15", "--theme", "asciinema",
         "--speed", "1.0", str(cast_path), str(gif_path)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        print(result.stdout + result.stderr, file=sys.stderr)
        return result.returncode

    print(f"  wrote {gif_path} ({gif_path.stat().st_size // 1024} KiB)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
