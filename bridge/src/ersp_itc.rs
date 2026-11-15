use rand::rngs::StdRng;
use rand::seq::SliceRandom;
use rand::{Rng, SeedableRng};
use rayon::prelude::*;
use rustfft::num_complex::Complex64;
use rustfft::FftPlanner;
use serde::{Deserialize, Serialize};
use std::f64::consts::PI;
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct ErspItcJob {
    pub recording_path: String,
    #[serde(default)]
    pub channel_name: String,
    #[serde(default)]
    pub roi_channels: Vec<String>,
    #[serde(default)]
    pub condition_a_trials: Vec<usize>,
    #[serde(default)]
    pub condition_b_trials: Vec<usize>,
    #[serde(default)]
    pub epoch_tmin_ms: Option<f64>,
    #[serde(default = "default_fmin")]
    pub fmin_hz: f64,
    #[serde(default = "default_fmax")]
    pub fmax_hz: f64,
    #[serde(default = "default_nfreqs")]
    pub n_freqs: usize,
    #[serde(default = "default_cycles_min")]
    pub n_cycles_min: f64,
    #[serde(default = "default_cycles_max")]
    pub n_cycles_max: f64,
    #[serde(default = "default_base_start")]
    pub baseline_start_ms: f64,
    #[serde(default = "default_base_end")]
    pub baseline_end_ms: f64,
    #[serde(default = "default_nperm")]
    pub n_perm: usize,
    #[serde(default = "default_seed")]
    pub seed: u64,
}

fn default_fmin() -> f64 {
    2.0
}
fn default_fmax() -> f64 {
    40.0
}
fn default_nfreqs() -> usize {
    24
}
fn default_cycles_min() -> f64 {
    3.0
}
fn default_cycles_max() -> f64 {
    8.0
}
fn default_base_start() -> f64 {
    -200.0
}
fn default_base_end() -> f64 {
    0.0
}
fn default_nperm() -> usize {
    200
}
fn default_seed() -> u64 {
    42
}

#[derive(Debug, Serialize)]
pub struct ErspItcResult {
    pub channel: String,
    pub times_ms: Vec<f64>,
    pub freqs_hz: Vec<f64>,
    pub n_trials_a: usize,
    pub n_trials_b: usize,
    pub ersp_a_db: Vec<f64>,
    pub itc_a: Vec<f64>,
    pub ersp_b_db: Option<Vec<f64>>,
    pub itc_b: Option<Vec<f64>>,
    pub ersp_diff_db: Option<Vec<f64>>,
    pub itc_diff: Option<Vec<f64>>,
    pub p_values_ersp: Vec<f64>,
    pub p_values_itc: Vec<f64>,
    pub trial_indices_a: Vec<usize>,
    pub trial_power_a_db: Vec<f64>,
    pub trial_itc_a: Vec<f64>,
    pub trial_indices_b: Vec<usize>,
    pub trial_power_b_db: Vec<f64>,
    pub trial_itc_b: Vec<f64>,
}

