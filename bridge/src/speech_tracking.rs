use nalgebra::DMatrix;
use rayon::prelude::*;
use rustfft::{num_complex::Complex, FftPlanner};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
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

struct WavStreamMeta {
    audio_fmt: u16,
    n_channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    data_offset: u64,
    data_bytes: usize,
}

fn parse_wav_header(path: &Path) -> Result<(File, WavStreamMeta), String> {
    let file = File::open(path).map_err(|e| format!("Cannot open WAV {}: {e}", path.display()))?;
    let mut reader = BufReader::with_capacity(64 * 1024, file);
    let mut riff = [0u8; 12];
    reader
        .read_exact(&mut riff)
        .map_err(|e| format!("Invalid WAV header: {e}"))?;
    if &riff[0..4] != b"RIFF" || &riff[8..12] != b"WAVE" {
        return Err("File is not a valid RIFF/WAVE audio file".into());
    }

    let mut audio_fmt: u16 = 0;
    let mut n_channels: u16 = 1;
    let mut sample_rate: u32 = 0;
    let mut bits_per_sample: u16 = 16;
    let mut data_info: Option<(u64, usize)> = None;

    let mut chunk_hdr = [0u8; 8];
    while reader.read_exact(&mut chunk_hdr).is_ok() {
        let id = &chunk_hdr[0..4];
        let size = u32::from_le_bytes([chunk_hdr[4], chunk_hdr[5], chunk_hdr[6], chunk_hdr[7]]) as usize;
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
            if size % 2 == 1 {
                let mut pad = [0u8; 1];
                let _ = reader.read_exact(&mut pad);
            }
        } else if id == b"data" {
            let pos = reader.stream_position().map_err(|e| e.to_string())?;
            data_info = Some((pos, size));
            break;
        } else {
            let skip = (size + (size % 2)) as i64;
            reader
                .seek(SeekFrom::Current(skip))
                .map_err(|e| e.to_string())?;
        }
    }

    let (data_offset, data_bytes) = data_info.ok_or("WAV file missing data chunk")?;
    if sample_rate == 0 {
        return Err("WAV sample rate is zero".into());
    }
    match (audio_fmt, bits_per_sample) {
        (3, 32) | (1, 16) | (1, 24) | (1, 32) => {}
        _ => {
            return Err(format!(
                "Unsupported WAV format={audio_fmt}, bits={bits_per_sample}"
            ))
        }
    }

    let mut file = reader.into_inner();
    file.seek(SeekFrom::Start(data_offset))
        .map_err(|e| e.to_string())?;
    Ok((
        file,
        WavStreamMeta {
            audio_fmt,
            n_channels,
            sample_rate,
            bits_per_sample,
            data_offset,
            data_bytes,
        },
    ))
}

#[inline]
fn decode_mono_frame(
    raw: &[u8],
    base: usize,
    n_channels: usize,
    bytes_per_sample: usize,
    audio_fmt: u16,
    bits_per_sample: u16,
) -> f32 {
    let mut sum = 0.0_f32;
    for c in 0..n_channels {
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
            _ => 0.0,
        };
        sum += val;
    }
    sum / n_channels as f32
}

