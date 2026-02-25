# External Python Mode (Electron-embedded Python)

This variant does not use PyInstaller. Instead, it vendors all Python deps (including `mlxk2`) into a folder and runs against the Python interpreter you ship inside your Electron app (`MyApp.app/Contents/Resources/python/bin/python3`).

## Build

```bash
# Recommended: point to your embedded Python
EMBEDDED_PYTHON="/path/to/MyApp.app/Contents/Resources/python/bin/python3" \
  scripts/build_external_python.sh

# Dev fallback (uses ./python/bin/python3 if present, else system python3)
scripts/build_external_python.sh
```

Output: `dist-ext-python/<BIN_NAME>/` (default `msty-mlx-studio/`), containing:
- `_vendor/` – vendored site-packages (deps + project)
- `msty-mlx-studio` – launcher that runs `-m mlxk2.cli` with `PYTHONPATH=_vendor`

Verify the Python in use:

```bash
./dist-ext-python/msty-mlx-studio/msty-mlx-studio --python-info

### Building without executing the embedded Python (avoids Gatekeeper during dev)

If macOS blocks running your embedded Python during the build, you can vendor wheels for a target version without executing that interpreter:

```bash
TARGET_PY_VERSION=3.10 \
VENDOR_VIA_WHEELS=1 \
scripts/build_external_python.sh
```

Notes:
- This uses your system Python to `pip download` wheels for macOS arm64 and the specified Python version, then unpacks them into `_vendor`.
- At runtime, the Electron-embedded Python imports from `_vendor` via `PYTHONPATH`.
- For compiled packages, you must choose a `TARGET_PY_VERSION` that matches your embedded Python minor version (e.g., 3.10 → cp310 wheels).
```

## Packaging into Electron

Place the folder under your app resources, for example:

```
MyApp.app/Contents/Resources/
  python/bin/python3              # your embedded Python
  mlxk2/
    _vendor/
    msty-mlx-studio               # launcher
```

### Option A: Use the launcher

- Command: `join(process.resourcesPath, 'mlxk2', 'msty-mlx-studio')`
- Env: set `RESOURCES_PATH=process.resourcesPath` (so the launcher finds `python/bin/python3`).

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

### Option B: Call Python directly

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

- You are responsible for shipping a compatible macOS arm64 Python with all required system libs.
- If using private or offline wheels, pass extra pip args: `PIP_ARGS="--no-index --find-links /path/to/wheels" scripts/build_external_python.sh`.
- To sanity check deps at runtime:
  `PYTHONPATH=<vendor> <embedded-python> -c "import mlxk2, fastapi, uvicorn, mlx, mlx_lm; print('ok')"`
