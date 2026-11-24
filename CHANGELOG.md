# Changelog

All notable CCS EEG Studio changes are documented here. Version headings are
also the source for GitHub Release notes, so a tagged release is rejected when
its matching section is missing.

## [1.2.64]

### Standalone Group Statistics, Multiple ERP Differences, Contrast Scope & Plot Readability

- **Standalone Multi-Factor Group Statistics**
  - Removed legacy Python environment warnings and the `Legacy Python Report` switcher so `GroupStatisticsWorkbench` runs cleanly as a standalone desktop workflow powered by the native Rust LMM/GLM backend (`ccs-eeg-engine`) and built-in permutation engine.
  - Simplified `2. Design & run` into one model flow (**Linear Mixed Model / GLM** by default, with optional permutation testing and ERP difference mode grouped under **Optional: Advanced model & ERP difference**).
- **Composable Multi-Source Factors & Unified Grouping Designer**
  - Added composable factor resolution supporting filename-cropped factors, folder-path factors, and multiple external `.xlsx`/`.csv` sheets together without overwriting earlier assignments, plus automatic `Session` extraction from filenames.
  - Unified redundant group-labeling dialogs onto **Factor & Grouping Designer** (`Factors & Groups…`) and exported all custom factor columns into `ERP_*_group_input.csv`.
- **Stage 4 Grouped Grand Average Waveforms**
  - Added an interactive **Grouped Grand Average** (`mean ± SEM`) waveform viewer directly inside ERP Stage 4 (`ERP & Topo`) with a **`Grand Avg by:`** factor selector and `Panels` vs `Lines` orientation toggle.
- **Type III Wald Tests, Custom Level Ordering & Contrast Scope**
  - Switched `factorial_lmm` to sum-to-zero deviation coding so omnibus Wald χ² / F effects are true **Type III marginal tests** invariant to factor level ordering, and preserved custom user level ordering (e.g. `CON → NOV → INT → ADV`) across both LMM/GLM and results plots.
  - Added an explicit **`Pairwise comparisons (Contrast scope):`** selector (`All factors` or `<Factor> only`) so pairwise comparisons and FDR/Bonferroni adjustments can focus on a chosen factor while keeping all main effects and interactions in the model.
- **Multiple ERP Differences (`B − A`)**
  - Added **`+ Add difference`** support (e.g. `Rare − Freq` and `Distr − Freq`) with automatic support for either unified multi-difference modelling (`Condition` kept checked) or separate difference metrics (`Condition` unchecked), plus human-readable difference metric labels.
- **Readable Statistical Plots & Box Plot Data Points**
  - Updated `ConfigurableStatsPlotWidget` so bracket stacks never squish curve height, aligned Y-axes across facet columns, added 5 Y-axis ticks and a clearer zero line, added color-coded `SeriesA–SeriesB *` cross-series brackets with an **`Off | Top 4 | All`** toggle, and widened the Metric selector.
  - Upgraded **Box Plots** with 1.5 × IQR Tukey whiskers and subtle low-discrepancy jittered individual data points behind the median line.
- **Improved In-App Release Notes Viewer**
  - Updated `FormattedReleaseNotes` in the update dialog to properly render Markdown headings (`#`–`####`), nested sub-bullets (`◦`), Markdown links, bold+inline-code combinations, italics, blockquotes, fenced code blocks, and a visible scrollbar.

## [1.2.63]

### macOS Developer ID Notarization & Windows SignPath Signing Infrastructure

- **macOS Developer ID Signing & Apple Notarization**
  - Signed and notarized macOS release builds with Apple Developer ID Application (Team `Y445J7MR4Q`), Hardened Runtime entitlements, and stapled notarization tickets for both `CCSEEGStudio-macos.zip` and drag-to-Applications `CCSEEGStudio-macos.dmg` — eliminating Gatekeeper/`xattr` terminal workarounds.
- **Windows SignPath Foundation Readiness**
  - Added [CODE_SIGNING_POLICY.md](CODE_SIGNING_POLICY.md), two-pass Authenticode CI signing hooks (for app binaries + Inno Setup installer), and SignPath Foundation attribution on the download page.

## [1.2.62]

### Native Python-Free GLM / LMM Engine, Clearer Group Stats & Generic Media Sync

- **Native Python-Free GLM / LMM Engine (`ccs-eeg-engine`)**
  - Added a standalone Rust `factorial_lmm` backend inside `ccs-eeg-engine` so multi-factor Group Statistics run with zero external Python (`numpy`, `pandas`, `scipy`, `statsmodels`) dependencies on Windows, macOS, and Linux.
  - Fits REML Random-Intercept Linear Mixed-Effects Models (`MixedLM`) for within-subject/repeated-measures factors and cluster-robust or plain OLS GLMs for between-subject designs, reporting exact Wald χ²/F main effects, interactions, marginal means, and Holm/BH-FDR/Bonferroni contrasts (validated within `< 5.5e-6` against `statsmodels`).

- **Clearer Group Statistics Workflows & Inline ERP Difference (`B − A`)**
  - Replaced confusing comparison mode names with explicit labels: `Multi-Factor GLM / LMM (Native)` for 1+ factors (with permutation option) alongside `Legacy Python Report (1–2 factors)`.
  - Added an inline **ERP Condition Mode** selector (`All conditions` vs `ERP Difference (B − A)`) directly inside Group Statistics so paired condition differences can be modelled in GLM / LMM and compared across cohorts without hunting for separate wizards.
  - Renamed the grouped waveform/topomap launcher to **Group Grand Averages & Topomaps…** and surfaced native GLM/LMM fitting status clearly.

- **Windows Media Playback Fixes & Guided FFmpeg Setup**
  - Fixed Windows `findTool` executable resolution across `PATH`, application directory, WinGet `Packages` installs, and persistent user preferences (`media_tools.json`).
  - Enabled native video and `.wav` audio playback on Windows via `libmpv` even when `ffmpeg.exe` is absent, with safe `compatibilityVideo` defaults so video playback no longer stalls waiting for FFmpeg transcoding.
  - Surfaced clear `Media load warning:` feedback and a guided **Setup FFmpeg…** dialog featuring 1-click **Install via WinGet** and **Locate ffmpeg.exe…** pickers that immediately re-extract waveform strips and unlock Neural Speech Tracking for compressed `.mp4`/`.m4a`/`.mp3` files.

- **Generic Audio/Video Sync for Independent Recorders**
  - Added pure-Dart Broadcast Wave (`bext`) and `LIST/INFO ICRD` WAV header timestamp parsing so standalone audio recorders, laptops, and mobile phones auto-align accurately to EEG clocks when metadata is present.
  - Added direct timeline manipulation (`Slide to sync` strip drag in Plots & Report, `±10s` nudges, and a clickable `Off:` sync dialog supporting **Landmark (`Audio ↔ EEG`)**, **Direct Offset**, and **Device Wall-Clock (`HH:MM:SS`)** alignment).
  - Persisted per-file offsets in `.ccssync.json` sidecars next to media files and added `Align to video…` plus sibling timestamped video cross-correlation.

## [1.2.61]

### Source Localization (eLORETA & Glass Brain), Channel Setup Headmap & ICA/GEDAI Clarity

- **eLORETA Inverse Operator (Pascual-Marqui, 2007):** Added fixed-orientation eLORETA in `ccs_algorithm` with average-reference centering ($H = I - \frac{1}{m}\mathbf{1}\mathbf{1}^T$), per-iteration trace-normalized regularization ($\alpha_k = \text{tr}(G_w) / (m \cdot \text{SNR}^2)$), allocation-free GEMM weight updates, and zero-localization-error verification across all synthetic dipoles and the 68-ROI `fsaverage` leadfield. Exposed both **eLORETA** and **XPIKAN** in `Source Space parameters` and the Source Space sidebar.
- **Publication-Ready Source Space Specification & Cleaner Glass Brain:** Displays forward model (`MNE fsaverage 3-shell BEM` with `0.30 / 0.006 / 0.30 S/m` vs `XPIKAN 3-shell PINN` with `0.33 / 0.0042 / 0.33 S/m`, `r = 0.87 / 0.92 / 1.00`), atlas (`DK68`), fixed surface-normal orientations, $\lambda^2 = 1/\text{SNR}^2$, and covariance model. Upgraded Glass Brain with an interactive **Threshold slider (`0%–80%`, default 25%)**, muted grayscale/white anatomical wireframe, side-by-side Sagittal/Coronal/Axial layout, and center `0` tick on the diverging colorbar.
- **Unified Channel Setup, Types, Manual Rename & Live 2D Headmap:** Merged `CHANNEL TYPES` from the bottom of the preprocessing sidebar into `1. Channel setup & montage`, fixed channel mapping dialog initialization so valid EEG channels start included, added a live **2D Headmap Preview** showing plottable 10-05/10-20 channels vs unlocated channels, and added an **`EGI HydroCel 128 -> 10-20`** preset.
- **ICA & GEDAI Parameter Clarity + ICA Review Upgrade:** Documented the `1.0 Hz` FIR high-pass decomposition copy and Stage 2 safety caps (max `10%` components / `30%` signal variance) in ICA parameters, renamed `ASR cutoff for the ICA fit copy (SD)` to `Bad segment removal cutoff for the ICA fit copy (SD)`, replaced GEDAI threshold text input with a GEVD preset pulldown (`auto-` noise=6/fallback 9, `auto` noise=3/fallback 6, `auto+` noise=1/fallback 3, numeric `1.0–12.0`), and updated **ICA component review** to show the major ICLabel class + % with green/red icons and full-recording `% signal variance removed`.

## [1.2.60]

- EEGLAB SET loading preserves channel labels beyond empty MATLAB struct fields; regression checks cover empty channel-reference fields and the affected 63-channel dataset was compared with Python.
- Microstate batches export joined group tables for state metrics, syntax entropy classes and transitions, with participant IDs, explicit units and a data dictionary. Shared-template group comparisons offer recording values and participant means for state metrics, LZ and syntax shares/ratios.
- Reopening a recording starts from original input. Resuming cached preprocessing is explicit; configured interactive steps are checked visibly, and Apply selected & finalise uses those exact selections.
- A global Start fresh action clears interactive EEG, ERP and Microstate views. Closing or replacing an input prompts to finalise unsaved preprocessing; temporary previews are deleted by default, with an explicit Keep cache option. Finalised exports are preserved.
- Preprocessing stages temporary files beside the output instead of the system temp drive. A persistent working-folder setting supports another drive, free-space checks explain low-space failures before staging, and elapsed engine activity remains visible during quiet ICA periods. Windows-specific behaviour still requires validation on affected machines.

- ERP group designs offer factor/level display aliases and series colours while preserving raw statistical identities. Corrected simple-effect brackets are restricted to their matching facet/cells, with expandable contrast details and result/contrast exports.
- N-factor analysis defaults to fitted Python OLS or REML random-intercept MixedLM with fitted-design marginal and simple-effect contrasts. Duplicate participant/cell rows are averaged before inference; corrected contrasts share one family per metric. The legacy native method is labelled as a split-plot ANOVA approximation, requires complete balanced cells, and uses paired participant-level comparisons for repeated factors. Earlier native group results should be rerun.
- The grouped publication studio exports PNG/SVG/PDF grand-average ERP, voltage maps, ERSP, ITC, saved rERP coefficients and saved ML AUC, with configurable grouping, facets, colours, ROI, limits, size, DPI and typography. TF groupings recompute from epochs and preserve distinct visits. Difference models read saved B-minus-A waveform measurements, including peaks/latencies.
- ERP folder selection detects completed .ccserp results and offers Results & groups rather than an unsupported-recording error. ERP saved-result entry points are confined to the ERP workflow.

## [1.2.59]

- XDF loading repairs bounded local timestamp reversals by interpolating between surrounding monotonic anchors, retaining sample order. Non-finite timestamps and large clock resets remain explicit errors. Repairs are recorded in provenance and the activity log.
- Feature plotting offers a session manager covering every subject group, plus a Sessions button on each stacked plot. Per-group exclusions can be reviewed together and applied without removing source files or changing another subject's selection.

## [1.2.58]

- Batch selection exposes automatic, parent-folder and editable per-file subject IDs. Subject sidecars follow cleaned recordings and feature CSVs, preserving overrides across flat output directories; subject-first Sub/TKG filenames group existing exports correctly.
- Compatibility video refreshes decoded frames independently of native textures during audio playback (up to 4 frames/s), with a visible renderer switch. Native playback remains available.
- GEDAI is disabled for new configurations, preserving explicit saved settings. Settings explain cumulative cleaning after ICA/ASR and that alpha-power reduction alone does not establish artifact removal. The GEDAI algorithm is unchanged.

## [1.2.57]

- ERPimage and its live condition averages share one plot column with matching time-axis boundaries. Butterfly defaults to accepted-trial condition averages, offers condition selection, and retains an explicit single-trial option.

- Paused video scrubbing decodes a frame at the requested media time, coalesces rapid timeline seeks, and hides the previous frame while decoding. Restore the native accelerated video texture for playback.
- Speech tracking explains five-fold recording-wide training, held-out predictions evaluated in 20-second windows every 5 seconds, decoder/forward models, circular-shift thresholds, and the absence of speech or silence detection. Curves are not labelled as evidence of attention.
- State Dynamics feature mapping places the heading above wrapping state chips, preventing six-state controls from collapsing the heading into a vertical column of characters.

## [1.2.56]

- Feature plots have a persistent Start fresh action that clears loaded plot files, figures, grouping, baseline selection, tracking status and attached media without deleting source files. The empty workspace offers a direct CSV loader.
- Media waveform, amplitude envelope and neural tracking layers can be shown or hidden separately. Envelope-only display is the default; long source captions are clipped to their own session axes.
- Media windows stay entirely inside the workspace when moved or resized, and expose playback in the title bar. Opening another segment preserves playback intent; initialization has a bounded wait and playback errors are visible.
- Neural speech tracking resolves the EEG recording behind a feature CSV even when that CSV initialized the media controller. Non-overlapping sessions are counted as skipped, with detailed per-session messages collapsed.

## [1.2.55]

- ICA review supports autoscaling and a fixed, zero-centered amplitude range retained across components and time windows.
- Raw and cleaned EEG can be compared side by side with channels matched by name, shared time and amplitude scaling, and independent sample rates. Successfully interpolated channels retain repair history without remaining marked bad.
- Interactive ERP always offers saved-epoch opening and distinguishes continuous cleaned recordings from saved trials. ERPimage averages have a larger, readable panel with correctly labelled negative-up scaling.
- Linked ERP measurements retain the live review window. Publication components and selected channels follow shared settings; preview and SVG polarity agree. Exports identify the displayed figure and save a settings sidecar; unsupported topomap SVG export is disabled.
- rERP and conventional difference waves align by sample time, with a shared amplitude range for rERP waveforms and maps. Model time axes follow epoch bounds; ML scores remain separate from amplitude maps.
- Measurements offer on-demand per-recording PDF reports with current components, accepted trial counts, source, baseline, waveforms and condition measurements.
- Feature plotting has a direct video/audio attachment action that works from feature CSVs. Feature gears show their own connectivity, ROI and band settings, without unrelated output-format controls; frequency bands use labelled table fields.
- Microstate scalp maps correct the MetaMaps angle convention (nose up, subject left at plot left), including legacy results, and align electrode dots with interpolation. Timeline defaults to shorter windows, spaced channel pages and one selected similarity trace; overlays are optional.
- Microstate syntax shows example state sequences for entropy classes and distinguishes sampled overlapping windows from unique word discovery.

## [1.2.54]

