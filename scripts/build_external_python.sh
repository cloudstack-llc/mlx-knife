#!/usr/bin/env bash
set -euo pipefail

# Build a "no-PyInstaller" distribution that runs against an external Python
# (e.g., the interpreter embedded in your Electron app at
#   MyApp.app/Contents/Resources/python/bin/python3).
#
# This script vendors all Python deps and this project into a folder and
# generates a small launcher that executes: <external-python> -m mlxk2.cli ...
# with PYTHONPATH pointing at the vendored deps.
#
# Usage:
#   # Preferred: point to your embedded Python
#   EMBEDDED_PYTHON="/path/to/MyApp.app/Contents/Resources/python/bin/python3" \
#     scripts/build_external_python.sh
#
#   # Dev fallback (uses repo-local python/bin if present, else system python3)
#   scripts/build_external_python.sh
#
# Optional env:
#   BIN_NAME=my-cli             -> output folder/launcher name (default msty-mlx-studio)
#   DIST_DIR=dist-ext-python    -> output root (default dist-ext-python)
#   PIP_ARGS="..."              -> extra pip args (e.g., --no-index --find-links ...)
#   CLEAN=1                     -> delete output dir before build
#

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${BIN_NAME:-${APP_NAME:-msty-mlx-studio}}"
OUT_ROOT="${DIST_DIR:-dist-ext-python}"
OUT_DIR="$OUT_ROOT/$APP_NAME"
VENDOR_DIR="$OUT_DIR/_vendor"

# Resolve external Python
if [[ -n "${EMBEDDED_PYTHON:-}" ]]; then
  PY="$EMBEDDED_PYTHON"
  echo "Using EMBEDDED_PYTHON: $PY"
elif [[ -x "$ROOT_DIR/python/bin/python3" ]]; then
  PY="$ROOT_DIR/python/bin/python3"
  echo "Using repo-local Python: $PY"
else
  PY="$(command -v python3)"
  echo "WARNING: Falling back to system python3: $PY" >&2
fi

if [[ ! -x "$PY" ]]; then
  echo "ERROR: Python interpreter not executable: $PY" >&2
  exit 1
fi

# Clean output if requested
if [[ "${CLEAN:-0}" == "1" ]]; then
  rm -rf "$OUT_DIR"
fi
mkdir -p "$VENDOR_DIR"

