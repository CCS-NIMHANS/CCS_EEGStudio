# Third-Party Notices

CCS EEG Studio is released under the [MIT License](LICENSE). It ports, re-implements, or builds upon algorithms, concepts, and reference implementations from the scientific neurophysiology community listed below.

## Ported Algorithms and Reference Implementations

| Algorithm / Method | Implementation / Location | Upstream Reference | Licence | Attribution & Notes |
| :--- | :--- | :--- | :--- | :--- |
| **Infomax ICA / runica** | `bridge/vendor/ccs_ica/` | [EEGLAB `pop_runica`](https://github.com/sccn/eeglab) | GPL-2.0+ / BSD | Bell & Sejnowski (1995); Makeig et al. (1996). Native Rust numerical port. |
| **Picard ICA** | `bridge/vendor/ccs_ica/` | [python-picard](https://github.com/mind-inria/picard) | BSD-3-Clause | Ablin, Cardoso & Gramfort (2018). Fast preconditioned ICA for EEG. |
| **ICLabel** | `bridge/vendor/ccs_ica/` | [ICLabel](https://github.com/sccn/ICLabel) | GPL-3.0 / MIT | Pion-Tonachini, Kreutz-Delgado & Makeig (2019). Component classification neural network ported to Rust. |
| **ASR (Artifact Subspace Removal)** | `bridge/vendor/ccs_algorithm/src/eeg/asr.rs` | [EEGLAB `clean_rawdata`](https://github.com/sccn/clean_rawdata) | GPL-1.0+ | Mullen et al. (2015); Chang et al. (2018). Native calibration and geometric projection. |
| **Riemannian ASR** | `bridge/vendor/ccs_algorithm/src/eeg/asr_riemann.rs` | [asr_riemannian](https://github.com/hoechenberger/asr_riemannian) | BSD-2-Clause | Blum et al. (2019). Riemannian geometric covariance adaptation. |
| **GEDAI** | `bridge/vendor/ccs_algorithm/src/eeg/gedai.rs` | [GEDAI](https://github.com/Marco-Congedo/Gedai) | BSD-3-Clause | Congedo et al. Generalized Eigenvalue Decomposition for Artifact Rejection. |
| **Spherical Splines & CSD** | `bridge/vendor/ccs_algorithm/src/eeg/spline.rs` | [Perrin et al. (1989)](https://doi.org/10.1016/0013-4694(89)90180-6) | Public Reference | Spherical spline interpolation and Current Source Density (Laplacian) operator. |
| **FOOOF / specparam** | `bridge/vendor/ccs_algorithm/src/eeg/spectral.rs` | [specparam / fooof](https://github.com/fooof-tools/fooof) | Apache-2.0 | Donoghue et al. (2020). Native Rust Levenberg–Marquardt optimization of aperiodic and oscillatory parameters. |
| **IRASA** | `bridge/vendor/ccs_algorithm/src/eeg/irasa.rs` | [Wen & Liu (2016)](https://doi.org/10.1007/s10548-015-0448-0) | Public Reference | Irregularly Resampled Auto-Spectral Analysis for fractal/aperiodic separation. |
| **Gaussian Copula MI (GCMI)** | `bridge/vendor/ccs_algorithm/src/eeg/gcmi.rs` | [Frites](https://github.com/brainets/frites) | BSD-3-Clause | Ince et al. (2017). Parametric copula mutual information on rank-transformed margins. Full notice in `docs/licenses/Frites-BSD-3-Clause.txt`. |
| **MNE-Python** | `bridge/src/mne_fif.rs`, filtering, connectivity | [MNE-Python](https://github.com/mne-tools/mne-python) | BSD-3-Clause | Gramfort et al. (2013). Format specification, zero-phase FIR filter designs, and connectivity metrics. |
| **eTFCE (Electrode-Adjacency TFCE)** | `assets/group_stats.py` | [Smith & Nichols (2009)](https://doi.org/10.1016/j.neuroimage.2008.03.061); [Mensen et al. (2013)](https://doi.org/10.1016/j.neuroimage.2012.10.027) | Public Reference | Threshold-Free Cluster Enhancement extended across 10-20 spherical scalp coordinate adjacency graphs. |
| **Unfold / rERP** | `bridge/src/erp_workbench.rs` | [Unfold toolbox](https://github.com/unfoldtoolbox/unfold) | GPL-3.0 | Ehinger & Dimigen (2019). Linear continuous FIR deconvolution subset implemented via LSQR. |
| **ERP CORE** | `lib/src/erp/task_guides.dart` | [ERP CORE](https://doi.org/10.1016/j.neuroimage.2020.117465) | CC-BY-4.0 | Kappenman & Luck (2021). Standard experimental parameters, windows, ROIs, and event coding schemes. |

## Open-Source Dependencies

- **Rust Compute Engine:** Detailed in `bridge/Cargo.lock`. Includes `nalgebra` (Apache-2.0), `rustfft` (MIT / Apache-2.0), `rayon` (MIT / Apache-2.0), `serde` (MIT / Apache-2.0), and `matrixmultiply` (MIT / Apache-2.0).
- **Dart / Flutter Interface:** Detailed in `pubspec.lock`. Includes official Flutter framework libraries (BSD-3-Clause), `pdf` (Apache-2.0), `printing` (Apache-2.0), and `file_picker` (MIT).

### Source-review template geometry

`assets/source_review_geometry.json` contains derived orthogonal boundary projections from the locally available FreeSurfer **fsaverage** pial surfaces and **aparc / Desikan–Killiany** annotations. `tools/build_source_review_geometry.py` records the derivation. The display is explicitly a template atlas visualization, rather than individual anatomy. FreeSurfer and the Desikan–Killiany parcellation are acknowledged as the anatomy/atlas sources; no subject EEG is included in this asset.
