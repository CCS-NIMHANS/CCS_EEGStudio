use nalgebra::DMatrix;
use rayon::prelude::*;
use rustfft::{num_complex::Complex, FftPlanner};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

#[derive(Deserialize)]
pub struct AudioEnvelopeJob {
    pub input: String,
    pub target_rate: Option<f64>,
    pub output_envelope_f32: Option<String>,
    pub n_display_bins: Option<usize>,
}

#[derive(Serialize)]
pub struct AudioEnvelopeResult {
    pub sample_rate: f64,
    pub duration_seconds: f64,
    pub envelope_rate: f64,
    pub envelope_len: usize,
    pub display_min: Vec<f32>,
    pub display_max: Vec<f32>,
    pub envelope_preview: Vec<f32>,
    pub envelope_f32_path: Option<String>,
}

#[derive(Deserialize)]
pub struct SpeechTrackingJob {
    pub eeg_path: String,
    pub audio_wav_path: String,
    pub audio_offset_seconds: Option<f64>,
    pub tmin_ms: Option<f64>,
    pub tmax_ms: Option<f64>,
    pub ridge_lambda: Option<f64>,
    pub channels: Option<Vec<String>>,
}

#[derive(Serialize)]
pub struct ChannelTrackingResult {
    pub channel: String,
    pub xcorr_peak_r: f64,
    pub xcorr_peak_lag_ms: f64,
    pub trf_encoding_r: f64,
    pub trf_weights: Vec<f64>,
    pub delta_coherence: f64,
    pub theta_coherence: f64,
}

#[derive(Serialize)]
pub struct SpeechTrackingResult {
    pub tracking_rate_hz: f64,
    pub overlap_seconds: f64,
    pub lag_times_ms: Vec<f64>,
    pub decoder_reconstruction_r: f64,
    pub decoder_p_approx: f64,
    pub best_channel: String,
    pub best_encoding_r: f64,
    pub channels: Vec<ChannelTrackingResult>,
}

/// Safe streaming PCM WAV reader (supports 16-bit, 24-bit, 32-bit int, and 32-bit float).
pub fn read_wav_mono(path: &Path) -> Result<(Vec<f32>, f64), String> {
    let file = File::open(path).map_err(|e| format!("Cannot open WAV {}: {e}", path.display()))?;
    let mut reader = BufReader::with_capacity(1024 * 1024, file);
    let mut riff = [0u8; 12];
    reader.read_exact(&mut riff).map_err(|e| format!("Invalid WAV header: {e}"))?;
    if &riff[0..4] != b"RIFF" || &riff[8..12] != b"WAVE" {
        return Err("File is not a valid RIFF/WAVE audio file".into());
    }

    let mut audio_fmt: u16 = 0;
    let mut n_channels: u16 = 1;
    let mut sample_rate: u32 = 0;
    let mut bits_per_sample: u16 = 16;
    let mut data_bytes: Option<Vec<u8>> = None;

    let mut chunk_hdr = [0u8; 8];
    while reader.read_exact(&mut chunk_hdr).is_ok() {
        let id = &chunk_hdr[0..4];
        let size = u32::from_le_bytes([chunk_hdr[4], chunk_hdr[5], chunk_hdr[6], chunk_hdr[7]]) as usize;
        if size > 1_500_000_000 {
            return Err("WAV chunk exceeds safe memory limit (1.5 GB)".into());
        }
        if id == b"fmt " {
            let mut fmt_buf = vec![0u8; size];
            reader.read_exact(&mut fmt_buf).map_err(|e| e.to_string())?;
            if fmt_buf.len() < 16 {
                return Err("Truncated WAV fmt chunk".into());
            }
            audio_fmt = u16::from_le_bytes([fmt_buf[0], fmt_buf[1]]);
            n_channels = u16::from_le_bytes([fmt_buf[2], fmt_buf[3]]).max(1);
            sample_rate = u32::from_le_bytes([fmt_buf[4], fmt_buf[5], fmt_buf[6], fmt_buf[7]]);
            bits_per_sample = u16::from_le_bytes([fmt_buf[14], fmt_buf[15]]);
        } else if id == b"data" {
            let mut buf = vec![0u8; size];
            reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
            data_bytes = Some(buf);
            break;
        } else {
            let skip = size + (size % 2);
            std::io::copy(&mut reader.by_ref().take(skip as u64), &mut std::io::sink())
                .map_err(|e| e.to_string())?;
        }
    }

    let raw = data_bytes.ok_or("WAV file missing data chunk")?;
    if sample_rate == 0 {
        return Err("WAV sample rate is zero".into());
    }
    let bytes_per_sample = (bits_per_sample / 8).max(1) as usize;
    let frame_bytes = bytes_per_sample * n_channels as usize;
    let n_frames = raw.len() / frame_bytes;
    if n_frames < 8 {
        return Err("WAV file contains too few audio frames".into());
    }

    let mut mono = Vec::with_capacity(n_frames);
    for f in 0..n_frames {
        let base = f * frame_bytes;
        let mut sum = 0.0f32;
        for c in 0..n_channels as usize {
            let off = base + c * bytes_per_sample;
            let val = match (audio_fmt, bits_per_sample) {
                (3, 32) => {
                    let v = f32::from_le_bytes([raw[off], raw[off + 1], raw[off + 2], raw[off + 3]]);
                    if v.is_finite() { v } else { 0.0 }
                }
                (1, 16) => i16::from_le_bytes([raw[off], raw[off + 1]]) as f32 / 32768.0,
                (1, 24) => {
                    let b0 = raw[off] as i32;
                    let b1 = (raw[off + 1] as i32) << 8;
                    let b2 = ((raw[off + 2] as i8) as i32) << 16;
                    (b0 | b1 | b2) as f32 / 8_388_608.0
                }
                (1, 32) => {
                    i32::from_le_bytes([raw[off], raw[off + 1], raw[off + 2], raw[off + 3]]) as f32
                        / 2_147_483_648.0
                }
                _ => return Err(format!("Unsupported WAV format={audio_fmt}, bits={bits_per_sample}")),
            };
            sum += val;
        }
        mono.push(sum / n_channels as f32);
    }
    Ok((mono, sample_rate as f64))
}

