# Release Guide (External Python, Signed + Notarized)

This project ships a single-folder bundle that runs with a Python you provide. Use one command to build, sign, package, and notarize a release.

## Prerequisites

- macOS Apple Silicon runner (local or GitHub Actions).
- Embedded Python at `python/bin/python3` (arm64).
- Apple Developer ID Application certificate (for codesign).
- Apple ID app-specific password (for notarization).
- Cloudflare R2 credentials if uploading.

## One‑shot local release (defaults)

```
# VERSION is picked from package.json if not set (override by exporting VERSION)
# export VERSION=2.0.0b6
export SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@apple.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"

# Minimal: external variant, uses ./python/bin/python3 automatically,
# disables library validation by default, signs + notarizes and emits TGZ
scripts/release.sh

### Automatic CPython download

If you don’t have `./python` prepared, provide a standalone CPython URL and the release script will download + extract it and use it as the embedded interpreter:

```
export SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_SPECIFIC_PASSWORD=…

CPYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20251014/cpython-3.10.19+20251014-aarch64-apple-darwin-install_only.tar.gz" \
  scripts/release.sh --variant external --disable-libval
```

By default, it extracts into `./python` and uses `./python/bin/python3`.
```

Outputs:
- Folder: `dist-ext-python/msty-mlx-studio` (includes `python/` and `_vendor/`)
- Tgz (for your in‑app download): `artifacts/msty-mlx-studio-<VERSION>.tgz` (signed)

Notes:
- `--disable-libval` adds the entitlement `com.apple.security.cs.disable-library-validation` to allow loading signed third‑party libraries while using hardened runtime.
- For a local dry-run without notarization, add `--skip-notarize`.

## NPM helper

```
# Uses the embedded python at ./python/bin/python3
# Environment variables for signing/notarization must be set as above
npm run mlx:release
```

## GitHub Actions CI

Use `.github/workflows/release.yml`:
- Triggers manually with `workflow_dispatch`.
- Requires secrets:
  - `CSC_NAME` – your codesign identity (Developer ID Application: … (TEAMID))
  - `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`
  - (Optional) `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` – base64 .p12 if importing the cert in CI
- (Optional) `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `R2_ENDPOINT` – for Cloudflare R2 upload (S3 compatible)
- (Optional) Input `cpython_url` – if provided, CI will download CPython automatically; otherwise expects `./python/bin/python3` checked in.
- (Optional) Input `r2_path` – custom path under the bucket (default `releases/<version>/`).

Artifacts:
- Uploaded to the workflow run (`artifacts/*.tgz`).
- Optionally uploaded to R2 at `s3://$R2_BUCKET/releases/<version>/`.

## Process model and signals

- The release builds a native launcher to keep the parent process name as `msty-mlx-studio`.
- The launcher sets `MLXK2_SUPERVISE=0` so uvicorn runs in-process. Expect one `python` child under the launcher.
- Stop via `SIGINT`/`SIGTERM` to the launcher; the python child receives the same and exits promptly. A second signal escalates to `SIGKILL`.

## Verify signing & notarization

Extract the TGZ, reapply quarantine to the launcher, then run Gatekeeper and codesign checks:

```
TMP=$(mktemp -d)
tar -xzf artifacts/msty-mlx-studio-<VERSION>.tgz -C "$TMP"
APP="$TMP/msty-mlx-studio/msty-mlx-studio"
xattr -w com.apple.quarantine "0081;$(date +%s);mlxk2;GatekeeperTest" "$APP"
spctl -a -t exec -vv "$APP"    # Expect: accepted (Notarized Developer ID)
codesign --verify --deep --strict --verbose=2 "$APP"
```

## Troubleshooting

- Gatekeeper blocks embedded Python during build:
  - The release script pre‑signs the embedded interpreter and clears quarantine.
- pydantic_core import error in PyInstaller bundle:
  - We collect `pydantic_core` explicitly.
- MLX `libmlx.dylib` missing:
  - External bundle places it under `_vendor/`. For PyInstaller, the build adds it under `dist/<name>/_internal/`.

## Minimal flags

We intentionally avoid extra knobs. Provide only:
- `--variant external` (default)
- `--embedded-python <path>` (required for external)
- `--disable-libval` (recommended)
- Signing/notary env vars as shown above.
