#!/usr/bin/env bash
# preflight_release.sh — Mandatory Pre-Release CI Gate for CCS EEG Studio.
#
# Runs locally before every push / tag to prevent recurring GitHub Actions
# failures (version drift, missing CHANGELOG release notes, missing Linux
# native shared-library packaging rules, or Rust/Flutter build regressions).
#
# Usage:
#   bash scripts/preflight_release.sh [--allow-workflow-pending] [--skip-tests]
set -euo pipefail

allow_workflow_pending=false
skip_tests=false
for arg in "$@"; do
  case "$arg" in
    --allow-workflow-pending) allow_workflow_pending=true ;;
    --skip-tests) skip_tests=true ;;
    -h|--help)
      echo "Usage: $0 [--allow-workflow-pending] [--skip-tests]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0
warn=0
pass_msg() { echo "  [PASS] $*"; }
warn_msg() { echo "  [WARN] $*"; warn=$((warn + 1)); }
fail_msg() { echo "  [FAIL] $*" >&2; fail=$((fail + 1)); }

echo "======================================================================"
echo " CCS EEG Studio — Pre-Release CI Preflight SOP"
echo "======================================================================"

echo "[1/5] Version metadata & CHANGELOG release-notes sync..."
pubspec_ver="$(awk '/^version:/ {print $2; exit}' pubspec.yaml)"
pubspec_ver="${pubspec_ver%%+*}"
cargo_ver="$(awk -F'"' '/^version = / {print $2; exit}' bridge/Cargo.toml)"
iss_ver="$(awk '/#define AppVersion/ {gsub(/"/, "", $3); print $3; exit}' windows/installer.iss)"

if [[ -n "$pubspec_ver" && "$pubspec_ver" == "$cargo_ver" && "$pubspec_ver" == "$iss_ver" ]]; then
  pass_msg "Versions aligned at $pubspec_ver (pubspec.yaml, bridge/Cargo.toml, windows/installer.iss)"
else
  fail_msg "Version mismatch: pubspec=$pubspec_ver cargo=$cargo_ver iss=$iss_ver"
fi

if bash scripts/release_notes.sh "$pubspec_ver" > /tmp/ccs_preflight_notes.md 2>/dev/null && test -s /tmp/ccs_preflight_notes.md; then
  pass_msg "CHANGELOG.md contains non-empty section ## [$pubspec_ver]"
else
  fail_msg "CHANGELOG.md missing or empty section ## [$pubspec_ver] (CI validate-release will fail)"
fi
rm -f /tmp/ccs_preflight_notes.md

if grep -q "$pubspec_ver" README.md; then
  pass_msg "README.md references current version $pubspec_ver"
else
  warn_msg "README.md does not mention version $pubspec_ver"
fi

echo "[2/5] Linux native plugin & AlmaLinux/Ubuntu runtime dependency parity..."
if grep -q "media_kit" pubspec.yaml; then
  if grep -q "mpv-libs" scripts/package_linux_rpm.sh && grep -q "libmpv.so.1" scripts/package_linux_rpm.sh; then
    pass_msg "scripts/package_linux_rpm.sh declares mpv-libs + libmpv.so.1 compatibility symlink"
  else
    fail_msg "scripts/package_linux_rpm.sh missing mpv-libs or libmpv.so.1 compatibility symlink"
  fi

  if grep -q "libmpv" scripts/package_linux_deb.sh; then
    pass_msg "scripts/package_linux_deb.sh declares libmpv dependency/recommendation + symlink"
  else
    fail_msg "scripts/package_linux_deb.sh missing libmpv runtime dependency"
  fi

  if grep -q "mpv-libs" scripts/install_linux.sh && grep -q "rpmfusion" scripts/install_linux.sh; then
    pass_msg "scripts/install_linux.sh provisions RPMFusion/mpv-libs for EL9"
  else
    fail_msg "scripts/install_linux.sh missing RPMFusion / mpv-libs setup"
  fi

  if grep -q "libmpv-dev" .github/workflows/build.yml; then
    pass_msg ".github/workflows/build.yml includes libmpv-dev build dependency"
  else
    fail_msg ".github/workflows/build.yml missing libmpv-dev"
  fi

  if grep -q "rpmfusion-free-release" .github/workflows/build.yml; then
    pass_msg ".github/workflows/build.yml enables RPMFusion before AlmaLinux 9 RPM test"
  elif [[ "$allow_workflow_pending" == true ]]; then
    warn_msg ".github/workflows/build.yml still needs EPEL + CRB + RPMFusion Free in the AlmaLinux 9 Docker smoke test (apply via GitHub Web UI before tagging $pubspec_ver)"
  else
    fail_msg ".github/workflows/build.yml misses RPMFusion in AlmaLinux 9 smoke test (use --allow-workflow-pending if editing workflow on GitHub Web UI)"
  fi