/// Computes rectified + smoothed acoustic speech envelope at `env_rate` Hz.
pub fn compute_envelope(mono: &[f32], audio_rate: f64, env_rate: f64) -> Vec<f64> {
    let duration = mono.len() as f64 / audio_rate;
    let n_out = ((duration * env_rate).floor() as usize).max(2);
    let step = audio_rate / env_rate;
    let mut env = Vec::with_capacity(n_out);
    for i in 0..n_out {
        let a = ((i as f64 * step).floor() as usize).min(mono.len() - 1);
        let b = (((i + 1) as f64 * step).ceil() as usize).clamp(a + 1, mono.len());
        let mut sum = 0.0f64;
        for &v in &mono[a..b] {
            sum += (v as f64).abs();
        }
        env.push(sum / (b - a) as f64);
    }
    // Zero-phase moving-average low-pass (~12 Hz smoothing)
    let win = ((env_rate / 12.0).round() as usize).max(1);
    let mut smooth = vec![0.0f64; n_out];
    let mut run = 0.0f64;
    for i in 0..n_out {
        run += env[i];
        if i >= win {
            run -= env[i - win];
        }
        smooth[i] = run / (i + 1).min(win) as f64;
    }
    smooth
}

pub fn run_audio_envelope(job: &AudioEnvelopeJob) -> Result<AudioEnvelopeResult, String> {
    let (mono, sr) = read_wav_mono(Path::new(&job.input))?;
    let duration = mono.len() as f64 / sr;
    let env_rate = job.target_rate.unwrap_or(100.0).clamp(10.0, 1000.0);
    let env = compute_envelope(&mono, sr, env_rate);

    let bins = job.n_display_bins.unwrap_or(2000).clamp(100, 10000);
    let mut display_min = Vec::with_capacity(bins);
    let mut display_max = Vec::with_capacity(bins);
    for b in 0..bins {
        let i0 = b * mono.len() / bins;
        let i1 = ((b + 1) * mono.len() / bins).clamp(i0 + 1, mono.len());
        let mut mn = f32::INFINITY;
        let mut mx = f32::NEG_INFINITY;
        for &v in &mono[i0..i1] {
            if v < mn { mn = v; }
            if v > mx { mx = v; }
        }
        display_min.push(mn);
        display_max.push(mx);
    }

    let env_preview: Vec<f32> = (0..bins)
        .map(|b| {
            let idx = (b * env.len() / bins).min(env.len() - 1);
            env[idx] as f32
        })
        .collect();

    if let Some(out_path) = &job.output_envelope_f32 {
        use std::io::Write;
        let mut w = std::io::BufWriter::new(File::create(out_path).map_err(|e| e.to_string())?);
        for &v in &env {
            w.write_all(&(v as f32).to_le_bytes()).map_err(|e| e.to_string())?;
        }
        w.flush().map_err(|e| e.to_string())?;
    }

    Ok(AudioEnvelopeResult {
        sample_rate: sr,
        duration_seconds: duration,
        envelope_rate: env_rate,
        envelope_len: env.len(),
        display_min,
        display_max,
        envelope_preview: env_preview,
        envelope_f32_path: job.output_envelope_f32.clone(),
    })
}

