#!/usr/bin/env bash
set -euo pipefail

# Codesign all Mach-O binaries in a folder (or .app) and optionally notarize.
#
# Usage:
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   scripts/sign_and_notarize.sh <target-folder-or-app> [--notarize] [--zip <out.zip>] [--entitlements <plist>]
#
# Optional env:
#   KEYCHAIN_PROFILE=AC_PROFILE   # notarytool keychain profile (xcrun notarytool store-credentials ...)
#
# Notes:
# - For local dev only, you can ad-hoc sign with SIGN_ID="-" (won't pass Gatekeeper on other Macs).
# - For proper distribution, use a real Developer ID Application cert and --notarize.

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "ERROR: missing target (folder or .app)" >&2; exit 1; }
shift || true

NOTARIZE=0
ZIP_OUT=""
ENTITLEMENTS=""
RUNTIME=1
DISABLE_LIBVAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) NOTARIZE=1; shift;;
    --zip) ZIP_OUT="${2:-}"; shift 2;;
    --entitlements) ENTITLEMENTS="${2:-}"; shift 2;;
    --no-runtime) RUNTIME=0; shift;;
    --disable-library-validation|--disable-libval) DISABLE_LIBVAL=1; shift;;
    *) echo "Unknown flag: $1" >&2; exit 1;;
  esac
done

[[ -n "${SIGN_ID:-}" ]] || { echo "ERROR: set SIGN_ID to your 'Developer ID Application: … (TEAMID)' or '-' for ad-hoc" >&2; exit 1; }

if [[ ! -e "$TARGET" ]]; then
  echo "ERROR: target not found: $TARGET" >&2
  exit 1
fi

echo "[sign] Clearing quarantine (dev convenience)"
xattr -dr com.apple.quarantine "$TARGET" || true

codesign_file() {
  local f="$1"
  if file -b "$f" | grep -Eq 'Mach-O|universal binary'; then
    local args=(--force --timestamp --sign "$SIGN_ID")
    if [[ "$RUNTIME" == "1" ]]; then
      args+=(--options runtime)
    fi
    if [[ -n "$ENTITLEMENTS" ]]; then
      args+=(--entitlements "$ENTITLEMENTS")
    fi
    codesign "${args[@]}" "$f" 2>/dev/null || {
      echo "[warn] codesign failed for $f; retrying verbose" >&2
      codesign "${args[@]}" --verbose "$f"
    }
  fi
}

if [[ "$DISABLE_LIBVAL" == "1" && -z "$ENTITLEMENTS" ]]; then
  echo "[sign] Creating temporary entitlements with disable-library-validation"
  ENT_TMP="$(mktemp)"
  cat > "$ENT_TMP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
  </dict>
  </plist>
PLIST
  ENTITLEMENTS="$ENT_TMP"
  # Hardened runtime generally required when using this entitlement
  RUNTIME=1
fi

echo "[sign] Walking files under: $TARGET"
if [[ -d "$TARGET" ]]; then
  while IFS= read -r -d '' f; do
    codesign_file "$f"
  done < <(find "$TARGET" -type f -print0)
else
  codesign_file "$TARGET"
fi

# If an .app, sign the bundle itself (deep)
if [[ "$TARGET" == *.app ]]; then
  echo "[sign] Deep-signing app bundle"
  args=(--force --timestamp --sign "$SIGN_ID" --deep)
  if [[ "$RUNTIME" == "1" ]]; then
    args+=(--options runtime)
  fi
  [[ -n "$ENTITLEMENTS" ]] && args+=(--entitlements "$ENTITLEMENTS")
  codesign "${args[@]}" "$TARGET"
fi

echo "[verify] Sample verification"
spctl -a -t exec -vv "$TARGET" || true

if [[ "$NOTARIZE" == "1" ]]; then
  ZIP_OUT=${ZIP_OUT:-"$(basename "$TARGET").zip"}
  echo "[zip] Creating: $ZIP_OUT"
  ditto -c -k --keepParent "$TARGET" "$ZIP_OUT"
  echo "[notary] Submitting to Apple Notary Service"
  if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
    echo "        using keychain profile: $KEYCHAIN_PROFILE"
    xcrun notarytool submit "$ZIP_OUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  else
    [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] || {
      echo "ERROR: provide KEYCHAIN_PROFILE or APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD" >&2; exit 1; }
    xcrun notarytool submit "$ZIP_OUT" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --wait
  fi
  # Staple if it's an .app
  if [[ "$TARGET" == *.app ]]; then
    echo "[staple] Stapling ticket to app"
    xcrun stapler staple "$TARGET" || true
  fi
  echo "[done] Notarization complete"
fi

echo "[done] Codesigning finished"