### ERP workflow and resuming saved work
- Replaced the duplicate stage ribbon, Tabs/Columns switch and parallel cards with one stage navigator: Prepare EEG → Events & trials → Measure ERP → Results & groups.
- Each stage owns its inputs: raw recordings in preprocessing, cleaned EEG in event review, saved epochs in ERP measurement, and saved waveforms or compact measurement tables in results. Loading saved epochs preserves trial boundaries; continuous inputs are routed back to event definition.
- Fixed the embedded preprocessing run callback so cleaned outputs actually reach the ERP workspace. Successful inspection carries those files forward and selects the appropriate next stage. Loading a different input set clears stale results and grouping exclusions.
- Saved measurement tables provide a fast route to group statistics without decoding full waveform files. Full waveform loading remains dependent on recording count and storage speed.
- Measurement output options live with the measurement stage; the results workspace no longer repeats the pipeline setup panel.

### Interactive labels and group analysis
- Replaced regex-first filename setup with automatic participant/session detection, visible filename-part mapping and editable, paged previews. Reviewed labels apply directly, while full recording paths keep separate sessions distinct.
- Data review distinguishes people, cohort groups, sessions and stimulus conditions, shows the source of every label, and previews recording-to-person mappings. Cohorts are never inferred from stimulus conditions.
- Excel group import uses the bundled reader, automatically finds subject IDs after serial-number columns, and separates participant identity from session suffixes. Missing cohort labels must be assigned or explicitly excluded.
- Guided Data & groups → Design & run → Results workflow with one run action, readable metric labels, optional advanced controls and honest reporting of unavailable Word/PDF exports.

### Connectivity and microstates
- Added weighted graph measures, seeded Louvain communities, directed transfer-entropy graph handling, configurable MIC/MIM ROIs, and a connectivity graph viewer with matrices, scalp/circular layouts and graph tables.
- Connectivity settings are grouped under their own features and directed/undirected measures are identified explicitly.
- Microstate results explain map polarity/scaling, canonical-label availability, variance and timing summaries, sparse syntax estimates and transition probabilities after leaving a state.

## [1.2.53]

### Preprocessing fixes (Workshop_Test review)
- Interactive Preprocessing: each step has a tick box and "Apply selected (N)" runs the ticked steps together in one cached engine run; "Default for new configured runs" boxes removed; Batch cards no longer show both a checkbox and a switch. Fixed Batch ASR/Muscle switches writing invalid modes (`burst_repair`, `cca`) and ASR "off" counting as enabled.
- Viewer: bad channels are drawn in red and can be hidden (header chip); right-click a channel to mark/unmark it bad (feeds the manual list of "Detect bad channels").
- ASR: slow (<1 Hz) excursions of artefact bursts that ASR cannot see are now interpolated (previously a ~9500 uV rms drift survived and appeared as a new artefact after ASR).
- GEDAI: runs on good channels only (with `leadfield_cov` subset to those electrodes) so flat/railed bad channels do not distort the covariance GEVD and interpolated channels are not treated as independent sources; bad channels are interpolated afterwards (along with ICA and ASR) before the output reference.
- Bad-channel detection: per-window linear detrend and a 4x (was 5x) amplitude ratio at the default setting, so channels like P3/FC2 are caught.


### Video/Audio ↔ EEG Sync Fixes & Time-Resolved Neural Speech Tracking

- **Sync root-cause fix:** the BrainVision `.vmrk` "New Segment" start-time pattern was one field short and never matched, so offsets silently fell back to file modification times. Start times now come from the `.vmrk` (with microseconds), the processing-history `source_path` chain, or a nearby matching `.vmrk`; media start prefers the recording-site clock in the file name over UTC `creation_time`; file mtimes are never used.
- **One wall-clock timeline:** every plotted session and media segment is placed by absolute start time, plot cursors are per session (no more one shared time on every axis), clicks on any plot seek the right media, seeks wait for the media duration before jumping, and media that does not cover the cursor no longer shows an unrelated frame.
- **Audio-to-video auto-alignment (`align_audio` job):** audio-only files without a clock are aligned to a loaded video's audio by speech-envelope cross-correlation (`Align to video` in the panel).
- **Envelope source & aligned lanes:** the audio waveform/envelope now names its source (video audio track vs audio file) and is drawn in the exact horizontal span of each session's feature plot.
- **Neural Speech Tracking time series:** sliding-window decoder-reconstruction r and forward-TRF r (out-of-fold, with circular-shift 95% chance lines) drawn under the feature plot on the same time axis (`Speech Tracking` in the Plots toolbar).

## [1.2.52]

### Multi-Component ERP, Group ERSP/ERPimage/rERP, Isolate Worker Fixes & Folder Picker Overhaul

- **Microstates, Group Statistics & Loader Isolate Fix:** Extracted all `Isolate.run` workers (`writeMicrostateSignalInWorker`, `decodeMicrostateJsonInWorker`, `_loadPortableInWorker`, `runDartPermutationsInWorker`) into top-level boundaries so live Flutter `State`/`BuildContext`/`WidgetsFlutterBinding` references are never captured by shared closures.
- **macOS Folder Picker Freeze Fix (`pickDirectorySafe`):** Added re-entrancy locking, fast reachability checks avoiding slow `/Volumes/` SMB fallback mounts (`NSNavLastRootDirectory` stalls), frame yields, `"Opening…"` UI busy feedback, and async `Directory.list` folder enumeration across Microstates, ERP, and Batch Workspaces.
- **BrainVision Recovery, Progress/ETA, New Instance & Clear Controls:** Added fuzzy `.eeg`/`.vmrk` companion mapping typo recovery (`vhdr_loader`), monotonic weighted batch progress & adaptive per-substep ETA (`BatchProgressTracker`), top-bar `New Instance` spawning, unified ERP progress banner, Stage 4 toggle/exports, and `Clear`/`Clear All` workspace resets.
- **Multi-Component ERP, Cached Grand Average & Interlinked Exploration:** Added multi-component definitions (`ErpComponentSpec`) and `erp_component_measurements.csv`, concatenated subject/session parsing (`SKYMED013SESSION03` -> `SKYMED013`), cached in-memory `ErpWaveformCache` / `ErpCacheRecompute` (live epoch cropping, re-baselining, grouping, and components without disk re-I/O), Searchable Subject Picker, Group Filter, Global Channel/ROI Switcher, and interlinked `ErpChannelGrid` enlargement.
- **Group ERSP/ITC, Group ERPimage, Group rERP/ML, 4+ Group Publication Plots & Group Statistics UX:** Added multi-group Okabe-Ito palettes, fixed Y-scaling & X-ticks, `RdBu_r` topomaps, and Fig 3 swatches (`publication_plots.dart`); added `GroupErpImagePanel`, `group_ersp_itc` with label fallback, subject-averaged rERP/decoding aggregation, and inline `Exclude "Unknown"` + `--exclude-levels` + composite-ROI preservation across Dart & Python Group Statistics.

## [1.2.51]

### True Algorithmic Parity Audit, Complete Method References & Permanent Pre-Release CI SOP

- **PREP / `clean_rawdata` Windowed Bad-Channel Detection:** Moved automated bad-channel detection in `preprocessing.rs` onto bandpass/notch-filtered `f64` channels (`detect_bad_channels_f64`) with 2 s windowed robust MAD amplitude, high-frequency noise ratio, and glitch-masked windowed spatial max-correlation (`Bigdely-Shamlo et al., 2015`). Prevents global saturation spikes from masking noisy/uncorrelated electrodes (validated on `Krithika_EEG` recordings and synthetic multi-channel fixtures).
- **RestingIAF + Klimesch Bands + Cohen (2014) Frequency Sliding:** Upgraded `iaf_and_sliding_features` in `main.rs` to Savitzky–Golay smoothed Welch PSD + 1/f background subtraction (`PAF`/`CoG` per Corcoran et al., 2018), Klimesch individual theta/alpha relative power (`1–40 Hz`), and reflection-padded raised-cosine plateau bandpass + Hilbert instantaneous phase derivative + Cohen (2014) 10-order (`50–400 ms`) temporal median filter.
- **Neural Speech Tracking (Crosse et al., 2016 mTRF Parity & Constant-Memory WAV Streaming):** Rewrote `speech_tracking.rs` to stream `.wav` files in 65,536-frame chunks with Hilbert + `env^0.3` auditory power-law compression (`Biesmans et al., 2017`), zero-phase `1–15 Hz` anti-aliased EEG and envelope filtering, first-difference Tikhonov smoothness penalty `M` + 5-fold CV `lambda` selection, dense `0–250 ms` causal decoder lags, and a valid one-tailed 200-shift circular-shift permutation null test (eliminating bogus low p-values on negative correlations).
- **True 3-Shell Domain-Decomposed XPIKAN (`xpikan.rs` & `source_loc.rs`):** Replaced the previous shrinkage stub with a genuine concentric 3-shell (cerebrum/skull/scalp) radial cubic B-spline × real spherical harmonic XPIKAN solver enforcing interior Laplace PDE residuals, interface potential & radial flux continuity, and outer scalp Neumann boundary condition (validated against the exact 3-shell analytical Legendre series to `r > 0.999` and `< 5%` L2 error), integrated into source localization with outer-scalp Neumann-spline manifold regularization.
- **Mixed-Design Split-Plot ANOVA Within-Subject Error & UI/Reporting Polish:** Separated subject random-intercept variance (`SS_subj`) from within-subject residual (`SS_within - SS_subj`) in `ErpGroupStatsEngine`, wired synced `Audio & Envelope` waveform + cursor ribbon directly into `TopoStatsView`, added single-file publication parameter logs (`analysis_parameters_log.md` + JSON), and added `EegViewer` time-axis progression tests.
- **Linux `mpv-libs` Packaging & Pre-Release CI SOP:** Added `Recommends: mpv-libs` and `libmpv.so.2 -> libmpv.so.1` symlinks in `scripts/package_linux_rpm.sh`, `scripts/package_linux_deb.sh`, and `scripts/install_linux.sh`, plus `scripts/preflight_release.sh` and `docs/RELEASE_SOP.md`. Restored and expanded peer-reviewed **Method References** across `README.md`, `docs/wiki/`, and `docs/methods_and_validation.md`.

## [1.2.50]

### Interactive Batch File Selector, Unbiased Grand Average Localizer, Factor Grouping Designer & Permutation GLM/LMM Plots

- **Integrated Folder & File Selection UI:** Defaulted `First N participants on folder import` to `0` (all files) and added `BatchFileSelectionDialog` across ERP Batch Stage 1/Stage 2 and EEG Batch folder imports. Users can inspect all discovered files, filter by filename/subfolder/wildcard, select/deselect/invert individual files, apply a First-N-subject subset, or merge additional `+ Files` / `+ Folder` sources from one dialog. Also added checkboxes and `+ Files` / `+ Folder` actions to `Review files and participant IDs…`.
- **Unbiased Grand Average Localizer (ROI & Time Window):** Added `grand_average_preview` in the Rust engine (`erp_workbench.rs`) and `GrandAverageLocalizerDialog` in ERP Stage 3 (`Grand Average Localizer (ROI & Window)…`). View Grand Averages **Collapsed** across all groups & conditions (unbiased localizer), **By Condition**, **By Group**, or **Group × Condition** in either **ROI Mean** or **Butterfly + GFP** mode; drag or slide to adjust the measurement window with a live-updating **Scalp Topography**, click electrodes or pick the top peak channels, and apply the ROI, time window, and polarity directly to Stage 3.
- **Factor & Grouping Designer (Folder/BIDS, CSV/Excel `.xlsx`, Interactive Filename Cropper & Grouping Tree):** Added `FactorGroupingDesignerDialog` (`TabularSheetReader` supporting `.xlsx`, `.csv`, and `.tsv` sheets like `Groups.xlsx` in pure Dart) with BIDS/folder auto-detection, an interactive **Filename Factor Cropper** that automatically infers extraction rules (keyword+digits, delimiter tokens, context anchors, or fixed slices) with live preview across all files, user-defined multi-factor management, and an interactive **Grouping Tree** to include or reject factor levels, branches, or individual files.
- **N-Way Permutation GLM / LMM & Configurable Statistical Plots with Dummy Preview:** Added pure-Dart `ErpGroupStatsEngine` supporting N-way Factorial GLM and Linear Mixed Models (LMM with subject random intercepts) with exchangeable permutation testing (`p_perm`) and FDR/Bonferroni post-hoc contrasts. Added `ConfigurableStatsPlotWidget` allowing users to assign any factor to **X-Axis (Points)**, **Lines/Hue (Series)**, **Subplot Columns**, and **Subplot Rows**, reorder/exclude factor levels, and inspect a live **Sample Dummy Preview** before running analysis.
- **CI Workflow & Linux Media Build Fix:** Upgraded `actions/upload-artifact` (`v7`) and `actions/download-artifact` (`v8`) for Node.js 24, and added `libmpv-dev` + `mpv` to Linux CI dependencies for `media_kit_video`.

## [1.2.49]

### Synced Video/Audio, Neural Speech Tracking, XPIKAN Source Localization & Core Reliability Fixes

- **Timestamp-Synced Multi-Video & Audio Playback:** Added a floating/dockable **Video / Audio** panel (`media_kit` + `media_kit_video`) that aligns single or multiple video/audio files to the EEG timeline via metadata (`creation_time`, `.vmrk` New Segment timestamp) or filename patterns, extracts mono audio from video via `ffmpeg`, and plots the audio waveform + speech envelope with a time-locked cursor synced to the EEG viewer.
- **Neural Speech Tracking (TRF & Stimulus Reconstruction):** Added `speech_tracking` in the Rust engine computing per-channel lag cross-correlation, 5-fold cross-validated forward **Temporal Response Function (TRF)** ridge encoding (`r`), delta/theta coherence, and multi-channel **backward stimulus-reconstruction decoding**.
- **IAF, Individual Bands & Frequency Sliding:** Added Individual Alpha Frequency (`IAF_Hz`), Klimesch Individual Theta/Alpha power (`IndTheta_PSD`, `IndAlpha_PSD`), and Cohen-style Hilbert **Frequency Sliding** (`Theta_FreqSliding_Hz`, `Alpha_FreqSliding_Hz`) to Rust PSD feature extraction.
- **XPIKAN Physics-Informed Source Localization:** Added **XPIKAN** (*Extended Physics-Informed Kolmogorov–Arnold Network*) in `source_loc.rs` alongside MNE, dSPM, sLORETA, and LCMV, minimizing forward leadfield physics residuals with multi-scale KAN spline modulation and sLORETA depth standardization.
- **Bad Channel Detection & Manual Batch/Single Rejection:** Upgraded `detect_bad_channels_configured` to evaluate flatline, robust log-variance MAD z-score, and spatial correlation across channels, and added an interactive **Bad Channel Table (Auto & Manual)** with chip toggles and batch comma-separated rejection.
- **Windows Preprocessing Cache & Stage Persistence Fixes:** Fixed Windows `session.json` and Rust `PrefixCache` checkpoint atomic replacement (`write_checkpoint`), normalized Windows cache paths and `LOCALAPPDATA`/`APPDATA` fallback roots, and ensured `manual_bad_channels` is included in cache identity.
- **EEG Time Axis Modes:** Added selectable `Time: Elapsed (s) | HH:MM:SS | Clock | Epoch` formatting in `EegViewer`.
- **Interactive Crop Bad-Segment Marking & EDF Scaling Fix:** Added interactive drag-to-mark bad segments inside `RecordingPreparationDialog`, auto-selected the cropped recording for downstream steps, and upgraded `_writeEdf` to per-channel asymmetric `[min, max]` physical bounds with last-sample padding (eliminating DC-offset waveform distortion).
- **Publication Parameter Logs, Batch Methodology Report & Microstate Sequence Exports:** Generated `preprocessing_parameters.json`, `feature_parameters.json`, `analysis_parameters_log.md`, and `batch_methodology_and_results_report.md`, plus dedicated per-file/per-epoch `<stem>_microstate_sequence.csv` exports.

## [1.2.48]

### All-States Dynamics Comparison, Batch Step Toggles & CI Node 24 Upgrade