if [[ "${VENDOR_VIA_WHEELS:-0}" == "1" ]]; then
  echo "[1/3] Vendoring via wheels (does not execute embedded Python)"
  SYS_PY="$(command -v python3)"
  if [[ -z "$SYS_PY" ]]; then
    echo "ERROR: python3 not found on PATH for wheel download" >&2
    exit 1
  fi
  : "${TARGET_PY_VERSION:?Set TARGET_PY_VERSION (e.g., 3.10)}"
  TARGET_PLATFORM="${TARGET_PLATFORM:-macosx_11_0_arm64}"
  # Derive ABI from version (e.g., 3.10 -> cp310)
  ver_nodot="${TARGET_PY_VERSION/.}"   # 3.10 -> 310
  TARGET_ABI="${TARGET_ABI:-cp${ver_nodot}}"
  WHEELS_DIR="$OUT_DIR/_wheels"
  rm -rf "$WHEELS_DIR" && mkdir -p "$WHEELS_DIR"

  echo "[1a] Downloading wheels for target Python ${TARGET_PY_VERSION} (${TARGET_ABI}) platform ${TARGET_PLATFORM}..."
  if [[ -f requirements.txt ]]; then
    "$SYS_PY" -m pip download -r requirements.txt -d "$WHEELS_DIR" \
      --only-binary=:all: --implementation cp --platform "$TARGET_PLATFORM" \
      --python-version "${TARGET_PY_VERSION}" --abi "$TARGET_ABI" ${PIP_ARGS:-}
  fi
  echo "[1b] Building wheel for local package..."
  "$SYS_PY" -m pip wheel -w "$WHEELS_DIR" . ${PIP_ARGS:-}

  echo "[2/3] Unpacking wheels into vendor..."
  for whl in "$WHEELS_DIR"/*.whl; do
    [ -e "$whl" ] || { echo "No wheels found in $WHEELS_DIR" >&2; exit 1; }
    unzip -oq "$whl" -d "$VENDOR_DIR"
  done

  # Sanity: detect missing MLX wheel for the chosen Python version
  if grep -Eqi '^\s*mlx([>=<]|\s|$)' "$ROOT_DIR/requirements.txt" 2>/dev/null; then
    if ! ls "$WHEELS_DIR"/mlx-*.whl >/dev/null 2>&1; then
      echo "" >&2
      echo "ERROR: No mlx wheel was downloaded for TARGET_PY_VERSION=${TARGET_PY_VERSION}." >&2
      echo "MLX publishes wheels only for certain Python versions (typically 3.11/3.12)." >&2
      echo "Try one of these options:" >&2
      echo "  - Use TARGET_PY_VERSION=3.12 (or 3.11) with VENDOR_VIA_WHEELS=1" >&2
      echo "  - Or omit VENDOR_VIA_WHEELS to let the embedded Python build from source (requires unquarantined/signed interpreter)" >&2
      exit 1
    fi
  fi
else
  echo "[1/3] Installing/Upgrading pip in external Python..."
  "$PY" - <<'PY'
import ensurepip, sys
try:
    ensurepip.bootstrap()
except Exception:
    pass
PY
  "$PY" -m pip install --upgrade pip setuptools wheel ${PIP_ARGS:-}

  echo "[2/3] Installing project dependencies into: $VENDOR_DIR"
  if [[ -f requirements.txt ]]; then
    "$PY" -m pip install --target "$VENDOR_DIR" -r requirements.txt ${PIP_ARGS:-}
  fi

  echo "[2/3b] Installing mlxk2 package into vendor..."
  "$PY" -m pip install --target "$VENDOR_DIR" . ${PIP_ARGS:-}
fi

echo "[3/3] Writing launcher: $OUT_DIR/$APP_NAME"
cat > "$OUT_DIR/$APP_NAME" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# Launcher for running mlxk2 against an external Python interpreter.
#
# Picks the interpreter from:
#   1) MLXK_PYTHON override
#   2) MyApp Electron resources path (macOS):
#        "$RESOURCES_PATH/python/bin/python3" if RESOURCES_PATH is set
#   3) repo-local ./python/bin/python3 relative to this launcher
#   4) system python3

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$SELF_DIR/_vendor"

PY="${MLXK_PYTHON:-}"
if [[ -z "$PY" && -n "${RESOURCES_PATH:-}" && -x "$RESOURCES_PATH/python/bin/python3" ]]; then
  PY="$RESOURCES_PATH/python/bin/python3"
fi
if [[ -z "$PY" && -x "$SELF_DIR/../python/bin/python3" ]]; then
  PY="$SELF_DIR/../python/bin/python3"
fi
if [[ -z "$PY" ]]; then
  PY="$(command -v python3)"
fi

if [[ "${1:-}" == "--python-info" ]]; then
  shift || true
  "$PY" - <<'PY'
import sys, json
print(json.dumps({
  "python_version": sys.version.split(" (", 1)[0],
  "executable": sys.executable,
  "prefix": sys.prefix,
  "base_prefix": getattr(sys, "base_prefix", None),
  "platform": sys.platform
}, indent=2))
PY
  exit 0
fi

export PYTHONNOUSERSITE=1
if [[ -n "${PYTHONPATH:-}" ]]; then
  export PYTHONPATH="$VENDOR_DIR:$PYTHONPATH"
else
  export PYTHONPATH="$VENDOR_DIR"
fi

exec "$PY" -m mlxk2.cli "$@"
SH
chmod +x "$OUT_DIR/$APP_NAME"

cp -f LICENSE "$OUT_DIR/" 2>/dev/null || true

echo "Built external-Python dist at: $OUT_DIR"
echo "Quick test:"
echo "  $OUT_DIR/$APP_NAME --python-info"
echo "  MLXK_PYTHON=\"/path/to/MyApp.app/Contents/Resources/python/bin/python3\" \\
    $OUT_DIR/$APP_NAME --version"
