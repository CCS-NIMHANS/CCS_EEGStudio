# Release & CI Standard Operating Procedure (SOP)

This SOP codifies the mandatory pre-release checks introduced after GitHub Actions runs **#128–#134** to eliminate preventable CI and packaging failures before pushing commits or release tags.

---

## CI Failure Post-Mortem (#128 – #134)

| CI Run(s) | Failing Job | Exact Failure | Root Cause | Automated Prevention Rule |
| :--- | :--- | :--- | :--- | :--- |
| **#128 – #129** (`v1.2.49`) | Linux (`build-linux`) | `PkgConfig::mpv not found` | Added `media_kit_video` to `pubspec.yaml` without adding `libmpv-dev` to Ubuntu build dependencies in `.github/workflows/build.yml`. | Preflight Gate 2 audits `pubspec.yaml` native plugins against Linux workflow deps. |
| **#130 – #132** | `validate-release` (13 s) | `Version mismatch: pubspec=1.2.50 installer=1.2.49 engine=1.2.49` | `pubspec.yaml` bumped ahead of `bridge/Cargo.toml`, `windows/installer.iss`, and `CHANGELOG.md`. | Preflight Gate 1 enforces exact 3-way version sync + `scripts/release_notes.sh` extraction. |
| **#133 – #134** (`v1.2.50`) | Linux (`Validate RPM installer on AlmaLinux 9`) | `libmpv.so.1 => not found` | `scripts/package_linux_rpm.sh` lacked `Recommends: mpv-libs` and `%post` `libmpv.so.2 -> libmpv.so.1` symlink, and AlmaLinux 9 Docker smoke test lacked EPEL + CRB + RPMFusion Free. | Preflight Gate 2 checks RPM/DEB/installer scripts AND AlmaLinux 9 RPMFusion workflow config before tagging. |
| Workflow push block | Local `git push` | Rejected `.github/workflows/` push without `workflow` OAuth scope | Default `gh auth` token lacked `workflow` scope (and OAuth refresh requests broader org access). | Preflight Gate 5 flags workflow edits early; use GitHub Web UI or a repo-scoped PAT (below). |

---

## Mandatory Pre-Release Preflight Command

Run this script from the repository root **before every commit/tag release**:

```bash
bash scripts/preflight_release.sh
```

What it verifies locally in one pass:

1. **Version & Changelog Sync (`validate-release` parity):** `pubspec.yaml`, `bridge/Cargo.toml`, `windows/installer.iss`, `README.md`, and `bash scripts/release_notes.sh "$version"`.
2. **Linux Shared-Library Packaging Parity:** Verifies `scripts/package_linux_rpm.sh`, `scripts/package_linux_deb.sh`, `scripts/install_linux.sh`, and `.github/workflows/build.yml` match any native desktop plugin dependencies (`media_kit` / `libmpv`).
3. **Rust Engine CI Suite (`--release --locked`):**
   - `cargo test --release --locked --lib --test erp_workbench_parity --test epoch_preprocessing --test vhdr_calibration`
   - `cargo test --release --locked --bin ccs-eeg-engine`
   - `cargo test --release --locked -p ccs_ica --lib`
   - `cargo test --release --locked -p ccs_algorithm --lib`
   - *Reminder:* Whenever `bridge/Cargo.toml` version or dependencies change, run `(cd bridge && cargo check)` so `bridge/Cargo.lock` stays updated before `--locked` runs.
4. **Flutter Analysis & Tests:** `flutter analyze --no-fatal-infos` and `flutter test`.
5. **Workflow Scope Guard:** Warns before pushing if `.github/workflows/` is modified locally.

> **Tag only after green check:** Never push tag `vX.Y.Z` until `preflight_release.sh` exits `0` cleanly (and any required `.github/workflows/build.yml` update is already on `main`).

---

## Updating `.github/workflows/build.yml` Safely (Without Unrelated Org OAuth Access)

If you do not want `gh` OAuth device login to request organization-level access to unrelated organizations, use **either**:

- **Option A — GitHub Web UI (Fastest, Zero Token Scope Changes):**
  Open `.github/workflows/build.yml` directly in your browser on GitHub, click the edit icon (✎), paste the change, and commit to `main`. Then run `git pull --rebase origin main` locally.
- **Option B — Repo-Scoped Fine-Grained PAT:**
  In GitHub → *Settings → Developer settings → Personal access tokens → Fine-grained tokens*, generate a token scoped **only** to `CCS-NIMHANS/CCS_EEGStudio` with *Contents (Read/Write)* + *Workflows (Read/Write)* permissions.
