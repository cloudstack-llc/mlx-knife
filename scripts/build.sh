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

# -----------------------------------------------------------------------------
# Temporary version override (VERSION env)
# -----------------------------------------------------------------------------
ORIG_VERSION="$(python3 - <<'PY'
import pathlib, re
text = pathlib.Path("mlxk2/__init__.py").read_text()
m = re.search(r'__version__\s*=\s*"([^"]+)"', text)
print(m.group(1) if m else "0.0.0")
PY
)"
TARGET_VERSION="${VERSION:-$ORIG_VERSION}"
TMP_INIT=""
TMP_README=""
RESTORE_VERSION=0
APPLIED_PATCHES=()

cleanup_version() {
  if [[ "$RESTORE_VERSION" == "1" ]]; then
    if [[ -n "$TMP_INIT" && -f "$TMP_INIT" ]]; then
      cp "$TMP_INIT" mlxk2/__init__.py
      rm -f "$TMP_INIT"
    fi
    if [[ -n "$TMP_README" && -f "$TMP_README" ]]; then
      cp "$TMP_README" README.md
      rm -f "$TMP_README"
    fi
  fi
}
cleanup_patches() {
  if [[ "${#APPLIED_PATCHES[@]}" -gt 0 ]]; then
    for pf in "${APPLIED_PATCHES[@]}"; do
      patch -l -p1 -R < "$pf" >/dev/null 2>&1 || true
    done
  fi
}
cleanup_all() {
  cleanup_version
  cleanup_patches
}
trap cleanup_all EXIT

if [[ "$TARGET_VERSION" != "$ORIG_VERSION" ]]; then
  echo "[version] Updating project version: $ORIG_VERSION -> $TARGET_VERSION"
  TMP_INIT="$(mktemp)"
  cp mlxk2/__init__.py "$TMP_INIT"
  if [[ -f README.md ]]; then
    TMP_README="$(mktemp)"
    cp README.md "$TMP_README"
  fi
  RESTORE_VERSION=1
  python3 - "$ORIG_VERSION" "$TARGET_VERSION" <<'PY'
import sys
import pathlib
import re

old, new = sys.argv[1:3]

def tag(ver: str) -> str:
    if 'b' in ver:
        base, beta = ver.split('b', 1)
        if beta and beta.isdigit():
            return f"v{base}-beta.{beta}"
    return f"v{ver}"

init_path = pathlib.Path("mlxk2/__init__.py")
text = init_path.read_text()
text = re.sub(r'__version__\s*=\s*".*?"', f'__version__ = "{new}"', text)
init_path.write_text(text)

readme_path = pathlib.Path("README.md")
if readme_path.exists():
    readme = readme_path.read_text()
    readme = readme.replace(old, new)
    readme = readme.replace(tag(old), tag(new))
    readme_path.write_text(readme)
PY
fi

# -----------------------------------------------------------------------------
# Apply local CLI patch (idempotent)
# -----------------------------------------------------------------------------
apply_patch_with_cleanup() {
  local patch_file="$1"
  [[ -f "$patch_file" ]] || return
  if patch --dry-run -l -p1 < "$patch_file" >/dev/null 2>&1; then
    echo "[patch] Applying patch from $patch_file"
    patch -l -p1 < "$patch_file"
    APPLIED_PATCHES+=("$patch_file")
  elif patch --dry-run -R -l -p1 < "$patch_file" >/dev/null 2>&1; then
    echo "[patch] Patch already applied; skipping ($patch_file)"
  else
    echo "ERROR: Failed to apply patch: $patch_file" >&2
    exit 1
  fi
}

apply_patch_with_cleanup "$ROOT_DIR/scripts/patches/cli.patch"
apply_patch_with_cleanup "$ROOT_DIR/scripts/patches/server_models.patch"
apply_patch_with_cleanup "$ROOT_DIR/scripts/patches/server_streaming_usage.patch"
apply_patch_with_cleanup "$ROOT_DIR/scripts/patches/runner_decode.patch"

# -----------------------------------------------------------------------------
# CLI flags (custom wheels)
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mlx-wheel)
      shift
      if [[ -n "${1:-}" ]]; then
        export MLX_WHEEL="${1:-}"
        shift || true
      else
        echo "ERROR: --mlx-wheel requires a path" >&2
        exit 1
      fi
      ;;
    --mlx-lm-wheel)
      shift
      if [[ -n "${1:-}" ]]; then
        export MLX_LM_WHEEL="${1:-}"
        shift || true
      else
        echo "ERROR: --mlx-lm-wheel requires a path" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Platform checks
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Create build virtualenv
# -----------------------------------------------------------------------------
echo "[1/3] Creating build venv..."
CUSTOM_PY_DIR="$ROOT_DIR/python"
if [[ -n "${PYTHON_EXE:-}" ]]; then
  echo "Using override Python (PYTHON_EXE): $PYTHON_EXE"