/// Computes complex Morlet wavelet time-frequency decomposition for a single condition's trials.
/// Returns (power_per_trial [n_trials][n_freqs][n_times_out], unit_phase_per_trial [n_trials][n_freqs][n_times_out]).
fn morlet_tfr(
    trials: &[Vec<f64>],
    srate: f64,
    freqs: &[f64],
    cycles: &[f64],
    out_indices: &[usize],
) -> (Vec<Vec<Vec<f64>>>, Vec<Vec<Vec<Complex64>>>) {
    let n_trials = trials.len();
    let n_samples = trials.first().map(|t| t.len()).unwrap_or(0);
    let n_freqs = freqs.len();
    let n_out = out_indices.len();
    if n_trials == 0 || n_samples == 0 || n_freqs == 0 || n_out == 0 {
        return (vec![], vec![]);
    }

    // Pad to next power of two >= n_samples + max_wavelet_len
    let max_half_win = (cycles[0] * srate / freqs[0]).ceil() as usize;
    let fft_len = (n_samples + 2 * max_half_win).next_power_of_two();

    let mut planner = FftPlanner::<f64>::new();
    let fft_fwd = planner.plan_fft_forward(fft_len);
    let fft_inv = planner.plan_fft_inverse(fft_len);

    // Precompute frequency-domain Morlet wavelets
    let wavelet_ffts: Vec<Vec<Complex64>> = freqs
        .iter()
        .zip(cycles.iter())
        .map(|(&f, &cyc)| {
            let sigma_t = cyc / (2.0 * PI * f);
            let half = ((3.0 * sigma_t * srate).ceil() as usize).min(fft_len / 2 - 1);
            let mut w = vec![Complex64::new(0.0, 0.0); fft_len];
            let norm = (1.0 / (sigma_t * (PI).sqrt())).sqrt();
            let mut energy = 0.0;
            for k in -(half as isize)..=(half as isize) {
                let t = k as f64 / srate;
                let gauss = (-t * t / (2.0 * sigma_t * sigma_t)).exp();
                let val = Complex64::from_polar(norm * gauss, 2.0 * PI * f * t);
                let idx = ((k + fft_len as isize) as usize) % fft_len;
                w[idx] = val;
                energy += val.norm_sqr();
            }
            let scale = if energy > 0.0 { 1.0 / energy.sqrt() } else { 1.0 };
            for v in &mut w {
                *v *= scale;
            }
            fft_fwd.process(&mut w);
            w
        })
        .collect();

    // Parallelize across trials
    let results: Vec<(Vec<Vec<f64>>, Vec<Vec<Complex64>>)> = trials
        .par_iter()
        .map(|sig| {
            let mut sig_buf = vec![Complex64::new(0.0, 0.0); fft_len];
            for (i, &v) in sig.iter().enumerate() {
                sig_buf[i] = Complex64::new(v, 0.0);
            }
            fft_fwd.process(&mut sig_buf);

            let mut trial_pow = vec![vec![0.0; n_out]; n_freqs];
            let mut trial_phase = vec![vec![Complex64::new(0.0, 0.0); n_out]; n_freqs];
            let inv_norm = 1.0 / fft_len as f64;

            let mut conv_buf = vec![Complex64::new(0.0, 0.0); fft_len];
            for fi in 0..n_freqs {
                let wfft = &wavelet_ffts[fi];
                for k in 0..fft_len {
                    conv_buf[k] = sig_buf[k] * wfft[k];
                }
                fft_inv.process(&mut conv_buf);
                for (ti, &sample_idx) in out_indices.iter().enumerate() {
                    let c = conv_buf[sample_idx] * inv_norm;
                    let mag2 = c.norm_sqr();
                    trial_pow[fi][ti] = mag2;
                    let mag = mag2.sqrt();
                    trial_phase[fi][ti] = if mag > 1e-12 {
                        c / mag
                    } else {
                        Complex64::new(0.0, 0.0)
                    };
                }
            }
            (trial_pow, trial_phase)
        })
        .collect();

    let mut pow_all = Vec::with_capacity(n_trials);
    let mut phase_all = Vec::with_capacity(n_trials);
    for (p, ph) in results {
        pow_all.push(p);
        phase_all.push(ph);
    }
    (pow_all, phase_all)
}

fn load_epoched_meta_tmin_ms(path: &str, fallback_ms: Option<f64>) -> f64 {
    if let Some(v) = fallback_ms {
        return v;
    }
    if let Ok(bytes) = std::fs::read(path) {
        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes) {
            if let Some(tmin_s) = val["epoch_tmin"].as_f64() {
                if tmin_s.is_finite() {
                    return tmin_s * 1000.0;
                }
            }
        }
    }
    -200.0
}

