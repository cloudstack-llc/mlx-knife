#!/usr/bin/env bash
set -euo pipefail

# Build and bundle a macOS arm64 (Apple Silicon) CLI tarball using PyInstaller.
# Invoked as scripts/build.sh
#
# Outputs: artifacts/<name>.tgz containing dist/<name>/...
# Optional env:
#   ONEFILE=1       -> build single-file binary (defaults to onedir for reliability)
#   VERSION=1.1     -> append version to tarball name
#   BIN_NAME=my-cli -> override binary/folder name (default: msty-mlx-studio)
#   USE_HF_XET=0    -> skip installing Hugging Face Xet plugin
#
# Requirements (run on an Apple Silicon Mac):
#   - Xcode Command Line Tools
#   - Python 3.9+ available as `python3`

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This script targets Apple Silicon (arm64) only." >&2
  exit 1
fi

APP_NAME="${BIN_NAME:-${APP_NAME:-msty-mlx-studio}}"
BUILD_VENV=".venv-build"
DIST_DIR="$ROOT_DIR/dist"
ART_DIR="$ROOT_DIR/artifacts"
SPEC_DIR="$ROOT_DIR/.pyi-spec"

mkdir -p "$ART_DIR" "$SPEC_DIR"

echo "[1/3] Creating build venv..."
python3 -m venv "$BUILD_VENV"
source "$BUILD_VENV/bin/activate"
python -m pip install --upgrade pip setuptools wheel

echo "[2/3] Installing project, deps and build tools..."
# Install runtime deps for MLX-Knife 2.x
if [[ -f requirements.txt ]]; then
  python -m pip install -r requirements.txt
fi
# Install the project itself (exposes version, console entry, etc.)
python -m pip install .

if [[ "${USE_HF_XET:-1}" == "1" ]]; then
  echo "[opt] Installing Hugging Face Xet plugin..."
  python -m pip install "huggingface_hub[hf_xet]" || true
fi

python -m pip install "pyinstaller>=6.6"

ENTRY_SCRIPT="$ROOT_DIR/.entry_mlxk_build.py"
cat > "$ENTRY_SCRIPT" <<'PY'
"""
Custom entry shim for PyInstaller bundle.

Implements supervised shutdown by default in a frozen binary:
- Parent process patches mlxk2.operations.serve.start_server to spawn a child
  process (the same frozen binary) that runs the server in-process.
- Parent supervises: SIGTERM on first Ctrl-C, SIGKILL on timeout/second Ctrl-C.

Also supports a child mode keyed by MLXK2_CHILD_SERVER=1 to run the server
directly without going through CLI argument parsing.
"""

import os
import signal
import subprocess
import sys
import time


def _to_bool(val: str) -> bool:
    return str(val).lower() in ("1", "true", "yes", "on")


# Fast path: strip CLI name from version output for compatibility
if "--version" in sys.argv and "--json" not in sys.argv:
    try:
        from mlxk2 import __version__ as _ver
    except Exception:
        _ver = "0.0.0"
    print(_ver)
    sys.exit(0)

# Child mode: run the server in-process (bypasses CLI parsing)
if os.environ.get("MLXK2_CHILD_SERVER") == "1":
    from mlxk2.core.server_base import run_server as _run_server

    host = os.environ.get("MLXK2_HOST", "127.0.0.1")
    port = int(os.environ.get("MLXK2_PORT", "8000"))
    log_level = os.environ.get("MLXK2_LOG_LEVEL", "info")
    reload = _to_bool(os.environ.get("MLXK2_RELOAD", "0"))
    _mt = os.environ.get("MLXK2_MAX_TOKENS", "")
    max_tokens = int(_mt) if _mt.strip() else None

    _run_server(host=host, port=port, max_tokens=max_tokens, reload=reload, log_level=log_level)
    sys.exit(0)


# Parent mode: patch start_server to supervise a child process
from mlxk2.core.server_base import run_server as _run_server
import mlxk2.operations.serve as _serve