elif [[ -x "$CUSTOM_PY_DIR/bin/python3" ]]; then
  PYTHON_EXE="$CUSTOM_PY_DIR/bin/python3"
  echo "Using project Python: $PYTHON_EXE"
else
  PYTHON_EXE="$(command -v python3)"
  echo "Using system Python: $PYTHON_EXE"
fi

"$PYTHON_EXE" -m venv "$BUILD_VENV"
source "$BUILD_VENV/bin/activate"

if ! python -m pip --version >/dev/null 2>&1; then
  echo "Bootstrapping pip via ensurepip..."
  python -m ensurepip --upgrade || true
fi
python -m pip install --upgrade pip setuptools wheel

# -----------------------------------------------------------------------------
# Install dependencies and project
# -----------------------------------------------------------------------------
echo "[2/3] Installing project, deps and build tools..."
CUSTOM_MLX_WHEEL="${MLX_WHEEL:-}"
if [[ -z "$CUSTOM_MLX_WHEEL" && -f "$ROOT_DIR/scripts/mlx-custom.whl" ]]; then
  CUSTOM_MLX_WHEEL="$ROOT_DIR/scripts/mlx-custom.whl"
fi
if [[ -n "$CUSTOM_MLX_WHEEL" ]]; then
  echo "[opt] Using custom MLX wheel: $CUSTOM_MLX_WHEEL"
  [[ -f "$CUSTOM_MLX_WHEEL" ]] || { echo "ERROR: MLX wheel not found: $CUSTOM_MLX_WHEEL" >&2; exit 1; }
fi

CUSTOM_MLX_LM_WHEEL="${MLX_LM_WHEEL:-}"
if [[ -z "$CUSTOM_MLX_LM_WHEEL" && -f "$ROOT_DIR/scripts/mlx-lm-custom.whl" ]]; then
  CUSTOM_MLX_LM_WHEEL="$ROOT_DIR/scripts/mlx-lm-custom.whl"
fi
if [[ -n "$CUSTOM_MLX_LM_WHEEL" ]]; then
  echo "[opt] Using custom MLX-LM wheel: $CUSTOM_MLX_LM_WHEEL"
  [[ -f "$CUSTOM_MLX_LM_WHEEL" ]] || { echo "ERROR: MLX-LM wheel not found: $CUSTOM_MLX_LM_WHEEL" >&2; exit 1; }
fi

if [[ -f requirements.txt ]]; then
  if [[ -n "$CUSTOM_MLX_WHEEL" || -n "$CUSTOM_MLX_LM_WHEEL" ]]; then
    REQ_TMP="$(mktemp)"
    awk 'BEGIN{IGNORECASE=0} {
      line=$0; trimmed=line; gsub(/^[ \t]+/,"",trimmed);
      if (trimmed ~ /^#/ || trimmed ~ /^$/) { print line; next }
      if (ENVIRON["FILTER_MLX"] && trimmed ~ /^mlx([ \t]|[><=]|$)/) { next }
      if (ENVIRON["FILTER_MLX_LM"] && trimmed ~ /^mlx-lm([ \t]|[><=]|$)/) { next }
      print line
    }' FILTER_MLX=$([[ -n "$CUSTOM_MLX_WHEEL" ]] && echo 1) FILTER_MLX_LM=$([[ -n "$CUSTOM_MLX_LM_WHEEL" ]] && echo 1) requirements.txt > "$REQ_TMP"
    python -m pip install ${PIP_ARGS:-} -r "$REQ_TMP"
    rm -f "$REQ_TMP"
  else
    python -m pip install ${PIP_ARGS:-} -r requirements.txt
  fi
fi

if [[ -n "${MLX_REPO_REF:-}" ]]; then
  echo "[opt] Overriding MLX from: ${MLX_REPO_REF}"
  python -m pip install ${PIP_ARGS:-} --no-deps "${MLX_REPO_REF}"
fi
if [[ -n "${MLX_LM_REPO_REF:-}" ]]; then
  echo "[opt] Overriding MLX-LM from: ${MLX_LM_REPO_REF}"
  python -m pip install ${PIP_ARGS:-} --no-deps "${MLX_LM_REPO_REF}"
fi

python -m pip install ${PIP_ARGS:-} .

if [[ "${USE_HF_XET:-1}" == "1" ]]; then
  echo "[opt] Installing Hugging Face Xet plugin..."
  python -m pip install "huggingface_hub[hf_xet]" || true
fi

if [[ -n "$CUSTOM_MLX_WHEEL" ]]; then
  echo "[opt] Installing custom MLX wheel: $CUSTOM_MLX_WHEEL"
  python -m pip install ${PIP_ARGS:-} --force-reinstall "$CUSTOM_MLX_WHEEL"
