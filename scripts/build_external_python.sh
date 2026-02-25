#!/usr/bin/env bash
set -euo pipefail

# Build a "no-PyInstaller" distribution that runs against an external Python
# (e.g., the interpreter embedded in your Electron app at
#   MyApp.app/Contents/Resources/python/bin/python3).
#
# The script vendors dependencies into dist-ext-python/<BIN_NAME>/_vendor and
# generates a launcher that executes: <python> -m mlxk2.cli ... with PYTHONPATH
# pointed at that vendor directory.

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
MLX_WHEEL_ARG=""
MLX_LM_WHEEL_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mlx-wheel)
      shift
      MLX_WHEEL_ARG="${1:-}"
      shift || true
      ;;
    --mlx-lm-wheel)
      shift
      MLX_LM_WHEEL_ARG="${1:-}"
      shift || true
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Output layout
# -----------------------------------------------------------------------------
APP_NAME="${BIN_NAME:-${APP_NAME:-msty-mlx-studio}}"
OUT_ROOT="${DIST_DIR:-dist-ext-python}"
OUT_DIR="$OUT_ROOT/$APP_NAME"
VENDOR_DIR="$OUT_DIR/_vendor"
ART_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ART_DIR"

# -----------------------------------------------------------------------------
# Resolve Python interpreter used for installs
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Prepare output (always clean)
# -----------------------------------------------------------------------------
rm -rf "$OUT_DIR"
mkdir -p "$VENDOR_DIR"

# -----------------------------------------------------------------------------
# Custom wheel resolution
# -----------------------------------------------------------------------------
CUSTOM_MLX_WHEEL="${MLX_WHEEL:-}"
if [[ -z "$CUSTOM_MLX_WHEEL" && -n "$MLX_WHEEL_ARG" ]]; then
  CUSTOM_MLX_WHEEL="$MLX_WHEEL_ARG"
fi
if [[ -z "$CUSTOM_MLX_WHEEL" && -f "$ROOT_DIR/scripts/mlx-custom.whl" ]]; then
  CUSTOM_MLX_WHEEL="$ROOT_DIR/scripts/mlx-custom.whl"
fi
if [[ -n "$CUSTOM_MLX_WHEEL" ]]; then
  echo "[opt] Using custom MLX wheel: $CUSTOM_MLX_WHEEL"
  [[ -f "$CUSTOM_MLX_WHEEL" ]] || { echo "ERROR: MLX wheel not found: $CUSTOM_MLX_WHEEL" >&2; exit 1; }
fi

CUSTOM_MLX_LM_WHEEL="${MLX_LM_WHEEL:-}"
if [[ -z "$CUSTOM_MLX_LM_WHEEL" && -n "$MLX_LM_WHEEL_ARG" ]]; then
  CUSTOM_MLX_LM_WHEEL="$MLX_LM_WHEEL_ARG"
fi
if [[ -z "$CUSTOM_MLX_LM_WHEEL" && -f "$ROOT_DIR/scripts/mlx-lm-custom.whl" ]]; then
  CUSTOM_MLX_LM_WHEEL="$ROOT_DIR/scripts/mlx-lm-custom.whl"
fi
if [[ -n "$CUSTOM_MLX_LM_WHEEL" ]]; then
  echo "[opt] Using custom MLX-LM wheel: $CUSTOM_MLX_LM_WHEEL"
  [[ -f "$CUSTOM_MLX_LM_WHEEL" ]] || { echo "ERROR: MLX-LM wheel not found: $CUSTOM_MLX_LM_WHEEL" >&2; exit 1; }
fi

