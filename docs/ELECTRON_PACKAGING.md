# MLX Knife – Electron Packaging (macOS arm64)

This document explains how we package the upstream `mlxk2` CLI for use inside our Electron app. We ship a self-contained binary bundle and keep upstream code unmodified. Model downloads happen in Electron, so we do not rely on `pull` at runtime.

## Overview

- Target: macOS Apple Silicon (M1/M2/M3), arm64.
- Builder: PyInstaller via `scripts/build.sh`.
- Output: `artifacts/<name>.tgz` containing a one-dir bundle by default (recommended) or a one-file binary.
- Binary/folder name: defaults to `msty-mlx-studio` (configurable via `BIN_NAME`).

## Prerequisites

- Apple Silicon Mac.
- Xcode Command Line Tools (`xcode-select --install`).
- Python 3.9+ available as `python3`.

## Build Script

```bash
# Onedir build (recommended)
scripts/build.sh

# Onefile build
ONEFILE=1 scripts/build.sh

# Versioned archive name
VERSION=1.2.3 scripts/build.sh

# Custom binary name (default is msty-mlx-studio)
BIN_NAME=my-cli scripts/build.sh

# Skip optional Hugging Face Xet plugin (installed by default)
USE_HF_XET=0 scripts/build.sh
```

The script creates a virtualenv, installs runtime deps from `requirements.txt` (`mlx`, `mlx-lm`, `fastapi`, `uvicorn`, etc.) plus the project itself, then builds a PyInstaller bundle and packages it into `artifacts/<name>.tgz`.

### Build options reference

Environment variables / flags:

- `VERSION` – temporary override for `mlxk2.__version__` while bundling.
- `BIN_NAME` – output folder/binary name (default `msty-mlx-studio`).
- `ONEFILE=1` – build a single-file PyInstaller binary (defaults to one-dir).
- `USE_HF_XET=0` – skip the optional Hugging Face Xet plugin.
- `PYTHON_EXE=/abs/path/python3` – force a specific interpreter for the build venv.
- `MLX_WHEEL=/abs/path/mlx.whl` or `--mlx-wheel` – install a custom `mlx` wheel after deps.
- `MLX_LM_WHEEL=/abs/path/mlx_lm.whl` or `--mlx-lm-wheel` – install a matching custom `mlx-lm` wheel.
- `PIP_ARGS="..."` – forwarded to pip install commands if you need custom indexes.

Quick test after build:

```bash
mkdir -p ~/mlxk-test
tar -xzf artifacts/msty-mlx-studio.tgz -C ~/mlxk-test
xattr -dr com.apple.quarantine ~/mlxk-test/msty-mlx-studio
~/mlxk-test/msty-mlx-studio/msty-mlx-studio --version  # prints just the numeric version
```

Where binaries land:
- Onedir: `dist/<name>/<name>` (folder with libs + executable)
- Onefile: `dist/<name>` (single executable)

## Server behavior

- The packaged binary runs the HTTP server in-process (single PID). This keeps process management simple from Electron.
- Pressing Ctrl-C stops the process; from Electron, send `SIGINT` to the spawned process handle or `SIGKILL` if needed.

Version reporting:
- The packaged binary prints only the numeric version for `--version`.
- For structured output, use `--version --json` to get `{ cli_version, json_api_spec_version }`.

## Notes

- Optional Hugging Face Xet plugin (`hf_xet`) is installed by default; disable with `USE_HF_XET=0` if a wheel isn’t available.
- The script copies `LICENSE` into the archive.
- No upstream source is modified. All adjustments happen in the generated entry shim used only at build time.
- The previous v1 helper worker is no longer built or packaged.

### Custom Python runtime

To freeze with a specific Python (and embed that version in the bundle), place it at `python/bin/python3` in the repo. The build script will automatically prefer this interpreter for creating the build venv and running PyInstaller. Alternatively, set `PYTHON_EXE=/absolute/path/to/python3` to override.

#### Custom MLX / MLX-LM wheels

If you need to ship custom builds:

```bash
# Auto-detected defaults: scripts/mlx-custom.whl, scripts/mlx-lm-custom.whl
MLX_WHEEL=/abs/path/mlx.whl \
MLX_LM_WHEEL=/abs/path/mlx_lm.whl \
  scripts/build.sh

# Equivalent flag form
scripts/build.sh \
  --mlx-wheel /abs/path/mlx.whl \
  --mlx-lm-wheel /abs/path/mlx_lm.whl
```

Notes:
- `mlx` and `mlx-lm` are filtered out of `requirements.txt`; your wheels install last and override PyPI pins.
- Provide compatible builds (matching Python ABI / MLX API surface) to avoid runtime mismatches.
- Use `--check-mlx-stack` (see below) on the finished binary to confirm both packages import cleanly.

### Version override

Set `VERSION` when invoking the build to stamp the bundle with a release number:

```bash
VERSION=2.0.0b4 scripts/build.sh
```

Details:
- The script temporarily rewrites `mlxk2/__version__` (and related README references) during the build.
- Files are restored to their original contents after the script exits, so your working tree stays clean.

Steps:
- Put your desired macOS arm64 Python at `python/bin/python3`.
- Run `scripts/build.sh`.
- Verify the embedded Python in the resulting binary:

```bash
./dist/msty-mlx-studio/msty-mlx-studio --python-info
# or
MLXK2_PY_INFO=1 ./dist/msty-mlx-studio/msty-mlx-studio --version
```

This prints JSON like:
```
{
  "python_version": "3.12.5",
  "executable": "/path/to/dist/msty-mlx-studio/msty-mlx-studio",
  "prefix": "/path/to/dist/msty-mlx-studio",
  "base_prefix": null,
  "frozen": true,
  "meipass": "/path/to/_MEIxxxx",
  "platform": "darwin"
}
```

Notes:
- `python_version` confirms which interpreter is embedded. `executable` is the frozen launcher (expected for PyInstaller).
- Ensure your chosen Python is compatible with the pinned PyInstaller (>= 6.6). For very new Python releases, update PyInstaller if needed.

### Quick diagnostics on the output bundle

- `./dist/<name>/<name> --python-info` – JSON summary of the embedded interpreter.
- `./dist/<name>/<name> --mlx-info` – JSON showing `mlx` version, module path, and dist-info directory.
- `./dist/<name>/<name> --pkg-info mlx_lm` – same diagnostic for `mlx-lm`.
- `./dist/<name>/<name> --check-mlx-stack` – verifies both `mlx` and `mlx_lm` import successfully.

Use these after applying custom wheels to ensure the expected versions were bundled.

### Clearing quarantine during development

macOS Gatekeeper may block unsigned interpreters inside the bundle. During local builds/tests, run:

```bash
scripts/clear_quarantine_python.sh dist/<name>/python
```

Or target your Electron resources path. This recurses through the folder and removes the `com.apple.quarantine` extended attribute, reporting any leftovers. (Sign and notarize for production distribution.)

## Runtime Integration

- Our Electron app handles model downloads directly (see `ELECTRON_INTEGRATION_GUIDE.md`).
- The packaged CLI is used for listing/showing models, running prompts, and serving the HTTP API.
- Set `HF_HOME` to the same cache location used by the Electron downloader so the CLI sees downloaded models.

That’s it—build, ship, and run the CLI as a single-folder artifact without patching upstream.