def _run_supervised_server(*, host: str, port: int, log_level: str, reload: bool, max_tokens):
    env = os.environ.copy()
    env["MLXK2_CHILD_SERVER"] = "1"
    env["MLXK2_HOST"] = host
    env["MLXK2_PORT"] = str(port)
    env["MLXK2_LOG_LEVEL"] = log_level
    env["MLXK2_RELOAD"] = "1" if reload else "0"
    if max_tokens is not None:
        env["MLXK2_MAX_TOKENS"] = str(max_tokens)

    # Start child in a new process group for clean signaling
    proc = subprocess.Popen([sys.executable], start_new_session=True, env=env)

    # Install signal handlers so SIGINT/SIGTERM to the parent trigger supervised cleanup
    shutting_down = {"done": False}

    def _graceful_shutdown(_sig=None, _frame=None):
        if shutting_down["done"]:
            return
        shutting_down["done"] = True
        # Ask child to stop gracefully
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except Exception:
            pass
        # Wait briefly, then escalate to SIGKILL if needed
        deadline = time.time() + 5.0
        while time.time() < deadline:
            ret = proc.poll()
            if ret is not None:
                return
            try:
                time.sleep(0.1)
            except Exception:
                pass
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass

    try:
        signal.signal(signal.SIGINT, _graceful_shutdown)
    except Exception:
        pass
    try:
        signal.signal(signal.SIGTERM, _graceful_shutdown)
    except Exception:
        pass
    try:
        return proc.wait()
    except KeyboardInterrupt:
        # Suppress further SIGINT while we clean up
        previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            # First Ctrl-C: ask child to stop gracefully
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except Exception:
                pass
            # Wait briefly, then force kill if still alive
            deadline = time.time() + 5.0
            while time.time() < deadline:
                ret = proc.poll()
                if ret is not None:
                    return ret
                try:
                    time.sleep(0.1)
                except KeyboardInterrupt:
                    # Second Ctrl-C: escalate to SIGKILL immediately
                    break
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                pass
            # Wait for child without being interrupted
            while True:
                ret = proc.poll()
                if ret is not None:
                    return ret
                time.sleep(0.05)
        finally:
            # Restore previous handler
            try:
                signal.signal(signal.SIGINT, previous)
            except Exception:
                pass


def _patched_start_server(*, model=None, port=8000, host="127.0.0.1", max_tokens=None,
                          reload=False, log_level="info", verbose=False, supervise=True):
    # Always run in-process (single PID for Electron to manage)
    return _run_server(host=host, port=port, max_tokens=max_tokens, reload=reload, log_level=log_level)


# Install patch before CLI main runs so cli imports get the patched version
_serve.start_server = _patched_start_server


if __name__ == "__main__":
    from mlxk2.cli import main
    main()
PY

echo "[3/3] Building and packaging..."
PYI_OPTS=(
  --clean
  --noconfirm
  --name "$APP_NAME"
  --log-level=WARN
  --specpath "$SPEC_DIR"
  --collect-all mlx
  --collect-all mlx_lm
  --collect-all huggingface_hub
  --collect-all requests
  --collect-all fastapi
  --collect-all pydantic
  --collect-all uvicorn
)

if [[ "${ONEFILE:-0}" == "1" ]]; then
  PYI_OPTS+=(--onefile)
else
  PYI_OPTS+=(--onedir)
fi

pyinstaller "${PYI_OPTS[@]}" "$ENTRY_SCRIPT"

# Package archive
TAR_BASE="$APP_NAME"
if [[ -n "${VERSION:-}" ]]; then
  TAR_BASE="$TAR_BASE-${VERSION}"
fi
TAR_NAME="${ARCHIVE_NAME:-${TAR_BASE}.tgz}"

PACK_DIR="$ROOT_DIR/.pack-tmp"
rm -rf "$PACK_DIR"
mkdir -p "$PACK_DIR/$APP_NAME"

if [[ "${ONEFILE:-0}" == "1" ]]; then
  cp "$DIST_DIR/$APP_NAME" "$PACK_DIR/$APP_NAME/$APP_NAME"
else
  rsync -a --delete "$DIST_DIR/$APP_NAME/" "$PACK_DIR/$APP_NAME/"
fi

cp -f LICENSE "$PACK_DIR/$APP_NAME/" 2>/dev/null || true

tar -C "$PACK_DIR" -czf "$ART_DIR/$TAR_NAME" "$APP_NAME"
echo "Created: $ART_DIR/$TAR_NAME"

echo "Build complete. Binaries are in dist/, archive in artifacts/."

rm -f "$ENTRY_SCRIPT"
