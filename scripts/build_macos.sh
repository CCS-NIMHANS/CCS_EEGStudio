#!/usr/bin/env bash
# build_macos.sh — Local macOS release build for CCS EEG Studio.
#
# Run from the repository root (or any directory; the script is self-relocating):
#   ./scripts/build_macos.sh
#
# What it does:
#   1. Compiles the Rust engine (bridge/src/main.rs → ccs-eeg-engine binary).
#   2. Builds the Flutter macOS app in release mode.
#   3. Copies ccs-eeg-engine into the .app bundle's MacOS directory so that
#      the Flutter ExtractionService can locate and launch it at runtime.
#   4. Removes any stale tools/ directory from the bundle Resources folder.
#   5. Signs the bundle with a Developer ID Application identity (and optionally
#      notarizes) via scripts/sign_and_notarize_macos.sh when available; otherwise
#      falls back to ad-hoc signing (`codesign --sign -`).
#
# Output: build/macos/Build/Products/Release/CCS EEG Studio.app
set -euo pipefail

# ── Locate repository root ─────────────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Locate cargo (supports ~/.cargo/bin path) ─────────────────────────────
CARGO_BIN="$(command -v cargo 2>/dev/null || true)"
if [[ -z "$CARGO_BIN" && -x "$HOME/.cargo/bin/cargo" ]]; then
  CARGO_BIN="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$CARGO_BIN" ]]; then
  echo "Error: cargo was not found. Install Rust via https://rustup.rs" >&2
  exit 1
fi

# ── Build Rust engine (universal arm64 + x86_64) ───────────────────────────
echo "==> Building Rust engine (release, arm64 + x86_64)..."
RUSTUP_BIN="$(command -v rustup 2>/dev/null || true)"
if [[ -z "$RUSTUP_BIN" && -x "$HOME/.cargo/bin/rustup" ]]; then
  RUSTUP_BIN="$HOME/.cargo/bin/rustup"
fi
if [[ -n "$RUSTUP_BIN" ]]; then
  "$RUSTUP_BIN" target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null || true
fi
cd "$ROOT/bridge"
MACOSX_DEPLOYMENT_TARGET=12.0 "$CARGO_BIN" build --release --locked --target aarch64-apple-darwin
MACOSX_DEPLOYMENT_TARGET=12.0 "$CARGO_BIN" build --release --locked --target x86_64-apple-darwin
mkdir -p "$ROOT/bridge/target/release"
lipo -create \
  "$ROOT/bridge/target/aarch64-apple-darwin/release/ccs-eeg-engine" \
  "$ROOT/bridge/target/x86_64-apple-darwin/release/ccs-eeg-engine" \
  -output "$ROOT/bridge/target/release/ccs-eeg-engine"
lipo -info "$ROOT/bridge/target/release/ccs-eeg-engine"
echo "    Engine: bridge/target/release/ccs-eeg-engine"

# ── Build Flutter macOS app ────────────────────────────────────────────────
echo "==> Building Flutter macOS app (release)..."
cd "$ROOT"
flutter build macos --release

APP="$ROOT/build/macos/Build/Products/Release/CCS EEG Studio.app"
if [[ ! -d "$APP" ]]; then
  echo "Error: Expected .app bundle not found at $APP" >&2
  exit 1
fi

# ── Embed the Rust engine inside the .app bundle ──────────────────────────
echo "==> Copying ccs-eeg-engine into .app bundle..."
cp "$ROOT/bridge/target/release/ccs-eeg-engine" "$APP/Contents/MacOS/ccs-eeg-engine"
chmod +x "$APP/Contents/MacOS/ccs-eeg-engine"

# Remove stale developer tools directory if it crept in from a previous run.
rm -rf "$APP/Contents/Resources/tools"

# ── Code sign (Developer ID if available, else ad-hoc fallback) ────────────
DEVID_DETECTED="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m 1 'Developer ID Application:' || true)"

if [[ -n "${MACOS_SIGN_IDENTITY:-}" || -n "$DEVID_DETECTED" ]]; then
  echo "==> Signing bundle with Developer ID..."
  APP_PATH="$APP" OUT_DIR="$ROOT/dist" bash "$ROOT/scripts/sign_and_notarize_macos.sh"
  echo ""
  echo "✅  Built & Developer ID signed: $APP"
else
  echo "==> Ad-hoc signing bundle..."
  codesign --force --deep --sign - "$APP"
  echo ""
  echo "✅  Built (ad-hoc signed): $APP"
  echo ""
  echo "To clear Gatekeeper quarantine after distributing:"
  echo "    xattr -rd com.apple.quarantine ~/Downloads/CCS\\ EEG\\ Studio.app"
fi
