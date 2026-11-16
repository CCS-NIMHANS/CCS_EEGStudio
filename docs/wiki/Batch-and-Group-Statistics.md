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
- **Channel Mapping Across Batches:** Use **Interactive Montage & Channel Mapping** to apply channel renames, 10–20 presets, or non-EEG exclusions across all queued files (`.ccschannels`).
- **Interactive ERP Batch Review:** Inspect individual participant ERPs alongside equal-participant Grand Averages (`±1 SEM`), assign cohort/group labels, and run group-level statistics.
- **Multi-User Linux Server Support:** Install system-wide via `scripts/install_linux.sh` or per-user without `sudo` (see [Server & Plot Controls](../server_and_plot_controls.md)).

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Space` | Play / Pause continuous EEG scrolling |
| `←` / `→` | Step backward / forward in time window |
| `↑` / `↓` | Increase / decrease EEG amplitude scale |
| `Ctrl/Cmd + O` | Open recording |
| `Ctrl/Cmd + S` | Save / export current output |
