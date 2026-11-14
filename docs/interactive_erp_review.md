# Interactive epochs and ERP review

The single-recording workflow has one **Epochs & ERP** module. Epoch definition
and averaging are distinct operations within this workspace, rather than
separate file-loading tabs. The advanced ERP workbench and Batch Workspace
remain available for measurements, models, group analysis and saved results.

1. Apply preprocessing bars while inspecting the waveform. **Finalise** writes
   the displayed samples as an analysis copy. It does not repeat filtering,
   ICA, ASR or GEDAI. New configured runs use the same intermediate-stage cache.
   An unapplied settings edit is not part of the displayed signal.
2. The following modules use that saved analysis copy. If applied processing
   changes, the app asks for a new finalisation before downstream analysis.
   Returning to a previously finalised cached combination can restore its saved
   copy. The handoff is remembered in the per-input cache manifest, and is
   invalidated if the output file changes or disappears.
3. Open **Epochs & ERP**, choose a shared ERP-CORE preset or define custom event
   groups, windows, baseline and response rules under **Protocol & event groups**.
   Create the trial preview. Existing saved epochs retain their definitions;
   their original baseline is not applied again.
4. Under **Epoching & trial review**, browse conditions and individual trials.
   Uncheck an included trial to exclude it, or reinstate it at any time. Original
   trial samples remain in memory. A compact live average stays visible while
   browsing, with a fixed amplitude scale so rejection cannot silently rescale
   the apparent effect. **ERP averages** provides the larger view.
5. **Averaging & ERP review** shows descriptive per-condition averages and trial
   counts. Use **Show ERP measurements** for the existing measurement/statistics workflow
   inline. Accepted trials and named conditions are handed through automatically;
   exporting the accepted epochs is optional. Use **Export results** for tables
   and reports. Lateralized ERP contrasts are
   computed there, not approximated in the descriptive review plot.

Trial exclusion/reinstatement updates running condition sums; it does not call
preprocessing or re-epoch the signal. A protocol change marks the old preview as
outdated and requires an explicit trial update before export. Review decisions
are saved under `.ccs_eegstudio_cache/erp_review/` beside the analysis input, with
`~/.config/ccs-eeg-studio/erp_review/` as a fallback. Different input files or
protocols use different decision files. Accepted-epoch exports retain source
onsets, condition labels, trial annotations, processing history and the original
accepted/rejected trial indices.

**Epoch → Clean** remains supported: save the reviewed epochs and use them for
cleaning. The waveform's trial boundaries are preserved. Standard **Clean →
Epoch** processing uses the finalised continuous analysis copy.