- **State Dynamics All-States Comparison:** Added a side-by-side **Compare All States** view in **State Feature Mapping** so all pooled states are shown together on one page with shared metric rows, clickable state cards, and the active state highlighted (`ACTIVE`).
- **Intuitive Batch Preprocessing Step Toggles:** Replaced the disabled `Apply` button inside Batch Stage 1 preprocessing step cards with interactive **Checkbox + Switch** toggles (`Included` / `Skipped`) directly on each card header (`Resample`, `Bandpass + notch filter`, `Detect bad channels`, `ICA / ICLabel`, `Muscle / motion cleaning`, `ASR on output`, `GEDAI`, `Bad channel interpolation`, `Re-reference`).
- **GitHub Actions Node 24 Support:** Upgraded `actions/upload-artifact` (`v4` → `v7`) and `actions/download-artifact` (`v4` → `v8`) in `.github/workflows/build.yml` to eliminate Node.js 20 deprecation warnings.
- **Updated Documentation & Screenshots:** Incorporated all updated and newly added screenshots (`eeg_feature_plots.png`, `batch_progress.png`, `erpimage.png`, `erp_butterflyplot.png`, `erp_topo.png`, `ersp_itc.png`, `erp_regression_ml.png`, `erp_measurements.png`) into `README.md`.

## [1.2.47]

### Streamlined Epochs & ERP Suite, Rust XDF Import & Linked Topoplots

- **Rust-Accelerated XDF Import & Exact Nominal Sampling Rate:** Ported XDF loading (`inspect_xdf`) to the native Rust engine (`ccs_eeg_engine`) with binary `f32` channel streaming to Dart (loading 40 MB / 35-ch XDF files in ~220 ms, with an optimized `Isolate.run` Dart fallback). Both Rust and Dart XDF loaders now snap effective LSL clock rates within `0.5%` of `nominal_srate` back to the exact nominal rate (e.g. `250.0 Hz` instead of `250.0009988 Hz`), preventing downstream EDF/preprocessing sampling-rate failures.
- **CCSEEG Fallback & Unlocated Non-EEG Channel Guard:** Automatically falls back to `.ccseeg` when an EDF header cannot represent a non-integer or irregular sampling rate cleanly. Added automatic detection of channels lacking 10–20/10–05 scalp coordinates (e.g. `X`, `Y`, `Z` motion/aux channels) with an on-open prompt and inline Step 1 warning + one-click removal button before preprocessing.
- **Coordinated 3-Step Epochs & ERP Workspace:** Redesigned `Epochs & ERP` around a unified 3-step sidebar (**1. Define ERP Protocol** with interactive epoch shades on the continuous EEG plot, **2. Epoch Review & Analysis**, **3. Measurements, Plots & Save**) and a single top view switcher (`ERPimage | Distributed | Butterfly | ERP & Topo | ERSP & ITC | rERP & ML | Measurements`) sharing one accepted-trial set, active electrode, and measurement window.
- **Upgraded ERPimage & Event Group Clarity:** Upgraded `ErpImagePanel` to an EEGLAB-style RdBu diverging heatmap (`Smooth: 1/3/5/10 trials`), right-side `µV` colorbar, `#trial` Y-axis ticks, inline `Group` selector (`Both` / individual conditions), left-gutter condition color strips with horizontal block dividers, and an inline `Topo ms` window linked to the main measurement window.
- **Butterfly Plot Alignment & Separate GFP Strip:** Highlighted only the single selected electrode in red on `ErpButterflyPainter`, moved **Global Field Power (GFP)** into its own dedicated lower strip with its own Y-axis, and aligned horizontal time axes (`-200 .. 0 .. 800 ms`) vertically with `Live ERP Preview`.
- **ERSP/ITC Linked Topoplots, Consolidated Tabs & Channel Algebra Fix:** Added interactive time–frequency ROI inputs (`Start ms`, `End ms`, `Min Hz`, `Max Hz`) in **ERSP & ITC** synced to the scalp topographies, consolidated the ERP suite from 10 tabs to 5 (`ERP & Topo`, `ERPimage`, `ERSP & ITC`, `rERP & ML`, `Measurements & Export`), increased vertical space for the `Distributed` all-epochs viewer, and fixed **Custom Channel Algebra** (`N2pc`, `LRP`, `Custom Ch A − Ch B`) to read `channel_a` and `channel_b` waveforms properly.

## [1.2.46]

### Unified Epoch Selection, Scalp Topoplots & Butterfly/ERPimage Fixes

- **Common Epoch Selection:** Removed the separate per-tab trial exclusion state in **ERSP & ITC** so **ERP**, **ERPimage**, **rERP**, **ML Decoding**, **ERSP**, and **ITC** all operate on the exact same accepted epochs from **Trial Review & ERPimage**, with a 1-click **Modify in Trial Review** link.
- **Interconnected ERP Tabs:** Added **ERPimage** directly inside **ERP Analysis & Measurements** next to **Waveforms (ERP)**, **Models (rERP)**, **Decoding (ML)**, and **ERSP & ITC**, with synchronized active channel and measurement window selection.
- **Scalp Topoplots Across All Modules:** Added all-channel **ERSP (dB)** and **ITC (0–1)** scalp topographies in Rust (`ersp_itc`) and UI, **ERPimage** window-mean topoplot, **rERP** beta topoplot, and **ML Decoding** spatial activation pattern (`channel_patterns`) topoplot at Peak AUC.
- **Butterfly Plot & ERPimage Fixes:** Fixed `_extractButterflyChannelWaves` and rERP's Conventional ERP overlay to read `channel_a`, `channel_b`, and `channel_difference` from `erp_results.ccserp`, and fixed `ErpImagePanel` to repaint immediately when changing sort order.

## [1.2.45]

### ERP Analysis Overhaul, Time-Frequency (ERSP/ITC) & Topoplot Selection

- **Recording Tab Carry-Over & Streamlined ERP Modes:** Switching between `raw`, `clean`, and `interactive preview` stays synchronized across modules (`keepModule: true`) and provides a direct recording switcher inside `Epochs & ERP`. Consolidated redundant ERP views into two clear modes (`Trial Review & ERPimage` and `ERP Analysis & Measurements`) with Blue/Red condition coding and a Difference (`B − A`) trace.
- **Interactive Measurement Window & Butterfly Plot:** Click and drag horizontally on the ERP waveform plot to define the measurement window in ms, and toggle the **Butterfly Plot** overlaying all scalp channels alongside Global Field Power (GFP) and the highlighted ROI/channel.
- **Select Channels from Topoplot:** Added interactive 2D scalp topoplot pickers in the ERP Waveform header, Multi-Channel Waveform Grid (`ErpChannelGrid`), and Trial Review (`InteractiveErpWorkspace`) to select or toggle electrodes directly from the head map.
- **Baseline Correction & Interactive ERPimage:** Apply interactive `[start, end] ms` baseline correction across epochs and inspect single trials in a sortable **ERPimage** heatmap (`chronological`, `meanAmplitude`, `peakAmplitude`) with click/drag trial rejection and reinstatement.
- **Guided rERP Builder & Channel Math:** Guided rERP / Unfold overlap-correction builder in `Models` with visual overlay against Conventional Average ERP, plus intuitive **Channel Manipulations** (`N2pc`, `LRP`, `Contra − Ipsi`, and custom `Ch A − Ch B`).
- **Within-Subject Permutation & eTFCE Statistics:** Run cluster permutation tests across waveform time points and eTFCE across scalp electrodes directly in the Rust engine, surfacing significance masks on the ERP waveform and topography.
- **Guided ML Decoding & Time-Frequency (ERSP / ITC):** Added a 1-click Shrinkage LDA decoding card with Peak AUC, Peak Latency, and temporal generalization matrix, plus parallelized Morlet wavelet **ERSP (dB)** and **ITC (0–1)** panels with permutation masking, interactive trial rejection/reinstatement, and CSV export.

### Bug Fixes & Polish

- **Preprocessing Filter Disabling (Windows/All Platforms):** Leaving the High-pass, Low-pass, or Notch filter box empty now sets the cutoff to `0.0` (disabled) instead of reverting to the previous value, and fixes a live viewer divide-by-zero when Low-pass is disabled.
- **Formatted In-App Release Notes:** Rendered GitHub release notes inside the update dialog with structured Markdown headings, bullet lists, bold text, and inline code formatting.

## [1.2.44]

### Streamlined interactive ERP workflow

- **Windows review persistence:** atomically finish saving the small trial-decision file before closing the review widget, preventing a lingering file lock or unfinished last decision.

- **One Epochs & ERP workspace:** collapsible protocol, trial-review and averaging bars replace the overlapping tabs. Browse individual trials, exclude/reinstate them, and see condition averages update immediately with retained trial timing and annotations.
- **Inline ERP measurements:** keep measurements and models inside the main application workspace. Accepted trials are passed through automatically using a cached portable recording; no Save dialog, second file selection or repeated condition assignment is required. Return to trial review or live averages without a separate window.
- **Correct named-condition handoff:** use actual accepted epoch labels instead of matching them against original event codes. Preserve ERP-CORE contrast order even when the first recorded trial belongs to the other condition. Fix false zero-matching-epoch warnings for reviewed P3 data.
- **Preprocessing finalisation:** export the exact displayed cached samples as the analysis copy without repeating filtering, ICA, ASR or GEDAI. Following modules use that saved copy explicitly. Remember the finalised handoff per cached combination and restore it on reopening.
- **Persistent, reversible review:** save trial exclusion decisions locally; accepted-epoch exports preserve labels, source onsets, annotations and review provenance. Keep epoch-first cleaning and the standalone advanced workbench available.
- **Clearer ERP display:** start at the task's measurement channel where available, use a fixed range based on the initial condition averages, and remove redundant trial-navigation sliders from the single-trial viewer.
- Automatically reuse completed measurements for an unchanged review; export measurement tables and reports with a dedicated action.

## [1.2.42]

### Unified epoch / ERP review and explicit preprocessing handoff

- Combine the overlapping Epochs and ERP navigation into one **Epochs & ERP** workspace. Collapsed bars hold shared ERP-CORE/custom protocol settings, epoch review, and averaging/export.
- Browse individual trials and condition groups, exclude or reinstate trials without deleting original samples, and immediately update descriptive condition averages. Keep a live ERP panel visible while browsing epochs.
- Save review decisions beside the input under `.ccs_eegstudio_cache/erp_review/` (with a user-configuration fallback). Export accepted trials with labels, original timing, annotations and rejection provenance for advanced measurements and models.
- **Finalise preprocessing** exports the exact displayed cached signal instead of rerunning the cleaners. Configured runs also use the interactive cache. Downstream modules prompt for finalisation and use the saved analysis copy explicitly.
- Remember the finalised copy for each cached combination and restore its handoff on reopening or returning to that combination. Changing the applied signal requires a new finalisation.
- Retain the epoch-first cleaning option and the advanced ERP workbench / saved-results access.

## [1.2.41]

### Recording save and source-feature plotting fixes

- **Mac recording saves:** replace the native Save sheet with an in-app filename and output-folder form. Browse folders or enter the path, validate filenames, and confirm before replacing an existing recording. Processing starts after the dialog closes.
- **Source-feature plots:** route atlas ROI labels to labelled regional traces and a ROI-by-time feature heatmap instead of electrode interpolation. Display these figures in the interactive Plots & Report workspace, with PNG/PDF export, and support automatic and batch plotting.
- Keep all source regions, show a shared feature-value heatmap scale, label individually scaled regional traces, and exclude timing/settings metadata from feature figures.
- Includes all interactive preprocessing, ICA review, GEDAI corrections and linked source-analysis improvements from v1.2.40.

## [1.2.40]

### Interactive preprocessing, retained ICA review and linked source analysis

- **Interactive preprocessing:** separate collapsed bars for resampling, filters, channel detection, ICA/ICLabel, muscle cleaning, output ASR, GEDAI, interpolation and reference. Apply, disable or update steps in any click order while retaining the scientific processing order. Save the exact displayed combination separately from a full configured pipeline run.
- **Persistent per-recording cache:** completed combinations and lossless intermediate stages survive closing and reopening a file. Reuse unchanged upstream stages, including ICA. Ignore equivalent numeric settings, inactive parameters and ineffective resampling when deciding whether to recompute. Invalidate stale results when source content, metadata or relevant processing changes. Open the exact cache folder from the panel; use an application-support fallback for read-only inputs.
- **ICA review:** retain both decomposition stages, scalp weights, component traces over the full recording, ICLabel probabilities, removal decisions, actual threshold criteria and stopping limits. Navigate time windows and individual saved trials. Report blink detection separately from components actually removed, and offer an explicit lower-threshold comparison without changing the global threshold default.
- **GEDAI alpha-preservation correction:** use the reference implementation's gentle broadband pass and nine-level wavelet decomposition, improve threshold search across flat objective regions, and restore the incoming reference before applying the requested output reference. Report matched-reference 8–13 Hz power retention. Refresh older GEDAI caches while reusing compatible upstream stages. **GEDAI outputs can change after this update; review regenerated results before continuing an existing analysis.**
- **Source analysis:** apply and cache inverse projections, switch channel/ROI waveforms instantly, and inspect scalp topoplots or sagittal/coronal/axial template glass-brain views with Desikan–Killiany ROI outlines. Match colours across ROI outlines, labels and waveforms. Source previews use lossless CCSEEG storage independently of the selected export format.
- **Waveform-first layout:** move linked head plots, ROI selection and model controls into the Source analysis side panel. Use one waveform timeline/cursor instead of an independent map slider. Support point, mean and RMS window summaries without crossing trial boundaries.
- **Honest amplitude comparison:** label scalp µV and source model amplitudes separately. Offer standardized, dimensionless z-score patterns with the same fixed colour scale and palette across channel/source maps; retain original waveform units. Keep native-unit colour ranges stable while navigating a recording/trial.
- **Reference selection:** searchable existing-channel picker with linked-electrode support and visible selected chips. Only retained EEG electrodes are offered; retain auxiliary reference electrodes in Channel setup when required.
- **Windows cache regression coverage:** compare canonical file identities rather than slash spelling when validating reuse of saved combinations.
- **Viewer fixes:** reset raw/processed display state when changing recordings, preserve linked cursor timing across channel/source switches, provide readable ROI label gutters, and defer selection callbacks until after widget updates.

### Upgrade notes

- Cache folders are beside the input under `.ccs_eegstudio_cache/`, independent of the export folder; the panel shows their exact location. Cache files contain recording samples and may use substantial disk space.
- Older ICA results that retained only a short trace need one fresh ICA run to populate full-recording review and exact criteria.
- Glass-brain geometry is the bundled fsaverage/aparc **template**, not participant-specific MRI. Custom-atlas waveforms remain available when custom geometry has not been supplied. Scalp voltages and inverse-model amplitudes are different quantities; z-score mode compares patterns rather than physical units.
- Includes macOS, Windows and Linux installers plus SHA-256 checksums through the desktop release workflow.

## [1.2.38]

### Uniform 4-stage batch workspace across EEG, ERP & Microstates, Stage 1 preprocessing & state dynamics alignment

- **Uniform 4-stage batch workspace architecture**:
  - Unified **Continuous EEG**, **ERP Analysis**, and **Microstates** batch workspaces under the standardized 4-stage pipeline layout.
  - Standardized the top workspace controls across all three modules: persistent batch queue status bar, one-click full pipeline execution, global output directory configuration, `Already preprocessed` fast-path switch, `Skip already processed files` resume switch, folder import subject limit, and responsive `Tabs` vs. `Columns` multi-stage layout switch.
  - Consistent visual hierarchy with responsive color-coded stage cards: Stage 1 (Purple), Stage 2 (Green), Stage 3 (Amber), and Stage 4 (Blue), with forward stage navigation (`Next stage →` / `← Previous stage`).
- **Stage 1 Preprocessing integration for ERP & Microstates**:
  - Integrated full Stage 1 Preprocessing capability directly into the **ERP** and **Microstates** batch workspaces.
  - Users can now perform channel montage mapping, 0.1–30.0 Hz zero-phase bandpass filtering, GEDAI ocular/muscle artifact cleaning, and bad channel detection before feeding cleaned recordings directly into ERP epoching or microstate clustering.
  - Added optional stage chaining toggle (`Use Stage 1 outputs (or choose recordings directly)`) and standalone single-stage execution (`Run Preprocessing Only`).
