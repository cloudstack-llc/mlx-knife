#!/usr/bin/env bash
set -euo pipefail

# All-in-one release script: build (external or pyinstaller), sign, package, and notarize.
#
# Usage examples:
#   VERSION=2.0.0bp6 \
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   APPLE_ID="you@apple.com" APPLE_TEAM_ID="TEAMID" APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#   scripts/release.sh --variant external --embedded-python /path/to/Resources/python/bin/python3
#
#   # With custom wheels and custom name
#   VERSION=2.0.0bp6 BIN_NAME=my-cli \
#   SIGN_ID="$CSC_NAME" APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_SPECIFIC_PASSWORD=... \
#   scripts/release.sh --variant pyinstaller --mlx-wheel scripts/mlx-custom.whl --mlx-lm-wheel scripts/mlx-lm-custom.whl
#
# Flags:
#   --variant external|pyinstaller   (default: external)
#   --embedded-python <path>         (required for external variant)
#   --mlx-wheel <path>               override MLX wheel
#   --mlx-lm-wheel <path>            override MLX-LM wheel
#   --skip-notarize                  sign only; do not notarize
#   --entitlements <plist>           optional entitlements for signing
#   --disable-libval                 add disable-library-validation entitlement
#
# Env:
#   VERSION, BIN_NAME                version stamp and output name
#   MLX_WHEEL, MLX_LM_WHEEL         alternative to flags
#   SIGN_ID or CSC_NAME              codesign identity (Developer ID Application: … (TEAMID))
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD   for notarytool
#

VARIANT=external
EMBED_PY=""
MLX_WHEEL_ARG=""
MLX_LM_WHEEL_ARG=""
SKIP_NOTARIZE=0
ENTITLEMENTS=""
DISABLE_LIBVAL=1
CPYTHON_URL_ARG=""
CPYTHON_DIR_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="${2:-}"; shift 2;;
    --embedded-python) EMBED_PY="${2:-}"; shift 2;;
    --cpython-url) CPYTHON_URL_ARG="${2:-}"; shift 2;;
    --cpython-dir) CPYTHON_DIR_ARG="${2:-}"; shift 2;;
    --mlx-wheel) MLX_WHEEL_ARG="${2:-}"; shift 2;;
    --mlx-lm-wheel) MLX_LM_WHEEL_ARG="${2:-}"; shift 2;;
    --skip-notarize) SKIP_NOTARIZE=1; shift;;
    --entitlements) ENTITLEMENTS="${2:-}"; shift 2;;
    --disable-libval) DISABLE_LIBVAL=1; shift;;
    --no-disable-libval) DISABLE_LIBVAL=0; shift;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Determine version: prefer env VERSION, otherwise package.json:version
if [[ -z "${VERSION:-}" ]]; then
  PKG_VER="$(python3 - <<'PY' 2>/dev/null || true
import json, sys
try:
    with open('package.json') as f:
        print(json.load(f).get('version',''))
except Exception:
    print('')
PY
)"
  if [[ -n "$PKG_VER" ]]; then
    export VERSION="$PKG_VER"
    echo "[version] Using package.json version: $VERSION"
  fi
fi

APP_NAME="${BIN_NAME:-${APP_NAME:-msty-mlx-studio}}"
ART_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ART_DIR"

# Determine signing identity early (used for pre-signing embedded Python)
SIGN_ID_EFFECTIVE="${SIGN_ID:-${CSC_NAME:-}}"

ENV_ASSIGN=()
if [[ -n "${VERSION:-}" ]]; then ENV_ASSIGN+=(VERSION="$VERSION"); fi
ENV_ASSIGN+=(BIN_NAME="$APP_NAME")
if [[ -n "$MLX_WHEEL_ARG" ]]; then ENV_ASSIGN+=(MLX_WHEEL="$MLX_WHEEL_ARG"); fi
if [[ -n "${MLX_WHEEL:-}" ]]; then ENV_ASSIGN+=(MLX_WHEEL="$MLX_WHEEL"); fi
if [[ -n "$MLX_LM_WHEEL_ARG" ]]; then ENV_ASSIGN+=(MLX_LM_WHEEL="$MLX_LM_WHEEL_ARG"); fi
if [[ -n "${MLX_LM_WHEEL:-}" ]]; then ENV_ASSIGN+=(MLX_LM_WHEEL="$MLX_LM_WHEEL"); fi