fi

if grep -q "x86_64-apple-darwin" scripts/sign_and_notarize_macos.sh && grep -q "lipo -create" scripts/sign_and_notarize_macos.sh; then
  pass_msg "scripts/sign_and_notarize_macos.sh enforces universal (x86_64 + arm64) macOS packaging"
else
  fail_msg "scripts/sign_and_notarize_macos.sh missing universal x86_64 + arm64 enforcement"
fi

echo "[3/5] Native Rust engine build & CI test suite (--release --locked)..."
if [[ "$skip_tests" == true ]]; then
  warn_msg "Skipped Rust tests (--skip-tests)"
else
  if (cd bridge && cargo test --release --locked --lib --test erp_workbench_parity --test epoch_preprocessing --test vhdr_calibration) && \
     (cd bridge && cargo test --release --locked --bin ccs-eeg-engine) && \
     (cd bridge && cargo test --release --locked -p ccs_ica --lib) && \
     (cd bridge && cargo test --release --locked -p ccs_algorithm --lib); then
    pass_msg "All Rust engine, binary, ccs_ica, and ccs_algorithm release tests passed (--locked)"
  else
    fail_msg "One or more Rust test targets failed"
  fi
fi

echo "[4/5] Flutter static analysis, Windows path-separator guard & Dart test suite..."
if python3 - <<'PY'
import glob, re, sys
bad = []
assign_slash_re = re.compile(r"""(?:final|var|const|String)\s+(\w+)\s*=\s*['"][^'"]*\$\{[^}]*\.path\}/""")
assign_any_re = re.compile(r"""(?:final|var|const|String)\s+(\w+)\s*=""")
direct_re = re.compile(r"""expect\([^;]*['"][^'"]*\$\{[^}]*\.path\}/""")
for path in sorted(glob.glob("test/**/*.dart", recursive=True)):
    lines = open(path, encoding="utf-8").read().splitlines()
    vars_with_slash = set()
    for idx, line in enumerate(lines, 1):
        m_slash = assign_slash_re.search(line)
        if m_slash:
            vars_with_slash.add(m_slash.group(1))
        else:
            m_any = assign_any_re.search(line)
            if m_any:
                vars_with_slash.discard(m_any.group(1))
        if direct_re.search(line) and "File(" not in line and "Directory(" not in line and "Link(" not in line:
            bad.append(f"{path}:{idx}: {line.strip()}")
        elif "expect(" in line and any(re.search(rf"\bexpect\([^,]+,\s*{re.escape(v)}\b", line) for v in vars_with_slash):
            bad.append(f"{path}:{idx}: {line.strip()} (uses variable with hardcoded '/' after .path)")
if bad:
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
PY
then
  pass_msg "No unportable '/' path-string assertions found in test/ (Windows-safe)"
else
  fail_msg "Found hardcoded '/' after .path in test/ assertion — use \${Platform.pathSeparator} so Windows CI passes"
fi

if flutter analyze --no-fatal-infos; then
  pass_msg "flutter analyze --no-fatal-infos passed cleanly"
else
  fail_msg "flutter analyze reported issues"
fi

if [[ "$skip_tests" == true ]]; then
  warn_msg "Skipped Flutter tests (--skip-tests)"
else
  if flutter test; then
    pass_msg "flutter test passed completely"
  else
    fail_msg "flutter test failed"
  fi
fi

echo "[5/5] Git workflow-scope push guard..."
if git diff --name-only -- .github/workflows/ | grep -q . || git diff --cached --name-only -- .github/workflows/ | grep -q .; then
  warn_msg "Local working tree modifies .github/workflows/ — pushing requires 'workflow' scope (Web UI or repo-only Fine-Grained PAT recommended)"
else
  pass_msg "No unpushable .github/workflows/ changes in local diff"
fi

echo "======================================================================"
echo " Summary: failures=$fail  warnings=$warn"
echo "======================================================================"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
