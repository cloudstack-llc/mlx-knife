# MLX Knife – Electron Integration Guide (macOS arm64)

This guide covers how our Electron app embeds the upstream `mlxk` CLI and how we download models ourselves (without `mlxk pull`).

- Build the CLI once with `scripts/build.sh` (see `docs/ELECTRON_PACKAGING.md`).
- Extract the archive into `app.getPath('userData')/msty-mlx-studio` (or whatever `BIN_NAME` you built).
- Clear quarantine (`xattr -dr com.apple.quarantine <folder>`) on first install.

## CLI usage (list/show/run/server)

Wrap the CLI in a helper so we can spawn it with consistent env vars:

```js
// electron/main/mlxk.js
import { spawn } from 'child_process';
import { join } from 'path';
import { app } from 'electron';

const binRoot = join(app.getPath('userData'), 'msty-mlx-studio');
const exePath = join(binRoot, 'msty-mlx-studio');

function baseEnv(extra = {}) {
  return {
    ...process.env,
    HF_HOME: join(app.getPath('userData'), 'hf'),
    TRANSFORMERS_NO_TORCH: '1',
    TRANSFORMERS_NO_TF: '1',
    TRANSFORMERS_NO_FLAX: '1',
    HF_HUB_DISABLE_TELEMETRY: '1',
    ...extra,
  };
}

export function spawnMlxk(args, options = {}) {
  const { env = {}, stdio = ['ignore', 'inherit', 'inherit'] } = options;
  return spawn(exePath, args, { env: baseEnv(env), stdio });
}
```

You can then build helpers such as:

```js
export function listModels({ all = false, verbose = false } = {}) {
  const args = ['list'];
  if (all) args.push('--all');
  if (verbose) args.push('--verbose');
  return new Promise((resolve, reject) => {
    const child = spawnMlxk(args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const output = [];
    child.stdout.on('data', (d) => output.push(d.toString()))
    child.stderr.on('data', (d) => output.push(d.toString()))
    child.on('exit', (code) => code === 0 ? resolve(output.join('')) : reject(code));
  });
}
```

The same `spawnMlxk` wrapper works for `show`, `rm`, `run`, or starting the HTTP server (`mlxk server`).

## Downloads handled in Node

Rather than calling `mlxk pull`, we download models from Hugging Face directly so we have full control over progress and caching. Use `MLXKModelDownloader` (see `apps/desktop/src/mlx/MLXKModelDownloader.ts`). It mirrors the existing `MLXModelDownloader` API:

```ts
import { MLXKModelDownloader } from './MLXKModelDownloader';
const downloader = new MLXKModelDownloader(app.getPath('userData'));

await downloader.downloadModel('mlx-community/Qwen3-4B-Instruct-2507-8bit', (progress) => {
  // progress.fileName, progress.percentage, progress.speed, etc.
});
```

The downloader writes into the Hugging Face cache layout:
```
HF_HOME/hub/models--<owner>--<name>/snapshots/<commit>/...
HF_HOME/hub/models--<owner>--<name>/refs/main            # contains <commit>
```
Once the files are in place, the CLI can list/run the model immediately.

### Cancellation
`MLXKModelDownloader.cancelDownloadForModel(modelId)` stops in-flight downloads, removes partial files, and cleans up empty directories.

## Environment Variables for CLI processes

Set these when spawning the CLI (already baked into `baseEnv` above):

- `HF_HOME` – shared cache location for downloads and CLI usage.
- `TRANSFORMERS_NO_TORCH=1`, `TRANSFORMERS_NO_TF=1`, `TRANSFORMERS_NO_FLAX=1` – faster start, no unwanted backend checks.
- `HF_HUB_DISABLE_TELEMETRY=1` – avoid telemetry from Hugging Face Hub.

## Server quick start

```bash
HF_HOME="/Users/<user>/.myapp/hf" \
~/Library/Application\ Support/MyApp/msty-mlx-studio/msty-mlx-studio \
  server --host 127.0.0.1 --port 8000 --max-tokens 4000
```

Interact via the OpenAI-compatible endpoints:

```bash
curl -X POST "http://127.0.0.1:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "Phi-3-mini-4k-instruct-4bit", "messages": [{"role":"user","content":"Hello"}]}'
```

That’s the entire integration: package the CLI once, manage downloads yourself with `MLXKModelDownloader`, and spawn the CLI for listing/running or serving models.
