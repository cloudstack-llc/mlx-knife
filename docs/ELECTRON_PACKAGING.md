# MLX Knife – Embedding in an Electron App (macOS arm64)

This note explains how we build and redistribute the upstream `mlxk` CLI inside our Electron app. The CLI bundle is unchanged from upstream; model downloads are handled in Electron (see `MLXKModelDownloader`), so we do **not** rely on `mlxk pull` at runtime.

## Overview

- Target: macOS Apple Silicon (M1/M2/M3), arm64.
- Build tool: PyInstaller (run via `scripts/build.sh`).
- Output: `artifacts/<name>.tgz` containing either a one-dir bundle or a one-file binary plus the helper `throttled_download_worker`.

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

The script creates a virtualenv, installs project dependencies (Transformers, tokenizers, etc.), builds the CLI and the helper worker, then packages them into `artifacts/<name>.tgz`. The CLI is ready to run from the extracted folder:

```bash
mkdir -p ~/mlxk-test
 tar -xzf artifacts/msty-mlx-studio.tgz -C ~/mlxk-test
xattr -dr com.apple.quarantine ~/mlxk-test/msty-mlx-studio
~/mlxk-test/msty-mlx-studio/msty-mlx-studio --help
```

Where binaries land:
- Onedir: `dist/<name>/<name>` (folder with libs + executable)
- Onefile: `dist/<name>` (single executable)

The worker binary `throttled_download_worker` is packaged alongside for CLI compatibility.

## Notes

- Optional Hugging Face Xet plugin (`hf_xet`) is installed by default for faster downloads when upstream enables it; disable with `USE_HF_XET=0` if the wheel is unavailable.
- The script copies `LICENSE` into the archive; add other files if desired.
- We intentionally avoid modifying upstream source (`mlx_knife/*`).

## Runtime Integration

- The Electron app handles downloads via `MLXKModelDownloader` and `MLXKModelDownloader.ts` (see `apps/desktop/src/mlx`).
- The packaged CLI is used for listing/running models, not for downloading. Simply ensure `HF_HOME` is set to the same cache directory the downloader writes to when spawning the CLI.

That’s it—no overlays, no runtime monkeypatches. Build, ship, and run the CLI as-is.
