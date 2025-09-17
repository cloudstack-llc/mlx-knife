#!/usr/bin/env bash
set -euo pipefail

# Build and bundle a macOS arm64 (Apple Silicon) CLI tarball using PyInstaller.
# Invoked as scripts/build.sh
#
# Outputs: artifacts/<name>.tgz containing dist/<name>/...
# Optional env:
#   ONEFILE=1   -> build single-file binary (defaults to onedir for reliability)
#   VERSION=1.1 -> append version to tarball name
#   USE_HF_XET=0 -> skip installing Hugging Face Xet plugin
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
CLI_FILE="$ROOT_DIR/mlx_knife/cli.py"
CLI_BACKUP="$CLI_FILE.bak"

mkdir -p "$ART_DIR" "$SPEC_DIR"

if [[ -f "$CLI_BACKUP" ]]; then
  rm -f "$CLI_BACKUP"
fi
cp "$CLI_FILE" "$CLI_BACKUP"
trap 'mv -f "$CLI_BACKUP" "$CLI_FILE" >/dev/null 2>&1 || true' EXIT

python - "$CLI_FILE" <<'PY'
from pathlib import Path
import sys

cli_path = Path(sys.argv[1])
text = cli_path.read_text()
needle = "version=f'MLX Knife {__version__}'"
if needle in text:
    text = text.replace(needle, "version=__version__")
cli_path.write_text(text)
PY

echo "[1/4] Creating build venv..."
python3 -m venv "$BUILD_VENV"
source "$BUILD_VENV/bin/activate"
python -m pip install --upgrade pip setuptools wheel

echo "[2/4] Installing project and build tools..."
python -m pip install .

TF_VERSION_CONSTRAINT=${TF_VERSION_CONSTRAINT:-">=4.44"}
TOKENIZERS_VERSION_CONSTRAINT=${TOKENIZERS_VERSION_CONSTRAINT:-">=0.15"}
SAFETENSORS_VERSION_CONSTRAINT=${SAFETENSORS_VERSION_CONSTRAINT:-">=0.4.2"}
SENTENCEPIECE_VERSION_CONSTRAINT=${SENTENCEPIECE_VERSION_CONSTRAINT:-">=0.1.99"}
python -m pip install \
  "transformers${TF_VERSION_CONSTRAINT}" \
  "tokenizers${TOKENIZERS_VERSION_CONSTRAINT}" \
  "safetensors${SAFETENSORS_VERSION_CONSTRAINT}" \
  "sentencepiece${SENTENCEPIECE_VERSION_CONSTRAINT}"

if [[ "${USE_HF_XET:-1}" == "1" ]]; then
  echo "[opt] Installing Hugging Face Xet plugin..."
  python -m pip install "huggingface_hub[hf_xet]" || true
fi

python -m pip install "pyinstaller>=6.6"

ENTRY_SCRIPT="$ROOT_DIR/.entry_mlxk_build.py"
cat > "$ENTRY_SCRIPT" <<'PY'
from mlx_knife.cli import main
if __name__ == "__main__":
    main()
PY

echo "[3/4] Building executables..."
PYI_OPTS=(
  --clean
  --noconfirm
  --name "$APP_NAME"
  --log-level=WARN
  --specpath "$SPEC_DIR"
  --collect-all mlx
  --collect-all mlx_lm
  --collect-all huggingface_hub
  --collect-all transformers
  --collect-all tokenizers
  --collect-all safetensors
  --collect-all sentencepiece
  --collect-all hf_xet
  --collect-all pyxet
  --collect-all fastapi
  --collect-all pydantic
  --add-data "$ROOT_DIR/mlx_knife/throttled_download_worker.py:mlx_knife"
)

if [[ "${ONEFILE:-0}" == "1" ]]; then
  PYI_OPTS+=(--onefile)
else
  PYI_OPTS+=(--onedir)
fi

pyinstaller "${PYI_OPTS[@]}" "$ENTRY_SCRIPT"

pyinstaller \
  --clean --noconfirm --onefile --log-level=WARN \
  --specpath "$SPEC_DIR" \
  --name throttled_download_worker \
  --collect-all huggingface_hub \
  --collect-all requests \
  mlx_knife/throttled_download_worker.py

echo "[4/4] Packaging archive..."
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

if [[ -f "$DIST_DIR/throttled_download_worker" ]]; then
  cp "$DIST_DIR/throttled_download_worker" "$PACK_DIR/$APP_NAME/throttled_download_worker"
fi

cp -f LICENSE "$PACK_DIR/$APP_NAME/" 2>/dev/null || true

tar -C "$PACK_DIR" -czf "$ART_DIR/$TAR_NAME" "$APP_NAME"
echo "Created: $ART_DIR/$TAR_NAME"

echo "Build complete. Binaries are in dist/, archive in artifacts/."

rm -f "$ENTRY_SCRIPT"