# -----------------------------------------------------------------------------
# Vendoring strategy
# -----------------------------------------------------------------------------
if [[ "${VENDOR_VIA_WHEELS:-0}" == "1" ]]; then
  echo "[1/3] Vendoring via wheels (does not execute embedded Python)"
  SYS_PY="$(command -v python3)"
  if [[ -z "$SYS_PY" ]]; then
    echo "ERROR: python3 not found on PATH for wheel download" >&2
    exit 1
  fi
  : "${TARGET_PY_VERSION:?Set TARGET_PY_VERSION (e.g., 3.12)}"
  TARGET_PLATFORM="${TARGET_PLATFORM:-macosx_11_0_arm64}"
  ver_nodot="${TARGET_PY_VERSION/.}"   # 3.12 -> 312
  TARGET_ABI="${TARGET_ABI:-cp${ver_nodot}}"
  WHEELS_DIR="$OUT_DIR/_wheels"
  rm -rf "$WHEELS_DIR"
  mkdir -p "$WHEELS_DIR"

  echo "[1a] Downloading wheels for Python ${TARGET_PY_VERSION} (${TARGET_ABI}) platform ${TARGET_PLATFORM}..."
  REQ_FILE="requirements.txt"
  if [[ ( -n "$CUSTOM_MLX_WHEEL" || -n "$CUSTOM_MLX_LM_WHEEL" ) && -f requirements.txt ]]; then
    REQ_TMP="$(mktemp)"
    awk 'BEGIN{IGNORECASE=0} {
      line=$0; trimmed=line; gsub(/^[ \t]+/,"",trimmed);
      if (trimmed ~ /^#/ || trimmed ~ /^$/) { print line; next }
      if (ENVIRON["FILTER_MLX"] && trimmed ~ /^mlx([ \t]|[><=]|$)/) { next }
      if (ENVIRON["FILTER_MLX_LM"] && trimmed ~ /^mlx-lm([ \t]|[><=]|$)/) { next }
      print line
    }' FILTER_MLX=$([[ -n "$CUSTOM_MLX_WHEEL" ]] && echo 1) FILTER_MLX_LM=$([[ -n "$CUSTOM_MLX_LM_WHEEL" ]] && echo 1) requirements.txt > "$REQ_TMP"
    REQ_FILE="$REQ_TMP"
  fi

  if [[ -f "$REQ_FILE" ]]; then
    "$SYS_PY" -m pip download -r "$REQ_FILE" -d "$WHEELS_DIR" \
      --only-binary=:all: --implementation cp --platform "$TARGET_PLATFORM" \
      --python-version "${TARGET_PY_VERSION}" --abi "$TARGET_ABI" ${PIP_ARGS:-}
  fi
  if [[ "${REQ_FILE}" != "requirements.txt" ]]; then
    rm -f "$REQ_FILE"
  fi

  [[ -z "$CUSTOM_MLX_WHEEL" ]] || cp "$CUSTOM_MLX_WHEEL" "$WHEELS_DIR/"
  [[ -z "$CUSTOM_MLX_LM_WHEEL" ]] || cp "$CUSTOM_MLX_LM_WHEEL" "$WHEELS_DIR/"

  echo "[1b] Building wheel for local package..."
  "$SYS_PY" -m pip wheel -w "$WHEELS_DIR" . ${PIP_ARGS:-}

  echo "[2/3] Unpacking wheels into vendor..."
  shopt -s nullglob
  for whl in "$WHEELS_DIR"/*.whl; do
    unzip -oq "$whl" -d "$VENDOR_DIR"
  done
  shopt -u nullglob

  if grep -Eqi '^\s*mlx([>=<]|\s|$)' "$ROOT_DIR/requirements.txt" 2>/dev/null; then
    if ! ls "$WHEELS_DIR"/mlx-*.whl >/dev/null 2>&1; then
      echo >&2
      echo "ERROR: No mlx wheel was downloaded for TARGET_PY_VERSION=${TARGET_PY_VERSION}." >&2
      echo "MLX publishes wheels only for select Python versions (typically 3.11/3.12)." >&2
      echo "Use TARGET_PY_VERSION=3.12 (or 3.11) or disable VENDOR_VIA_WHEELS to build from source." >&2
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
    if [[ -n "$CUSTOM_MLX_WHEEL" || -n "$CUSTOM_MLX_LM_WHEEL" ]]; then
      REQ_TMP="$(mktemp)"
      awk 'BEGIN{IGNORECASE=0} {
        line=$0; trimmed=line; gsub(/^[ \t]+/,"",trimmed);
        if (trimmed ~ /^#/ || trimmed ~ /^$/) { print line; next }
        if (ENVIRON["FILTER_MLX"] && trimmed ~ /^mlx([ \t]|[><=]|$)/) { next }
        if (ENVIRON["FILTER_MLX_LM"] && trimmed ~ /^mlx-lm([ \t]|[><=]|$)/) { next }
        print line
      }' FILTER_MLX=$([[ -n "$CUSTOM_MLX_WHEEL" ]] && echo 1) FILTER_MLX_LM=$([[ -n "$CUSTOM_MLX_LM_WHEEL" ]] && echo 1) requirements.txt > "$REQ_TMP"
      "$PY" -m pip install --target "$VENDOR_DIR" -r "$REQ_TMP" ${PIP_ARGS:-}
      rm -f "$REQ_TMP"
    else
      "$PY" -m pip install --target "$VENDOR_DIR" -r requirements.txt ${PIP_ARGS:-}
    fi
  fi

  echo "[2/3b] Installing mlxk2 package into vendor..."
  "$PY" -m pip install --upgrade --force-reinstall --target "$VENDOR_DIR" . ${PIP_ARGS:-}

  if [[ -n "$CUSTOM_MLX_WHEEL" ]]; then
    echo "[opt] Installing custom MLX wheel into vendor..."
    "$PY" -m pip install --target "$VENDOR_DIR" --force-reinstall "$CUSTOM_MLX_WHEEL" ${PIP_ARGS:-}
  fi
  if [[ -n "$CUSTOM_MLX_LM_WHEEL" ]]; then
    echo "[opt] Installing custom MLX-LM wheel into vendor..."
    "$PY" -m pip install --target "$VENDOR_DIR" --force-reinstall "$CUSTOM_MLX_LM_WHEEL" ${PIP_ARGS:-}
  fi
fi

# -----------------------------------------------------------------------------
# Launcher
# -----------------------------------------------------------------------------
echo "[3/3] Writing launcher: $OUT_DIR/$APP_NAME"
cat > "$OUT_DIR/$APP_NAME" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$SELF_DIR/_vendor"

PY="${MLXK_PYTHON:-}"
if [[ -z "$PY" && -n "${RESOURCES_PATH:-}" && -x "$RESOURCES_PATH/python/bin/python3" ]]; then
  PY="$RESOURCES_PATH/python/bin/python3"
fi
if [[ -z "$PY" && -x "$SELF_DIR/python/bin/python3" ]]; then
  PY="$SELF_DIR/python/bin/python3"
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

if [[ "${1:-}" == "--mlx-info" || "${1:-}" == "--pkg-info" ]]; then
  cmd="$1"; shift || true
  pkg="mlx"
  if [[ "$cmd" == "--pkg-info" ]]; then
    pkg="${1:-mlx}"; shift || true
  fi
  "$PY" - <<PY
import json, importlib, sys, os
pkg = ${pkg@P}
try:
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
    print(json.dumps({
        "package": pkg,
        "version": version,
        "module_file": getattr(mod, "__file__", None),
        "dist_info": dist_info_dir,
    }, indent=2))
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(2)
PY
  exit 0
fi

if [[ "${1:-}" == "--check-mlx-stack" ]]; then
  "$PY" - <<'PY'
import json
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
    except Exception as exc:
        out["error"] = f"import mlx_lm failed: {exc}"
        print(json.dumps(out, indent=2))
        raise SystemExit(2)
    out["ok"] = True
    print(json.dumps(out, indent=2))
except Exception as exc:
    out["error"] = str(exc)
    print(json.dumps(out, indent=2))
    raise SystemExit(2)
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
echo "  $OUT_DIR/$APP_NAME --check-mlx-stack"
echo "  MLXK_PYTHON=\"/path/to/MyApp.app/Contents/Resources/python/bin/python3\" \\
    $OUT_DIR/$APP_NAME --version"

# -----------------------------------------------------------------------------
# Package tarball for distribution (unless skipped)
# -----------------------------------------------------------------------------
if [[ "${SKIP_TAR:-0}" != "1" ]]; then
  TAR_BASE="$APP_NAME"
  if [[ -n "${VERSION:-}" ]]; then
    TAR_BASE="$TAR_BASE-${VERSION}"
  fi
  TAR_NAME="${ARCHIVE_NAME:-${TAR_BASE}.tgz}"
  echo "[package] Creating $ART_DIR/$TAR_NAME"
  tar -C "$OUT_ROOT" -czf "$ART_DIR/$TAR_NAME" "$APP_NAME"
  echo "Created: $ART_DIR/$TAR_NAME"
fi
