# 3. Coordinated Epochs & ERP Analysis Suite

[← Features & State Dynamics](Features-and-State-Dynamics.md) · [Wiki Home](Home.md) · [Next: Batch & Group Statistics →](Batch-and-Group-Statistics.md)

---

## 3-Step Visual Workflow

```mermaid
flowchart LR
  S1["Step 1: Define ERP Protocol<br/>Marker groups, [-200, 800] ms limits<br/>Click epoch shades on EEG to enable/disable"] --> S2["Step 2: Epoch Review & Analysis<br/>Shared accepted trials, electrode & window<br/>ERPimage | Distributed | Butterfly | ERP & Topo | ERSP & ITC | rERP & ML"]
  S2 --> S3["Step 3: Measurements, Plots & Save<br/>Summary tables, publication figures,<br/>.ccserp, .csv & PDF export"]
```

Everything in **Step 2** shares **one accepted-trial set**, **one active electrode** (selectable from dropdown or 2D scalp topoplot), and **one measurement window** (`Start–End ms`).

---

## Interactive Review & Analysis Views

| ERPimage (Grouped Events + Linked Topo) | Butterfly Plot + Separate GFP Strip |
| :---: | :---: |
| ![ERPimage](../../screenshots/erpimage.png) | ![Butterfly Plot](../../screenshots/erp_butterflyplot.png) |
| • EEGLAB-style RdBu diverging heatmap (`Smooth: 1/3/5/10`)<br>• Inline **Group** selector (`Both` or single condition) + colored condition strips & dividers<br>• Click/drag rows to reject or reinstate trials; linked **Topo ms** window | • Highlights **only the active electrode** in red across all channels<br>• Dedicated lower **GFP (µV)** strip with its own Y-axis<br>• Time axis aligned vertically with `Live ERP Preview` & right-side Topo channel picker |

| ERP Waveforms & Scalp Topographies | ERSP & ITC (Time–Frequency + Linked Topos) |
| :---: | :---: |
| ![ERP & Topo](../../screenshots/erp_topo.png) | ![ERSP & ITC](../../screenshots/ersp_itc.png) |
| • Condition waveforms (`A`, `B`, `B − A`) + interactive drag window<br>• Within-subject permutation & **eTFCE** significance masks<br>• **Channel Algebra** (`N2pc`, `LRP`, `Custom Ch A − Ch B`) | • Parallel Morlet wavelet **ERSP (dB)** & **ITC (0–1)** with permutation masking<br>• Inline **Topo Window** (`ms` & `Hz`) synced with ERSP & ITC scalp topographies |

| rERP Overlap Correction & ML Decoding | Measurements, Publication Plots & Export |
| :---: | :---: |
| ![rERP & ML](../../screenshots/erp_regression_ml.png) | ![ERP Measurements](../../screenshots/erp_measurements.png) |
| • Guided **rERP** GLM overlap-correction overlaid against Conventional ERP + Beta topo<br>• **Shrinkage LDA** time-resolved decoding, Peak AUC/latency & spatial pattern topoplot | • Component latency/amplitude tables (`Mean`, `Peak`, `Area`, `50% Fractional Area`)<br>• Publication-ready multi-panel exports (`.csv`, `.ccserp`, `.svg`/`.png`, `.pdf`) |
