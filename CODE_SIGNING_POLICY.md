# Code Signing Policy

This policy documents how official binary releases of **CCS EEG Studio** (`https://github.com/CCS-NIMHANS/CCS_EEGStudio`) are built, verified, and code-signed for distribution under the **MIT License** ([LICENSE](LICENSE)).

## Attribution

> Free code signing provided by SignPath.io, certificate by SignPath Foundation.

## Platform Signing Overview

| Platform | Signing Authority / Mechanism | Scope |
| :--- | :--- | :--- |
| **Windows** (`.exe` app binaries, bundled `.dll`s, Inno Setup installer) | **SignPath Foundation** (`SignPath.io` open-source Authenticode EV certificate) | Eliminates Windows 11 Smart App Control blocks and Microsoft Defender SmartScreen warnings |
| **macOS** (`.app` inside `.zip` & `.dmg`) | **Apple Developer ID Application** (Team `Y445J7MR4Q` — Arun Sasidharan) + **Hardened Runtime** + **Apple Notarization** & stapling | Eliminates macOS Gatekeeper quarantine warnings without requiring terminal commands |
| **Linux** (`.deb`, `.rpm`, `.tar.gz`) | GitHub Release `SHA256SUMS.txt` checksums verified in CI | Reproducible static musl engine + AlmaLinux 9 Docker RPM smoke check |

## Build Environment & Trust Model

- **GitHub-Hosted CI Runners Only:** All signed release binaries and installers are built exclusively from source in this public GitHub repository (`CCS-NIMHANS/CCS_EEGStudio`) on GitHub-hosted runners (`windows-2022`, `macos-latest`, `ubuntu-22.04`).
- **Branch & Tag Controls:** Production release signing runs only on protected release tags (`v*`) pushed from `main` (or explicit maintainer `workflow_dispatch`), never from pull requests or fork workflows.
- **No Unreviewed External Code in Signed Artifacts:** External pull requests cannot access repository secrets or trigger signing workflows and must be reviewed and merged by a repository maintainer before any release tag is cut.

## Team Roles

| Role | Responsibility | Members |
| :--- | :--- | :--- |
| **Committers & Reviewers** | Author source code, review pull requests, run automated test suites (`cargo test`, `flutter test`), and maintain dependency hygiene | CCS-NIMHANS maintainers led by **Dr. Arun Sasidharan** (`@arunsasidharan84`, Centre for Consciousness Studies, Department of Neurophysiology, NIMHANS) |
| **Approvers** | Approve release tags (`v*`), verify release notes and checksums, and approve SignPath signing requests when required | Repository administrators of `CCS-NIMHANS/CCS_EEGStudio` |
| **Contributors** | External community contributors submitting issues or pull requests (no direct commit or signing access) | Open-source contributors via pull requests |

## Privacy Policy

CCS EEG Studio is an offline desktop neuroimaging and electrophysiology analysis application. It processes EEG recordings, audio/video files, and statistical datasets strictly **locally on the user's machine** and does **not** collect telemetry, analytics, or user data, and does **not** transfer any information to external networked systems unless explicitly initiated by the user (for example: clicking **Updates** to query public GitHub Releases metadata/download installers, checking official public biological/neuroimaging reference resources if requested, or clicking **Setup FFmpeg -> Install via WinGet** on Windows).