/// Zero-phase reflection-padded raised-cosine FFT bandpass/lowpass filter.
fn zero_phase_bandpass(signal: &[f64], rate: f64, low_hz: f64, high_hz: f64) -> Vec<f64> {
    let n = signal.len();
    if n < 8 || !rate.is_finite() || rate <= 0.0 {
        return signal.to_vec();
    }
    let mean = signal.iter().sum::<f64>() / n as f64;
    let pad = n.min((2.0 * rate).round() as usize);
    let total = n + 2 * pad;
    let nfft = total.next_power_of_two().max(256);

    let mut padded = Vec::with_capacity(total);
    for k in (1..=pad).rev() {
        padded.push(signal[k.min(n - 1)] - mean);
    }
    for &v in signal {
        padded.push(v - mean);
    }
    for k in 0..pad {
        let src = n.saturating_sub(2 + k.min(n.saturating_sub(2)));
        padded.push(signal[src] - mean);
    }

    let mut planner = FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(nfft);
    let ifft = planner.plan_fft_inverse(nfft);

    let mut spec = vec![Complex::new(0.0, 0.0); nfft];
    for (i, &v) in padded.iter().enumerate() {
        spec[i] = Complex::new(v, 0.0);
    }
    fft.process(&mut spec);

    let df = rate / nfft as f64;
    let nyq = rate * 0.48;
    let hi = high_hz.min(nyq).max(0.5);
    let lo = low_hz.max(0.0).min(hi * 0.8);
    let trans_lo = (lo * 0.35).max(0.25);
    let trans_hi = (hi * 0.15).max(1.0);
    let lo0 = (lo - trans_lo).max(0.0);
    let hi1 = (hi + trans_hi).min(nyq);

    for k in 0..=nfft / 2 {
        let f = k as f64 * df;
        let g = if lo <= 0.0 {
            if f <= hi {
                1.0
            } else if f <= hi1 {
                0.5 * (1.0 + (std::f64::consts::PI * (f - hi) / (hi1 - hi).max(1e-6)).cos())
            } else {
                0.0
            }
        } else if f >= lo && f <= hi {
            1.0
        } else if f >= lo0 && f < lo {
            0.5 * (1.0 - (std::f64::consts::PI * (f - lo0) / (lo - lo0).max(1e-6)).cos())
        } else if f > hi && f <= hi1 {
            0.5 * (1.0 + (std::f64::consts::PI * (f - hi) / (hi1 - hi).max(1e-6)).cos())
        } else {
            0.0
        };
        spec[k] *= g;
        if k > 0 && k < nfft - k {
            spec[nfft - k] *= g;
        }
    }
    if lo > 0.0 {
        spec[0] = Complex::new(0.0, 0.0);
    }

    ifft.process(&mut spec);
    let inv_n = 1.0 / nfft as f64;
    (0..n).map(|i| spec[pad + i].re * inv_n).collect()
}

/// Computes FFT Hilbert analytic magnitude `|z[t]|` for a real slice.
fn hilbert_magnitude_chunk(chunk: &[f64]) -> Vec<f64> {
    let n = chunk.len();
    if n < 4 {
        return chunk.iter().map(|v| v.abs()).collect();
    }
    let mean = chunk.iter().sum::<f64>() / n as f64;
    let nfft = n.next_power_of_two();
    let mut planner = FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(nfft);
    let ifft = planner.plan_fft_inverse(nfft);
    let mut buf = vec![Complex::new(0.0, 0.0); nfft];
    for (i, &v) in chunk.iter().enumerate() {
        buf[i] = Complex::new(v - mean, 0.0);
    }
    fft.process(&mut buf);
    for k in 1..(nfft / 2) {
        buf[k] *= 2.0;
    }
    for k in (nfft / 2 + 1)..nfft {
        buf[k] = Complex::new(0.0, 0.0);
    }
    ifft.process(&mut buf);
    let scale = 1.0 / nfft as f64;
    (0..n)
        .map(|i| (buf[i] * scale).norm())
        .collect()
}

/// Resamples a continuous vector from `in_rate` to `out_len` samples at `out_rate` using block anti-aliasing + linear interpolation.
fn resample_envelope_to_rate(inter: &[f64], in_rate: f64, out_len: usize, out_rate: f64) -> Vec<f64> {
    if inter.is_empty() || out_len == 0 {
        return Vec::new();
    }
    let ratio = in_rate / out_rate;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        if ratio > 1.25 {
            let a = ((i as f64 * ratio).floor() as usize).min(inter.len() - 1);
            let b = (((i + 1) as f64 * ratio).ceil() as usize).clamp(a + 1, inter.len());
            let mean = inter[a..b].iter().sum::<f64>() / (b - a) as f64;
            out.push(mean);
        } else {
            let pos = (i as f64 * ratio).clamp(0.0, (inter.len() - 1) as f64);
            let idx = (pos.floor() as usize).min(inter.len() - 1);
            let frac = pos - idx as f64;
            let next = (idx + 1).min(inter.len() - 1);
            out.push(inter[idx] * (1.0 - frac) + inter[next] * frac);
        }
    }
    out
}

