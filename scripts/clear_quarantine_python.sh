#!/usr/bin/env bash
set -euo pipefail

# Recursively remove macOS Gatekeeper quarantine from an embedded Python folder
# and verify any leftovers (executables, .dylib, .so, etc.).
#
# Usage:
#   scripts/clear_quarantine_python.sh /path/to/MyApp.app/Contents/Resources/python
#   # or, if your repo has ./python
#   scripts/clear_quarantine_python.sh
#

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 [python_folder]"
  echo "Example: $0 /Applications/MyApp.app/Contents/Resources/python"
  exit 0
fi

PY_DIR="${1:-}"
if [[ -z "$PY_DIR" ]]; then
  if [[ -d "python" ]]; then
    PY_DIR="python"
  else
    echo "ERROR: No python folder provided and ./python not found." >&2
    echo "Provide the path to your embedded Python folder." >&2
    exit 1
  fi
fi

if [[ ! -d "$PY_DIR" ]]; then
  echo "ERROR: Not a directory: $PY_DIR" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "WARNING: This script is intended for macOS (Darwin). Proceeding anyway..." >&2
fi

echo "Target python folder: $PY_DIR"

echo "Scanning for quarantined items before..."
before_list=$(mktemp)
find "$PY_DIR" -type f -print0 \
  | xargs -0 -I{} sh -c 'xattr -p com.apple.quarantine "$1" >/dev/null 2>&1 && printf "%s\n" "$1"' -- {} \
  | tee "$before_list" >/dev/null || true
before_count=$(wc -l < "$before_list" | tr -d ' ')
echo "Quarantined files found: ${before_count}"

echo "Clearing quarantine recursively..."
xattr -dr com.apple.quarantine "$PY_DIR" || true

echo "Re-scanning for leftovers..."
after_list=$(mktemp)
find "$PY_DIR" -type f -print0 \
  | xargs -0 -I{} sh -c 'xattr -p com.apple.quarantine "$1" >/dev/null 2>&1 && printf "%s\n" "$1"' -- {} \
  | tee "$after_list" >/dev/null || true
after_count=$(wc -l < "$after_list" | tr -d ' ')

if [[ "$after_count" -eq 0 ]]; then
  echo "Success: no quarantined files remain under $PY_DIR."
else
  echo "WARNING: ${after_count} quarantined files remain (showing up to 20):"
  head -n 20 "$after_list"
  echo "You may need elevated permissions or to remove quarantine on parent folders."
fi

rm -f "$before_list" "$after_list"