case "$VARIANT" in
  external)
    # Resolve CPython source if not explicitly provided
    CPYTHON_URL="${CPYTHON_URL_ARG:-${CPYTHON_URL:-}}"
    CPYTHON_DIR="${CPYTHON_DIR_ARG:-${CPYTHON_DIR:-${ROOT_DIR}/python}}"

    if [[ -z "$EMBED_PY" ]]; then
      if [[ -n "$CPYTHON_URL" ]]; then
        echo "[fetch] Downloading CPython from: $CPYTHON_URL"
        TMP_TAR="$(mktemp -t cpython-XXXXXX).tar.gz"
        curl -L "$CPYTHON_URL" -o "$TMP_TAR"
        mkdir -p "$CPYTHON_DIR"
        # Extract; detect if payload contains a top-level 'python' folder
        TAR_TOP="$(tar -tzf "$TMP_TAR" | head -n1 | cut -d/ -f1)"
        tar -xzf "$TMP_TAR" -C "$CPYTHON_DIR" --strip-components=0
        rm -f "$TMP_TAR"
        # Common layouts: either extracted files under CPYTHON_DIR directly or nested python/*
        if [[ -x "$CPYTHON_DIR/bin/python3" ]]; then
          EMBED_PY="$CPYTHON_DIR/bin/python3"
        elif [[ -x "$CPYTHON_DIR/python/bin/python3" ]]; then
          EMBED_PY="$CPYTHON_DIR/python/bin/python3"
        else
          # Try to find any python3 in subtree
          EMBED_PY="$(find "$CPYTHON_DIR" -type f -path '*/bin/python3*' -perm -111 -print -quit 2>/dev/null || true)"
        fi
        [[ -n "$EMBED_PY" ]] || { echo "ERROR: Unable to find python3 in extracted CPython at $CPYTHON_DIR" >&2; exit 1; }
        echo "[fetch] Embedded Python resolved to: $EMBED_PY"
      elif [[ -x "$ROOT_DIR/python/bin/python3" ]]; then
        EMBED_PY="$ROOT_DIR/python/bin/python3"
      fi
    fi

    [[ -n "$EMBED_PY" ]] || { echo "ERROR: Embedded Python not found. Provide --embedded-python or CPYTHON_URL/CPYTHON_DIR or place it at ./python/bin/python3" >&2; exit 1; }
    echo "[build] External-Python variant"
    # Pre-sign embedded Python so we can execute it during build (and clear quarantine)
    PYSRC_DIR="$(cd "$(dirname "$EMBED_PY")/.." && pwd)"
    if [[ -d "$PYSRC_DIR" ]]; then
      echo "[prep] Clearing quarantine and signing embedded Python at: $PYSRC_DIR"
      dos2unix scripts/* || true
      scripts/clear_quarantine_python.sh "$PYSRC_DIR" || true
      PRE_SIGN_ARGS=("$PYSRC_DIR")
      if [[ "$DISABLE_LIBVAL" == "1" ]]; then PRE_SIGN_ARGS+=(--disable-libval); fi
      if [[ -n "$ENTITLEMENTS" ]]; then PRE_SIGN_ARGS+=(--entitlements "$ENTITLEMENTS"); fi
      if [[ -n "$SIGN_ID_EFFECTIVE" ]]; then SIGN_ID="$SIGN_ID_EFFECTIVE" scripts/sign_and_notarize.sh "${PRE_SIGN_ARGS[@]}"; else echo "[prep] SIGN_ID not set; skipping pre-sign (may still run locally if quarantine is clear)"; fi
    fi
    # Always clean external bundle output for release builds
    env "${ENV_ASSIGN[@]}" EMBEDDED_PYTHON="$EMBED_PY" CLEAN=1 SKIP_TAR=1 scripts/build_external_python.sh
    BUNDLE_DIR="$ROOT_DIR/dist-ext-python/$APP_NAME"

    # Include the embedded Python inside the bundle so the launcher can auto-resolve SELF_DIR/python/bin/python3
    if [[ -d "$PYSRC_DIR" ]]; then
      echo "[bundle] Embedding Python into bundle at: $BUNDLE_DIR/python"
      rsync -a --delete "$PYSRC_DIR/" "$BUNDLE_DIR/python/"
    fi

    # Replace shell launcher with a tiny Mach-O wrapper so the process name shows as "$APP_NAME"
    echo "[bundle] Building native launcher to keep process name as $APP_NAME"
    cat > "$BUNDLE_DIR/.launcher.c" <<'C'
#include <spawn.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <signal.h>
extern char **environ;

static volatile sig_atomic_t got_sig = 0;
static volatile pid_t child_pid = -1;

static void dirname_of(const char *path, char *out, size_t outsz) {
    strncpy(out, path, outsz - 1); out[outsz-1] = '\0';
    char *d = dirname(out);
    if (d != out) strncpy(out, d, outsz - 1);
}

static void handle_signal(int sig) {
    got_sig++;
    pid_t pid = child_pid;
    if (pid > 0) {
        if (got_sig == 1) kill(pid, sig == SIGINT ? SIGINT : SIGTERM);
        else kill(pid, SIGKILL);
    }
}

int main(int argc, char *argv[]) {
    // Resolve executable path
    char execPath[PATH_MAX]; uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) != 0) return 127;
    char bundleRoot[PATH_MAX]; dirname_of(execPath, bundleRoot, sizeof(bundleRoot));

    // Construct embedded python and vendor paths
    char pyPath[PATH_MAX]; snprintf(pyPath, sizeof(pyPath), "%s/python/bin/python3", bundleRoot);
    char vendorPath[PATH_MAX]; snprintf(vendorPath, sizeof(vendorPath), "%s/_vendor", bundleRoot);

    // Prepare environment
    setenv("MLXK_PYTHON", pyPath, 1);
    setenv("RESOURCES_PATH", bundleRoot, 1);
    setenv("PYTHONNOUSERSITE", "1", 0);
    // Disable supervised uvicorn subprocess; run server in-process
    setenv("MLXK2_SUPERVISE", "0", 1);
    // Ensure any `python3` shebang or /usr/bin/env python3 resolves to embedded one
    const char *old_path = getenv("PATH");
    size_t newlen = strlen(bundleRoot) + strlen("/python/bin") + 1 + (old_path ? strlen(old_path) : 0) + 1;
    char *newpath = (char*)malloc(newlen);
    if (newpath) {
        if (old_path && *old_path)
            snprintf(newpath, newlen, "%s/python/bin:%s", bundleRoot, old_path);
        else
            snprintf(newpath, newlen, "%s/python/bin", bundleRoot);
        setenv("PATH", newpath, 1);
        free(newpath);
    }
    // Help Python find its stdlib explicitly
    char pyHome[PATH_MAX]; snprintf(pyHome, sizeof(pyHome), "%s/python", bundleRoot);
    setenv("PYTHONHOME", pyHome, 1);
    setenv("PYTHONEXECUTABLE", pyPath, 1);
    // Prepend vendor to PYTHONPATH
    const char *pp = getenv("PYTHONPATH");
    if (pp && *pp) {
        size_t len = strlen(vendorPath) + 1 + strlen(pp) + 1;
        char *buf = (char*)malloc(len);
        if (!buf) return 127;
        snprintf(buf, len, "%s:%s", vendorPath, pp);
        setenv("PYTHONPATH", buf, 1);
        free(buf);
    } else {
        setenv("PYTHONPATH", vendorPath, 1);
    }

    // Build argv for python: python -m mlxk2.cli [args...]
    int n = argc + 3; // python, -m, module, args...
    char **pargv = (char**)calloc(n + 1, sizeof(char*));
    if (!pargv) return 127;
    pargv[0] = pyPath;
    pargv[1] = "-m";
    pargv[2] = "mlxk2.cli";
    for (int i = 1; i < argc; ++i) pargv[2 + i] = argv[i];
    pargv[n] = NULL;

    // Install signal handlers to forward to child
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal; sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    // Spawn python child; keep this process name as launcher
    pid_t pid; int rc = posix_spawn(&pid, pyPath, NULL, NULL, pargv, environ);
    if (rc != 0) return rc;
    child_pid = pid;

    // Wait and propagate exit
    int status = 0; while (1) {
        pid_t w = waitpid(pid, &status, 0);
        if (w == -1) continue; // interrupted by signal
        break;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 0;
}
C
    clang -O2 -Wall -mmacosx-version-min=11 -o "$BUNDLE_DIR/.launcher" "$BUNDLE_DIR/.launcher.c"
    mv -f "$BUNDLE_DIR/.launcher" "$BUNDLE_DIR/$APP_NAME"
    rm -f "$BUNDLE_DIR/.launcher.c"
    ;;
  pyinstaller)
    echo "[build] PyInstaller variant"
    # Clean old bundle output to avoid stale files across releases
    rm -rf "$ROOT_DIR/dist/$APP_NAME" "$ROOT_DIR/build/$APP_NAME"
    env "${ENV_ASSIGN[@]}" scripts/build.sh
    BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME"
    ;;
  *)
    echo "Unknown variant: $VARIANT" >&2; exit 1;
    ;;
esac

[[ -d "$BUNDLE_DIR" ]] || { echo "ERROR: bundle directory not found: $BUNDLE_DIR" >&2; exit 1; }

# Post-build version report: ensure bundled mlx + mlx-lm satisfy requirements.txt
REQ_FILE="$ROOT_DIR/requirements.txt"
if [[ -f "$REQ_FILE" ]]; then
  echo "[verify] MLX bundle version report"
  python3 - "$BUNDLE_DIR" "$REQ_FILE" <<'PY'
import os
import re
import sys

bundle_dir = sys.argv[1]
req_path = sys.argv[2]
targets = {"mlx", "mlx-lm"}

Requirement = None
try:
    from packaging.requirements import Requirement  # type: ignore
except Exception:
    try:
        from pip._vendor.packaging.requirements import Requirement  # type: ignore
    except Exception:
        Requirement = None


def find_metadata(root: str):
    for dirpath, _, filenames in os.walk(root):
        if "METADATA" in filenames:
            yield os.path.join(dirpath, "METADATA")


def parse_metadata(path: str):
    name = None
    version = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("Name:"):
                    name = line.split(":", 1)[1].strip()
                elif line.startswith("Version:"):
                    version = line.split(":", 1)[1].strip()
                if name and version:
                    break
    except Exception:
        return None, None
    return name, version


search_root = os.path.join(bundle_dir, "_vendor")
roots = [search_root] if os.path.isdir(search_root) else [bundle_dir]

found = {}
duplicates = {}
for root in roots:
    for meta in find_metadata(root):
        name, version = parse_metadata(meta)
        if not name or not version:
            continue
        key = name.lower()
        if key not in targets:
            continue
        if key in found and found[key]["version"] != version:
            duplicates.setdefault(key, []).append({"version": version, "metadata": meta})
        else:
            found.setdefault(key, {"version": version, "metadata": meta})


def parse_requirements(path: str):
    reqs = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith(("-r", "--")):
                continue
            if Requirement is not None:
                try:
                    req = Requirement(line)
                except Exception:
                    continue
                name = req.name.lower()
                if name in targets:
                    if req.marker is not None and not req.marker.evaluate():
                        continue
                    reqs[name] = {"raw": line, "specifier": req.specifier}
            else:
                match = re.match(r"([A-Za-z0-9_.-]+)(.*)", line)
                if not match:
                    continue
                name = match.group(1).lower()
                if name in targets:
                    reqs[name] = {"raw": line, "specifier": match.group(2).strip()}
    return reqs


def simple_satisfies(version: str, spec) -> bool | None:
    spec_str = str(spec or "").strip()
    if not spec_str:
        return None
    match = re.match(r"(==|>=|<=|<|>)(.+)", spec_str)
    if not match:
        return None
    op = match.group(1)
    req_ver = match.group(2).strip()

    def split_nums(v: str):
        parts = []
        for part in re.split(r"[.+-]", v):
            if part.isdigit():
                parts.append(int(part))
            else:
                break
        return parts

    a = split_nums(version)
    b = split_nums(req_ver)
    if not a or not b:
        return None
    n = max(len(a), len(b))
    a += [0] * (n - len(a))
    b += [0] * (n - len(b))
    if a < b:
        cmp = -1
    elif a > b:
        cmp = 1
    else:
        cmp = 0
    if op == "==":
        return cmp == 0
    if op == ">=":
        return cmp >= 0
    if op == "<=":
        return cmp <= 0
    if op == ">":
        return cmp > 0
    if op == "<":
        return cmp < 0
    return None


reqs = parse_requirements(req_path)
errors = []
notes = []

root_label = roots[0]
print(f"  source: {root_label}")
for name in sorted(targets):
    inst = found.get(name)
    req = reqs.get(name)
    inst_ver = inst["version"] if inst else "MISSING"
    req_spec = str(req["specifier"]) if req else "MISSING"
    print(f"  - {name}: {inst_ver} (requirement: {req_spec})")
    if not inst:
        errors.append(f"{name} not found in bundle (searched {root_label})")
        continue
    if req and req.get("specifier"):
        ok = None
        if Requirement is not None:
            try:
                ok = req["specifier"].contains(inst["version"], prereleases=True)
            except Exception:
                ok = None
        if ok is None:
            ok = simple_satisfies(inst["version"], req["specifier"])
        if ok is False:
            errors.append(f"{name} {inst['version']} does not satisfy '{req_spec}'")
        elif ok is None:
            notes.append(f"{name}: unable to verify requirement '{req_spec}' (no packaging)")

if duplicates:
    for name, dups in duplicates.items():
        versions = ", ".join(sorted({d["version"] for d in dups}))
        errors.append(f"{name} multiple versions found: {versions}")

for note in notes:
    print(f"  note: {note}")

if errors:
    for err in errors:
        print(f"  error: {err}")
    sys.exit(1)
PY
else
  echo "[verify] requirements.txt not found; skipping MLX version report"
fi

SIGN_ID_EFFECTIVE="${SIGN_ID:-${CSC_NAME:-}}"
[[ -n "$SIGN_ID_EFFECTIVE" ]] || { echo "ERROR: set SIGN_ID or CSC_NAME to your codesigning identity" >&2; exit 1; }

SIGN_ARGS=("$BUNDLE_DIR")
if [[ -n "$ENTITLEMENTS" ]]; then SIGN_ARGS+=(--entitlements "$ENTITLEMENTS"); fi
if [[ "$DISABLE_LIBVAL" == "1" ]]; then SIGN_ARGS+=(--disable-libval); fi

echo "[sign] Codesigning bundle with: $SIGN_ID_EFFECTIVE"
SIGN_ID="$SIGN_ID_EFFECTIVE" scripts/sign_and_notarize.sh "${SIGN_ARGS[@]}"

TGZ_NAME_BASE="$APP_NAME"; [[ -n "${VERSION:-}" ]] && TGZ_NAME_BASE+="-${VERSION}"
TGZ_PATH="$ART_DIR/${TGZ_NAME_BASE}.tgz"

# Notarize using a temporary zip (Apple Notary Service prefers zip input).
if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  TMP_ZIP="$(mktemp -t ${APP_NAME}-notary-XXXXXX).zip"
  echo "[notary] Submitting for notarization via temporary zip"
  SIGN_ID="$SIGN_ID_EFFECTIVE" \
  APPLE_ID="${APPLE_ID:-}" APPLE_TEAM_ID="${APPLE_TEAM_ID:-}" APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}" \
  scripts/sign_and_notarize.sh "$BUNDLE_DIR" --notarize --zip "$TMP_ZIP"
  rm -f "$TMP_ZIP" || true
fi

# Always produce TGZ for distribution
echo "[package] Creating tgz: $TGZ_PATH"
tar -C "$(dirname "$BUNDLE_DIR")" -czf "$TGZ_PATH" "$APP_NAME"

echo "[done] Release ready"
echo "- Bundle: $BUNDLE_DIR"
echo "- TGZ:    $TGZ_PATH"