/// Streams PCM/float WAV in constant-size chunks (no full-file RAM buffer),
/// computing display min/max peaks and Biesmans et al. (2017) Hilbert + power-law
/// compressed acoustic envelope.
fn stream_wav_envelope_and_peaks(
    path: &Path,
    env_rate: f64,
    n_display_bins: usize,
    highpass_hz: f64,
) -> Result<(f64, f64, Vec<f32>, Vec<f32>, Vec<f64>), String> {
    let (mut file, meta) = parse_wav_header(path)?;
    let _ = meta.data_offset;
    let sr = meta.sample_rate as f64;
    let bytes_per_sample = (meta.bits_per_sample / 8).max(1) as usize;
    let frame_bytes = bytes_per_sample * meta.n_channels as usize;
    let n_frames = meta.data_bytes / frame_bytes;
    if n_frames < 8 {
        return Err("WAV file contains too few audio frames".into());
    }
    let duration = n_frames as f64 / sr;

    let inter_rate = (env_rate * 2.0).clamp(160.0, sr.min(400.0));
    let inter_step = sr / inter_rate;
    let inter_len = ((duration * inter_rate).floor() as usize).max(2);
    let mut inter_sum = vec![0.0_f64; inter_len];
    let mut inter_cnt = vec![0_usize; inter_len];

    let bins = n_display_bins.clamp(1, 20000);
    let mut display_min = vec![f32::INFINITY; bins];
    let mut display_max = vec![f32::NEG_INFINITY; bins];

    const CHUNK_FRAMES: usize = 65_536;
    const EDGE_OVERLAP: usize = 512;
    let mut byte_buf = vec![0u8; CHUNK_FRAMES * frame_bytes];
    let mut overlap_tail: Vec<f64> = Vec::new();
    let mut frame_cursor = 0_usize;

    while frame_cursor < n_frames {
        let want_frames = (n_frames - frame_cursor).min(CHUNK_FRAMES);
        let want_bytes = want_frames * frame_bytes;
        let slice = &mut byte_buf[..want_bytes];
        file.read_exact(slice).map_err(|e| e.to_string())?;

        let mut mono_chunk = Vec::with_capacity(overlap_tail.len() + want_frames);
        let prefix_len = overlap_tail.len();
        mono_chunk.extend_from_slice(&overlap_tail);

        for f in 0..want_frames {
            let sample = decode_mono_frame(
                slice,
                f * frame_bytes,
                meta.n_channels as usize,
                bytes_per_sample,
                meta.audio_fmt,
                meta.bits_per_sample,
            );
            let g_idx = frame_cursor + f;
            let b = ((g_idx as u128 * bins as u128) / n_frames as u128) as usize;
            let bin = b.min(bins - 1);
            if sample < display_min[bin] {
                display_min[bin] = sample;
            }
            if sample > display_max[bin] {
                display_max[bin] = sample;
            }
            mono_chunk.push(sample as f64);
        }

        // Chunked Hilbert analytic magnitude (with overlap tail for boundary continuity)
        let mag_chunk = hilbert_magnitude_chunk(&mono_chunk);
        for f in 0..want_frames {
            let g_idx = frame_cursor + f;
            let ib = ((g_idx as f64 / inter_step).floor() as usize).min(inter_len - 1);
            inter_sum[ib] += mag_chunk[prefix_len + f];
            inter_cnt[ib] += 1;
        }

        let tail_start = mono_chunk.len().saturating_sub(EDGE_OVERLAP);
        overlap_tail = mono_chunk[tail_start..].to_vec();
        frame_cursor += want_frames;
    }

    for b in 0..bins {
        if !display_min[b].is_finite() {
            display_min[b] = 0.0;
        }
        if !display_max[b].is_finite() {
            display_max[b] = 0.0;
        }
    }

    // Power-law auditory compression (Biesmans et al., 2017: env^0.3)
    let mut inter_env = Vec::with_capacity(inter_len);
    for i in 0..inter_len {
        let raw_mag = if inter_cnt[i] > 0 {
            inter_sum[i] / inter_cnt[i] as f64
        } else if i > 0 {
            inter_sum[i - 1]
        } else {
            0.0
        };
        inter_env.push(raw_mag.max(0.0).powf(0.3));
    }

    // Zero-phase bandpass/lowpass in modulation band (up to 15 Hz)
    let filtered = zero_phase_bandpass(&inter_env, inter_rate, highpass_hz, 15.0);
    let out_len = ((duration * env_rate).floor() as usize).max(2);
    let out_env = resample_envelope_to_rate(&filtered, inter_rate, out_len, env_rate);
    Ok((sr, duration, display_min, display_max, out_env))
}

