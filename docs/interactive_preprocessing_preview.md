# Local interactive preprocessing preview

Each bar expands to reveal its settings. Apply enables that operation in the displayed pipeline; Disable removes it. Changed parameters show Update. Operations always follow the scientific pipeline order: resample, filter, bad-channel detection, ICA, muscle cleaning, output ASR, GEDAI, interpolation, reference. Clicking controls in another order does not change this processing order.

Cached combinations switch without another engine run. New combinations reuse unchanged upstream stages through lossless float64 checkpoints. For example, enabling re-reference after ICA reuses the ICA fit. Changing filtering or channel exclusions changes ICA's input and requires a new fit once. Reading stored samples still takes disk I/O; first-time downstream operations still require computation.

## Persistence and location

Cache data live next to the **original input**, under `.ccs_eegstudio_cache/<content fingerprint>/`. They are independent of the chosen export/output folder. If the input folder is read-only, the Mac fallback is `~/Library/Application Support/CCS EEG Studio/preprocessing_cache/`. The panel's **Persistent file cache · Show folder** button opens the exact directory.

`session.json` records the last successful selection and settings. `combination-*.ccseeg` files, their `.ccshistory` metadata and completion markers retain displayed results. `stages/*.checkpoint` files store lossless intermediate samples and stage reports. Switching files or closing the app clears memory, while these files remain. Reopening the same unchanged original restores the last selected result and ICA review. Source content, external sample files, recording metadata, and cache schema changes invalidate reuse. Old cache revisions remain on disk and can be removed when no longer needed; removal means recomputation on the next use.

Use **Save displayed combination** to export the exact preview, including retained ICA review data. The full preprocessing run instead uses the configuration selected in the detail panels and includes saved-output/epoch settings. Interactive previews preserve the existing continuous/epoched structure.

## ICA review

Both ICA stages retain scalp weights, all ICLabel scores, the full projection, removal decisions, and the actual last-tested removal threshold. The review states which targeted class met that threshold and explains the adaptive threshold search and its stopping limits. ICLabel Brain scores are probabilities, not measured signal loss.

Component display traces cover the complete recording at up to 200 Hz. Use the time slider, previous/next window, horizontal trackpad scrolling, or drag the waveform. Saved trials have separate navigation and do not bridge trial boundaries. These traces have arbitrary ICA scale and are for review; processing samples remain at the recording's processing rate.

Earlier local preview results retained only the first 30 seconds and did not record exact removal criteria. Those details cannot be recovered from that limited trace: recompute ICA once with this build to seed the new persistent cache. This workflow does not publish a GitHub release.

## Source review workspace

The Source localisation panel has a collapsed inverse-model/atlas configuration bar and an **Apply source projection** action. Results are cached by channel input, selected samples/channels, source method, SNR and custom model content. Applying the same model again loads its saved result. **Save source recording** exports it separately.

Switch **Channels** / **Source / ROIs** in the side panel without running another inverse. The single waveform overview, waveform clicks and linked cursor field control the side-panel head plot. There is no independent map slider. Window mean and RMS never cross a saved trial boundary; trials have separate navigation. Scalp mode uses the standard-montage topoplot. Source mode shows transparent sagittal/coronal/axial fsaverage/aparc projections, using actual projected atlas boundaries from local FreeSurfer pial surfaces and aparc annotation files. ROI outlines, legend labels and traces share identity colours. Dots indicate the signed amplitude (or RMS magnitude) for the selected interval; this is a template ROI display, not a voxelwise activation map or an individual MRI. Click an ROI or its legend to isolate traces. Custom atlas waveforms remain available, but unprovided custom anatomy is not drawn as the bundled atlas.

Source traces start with per-trace autoscaling because inverse-model units differ from sensor µV. Channel/source switching preserves the selected time. Geometry can be reproduced with `tools/build_source_review_geometry.py` from an existing FreeSurfer fsaverage subject directory; no download runs in the application.

## Cache and blink review refinements

Effective settings determine cache identity: reordering JSON keys, 250 versus 250.0, parameters belonging to disabled steps, and resampling an already-250-Hz recording to 250 Hz do not trigger another fit. Existing completed combinations are recognized under these normalized identities. A genuinely changed upstream signal still needs downstream computation once.

The ICA bar reports the actual number of ocular components removed. Blink detection can succeed even when no ICLabel Eye/Heart score exceeds the configured minimum probability. The probability floor is adjustable per file. **Compare with 50% Eye threshold** provides an explicit lower-threshold trial when the conservative setting retained all components; it does not change the global default or guarantee removal of every transient. Inspect component traces, scalp maps and Brain scores before keeping a less certain removal.

Re-referencing now offers a searchable multiple-channel picker. It lists retained EEG electrodes; auxiliary reference electrodes must first be retained in Channel setup.

## GEDAI correction in 1.2.39

GEDAI now uses the MATLAB reference's gentle broadband pass and nine-level MODWT/MRA decomposition. Threshold optimization samples more of the recording and scans the hard-mask objective before local refinement, avoiding an arbitrary result on a flat starting plateau. The internal full-rank pseudo-average reference is inverted after cleaning so that the requested final output reference is honoured. This transforms cleaned signals only; it never adds the original recording or an untouched alpha band back into the output.

The recorded `gedai_quality` metadata identifies the algorithm revision, actual thresholds, input/output references and estimated 8–13 Hz power on a common-average reference applied identically to both inputs. It reports median channel-wise alpha power retention, not a guarantee that alpha is neural or that every dataset should retain the same power. Large alpha reductions are flagged for review. Other cached preprocessing stages are retained, but old GEDAI-containing combinations are refreshed before reuse.

## Linked scales and units

Head plots and ROI values are in the Source side panel, leaving the waveform at full height. Raw sensor amplitudes are labelled µV; source values are labelled ROI model units. They are not interchangeable physical measurements. **Standardized patterns (z)** uses each trace's mean and standard deviation over the recording or selected saved trial, with a shared fixed ±3 z scale (0–3 for RMS) and the same palette across scalp and source displays. Waveforms retain their native amplitudes. Native-unit map ranges stay fixed over the recording/trial rather than rescaling at every cursor position.
