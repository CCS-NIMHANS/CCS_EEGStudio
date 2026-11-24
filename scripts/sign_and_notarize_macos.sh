#!/usr/bin/env bash
# sign_and_notarize_macos.sh — Developer ID signing, Hardened Runtime,
# Apple Notarization, and stapled .zip / .dmg packaging for CCS EEG Studio.
#
# Supports CI (ephemeral keychain + App Store Connect API key) and local release
# builds, with safe ad-hoc fallback when no Developer ID identity is available.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT/build/macos/Build/Products/Release/CCS EEG Studio.app}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/macos/Runner/Release.entitlements}"
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-Y445J7MR4Q}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --entitlements) ENTITLEMENTS="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--app <path>] [--out-dir <dir>] [--entitlements <plist>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: App bundle not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

TEMP_KEYCHAIN=""
TEMP_DIR=""
ORIG_KEYCHAINS=()

cleanup() {
  if [[ -n "$TEMP_KEYCHAIN" ]]; then
    if [[ ${#ORIG_KEYCHAINS[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}" 2>/dev/null || true
    fi
    security delete-keychain "$TEMP_KEYCHAIN" 2>/dev/null || true
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

# ── Optional CI certificate import into temporary keychain ─────────────────
if [[ -n "${MACOS_CERT_P12_BASE64:-}" ]]; then
  if [[ -z "${MACOS_CERT_PASSWORD:-}" ]]; then
    echo "Error: MACOS_CERT_PASSWORD must be set when MACOS_CERT_P12_BASE64 is provided." >&2
    exit 1
  fi
  TEMP_DIR="$(mktemp -d)"
  P12_FILE="$TEMP_DIR/devid.p12"
  KEYCHAIN_PASS="$(openssl rand -hex 16)"
  TEMP_KEYCHAIN="$TEMP_DIR/signing.keychain-db"

  printf '%s' "$MACOS_CERT_P12_BASE64" | tr -d '[:space:]' | base64 --decode > "$P12_FILE"

  while IFS= read -r kc; do
    kc="${kc//\"/}"
    kc="${kc#"${kc%%[![:space:]]*}"}"
    kc="${kc%"${kc##*[![:space:]]}"}"
    [[ -n "$kc" ]] && ORIG_KEYCHAINS+=("$kc")
  done < <(security list-keychains -d user)

  security create-keychain -p "$KEYCHAIN_PASS" "$TEMP_KEYCHAIN"
  security set-keychain-settings -lut 21600 "$TEMP_KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$TEMP_KEYCHAIN"
  security import "$P12_FILE" \
    -P "$MACOS_CERT_PASSWORD" \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -t cert \
    -f pkcs12 \
    -k "$TEMP_KEYCHAIN"
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASS" \
    "$TEMP_KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$TEMP_KEYCHAIN" "${ORIG_KEYCHAINS[@]}"
  rm -f "$P12_FILE"
fi

# ── Resolve Developer ID Application identity ──────────────────────────────
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n 1 || true)"
fi

ZIP_OUT="$OUT_DIR/CCSEEGStudio-macos.zip"
DMG_OUT="$OUT_DIR/CCSEEGStudio-macos.dmg"

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "==> No Developer ID Application identity found; falling back to ad-hoc signing..."
  codesign --force --deep --sign - "$APP_PATH"
  rm -f "$ZIP_OUT"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_OUT"
  echo "    Ad-hoc ZIP created: $ZIP_OUT"
  exit 0
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Error: Entitlements file not found at $ENTITLEMENTS" >&2
  exit 1
fi

echo "==> Signing macOS bundle inside-out with: $SIGN_IDENTITY"

# 1. Sign nested dynamic libraries and shared objects.
for subdir in "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/PlugIns"; do
  if [[ -d "$subdir" ]]; then
    while IFS= read -r -d '' bin; do
      codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$bin"
    done < <(find "$subdir" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)
  fi
done

# 2. Sign nested frameworks / XPC services / embedded app helpers.
for subdir in "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/PlugIns"; do
  if [[ -d "$subdir" ]]; then
    while IFS= read -r -d '' fw; do
      codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$fw"
    done < <(find "$subdir" -maxdepth 2 \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) -print0)
  fi
done

# 3. Sign embedded Rust engine executable.
if [[ -f "$APP_PATH/Contents/MacOS/ccs-eeg-engine" ]]; then
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    "$APP_PATH/Contents/MacOS/ccs-eeg-engine"
fi

# 4. Sign the outer .app bundle with Hardened Runtime entitlements.
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP_PATH"

echo "==> Verifying Developer ID signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -f "$ZIP_OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_OUT"
echo "    Signed ZIP created: $ZIP_OUT"

# ── Determine notarization credentials (3 supported modes) ─────────────────
NOTARY_ARGS=()
if [[ -n "${MACOS_NOTARY_KEY_BASE64:-}" || -n "${MACOS_NOTARY_KEY_PATH:-}" ]]; then
  if [[ -z "${MACOS_NOTARY_KEY_ID:-}" || -z "${MACOS_NOTARY_ISSUER_ID:-}" ]]; then
    echo "Error: MACOS_NOTARY_KEY_ID and MACOS_NOTARY_ISSUER_ID are required for API key notarization." >&2
    exit 1
  fi
  if [[ -n "${MACOS_NOTARY_KEY_PATH:-}" ]]; then
    NOTARY_KEY_FILE="$MACOS_NOTARY_KEY_PATH"
  else
    [[ -n "$TEMP_DIR" ]] || TEMP_DIR="$(mktemp -d)"
    NOTARY_KEY_FILE="$TEMP_DIR/AuthKey_${MACOS_NOTARY_KEY_ID}.p8"
    printf '%s' "$MACOS_NOTARY_KEY_BASE64" | tr -d '[:space:]' | base64 --decode > "$NOTARY_KEY_FILE"
    chmod 600 "$NOTARY_KEY_FILE"
  fi
  NOTARY_ARGS=(
    --key "$NOTARY_KEY_FILE"
    --key-id "$MACOS_NOTARY_KEY_ID"
    --issuer "$MACOS_NOTARY_ISSUER_ID"
  )
elif [[ -n "${MACOS_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$MACOS_NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(
    --apple-id "$APPLE_ID"
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
    --team-id "$APPLE_TEAM_ID"
  )
fi

if [[ ${#NOTARY_ARGS[@]} -eq 0 ]]; then
  echo "==> No notarization credentials provided; skipping Apple notarization and DMG creation."
  exit 0
fi

# ── Build, sign, and notarize drag-to-Applications .dmg once (covers .app + .dmg) ─
echo "==> Creating drag-to-Applications DMG..."
[[ -n "$TEMP_DIR" ]] || TEMP_DIR="$(mktemp -d)"
DMG_STAGE="$TEMP_DIR/dmg-stage"
mkdir -p "$DMG_STAGE"
ditto "$APP_PATH" "$DMG_STAGE/CCS EEG Studio.app"
ln -s /Applications "$DMG_STAGE/Applications"

rm -f "$DMG_OUT"
hdiutil create \
  -volname "CCS EEG Studio" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG_OUT"

codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_OUT"

echo "==> Submitting DMG for Apple Notarization (single submission for .dmg & .app)..."
xcrun notarytool submit "$DMG_OUT" "${NOTARY_ARGS[@]}" --wait --timeout 45m

echo "==> Stapling notarization tickets to DMG and .app bundle..."
xcrun stapler staple "$DMG_OUT"
xcrun stapler validate "$DMG_OUT"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

rm -f "$ZIP_OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_OUT"
echo "✅  Notarized macOS artifacts ready in $OUT_DIR"