- **State dynamics timeline alignment & duration precision**:
  - Re-engineered CSV parser in the Rust engine (`bridge/src/state_dynamics.rs`) with RFC 4180-compliant quote and escape handling, preventing commas embedded in JSON event markers and connectivity metadata from corrupting column alignment.
  - Resolved session duration discrepancies by calculating recording time from true epoch boundaries (`rec.t_end.last()`) rather than synthetic window counts.
  - Aligned the interactive timeline panels in `StateDynamicsView` 1:1 with `TopoFigure` waveform columns (`alignedFigureWidth` and `alignedPanelSpans`), ensuring multi-session comparison plots remain perfectly synchronized across continuous time.
- **State dynamics visualization & event marker opacity**:
  - Merged contiguous same-state time intervals into unified segments in both `TopoFigure` state strips and `StateDynamicsView`, completely eliminating solid white-out borders on short recording sessions.
  - Added customizable event marker opacity controls (`Off`, `15%`, `30%`, `50%`, `80%`, `100%`) and an event labels toggle across the Plots & Report toolbar, sidebar style panel, and State Dynamics control bar.
  - Implemented sub-pixel horizontal deduplication and collision avoidance for event marker lines and text annotations, allowing dense event bursts (such as 1,000+ MMN markers) to remain translucent behind waveforms without obscuring raw EEG traces.

## [1.2.37]

### ERP Batch Workspace modular redesign, ERP-CORE presets, multi-condition topographies & plot fixes

- **Modular ERP Batch Workspace pipeline**:
  - Re-architected ERP Batch Workspace to align with the Continuous EEG Batch Workspace, featuring a clean top pipeline stage selector (`ERP BATCH PIPELINE`: `All Stages`, `Stage 1: Recordings`, `Stage 2: Task & Markers`, `Stage 3: Windows & Models`, `Stage 4: Run & Export`).
  - Completely un-crowded the UI layout, organizing controls into responsive focused stages with clear forward guidance.
- **ERP-CORE paradigm presets & marker scheme support**:
  - Added native ERP-CORE paradigm preset selectors (`Auto-detect`, `P3`, `MMN`, `N170`, `N2pc`, `N400`, `ERN`, `LRP`, `Custom`) configured with exact event code schemes, ROI electrodes, component windows, baseline intervals, and polarities.
  - Fixed paradigm profile clobbering bug where inspection inadvertently restored stale single-recording custom options (`Rare`/`Freq`, `-500 to 1200 ms`), ensuring auto-detected ERP-CORE tasks run with verified protocol parameters.
  - Fixed participant ID extraction for numeric ERP-CORE datasets (`1_P3_cleaned.edf`, `10_P3_cleaned.edf` correctly recognized as `Subj 1` and `Subj 10` rather than stripping the index).
  - Added preceding stimulus-to-response pairing (`11, 12, 21, 22` -> response within `200–1000 ms`) for response-locked `ERN` and `LRP` paradigms to filter out pre-stimulus button presses.
- **Streamlined recording browser & identity card**:
  - Replaced crowded two-row button/tab header with a single structured control bar displaying active Task, prominent Recording Selector dropdown (`★ Grand Average` or `#i: Subject · Session — filename.edf`), `< Prev / Next >` buttons, and compact `Groups & Models` / `Load / Add` menus.
  - Added an **Active Recording Identity Card** prominently displaying recording index, Subject, Session/Task, exact filename, and accepted trial counts per condition.
- **Integrated waveforms, channel selection & multi-condition topographies**:
  - Added single-row primary plot channel selector toolbar with quick chips (`Task ROI`, `Fz`, `FCz`, `Cz`, `CPz`, `Pz`, `Oz`, `PO7`, `PO8`, `C3`, `C4`, or any channel via dropdown) alongside `Negative up`, `Smoothing`, and collapsible `Axis limits`.
  - Added side-by-side component-window scalp topographies displaying **Condition A**, **Condition B** (on a shared symmetric amplitude scale), and **Difference (`B − A`)** with max-$|t|$-corrected $p \le .05$ permutation significance rings.
  - Redesigned multi-channel electrode grid with quick anatomical region presets (`Task ROI`, `Midline`, `Frontal`, `Central`, `Parieto-Occipital`, `All`, `Clear`) and interactive channel toggle chips.
- **Plots & Reports grouping and clearing enhancements**:
  - Enabled arbitrary multi-file selection across folders without auto-pulling sibling files or splitting groups.
  - Added `Clear all files` button and individual file removal (`✕`) chips to easily manage comparison groups.
- **Batch plot PDF crash fix**:
  - Resolved fatal crash during batch PDF generation after nonlinear feature plotting (`lziv_nonlinear`).
  - Cleaned and truncated long session table headers to prevent landscape A4 table width overflow in PDF generation.
- **State dynamics feature mapping synchronization**:
  - Synchronized stable-state segmentation timeline with State Feature Mapping, supporting interactive state inspection and multi-scale stage analysis.

## [1.2.36]

### State dynamics port, multi-file ERP loading & non-overwriting outputs

- **State dynamics analysis & interactive visualization**:
  - Full Rust port of State Dynamics approach (`bridge/src/state_dynamics.rs`) based on *Scientific Reports* (`s41598-026-45893-4`) with exact numerical parity on Gyudmed Monastery recordings (135 stages, identical silhouette scores and state distributions across recordings).
  - Integrated into Plots & Reports: stable-state segmentation timeline with band PSD mean $\pm$ CI95, Fz trajectory, task event markers, categorical state strips, and multi-scale boundary rasters.
  - Interactive Feature Mapping heatmap with clickable states, Bonferroni-corrected Mann-Whitney significance dots, and dynamic feature family filtering (`All`, `PSD`, `Ratio`, `Coh`, `MIC`, `FOOOF_band`, `FOOOF_param`, `IRASA_band`, `IRASA_param`, `Nonlinear`, `ACW`).
- **Non-overwriting ERP output naming**:
  - Individual ERP analyses now automatically save with clean recording-stem prefixes (`<stem>_erp_results.ccserp`, `<stem>_erp_measurements.csv`, `<stem>_erp_waveforms.csv`, `<stem>_erp_report.pdf`, etc.) alongside canonical names, completely preventing accidental overwriting when running successive recordings in the same output directory.
  - Multi-recording batch runs preserve individual participant `.ccserp` files alongside the pooled batch results.
- **Direct & multi-file ERP loading and merging**:
  - Enabled multi-selection of `.ccserp` and `erp_results*.json` files in the workbench.
  - Added folder-based ERP result scanning and automatic composite grand-average merging (`mergeErpResults`), computing multi-participant pooled waveforms with $\pm 1$ SEM shading and full interactive batch review support.
  - Added direct action buttons in the ERP review toolbar, workbench sidebar, and the Open Recording start screen for instantaneous loading of saved ERP results and epoched EEG files.
- **ERP interactive workflow improvements**:
  - Interactive missing-condition alert banner in the ERP workbench with one-click removal/skip of empty protocol conditions.
  - Clear visual progress checkmarks across top workflow modules with automatic forward guidance after preprocessing.

## [1.2.35]

### GEDAI performance acceleration, pipeline persistence and batch resume

- **High-speed GEDAI Rust optimization**: Precomputed generalized eigenvalue inverse reconstruction with BLAS GEMM matrix operations, regularized diagonal covariance to eliminate non-converging QR eigensolver loops on rank-deficient/zero-variance noise, parallelized Brent optimization evaluations across CPU cores using Rayon, and subsampled reference template projection. Full GEDAI cleaning on real EDF recordings dropped from >15 minutes down to ~3-4 seconds.
- **EDF auxiliary channel protection**: Fixed division-by-zero when reading EDF files containing auxiliary or flat non-EEG channels where physical or digital min/max are identical (such as SpO2, Pulse, CO2Wave). Channels with zero or invalid range are safely zeroed out instead of generating NaNs.
- **Preprocessing pipeline save/load & auto-persistence**:
  - Automatically persist user preprocessing configurations across app restarts (`~/.config/ccs-eeg-studio/preprocessing_pipeline.json`).
  - Added dedicated **Save** and **Load** buttons in the Stage 1 Preprocessing card header to export and reuse `.ccspipeline` configuration files.
  - Automatically write `Preprocessing_Pipeline.json` into batch destination directories during batch runs to guarantee complete parameter provenance and scientific reproducibility.
- **Batch skip & resume**: Enabled one-click resume across batch stages (`Stage 1: Preprocessing`, `Stage 2: Feature Extraction`, and `Stage 3: Plots`). Existing cleaned recordings, feature CSVs, and plot PDFs in the output directory are automatically skipped when requested.
- **Robust recording deserialization**: Fixed type cast exceptions during `.ccseeg` and `.ccsmeta` loading by enforcing null-safe numeric casting across all channel sample lists and epoch onset metadata.
- **CI/CD workflow validation**: Fixed release note extraction and shell regex quoting in GitHub Actions build automation.

## [1.2.33]

### Pipeline sequence alignment and batch workspace redesign

- Strictly align preprocessing steps with the original MATLAB CCS pipeline (`accs_CCScleaningpipeline.m`): Channel mapping / montage setup -> Downsample -> Bandpass & notch filtering -> Bad channel detection -> Artifact cleaning (GEDAI, ICA/ICLabel, ASR) -> Spherical spline bad channel interpolation -> Re-referencing (final step before saving).
- Add global batch output directory container placed prominently outside stage cards, applicable to all batch processing stages with browse and reset options while preserving per-stage overrides.
- Redesign batch cards into a responsive tabbed view with step bar badges (`Stage 1: Preprocessing`, `Stage 2: Feature Extraction`, `Stage 3: Plots`, `Stage 4: Group Statistics`) and previous/next navigation for clearer visibility on smaller screens, with a toggle segmented button to switch between Tab and Column views.
- Link preprocessing epoching to feature extraction: when trials or fixed windows are defined in preprocessing, feature extraction locks primary epoch creation and restricts modification to trial subepoching within parent boundaries.
- Provide an interactive batch channel montage modal with preset configurations for LiveAmp 32 (10-20), ActiCAP 32 / BioSemi, standard 10-20 (19-ch), automatic prefix/suffix stripping, and `.ccschannels` profile save/load.

### Multi-condition ERP workbench and high-performance XDF loading

- Support multi-condition ERP analysis beyond two-group comparisons: event groups display actual condition names in plots and exported statistics tables instead of generic Group A/B labels.
- Correct peak latency calculation to identify the exact timepoint of maximal/minimal amplitude within the analysis window rather than reporting the window endpoint.
- Add group tagging directly from the ERP batch workbench UI to simplify publication-ready split and group comparison plots.
- Implement high-performance native Rust XDF streaming parser (`bridge/src/xdf_loader.rs`) with multi-stream detection, irregular timestamp resolution, and robust header parsing for LiveAmp, OpenBCI, and Neuropype recording setups.

## [1.2.32]

### Continuous cleaned output and independent analysis windows

- Correct the hidden preprocessing default that saved continuous inputs as 1-second trials using GEDAI's internal block length. New preprocessing now saves continuous cleaned EEG by default; feature extraction independently chooses analysis length and overlap.
- Move **Saved output** into a visible, expanded preprocessing section in single-recording and EEG batch workflows. Choose continuous, event-based or explicit fixed-length output. Fixed output has its own length (default 5 seconds) and overlap fields, separate from GEDAI's internal processing blocks.
- Clean continuous samples once before forming explicit fixed windows, including overlapping windows. Preserve annotation times and duplicate annotations into their corresponding overlapping windows. Existing saved trials retain their boundaries.
- Fix feature extraction on saved trials rejecting an unrelated continuous-window overlap setting. Reusing complete saved trials ignores that setting; continuous and newly subdivided windows retain strict overlap validation. The engine also guards this behavior for direct callers.

### Recovery and validation

- Existing 1-second files are not repaired by installing this release. Rerun preprocessing from the original continuous recordings into a new output folder, choose **Saved output → Continuous recording**, then select the desired epoch length and overlap in Feature Extraction. Do not reuse old `-epo_clean` files when the intention is to create longer analysis windows.
- Explicit fixed windows are optional; they deliberately create saved epochs. Existing trials can be subdivided within parent boundaries, but are not silently joined into longer recordings.
- Validate three complete supplied raw EDFs through 19-channel selection, filtering, resampling, common-average referencing, GEDAI, continuous EDF export and 5-second/2-second-overlap PSD extraction. The cleaned recordings contained 400,750, 338,500 and 326,000 samples at 250 Hz, producing the expected 533, 450 and 434 analysis windows with original marker counts retained.
- Add regression coverage for continuous output despite 1-second GEDAI blocks, explicit 5-second saved windows with 2-second overlap and annotation duplication, visible output controls, and native saved-trial overlap handling. Engine binary unit tests passed locally alongside the library and integration tests.

### In-app updates

Use **Updates → Check for updates → Download and install**. GitHub publishes macOS, Windows and Linux packages with SHA-256 checksums verified by the updater. Existing per-user Linux updates remain supported.

## [1.2.31]

### Batch channel correction and selection

- Add a batch EEG mapping editor with representative-file selection, arbitrary name editing, literal prefix/suffix removal, find/replace, source-name exclusions and reusable `.ccschannels` mappings.
- Apply selected and renamed EEG samples before preprocessing/referencing/ICA and to direct feature extraction; corrected output names remain usable in downstream stages. Preserve original source names, mapping history and annotation channel indices.
- Suggest EEG prefix/reference-suffix correction for compatible EDFs, excluding POL/auxiliary and A1/A2 references by default. Reject duplicate names or insufficient matches per file rather than silently incorporating unmatched channels.
- Validate real EDF selection across three source files, an EEG-only average-reference calculation, app regression tests and static analysis.

### Workflow and compatibility

- Open **Batch EEG channel mapping…** above the EEG stages or within Stage 1. Choose any queued representative file. Use arbitrary per-channel edits or literal prefix/suffix removal and find/replace (blank replacement removes text); leave fields blank or use source-name exclusions to omit channels.
- Review corrected names before applying. Save/load `.ccschannels` mappings for reuse. Already-corrected names are accepted when later stages consume cleaned outputs. Unknown/unmatched channels are excluded, duplicate corrected names are rejected, and files with fewer than four matching EEG channels fail with a clear message.
- Apply mapping only in the EEG batch paths. Keep source files unchanged, retain source names/history, and materialize selected samples before native jobs so original EDF headers cannot override the reviewed selection.
- Validation: 239 app tests passed (six skipped), clean static analysis, and three real EDFs with 39/43 channels resolved to the same 19 scalp EEG channels. A numerical common-average check used only those selected channels. This validates routing and referencing; it does not establish acquisition montage identity or validate every ICA/source result.

### Installation and in-app updates

Use **Updates → Check for updates → Download and install**. macOS, Windows and Linux packages include SHA-256 checksums verified by the app. Existing per-user Linux updates remain supported.

## [1.2.30]

### Microstate syntax and sample-level exports

- Add native Microsynt TER/EER/MER, entropy representation ratios, observed word counts and seeded dictionary discovery, with editable word length and an explicit legacy-window compatibility option.
- Export per-sample final labels, epoch/sample indices, original and fitting GFP, assigned squared-correlation fit and each state's absolute/relative fit percentages.
- Respect epoch boundaries in peak selection, smoothing, state durations, transitions and syntax. Add visible per-epoch channel DC subtraction for analysis, recorded in results; keep original GFP separately.
- Show loading, preparation, model/restart/iteration, sample backfit and output phases with elapsed time and Stop in the workspace centre as well as the controls. Stage JSON serialization/result decoding off the UI thread.
- Validate four complete supplied 15-second epochs (60,000 samples), paper worked examples and supplied Python-reference parity. Document sparse-dictionary limits and distinguish legacy sequence complexity from the paper's LZMA2 measure.

