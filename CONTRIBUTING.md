# Contributing to CCS EEG Studio

Thank you for your interest in improving CCS EEG Studio. Contributions of all kinds are welcome: bug reports, documentation, test recordings or reference results, new file-format readers, and code.

## Getting help and reporting problems

- **Questions and usage help:** open a [GitHub issue](https://github.com/CCS-NIMHANS/CCS_EEGStudio/issues) or start a discussion on the repository.
- **Bugs:** open an issue using the *Bug report* template. Include the app version (shown in the top bar and in `CHANGELOG.md`), your operating system, the recording format, and the steps to reproduce. **Do not attach recordings that contain patient- or participant-identifiable information.** Share only de-identified excerpts or synthetic fixtures.
- **Feature requests:** open an issue using the *Feature request* template and describe the neurophysiology research or clinical use case.

## Building and testing

Prerequisites are listed in the [README](README.md#-running--building-locally): the Flutter SDK (stable channel) and the Rust toolchain (`cargo` and `rustc`).

```sh
# Clone the repository
git clone https://github.com/CCS-NIMHANS/CCS_EEGStudio.git
cd CCS_EEGStudio

# 1. Compile the native Rust computation engine and run engine tests
(cd bridge && cargo build --release && cargo test)

# 2. Run ERP parity and numerical test suite
(cd bridge && cargo test --test erp_workbench_parity)

# 3. Flutter dependencies, static analysis, and full test suite
flutter pub get
flutter analyze
flutter test
```

## Making a change

1. Fork the repository and create a branch from `main`.
2. Keep each pull request focused on one logical change.
3. Add or update tests. For re-implemented scientific methods, please add a comparison against the reference implementation (or a published benchmark) and document the tolerance achieved.
4. Ensure `cargo test`, `flutter analyze`, and `flutter test` all pass with zero errors.
5. Add a short entry to `CHANGELOG.md` for user-visible changes.
6. Open a pull request describing what changed and why.

## Code style

- **Rust:** follow standard conventions (`cargo fmt`, `cargo clippy` where practical).
- **Dart:** follow `flutter_lints` rules; `flutter analyze` must report no issues.
- **Comments:** prefer clear names and comments that explain *why*, particularly where a mathematical method follows a published paper or reference algorithm (cite the author, year, and DOI).

## Contributing data and reference results

Test data must be openly redistributable and fully de-identified, with the consent or ethics basis stated. Please open an issue before submitting large recording files.

## Scientific and clinical disclaimer

CCS EEG Studio is designed for cognitive neuroscience and clinical neurophysiology research. Automated artifact removal, ERP measurements, microstates, and quantitative EEG outputs are intended for research purposes and are not a substitute for review by a qualified clinical neurophysiologist. The software is not a certified medical device.

## Conduct and licence

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). By contributing, you agree that your contributions are licensed under the project's [MIT licence](LICENSE).