fn zscore(x: &[f64]) -> Vec<f64> {
    let n = x.len().max(1) as f64;
    let m = x.iter().sum::<f64>() / n;
    let var = x.iter().map(|&v| (v - m) * (v - m)).sum::<f64>() / n;
    let sd = var.sqrt().max(1e-12);
    x.iter().map(|&v| (v - m) / sd).collect()
}

fn pearson_r(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len().min(b.len());
    if n < 4 {
        return 0.0;
    }
    let ma = a[..n].iter().sum::<f64>() / n as f64;
    let mb = b[..n].iter().sum::<f64>() / n as f64;
    let (mut num, mut va, mut vb) = (0.0, 0.0, 0.0);
    for i in 0..n {
        let da = a[i] - ma;
        let db = b[i] - mb;
        num += da * db;
        va += da * da;
        vb += db * db;
    }
    let d = (va * vb).sqrt();
    if d <= 1e-12 { 0.0 } else { num / d }
}

fn band_coherence(x: &[f64], y: &[f64], rate: f64, f_lo: f64, f_hi: f64) -> f64 {
    let n = x.len().min(y.len());
    let seg_len = ((rate * 2.0) as usize).next_power_of_two().clamp(64, 512);
    if n < seg_len {
        return 0.0;
    }
    let step = seg_len / 2;
    let mut planner = FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(seg_len);
    let df = rate / seg_len as f64;
    let k0 = ((f_lo / df).ceil() as usize).max(1);
    let k1 = ((f_hi / df).floor() as usize).min(seg_len / 2 - 1);
    if k1 < k0 {
        return 0.0;
    }
    let mut pxx = vec![0.0; k1 - k0 + 1];
    let mut pyy = vec![0.0; k1 - k0 + 1];
    let mut pxy = vec![Complex::new(0.0, 0.0); k1 - k0 + 1];

    let mut pos = 0;
    while pos + seg_len <= n {
        let mut bx: Vec<Complex<f64>> = (0..seg_len)
            .map(|i| {
                let w = 0.5 * (1.0 - (2.0 * std::f64::consts::PI * i as f64 / (seg_len - 1) as f64).cos());
                Complex::new(x[pos + i] * w, 0.0)
            })
            .collect();
        let mut by: Vec<Complex<f64>> = (0..seg_len)
            .map(|i| {
                let w = 0.5 * (1.0 - (2.0 * std::f64::consts::PI * i as f64 / (seg_len - 1) as f64).cos());
                Complex::new(y[pos + i] * w, 0.0)
            })
            .collect();
        fft.process(&mut bx);
        fft.process(&mut by);
        for (idx, k) in (k0..=k1).enumerate() {
            pxx[idx] += bx[k].norm_sqr();
            pyy[idx] += by[k].norm_sqr();
            pxy[idx] += bx[k] * by[k].conj();
        }
        pos += step;
    }
    let sum_coh: f64 = (0..pxx.len())
        .map(|i| {
            let denom = (pxx[i] * pyy[i]).max(1e-18);
            (pxy[i].norm_sqr() / denom).clamp(0.0, 1.0)
        })
        .sum();
    sum_coh / pxx.len() as f64
}