### Interpretation, compatibility and validation

- Sample fit means `100 × r²` for the final assigned state. Relative per-state fits are normalized squared correlations, not calibrated probabilities. Original µV GFP, post-DC-removal µV GFP and normalized unitless GFP have separate columns.
- Default syntax uses no-permanence sequences and includes the final valid word window, as in the paper. Enable legacy window counting to match the supplied `microsynt.py` off-by-one convention. Sparse dictionaries are flagged; dictionary discovery does not claim a cohort-level statistical optimum.
- Per-epoch channel DC removal is visible and defaults on for new analyses; its setting is stored in results. Source files remain unchanged. Older saved microstate results without syntax fields remain readable. Historical LZ/sequence complexity retains its previous convention and is not presented as the paper's LZMA2 measure.
- Four complete 63-channel, 15-second SET/FDT recordings were tested: 60,000 sample rows, correct assigned/per-state fits, normalized relative fits, epoch indices and monotonic progress. Single-recording analysis was also checked. Rust TER/EER/MER match the supplied Python reference to 1e-10 with the documented window convention.
- Local validation: 238 app tests passed (six skipped), 18 native library tests passed, and static analysis was clean. A reusable real-data validation tool and method/license documentation are included.

### Installation and in-app updates

Use **Updates → Check for updates → Download and install**. GitHub provides macOS, Windows and Linux packages with SHA-256 checksums verified by the app. Existing per-user Linux installations continue to update without sudo.

## [1.2.29]

### Compact workflow and preprocessing organization

- Replace the full-height workflow sidebar with a compact horizontal step bar, restoring waveform width. Scroll the bar on narrow windows; select any step to return to its settings.
- Keep the ERP clean-first/epoch-first selector beside the steps. Step order updates immediately and existing settings remain in memory when navigating.
- Remove the duplicate preprocessing form from Advanced settings. Primary signal and artifact controls remain in their dedicated sections; protocols and additional processing parameters stay accessible without repeating those controls.
- Retain non-ERP continuous/event/fixed output structure and fixed-window overlap settings. Existing saved trials retain their boundaries.
- Update navigation regression tests to check horizontal ordering. Existing analysis methods and recording formats are unchanged.

### In-app updates

Install using **Updates → Check for updates → Download and install**. macOS, Windows and Linux packages include SHA-256 checksums verified by the updater. Existing per-user Linux updates remain supported.

## [1.2.28]

### Faster saving and clearer ERP displays

- Buffer native JSON transfer writes (1 MiB) and borrow signal arrays rather than cloning them for serialization. Preserve the existing portable recording schema and samples. A local 100,000-sample comparison measured 285 ms for the previous unbuffered writer versus 2.6 ms buffered; this is a serialization microbenchmark, not an end-to-end processing speed claim.
- Record within-trial reflection as an ICA method note rather than a processing failure warning, including compatible interpretation of older history. Actual skipped-step and cleaning warnings remain visible.
- Show named conditions instead of Group A/B on condition cards and remove duplicate A/B aliases from the on-screen measurement table. Label the retained difference with the two condition names. Update readiness text after editing conditions.
- Apply display smoothing to every named-condition waveform, fixing three-or-more-condition plots. Preserve unsmoothed analysis measurements.
- Replace fixed interaction-plot amplitude limits with a shared data/SEM range, including negative amplitudes. Missing observations are omitted instead of plotted as zero; repeated recordings are averaged within participant before SEM.
- Start publication figures from the active component/window, use an All participants group when labels are absent, keep unlabelled participants separate when labels are partially assigned, separate legends/headings, clip traces to axes and allow horizontal scrolling of figures and controls. Interaction SVG export uses the same measurements and range.
- Validation: full app suite 237 passed, six skipped; native engine/epoch checks passed; portable serialization round-trip and benchmark passed; Data_v2 interaction figure rendered and inspected. A repeated 12-trial ICA run completed with zero warnings and retained the reflection explanation under method notes.

### Installation and compatibility

Open **Updates → Check for updates → Download and install**. The app selects the macOS, Windows or Linux package and verifies its published SHA-256 checksum. Per-user Linux installations continue to update without sudo.

EDF+ remains the default recording output, with its `.ccsmeta` companion retained. Existing FIF, CCSEEG and legacy JSON inputs remain supported. This release preserves the portable recording schema and measurement CSV aliases; the on-screen table hides redundant A/B rows. Smoothing remains a display operation and does not change exported analysis measurements.

## [1.2.27]

### Saved-trial ERP workflow and preprocessing

- Repair ICA blink filtering for short saved trials using reflection within each trial, preserving sample timing and boundaries. Reuse filter coefficients across trials; retain the existing long-recording filter path.
- Separate compact signal preparation and artifact-cleaning controls. Distinguish ASR used only on the ICA training copy from standalone ASR applied to continuous output; show the selected cleaning sequence.
- Show elapsed processing time, ICA pass/iteration details and monotonic progress; reach completion only after export finishes. Retain the stop control.
- Recover missing saved-trial time zero from recorded parent epoch protocols; preserve it during further preprocessing and export. Do not infer timing from filenames or assign epoch timing to continuous recordings.
- Suggest actual saved condition groups instead of empty preset groups. Add explicit condition ordering, compact group selectors and readable preparation history with processing warnings. Carry input cleaning warnings into ERP results and reports.
- Normalize recording-save names before the native dialog to avoid repeated extensions. Preserve legacy recording and metadata loading.
- Correct named-condition trial counts in ERP measurement CSVs and quote condition labels safely. Existing A/B/contrast aliases remain compatible.
- Validate the complete 360-trial Sakshi Data_v2 file with the P300 example at Pz, 300–600 ms; validate ICA on a 12-trial, eight-channel subset at 1000 Hz and 250 Hz. See the Data_v2 walkthrough in the README.

### Outputs and compatibility

- EDF+ remains the default recording output. Keep its `.ccsmeta` companion beside the signal file; FIF and CCSEEG options and legacy JSON inputs remain supported.
- Existing saved epochs are reused without epoching again. The UI separates selecting saved condition groups from defining event codes for continuous recordings.
- Existing ICA-skip warnings in older files remain visible; this release does not retroactively clean their samples. Re-run cleaning if required.
- ERP measurement CSVs retain named conditions and legacy A/B/B_minus_A aliases. Select one representation for statistical input to avoid counting the same observations twice.

### Validation and scope

- Full Flutter suite: 234 passed, six skipped. Static analysis: no issues.
- Native engine library: 14 tests passed; ERP parity: 12 passed; ICA library: 10 passed. Includes all seven ERP tasks reusing saved trials and correct named-condition counts.
- Real Data_v2 validation: 61 channels, 360 saved trials, Pz, 300–600 ms, baseline −200–0 ms, original −500–1200 ms trial window; Standard 280, Pleasant 40 and Neurtral 40. Waveforms, measurements and a two-page PDF generated successfully. One participant is descriptive only.
- Short-trial ICA validated separately on 12 complete trials and eight scalp channels at both 1000 Hz and 250 Hz. This is not a claim of full 61-channel ICA validation or identical reflected-edge behavior to other toolboxes.

### Installation and in-app updates

Open **Updates → Check for updates** to download and install v1.2.27. GitHub publishes macOS, Windows and Linux packages with `SHA256SUMS.txt`; the app verifies the selected package before installation. Existing per-user Linux installations continue to update without sudo.

## [1.2.26]

- Supersede the unpublished v1.2.24/v1.2.25 builds after Windows tests exposed that forcibly killing an isolate can skip file-closing finally blocks. Use cooperative XDF cancellation checkpoints, allow decoder cleanup to finish, and await worker exit before returning. Other readers finish their current decoding phase before reporting cancellation. Add a Windows loading/epoch-worker preflight before desktop compilation.


### Epoch creation and compact condition editing

- Fix event epoch creation failing with an unsendable WidgetsFlutterBinding/isolate-message error. Pass only recording samples, event data and epoch options through a top-level worker boundary; do not capture widget State.
- Simplify the dedicated Epochs dialog: show named conditions and their codes, clear event-relative start/end fields and baseline settings. Hide the redundant enable checkbox and collapse raw-code selection, response rules, advanced matching and recording-range limits.
- Hide system markers from normal condition choices, remove stale condition-name entries from the code picker, and deselect codes when a compact condition group is deleted. Preserve original event annotations in the saved trials.

### Flexible ERP preparation order

- Add **ERP preparation order** in the workflow sidebar: **Clean → Epoch** or **Epoch → Clean**. Reorder the sidebar and overview to match; both routes use the same event-group and trial-window protocol.
- Route newly saved epochs to Preprocess when epoch-first is chosen, and cleaned saved epochs directly to ERP averaging. Keep an explicit skip-cleaning route for already preprocessed trials. The preprocessing panel identifies the active trials rather than showing their continuous parent.
- Save the preparation-order choice in reusable ERP protocols. Older protocols retain clean-first behavior. Internal GEDAI cleaning windows remain distinct from saved event trials; standalone ASR still requires continuous input.

### Clearer recording-to-ERP workflow

- Rename Load Raw to **Open Recording** to clarify that raw signals, preprocessed continuous signals and saved epochs are accepted.
- Add a separate **Epochs** stage to the ERP and Full Pipeline sidebars. The ERP sequence is Open Recording → optional Preprocess → Epochs → ERP Analysis.
- In the single-recording ERP profile, preprocessing preserves continuous input as continuous data. Event-group definitions and trial windows remain available for the subsequent Epochs step; saved trials keep their boundaries when cleaned.
- Add **Next: Epochs (skip cleaning)** for already preprocessed data. The Epochs step explains locking events, named condition groups, trial/baseline windows, reusable protocols and the handoff to averaging.
- Add **Open preprocessed EEG / saved epochs…** directly in ERP Analysis. Existing epochs proceed to condition averaging without re-epoching; continuous recordings link to the Epochs step.
- Move event-trial construction off the UI isolate and preserve legacy combined preprocessing/epoching behavior outside the single-recording ERP profile.

### XDF signal and marker import

- Add a chunked Dart XDF importer requiring no Python installation. Support float32, double64, int8, int16, int32 and int64 numeric signal samples and string/numeric irregular event streams, including implicit timestamps.
- Offer explicit selection when a container has multiple numeric signal streams. Preserve channel names, normalize declared voltage units to µV, apply stream clock-offset interpolation, align markers to the corrected signal origin, and uniformly resample the selected signal using linear interpolation.
- Record selected stream, nominal rate, resampling and unit assumptions in provenance. Preprocessing and feature extraction stage XDF samples into the native engine's portable representation, retaining annotations.
- Reject malformed/truncated chunks, non-finite signals, clock resets, non-monotonic timestamps and gaps larger than five nominal sample intervals rather than silently shifting ERP events.
- Limitations: compressed .xdfz is not supported; unspecified channel units are assumed to be µV; specialist clock-reset/gap recovery is not implemented. This is a baseline importer, not full pyxdf recovery/dejittering parity. Verification used generated XDF fixtures; user-recording validation remains pending.

### Responsive loading and clearer file selection

- Display the installed version beside the app title.
- Run recording parsing in a cancellable isolate. **Cancel loading** requests a safe stop, including during startup. XDF checks between chunks and sample blocks; other readers finish their current decoding phase before cancellation returns. File handles close before another file is loaded.
- Show loading phases and XDF reading/alignment progress. Other readers use an indeterminate indicator when a meaningful percentage is unavailable.
- Hide settings, protocols, metadata and analysis results from recording selection. Label saved epochs, preprocessed signals and XDF containers with their likely next step; continue accepting legacy signal JSON and matching .ccsmeta companions.

### Validation and updates

- Validate the revised workflow and visible version with widget tests, recording identity/backward compatibility with loader tests, and XDF units, clocks, markers, all numeric sample formats, malformed data and cancellation with generated fixtures.
- Ship the standard macOS ZIP, Windows installer, Linux DEB/RPM and portable per-user Linux archive with SHA256SUMS.txt. Existing installations can use **Updates → Check for updates**; portable Linux updates remain available without sudo.

## [1.2.23]

### Independent app instances

- Make the toolbar launcher discoverable with a labeled **New instance** button and a tooltip explaining independent analyses and output folders.
- Launch macOS application bundles through Launch Services with `open -n`, explicitly requesting a separate process. Linux and Windows launch the current executable directly; Linux retains `G_APPLICATION_NON_UNIQUE` so desktop activation does not merge processes.
- Report launch failures in the activity log and a visible notification instead of leaving an unhandled asynchronous error.
- Each instance starts with its own recording and analysis state. Use different output folders for concurrent work; shared output files are not merged automatically. Per-user Linux updates continue to retain the release directories used by running processes.

### Release maintenance

- Align Flutter, Windows installer and native engine version metadata for reproducible desktop packaging.
- Include the multi-condition ERP, individual ERP gallery and publication plotting changes documented in 1.2.22.

- Fix administrator Linux updates failing with `curl: (23)` when a previous user owns the fixed package filename in `/tmp`. Package downloads and optional engine rebuilds now use a private temporary directory, cleaned on success or failure. The generated updater also cleans its downloaded installer. Existing updater commands fetch this fix from `main`; no application reinstall is needed.

## [1.2.22]

### Multi-condition ERP analysis and event group naming

- Support arbitrary multiple conditions ($K \ge 2$, e.g. Standard, Oddball, Distracter, Novel) in ERP analysis and interactive review instead of rigid two-condition A/B limits.
- Automatically serialize and display actual event group names across waveforms, channel grids, legends, hover readouts, measurement summary tables, and exported model CSVs (`Condition` column now records the condition group name).
- Maintain 100% backward compatibility for legacy 2-condition profiles and scripts (`a`, `b`, `difference`).

### Peak latency interior turning-point detection

- Fix peak latency returning window endpoints instead of the true peak timepoint. The interior turning-point algorithm isolates true local extrema where the first derivative crosses zero.
- If the waveform is monotonic or flat at the boundary, the solver falls back to an interior opposite-polarity deflection rather than pinning to the boundary edge. Verified across Dart and Rust test suites.

### Batch individual ERP browsing gallery

- Add a dedicated **Individual ERPs** gallery tab in batch results with live search and filter by Subject ID or assigned group.
- Each participant card renders mini sparkline ERP waveforms across conditions, accepted trial counts, group affiliation badges, and peak latency/amplitude callouts, with a one-click **Inspect →** button jumping directly into that participant's waveforms and channel grid.
- Add `[◀ Prev]` `Grand Average / Participant X of N` `[Next ▶]` stepper in the ERP results header to rapidly cycle through individual participants.

### Publication-friendly plots studio and group labeling

- Add an interactive **Publication plots** studio matching the journal aesthetic of cognitive ERP literature (Cahn & Polich 2009):
  - **Fig 1**: Grand-averaged waveform grid across midline electrodes (e.g. Fz, Cz, Pz) and conditions with group overlays, shaded SEM error bands, and N1/P2/P3a peak callouts.
  - **Fig 2**: Scalp topographic voltage maps grid (Groups $\times$ Conditions $\times$ Components) with scientific diverging colorbar and head outlines.
  - **Fig 3 & 5**: Interaction line plots of Component Mean Amplitude / Peak Latency across Electrodes and Conditions with SEM error bars.
- One-click export to **W3C Vector SVG** (infinite resolution for Adobe Illustrator/Inkscape) and **300 DPI High-Resolution PNG**.
- Add interactive `ErpGroupLabelDialog` to label participant cohorts directly from the UI after batch analysis, with automatic prefix guessing (e.g. `CTRL_` vs `MED_`), 50/50 split, manual assignment, and CSV export/import (`participant_groups.csv`).

### State-of-the-art statistics (eTFCE & LMM/GLM)

- Add full electrode-adjacency Threshold-Free Cluster Enhancement (`compute_etfce`) in `assets/group_stats.py` using Smith & Nichols (2009) and Mensen et al. (2013) parameters ($E=0.5, H=2.0$), 10-20 spherical scalp coordinate neighborhood adjacency graphs, and non-parametric subject permutation testing.
- Connect publication plots directly into the Linear Mixed Models (LMM), Repeated-Measures ANOVA, and eTFCE statistics engine via **Run LMM / GLM & eTFCE Stats**.