fi
if [[ -n "$CUSTOM_MLX_LM_WHEEL" ]]; then
  echo "[opt] Installing custom MLX-LM wheel: $CUSTOM_MLX_LM_WHEEL"
  python -m pip install ${PIP_ARGS:-} --force-reinstall "$CUSTOM_MLX_LM_WHEEL"
fi

python -m pip install "pyinstaller>=6.6"

# -----------------------------------------------------------------------------
# Entry script for PyInstaller
# -----------------------------------------------------------------------------
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
import json
import signal
import subprocess
import sys
import time


def _to_bool(val: str) -> bool:
    return str(val).lower() in ("1", "true", "yes", "on")


# Fast path: strip CLI name from version output for compatibility
if "--version" in sys.argv and "--json" not in sys.argv and "--python-info" not in sys.argv:
    try:
        from mlxk2 import __version__ as _ver
    except Exception:
        _ver = "0.0.0"
    print(_ver)
    sys.exit(0)

# Diagnostic: print embedded Python details
if "--python-info" in sys.argv or os.environ.get("MLXK2_PY_INFO") == "1":
    info = {
        "python_version": sys.version.split(" (", 1)[0],
        "executable": sys.executable,
        "prefix": sys.prefix,
        "base_prefix": getattr(sys, "base_prefix", None),
        "frozen": bool(getattr(sys, "frozen", False)),
        "meipass": getattr(sys, "_MEIPASS", None),
        "platform": sys.platform,
    }
    print(json.dumps(info, indent=2))
    sys.exit(0)

# Diagnostic: package info helpers
if "--mlx-info" in sys.argv or "--pkg-info" in sys.argv:
    try:
        if "--mlx-info" in sys.argv:
            pkg = "mlx"
        else:
            idx = sys.argv.index("--pkg-info")
            pkg = sys.argv[idx + 1]
        import importlib
        mod = importlib.import_module(pkg)
        version = None
        try:
            import importlib.metadata as md
            try:
                version = md.version(pkg)
            except Exception:
                version = None
        except Exception:
            pass
        if version is None:
            version = getattr(mod, "__version__", None)
        dist_info_dir = None
        try:
            import importlib.metadata as md
            dist = md.distribution(pkg)
            files = list(dist.files or [])
            for f in files:
                if str(f).endswith("METADATA"):
                    dist_info_dir = os.fspath(dist.locate_file(f))
                    dist_info_dir = os.path.dirname(dist_info_dir)
                    break
        except Exception:
            dist_info_dir = None
        out = {
            "package": pkg,
            "version": version,
            "module_file": getattr(mod, "__file__", None),
            "dist_info": dist_info_dir,
        }
        print(json.dumps(out, indent=2))
        sys.exit(0)
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(2)

# Diagnostic: verify MLX stack imports cleanly
if "--check-mlx-stack" in sys.argv:
    out = {"ok": False, "mlx": None, "mlx_lm": None, "error": None}
    try:
        import importlib
        mlx = importlib.import_module("mlx")
        out["mlx"] = {
            "version": getattr(mlx, "__version__", None),
            "file": getattr(mlx, "__file__", None),
        }
        try:
            mlx_lm = importlib.import_module("mlx_lm")
            out["mlx_lm"] = {
                "version": getattr(mlx_lm, "__version__", None),
                "file": getattr(mlx_lm, "__file__", None),
            }
        except Exception as e:
            out["error"] = f"import mlx_lm failed: {e}"
            print(json.dumps(out, indent=2))
            sys.exit(2)
        out["ok"] = True
        print(json.dumps(out, indent=2))
        sys.exit(0)
    except Exception as e:
        out["error"] = str(e)
        print(json.dumps(out, indent=2))
        sys.exit(2)

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

    proc = subprocess.Popen([sys.executable], start_new_session=True, env=env)

    shutting_down = {"done": False}

    def _graceful_shutdown(_sig=None, _frame=None):
        if shutting_down["done"]:
            return
        shutting_down["done"] = True
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except Exception:
            pass
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
        previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except Exception:
                pass
            deadline = time.time() + 5.0
            while time.time() < deadline:
                ret = proc.poll()
                if ret is not None:
                    return ret
                try:
                    time.sleep(0.1)
                except KeyboardInterrupt:
                    break
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                pass
            while True:
                ret = proc.poll()
                if ret is not None:
                    return ret
                time.sleep(0.05)
        finally:
            try:
                signal.signal(signal.SIGINT, previous)
            except Exception:
                pass


def _patched_start_server(*, model=None, port=8000, host="127.0.0.1", max_tokens=None,
                          reload=False, log_level="info", verbose=False, supervise=True):
    return _run_server(host=host, port=port, max_tokens=max_tokens, reload=reload, log_level=log_level)


_serve.start_server = _patched_start_server

if __name__ == "__main__":
    from mlxk2.cli import main
    main()
PY

# -----------------------------------------------------------------------------
# Build with PyInstaller
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Package archive
# -----------------------------------------------------------------------------
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
