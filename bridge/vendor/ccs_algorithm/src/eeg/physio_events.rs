use serde::{Deserialize, Serialize};
use std::f64::consts::PI;

use crate::cardiac::peaks::detect_ecg_peaks;
use crate::eeg::Recording;

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct PhysioEventOptions {
    pub detect_blinks: bool,
    pub detect_eye_movements: bool,
    pub detect_emg_surges: bool,
    pub detect_ecg: bool,
    pub detect_artifact_bursts: bool,
    pub blink_channel: String,
    pub eog_channel: String,
    pub emg_channel: String,
    pub ecg_channel: String,
    pub eye_movement_z: f64,
    pub emg_z: f64,
    pub emg_min_duration_sec: f64,
    pub artifact_z: f64,
    pub artifact_min_uv: f64,
}

impl Default for PhysioEventOptions {
    fn default() -> Self {
        Self {
            detect_blinks: true,
            detect_eye_movements: true,
            detect_emg_surges: true,
            detect_ecg: true,
            detect_artifact_bursts: false,
            blink_channel: String::new(),
            eog_channel: String::new(),
            emg_channel: String::new(),
            ecg_channel: String::new(),
            eye_movement_z: 3.5,
            emg_z: 3.5,
            emg_min_duration_sec: 0.25,
            artifact_z: 5.0,
            artifact_min_uv: 150.0,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct DetectedPhysioEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    pub description: String,
    pub start_seconds: f64,
    pub duration_seconds: f64,
    pub channel: String,
    pub score: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct PhysioEventSummary {
    pub duration_seconds: f64,
    pub blink_count: usize,
    pub blink_rate_per_min: f64,
    pub blink_channel: Option<String>,
    pub eye_movement_count: usize,
    pub eye_movement_rate_per_min: f64,
    pub eye_movement_channel: Option<String>,
    pub emg_surge_count: usize,
    pub emg_surge_rate_per_min: f64,
    pub emg_burden_pct: f64,
    pub emg_mean_duration_sec: f64,
    pub emg_channels: Vec<String>,
    pub ecg_r_peak_count: usize,
    pub heart_rate_bpm: Option<f64>,
    pub mean_rr_ms: Option<f64>,
    pub sdnn_ms: Option<f64>,
    pub rmssd_ms: Option<f64>,
    pub ecg_channel: Option<String>,
    pub artifact_burst_count: usize,
    pub notes: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct PhysioEventResult {
    pub events: Vec<DetectedPhysioEvent>,
    pub summary: PhysioEventSummary,
}

pub fn extract_physio_events(
    rec: &Recording,
    opts: &PhysioEventOptions,
) -> Result<PhysioEventResult, String> {
    if rec.channels.is_empty() {
        return Err("Recording has no channels".into());
    }
    if !rec.rate.is_finite() || rec.rate <= 0.0 {
        return Err("Recording has invalid sample rate".into());
    }
    let n_samples = rec.channels.iter().map(Vec::len).min().unwrap_or(0);
    if n_samples < 8 {
        return Err("Recording is too short for physiological event extraction".into());
    }
    let rate = rec.rate;
    let duration_sec = n_samples as f64 / rate;
    let minutes = (duration_sec / 60.0).max(1e-6);

    let mut summary = PhysioEventSummary {
        duration_seconds: duration_sec,
        ..Default::default()
    };
    let mut events = Vec::<DetectedPhysioEvent>::new();
    let mut blink_times = Vec::<f64>::new();

    // 1. Eye blinks (VEOG / frontal EEG)
    if opts.detect_blinks {
        if let Some((ch_idx, ch_name)) = pick_blink_channel(&rec.labels, &opts.blink_channel) {
            summary.blink_channel = Some(ch_name.clone());
            let sig = finite_f64(&rec.channels[ch_idx][..n_samples]);
            let mut peaks_0: Vec<usize> = match ccs_ica::blink::eyeblink_detection(&sig, rate) {
                Ok(groups) if !groups.is_empty() => groups
                    .into_iter()
                    .next()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|p| p.saturating_sub(1))
                    .collect(),
                _ => Vec::new(),
            };
            // Filtered signal for local FWHM / z-score and sparse fallback detection.
            let lo = 1.5_f64.min(0.2 * rate);
            let hi = 15.0_f64.min(0.45 * rate);
            let filt = if hi > lo + 0.5 {
                butter_bandpass_zero_phase(&sig, rate, Some(lo), Some(hi), 4)
            } else {
                demean_vec(&sig)
            };
            let (med, mad_sd) = median_and_mad(&filt);
            if peaks_0.is_empty() && mad_sd > 1e-6 {
                peaks_0 = detect_abs_peaks(&filt, rate, med, mad_sd, 4.0, 0.50);
            }
            peaks_0.sort_unstable();
            peaks_0.dedup();
            for &pk in &peaks_0 {
                if pk >= n_samples {
                    continue;
                }
                let t = pk as f64 / rate;
                blink_times.push(t);
                let dur = estimate_blink_duration(&filt, pk, med, rate);
                let z = if mad_sd > 1e-9 {
                    (filt[pk] - med).abs() / mad_sd
                } else {
                    0.0
                };
                events.push(DetectedPhysioEvent {
                    event_type: "Physio/Blink".into(),
                    description: "Blink".into(),
                    start_seconds: (t - dur * 0.4).max(0.0),
                    duration_seconds: dur,
                    channel: ch_name.clone(),
                    score: round2(z),
                });
            }
            summary.blink_count = peaks_0.len();
            summary.blink_rate_per_min = round2(peaks_0.len() as f64 / minutes);
        } else {
            summary
                .notes
                .push("Blink extraction skipped: no matching EOG/frontal channel.".into());
        }
    }

    // 2. Eye movements / horizontal saccades (HEOG / bipolar horizontal frontal pair)
    if opts.detect_eye_movements {
        if let Some((sig, label, is_bipolar)) =
            build_eye_movement_signal(rec, n_samples, &opts.eog_channel)
        {
            summary.eye_movement_channel = Some(label.clone());
            let z_thr = if opts.eye_movement_z.is_finite() && opts.eye_movement_z > 0.5 {
                opts.eye_movement_z
            } else {
                3.5
            };
            let hi = 10.0_f64.min(0.45 * rate);
            let lo = 0.3_f64.min(hi * 0.3);
            let filt = if hi > lo + 0.2 {
                butter_bandpass_zero_phase(&sig, rate, Some(lo), Some(hi), 4)
            } else {
                demean_vec(&sig)
            };
            let win = ((0.020 * rate).round() as usize).max(1);
            let mut vel = vec![0.0_f64; n_samples];
            let dt = (2 * win) as f64 / rate;
            for i in win..n_samples.saturating_sub(win) {
                vel[i] = (filt[i + win] - filt[i - win]) / dt;
            }
            let (v_med, v_mad) = median_and_mad(&vel);
            if v_mad > 1e-6 {
                let mut active = vec![false; n_samples];
                for (i, &v) in vel.iter().enumerate() {
                    if (v - v_med).abs() > z_thr * v_mad {
                        active[i] = true;
                    }
                }
                let runs = extract_runs(&active, rate, 0.015, 0.060);
                let mut last_kept = -1.0_f64;
                let mut count = 0usize;
                for (s, e) in runs {
                    let mid = (s + e) / 2;
                    let t_onset = s as f64 / rate;
                    let t_mid = mid as f64 / rate;
                    let dur = ((e - s + 1) as f64 / rate).min(0.60);
                    if last_kept >= 0.0 && (t_onset - last_kept) < 0.20 {
                        continue;
                    }
                    // Exclude eye-movement detections coinciding with a blink peak.
                    if blink_times.iter().any(|&bt| (bt - t_mid).abs() < 0.14) {
                        continue;
                    }
                    let mut peak_signed = 0.0_f64;
                    let mut peak_abs = 0.0_f64;
                    for idx in s..=e {
                        let d = vel[idx] - v_med;
                        if d.abs() > peak_abs {
                            peak_abs = d.abs();
                            peak_signed = d;
                        }
                    }
                    let desc = if is_bipolar {
                        if peak_signed >= 0.0 {
                            "EyeMove_Right"
                        } else {
                            "EyeMove_Left"
                        }
                    } else {
                        "EyeMove"
                    };
                    events.push(DetectedPhysioEvent {
                        event_type: "Physio/EyeMovement".into(),
                        description: desc.into(),
                        start_seconds: t_onset,
                        duration_seconds: round3(dur),
                        channel: label.clone(),
                        score: round2(peak_abs / v_mad),
                    });
                    last_kept = t_onset;
                    count += 1;
                }
                summary.eye_movement_count = count;
                summary.eye_movement_rate_per_min = round2(count as f64 / minutes);
            }
        } else {
            summary
                .notes
                .push("Eye-movement extraction skipped: no EOG or frontal lateral pair found.".into());
        }
    }

    // 3. EMG surges (cognitive strain / jaw / temporalis muscle bursts)
    if opts.detect_emg_surges {
        if rate <= 45.0 {
            summary.notes.push(format!(
                "EMG surge extraction skipped: sample rate {:.1} Hz is too low (>45 Hz needed).",
                rate
            ));
        } else {
            let emg_idxs = pick_emg_channels(&rec.labels, &opts.emg_channel);
            if emg_idxs.is_empty() {
                summary
                    .notes
                    .push("EMG surge extraction skipped: no EMG or temporal/frontal EEG channels found.".into());
            } else {
                summary.emg_channels = emg_idxs.iter().map(|&i| rec.labels[i].clone()).collect();
                let lo = 20.0_f64;
                let hi = 90.0_f64.min(0.45 * rate);
                let step = ((0.050 * rate).round() as usize).max(1);
                let win = ((0.250 * rate).round() as usize).max(2);
                let n_frames = (n_samples.saturating_sub(win) / step).max(1);
                let mut max_z = vec![0.0_f64; n_frames];
                let mut best_ch = vec![0usize; n_frames];

                for &ch_i in &emg_idxs {
                    let sig = finite_f64(&rec.channels[ch_i][..n_samples]);
                    let filt = butter_bandpass_zero_phase(&sig, rate, Some(lo), Some(hi), 4);
                    let mut env = Vec::with_capacity(n_frames);
                    for f in 0..n_frames {
                        let start = f * step;
                        let end = (start + win).min(n_samples);
                        let rms = (filt[start..end].iter().map(|v| v * v).sum::<f64>()
                            / (end - start).max(1) as f64)
                            .sqrt();
                        env.push(rms);
                    }
                    let (med, mad_sd) = median_and_mad(&env);
                    let scale = mad_sd.max(med * 0.15).max(1e-6);
                    for (f, &val) in env.iter().enumerate() {
                        let z = (val - med) / scale;
                        if z > max_z[f] {
                            max_z[f] = z;
                            best_ch[f] = ch_i;
                        }
                    }
                }

                let emg_z_thr = if opts.emg_z.is_finite() && opts.emg_z > 0.5 {
                    opts.emg_z
                } else {
                    3.5
                };
                let min_dur = if opts.emg_min_duration_sec.is_finite() && opts.emg_min_duration_sec > 0.0 {
                    opts.emg_min_duration_sec
                } else {
                    0.25
                };
                let frame_rate = rate / step as f64;
                let active: Vec<bool> = max_z.iter().map(|&z| z > emg_z_thr).collect();
                let runs = extract_runs(&active, frame_rate, min_dur, 0.30);
                let mut total_dur = 0.0_f64;
                for &(fs_idx, fe_idx) in &runs {
                    let s_sec = (fs_idx * step) as f64 / rate;
                    let e_sec = (((fe_idx + 1) * step + win / 2).min(n_samples)) as f64 / rate;
                    let dur = (e_sec - s_sec).max(min_dur);
                    total_dur += dur;
                    let mut pk_z = 0.0_f64;
                    let mut pk_ch = best_ch[fs_idx];
                    for f in fs_idx..=fe_idx {
                        if max_z[f] > pk_z {
                            pk_z = max_z[f];
                            pk_ch = best_ch[f];
                        }
                    }
                    events.push(DetectedPhysioEvent {
                        event_type: "Physio/EMG".into(),
                        description: "EMG_Surge".into(),
                        start_seconds: round3(s_sec),
                        duration_seconds: round3(dur),
                        channel: rec.labels[pk_ch].clone(),
                        score: round2(pk_z),
                    });
                }
                summary.emg_surge_count = runs.len();
                summary.emg_surge_rate_per_min = round2(runs.len() as f64 / minutes);
                summary.emg_burden_pct = round2((total_dur / duration_sec * 100.0).min(100.0));
                summary.emg_mean_duration_sec = if runs.is_empty() {
                    0.0
                } else {
                    round3(total_dur / runs.len() as f64)
                };
            }
        }
    }

    // 4. ECG R-peaks (Heartbeat-Evoked Potential / HEP analysis & autonomic timing)
    if opts.detect_ecg {
        if let Some((ch_idx, ch_name)) = pick_ecg_channel(&rec.labels, &opts.ecg_channel) {
            summary.ecg_channel = Some(ch_name.clone());
            let sig = finite_f64(&rec.channels[ch_idx][..n_samples]);
            let lo = 5.0_f64.min(0.2 * rate);
            let hi = 35.0_f64.min(0.45 * rate);
            let filt = if hi > lo + 1.0 {
                butter_bandpass_zero_phase(&sig, rate, Some(lo), Some(hi), 4)
            } else {
                demean_vec(&sig)
            };
            let neg_filt: Vec<f64> = filt.iter().map(|v| -v).collect();
            let pos_peaks = refine_ecg_r_peaks(detect_ecg_peaks(&filt, rate), &filt, rate);
            let neg_peaks = refine_ecg_r_peaks(detect_ecg_peaks(&neg_filt, rate), &neg_filt, rate);
            let (chosen, used_neg) = if score_ecg_train(&neg_peaks, &neg_filt, rate)
                > score_ecg_train(&pos_peaks, &filt, rate)
            {
                (neg_peaks, true)
            } else {
                (pos_peaks, false)
            };

            let (_, mad_sd) = median_and_mad(&filt);
            let min_rr = 0.30_f64;
            let mut rr_ms = Vec::new();
            let mut prev_t: Option<f64> = None;
            let mut kept_peaks = Vec::with_capacity(chosen.len());
            for pk in chosen {
                if pk >= n_samples {
                    continue;
                }
                let t = pk as f64 / rate;
                if let Some(pt) = prev_t {
                    if t - pt < min_rr {
                        continue;
                    }
                    let rr = (t - pt) * 1000.0;
                    if (300.0..=2000.0).contains(&rr) {
                        rr_ms.push(rr);
                    }
                }
                prev_t = Some(t);
                kept_peaks.push(pk);
                let amp = if used_neg { -filt[pk] } else { filt[pk] };
                let z = if mad_sd > 1e-9 { amp / mad_sd } else { 0.0 };
                events.push(DetectedPhysioEvent {
                    event_type: "Physio/ECG".into(),
                    description: "ECG_R".into(),
                    start_seconds: round4(t),
                    duration_seconds: 0.0,
                    channel: ch_name.clone(),
                    score: round2(z),
                });
            }
            summary.ecg_r_peak_count = kept_peaks.len();
            if !rr_ms.is_empty() {
                let mean_rr = rr_ms.iter().sum::<f64>() / rr_ms.len() as f64;
                summary.mean_rr_ms = Some(round2(mean_rr));
                if mean_rr > 0.0 {
                    summary.heart_rate_bpm = Some(round2(60000.0 / mean_rr));
                }
                if rr_ms.len() >= 2 {
                    let var = rr_ms
                        .iter()
                        .map(|r| (r - mean_rr).powi(2))
                        .sum::<f64>()
                        / (rr_ms.len() - 1) as f64;
                    summary.sdnn_ms = Some(round2(var.sqrt()));
                    let rmssd = (rr_ms
                        .windows(2)
                        .map(|w| (w[1] - w[0]).powi(2))
                        .sum::<f64>()
                        / (rr_ms.len() - 1) as f64)
                        .sqrt();
                    summary.rmssd_ms = Some(round2(rmssd));
                }
            } else if kept_peaks.len() < 2 {
                summary.notes.push(format!(
                    "ECG channel '{}' yielded {} R-peak(s); check signal quality or channel gain.",
                    ch_name,
                    kept_peaks.len()
                ));
            }
        } else {
            summary.notes.push(
                "No dedicated ECG channel matched (e.g. ECG, EKG); choose a channel manually if your cardiac lead uses another name."
                    .into(),
            );
        }
    }

    // 5. Optional high-amplitude multi-channel artifact bursts
    if opts.detect_artifact_bursts {
        let eeg_idxs: Vec<usize> = rec
            .labels
            .iter()
            .enumerate()
            .filter(|(_, l)| !is_aux_channel_label(l))
            .map(|(i, _)| i)
            .collect();
        if !eeg_idxs.is_empty() {
            let step = ((0.050 * rate).round() as usize).max(1);
            let win = ((0.250 * rate).round() as usize).max(2);
            let n_frames = (n_samples.saturating_sub(win) / step).max(1);
            let mut votes = vec![0usize; n_frames];
            let mut frame_max_z = vec![0.0_f64; n_frames];
            let mut frame_ch = vec![eeg_idxs[0]; n_frames];
            let art_z = if opts.artifact_z.is_finite() && opts.artifact_z > 0.5 {
                opts.artifact_z
            } else {
                5.0
            };
            let min_uv = opts.artifact_min_uv.max(0.0);

            for &ch_i in &eeg_idxs {
                let sig = finite_f64(&rec.channels[ch_i][..n_samples]);
                let hp = if rate > 4.0 {
                    butter_bandpass_zero_phase(&sig, rate, Some(1.0), None, 4)
                } else {
                    demean_vec(&sig)
                };
                let mut peak_env = Vec::with_capacity(n_frames);
                for f in 0..n_frames {
                    let s = f * step;
                    let e = (s + win).min(n_samples);
                    let mx = hp[s..e].iter().map(|v| v.abs()).fold(0.0_f64, f64::max);
                    peak_env.push(mx);
                }
                let (med, mad_sd) = median_and_mad(&peak_env);
                let scale = mad_sd.max(1e-6);
                for (f, &val) in peak_env.iter().enumerate() {
                    let z = (val - med) / scale;
                    if z > art_z && val >= min_uv {
                        votes[f] += 1;
                    }
                    if z > frame_max_z[f] {
                        frame_max_z[f] = z;
                        frame_ch[f] = ch_i;
                    }
                }
            }
            let min_votes = eeg_idxs.len().min(2);
            let active: Vec<bool> = votes.iter().map(|&v| v >= min_votes).collect();
            let runs = extract_runs(&active, rate / step as f64, 0.05, 0.30);
            for &(fs_idx, fe_idx) in &runs {
                let s_sec = (fs_idx * step) as f64 / rate;
                let e_sec = (((fe_idx + 1) * step + win / 2).min(n_samples)) as f64 / rate;
                let mut pk_z = 0.0_f64;
                let mut pk_ch = frame_ch[fs_idx];
                for f in fs_idx..=fe_idx {
                    if frame_max_z[f] > pk_z {
                        pk_z = frame_max_z[f];
                        pk_ch = frame_ch[f];
                    }
                }
                events.push(DetectedPhysioEvent {
                    event_type: "Physio/Artifact".into(),
                    description: "Artifact_Burst".into(),
                    start_seconds: round3(s_sec),
                    duration_seconds: round3((e_sec - s_sec).max(0.05)),
                    channel: rec.labels[pk_ch].clone(),
                    score: round2(pk_z),
                });
            }
            summary.artifact_burst_count = runs.len();
        }
    }

    events.sort_by(|a, b| a.start_seconds.total_cmp(&b.start_seconds));
    Ok(PhysioEventResult { events, summary })
}

fn find_label(labels: &[String], target: &str) -> Option<(usize, String)> {
    let t = target.trim();
    if t.is_empty() {
        return None;
    }
    labels
        .iter()
        .position(|l| l.trim().eq_ignore_ascii_case(t))
        .map(|i| (i, labels[i].clone()))
}

fn match_candidates(labels: &[String], exact_names: &[&str], contains: &[&str]) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    for name in exact_names {
        if let Some((i, l)) = find_label(labels, name) {
            if !out.iter().any(|(idx, _)| *idx == i) {
                out.push((i, l));
            }
        }
    }
    if out.is_empty() && !contains.is_empty() {
        for (i, l) in labels.iter().enumerate() {
            let up = l.to_uppercase();
            if contains.iter().any(|c| up.contains(c)) {
                out.push((i, l.clone()));
            }
        }
    }
    out
}

fn pick_blink_channel(labels: &[String], override_ch: &str) -> Option<(usize, String)> {
    if let Some(hit) = find_label(labels, override_ch) {
        return Some(hit);
    }
    let candidates = match_candidates(
        labels,
        &[
            "VEOG", "EOG1", "VEO", "VEOG+", "SO1", "SO2", "IO1", "IO2", "EOG",
            "Fp1", "Fp2", "AFz", "Fpz", "AF3", "AF4", "Fz",
        ],
        &["VEOG", "EOG"],
    );
    candidates
        .into_iter()
        .next()
        .or_else(|| labels.first().map(|l| (0, l.clone())))
}

fn build_eye_movement_signal(
    rec: &Recording,
    n_samples: usize,
    override_ch: &str,
) -> Option<(Vec<f64>, String, bool)> {
    if let Some((idx, name)) = find_label(&rec.labels, override_ch) {
        return Some((finite_f64(&rec.channels[idx][..n_samples]), name, false));
    }
    if let Some((idx, name)) = find_label(&rec.labels, "HEOG") {
        return Some((finite_f64(&rec.channels[idx][..n_samples]), name, true));
    }
    for (left, right) in [
        ("LEOG", "REOG"),
        ("LO1", "LO2"),
        ("EOG1", "EOG2"),
        ("HEOG+", "HEOG-"),
        ("F7", "F8"),
        ("AF7", "AF8"),
        ("Fp1", "Fp2"),
        ("F3", "F4"),
    ] {
        if let (Some((li, ln)), Some((ri, rn))) =
            (find_label(&rec.labels, left), find_label(&rec.labels, right))
        {
            let diff: Vec<f64> = (0..n_samples)
                .map(|s| {
                    let a = rec.channels[ri][s] as f64;
                    let b = rec.channels[li][s] as f64;
                    let d = a - b;
                    if d.is_finite() { d } else { 0.0 }
                })
                .collect();
            return Some((diff, format!("{rn}-{ln}"), true));
        }
    }
    for (i, l) in rec.labels.iter().enumerate() {
        let up = l.to_uppercase();
        if up.contains("EOG") {
            return Some((finite_f64(&rec.channels[i][..n_samples]), l.clone(), false));
        }
    }
    None
}

fn pick_emg_channels(labels: &[String], override_ch: &str) -> Vec<usize> {
    if let Some((idx, _)) = find_label(labels, override_ch) {
        return vec![idx];
    }
    let dedicated = match_candidates(
        labels,
        &["EMG", "EMG1", "EMG2", "CHIN", "CHIN1", "MASS", "JAW", "EMG_L", "EMG_R"],
        &["EMG", "CHIN", "MASS"],
    );
    if !dedicated.is_empty() {
        return dedicated.into_iter().map(|(i, _)| i).collect();
    }
    let peripheral = match_candidates(
        labels,
        &["T7", "T8", "FT9", "FT10", "TP9", "TP10", "F7", "F8", "Fp1", "Fp2"],
        &[],
    );
    if !peripheral.is_empty() {
        return peripheral.into_iter().map(|(i, _)| i).collect();
    }
    labels
        .iter()
        .enumerate()
        .filter(|(_, l)| !is_aux_channel_label(l))
        .map(|(i, _)| i)
        .collect()
}

fn pick_ecg_channel(labels: &[String], override_ch: &str) -> Option<(usize, String)> {
    if let Some(hit) = find_label(labels, override_ch) {
        return Some(hit);
    }
    match_candidates(
        labels,
        &["ECG", "EKG", "ECG1", "ECG2", "EKG1", "EKG2", "HEART", "EKG_L", "ECG_L"],
        &["ECG", "EKG", "HEART"],
    )
    .into_iter()
    .next()
}

fn is_aux_channel_label(label: &str) -> bool {
    let up = label.to_uppercase();
    ["ECG", "EKG", "EOG", "EMG", "GSR", "RESP", "PPG", "X_DIR", "Y_DIR", "Z_DIR", "STATUS", "MARK"]
        .iter()
        .any(|k| up.contains(k))
}

fn finite_f64(xs: &[f32]) -> Vec<f64> {
    xs.iter()
        .map(|&v| if v.is_finite() { v as f64 } else { 0.0 })
        .collect()
}

fn demean_vec(xs: &[f64]) -> Vec<f64> {
    if xs.is_empty() {
        return Vec::new();
    }
    let m = xs.iter().sum::<f64>() / xs.len() as f64;
    xs.iter().map(|&v| v - m).collect()
}

fn median_and_mad(xs: &[f64]) -> (f64, f64) {
    if xs.is_empty() {
        return (0.0, 0.0);
    }
    let mut sorted = xs.to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let med = sorted[sorted.len() / 2];
    let mut devs: Vec<f64> = sorted.iter().map(|&v| (v - med).abs()).collect();
    devs.sort_by(|a, b| a.total_cmp(b));
    let mad_sd = devs[devs.len() / 2] * 1.4826;
    (med, mad_sd)
}

fn butter_bandpass_zero_phase(
    x: &[f64],
    rate: f64,
    low: Option<f64>,
    high: Option<f64>,
    order: usize,
) -> Vec<f64> {
    let mut out = demean_vec(x);
    if out.len() < 4 {
        return out;
    }
    let sections = (order / 2).max(1);
    if let Some(cutoff) = low {
        if cutoff > 0.0 && cutoff < rate * 0.5 {
            for s in 0..sections {
                let q = 1.0 / (2.0 * ((2 * s + 1) as f64 * PI / (2 * order) as f64).cos());
                let w = 2.0 * PI * cutoff / rate;
                let c = w.cos();
                let a = w.sin() / (2.0 * q);
                let a0 = 1.0 + a;
                biquad_zero_phase(
                    &mut out,
                    [(1.0 + c) / 2.0 / a0, -(1.0 + c) / a0, (1.0 + c) / 2.0 / a0],
                    [-2.0 * c / a0, (1.0 - a) / a0],
                );
            }
        }
    }
    if let Some(cutoff) = high {
        if cutoff > 0.0 && cutoff < rate * 0.5 {
            for s in 0..sections {
                let q = 1.0 / (2.0 * ((2 * s + 1) as f64 * PI / (2 * order) as f64).cos());
                let w = 2.0 * PI * cutoff / rate;
                let c = w.cos();
                let a = w.sin() / (2.0 * q);
                let a0 = 1.0 + a;
                biquad_zero_phase(
                    &mut out,
                    [(1.0 - c) / 2.0 / a0, (1.0 - c) / a0, (1.0 - c) / 2.0 / a0],
                    [-2.0 * c / a0, (1.0 - a) / a0],
                );
            }
        }
    }
    out
}

fn biquad_zero_phase(x: &mut [f64], b: [f64; 3], a: [f64; 2]) {
    if x.len() < 3 {
        return;
    }
    let pad = 24.min(x.len() - 1);
    let mut vals = Vec::with_capacity(x.len() + 2 * pad);
    for i in (1..=pad).rev() {
        vals.push(2.0 * x[0] - x[i]);
    }
    vals.extend_from_slice(x);
    for i in 1..=pad {
        vals.push(2.0 * x[x.len() - 1] - x[x.len() - 1 - i]);
    }
    for _ in 0..2 {
        let initial = vals[0];
        let denom = 1.0 + a[0] + a[1];
        let gain = if denom.abs() > 1e-12 {
            (b[0] + b[1] + b[2]) / denom
        } else {
            0.0
        };
        let mut z1 = (gain - b[0]) * initial;
        let mut z2 = (b[2] - a[1] * gain) * initial;
        for v in &mut vals {
            let input = *v;
            let output = b[0] * input + z1;
            z1 = b[1] * input - a[0] * output + z2;
            z2 = b[2] * input - a[1] * output;
            *v = output;
        }
        vals.reverse();
    }
    x.copy_from_slice(&vals[pad..pad + x.len()]);
}

fn detect_abs_peaks(
    x: &[f64],
    rate: f64,
    med: f64,
    mad_sd: f64,
    z_thr: f64,
    min_dist_sec: f64,
) -> Vec<usize> {
    let min_dist = ((min_dist_sec * rate).round() as usize).max(1);
    let mut cands = Vec::new();
    for i in 1..x.len().saturating_sub(1) {
        let a = (x[i] - med).abs();
        if a > z_thr * mad_sd
            && a >= (x[i - 1] - med).abs()
            && a >= (x[i + 1] - med).abs()
        {
            cands.push((i, a));
        }
    }
    cands.sort_by(|a, b| b.1.total_cmp(&a.1));
    let mut kept: Vec<usize> = Vec::new();
    for (idx, _) in cands {
        if kept.iter().all(|&k| k.abs_diff(idx) >= min_dist) {
            kept.push(idx);
        }
    }
    kept.sort_unstable();
    kept
}

fn estimate_blink_duration(x: &[f64], pk: usize, med: f64, rate: f64) -> f64 {
    let pk_amp = (x[pk] - med).abs();
    if pk_amp <= 1e-9 {
        return 0.30;
    }
    let half = 0.4 * pk_amp;
    let max_step = ((0.35 * rate).round() as usize).max(2);
    let mut left = 0usize;
    while left < max_step && pk >= left + 1 && (x[pk - left] - med).abs() > half {
        left += 1;
    }
    let mut right = 0usize;
    while right < max_step && pk + right + 1 < x.len() && (x[pk + right] - med).abs() > half {
        right += 1;
    }
    let dur = (left + right) as f64 / rate;
    round3(dur.clamp(0.15, 0.55))
}

fn extract_runs(active: &[bool], rate: f64, min_dur_sec: f64, merge_gap_sec: f64) -> Vec<(usize, usize)> {
    let mut raw = Vec::<(usize, usize)>::new();
    let mut i = 0usize;
    while i < active.len() {
        if !active[i] {
            i += 1;
            continue;
        }
        let s = i;
        while i + 1 < active.len() && active[i + 1] {
            i += 1;
        }
        raw.push((s, i));
        i += 1;
    }
    if raw.is_empty() {
        return raw;
    }
    let max_gap = (merge_gap_sec * rate).round() as usize;
    let mut merged = Vec::with_capacity(raw.len());
    let mut cur = raw[0];
    for &(s, e) in raw.iter().skip(1) {
        if s.saturating_sub(cur.1) <= max_gap {
            cur.1 = e;
        } else {
            merged.push(cur);
            cur = (s, e);
        }
    }
    merged.push(cur);
    let min_samples = ((min_dur_sec * rate).round() as usize).max(1);
    merged
        .into_iter()
        .filter(|&(s, e)| e - s + 1 >= min_samples)
        .collect()
}

fn refine_ecg_r_peaks(peaks: Vec<usize>, filt: &[f64], rate: f64) -> Vec<usize> {
    let rad = ((0.03 * rate).round() as usize).max(1);
    peaks
        .into_iter()
        .filter_map(|p| {
            if p >= filt.len() {
                return None;
            }
            let s = p.saturating_sub(rad);
            let e = (p + rad).min(filt.len() - 1);
            let mut best_i = s;
            let mut best_v = filt[s];
            for i in s..=e {
                if filt[i] > best_v {
                    best_v = filt[i];
                    best_i = i;
                }
            }
            Some(best_i)
        })
        .collect()
}

fn score_ecg_train(peaks: &[usize], filt: &[f64], rate: f64) -> f64 {
    if peaks.len() < 2 {
        return peaks.first().map(|&p| filt[p].max(0.0)).unwrap_or(0.0);
    }
    let mean_amp = peaks.iter().map(|&p| filt[p]).sum::<f64>() / peaks.len() as f64;
    let rr: Vec<f64> = peaks
        .windows(2)
        .map(|w| (w[1] - w[0]) as f64 / rate)
        .filter(|&d| (0.33..=1.80).contains(&d))
        .collect();
    if rr.is_empty() {
        return mean_amp * 0.2;
    }
    let rr_frac = rr.len() as f64 / (peaks.len() - 1) as f64;
    mean_amp * (0.5 + rr_frac)
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

fn round4(v: f64) -> f64 {
    (v * 10000.0).round() / 10000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_blinks_eye_movements_emg_and_ecg() {
        let fs = 250.0;
        let secs = 20.0;
        let n = (fs * secs) as usize;
        let mut fp1 = vec![0.0_f32; n];
        let mut f7 = vec![0.0_f32; n];
        let mut f8 = vec![0.0_f32; n];
        let mut t7 = vec![0.0_f32; n];
        let mut ecg = vec![0.0_f32; n];

        for i in 0..n {
            let t = i as f64 / fs;
            // Background low-amplitude alpha/pink-like carrier
            let bg = 2.0 * (2.0 * PI * 10.0 * t).sin() + 1.0 * (2.0 * PI * 3.7 * t).cos();
            fp1[i] = bg as f32;
            f7[i] = bg as f32;
            f8[i] = bg as f32;
            t7[i] = bg as f32;
            ecg[i] = (5.0 * (2.0 * PI * 1.5 * t).sin()) as f32;
        }

        // Blinks at 3.0, 7.0, 11.0, 15.0 s on Fp1 (common mode across F7/F8 too)
        for &bt in &[3.0_f64, 7.0, 11.0, 15.0] {
            for k in -45..=45 {
                let idx = (bt * fs).round() as isize + k;
                if idx >= 0 && (idx as usize) < n {
                    let g = 140.0 * (-((k as f64 / 15.0).powi(2))).exp();
                    fp1[idx as usize] += g as f32;
                    f7[idx as usize] += (0.5 * g) as f32;
                    f8[idx as usize] += (0.5 * g) as f32;
                }
            }
        }

        // Horizontal saccades at 5.0 s (rightward: F8-F7 step) and 13.0 s (leftward)
        for i in 0..n {
            let t = i as f64 / fs;
            let sacc = if (5.0..6.5).contains(&t) {
                80.0 / (1.0 + (-40.0 * (t - 5.0)).exp()) - 80.0 / (1.0 + (-40.0 * (t - 6.5)).exp())
            } else if (13.0..14.5).contains(&t) {
                -(80.0 / (1.0 + (-40.0 * (t - 13.0)).exp()) - 80.0 / (1.0 + (-40.0 * (t - 14.5)).exp()))
            } else {
                0.0
            };
            f8[i] += sacc as f32;
            f7[i] -= sacc as f32;
        }

        // High-frequency EMG surge 8.5..9.5 s on T7 (45 Hz burst)
        for i in 0..n {
            let t = i as f64 / fs;
            if (8.5..9.5).contains(&t) {
                t7[i] += (65.0 * (2.0 * PI * 45.0 * t).sin()) as f32;
            }
        }

        // ECG R-peaks every 1.0 s (60 bpm) at 1.0, 2.0, ..., 19.0 s
        for sec in 1..20 {
            let center = (sec as f64 * fs).round() as isize;
            for k in -10..=10 {
                let idx = center + k;
                if idx >= 0 && (idx as usize) < n {
                    let qrs = 850.0 * (-((k as f64 / 2.5).powi(2))).exp();
                    ecg[idx as usize] += qrs as f32;
                }
            }
        }

        let rec = Recording {
            rate: fs,
            labels: vec!["Fp1".into(), "F7".into(), "F8".into(), "T7".into(), "ECG".into()],
            channels: vec![fp1, f7, f8, t7, ecg],
            source_epoch_samples: None,
            epoch_labels: None,
        };
        let res = extract_physio_events(&rec, &PhysioEventOptions::default()).unwrap();
        assert!(res.summary.blink_count >= 3, "blinks={}", res.summary.blink_count);
        assert!(
            res.summary.eye_movement_count >= 2,
            "eye_movements={}",
            res.summary.eye_movement_count
        );
        assert!(res.summary.emg_surge_count >= 1, "emg={}", res.summary.emg_surge_count);
        assert!(res.summary.emg_burden_pct > 2.0);
        assert!(
            res.summary.ecg_r_peak_count >= 16,
            "ecg={}",
            res.summary.ecg_r_peak_count
        );
        let hr = res.summary.heart_rate_bpm.unwrap();
        assert!((hr - 60.0).abs() < 3.0, "hr={hr}");
        assert!(res.events.iter().any(|e| e.event_type == "Physio/EMG"));
        assert!(res.events.iter().any(|e| e.event_type == "Physio/ECG"));
    }
}