### Validation

- Full test suite passes cleanly, including `erp_review_test.dart`, `erp_workbench_parity.rs`, `unified_analysis_workflow_test.dart`, and `erp_workbench_test.dart`.
- Static analysis clean: `flutter analyze` reports 0 issues across the entire codebase.

## [1.2.21]

- Supersede the unpublished v1.2.20 build tag after correcting the Linux portable-package workflow.

### ERP display and preprocessing controls

- Add editable time-axis limits in milliseconds and amplitude-axis limits in µV to the ERP waveform and interactive batch review. Apply shared limits to electrode panels, validate ordered finite ranges, and reset either axis to Auto. These controls affect display only; trial data, baseline and measurement windows are unchanged.
- Show the actual trial duration in single-epoch waveform view instead of a stale continuous-window setting. Stitched/continuous view retains the selected time window. Short-epoch tick labels retain fractional seconds and reflect saved event-zero offsets.
- Expose output re-referencing directly in preprocessing: keep the current/cleaned reference, common average, or selected/linked reference electrodes. The native pipeline applies the chosen output reference after cleaning.

### Per-user Linux updates and concurrent instances

- Publish a portable Linux x86_64 `.tar.gz` bundle alongside DEB/RPM installers. The in-app updater prefers it and installs under the current user's XDG data directory without sudo or package-manager privileges.
- Install into versioned directories and atomically switch the per-user launcher. Preserve previous versions so other running instances continue using their existing binaries, libraries and assets. Add a per-user update lock, readiness/error checks and a desktop launcher override.
- Add `scripts/update_linux_nosudo.sh` for a one-time no-sudo bootstrap from an older system installation. It downloads the current tagged portable bundle, verifies `SHA256SUMS.txt`, and installs for the invoking user. Existing GTK/system runtime dependencies must already be available.
- Use unique temporary download directories per update and verify SHA-256 before launching installers (API digest or the matching tagged checksum file). No shared system directories are made world-writable.
- Add an Open another independent instance toolbar action. Linux already uses `G_APPLICATION_NON_UNIQUE`; native jobs use separate temporary workspaces. Use distinct output paths for concurrent analyses. `RAYON_NUM_THREADS` can bound each instance's CPU worker count on shared servers.
- GPU rendering is distinct from numerical acceleration. The scientific Rust engine remains CPU-based in this release; a compute backend requires the server GPU/driver/runtime details and parity validation. No unverified GPU acceleration is claimed.

### Validation