pub fn run_speech_tracking(
    job: &SpeechTrackingJob,
    eeg_channels: &[Vec<f32>],
    eeg_labels: &[String],
    eeg_rate: f64,
) -> Result<SpeechTrackingResult, String> {
    let (mono, audio_sr) = read_wav_mono(Path::new(&job.audio_wav_path))?;
    let track_rate = 100.0_f64.min(eeg_rate);
    let env_full = compute_envelope(&mono, audio_sr, track_rate);

    let offset_sec = job.audio_offset_seconds.unwrap_or(0.0);
    let eeg_dur = eeg_channels.first().map(Vec::len).unwrap_or(0) as f64 / eeg_rate;
    let audio_dur = env_full.len() as f64 / track_rate;

    // Align overlapping segment: audio starts at `offset_sec` on the EEG timeline
    let overlap_start = offset_sec.max(0.0);
    let overlap_end = (offset_sec + audio_dur).min(eeg_dur);
    let overlap_seconds = overlap_end - overlap_start;
    if overlap_seconds < 4.0 {
        return Err(format!(
            "EEG and audio overlap ({overlap_seconds:.2} s) is too short (< 4 s) for Neural Speech Tracking"
        ));
    }

    let n_track = (overlap_seconds * track_rate).floor() as usize;
    let env_offset_idx = ((overlap_start - offset_sec) * track_rate).round().max(0.0) as usize;
    let env_slice = zscore(&env_full[env_offset_idx..(env_offset_idx + n_track).min(env_full.len())]);
    let n_pts = env_slice.len();

    let tmin_ms = job.tmin_ms.unwrap_or(-100.0);
    let tmax_ms = job.tmax_ms.unwrap_or(450.0);
    let lag_min = (tmin_ms / 1000.0 * track_rate).round() as isize;
    let lag_max = (tmax_ms / 1000.0 * track_rate).round() as isize;
    let lags: Vec<isize> = (lag_min..=lag_max).collect();
    let lag_times_ms: Vec<f64> = lags.iter().map(|&l| l as f64 * 1000.0 / track_rate).collect();
    let n_lags = lags.len();
    let lambda = job.ridge_lambda.unwrap_or(100.0).max(1e-3);

    // Build Toeplitz design matrix X (n_pts x n_lags) for forward encoding TRF
    let mut x_mat = DMatrix::zeros(n_pts, n_lags);
    for (col, &lag) in lags.iter().enumerate() {
        for t in 0..n_pts {
            let src = t as isize - lag;
            if src >= 0 && (src as usize) < n_pts {
                x_mat[(t, col)] = env_slice[src as usize];
            }
        }
    }
    let xtx = x_mat.transpose() * &x_mat;

    // Resample each selected EEG channel to track_rate over [overlap_start .. overlap_end]
    let selected: Vec<usize> = (0..eeg_labels.len())
        .filter(|&i| {
            job.channels
                .as_ref()
                .map_or(true, |wanted| wanted.iter().any(|w| w.eq_ignore_ascii_case(&eeg_labels[i])))
        })
        .collect();
    if selected.is_empty() {
        return Err("No matching EEG channels selected for Neural Speech Tracking".into());
    }

    let eeg_resampled: Vec<(String, Vec<f64>)> = selected
        .par_iter()
        .map(|&ch_idx| {
            let src = &eeg_channels[ch_idx];
            let mut y = Vec::with_capacity(n_pts);
            for i in 0..n_pts {
                let t = overlap_start + i as f64 / track_rate;
                let idx = (t * eeg_rate).round() as usize;
                y.push(if idx < src.len() { src[idx] as f64 } else { 0.0 });
            }
            (eeg_labels[ch_idx].clone(), zscore(&y))
        })
        .collect();

    // Forward TRF encoding + xcorr + coherence per channel (5-fold CV)
    let n_folds = 5;
    let fold_len = (n_pts / n_folds).max(1);
    let reg_inv = (xtx.clone() + DMatrix::identity(n_lags, n_lags) * lambda)
        .try_inverse()
        .ok_or("Singular TRF design matrix")?;

    let ch_results: Vec<ChannelTrackingResult> = eeg_resampled
        .par_iter()
        .map(|(name, y)| {
            let y_vec = DMatrix::from_column_slice(n_pts, 1, y);
            let w_full = &reg_inv * (x_mat.transpose() * &y_vec);
            let trf_weights: Vec<f64> = w_full.iter().copied().collect();

            // 5-fold cross-validated encoding correlation
            let mut cv_r_sum = 0.0;
            for f in 0..n_folds {
                let a = f * fold_len;
                let b = ((f + 1) * fold_len).min(n_pts);
                let mut x_tr_x = DMatrix::zeros(n_lags, n_lags);
                let mut x_tr_y = DMatrix::zeros(n_lags, 1);
                for t in 0..n_pts {
                    if t >= a && t < b { continue; }
                    let row = x_mat.row(t);
                    x_tr_x += row.transpose() * row;
                    x_tr_y += row.transpose() * y[t];
                }
                if let Some(inv_f) = (x_tr_x + DMatrix::identity(n_lags, n_lags) * lambda).try_inverse() {
                    let wf = inv_f * x_tr_y;
                    let mut pred = Vec::with_capacity(b - a);
                    for t in a..b {
                        pred.push((x_mat.row(t) * &wf)[(0, 0)]);
                    }
                    cv_r_sum += pearson_r(&pred, &y[a..b]);
                }
            }
            let trf_encoding_r = cv_r_sum / n_folds as f64;

            // Lagged cross-correlation peak
            let mut best_r: f64 = 0.0;
            let mut best_lag_ms: f64 = 0.0;
            for (li, &lag) in lags.iter().enumerate() {
                let mut num = 0.0;
                let mut cnt = 0;
                for t in 0..n_pts {
                    let s = t as isize - lag;
                    if s >= 0 && (s as usize) < n_pts {
                        num += env_slice[s as usize] * y[t];
                        cnt += 1;
                    }
                }
                let r = if cnt > 0 { num / cnt as f64 } else { 0.0 };
                if r.abs() > best_r.abs() {
                    best_r = r;
                    best_lag_ms = lag_times_ms[li];
                }
            }

            let delta_coherence = band_coherence(y, &env_slice, track_rate, 1.0, 4.0);
            let theta_coherence = band_coherence(y, &env_slice, track_rate, 4.0, 8.0);

            ChannelTrackingResult {
                channel: name.clone(),
                xcorr_peak_r: best_r,
                xcorr_peak_lag_ms: best_lag_ms,
                trf_encoding_r,
                trf_weights,
                delta_coherence,
                theta_coherence,
            }
        })
        .collect();

    // Backward Stimulus Reconstruction Decoder (multi-channel EEG -> speech envelope)
    let max_dec_ch = eeg_resampled.len().min(16);
    let dec_lags: Vec<isize> = (0..=4).map(|k| k * (track_rate * 0.05).round() as isize).collect();
    let n_feat = max_dec_ch * dec_lags.len();
    let mut r_mat = DMatrix::zeros(n_pts, n_feat);
    for (ci, (_, y)) in eeg_resampled.iter().take(max_dec_ch).enumerate() {
        for (li, &lag) in dec_lags.iter().enumerate() {
            let col = ci * dec_lags.len() + li;
            for t in 0..n_pts {
                let src = t as isize + lag;
                if src >= 0 && (src as usize) < n_pts {
                    r_mat[(t, col)] = y[src as usize];
                }
            }
        }
    }
    let mut dec_r_sum = 0.0;
    for f in 0..n_folds {
        let a = f * fold_len;
        let b = ((f + 1) * fold_len).min(n_pts);
        let mut rtr = DMatrix::zeros(n_feat, n_feat);
        let mut rts = DMatrix::zeros(n_feat, 1);
        for t in 0..n_pts {
            if t >= a && t < b { continue; }
            let row = r_mat.row(t);
            rtr += row.transpose() * row;
            rts += row.transpose() * env_slice[t];
        }
        if let Some(inv_d) = (rtr + DMatrix::identity(n_feat, n_feat) * (lambda * 2.0)).try_inverse() {
            let gd = inv_d * rts;
            let mut pred = Vec::with_capacity(b - a);
            for t in a..b {
                pred.push((r_mat.row(t) * &gd)[(0, 0)]);
            }
            dec_r_sum += pearson_r(&pred, &env_slice[a..b]);
        }
    }
    let decoder_reconstruction_r = dec_r_sum / n_folds as f64;
    let z_stat = decoder_reconstruction_r.abs() * ((n_pts as f64 / 10.0).max(4.0)).sqrt();
    let decoder_p_approx = (-0.5 * z_stat * z_stat).exp().clamp(1e-12, 1.0);

    let best = ch_results
        .iter()
        .max_by(|a, b| a.trf_encoding_r.abs().total_cmp(&b.trf_encoding_r.abs()))
        .ok_or("No channel tracking results")?;

    Ok(SpeechTrackingResult {
        tracking_rate_hz: track_rate,
        overlap_seconds,
        lag_times_ms,
        decoder_reconstruction_r,
        decoder_p_approx,
        best_channel: best.channel.clone(),
        best_encoding_r: best.trf_encoding_r,
        channels: ch_results,
    })
}