/// Computes Hilbert analytic + power-law (0.3) compressed + zero-phase 15 Hz low-pass acoustic speech envelope at `env_rate` Hz.
pub fn compute_envelope(mono: &[f32], audio_rate: f64, env_rate: f64) -> Vec<f64> {
    if mono.is_empty() || audio_rate <= 0.0 || env_rate <= 0.0 {
        return Vec::new();
    }
    let duration = mono.len() as f64 / audio_rate;
    let inter_rate = (env_rate * 2.0).clamp(160.0, audio_rate.min(400.0));
    let inter_step = audio_rate / inter_rate;
    let inter_len = ((duration * inter_rate).floor() as usize).max(2);

    let f64_mono: Vec<f64> = mono.iter().map(|&v| v as f64).collect();
    let mag = hilbert_magnitude_chunk(&f64_mono);
    let mut inter_env = Vec::with_capacity(inter_len);
    for i in 0..inter_len {
        let a = ((i as f64 * inter_step).floor() as usize).min(mag.len() - 1);
        let b = (((i + 1) as f64 * inter_step).ceil() as usize).clamp(a + 1, mag.len());
        let mean = mag[a..b].iter().sum::<f64>() / (b - a) as f64;
        inter_env.push(mean.max(0.0).powf(0.3));
    }
    let filtered = zero_phase_bandpass(&inter_env, inter_rate, 0.0, 15.0);
    let out_len = ((duration * env_rate).floor() as usize).max(2);
    resample_envelope_to_rate(&filtered, inter_rate, out_len, env_rate)
}

