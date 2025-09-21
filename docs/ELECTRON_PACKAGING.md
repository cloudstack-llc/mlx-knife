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

## Runtime Integration

- Our Electron app handles model downloads directly (see `ELECTRON_INTEGRATION_GUIDE.md`).
- The packaged CLI is used for listing/showing models, running prompts, and serving the HTTP API.
- Set `HF_HOME` to the same cache location used by the Electron downloader so the CLI sees downloaded models.

That’s it—build, ship, and run the CLI as a single-folder artifact without patching upstream.