- Full local Flutter suite: 212 passed, 6 skipped; focused rootless installer and axis-control checks passed. Scientific GPU compute remains pending server-specific backend selection and validation.
- Includes the 1.2.19 BrainVision float32 calibration correction and all earlier recording format/ERP workflow improvements.
- Isolate group-statistics scripts, Matplotlib caches and copied-plot files in unique temporary directories, avoiding cross-account and cross-instance temporary-file collisions.
- Add ERP axis-control, epoch/stitched-window label, per-user installer, portable-asset selection and checksum-rejection tests.
- Exercise two successive rootless installs and verify the first version remains intact while the launcher selects the second.
- See [server installation, multiple instances and ERP display controls](https://github.com/CCS-NIMHANS/CCS_EEGStudio/blob/v1.2.21/docs/server_and_plot_controls.md).


## [1.2.19]

### Cross-platform output migration

- Match metadata source paths using platform-aware separator and case normalisation so Windows mixed-slash paths are updated with their renamed signal files. Validate the migration with an explicit mixed-separator regression case.
- Supersede the v1.2.17 and v1.2.18 build tags before publication; neither tag produced a published release.

### BrainVision amplitude calibration correction

- Correct the Flutter BrainVision `IEEE_FLOAT_32` loader to multiply every sample by its channel resolution, just as the integer and native Rust paths do. With a 0.0488281 µV resolution, the prior viewer/direct-export amplitude was about 20.48× too large.
- Convert V, mV and nV channel units to internal µV consistently in both Flutter and Rust loaders. Test float32, int16 and int32 in multiplexed and vectorized storage layouts.
- Validate the Pallavi Post recording against an independent MNE sample read. Native preprocessing directly from the original `.vhdr` already applied the resolution; do not assume all native outputs are affected. Direct epoch-only/crop exports created from incorrectly calibrated Flutter-loaded float samples may require regeneration. Previously exported files are not silently rescaled.

### Recording performance and processing feedback

- Move recording decoding and full-resolution display filtering off the Flutter UI isolate. Use typed buffers, reduce BrainVision/portable temporary copies, and pass existing portable files directly to native processing when possible.
- Show immediate loading feedback, progress activity and a visible Stop action. Stage native outputs before replacing a saved recording, and prevent restart races while cancellation completes.
- Report ICA iteration activity, reuse Infomax activation buffers and enable native thin LTO. Solver learning rules and convergence settings remain unchanged; Windows speed improvements have not yet been benchmarked.

### Recording formats and unambiguous filenames

- Add a persistent saved-recording format setting shared by preprocessing, crop/subepoch, source outputs and event epoching: **EDF+**, **FIF**, or **CCSEEG**. EDF+ is the default for fresh settings; an explicitly saved preference is retained.
- Write real binary EDF+ with per-channel 16-bit amplitude scaling and native float32 FIF for continuous and epoched recordings. Native CCSEEG retains its portable JSON contents under a dedicated `.ccseeg` extension; renaming is not compression.
- Store EDF/FIF application metadata in matching `.ccsmeta` companions. Preserve exact sample counts, padding information, original event timing, trial boundaries/labels, epoch zero, protocols and processing history. Keep the companion with its signal file. Fractional EDF rates use rational record durations; unsupported rates fail explicitly instead of changing the sample clock.
- Use distinct JSON-content extensions for reusable ERP protocols (`.ccsprotocol`), reopenable ERP results (`.ccserp`), native processing history (`.ccshistory`), legacy preparation history (`.ccspreparation`), and feature-analysis metadata (`.ccsanalysis`). Internal engine job files remain JSON.
- Accept legacy signal JSON, `.ccseeg.json`, protocol JSON, ERP-result JSON and old history companions. Hide non-recording metadata from signal pickers and strip repeated known signal extensions from new output names.
- Add **Settings → Organise legacy output filenames**: preview recognised renames, refuse collisions, update exact companion source-path references and retain a `.ccsmigration` manifest. Migration does not re-encode signal samples or rename raw vendor inputs. A dry-run/apply command-line tool is also included.

### Intuitive epoching and behavioral inclusion

- Replace independent output-epoch checkboxes with one **Saved data structure** choice: Continuous recording, Event-based trials (ERP), or Fixed-length windows. Event windows and fixed-window overlap settings remain separate.
- Increase waveform marker-line contrast while retaining event labels in their own lane.
- Group preprocessing parameters into collapsible Filter/notch, Bad channels/interpolation, GEDAI, Reference, ICA/ICLabel and ASR/muscle sections. Existing method icons open the corresponding section; ICA has its own parameter action.
- Persist response inclusion rules in reusable epoch/ERP protocols: all trials, correct-only, incorrect-only, or missed-only. Support explicit correct/incorrect feedback codes and stimulus-specific expected-button mappings such as `S20 = R1`, `S30 = R2`.
- Use the first recognised response inside the configured time window, stopping at the next selected stimulus. Unknown response codes are ignored; missing mappings are not guessed.

### Boundary-aware ICA and event timing

- Permit ICA to fit a shared decomposition across epoched data while retaining trial count, sample count, labels and event timing. High-pass filtering, blink detection and blink-training selections respect trial boundaries.
- Pool ICA training-copy ASR calibration statistics from within-trial covariance/RMS windows and reset ASR processing state at each trial. Rejected training samples do not shorten saved ERP trials. Insufficient calibration data are reported, with unrejected training data retained.
- For continuous input, run ICA/ASR before event extraction. Reject-ASR is refused with event extraction because deleting samples would invalidate event positions; Correct-ASR preserves time. Standalone ASR and standalone muscle cleaners remain continuous-input operations.
- Preserve original epoch protocols and parent processing provenance when cropping, subepoching, exporting and reopening saved recordings.
- Add selectable ERP electrode panel grids and clearer 0-ms / 0-µV references; retain native condition A/B channel waveforms and participant-weighted interactive review.

### Verification and practical limits

- Local Flutter regression suite: **207 passed, 6 skipped**. Static analysis and macOS release compilation passed. Native checks cover saved-trial ERP parity, epoched ICA, blink-window boundaries, and time-zero alignment after 1000→250 and 256→250 Hz resampling with filtering on/off.
- Independent MNE reads validate EDF/FIF signals, channel labels, annotations, epoch anchors and EDF quantization bounds. Export itself does not require Python or MNE.
- Read-only Pallavi audit: 1,156,520 raw samples at 1000 Hz map to 289,130 saved samples at 250 Hz; five local checks found zero sample lag. All 483 saved Pz epochs match their cleaned continuous-source slices after baseline adjustment. Oscillatory morphology is also present in independently filtered raw-data averages; this does not certify an artifact-free ERP or determine unknown behavioral marker meanings.
- The epoched ASR training-copy adapter is an application extension, not a claim of full clean_rawdata parity on epoched inputs. Existing outputs already misaligned by releases before 1.2.16 still require regeneration from the original data; filename migration cannot repair sample timing.
- macOS packages are ad-hoc signed. Platform installers and `SHA256SUMS.txt` are supplied by the desktop release workflow for the in-app updater.

### Guides and method references

- [Recording formats, performance checks and independent format validation](https://github.com/CCS-NIMHANS/CCS_EEGStudio/blob/v1.2.19/docs/pallavi_performance_and_files.md)
- [Pallavi ERP timing review, boundary-aware ICA, response rules and filename migration](https://github.com/CCS-NIMHANS/CCS_EEGStudio/blob/v1.2.19/docs/pallavi_erp_review.md)
- [ERP methods, references, parity and recovery guidance](https://github.com/CCS-NIMHANS/CCS_EEGStudio/blob/v1.2.19/docs/erp_workbench.md)
- [EEGLAB ICA workflow](https://eeglab.org/tutorials/06_RejectArtifacts/RunICA.html), [EEGLAB filtering guidance](https://eeglab.org/tutorials/05_Preprocess/Filtering.html), [EDF specifications](https://www.edfplus.info/specs/edf.html), [EDF+ specifications](https://www.edfplus.info/specs/edfplus.html)

## [1.2.16]

### Critical resampling/event-alignment correction

- Fixed rational resampling ratios in preprocessing: 256→250 Hz previously used 244/250 while labelling output as 250 Hz, shifting samples relative to unchanged event times. The corrected ratio is 125/128. Rates are formed at millihertz precision and the actual generated sample rate is retained.
- Fixed saved-trial sample counts to use the resampler's actual ceiling length rather than rounding, preventing boundaries from slipping across resampled trials.
- Added late-impulse alignment and independent-trial resampling regression tests. Reconstructed the supplied ERN stage by stage: the earlier sign reversal appears at downsampling alone; corrected downsampling preserves the negative response. Previously affected epoched files must be regenerated from the original input; changing labels or display polarity cannot repair them.
- Made `erp_trial_measurements.csv` an optional advanced export, disabled by default. `erp_measurements.csv` remains the conventional participant/condition-average measurement export. Existing files are retained.

### ERP reconstruction and validation

For the supplied already-cleaned ERN recording, using identical correct/error classes (319/82 trials), FCz, baseline −400…−200 ms and measurement window 0…100 ms:

| Processing route | Incorrect − Correct mean |
|---|---:|
| Epoch-only, original 256 Hz signal | −9.68 µV |
| Old 256→250 Hz resampling, no filter or cleaner | +12.16 µV |
| Corrected 256→250 Hz resampling, no filter or cleaner | −9.65 µV |
| Corrected resampling + filtering | −10.47 µV |
| Corrected complete GEDAI/interpolation configuration | −5.50 µV |

The sign reversal was caused by sample/event misalignment, not display orientation or swapping condition labels. GEDAI still attenuates the response on this already-cleaned input; epoch-only avoids additional processing. Existing outputs are retained for audit and must be regenerated where affected.

- Regression validation: **178 Flutter tests passed, 5 skipped**; **26 affected native tests passed**, including late-event alignment, per-trial output length, all-seven ERP reuse, optional CSV output, preprocessing and ICA/ASR tests.
- Independent MNE/SciPy reconstruction validates the corrected real-data resampling ratio and condition waveforms. Diagnostic scripts and output descriptions are in [the ERP guide](docs/erp_workbench.md#resampling-correction-and-existing-results).
- Version metadata is aligned across the app, engine and installer. The release supplies macOS, Windows, Debian and RPM update packages with checksums.

### Which ERP export to use

- **Conventional ERP:** `erp_measurements.csv` measures the participant/recording condition averages and their difference. Use the interactive review's participant-level CSV for chosen windows, parameters and cohort labels.
- **Optional trial-level work:** enable **Advanced analyses → Export individual-trial measurements** for `erp_trial_measurements.csv`. Rows contain per-event ROI measurements, not averaged ERPs and not complete trial waveforms. Trial-level models need participant-aware inference. Averaging trial peaks does not equal measuring the peak of the average ERP.
- The checkbox is off by default and saved in reusable analysis protocols. Disabling it does not delete previously exported trial files.

## [1.2.15]

### ERP waveform review and measurement export

- Added interactive batch review with searchable participant selection, individual recording/participant views, difference overlays, cohort labels and equal-participant grand averages with ±1 SEM for A/B and paired differences.
- Added optional display smoothing without changing exported measurements, live measurement-window controls and full-resolution channel difference outputs for exact scalp-map updates.
- Added selectable participant-level CSV metrics and a handoff to group statistics with cohort labels and reviewed window metadata.
- Made subtraction direction and display polarity explicit; added an epoch-only route for already-cleaned data.
- Restored continuous portable ERP event loading from preprocessing sidecars only when original timing was preserved.

### Connected ERP preparation and reusable protocols

- Connected waveform event epoching and preprocessing through shared event/group, baseline and timing settings; direct epoching now saves a real portable trial file before opening ERP analysis.
- Added reusable epoching/averaging protocol JSON import/export in interactive preprocessing, ERP analysis and the ERP Batch Workspace; compatible sidecars restore epoch settings on reopen.
- Distinguished new `-epo` and `-epo_clean` outputs, retained original event onsets and cleaning history, and prevented repeated derived-name suffixes.
- Preserved processed recordings when switching to raw; added an explicit saved-trial handoff, averaging action, contextual tooltips and trial-fitted waveform displays.

### Unified batch profiles and saved-trial ERP workflow

- Consolidated multi-recording entry points in Batch Workspace with EEG, ERP and Microstates profiles; removed the competing guided/legacy ERP selector and Microstates batch toggle from interactive analysis.
- Interactive ERP automatically loads the active prepared trial file and compares saved condition groups. Existing epoch boundaries/onsets are reused, and task-specific guides cover all seven ERP CORE components.
- Extended the native ERP engine to saved epochs, preserving trial layout rather than cutting around markers again. Behavioral response selection is not silently repeated on prepared trials; continuous FIR deconvolution is omitted for saved epochs.
- Added optional task-comparison reconstruction from original saved locking codes, allowing a different factor to be compared without re-epoching. The supplied ERN file's Congruent/Incongruent labels can thus produce the correct/error comparison (319/82 trials).
- Recognized ERP CORE `(uncorr) HEOG/VEOG` labels as auxiliary eye channels, preventing them from entering GEDAI montage lookup on future preprocessing runs. Existing outputs are not rewritten.
- Added all-seven-task saved-trial regression coverage and an independent NumPy waveform check for the user's prepared ERN recording.


### Event epoching and waveform navigation

- Compacted the waveform toolbar, collapsed full controls by default, reduced overview height and sized event lanes to occupied rows. Added independent panel toggles and a waveform focus/restore button; panel choices and navigation time survive collapsing.

- Added named event groups in preprocessing and the direct Epoch Events dialog: combine codes under editable condition labels while preserving original annotations and source times.
- Moved regex matching into an advanced section, removed implicit MMN marker defaults and synchronized shared panel controls. Direct epoching now matches normalized codes exactly (12 does not select 112).
- Added a clickable/draggable whole-recording amplitude/event overview with time ticks and viewport highlighting, plus separate collision-free event label lanes and full-label/time tooltips.
- Moved event/fixed-window choices before cleaning controls. Event trials suppress fixed-window epoching and its overlap; GEDAI's internal processing window is shown only where applicable. Added a preflight prompt for unmatched event selections.

### Guided ERP workbench

- Added single-recording and batch ERP workflows with recursive folder discovery, cleaned/raw duplicate preference, participant pilot limits and reviewable file lists.
- Added editable ERP CORE presets for MMN, N170, N2pc, N400, P3, LRP and ERN, searchable marker assignment, custom component definitions and saved per-task settings for mixed batches.
- Preserved supplied seconds-based event sidecars; audited source timing against EDF Status events and exposed sidecar markers in the raw viewer.
- Added native Rust peak, mean, signed/positive/negative AUC, fractional-area latency and fractional-peak onset measurements, with participant/condition and event-indexed trial exports.
- Added native multichannel rERP, sparse continuous FIR overlap correction with solver diagnostics, and training-fold-only shrinkage LDA with purged blocked CV and optional temporal generalization. The FIR implementation is a linear Unfold-style subset, not the entire toolbox.
- Added participant-level paired tests/FDR, channel and channel×time max-|t| FWER inference, paired normalized-map TANOVA-style testing, GFP exports and rERP class-beta inference. Single-participant outputs remain descriptive.
- Added channel/predictor model inspection, corrected-map masking, reopenable results, metadata/group-model handoff, compact PDF reports and tidy waveform/model CSVs. Optional-model failures retain conventional ERP results.
- Validated all seven paradigms in 14 cleaned ERP CORE recordings against an independent MNE/NumPy reconstruction; checked numerical kernels and real-data OLS/FIR coefficients against NumPy/SciPy. See `docs/erp_workbench.md` for exact methods, scope and references.


### Source, temporal information connectivity and graph summaries

- Corrected the former eLORETA label to the actual minimum-norm method; added MNE, dSPM, sLORETA and LCMV operators under the documented fixed-orientation assumptions.
- Added imported JSON/gzip forward-plus-atlas models and a coordinate-aware atlas conversion tool. HCPex is supported through a compatible user-provided mixed/volumetric forward and atlas; HCPex data and Rust BEM/FEM solvers are not bundled.
- Added Gaussian-copula MI and lagged-time conditional-information TE within each epoch, with configurable temporal embeddings. This is time-sample directed connectivity, not across-trial TE.
- Added configurable connectivity pair/graph-summary output choices and graph metrics. Estimator conventions, rank/tie behavior, graph definitions and attribution are documented in `docs/source_information_graph.md`; full toolbox parity is not claimed.

### Event-preserving feature plots and robustness

- Feature CSVs carry time-aligned `event_markers` JSON through retained preprocessing timelines and overlapping subepochs. Feature plots deduplicate repeated annotations and display onset labels and duration spans.
- Updated report/topography and group-statistics handling alongside the expanded analysis settings. Existing feature CSVs require re-extraction to obtain event annotations.

### Upgrade and workflow notes

- Use **Updates** in the toolbar for the platform package, or download the macOS ZIP, Windows installer, Debian package or RPM below. Versioned packages include SHA-256 checksums.
- All multi-recording EEG, ERP and Microstates entry points are under **Batch Workspace**; interactive ERP uses the active saved trials.
- For already-cleaned recordings, choose **Epoch only** to retain the supplied signal rather than applying the cleaners again. Original and derived recordings remain available when switching.
- Smoothing is display-only. Grand averages give participants equal weight after averaging their repeated recordings; uncertainty shadows are ±1 SEM across participants and are omitted for a single participant.
- Use **Interactive batch review → Label groups → CSV parameters → Export CSV / Group statistics**. CSV rows contain participant/condition measurements, cohort labels, ROI/window metadata and selected metrics. Live measurement-window changes do not silently recalculate inferential p-values.
- New results retain full-resolution channel differences for live scalp maps. Re-average older results for arbitrary-window topographies. Previously generated data are not overwritten by installing this update.
- macOS packages are ad-hoc signed, as in prior releases; initial launch may require the documented Gatekeeper steps. The macOS artifact targets the CI runner architecture, currently Apple Silicon.

### Validation, methods and limitations

- Local validation: **178 Flutter tests passed, 5 skipped**; **12 native ERP parity/regression tests passed**. Static analysis was clean and the macOS release bundle compiled and passed signature verification.
- Independent MNE/NumPy reconstruction matched the supplied cleaned EDF's 319 Correct / 82 Incorrect ERN waveforms with **0 µV discrepancy**. Independent NumPy reconstruction of the saved processed epochs also matched with **0 µV discrepancy**. An epoch-only preservation test matched the original cleaned EDF within 0.00001 µV.
- A prior 14-recording ERP CORE pilot covered all seven components; native numerical fixtures exercise measurements, regression, FIR solving, decoding and permutation logic. Source/information-connectivity fixtures check their documented supported formulas/subsets. Tests do not establish full parity with every upstream toolbox option or universal scientific validity for every dataset.
- Full workflow, measurement definitions, numerical checks and method references: [ERP workbench](docs/erp_workbench.md), [source/information/graph methods](docs/source_information_graph.md), [feature event timing](docs/feature_event_markers.md), and the [README method references](README.md#-method-references).

## [1.2.14]

### Stacked Multi-Group TopoStats Display & Lateral Spread Controls

- **Stacked Multi-Group Figures**: Added first-class support in "Plots & Report" (TopoStats) for displaying multiple recordings, subjects, or experimental sessions stacked vertically one below the other.
- **Group Management**: Automatically partitions sessions by recording ID (`groupByRecording`) and provides sidebar actions to append additional folders or CSV sets (`+ Add group`).
- **Active Group Editing**: Active group dropdown in the sidebar lets you reorder sessions, select custom baseline sessions, and adjust session colors independently per group.
- **Synchronized Inspection & Zoom**: Hover tooltips, click-to-inspect topomap dialogs, and smooth zoom (`Cmd+Scroll` / toolbar buttons) work seamlessly across all stacked figure cards.
- **Multi-Group Export**: Export PDF generates a high-resolution multi-page PDF document with one page per plot group; Export PNG and CSV exports batch results for all active groups.
- **Lateral Spread Reduction & Width Presets**: Added quick width pills (`Compact (0.35")`, `Medium (0.5")`, `Wide (0.8")`) and responsive recalculation (`onSubmitted`) for `Topo width` to instantly compress wide figures across long timelines without recomputing permutation statistics.

### MMN ERP Stimulus Epoching Parity

- **Epoch Preservation**: Prevented continuous sliding-window overlap slicing (`RecordingTransform.subepoch()`) from modifying stimulus-locked epoched files during preprocessing.
- **Stimulus Epoch Configuration**: Automatically zeroed and hid continuous window overlap settings in the UI when stimulus-locked epoching is enabled.
- **Dataset Parity Verification**: Re-generated and verified MMN epoched files for Day 3 (`20260922`), matching the 750-epoch structure and cluster permutation tests of Day 1 (`20260709`) and Day 2 (`20260710`).

### Group Statistics & Workspace

- Repaired group-statistics numeric imports, including mixed CSV types and DFA/fE:I numeric aggregation. Aligned pooled CSVs by column names instead of row position.
- Added consistent readable group-workbench theming, folder/multi-file loading, visible run controls, channel scope, and simpler EEG-focused defaults.
- Added searchable bounded plot recording lists and bulk selection; initially select up to eight records while keeping all files available.
- Added explicit exploratory short-epoch DFA/fE:I verification with separate `_short` columns. Published-scale estimators are not silently redefined.
- Defaulted analysis PDFs to compact summaries with representative channels, limited maps/time courses, and key tables. Detailed mode retains all channels/features.
- Rendered waveforms using preview sampling rate and a shared peak-safe amplitude scale; avoid row clipping of shown peaks. Added fitted scalp outlines and contours.
- Added configurable DFA/fE:I source context (UI default 60 s; zero = epoch only), retaining shorter epochs for other features and respecting saved trial boundaries.
- Recorded actual context duration/start/end in CSV metadata and provenance.
- Rejected fE:I when DFA is missing, closing the legacy NaN-comparison qualification loophole.
- Validated four-page PC001 report visually and full-band computation on five representative channels with five-second cadence and 60-second context.

## [1.2.13]

### FieldTrip loading and extraction

- Fixed continuous FieldTrip MAT inspection: a one-cell continuous trial remains
  continuous instead of being exposed as one synthetic saved epoch.
- This fixes "recording is shorter than one analysis epoch" for psiconnect
  recordings longer than four minutes. The native engine reads the original
  full-resolution file rather than a decimated waveform preview.
- Materialize full samples before serializing decimated native epoched inputs.
  Original recording names and source identity remain in feature outputs.

### Overlapping windows

- Added feature epoch overlap in seconds. Zero overlap preserves nonoverlapping
  extraction; overlap must be nonnegative and shorter than the window.
- Added optional subdivision of existing trials into feature windows, preserving
  parent boundaries and source window coordinates. Incomplete tails are dropped.
- Added overlapping saved windows after preprocessing: clean each original sample
  once, then construct the output windows. On continuous inputs this defers saved
  epoch construction until cleaning finishes. Existing parent trials remain boundaries.
- Persist output window/overlap and timing provenance. Overlap is not a change to
  GEDAI's internal covariance-window implementation.
- Short-window DFA/fE:I is permitted when meaningful for a band. Lower-band
  missing values and fE:I validity failures remain missing; the advisory warning
  does not block explicit continuation or fabricate values.

### Batch workflow and group statistics

- Added Already preprocessed mode to start with features and hide preprocessing.
- Added first-N-subject folder import (zero means all), using sorted BIDS subject
  IDs or first filename tokens. Queue counts now reflect the selected input stage.
- The main workflow can run feature extraction and plots without a preprocessing queue.
- Added Stage 4 Group Statistics, with optional automatic opening after batch
  completion. It pools successful feature outputs into an explicit group-input
  table and opens metadata/model configuration; it does not run an unspecified model.
- Fixed numeric categorical factors (such as sessions 1/2) being represented
  differently during model fitting and adjusted contrast construction.

### Filename metadata

- Added Infer metadata from filenames with a review-and-save preview.
- Recognize BIDS sub/ses/task/run/acq fields and legacy SubNN subject identifiers.
- Support custom named-group regular expressions and require an updated preview
  before saving an edited pattern. Preserve identifier strings in the metadata CSV.
- Deduplicate recording names, leave unmatched fields blank, select the reviewed
  CSV for metadata joining, and set filename as the join key.
- No demographic, diagnosis or treatment details are inferred from unsupported names.

### Validation and documentation

- 146 Flutter tests passed with 5 dataset-dependent skips; Dart analysis is clean.
  Rust tests passed, including sliding-window boundary checks; 6 Python statistics
  tests passed, including numeric categorical contrasts.
- All 79 recordings from PC001–PC010 passed full-channel PSD extraction using
  two-second windows and one-second overlap: 1,466,112 rows. No other subjects
  were processed and the source files were not modified.
- Bounded first-ten-second checks from one recording per subject produced 5,760
  finite Gamma1 DFA values and 708 finite Gamma1 fE:I values. Lower-band fits were
  unavailable at that window length; this is not a claim of validity in all bands.
- Exercised a metadata-joined Fz Alpha_PSD LMM with Task/Session fixed factors and
  Subject random intercepts. This validates the workflow, not a full dataset finding.
- Compiled and verified the local macOS app; platform CI builds installers for release.
- Updated README and docs/psiconnect_batch_workflow.md with controls, naming rules,
  statistical setup, implementation conventions and the exact pilot scope.

## [1.2.12]

### Feature-window warnings

- Added a pre-extraction popup for selected DFA/fE:I windows below the practical
  60-second full-band recommendation, FOOOF/IRASA below one second, Welch windows
  longer than the epoch, and insufficient samples for the configured GC lag count.
- Use actual saved parent-epoch length for already epoched files. Increasing the
  extraction control does not silently merge existing trials.
- Offer Change settings or explicit continuation with limited/missing values.
  Batch extraction deduplicates identical warnings; cancellation stops the stage.
- Confirmed the supplied Girish two-second outputs: all 28,132 Gamma1 DFA values
  are finite, 3,759 Gamma1 fE:I values are finite, and Delta through Beta2 DFA/fE:I
  values are missing. Missing values are retained rather than filled or fabricated.
- Sixty seconds is an implementation-informed recommendation, not a universal
  validity guarantee. fE:I has additional validity gates even with longer windows.

### Compact outputs and naming

- Default to one feature CSV per recording rather than also writing a redundant
  pooled Batch_features.csv. Combined export remains available when selected.
- Default to one combined plots PDF and statistics CSV per recording without
  hundreds of individual PNGs. PNG export remains selectable; disabling the plots
  PDF produces PNGs so a visible plot output remains available.
- Name new preprocessing/feature summary reports `.analysis_report.pdf`, replacing
  `.features_report.pdf`. Plot reports retain their established TopoStats names.
- Keep batch analysis PDFs in the selected output directory even when individual
  feature CSVs are disabled and engine CSVs are temporary.
- Retain cleaned signals, analysis/preprocessing provenance and numerical plot
  statistics. Existing outputs are not deleted or renamed automatically.

### Documentation and method references

- Updated README with actual window-warning thresholds, output defaults, method
  papers and reference implementation links.
- Added docs/output_files.md to distinguish data, analysis reports, plots, statistics,
  provenance and optional duplicate exports; docs/methods_and_validation.md retains
  scoped ICA/ASR/DFA/fE:I reference evidence and experimental-variant limits.
- No feature algorithms or estimator thresholds were changed in this release.

### Validation

- Targeted window/default/export tests passed, including PDF-only output retaining
  statistics without PNG files and saved epoch lengths overriding UI cut settings.
- The full run passed 141 tests with 5 skips; the sole stale UI-label test was
  updated and passed in the 12-test UI rerun (142 tests covered in total).
- Dart analysis is clean. The local macOS 1.2.12 bundle compiled, embedded its
  release engine, and passed code-signature verification. Desktop CI also runs
  the complete suite before publishing platform packages.

## [1.2.11]

### ICA and ASR preprocessing (alternative or precursor to GEDAI)

- New **ICA cleaning** option in Preprocess: EEGLAB-parity Infomax (`runica`) or Picard,
  with blink-locked ICA (eye / optional heart components), a second ICA stage
  (muscle, line noise, channel noise) and ICLabel classification. Runs before ASR and GEDAI.
- New **ASR burst cleaning** (clean_rawdata parity): *Correct* reconstructs bursts in place
  (timing preserved), *Reject* drops burst samples. It follows ICA when both are enabled.
- Engine: vendored `bridge/vendor/ccs_ica` (sources of `ccs_toolbox/rust_ica`, validated against
  MATLAB/EEGLAB). ICA/ICLabel need 10-05 electrode names and continuous data; bad channels are
  left out of the decomposition and interpolated afterwards. The preprocessing summary gains an
  `ica` report (components removed with ICLabel classes, ASR samples modified).
- Parameters (eye channel, thresholds, ICLabel classes, ASR cutoff, seed) are in Preprocessing parameters.
- **ASR variants**: Riemannian ASR (EEGLAB `asr_calibrate_r` port, MATLAB-verified), ASR_DBSCAN / ASR_GEV calibration for
  movement-heavy data (sample selection matches mne-denoise `select_juggler_reference_samples`: DBSCAN identical, GEV 1 of 12000
  samples), adaptive (EMA) ASR (own design, not the published A-ASR), and E-ASR / VMD-ASR / EMD-ASR for up to 8 channels
  (interpretations; the E-ASR reference could not be accessed, so no reference check exists).
- **Muscle / motion cleaners** (after ICA, before ASR): BSS-CCA and iCanClean (pseudo-reference) match mne-denoise numerically
  (1e-8 or better); wICA follows HAPPE `wICA.m` (coif5 SWT, 5 levels, `ddencmp` soft threshold) and matches a MATLAB run of it to
  9e-5 (MATLAB single precision). wICA default levels are now 5.
- Verification scripts and numbers: `ccs_toolbox/rust_ica/README.md`.

### Orbit recording fixes

- Corrected the engine handoff for Orbit `.orb` / `.signal` recordings: the app
  sends the parsed full-resolution channels as portable EEG rather than asking
  the EDF reader to parse Orbit JSON. This fixes "invalid digit found in string"
  during preprocessing and feature extraction.
- Scalar C/D fields no longer create false EEG channels; array-valued C/D still
  represent additional channels. Two-channel recordings show AF7, AF8 and PPG.
- Added regression checks for channel detection and engine preprocessing/extraction.

### DFA and functional excitation/inhibition

- Added optional band-limited amplitude-envelope DFA and fE:I extraction with
  band-specific CSV columns, family reporting, and shared batch controls.
- The Rust implementation follows the CCS Python DFA/fE:I implementation and
  Hardstone/Bruining methodology. Fit ranges and windows adapt to available data;
  bands without enough data yield missing values rather than fabricated estimates.
- Short-window results are adaptations and do not establish literature-scale
  long-range correlations. fE:I is a signal-derived index, not a measured synaptic ratio.

### Pipeline behavior and reproducibility

- ICA requires continuous input, at least 8 good channels with recognized 10-05
  positions and at least 20 seconds of data. Unlocated/bad channels are excluded.
- Enabled cleaners run after bad-channel detection in ICA, muscle, ASR order,
  before fixed-window subepoching/GEDAI. Already epoched input skips these cleaners
  with a warning. Stimulus epochs created before this stage are also epoched input.
- ASR Correct preserves sample count; Reject removes samples and loses one-to-one
  input timing. Marker copying and raw/cleaned comparison are disabled when that
  timeline is not preserved.
- E-ASR, VMD-ASR and EMD-ASR skip inputs above 8 channels with a warning.
  Riemannian ASR uses 30-second processing blocks in Studio.
- ICA, ASR and muscle cleaning remain opt-in; enabling multiple cleaners combines
  their effects. Sidecars, activity logs and reports record selected options and outcomes.
- GEDAI reports whether a leadfield or identity reference was used. Unknown labels
  produce an explicit warning: identity fallback is not leadfield-based GEDAI.
- Updated macOS project and CocoaPods deployment targets consistently to macOS 12.
- Added method papers, reference implementation links and a scoped numerical
  validation table in README and docs/methods_and_validation.md.

### Validation

- Dart analysis is clean; 138 Flutter tests passed with 5 dataset-dependent skips.
  All Rust bridge tests passed, including 8 ICA/ASR and 4 advanced-parameter checks.
  The vendored algorithm library passed all 26 tests, including DFA/fE:I checks.
  The local macOS 1.2.11 bundle compiled and passed code-signature verification.
- Detailed parity figures describe upstream checks, not freshly rerun clinical or
  algorithm-effectiveness validation. ICA2 removal is weakly tested on the upstream
  fixtures because no components exceeded its thresholds.

## [1.2.10]

### Recording preparation and epoch handling

- Added Crop / subepoch and save in Load Raw, Preprocess, and Feature Extraction.
- Crop by annotation endpoints, annotation start plus duration, time endpoints,
  or time start plus duration before creating subepochs. Saved portable recordings
  retain annotations and preparation provenance for reuse.
- Native previews are loaded at full resolution before preparation. Mixed-rate
  channels are rejected rather than silently truncated.
- Existing trials support within-trial crops and complete-epoch selection on the
  stitched timeline. Sliding windows support overlap without crossing parent trials;
  incomplete windows are dropped and sample rounding determines the exact hop.
- Preserve window start/end coordinates in saved recordings and feature CSVs.
  Interval extraction keeps complete windows; time bins use window centres.
- Hide continuous epoch-cutting controls for already epoched recordings.

### Preprocessing and feature settings

- Added settings icons for output and feature references, filters, bad-channel
  detection, interpolation, source analysis, and feature families.
- Output references support keeping the input reference, common average, and named
  EEG reference channels. Feature referencing can be configured independently.
- Added FIR taps, Butterworth order, notch stop/transition widths, bad-channel
  variance ratio, spline parameters, source SNR and selectable atlas regions.
- Added Welch mean/median and window settings, custom frequency bands, FOOOF peak
  controls, IRASA factors, sample-entropy tolerance, Higuchi kmax, ACW crossing,
  and GC lag settings. Existing defaults are retained.
- Added GC minus time-reversed GC as a separately named contrast. It uses the
  same fits as GC and GC-TR and is distinct from net directional GC.
- Fixed preprocessing resampling despite the downsampling option being disabled.
- Recover preprocessing/source completion from saved provenance, recognize legacy
  clean filenames, and recover adjacent feature CSVs and figure folders on reopen.

### File selection and plot presentation

- Added filename wildcard filtering with *, ?, and semicolon-separated patterns
  to file selectors and batch folder queues.
- Added manual session ordering and per-session hexadecimal line colors, including
  exported plots. Display reordering preserves the baseline and computed statistics.

### Metadata-based group statistics

- Added Group Statistics in the batch workspace and Full Pipeline, adapted from
  CCS SleepStudio's local Python LMM/GLM workbench.
- Join feature CSVs with metadata CSV/XLSX, choose subject/group/within-subject
  factors, covariates, and outcomes, then export model tables, contrasts, and plots.
- Validate metadata joins; aggregate epoch values per recording/channel/condition;
  avoid treating duplicated connectivity rows as separate channel observations.
- LMM uses subject random intercepts; GLM uses HC3 or subject-clustered covariance.
  Failed mixed models do not silently fall back to independent-observation OLS.
- Contrasts use model-adjusted means and covariance, with selected-outcome multiple
  comparison correction and separately recorded omnibus/coefficient families.
- This optional workbench requires local Python with numpy, pandas, scipy,
  matplotlib, and statsmodels. XLSX uses openpyxl; optional Word/PDF reports use
  python-docx/reportlab. Set CCS_EEG_PYTHON to select an interpreter.

### Analysis conventions and compatibility

- FOOOF/IRASA retain a 1–40 Hz fit range; connectivity retains its 4–40 Hz grid.
  Custom PSD bands may extend to Nyquist. Standard bands preserve legacy
  integration; custom bands use trapezoidal integration.
- Overlapping epochs are not independent group observations. Multiple subjects
  and estimable designs are required for group inference.
- Recording and analysis sidecars record the actual source, settings, and timing.
  Existing cleaned files are not automatically regenerated with the new options.

### Validation

- 136 Flutter tests passed; 5 dataset-dependent tests skipped. Dart analysis was clean.
- Rust bridge and parameter tests passed, including reference voltage differences,
  alpha/high-frequency filtering, Welch robustness, and GC contrast identity.
- 23 vendored reference-fixture tests and 5 group-statistics tests passed.

## [1.2.9]

### GEDAI controls

- Exposed GEDAI's automatic presets and numeric threshold in preprocessing,
  shared between interactive and batch workflows, with input validation.
- Kept the existing automatic default; lower numeric thresholds can be used
  to review more conservative cleaning without changing all users' settings.

### Feature reports

- Added separate raw and cleaned waveform panels with the same time interval
  and amplitude scale, divided into readable channel groups.
- Reduced plot density and simplified the report summary.
- Report the actual saved epoch duration rather than the extraction UI value.
- Persist raw-source and preprocessing provenance so batch reports can recover
  the raw recording and describe the settings actually used.
- Avoid raw comparisons when stimulus epochs or differing durations make the
  timelines incompatible.

### Validation

- Verified the revised report visually on the supplied recording and passed
  threshold configuration and UI regression tests.

## [1.2.8]

### Batch results and plotting

- Added View Results to completed batch runs and the batch workspace, opening
  the interactive plot comparison directly with the latest batch outputs.
- Added Open Reports Folder for the generated figures and PDFs.
- Prefer individual recording CSVs over the redundant Batch_features.csv.
  Combined-only exports are split into named sessions before plotting.
- Changing selected sessions updates the plot automatically and selects a
  remaining baseline when the previous baseline is removed.
- Deselecting all sessions clears the plot and prompts for a recording instead
  of retaining an invalid baseline or stale figure.
- The batch result viewer inherits the configured epoch, smoothing, and window
  settings. Combined CSV previews export beside the source CSV.

### Release packaging

- Fixed RPM installation steps to use shell syntax supported by rpmbuild and
  explicitly run Bash-based desktop launcher setup with Bash.
- Added engine --help support for the Linux installer smoke test.
- Supersedes the unpublished 1.2.7 build, whose RPM packaging check failed.

### Validation

- Added regression tests for pooled/per-recording inputs, quoted filenames,
  baseline removal, and deselecting/reselecting sessions in the viewer.

## [1.2.6]

### Batch analysis

- Fixed an IRASA crash on one-second epochs when resampling produced fewer
  samples than the requested Welch window. Short windows now retain the FFT
  grid through zero-padding.
- Included the patched algorithm source so all platform builds use the fix.

### Interactive workspace

- Open directly into the recording workspace with workflow modules and the
  waveform viewer visible.
- Show the waveform automatically after loading or switching raw recordings.

### Validation

- Verified feature extraction on all 11 recordings from the reported batch.
- Passed UI regression tests and spectral reference tests.

## [1.2.5]

### Release reliability

- Pinned Flutter 3.41.9 across macOS, Windows, and Linux so CI runs the same
  tested SDK on every platform instead of silently moving to a newer stable
  toolchain.
- Updated GitHub checkout steps to the Node 24-based action release.
- Retains all application, ERP, microstate, viewer, format-loader, batch, and
  reporting improvements documented for 1.2.4 below.

## [1.2.4]

### Microstate timeline and statistics

- Aligned the microstate sequence strip, EEG waveform, and per-state
  similarity traces to one absolute-time axis and one common plot area.
- Added selectable EEG density (3, 6, 12, or 24 visible channels) and
  individually toggleable similarity traces.
- Added sample-wise state-similarity probabilities based on normalized squared
  spatial correlations.
- Display transition probabilities as percentages with two decimal places so
  small off-diagonal transitions remain distinguishable.
- Clarified canonical-template correlations and applied the same state colors
  to maps, legends, sequences, and similarity traces.

### ERP scalp mapping

- Added condition A, condition B, B−A, and Welch-t scalp maps across standard
  10–20 electrodes.
- Added an independently configurable scalp-map time point and a switch between
  that point and the configured component-window average.
- Added electrode-level condition statistics with Benjamini–Hochberg FDR
  correction; significant electrodes are marked directly on the maps.
- Preserved the existing Python-parity waveform, cluster-permutation,
  bootstrap, and summary statistics.

### Viewer and usability

- Kept raw and preprocessed recordings at the same absolute timeline position
  while switching between them, including stitched epochs.
- Constrained long recording tabs, added ellipsis, and exposed the full name in
  a tooltip so filenames cannot cover adjacent controls.
- Increased waveform readability with a light canvas, uniform traces, channel
  paging, and EEGLAB-style stitched epoch navigation.

### Validation

- Verified ERP parity against the Python reference data.
- Added synthetic and real 32-channel tests for point and window scalp maps.
- Passed the complete Flutter test suite and macOS bundle signature checks.

## [1.2.3]

### Recording formats

- Added FieldTrip MATLAB v5 files with continuous numeric trials and cell-array
  trials, including the Psiconnect `*_Clean-ft.mat` layout.
- Added EEGLAB `.set` support for embedded data and external `.fdt` files.
- Added continuous and epoched MNE `.fif` loading.
- Added BrainVision marker parsing for stimulus-locked ERP epoch generation.

### Workflow and batch processing

- Reworked the home, single-recording, and batch workspaces to remove duplicate
  navigation and give the active task the full application area.
- Added independent preprocessing, feature-extraction, and plotting batch
  stages with explicit inputs and shared, visible parameters.
- Added recursive folder loading, per-file progress, live logs, cancellation,
  failure isolation, and incremental pooled CSV output.
- Added a configurable GEDAI epoch/window size and stimulus-locked preprocessing
  with epoch metadata preserved in portable CCS EEG files.

### Analysis and distribution

- Added interactive and batch microstate analysis, canonical maps, temporal
  metrics, transition matrices, sequence export, and timeline exploration.
- Added ERP condition selection, waveform/SEM plots, cluster permutation tests,
  effect sizes, bootstrap intervals, statistics tables, and PDF/CSV export.
- Added in-app update discovery and platform-specific installer download from
  GitHub Releases.

## [1.2.0]

- Restructured the application into connected workflow modules.
- Added automatic and reviewable EEG/auxiliary channel typing.
- Added single-recording and batch parameter parity, per-recording outputs,
  pooled feature CSVs, and group overlays.
- Integrated the shared `CCS_Algorithm` Rust crate and variance-based bad-channel
  detection.

## [1.1.3]

- Fixed sidebar and stage-card Material ancestry assertions.
- Stabilized interactive and batch navigation layout.

## [1.1.2]

- Resolved static-analysis failures that blocked release builds.
- Hardened CI lint handling and desktop compilation.

## [1.1.1]

- Made fixture-dependent plotting tests skip cleanly when external research
  datasets are unavailable on CI runners.
- Restored successful GitHub Actions builds on clean machines.

## [1.1.0]

- Introduced separate interactive and batch workflows.
- Added real-time preview filtering and configurable analysis controls.

## [1.0.0]

- First versioned desktop release.
- Added Rust-backed EEG feature extraction, connectivity analysis, plotting,
  batch execution, CSV output, and PDF reporting.

[1.2.5]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/compare/v1.2.4...v1.2.5
[1.2.4]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/compare/v1.2.0...v1.2.4
[1.2.3]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/compare/v1.2.0...v1.2.3
[1.2.0]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/releases/tag/v1.2.0
[1.1.3]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/releases/tag/v1.1.3
[1.1.2]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/releases/tag/v1.1.2
[1.1.1]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/releases/tag/v1.1.1
[1.1.0]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/releases/tag/v1.1.0
[1.0.0]: https://github.com/CCS-NIMHANS/CCS_EEGStudio/releases/tag/v1.0.0

### Event-aligned feature plots (unreleased)
- Export raw annotations as structured `event_markers` metadata with exact source onsets and durations.
- Preserve duration annotations through overlapping subepochs, including annotations starting before a window.
- Draw deduplicated onset labels and shaded annotation intervals on feature line plots; exclude marker metadata from numeric outcomes.

### Source models and connectivity graphs (unreleased)
- Correct the former eLORETA label to MNE; add fixed-orientation dSPM, sLORETA, and unit-gain LCMV inverse choices.
- Import validated custom forward/atlas models; provide an explicit MNI-grid mapping utility for supplied HCPex or other volumetric atlases. No cortical-only model is presented as a complete HCPex reconstruction.
- Add native univariate GCMI and within-epoch temporal Gaussian-copula TE with configurable lag/history embedding, finite-sample bias correction and pinned Frites CMI numerical fixtures. Overlapping windows are supported; no across-trial estimator is exposed.
- Export raw node pairs, graph summaries, or both for GCMI, TE, coherence, PLV, ciPLV, PLI, and wPLI; support electrode and ROI inputs.
- Add positive-density thresholding, in/out strength, degree, weighted clustering, nodal/global efficiency, and realized density; document directed and symmetric-graph conventions.
- Recognize graph outcomes in group statistics, stop source processing on invalid model imports, and document supported mathematical parity separately from unimplemented full-toolbox options.