pub fn run_audio_envelope(job: &AudioEnvelopeJob) -> Result<AudioEnvelopeResult, String> {
    let env_rate = job.target_rate.unwrap_or(100.0).clamp(10.0, 1000.0);
    let bins = job.n_display_bins.unwrap_or(2000).clamp(100, 10000);
    let (sr, duration, display_min, display_max, env) =
        stream_wav_envelope_and_peaks(Path::new(&job.input), env_rate, bins, 0.0)?;

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
            w.write_all(&(v as f32).to_le_bytes())
                .map_err(|e| e.to_string())?;
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

/// Crosse et al. (2016) mTRF first-difference Tikhonov smoothness penalty matrix M
/// (+ small identity ridge for strict positive definiteness).
fn tikhonov_m(n_lags: usize) -> DMatrix<f64> {
    let mut m = DMatrix::zeros(n_lags, n_lags);
    if n_lags == 1 {
        m[(0, 0)] = 1.0;
        return m;
    }
    for i in 0..n_lags {
        m[(i, i)] = if i == 0 || i + 1 == n_lags { 1.001 } else { 2.001 };
        if i + 1 < n_lags {
            m[(i, i + 1)] = -1.0;
            m[(i + 1, i)] = -1.0;
        }
    }
    m
}

fn block_tikhonov_m(n_ch: usize, n_lags: usize) -> DMatrix<f64> {
    let single = tikhonov_m(n_lags);
    let total = n_ch * n_lags;
    let mut out = DMatrix::zeros(total, total);
    for c in 0..n_ch {
        let off = c * n_lags;
        out.view_mut((off, off), (n_lags, n_lags)).copy_from(&single);
    }
    out
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
                let w = 0.5
                    * (1.0 - (2.0 * std::f64::consts::PI * i as f64 / (seg_len - 1) as f64).cos());
                Complex::new(x[pos + i] * w, 0.0)
            })
            .collect();
        let mut by: Vec<Complex<f64>> = (0..seg_len)
            .map(|i| {
                let w = 0.5
                    * (1.0 - (2.0 * std::f64::consts::PI * i as f64 / (seg_len - 1) as f64).cos());
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
    let track_rate = 64.0_f64.min(eeg_rate).max(16.0);
    let (_, audio_dur, _, _, env_full) = stream_wav_envelope_and_peaks(
        Path::new(&job.audio_wav_path),
        track_rate,
        256,
        1.0,
    )?;

    let offset_sec = job.audio_offset_seconds.unwrap_or(0.0);
    let eeg_dur = eeg_channels.first().map(Vec::len).unwrap_or(0) as f64 / eeg_rate;

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
    if n_pts < 64 {
        return Err("Insufficient overlapping tracking samples (< 64)".into());
    }

    let tmin_ms = job.tmin_ms.unwrap_or(-100.0);
    let tmax_ms = job.tmax_ms.unwrap_or(450.0);
    let lag_min = (tmin_ms / 1000.0 * track_rate).round() as isize;
    let lag_max = (tmax_ms / 1000.0 * track_rate).round() as isize;
    let lags: Vec<isize> = (lag_min..=lag_max).collect();
    let lag_times_ms: Vec<f64> = lags.iter().map(|&l| l as f64 * 1000.0 / track_rate).collect();
    let n_lags = lags.len();

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
    let xtx_diag_mean = (xtx.trace() / n_lags.max(1) as f64).max(1.0);
    let m_fwd = tikhonov_m(n_lags);

    let n_folds = 5_usize;
    let fold_len = (n_pts / n_folds).max(1);
    let fold_bounds: Vec<(usize, usize)> = (0..n_folds)
        .map(|f| (f * fold_len, if f + 1 == n_folds { n_pts } else { ((f + 1) * fold_len).min(n_pts) }))
        .collect();
    let fold_xtx: Vec<DMatrix<f64>> = fold_bounds
        .iter()
        .map(|&(a, b)| {
            let xf = x_mat.rows(a, b - a);
            xf.transpose() * &xf
        })
        .collect();

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

    let raw_s0 = ((overlap_start * eeg_rate).floor() as usize).min(eeg_channels[0].len());
    let raw_s1 = ((overlap_end * eeg_rate).ceil() as usize).clamp(raw_s0 + 8, eeg_channels[0].len());
    let bp_hi = (track_rate * 0.42).min(15.0);

    // Bandpass filter (1..15 Hz zero-phase anti-aliasing) then resample each selected EEG channel
    let eeg_resampled: Vec<(String, Vec<f64>)> = selected
        .par_iter()
        .map(|&ch_idx| {
            let raw_seg: Vec<f64> = eeg_channels[ch_idx][raw_s0..raw_s1]
                .iter()
                .map(|&v| v as f64)
                .collect();
            let bp = zero_phase_bandpass(&raw_seg, eeg_rate, 1.0, bp_hi);
            let resamp = resample_envelope_to_rate(&bp, eeg_rate, n_pts, track_rate);
            (eeg_labels[ch_idx].clone(), zscore(&resamp))
        })
        .collect();

    let fwd_lambdas: Vec<f64> = match job.ridge_lambda {
        Some(lam) => vec![lam.max(1e-4)],
        None => vec![0.01, 0.1, 1.0, 10.0, 100.0, 1000.0]
            .into_iter()
            .map(|c| c * xtx_diag_mean)
            .collect(),
    };

    let ch_results: Vec<ChannelTrackingResult> = eeg_resampled
        .par_iter()
        .map(|(name, y)| {
            let y_vec = DMatrix::from_column_slice(n_pts, 1, y);
            let xty_all = x_mat.transpose() * &y_vec;
            let fold_xty: Vec<DMatrix<f64>> = fold_bounds
                .iter()
                .map(|&(a, b)| {
                    let xf = x_mat.rows(a, b - a);
                    let yf = DMatrix::from_column_slice(b - a, 1, &y[a..b]);
                    xf.transpose() * &yf
                })
                .collect();

            let mut best_lam = fwd_lambdas[0];
            let mut best_cv_r = f64::NEG_INFINITY;
            for &lam in &fwd_lambdas {
                let mut cv_sum = 0.0;
                let mut valid_folds = 0_usize;
                for f in 0..n_folds {
                    let (a, b) = fold_bounds[f];
                    if b <= a + 4 {
                        continue;
                    }
                    let tr_xtx = &xtx - &fold_xtx[f];
                    let tr_xty = &xty_all - &fold_xty[f];
                    if let Some(inv_f) = (tr_xtx + &m_fwd * lam).try_inverse() {
                        let wf = inv_f * tr_xty;
                        let pred_m = x_mat.rows(a, b - a) * &wf;
                        let pred: Vec<f64> = pred_m.iter().copied().collect();
                        cv_sum += pearson_r(&pred, &y[a..b]);
                        valid_folds += 1;
                    }
                }
                let mean_r = if valid_folds > 0 { cv_sum / valid_folds as f64 } else { 0.0 };
                if mean_r > best_cv_r {
                    best_cv_r = mean_r;
                    best_lam = lam;
                }
            }
            let trf_encoding_r = if best_cv_r.is_finite() { best_cv_r } else { 0.0 };
            let reg_inv = (xtx.clone() + &m_fwd * best_lam)
                .try_inverse()
                .unwrap_or_else(|| DMatrix::identity(n_lags, n_lags));
            let trf_weights: Vec<f64> = (reg_inv * &xty_all).iter().copied().collect();

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
    // Dense causal lags 0..=250 ms across up to 16 evenly spaced channels
    let max_dec_ch = eeg_resampled.len().min(16);
    let ch_step = (eeg_resampled.len() / max_dec_ch).max(1);
    let dec_ch_indices: Vec<usize> = (0..eeg_resampled.len()).step_by(ch_step).take(max_dec_ch).collect();
    let max_dec_lag = ((0.25 * track_rate).round() as isize).clamp(4, 15);
    let dec_lags: Vec<isize> = (0..=max_dec_lag).collect();
    let n_dec_ch = dec_ch_indices.len();
    let n_dec_lags = dec_lags.len();
    let n_feat = n_dec_ch * n_dec_lags;

    let mut r_mat = DMatrix::zeros(n_pts, n_feat);
    for (ci, &src_ch_idx) in dec_ch_indices.iter().enumerate() {
        let (_, ref y) = eeg_resampled[src_ch_idx];
        for (li, &lag) in dec_lags.iter().enumerate() {
            let col = ci * n_dec_lags + li;
            for t in 0..n_pts {
                let src = t as isize + lag;
                if src >= 0 && (src as usize) < n_pts {
                    r_mat[(t, col)] = y[src as usize];
                }
            }
        }
    }

    let env_col = DMatrix::from_column_slice(n_pts, 1, &env_slice);
    let rtr_all = r_mat.transpose() * &r_mat;
    let rts_all = r_mat.transpose() * &env_col;
    let fold_rtr: Vec<DMatrix<f64>> = fold_bounds
        .iter()
        .map(|&(a, b)| {
            let rf = r_mat.rows(a, b - a);
            rf.transpose() * &rf
        })
        .collect();
    let fold_rts: Vec<DMatrix<f64>> = fold_bounds
        .iter()
        .map(|&(a, b)| {
            let rf = r_mat.rows(a, b - a);
            let sf = DMatrix::from_column_slice(b - a, 1, &env_slice[a..b]);
            rf.transpose() * &sf
        })
        .collect();

    let m_dec = block_tikhonov_m(n_dec_ch, n_dec_lags);
    let rtr_diag_mean = (rtr_all.trace() / n_feat.max(1) as f64).max(1.0);
    let dec_lambdas: Vec<f64> = match job.ridge_lambda {
        Some(lam) => vec![(lam * 2.0).max(1e-3)],
        None => vec![0.1, 1.0, 10.0, 100.0, 1000.0, 10000.0]
            .into_iter()
            .map(|c| c * rtr_diag_mean)
            .collect(),
    };

    let mut best_dec_r = f64::NEG_INFINITY;
    let mut best_pred_oof = vec![0.0_f64; n_pts];
    for &lam in &dec_lambdas {
        let mut pred_oof = vec![0.0_f64; n_pts];
        let mut fold_r_sum = 0.0;
        let mut valid = 0_usize;
        for f in 0..n_folds {
            let (a, b) = fold_bounds[f];
            if b <= a + 4 {
                continue;
            }
            let tr_rtr = &rtr_all - &fold_rtr[f];
            let tr_rts = &rts_all - &fold_rts[f];
            if let Some(inv_d) = (tr_rtr + &m_dec * lam).try_inverse() {
                let gd = inv_d * tr_rts;
                let pf = r_mat.rows(a, b - a) * &gd;
                let pred: Vec<f64> = pf.iter().copied().collect();
                for (i, &val) in pred.iter().enumerate() {
                    pred_oof[a + i] = val;
                }
                fold_r_sum += pearson_r(&pred, &env_slice[a..b]);
                valid += 1;
            }
        }
        let mean_r = if valid > 0 { fold_r_sum / valid as f64 } else { 0.0 };
        if mean_r > best_dec_r {
            best_dec_r = mean_r;
            best_pred_oof = pred_oof;
        }
    }
    let decoder_reconstruction_r = if best_dec_r.is_finite() {
        best_dec_r
    } else {
        0.0
    };

    // Valid one-tailed circular-shift permutation null test (preserves temporal autocorrelation;
    // never assigns low p-values to negative out-of-fold correlations).
    let n_perm = 200_usize;
    let min_shift = ((2.0 * track_rate).round() as usize).clamp(4, (n_pts / 4).max(4));
    let span = n_pts.saturating_sub(2 * min_shift).max(1);
    let mut exceed = 0_usize;
    let mut shifted = vec![0.0_f64; n_pts];
    for p in 0..n_perm {
        let shift = min_shift + (p * span / n_perm);
        shifted[..n_pts - shift].copy_from_slice(&env_slice[shift..]);
        shifted[n_pts - shift..].copy_from_slice(&env_slice[..shift]);
        let r_null = pearson_r(&best_pred_oof, &shifted);
        if r_null >= decoder_reconstruction_r {
            exceed += 1;
        }
    }
    let decoder_p_approx = (exceed + 1) as f64 / (n_perm + 1) as f64;

    let best = ch_results
        .iter()
        .max_by(|a, b| a.trf_encoding_r.total_cmp(&b.trf_encoding_r))
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

#[cfg(test)]
mod tests {
    use super::*;

    fn write_test_wav(path: &Path, sample_rate: u32, samples: &[f32]) {
        use std::io::Write;
        let data_bytes = (samples.len() * 2) as u32;
        let mut f = File::create(path).unwrap();
        f.write_all(b"RIFF").unwrap();
        f.write_all(&(36 + data_bytes).to_le_bytes()).unwrap();
        f.write_all(b"WAVEfmt ").unwrap();
        f.write_all(&16u32.to_le_bytes()).unwrap();
        f.write_all(&1u16.to_le_bytes()).unwrap();
        f.write_all(&1u16.to_le_bytes()).unwrap();
        f.write_all(&sample_rate.to_le_bytes()).unwrap();
        f.write_all(&(sample_rate * 2).to_le_bytes()).unwrap();
        f.write_all(&2u16.to_le_bytes()).unwrap();
        f.write_all(&16u16.to_le_bytes()).unwrap();
        f.write_all(b"data").unwrap();
        f.write_all(&data_bytes.to_le_bytes()).unwrap();
        for &s in samples {
            let q = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
            f.write_all(&q.to_le_bytes()).unwrap();
        }
    }

    #[test]
    fn speech_tracking_recovers_synthetic_trf_and_rejects_uncorrelated_noise() {
        let dir = std::env::temp_dir();
        let wav_path = dir.join("ccs_speech_track_parity_test.wav");
        let audio_sr = 16_000_u32;
        let dur_sec = 20_usize;
        let n_audio = dur_sec * audio_sr as usize;
        let two_pi = 2.0 * std::f64::consts::PI;

        // Syllable-rate (3-6 Hz) amplitude-modulated speech-like acoustic carrier
        let wav_samples: Vec<f32> = (0..n_audio)
            .map(|i| {
                let t = i as f64 / audio_sr as f64;
                let mod_env = 0.5 + 0.25 * (two_pi * 3.5 * t).sin() + 0.20 * (two_pi * 5.2 * t + 0.8).cos();
                let carrier = (two_pi * 220.0 * t).sin() * 0.6 + (two_pi * 440.0 * t).sin() * 0.4;
                (mod_env * carrier) as f32
            })
            .collect();
        write_test_wav(&wav_path, audio_sr, &wav_samples);

        // Extract ground-truth envelope at EEG rate (256 Hz) and convolve with auditory N1-P2 TRF
        let eeg_rate = 256.0;
        let n_eeg = dur_sec * eeg_rate as usize;
        let env_256 = compute_envelope(&wav_samples, audio_sr as f64, eeg_rate);
        let env_z = zscore(&env_256[..n_eeg]);

        let n1_lag = (0.10 * eeg_rate).round() as isize;
        let p2_lag = (0.20 * eeg_rate).round() as isize;
        let mut eeg_channels = Vec::with_capacity(8);
        let mut labels = Vec::with_capacity(8);
        for ch in 0..8 {
            labels.push(format!("Ch{}", ch + 1));
            let mut sig = vec![0.0_f32; n_eeg];
            let mut state = 12345_u64 + ch as u64 * 997;
            for t in 0..n_eeg {
                let s_n1 = if t as isize >= n1_lag { env_z[(t as isize - n1_lag) as usize] } else { 0.0 };
                let s_p2 = if t as isize >= p2_lag { env_z[(t as isize - p2_lag) as usize] } else { 0.0 };
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                let noise = (((state >> 33) as f64 / u32::MAX as f64) - 0.5) * 0.4;
                let gain = 1.0 - 0.05 * ch as f64;
                sig[t] = (gain * (-1.0 * s_n1 + 1.2 * s_p2) + noise) as f32;
            }
            eeg_channels.push(sig);
        }

        let job = SpeechTrackingJob {
            eeg_path: "synthetic".into(),
            audio_wav_path: wav_path.to_string_lossy().into_owned(),
            audio_offset_seconds: Some(0.0),
            tmin_ms: Some(-100.0),
            tmax_ms: Some(450.0),
            ridge_lambda: None,
            channels: None,
        };
        let res = run_speech_tracking(&job, &eeg_channels, &labels, eeg_rate).unwrap();
        assert!(
            res.best_encoding_r > 0.45,
            "expected positive encoding r > 0.45, got {}",
            res.best_encoding_r
        );
        assert!(
            res.decoder_reconstruction_r > 0.45,
            "expected decoder r > 0.45, got {}",
            res.decoder_reconstruction_r
        );
        assert!(
            res.decoder_p_approx < 0.02,
            "expected significant surrogate p < 0.02, got {}",
            res.decoder_p_approx
        );

        // Verify N1 negative weight near 100 ms and P2 positive weight near 200 ms
        let idx_100 = res
            .lag_times_ms
            .iter()
            .enumerate()
            .min_by(|a, b| (a.1 - 100.0).abs().total_cmp(&(b.1 - 100.0).abs()))
            .unwrap()
            .0;
        let idx_200 = res
            .lag_times_ms
            .iter()
            .enumerate()
            .min_by(|a, b| (a.1 - 200.0).abs().total_cmp(&(b.1 - 200.0).abs()))
            .unwrap()
            .0;
        let w = &res.channels[0].trf_weights;
        assert!(w[idx_100] < 0.0, "expected negative N1 weight at ~100ms, got {}", w[idx_100]);
        assert!(w[idx_200] > 0.0, "expected positive P2 weight at ~200ms, got {}", w[idx_200]);

        // Now run with uncorrelated random EEG and verify surrogate null test does NOT fake low p
        let mut uncorr = Vec::with_capacity(8);
        for ch in 0..8 {
            let mut sig = vec![0.0_f32; n_eeg];
            let mut state = 777777_u64 + ch as u64 * 1337;
            for t in 0..n_eeg {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                sig[t] = ((((state >> 33) as f64 / u32::MAX as f64) - 0.5) * 10.0) as f32;
            }
            uncorr.push(sig);
        }
        let null_res = run_speech_tracking(&job, &uncorr, &labels, eeg_rate).unwrap();
        assert!(
            null_res.decoder_p_approx > 0.05,
            "uncorrelated noise falsely flagged significant (r={}, p={})",
            null_res.decoder_reconstruction_r,
            null_res.decoder_p_approx
        );
        let _ = std::fs::remove_file(&wav_path);
    }
}
