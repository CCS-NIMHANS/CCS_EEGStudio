# Methods, implementation conventions and validation

This guide accompanies version 1.2.51. Paper citations and original implementation
links appear in the [README method table](../README.md#-method-references).
Native ports and algorithms are integrated by
[`preprocessing.rs`](../bridge/vendor/ccs_algorithm/src/eeg/preprocessing.rs),
[`xpikan.rs`](../bridge/vendor/ccs_algorithm/src/eeg/xpikan.rs),
[`source_loc.rs`](../bridge/vendor/ccs_algorithm/src/eeg/source_loc.rs),
[`speech_tracking.rs`](../bridge/src/speech_tracking.rs), and
[`main.rs`](../bridge/src/main.rs); the vendored ICA library is
[`ccs_ica`](../bridge/vendor/ccs_ica/README.md).

## Processing order and input requirements

Continuous input follows filtering/downsampling, optional accepted/rejected time
selection, bad-channel detection, ICA, muscle cleaner, ASR, fixed-window epoching,
GEDAI, interpolation, output referencing, then optional source projection.
Stimulus epoching happens before the ICA/ASR stage; those cleaners therefore skip
stimulus epochs with a warning. Already epoched recordings also skip them.

ICA needs at least eight usable channels with positions in the 10-05 lookup and
at least 20 seconds. Bad and unlocated channels are excluded from the fit. ASR
needs at least two good channels. ICA/ASR fit on a 1 Hz high-passed copy unless
input filtering already provides it; removed/corrected contributions are applied
to the analysis data. Bad-channel detection runs on the bandpass/notch-filtered
`f64` channels using 2 s windowed robust MAD amplitude, high-frequency noise
ratio, and glitch-masked windowed spatial max-correlation (Bigdely-Shamlo et al.,
2015), combined with manual exclusions from the UI table before interpolation.

ASR Correct retains sample count. Reject drops burst samples: original markers
and input waveform comparisons are not copied as though the timeline were
unchanged. Output timing is compressed. Use Correct for timing-sensitive analysis.
Interpolation occurs later. Cleaners are opt-in, and combining them can remove
more signal than any one cleaner. Logs and `.preprocessing.json` report actual
settings, warnings, component removals, and ASR outcomes.

## ICA and ICLabel

The first stage detects blinks from a selected raw eye channel, or the first
recording-order channel matching Fp1/Fp2/AFz/Fz/F7/F8/AF3/AF4. It fits ICA on a
random subset of two-second blink-centred epochs of the 1 Hz copy. Defaults are
20 epochs, blink threshold 0.99, second-stage threshold 0.60, with heart-component
removal enabled. Selection loops lower thresholds within configured floors.

The second stage fits ICA on the stage-one-cleaned high-passed data after ASR
fit-data burst rejection (cutoff 15) and window screening. The weights apply to
the un-rejected analysis data. ICLabel identifies Muscle, Line Noise and Channel
Noise classes. Selection limits include 10% of components and 30% signal loss.
Studio supports runica and Picard; random seed is fixed/configurable. Component
signs and independent stochastic fits need not match MATLAB component by component.

## ASR and muscle variants

| Option | Actual implementation | Evidence or limitation |
| :--- | :--- | :--- |
| Standard ASR | Native clean_asr/asr_calibrate/asr_process/clean_windows port | Upstream comparisons against MATLAB/EEGLAB on three 120-second, 30-channel EDFs at cutoffs 5/15/20. |
| Riemannian ASR | asr_calibrate_r/asr_process_r port | Same three-file/cutoff comparison; Studio processes in 30-second blocks. Reference comparisons used one MATLAB memory block. |
| ASR_DBSCAN / ASR_GEV | mne-denoise-style calibration sample selection followed by this crate's EEGLAB-style ASR reconstruction | Selection was checked; the mne-denoise reconstruction core was not compared. |
| Adaptive ASR | Own exponential-moving-average recalibration | Not mne-denoise's published AdaptiveASR psw/psp/mw implementation. Alpha zero matches static ASR; no original A-ASR parity claim. |
| E-ASR | Delay embedding, ASR of pseudo-channels, recombination | Experimental interpretation; original code/paper validation was unavailable. Inputs above eight channels skip with a warning. |
| VMD-ASR / EMD-ASR | Per-channel mode decomposition, ASR of modes, recombination | Mode checks do not validate the combined ASR method. Above eight channels skip. |
| BSS-CCA | CCA with a lagged signal; remove low-correlation components | Checked against mne-denoise and MATLAB canoncorr. |
| iCanClean | Sliding CCA with a pseudo-reference formed by a fourth-order zero-phase Butterworth band-stop | Checked against mne-denoise pseudo-reference mode. This is not every physical-reference/calibrated/hybrid mode of iCanClean. |
| wICA | HAPPE-style extended runica, coif5 SWT/iswt, ddencmp soft thresholds, subtraction of wavelet IC contribution | Default five levels. Wavelet/reconstruction check reused MATLAB's unmixing matrix, so it does not establish independent-fit end-to-end equality. |

Additional original sources: [mne-denoise](https://github.com/mne-tools/mne-denoise),
[HAPPE](https://github.com/lcnhappe/happe),
[EEGLAB clean_rawdata](https://github.com/sccn/clean_rawdata), and
[python-picard](https://github.com/mind-inria/picard).
Deep-learning denoisers and nASR are not implemented.

## Upstream numerical evidence

The following records were supplied with the library and inspected for this
release. They are scoped to those fixtures and are not newly rerun external
MATLAB/Python comparisons during packaging. The source workspace's
`ccs_toolbox/rust_ica/validation/` contains reference harnesses; the vendored
snapshot retains [its validation record](../bridge/vendor/ccs_ica/VALIDATION.md).

| Check | Recorded result | Important scope |
| :--- | :--- | :--- |
| runica/pop_runica | W/inverse differences about 1e-6–1e-4 across six runs | Random permutations replayed; PCA component signs may differ. |
| ICLabel continuous stage | Topographies exact; autocorrelation 6e-8; PSD up to 1e-5; class probabilities up to 1e-4; argmax classes identical | Three 120-second EDFs. |
| ICLabel blink stage | Probabilities up to 1.5e-2; argmax classes identical | Near-constant blink components had PSD discrepancies up to 0.16 normalized. |
| Component selection | Identical lists on six fits; blink cleaning 1e-5–1e-4 µV | Stage two removed no components on these fixtures, so removal effectiveness there is weakly tested. |
| Picard | About 1e-12 standard/orthogonal; 3e-6 non-extended orthogonal | Compared with python-picard. |
| Standard ASR | Repaired data about 1e-12 on two files, 5e-8 on one; rejection masks identical | Three files × three cutoffs; calibration differences have separate scales. |
| Riemannian ASR | Calibration M about 1e-13, 3e-9 on one file; repaired data 1e-12 where repair occurs | Two files changed less than 4e-6, so their repair check is weak evidence. |
| Blink detection | Identical event counts 11/39/7; FIRLS 1.5e-14; eegfilt up to 5e-12 | Detector parity does not guarantee artifact labels in every recording. |
| BSS-CCA | About 1e-10 mne-denoise; canonical correlations 7.7e-14 MATLAB | Counts 3/6 and rho threshold 0.98. |
| iCanClean | Maximum absolute differences 1.3e-9 and 3.8e-8 | Two band/threshold settings on 30-channel EEG. |
| wICA | 9.4e-5 maximum cleaned-data difference; signal change up to 211 | MATLAB single-precision pathway, same unmixing matrix. |
| DBSCAN/GEV selection | DBSCAN identical; GEV one sample of 12,000 differs | GEV optimizer tolerance; ASR reconstruction not a mne-denoise parity claim. |
| EMD | First three IMF correlations 0.998–0.999 versus MATLAB | Seven versus eight IMFs; different from PyEMD stopping rules. |
| VMD | Per-mode relative difference 1e-4–2.4e-4 versus vmdpy | Nonconverged run with matching iteration convention. |

## DFA/fE:I and other feature conventions

Band-limited DFA/fE:I uses Hilbert amplitude envelopes, detrended scaling and
amplitude/fluctuation relations, following Hardstone et al. (2012) and Bruining
et al. (2020). See [`dfa_fei.rs`](../bridge/vendor/ccs_algorithm/src/eeg/dfa_fei.rs)
for filter, fit-scale, outlier and window rules. The port's source record reports
roughly 1e-14 agreement with the CCS Python implementation on its fixtures;
the context/gating update deliberately diverges from the legacy NaN fE:I gate;
see [report/context conventions](report_and_dfa_context.md). The earlier release
ran its internal regression tests rather than repeating that
external parity exercise. Windows are clamped for short data; bands unable to
fit return NaN. Those adaptations cannot establish long-range correlations from
two-second epochs or turn fE:I into a direct physiological E/I measurement.

FOOOF/IRASA retain the documented 1–40 Hz fitting range. Connectivity uses the
4–40 Hz grid; GC − GC-TR is the difference of the same forward/time-reversed fits,
not net directional GC. Custom PSD bands and references follow the
[workflow conventions](workflow_improvements.md). GEDAI uses leadfield covariance
for recognized channels; unknown geometry has an explicit identity-reference
warning and must not be reported as equivalent leadfield-based GEDAI.

## New & audited algorithms (v1.2.49 – v1.2.51)

| Method | Actual implementation | Validation & explicit scope limits |
| :--- | :--- | :--- |
| **Windowed Bad Channel Detection** | Bigdely-Shamlo et al. (2015) PREP / `clean_rawdata`-inspired 2 s windowed robust MAD (`1.4826×MAD`), HF ratio, and glitch-masked windowed spatial max-`\|r\|` on filtered `f64` EEG | Verified against synthetic 16-ch EEG with `500,000 µV` global saturation spike and inspected on all 4 `Krithika_EEG/*.vhdr` files (`PB2001_1` flags `TP10`, `Oz`, `O2`, `FC2`, `FT10`, etc.). Not full RANSAC channel-by-channel reconstruction during detection. |
| **IAF & Individual Bands** | Welch PSD + 5-pt cubic Savitzky–Golay smoothing + log-log 1/f background subtraction; parabolic PAF (`>0.15` peak prominence) or CoG fallback (`IAF_Hz`, Corcoran et al., 2018); Klimesch (1999) `[IAF-6, IAF-2]` & `[IAF-2, IAF+2]` relative PSD (`1–40 Hz`) | Verified on synthetic multi-oscillation epochs (`|IAF - 10.5| < 0.35 Hz`). Single short epochs (`< 2 s`) have coarser `Δf` resolution than multi-minute resting averages. |
| **Frequency Sliding** | Cohen (2014): reflection-padded raised-cosine plateau bandpass + Hilbert analytic phase derivative + 10-order temporal median filter (`50–400 ms`) with edge trim | Verified on synthetic rhythms and injected phase-slip spikes (`< 0.35 Hz` error). Reported per epoch as median sliding frequency (`Theta/Alpha_FreqSliding_Hz`). |
| **Neural Speech Tracking (`mTRF`)** | Streamed constant-memory WAV decoder + Hilbert `env^0.3` compression (Biesmans et al., 2017) + zero-phase `1–15 Hz` anti-aliased EEG/envelope + 64 Hz Crosse et al. (2016) mTRF first-difference Tikhonov smoothness `M` + 5-fold CV `λ` search + dense causal decoder (`0–250 ms`) + one-tailed 200-shift circular surrogate null test | Verified on synthetic auditory N1 (`−100 ms`) / P2 (`+200 ms`) convolution recovery (`r > 0.45, p < 0.02`) and uncorrelated pink/white noise (`p > 0.05`, no spurious low p on negative `r`). |
| **3-Shell XPIKAN (`xpikan.rs` & `source_loc.rs`)** | Domain-decomposed concentric 3-shell (`cerebrum / skull / scalp`) cubic B-spline × real spherical harmonic KAN (`∇²u = 0`, interface potential & normal flux continuity, outer scalp Neumann BC) verified against exact 3-shell Legendre series (`r > 0.995`, rel L2 `< 5%`); inverse operator uses outer-scalp Neumann-spline manifold projector + empirical sensor covariance with sLORETA depth standardization | CPU-native physics-informed solver over canonical concentric head shells + fsaverage 10–05 leadfield; not individualized MRI FEM/BEM or multi-hour GPU neural training. |
| **Group Statistics (`ErpGroupStatsEngine`)** | Split-plot Mixed-Design Factorial ANOVA (separating `SS_subj` between-subject intercept variance from `SS_within - SS_subj` within-subject residual) paired with exchangeable permutation testing (`p_perm`) and BH-FDR / Bonferroni post-hocs | Verified against exact balanced 2×2 analytical split-plot `F_within` (`640.0` within `1e-4`). Uses ANOVA cell-mean marginal SS rather than full REML `lme4` covariance estimation on unbalanced hierarchical designs. |

## Release checks

Use `bash scripts/preflight_release.sh` at the project root (runs `cargo test --release --locked`, `flutter analyze --no-fatal-infos`, `flutter test`, version sync, and Linux dependency checks). Documentation and [Release CI SOP](RELEASE_SOP.md) explain CI packaging verification across macOS, Windows, Ubuntu `.deb`, and AlmaLinux 9 `.rpm`.
