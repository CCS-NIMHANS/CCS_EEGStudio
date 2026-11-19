# 4. Batch Pipeline & Group Statistics

[← Epochs & ERP Suite](Epochs-and-ERP-Suite.md) · [Wiki Home](Home.md)

---

## Multi-File Batch Pipeline

```mermaid
flowchart LR
  B1["Stage 1: Preprocessing<br/>Toggle steps with Checkbox/Switch<br/>Load / Save .ccspipeline"] --> B2["Stage 2: Source / Epochs<br/>Inverse projection or batch epoching"]
  B2 --> B3["Stage 3: Features / ERP<br/>Parallel extraction or grand-avg ERP"]
  B3 --> B4["Stage 4: Plots & Group Stats<br/>Participant labels, LMM / GLM, eTFCE"]
```

| Batch Pipeline Configuration | Live Batch Progress & File Status |
| :---: | :---: |
| ![Batch Analysis Pipeline](../../screenshots/batch_analysis.png) | ![Batch Progress](../../screenshots/batch_progress.png) |

---

## Key Batch & Server Capabilities

- **Direct Step Toggles:** In **Stage 1: Preprocessing**, each step card (`Resample`, `Bandpass + notch`, `Detect bad channels`, `ICA`, `Muscle`, `ASR`, `GEDAI`, `Interpolate`, `Re-reference`) has a direct **Checkbox + Switch** (`Included` / `Skipped`) on its header.
- **Channel Mapping & Manual Bad Channels Across Batches:** Use **Interactive Montage & Channel Mapping** to apply channel renames, 10–20 presets, or non-EEG exclusions across all queued files (`.ccschannels`), and enter batch manual bad-channel exclusions in the Bad Channel Detection card.
- **Publication Parameter Logs & Methodology Reports:** Every single-file and batch run writes `preprocessing_parameters.json`, `feature_parameters.json`, `analysis_parameters_log.md`, and `batch_methodology_and_results_report.md` directly into the output directory.
- **Interactive ERP Batch Review & Statistics:** Use the **Unbiased Grand Average Localizer** and **Factor & Grouping Designer** (`Groups.xlsx` / BIDS / interactive filename cropper), then run **Mixed-Design ANOVA / Permutation GLM & LMM** with live factor plot configuration.
- **Multi-User Linux Server Support:** Install system-wide via `scripts/install_linux.sh` or per-user without `sudo` (see [Server & Plot Controls](../server_and_plot_controls.md)).

---

## Method References

| Statistical Method / Plot | Reference |
| :--- | :--- |
| **Unbiased Grand Average Collapsed Localizer** | Luck & Gaspelin (2017), *Psychophysiology* 54(1):146–157, [doi:10.1111/psyp.12639](https://doi.org/10.1111/psyp.12639) |
| **Split-Plot Mixed-Design ANOVA & Exchangeable Permutation** | Anderson & Braak (2003), *J. Stat. Comput. Simul.* 73(2):85–113; Winkler et al. (2014), *NeuroImage* 92:381–397 |
| **BH-FDR & e-TFCE Multi-Channel Correction** | Benjamini & Hochberg (1995), *J. R. Stat. Soc. B* 57(1):289–300; Mensen & Khatami (2013), [doi:10.1016/j.neuroimage.2012.10.027](https://doi.org/10.1016/j.neuroimage.2012.10.027) |

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Space` | Play / Pause continuous EEG scrolling |
| `←` / `→` | Step backward / forward in time window |
| `↑` / `↓` | Increase / decrease EEG amplitude scale |
| `Ctrl/Cmd + O` | Open recording |
| `Ctrl/Cmd + S` | Save / export current output |
