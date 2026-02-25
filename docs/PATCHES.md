# Build-Time Patches

Patches in `scripts/patches/` are applied during the build process (`build.sh` and `build_external_python.sh`) to modify source files before packaging. They are automatically cleaned up on exit via the `cleanup_patches()` trap.

These patches exist separately from the main source to keep the development codebase clean while applying build-specific fixes and enhancements to the packaged binary.

## Status

| Patch | Upstream Fix? | Why Still Needed |
|---|---|---|
| **cli.patch** | No | `main` still hardcodes `supervise=True`. Build scripts still use the two-tier parent/child architecture requiring `MLXK2_SUPERVISE=0` to prevent double supervision. |
| **server_models.patch** | No | `main` still filters out unhealthy models with `health != "healthy"` check. |
| **server_streaming_usage.patch** | No | `main` still uses rough `len(text.split()) * 1.3` estimation in `count_tokens()` with no tokenizer parameter. Streaming responses have no `usage` block. |
| **runner_decode.patch** | No | `main` still uses `_decode_tokens()` which resets and re-processes all tokens on every call (O(n^2)). The issue is in this project's usage pattern, not an upstream mlx-lm bug. |
---

## cli.patch

**File:** `mlxk2/cli.py`

Adds the `MLXK2_SUPERVISE` environment variable to allow disabling subprocess uvicorn supervision.

The packaged binary uses a two-tier server architecture: a parent process (PyInstaller wrapper) spawns and supervises a child process that runs the actual uvicorn server. The parent handles graceful shutdown (SIGTERM then SIGKILL). Without this patch, the child would also try to spawn its own supervised subprocess, creating redundant nesting. Setting `MLXK2_SUPERVISE=0` lets the child run the server in-process.

## server_models.patch

**File:** `mlxk2/core/server_base.py`

Removes the `health != "healthy"` filter from the `/v1/models` endpoint, keeping only the `runtime_compatible` filter.

The `health` field indicates file integrity issues (corrupted files, missing snapshots), while `runtime_compatible` indicates feature compatibility (e.g., vision model without mlx-vlm installed). By filtering out unhealthy models entirely, users had no way to see why a model disappeared from the list. With this patch, unhealthy models remain visible with their status, so users can diagnose and repair them.

## server_streaming_usage.patch

**File:** `mlxk2/core/server_base.py`

Adds token usage statistics to streaming responses and switches `count_tokens()` from rough word-count estimation to actual tokenizer-based counting.

The OpenAI streaming API spec includes a `usage` block (`prompt_tokens`, `completion_tokens`, `total_tokens`) in the final SSE chunk. Without this patch, streaming responses omit usage entirely, and non-streaming responses use an inaccurate `len(text.split()) * 1.3` approximation. The patch accumulates generated text during streaming, counts tokens via `tokenizer.encode()`, and includes the usage block in the final chunk.

## runner_decode.patch

**File:** `mlxk2/core/runner/__init__.py`

Replaces `self._decode_tokens()` with `self.tokenizer.decode()` to fix an O(n^2) performance regression during streaming inference.

The custom `_decode_tokens()` method calls `detokenizer.reset()` and re-processes all tokens on every invocation. When called in the streaming loop for each new token, this causes quadratic complexity, dropping inference speed from ~200 tokens/sec to ~5 tokens/sec. Using `tokenizer.decode()` directly is a single-pass O(n) operation and handles BPE space markers correctly.

