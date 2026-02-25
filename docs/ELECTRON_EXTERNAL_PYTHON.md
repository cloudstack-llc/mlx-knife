# External Python Mode (Electron-embedded Python)

This variant skips PyInstaller. We vendor all Python dependencies (and `mlxk2` itself) into a folder and run the CLI with the Python interpreter you bundle inside the Electron app (`MyApp.app/Contents/Resources/python/bin/python3`).

## Build quick reference

```bash
# Preferred: install using the embedded Python
EMBEDDED_PYTHON="/path/to/MyApp.app/Contents/Resources/python/bin/python3" \
  scripts/build_external_python.sh

# Dev fallback (uses ./python/bin/python3 if present, else system python3)
scripts/build_external_python.sh

# Provide custom MLX / MLX-LM wheels
scripts/build_external_python.sh \
  --mlx-wheel scripts/mlx-custom.whl \
  --mlx-lm-wheel scripts/mlx-lm-custom.whl

# Wheels-only mode (no interpreter execution)
TARGET_PY_VERSION=3.12 \
VENDOR_VIA_WHEELS=1 \
scripts/build_external_python.sh
```

Output: `dist-ext-python/<BIN_NAME>/` (default `msty-mlx-studio/`), containing:

- `_vendor/` – vendored site-packages (deps + project)
- `msty-mlx-studio` – launcher that runs `-m mlxk2.cli` with `PYTHONPATH=_vendor`

### Build options reference

- `EMBEDDED_PYTHON` – interpreter used for installs (falls back to `./python/bin/python3`, then system python3).
- `MLX_WHEEL`, `MLX_LM_WHEEL`, `--mlx-wheel`, `--mlx-lm-wheel` – custom package wheels; defaults auto-detect `scripts/mlx-custom.whl` and `scripts/mlx-lm-custom.whl` if present.
- `VERSION` – temporary override for `mlxk2.__version__` while bundling; README references adjust automatically.
- `DIST_DIR`, `BIN_NAME` – output location/name (default `dist-ext-python/msty-mlx-studio`).
- `CLEAN=1` – delete the output directory before writing.
- `PIP_ARGS="..."` – extra pip flags (shared by install/download steps).
- `VENDOR_VIA_WHEELS=1`, `TARGET_PY_VERSION`, `TARGET_PLATFORM`, `TARGET_ABI` – download wheels without executing the embedded interpreter.

### Wheels-only mode (Gatekeeper-friendly)

If macOS blocks your embedded Python during the build, set `VENDOR_VIA_WHEELS=1` and choose a compatible `TARGET_PY_VERSION`. The script uses the system python to `pip download` macOS arm64 wheels and unpacks them into `_vendor`. Ensure the chosen Python minor version matches your embedded interpreter so compiled wheels load correctly.

### Custom MLX / MLX-LM wheels

Provide custom builds to keep the MLX stack in sync:

```bash
scripts/build_external_python.sh \
  --mlx-wheel /abs/path/mlx.whl \
  --mlx-lm-wheel /abs/path/mlx_lm.whl
```

Both options can also be set via environment variables. The script filters `mlx` and `mlx-lm` out of `requirements.txt`, then installs your wheels last so they override PyPI pins in `_vendor`.

### Diagnostics

After building, run the launcher with these flags to confirm what was bundled:

```bash
./dist-ext-python/msty-mlx-studio/msty-mlx-studio --python-info   # interpreter summary
./dist-ext-python/msty-mlx-studio/msty-mlx-studio --mlx-info      # mlx version + dist-info path
./dist-ext-python/msty-mlx-studio/msty-mlx-studio --pkg-info mlx_lm
./dist-ext-python/msty-mlx-studio/msty-mlx-studio --check-mlx-stack
```

`--check-mlx-stack` imports both `mlx` and `mlx_lm` to ensure API compatibility—run this after swapping in custom wheels.

### Version override

Stamp the vendored package with a release number:

```bash
VERSION=2.0.0b4 scripts/build_external_python.sh
```

The script temporarily rewrites `mlxk2/__version__` and README references for the build and restores them afterward, so your working tree stays clean.

## Packaging into Electron

Place the output under app resources, for example:

```
MyApp.app/Contents/Resources/
  python/bin/python3              # bundled interpreter
  mlxk2/
    _vendor/
    msty-mlx-studio               # launcher
```

### Option A – use the launcher

- Command: `join(process.resourcesPath, 'mlxk2', 'msty-mlx-studio')`
- Env: set `RESOURCES_PATH=process.resourcesPath` (the launcher uses it to locate `python/bin/python3`).

```js
import { spawn } from 'child_process';
import { join } from 'path';
import { app } from 'electron';

const launcher = join(process.resourcesPath, 'mlxk2', 'msty-mlx-studio');

export function startServer({ host = '127.0.0.1', port = 8000, maxTokens } = {}) {
  const args = ['serve', '--host', host, '--port', String(port)];
  if (maxTokens != null) args.push('--max-tokens', String(maxTokens));
  const env = { ...process.env, RESOURCES_PATH: process.resourcesPath };
  const child = spawn(launcher, args, { env, stdio: ['ignore', 'inherit', 'inherit'] });
  return child;
}
```

### Option B – call Python directly

- Python: `join(process.resourcesPath, 'python', 'bin', 'python3')`
- Vendor: `join(process.resourcesPath, 'mlxk2', '_vendor')`
- Env: `PYTHONPATH=<vendor>[:$PYTHONPATH]`, `PYTHONNOUSERSITE=1`

```js
import { spawn } from 'child_process';
import { join } from 'path';
import { app } from 'electron';

export function startServer({ host = '127.0.0.1', port = 8000, maxTokens } = {}) {
  const pythonPath = join(process.resourcesPath, 'python', 'bin', 'python3');
  const vendor = join(process.resourcesPath, 'mlxk2', '_vendor');
  const args = ['-m', 'mlxk2.cli', 'serve', '--host', host, '--port', String(port)];
  if (maxTokens != null) args.push('--max-tokens', String(maxTokens));
  const env = { ...process.env, PYTHONNOUSERSITE: '1', PYTHONPATH: vendor };
  const child = spawn(pythonPath, args, { env, stdio: ['ignore', 'inherit', 'inherit'] });
  return child;
}
```

## Notes

- Ship a compatible macOS arm64 Python with required system libs.
- For private/offline wheels, pass `PIP_ARGS="--no-index --find-links /path/to/wheels"`.
- Clear Gatekeeper quarantine on the embedded Python during development with `scripts/clear_quarantine_python.sh /path/to/Resources/python`.
- Sanity-check at runtime:
  `PYTHONPATH=<vendor> <embedded-python> -c "import mlxk2, fastapi, uvicorn, mlx, mlx_lm; print('ok')"`
- Sign + notarize the final `.app` for distribution.