pub fn run(job: &ErspItcJob) -> Result<ErspItcResult, String> {
    let rec = crate::preprocessing::load_portable(Path::new(&job.recording_path))
        .map_err(|e| format!("Could not load recording '{}': {e}", job.recording_path))?;

    let n_pts = rec.source_epoch_samples.unwrap_or(0);
    let total_samples = rec.channels.first().map(|c| c.len()).unwrap_or(0);
    let epoch_count = if n_pts > 0 { total_samples / n_pts } else { 0 };
    if epoch_count == 0 || n_pts == 0 {
        return Err("ERSP & ITC require an epoched recording.".into());
    }
    let srate = rec.rate;
    let tmin_ms = load_epoched_meta_tmin_ms(&job.recording_path, job.epoch_tmin_ms);
    let dt_ms = 1000.0 / srate;

    // Resolve channel(s)
    let chan_indices: Vec<usize> = if !job.channel_name.is_empty()
        && job.channel_name.to_uppercase() != "ROI"
    {
        let idx = rec
            .labels
            .iter()
            .position(|l| l.eq_ignore_ascii_case(&job.channel_name))
            .ok_or_else(|| format!("Channel '{}' not found", job.channel_name))?;
        vec![idx]
    } else if !job.roi_channels.is_empty() {
        let mut idxs = Vec::new();
        for ch in &job.roi_channels {
            if let Some(i) = rec.labels.iter().position(|l| l.eq_ignore_ascii_case(ch)) {
                idxs.push(i);
            }
        }
        if idxs.is_empty() {
            vec![0]
        } else {
            idxs
        }
    } else {
        vec![0]
    };

    let channel_label = if chan_indices.len() == 1 {
        rec.labels[chan_indices[0]].clone()
    } else {
        format!(
            "ROI ({})",
            chan_indices
                .iter()
                .map(|&i| rec.labels[i].as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )
    };

    let extract_trial = |trial_idx: usize| -> Option<Vec<f64>> {
        if trial_idx >= epoch_count {
            return None;
        }
        let start = trial_idx * n_pts;
        let mut out = vec![0.0; n_pts];
        let denom = chan_indices.len() as f64;
        for &ch in &chan_indices {
            if ch >= rec.channels.len() || start + n_pts > rec.channels[ch].len() {
                return None;
            }
            for s in 0..n_pts {
                out[s] += rec.channels[ch][start + s] as f64 / denom;
            }
        }
        Some(out)
    };

    let trials_a_idx: Vec<usize> = if job.condition_a_trials.is_empty() {
        (0..epoch_count).collect()
    } else {
        job.condition_a_trials
            .iter()
            .copied()
            .filter(|&i| i < epoch_count)
            .collect()
    };
    let trials_b_idx: Vec<usize> = job
        .condition_b_trials
        .iter()
        .copied()
        .filter(|&i| i < epoch_count)
        .collect();

    let trials_a: Vec<Vec<f64>> = trials_a_idx.iter().filter_map(|&i| extract_trial(i)).collect();
    let trials_b: Vec<Vec<f64>> = trials_b_idx.iter().filter_map(|&i| extract_trial(i)).collect();

    if trials_a.is_empty() {
        return Err("No valid trials selected for Condition A.".into());
    }

    // Downsample output time grid to <= 120 points for fast interactive rendering
    let step = (n_pts / 120).max(1);
    let out_indices: Vec<usize> = (0..n_pts).step_by(step).collect();
    let times_ms: Vec<f64> = out_indices
        .iter()
        .map(|&i| tmin_ms + i as f64 * dt_ms)
        .collect();
    let n_out = times_ms.len();

    let n_freqs = job.n_freqs.clamp(4, 60);
    let fmin = job.fmin_hz.max(0.5);
    let fmax = job.fmax_hz.min(srate * 0.45).max(fmin + 1.0);
    let freqs_hz: Vec<f64> = (0..n_freqs)
        .map(|i| {
            if n_freqs == 1 {
                fmin
            } else {
                fmin + (fmax - fmin) * (i as f64) / ((n_freqs - 1) as f64)
            }
        })
        .collect();
    let cycles: Vec<f64> = (0..n_freqs)
        .map(|i| {
            if n_freqs == 1 {
                job.n_cycles_min
            } else {
                job.n_cycles_min
                    + (job.n_cycles_max - job.n_cycles_min) * (i as f64) / ((n_freqs - 1) as f64)
            }
        })
        .collect();

    let base_indices: Vec<usize> = times_ms
        .iter()
        .enumerate()
        .filter(|(_, &t)| t >= job.baseline_start_ms && t <= job.baseline_end_ms)
        .map(|(i, _)| i)
        .collect();
    let base_indices = if base_indices.is_empty() {
        vec![0]
    } else {
        base_indices
    };

    let post_indices: Vec<usize> = times_ms
        .iter()
        .enumerate()
        .filter(|(_, &t)| t >= 0.0)
        .map(|(i, _)| i)
        .collect();
    let post_indices = if post_indices.is_empty() {
        (0..n_out).collect()
    } else {
        post_indices
    };

    let (pow_a, phase_a) = morlet_tfr(&trials_a, srate, &freqs_hz, &cycles, &out_indices);
    let (pow_b, phase_b) = if !trials_b.is_empty() {
        morlet_tfr(&trials_b, srate, &freqs_hz, &cycles, &out_indices)
    } else {
        (vec![], vec![])
    };

    // Baseline power per frequency (computed from mean power across trials in baseline window)
    let compute_ersp_itc = |pow: &[Vec<Vec<f64>>],
                            phase: &[Vec<Vec<Complex64>>],
                            shared_base: Option<&[f64]>|
     -> (Vec<f64>, Vec<f64>, Vec<f64>) {
        let n_tr = pow.len() as f64;
        let mut base_f = vec![0.0; n_freqs];
        if let Some(sb) = shared_base {
            base_f.copy_from_slice(sb);
        } else {
            for fi in 0..n_freqs {
                let mut sum = 0.0;
                for tr in pow {
                    for &bi in &base_indices {
                        sum += tr[fi][bi];
                    }
                }
                base_f[fi] = (sum / (n_tr * base_indices.len() as f64)).max(1e-20);
            }
        }
        let mut ersp = vec![0.0; n_freqs * n_out];
        let mut itc = vec![0.0; n_freqs * n_out];
        for fi in 0..n_freqs {
            for ti in 0..n_out {
                let mut p_sum = 0.0;
                let mut ph_sum = Complex64::new(0.0, 0.0);
                for k in 0..pow.len() {
                    p_sum += pow[k][fi][ti];
                    ph_sum += phase[k][fi][ti];
                }
                let mean_p = (p_sum / n_tr).max(1e-20);
                ersp[fi * n_out + ti] = 10.0 * (mean_p / base_f[fi]).log10();
                itc[fi * n_out + ti] = ph_sum.norm() / n_tr;
            }
        }
        (ersp, itc, base_f)
    };

    // Compute common baseline if comparing A and B, or Condition A baseline
    let mut common_base = vec![0.0; n_freqs];
    let total_tr = (pow_a.len() + pow_b.len()) as f64;
    for fi in 0..n_freqs {
        let mut sum = 0.0;
        for tr in &pow_a {
            for &bi in &base_indices {
                sum += tr[fi][bi];
            }
        }
        for tr in &pow_b {
            for &bi in &base_indices {
                sum += tr[fi][bi];
            }
        }
        common_base[fi] = (sum / (total_tr * base_indices.len() as f64)).max(1e-20);
    }

    let (ersp_a_db, itc_a, _) = compute_ersp_itc(&pow_a, &phase_a, Some(&common_base));
    let (ersp_b_db, itc_b, ersp_diff_db, itc_diff) = if !pow_b.is_empty() {
        let (eb, ib, _) = compute_ersp_itc(&pow_b, &phase_b, Some(&common_base));
        let ediff: Vec<f64> = eb.iter().zip(&ersp_a_db).map(|(b, a)| b - a).collect();
        let idiff: Vec<f64> = ib.iter().zip(&itc_a).map(|(b, a)| b - a).collect();
        (Some(eb), Some(ib), Some(ediff), Some(idiff))
    } else {
        (None, None, None, None)
    };

    // Per-trial summaries (for interactive trial rejection strip)
    let summarize_trials =
        |pow: &[Vec<Vec<f64>>], phase: &[Vec<Vec<Complex64>>], mean_phase_ref: &[f64]| -> (Vec<f64>, Vec<f64>) {
            let mut tr_pow = Vec::with_capacity(pow.len());
            let mut tr_itc = Vec::with_capacity(pow.len());
            // Compute mean phase vector across trials for alignment score
            let mut mean_vec = vec![vec![Complex64::new(0.0, 0.0); n_out]; n_freqs];
            for fi in 0..n_freqs {
                for ti in 0..n_out {
                    let mut s = Complex64::new(0.0, 0.0);
                    for tr in phase {
                        s += tr[fi][ti];
                    }
                    let n = s.norm();
                    mean_vec[fi][ti] = if n > 1e-12 { s / n } else { Complex64::new(1.0, 0.0) };
                }
            }
            let _ = mean_phase_ref;
            for k in 0..pow.len() {
                let mut db_sum = 0.0;
                let mut align_sum = 0.0;
                let mut cnt = 0.0_f64;
                for fi in 0..n_freqs {
                    for &ti in &post_indices {
                        let ratio = (pow[k][fi][ti] / common_base[fi]).max(1e-20);
                        db_sum += 10.0 * ratio.log10();
                        // Real projection onto condition mean phase vector
                        let proj = phase[k][fi][ti].re * mean_vec[fi][ti].re
                            + phase[k][fi][ti].im * mean_vec[fi][ti].im;
                        align_sum += proj;
                        cnt += 1.0;
                    }
                }
                tr_pow.push(db_sum / cnt.max(1.0));
                tr_itc.push((align_sum / cnt.max(1.0)).clamp(-1.0, 1.0));
            }
            (tr_pow, tr_itc)
        };

    let (trial_power_a_db, trial_itc_a) = summarize_trials(&pow_a, &phase_a, &itc_a);
    let (trial_power_b_db, trial_itc_b) = if !pow_b.is_empty() {
        summarize_trials(&pow_b, &phase_b, itc_b.as_deref().unwrap_or(&itc_a))
    } else {
        (vec![], vec![])
    };

    // Permutation statistics for ERSP & ITC
    let n_cells = n_freqs * n_out;
    let mut p_values_ersp = vec![1.0; n_cells];
    let mut p_values_itc = vec![1.0; n_cells];
    let n_perm = job.n_perm.clamp(20, 1000);
    let mut rng = StdRng::seed_from_u64(job.seed);

    if !pow_b.is_empty() {
        // Two-condition permutation test: B vs A
        let na = pow_a.len();
        let nb = pow_b.len();
        let n_tot = na + nb;
        let obs_e = ersp_diff_db.as_ref().unwrap();
        let obs_i = itc_diff.as_ref().unwrap();
        let mut counts_e = vec![0usize; n_cells];
        let mut counts_i = vec![0usize; n_cells];
        let mut indices: Vec<usize> = (0..n_tot).collect();

        for _ in 0..n_perm {
            indices.shuffle(&mut rng);
            for fi in 0..n_freqs {
                for ti in 0..n_out {
                    let mut sum_pa = 0.0;
                    let mut sum_pha = Complex64::new(0.0, 0.0);
                    for &idx in &indices[0..na] {
                        if idx < na {
                            sum_pa += pow_a[idx][fi][ti];
                            sum_pha += phase_a[idx][fi][ti];
                        } else {
                            sum_pa += pow_b[idx - na][fi][ti];
                            sum_pha += phase_b[idx - na][fi][ti];
                        }
                    }
                    let mut sum_pb = 0.0;
                    let mut sum_phb = Complex64::new(0.0, 0.0);
                    for &idx in &indices[na..] {
                        if idx < na {
                            sum_pb += pow_a[idx][fi][ti];
                            sum_phb += phase_a[idx][fi][ti];
                        } else {
                            sum_pb += pow_b[idx - na][fi][ti];
                            sum_phb += phase_b[idx - na][fi][ti];
                        }
                    }
                    let ea = 10.0 * ((sum_pa / na as f64).max(1e-20) / common_base[fi]).log10();
                    let eb = 10.0 * ((sum_pb / nb as f64).max(1e-20) / common_base[fi]).log10();
                    let ia = sum_pha.norm() / na as f64;
                    let ib = sum_phb.norm() / nb as f64;
                    let cell = fi * n_out + ti;
                    if (eb - ea).abs() >= obs_e[cell].abs() {
                        counts_e[cell] += 1;
                    }
                    if (ib - ia).abs() >= obs_i[cell].abs() {
                        counts_i[cell] += 1;
                    }
                }
            }
        }
        for cell in 0..n_cells {
            p_values_ersp[cell] = (counts_e[cell] as f64 + 1.0) / (n_perm as f64 + 1.0);
            p_values_itc[cell] = (counts_i[cell] as f64 + 1.0) / (n_perm as f64 + 1.0);
        }
    } else {
        // Single-condition: ERSP sign-flip against baseline 0 dB; ITC Rayleigh p = exp(-N * ITC^2)
        let na = pow_a.len();
        let mut trial_db = vec![vec![0.0; n_cells]; na];
        for k in 0..na {
            for fi in 0..n_freqs {
                for ti in 0..n_out {
                    trial_db[k][fi * n_out + ti] =
                        10.0 * ((pow_a[k][fi][ti] / common_base[fi]).max(1e-20)).log10();
                }
            }
        }
        let mut base_trial_mean = vec![vec![0.0; n_freqs]; na];
        for k in 0..na {
            for fi in 0..n_freqs {
                let s: f64 = base_indices.iter().map(|&bi| trial_db[k][fi * n_out + bi]).sum();
                base_trial_mean[k][fi] = s / base_indices.len() as f64;
            }
        }
        let mut counts_e = vec![0usize; n_cells];
        for _ in 0..n_perm {
            let signs: Vec<f64> = (0..na)
                .map(|_| if rng.gen_bool(0.5) { 1.0 } else { -1.0 })
                .collect();
            for fi in 0..n_freqs {
                for ti in 0..n_out {
                    let cell = fi * n_out + ti;
                    let mut diff_sum = 0.0;
                    for k in 0..na {
                        diff_sum += signs[k] * (trial_db[k][cell] - base_trial_mean[k][fi]);
                    }
                    if (diff_sum / na as f64).abs() >= ersp_a_db[cell].abs() {
                        counts_e[cell] += 1;
                    }
                }
            }
        }
        for cell in 0..n_cells {
            p_values_ersp[cell] = (counts_e[cell] as f64 + 1.0) / (n_perm as f64 + 1.0);
            // Rayleigh test for phase concentration: p ≈ exp(-N * R^2)
            let r = itc_a[cell];
            p_values_itc[cell] = (-(na as f64) * r * r).exp().clamp(0.0, 1.0);
        }
    }

    Ok(ErspItcResult {
        channel: channel_label,
        times_ms,
        freqs_hz,
        n_trials_a: trials_a.len(),
        n_trials_b: trials_b.len(),
        ersp_a_db,
        itc_a,
        ersp_b_db,
        itc_b,
        ersp_diff_db,
        itc_diff,
        p_values_ersp,
        p_values_itc,
        trial_indices_a: trials_a_idx,
        trial_power_a_db,
        trial_itc_a,
        trial_indices_b: trials_b_idx,
        trial_power_b_db,
        trial_itc_b,
    })
}

#[derive(Debug, Deserialize)]
pub struct WithinErpStatsJob {
    pub recording_path: String,
    #[serde(default)]
    pub channel_name: String,
    #[serde(default)]
    pub roi_channels: Vec<String>,
    #[serde(default)]
    pub condition_a_trials: Vec<usize>,
    #[serde(default)]
    pub condition_b_trials: Vec<usize>,
    #[serde(default)]
    pub epoch_tmin_ms: Option<f64>,
    #[serde(default = "default_win_start")]
    pub window_start_ms: f64,
    #[serde(default = "default_win_end")]
    pub window_end_ms: f64,
    #[serde(default = "default_base_start")]
    pub baseline_start_ms: f64,
    #[serde(default = "default_base_end")]
    pub baseline_end_ms: f64,
    #[serde(default = "default_stats_nperm")]
    pub n_perm: usize,
    #[serde(default = "default_t_thresh")]
    pub t_thresh: f64,
    #[serde(default = "default_seed")]
    pub seed: u64,
}

fn default_win_start() -> f64 {
    300.0
}
fn default_win_end() -> f64 {
    600.0
}
fn default_stats_nperm() -> usize {
    500
}
fn default_t_thresh() -> f64 {
    2.0
}

#[derive(Debug, Serialize)]
pub struct WithinErpStatsResult {
    pub contrast_label: String,
    pub channel_label: String,
    pub n_trials_a: usize,
    pub n_trials_b: usize,
    pub times_ms: Vec<f64>,
    pub t_obs_waveform: Vec<f64>,
    pub sig_mask_waveform: Vec<bool>,
    pub clusters: Vec<crate::stats::ErpCluster>,
    pub channel_labels: Vec<String>,
    pub channel_t_etfce: Vec<f64>,
    pub channel_p_etfce: Vec<f64>,
}

pub fn run_within_erp_stats(job: &WithinErpStatsJob) -> Result<WithinErpStatsResult, String> {
    let rec = crate::preprocessing::load_portable(Path::new(&job.recording_path))
        .map_err(|e| format!("Could not load recording '{}': {e}", job.recording_path))?;

    let n_pts = rec.source_epoch_samples.unwrap_or(0);
    let total_samples = rec.channels.first().map(|c| c.len()).unwrap_or(0);
    let epoch_count = if n_pts > 0 { total_samples / n_pts } else { 0 };
    if epoch_count == 0 || n_pts == 0 {
        return Err("Within-subject ERP stats require an epoched recording.".into());
    }
    let srate = rec.rate;
    let tmin_ms = load_epoched_meta_tmin_ms(&job.recording_path, job.epoch_tmin_ms);
    let dt_ms = 1000.0 / srate;
    let times_sec: Vec<f64> = (0..n_pts)
        .map(|i| (tmin_ms + i as f64 * dt_ms) / 1000.0)
        .collect();
    let times_ms: Vec<f64> = times_sec.iter().map(|t| t * 1000.0).collect();

    let chan_indices: Vec<usize> = if !job.channel_name.is_empty()
        && job.channel_name.to_uppercase() != "ROI"
    {
        let idx = rec
            .labels
            .iter()
            .position(|l| l.eq_ignore_ascii_case(&job.channel_name))
            .ok_or_else(|| format!("Channel '{}' not found", job.channel_name))?;
        vec![idx]
    } else if !job.roi_channels.is_empty() {
        let mut idxs = Vec::new();
        for ch in &job.roi_channels {
            if let Some(i) = rec.labels.iter().position(|l| l.eq_ignore_ascii_case(ch)) {
                idxs.push(i);
            }
        }
        if idxs.is_empty() {
            vec![0]
        } else {
            idxs
        }
    } else {
        vec![0]
    };

    let channel_label = if chan_indices.len() == 1 {
        rec.labels[chan_indices[0]].clone()
    } else {
        format!(
            "ROI ({})",
            chan_indices
                .iter()
                .map(|&i| rec.labels[i].as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )
    };

    let trials_a_idx: Vec<usize> = if job.condition_a_trials.is_empty() {
        (0..epoch_count).collect()
    } else {
        job.condition_a_trials
            .iter()
            .copied()
            .filter(|&i| i < epoch_count)
            .collect()
    };
    let trials_b_idx: Vec<usize> = job
        .condition_b_trials
        .iter()
        .copied()
        .filter(|&i| i < epoch_count)
        .collect();

    if trials_a_idx.is_empty() {
        return Err("No valid trials selected for Condition A.".into());
    }

    let extract_roi_wave = |trial_idx: usize| -> Vec<f64> {
        let start = trial_idx * n_pts;
        let mut out = vec![0.0; n_pts];
        let denom = chan_indices.len() as f64;
        for &ch in &chan_indices {
            if ch < rec.channels.len() && start + n_pts <= rec.channels[ch].len() {
                for s in 0..n_pts {
                    out[s] += rec.channels[ch][start + s] as f64 / denom;
                }
            }
        }
        out
    };

    let waves_a: Vec<Vec<f64>> = trials_a_idx.iter().map(|&i| extract_roi_wave(i)).collect();
    let waves_b: Vec<Vec<f64>> = if !trials_b_idx.is_empty() {
        trials_b_idx.iter().map(|&i| extract_roi_wave(i)).collect()
    } else {
        // Baseline reference trials (constant per-trial baseline mean)
        let base_idx: Vec<usize> = times_ms
            .iter()
            .enumerate()
            .filter(|(_, &t)| t >= job.baseline_start_ms && t <= job.baseline_end_ms)
            .map(|(i, _)| i)
            .collect();
        waves_a
            .iter()
            .map(|w| {
                let bmean = if base_idx.is_empty() {
                    0.0
                } else {
                    base_idx.iter().map(|&i| w[i]).sum::<f64>() / base_idx.len() as f64
                };
                vec![bmean; n_pts]
            })
            .collect()
    };

    let contrast_label = if !trials_b_idx.is_empty() {
        "Condition B vs Condition A".to_string()
    } else {
        format!(
            "Condition vs Baseline ({:.0}..{:.0} ms)",
            job.baseline_start_ms, job.baseline_end_ms
        )
    };

    let n_perm = job.n_perm.clamp(50, 2000);
    let (t_obs_waveform, clusters) = if !trials_b_idx.is_empty() {
        crate::stats::cluster_permutation_test_1d(
            &waves_b,
            &waves_a,
            &times_sec,
            n_perm,
            job.seed,
        )
    } else {
        crate::stats::cluster_permutation_test_1d(
            &waves_a,
            &waves_b,
            &times_sec,
            n_perm,
            job.seed,
        )
    };

    let mut sig_mask_waveform = vec![false; n_pts];
    for cl in &clusters {
        if cl.p_value <= 0.05 {
            for i in cl.start_idx..cl.end_idx.min(n_pts) {
                sig_mask_waveform[i] = true;
            }
        }
    }

    // Channel-level eTFCE in the selected measurement window
    let win_idx: Vec<usize> = times_ms
        .iter()
        .enumerate()
        .filter(|(_, &t)| t >= job.window_start_ms && t <= job.window_end_ms)
        .map(|(i, _)| i)
        .collect();
    let base_idx: Vec<usize> = times_ms
        .iter()
        .enumerate()
        .filter(|(_, &t)| t >= job.baseline_start_ms && t <= job.baseline_end_ms)
        .map(|(i, _)| i)
        .collect();

    let n_ch = rec.labels.len().min(rec.channels.len());
    let channel_mean_matrix = |trial_indices: &[usize], sample_indices: &[usize]| -> Vec<Vec<f64>> {
        trial_indices
            .iter()
            .map(|&ti| {
                let start = ti * n_pts;
                (0..n_ch)
                    .map(|ch| {
                        if sample_indices.is_empty() || start + n_pts > rec.channels[ch].len() {
                            0.0
                        } else {
                            sample_indices
                                .iter()
                                .map(|&si| rec.channels[ch][start + si] as f64)
                                .sum::<f64>()
                                / sample_indices.len() as f64
                        }
                    })
                    .collect()
            })
            .collect()
    };

    let adj = crate::stats::get_channel_adjacency(&rec.labels[..n_ch]);
    let (channel_t_etfce, channel_p_etfce) = if n_ch > 0 && !win_idx.is_empty() {
        if !trials_b_idx.is_empty() {
            let mat_a = channel_mean_matrix(&trials_a_idx, &win_idx);
            let mat_b = channel_mean_matrix(&trials_b_idx, &win_idx);
            crate::stats::etfce_channel_stats(&mat_a, &mat_b, &adj, n_perm, job.seed)
        } else {
            let mat_base = channel_mean_matrix(&trials_a_idx, &base_idx);
            let mat_win = channel_mean_matrix(&trials_a_idx, &win_idx);
            crate::stats::etfce_channel_stats(&mat_base, &mat_win, &adj, n_perm, job.seed)
        }
    } else {
        (vec![0.0; n_ch], vec![1.0; n_ch])
    };

    Ok(WithinErpStatsResult {
        contrast_label,
        channel_label,
        n_trials_a: trials_a_idx.len(),
        n_trials_b: trials_b_idx.len(),
        times_ms,
        t_obs_waveform,
        sig_mask_waveform,
        clusters,
        channel_labels: rec.labels[..n_ch].to_vec(),
        channel_t_etfce,
        channel_p_etfce,
    })
}
