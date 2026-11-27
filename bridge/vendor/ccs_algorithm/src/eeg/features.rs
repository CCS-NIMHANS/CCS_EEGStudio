use super::signal::{hamming, rfft_power};
use rayon::prelude::*;
use std::collections::BTreeMap;

pub const BANDS: [(f64, f64, &str); 7] = [
    (1.0, 4.0, "Delta"),
    (4.0, 8.0, "Theta"),
    (6.0, 10.0, "ThetaAlpha"),
    (8.0, 12.0, "Alpha"),
    (12.0, 18.0, "Beta1"),
    (18.0, 30.0, "Beta2"),
    (30.0, 40.0, "Gamma1"),
];

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(f64::total_cmp);
    let n = values.len();
    if n == 0 {
        return 0.0;
    }
    if n % 2 == 0 {
        (values[n / 2 - 1] + values[n / 2]) / 2.0
    } else {
        values[n / 2]
    }
}

fn median_bias(n: usize) -> f64 {
    let mut bias = 1.0;
    for index in 1..=((n.saturating_sub(1)) / 2) {
        let even = (2 * index) as f64;
        bias += 1.0 / (even + 1.0) - 1.0 / even;
    }
    bias
}

fn simpson(values: &[f64], dx: f64) -> f64 {
    match values.len() {
        0 | 1 => 0.0,
        2 => (values[0] + values[1]) * dx / 2.0,
        n if n % 2 == 1 => {
            let odd = values[1..n - 1].iter().step_by(2).sum::<f64>();
            let even = values[2..n - 1].iter().step_by(2).sum::<f64>();
            dx / 3.0 * (values[0] + values[n - 1] + 4.0 * odd + 2.0 * even)
        }
        n => {
            simpson(&values[..n - 1], dx)
                + dx * (5.0 * values[n - 1] / 12.0 + 2.0 * values[n - 2] / 3.0
                    - values[n - 3] / 12.0)
        }
    }
}

/// SciPy-compatible Welch PSD for the pipeline's fixed configuration:
/// one-second Hamming windows, 50% overlap, density scaling, median average.
pub fn welch_median(signal: &[f64], sfreq: f64) -> (Vec<f64>, Vec<f64>) {
    let nperseg = sfreq.round() as usize;
    if signal.len() < nperseg || nperseg == 0 {
        return (Vec::new(), Vec::new());
    }
    welch_median_nperseg(signal, sfreq, nperseg)
}

pub fn welch_median_nperseg(signal: &[f64], sfreq: f64, nperseg: usize) -> (Vec<f64>, Vec<f64>) {
    welch_psd_nperseg(signal,sfreq,nperseg,false)
}
pub fn welch_psd_nperseg(signal: &[f64], sfreq: f64, nperseg: usize, mean_average: bool) -> (Vec<f64>,Vec<f64>) {
    if signal.is_empty() || nperseg == 0 || !sfreq.is_finite() || sfreq <= 0.0 {
        return (Vec::new(), Vec::new());
    }
    // IRASA downsampling can make an epoch shorter than the requested window.
    // Shorten the window, but retain the FFT length so paired spectra share bins.
    let window_len = nperseg.min(signal.len());
    let step = window_len.max(2) / 2;
    let window = hamming(window_len);
    let window_energy = window.iter().map(|value| value * value).sum::<f64>();
    if window_energy == 0.0 || sfreq == 0.0 {
        return (Vec::new(), Vec::new());
    }
    let segments: Vec<&[f64]> = (0..=signal.len().saturating_sub(window_len))
        .step_by(step)
        .map(|start| &signal[start..start + window_len])
        .collect();
    if segments.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let spectra: Vec<Vec<f64>> = segments
        .par_iter()
        .map(|segment| {
            let mean = segment.iter().sum::<f64>() / segment.len() as f64;
            let mut tapered: Vec<f64> = segment
                .iter()
                .zip(&window)
                .map(|(value, weight)| (value - mean) * weight)
                .collect();
            tapered.resize(nperseg, 0.0);
            let mut power = rfft_power(&tapered);
            let scale = 1.0 / (sfreq * window_energy);
            for (index, value) in power.iter_mut().enumerate() {
                *value *= scale;
                if index != 0 && (nperseg % 2 != 0 || index != nperseg / 2) {
                    *value *= 2.0;
                }
            }
            power
        })
        .collect();
    let bins = nperseg / 2 + 1;
    let mut psd = vec![0.0; bins];
    let bias = median_bias(spectra.len());
    for bin in 0..bins {
        let mut values: Vec<f64> = spectra.iter().map(|spectrum| spectrum[bin]).collect();
        psd[bin] = if mean_average { values.iter().sum::<f64>() / values.len() as f64 } else { median(&mut values) / bias };
    }
    let frequencies = (0..bins)
        .map(|index| index as f64 * sfreq / nperseg as f64)
        .collect();
    (frequencies, psd)
}

/// Discrete Prolate Spheroidal Sequences (DPSS) / Slepian tapers.
/// Returns (tapers, concentration_ratios) where tapers is a Vec of K tapers of length M.
/// Solved via O(M * K) Sturm sequence bisection + Thomas inverse iteration on Slepian tridiagonal matrix.
pub fn dpss_windows(m: usize, nw: f64, k_max: usize) -> (Vec<Vec<f64>>, Vec<f64>) {
    if m == 0 || k_max == 0 || nw <= 0.0 || nw >= m as f64 / 2.0 {
        return (Vec::new(), Vec::new());
    }
    let k = k_max.min(m);
    let w = nw / m as f64;
    let pi = std::f64::consts::PI;

    // Slepian symmetric tridiagonal matrix diagonal and off-diagonal
    let cos_2pi_w = (2.0 * pi * w).cos();
    let mut diag = vec![0.0; m];
    for i in 0..m {
        let term = (m as f64 - 1.0 - 2.0 * i as f64) / 2.0;
        diag[i] = term * term * cos_2pi_w;
    }
    let mut off = vec![0.0; m.saturating_sub(1)];
    for i in 0..off.len() {
        off[i] = (i + 1) as f64 * (m as f64 - (i + 1) as f64) / 2.0;
    }

    // Gershgorin circle theorem bound on eigenvalues
    let mut r_max: f64 = 0.0;
    for i in 0..m {
        let left = if i > 0 { off[i - 1].abs() } else { 0.0 };
        let right = if i + 1 < m { off[i].abs() } else { 0.0 };
        let bound = diag[i].abs() + left + right;
        if bound > r_max {
            r_max = bound;
        }
    }

    // Sturm sequence count of eigenvalues < val
    let count_less = |val: f64| -> usize {
        let mut cnt = 0;
        let mut q: f64 = 1.0;
        for i in 0..m {
            let mut d = diag[i] - val;
            if i > 0 {
                let safe_q = if q.abs() < 1e-30 { 1e-30 } else { q };
                d -= (off[i - 1] * off[i - 1]) / safe_q;
            }
            if d < 0.0 {
                cnt += 1;
            }
            q = d;
        }
        cnt
    };

    // Find top K eigenvalues by bisection
    let mut eigs = Vec::with_capacity(k);
    for order in 0..k {
        let target = m - 1 - order;
        let mut low = -r_max - 1.0;
        let mut high = r_max + 1.0;
        for _ in 0..64 {
            let mid = 0.5 * (low + high);
            if count_less(mid) <= target {
                low = mid;
            } else {
                high = mid;
            }
        }
        eigs.push(0.5 * (low + high));
    }

    // Inverse iteration for each eigenvector (Thomas algorithm)
    let mut tapers = Vec::with_capacity(k);
    let mut cp = vec![0.0; m.saturating_sub(1)];
    let mut dp = vec![0.0; m];
    for (order, &lam) in eigs.iter().enumerate() {
        let shift_lam = lam + 1e-12;
        let mut v = vec![1.0; m];
        for _ in 0..3 {
            // Forward elimination
            if m > 1 {
                let b0 = diag[0] - shift_lam;
                cp[0] = off[0] / b0;
                dp[0] = v[0] / b0;
                for i in 1..(m - 1) {
                    let denom = (diag[i] - shift_lam) - off[i - 1] * cp[i - 1];
                    cp[i] = off[i] / denom;
                    dp[i] = (v[i] - off[i - 1] * dp[i - 1]) / denom;
                }
                let denom = (diag[m - 1] - shift_lam) - off[m - 2] * cp[m - 2];
                dp[m - 1] = (v[m - 1] - off[m - 2] * dp[m - 2]) / denom;

                // Back substitution
                v[m - 1] = dp[m - 1];
                for i in (0..(m - 1)).rev() {
                    v[i] = dp[i] - cp[i] * v[i + 1];
                }
            }
            let norm_sq: f64 = v.iter().map(|&x| x * x).sum();
            let norm = norm_sq.sqrt();
            if norm > 0.0 {
                for x in &mut v {
                    *x /= norm;
                }
            }
        }

        // Standard convention (Percival & Walden, 1993):
        // Even tapers (k=0, 2, 4...) have positive sum
        if order % 2 == 0 {
            if v.iter().sum::<f64>() < 0.0 {
                for x in &mut v {
                    *x = -*x;
                }
            }
        } else {
            // Odd tapers: start with positive lobe
            let thresh = (1.0 / m as f64).max(1e-7);
            if let Some(&first_val) = v.iter().find(|&&x| x * x > thresh) {
                if first_val < 0.0 {
                    for x in &mut v {
                        *x = -*x;
                    }
                }
            }
        }
        tapers.push(v);
    }

    // Concentration ratios (eigenvalues of integral equation)
    let mut r = vec![0.0; m];
    r[0] = 2.0 * w;
    for idx in 1..m {
        r[idx] = (2.0 * pi * w * idx as f64).sin() / (pi * idx as f64);
    }

    let mut ratios = Vec::with_capacity(k);
    for taper in &tapers {
        let mut rxx = vec![0.0; m];
        for lag in 0..m {
            let mut sum = 0.0;
            for n in 0..(m - lag) {
                sum += taper[n] * taper[n + lag];
            }
            rxx[lag] = sum;
        }
        let mut lambda = rxx[0] * r[0];
        for lag in 1..m {
            lambda += 2.0 * rxx[lag] * r[lag];
        }
        ratios.push(lambda.clamp(0.0, 1.0));
    }

    (tapers, ratios)
}

/// Thomson's Adaptive Multitaper Power Spectral Density estimation.
pub fn multitaper_psd(
    signal: &[f64],
    sfreq: f64,
    nw: f64,
    adaptive: bool,
) -> (Vec<f64>, Vec<f64>) {
    let m = signal.len();
    if m < 4 || !sfreq.is_finite() || sfreq <= 0.0 || nw <= 0.0 {
        return (Vec::new(), Vec::new());
    }

    let k_max = ((2.0 * nw).floor() as usize).saturating_sub(1).max(1);
    let (tapers, lambdas) = dpss_windows(m, nw, k_max);
    if tapers.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let k = tapers.len();

    let mean = signal.iter().sum::<f64>() / m as f64;
    let centered: Vec<f64> = signal.iter().map(|&v| v - mean).collect();
    let var_sig = centered.iter().map(|&v| v * v).sum::<f64>() / m as f64;

    let nfft = m;
    let bins = nfft / 2 + 1;

    let mut spectra: Vec<Vec<f64>> = Vec::with_capacity(k);
    for taper in &tapers {
        let tapered: Vec<f64> = centered.iter().zip(taper).map(|(&x, &w)| x * w).collect();
        let mut power = rfft_power(&tapered);
        let scale = 1.0 / sfreq;
        for (idx, val) in power.iter_mut().enumerate() {
            *val *= scale;
            if idx != 0 && (nfft % 2 != 0 || idx != nfft / 2) {
                *val *= 2.0;
            }
        }
        spectra.push(power);
    }

    let mut psd = vec![0.0; bins];

    if adaptive && k >= 2 && var_sig > 0.0 {
        // Thomson adaptive spectral weighting
        for bin in 0..bins {
            psd[bin] = 0.5 * (spectra[0][bin] + spectra[1][bin]);
        }

        for _iter in 0..6 {
            let mut updated = vec![0.0; bins];
            for bin in 0..bins {
                let s_prev = psd[bin];
                let mut sum_b_s = 0.0;
                let mut sum_b = 0.0;
                for i in 0..k {
                    let lam = lambdas[i];
                    let denom = lam * s_prev + (1.0 - lam) * var_sig;
                    let d = if denom > 0.0 {
                        (lam.sqrt() * s_prev) / denom
                    } else {
                        1.0
                    };
                    let b = d * d;
                    sum_b_s += b * spectra[i][bin];
                    sum_b += b;
                }
                updated[bin] = if sum_b > 0.0 { sum_b_s / sum_b } else { s_prev };
            }
            psd = updated;
        }
    } else {
        for bin in 0..bins {
            let sum: f64 = spectra.iter().map(|s| s[bin]).sum();
            psd[bin] = sum / k as f64;
        }
    }

    let frequencies = (0..bins)
        .map(|idx| idx as f64 * sfreq / nfft as f64)
        .collect();

    (frequencies, psd)
}

pub fn bandpowers(signal: &[f64], sfreq: f64) -> BTreeMap<String, f64> {
    bandpowers_with_options(signal, sfreq, "welch", 1.0, false, 3.0, true, &BANDS)
}

pub fn bandpowers_with_options(
    signal: &[f64],
    sfreq: f64,
    psd_method: &str,
    window_seconds: f64,
    mean_average: bool,
    multitaper_nw: f64,
    multitaper_adaptive: bool,
    bands: &[(f64, f64, &str)],
) -> BTreeMap<String, f64> {
    let (frequencies, psd) = if psd_method.eq_ignore_ascii_case("multitaper") {
        multitaper_psd(signal, sfreq, multitaper_nw, multitaper_adaptive)
    } else {
        welch_psd_nperseg(signal, sfreq, (window_seconds * sfreq).round() as usize, mean_average)
    };
    if bands != &BANDS && frequencies.len()>1 {
        let low=bands.iter().map(|b|b.0).fold(1.0,f64::min);
        let high=bands.iter().map(|b|b.1).fold(40.0,f64::max);
        let total=integrate_trapezoid(&frequencies,&psd,low,high);
        return bands.iter().map(|&(low,high,label)|(format!("{label}_PSD"),if total>0.0 {integrate_trapezoid(&frequencies,&psd,low,high)/total}else{0.0})).collect();
    }
    if frequencies.is_empty() {
        return bands
            .iter()
            .map(|&(_, _, label)| (format!("{label}_PSD"), 0.0))
            .collect();
    }
    let minimum = bands
        .iter()
        .map(|band| band.0)
        .fold(f64::INFINITY, f64::min);
    let maximum = bands
        .iter()
        .map(|band| band.1)
        .fold(f64::NEG_INFINITY, f64::max);
    let selected: Vec<(f64, f64)> = frequencies
        .iter()
        .copied()
        .zip(psd.iter().copied())
        .filter(|(frequency, _)| *frequency >= minimum && *frequency <= maximum)
        .collect();
    if selected.len() < 2 {
        return bands
            .iter()
            .map(|&(_, _, label)| (format!("{label}_PSD"), 0.0))
            .collect();
    }
    let resolution = frequencies[1] - frequencies[0];
    let total_values: Vec<f64> = selected.iter().map(|(_, value)| *value).collect();
    let total = simpson(&total_values, resolution);
    if total <= 0.0 || !total.is_finite() {
        return bands
            .iter()
            .map(|&(_, _, label)| (format!("{label}_PSD"), 0.0))
            .collect();
    }
    bands
        .iter()
        .map(|&(low, high, label)| {
            let values: Vec<f64> = selected
                .iter()
                .filter_map(|(frequency, value)| {
                    (*frequency >= low && *frequency <= high).then_some(*value)
                })
                .collect();
            let power = simpson(&values, resolution);
            (format!("{label}_PSD"), power / total)
        })
        .collect()
}

pub fn integrate_trapezoid(frequencies:&[f64],values:&[f64],low:f64,high:f64)->f64 {
    frequencies.windows(2).zip(values.windows(2)).map(|(f,p)|{
        let start=low.max(f[0]);let end=high.min(f[1]);
        if end<=start||f[1]<=f[0]{return 0.0;}
        let interpolate=|at:f64|p[0]+(p[1]-p[0])*(at-f[0])/(f[1]-f[0]);
        (interpolate(start)+interpolate(end))*(end-start)/2.0
    }).sum()
}

pub fn acw50(signal:&[f64],sfreq:f64)->f64 {acw_fraction(signal,sfreq,0.5)}

pub fn individual_alpha_features(
    signal: &[f64],
    sfreq: f64,
    psd_method: &str,
    window_seconds: f64,
    mean_average: bool,
    multitaper_nw: f64,
    multitaper_adaptive: bool,
    iaf_min_hz: f64,
    iaf_max_hz: f64,
) -> BTreeMap<String, f64> {
    let mut out = BTreeMap::new();
    let (lo_search, hi_search) = if iaf_min_hz.is_finite() && iaf_max_hz.is_finite() && iaf_max_hz > iaf_min_hz {
        (iaf_min_hz, iaf_max_hz)
    } else {
        (7.0, 14.0)
    };
    let (frequencies, psd) = if psd_method.eq_ignore_ascii_case("multitaper") {
        multitaper_psd(signal, sfreq, multitaper_nw, multitaper_adaptive)
    } else {
        welch_psd_nperseg(signal, sfreq, (window_seconds * sfreq).round() as usize, mean_average)
    };
    if frequencies.len() < 3 || psd.len() != frequencies.len() {
        out.insert("IAF_Hz".into(), 0.5 * (lo_search + hi_search));
        out.insert("IndAlpha_PSD".into(), 0.0);
        out.insert("IndTheta_PSD".into(), 0.0);
        return out;
    }

    let in_range: Vec<usize> = frequencies
        .iter()
        .enumerate()
        .filter_map(|(i, &f)| (f >= lo_search && f <= hi_search).then_some(i))
        .collect();

    let mut best_local: Option<usize> = None;
    let mut best_local_val = f64::NEG_INFINITY;
    for &i in &in_range {
        if i > 0 && i + 1 < frequencies.len() && psd[i] >= psd[i - 1] && psd[i] >= psd[i + 1] && psd[i] > best_local_val {
            best_local_val = psd[i];
            best_local = Some(i);
        }
    }

    let iaf = if let Some(idx) = best_local {
        let y_l = psd[idx - 1];
        let y_c = psd[idx];
        let y_r = psd[idx + 1];
        let denom = 2.0 * (y_l - 2.0 * y_c + y_r);
        let df = frequencies[idx + 1] - frequencies[idx];
        let delta = if denom.abs() > 1e-18 && denom < 0.0 {
            ((y_l - y_r) / denom).clamp(-0.5, 0.5)
        } else {
            0.0
        };
        (frequencies[idx] + delta * df).clamp(lo_search, hi_search)
    } else {
        let mut num = 0.0;
        let mut den = 0.0;
        for &i in &in_range {
            let p = psd[i].max(0.0);
            num += frequencies[i] * p;
            den += p;
        }
        if den > 0.0 {
            (num / den).clamp(lo_search, hi_search)
        } else {
            0.5 * (lo_search + hi_search)
        }
    };

    let total = integrate_trapezoid(&frequencies, &psd, 1.0, 40.0);
    let alpha_lo = iaf - 2.0;
    let alpha_hi = iaf + 2.0;
    let theta_lo = (iaf - 6.0).max(1.0);
    let theta_hi = (iaf - 2.0).max(1.5).max(theta_lo + 0.5);
    let ind_alpha = if total > 0.0 {
        integrate_trapezoid(&frequencies, &psd, alpha_lo, alpha_hi) / total
    } else {
        0.0
    };
    let ind_theta = if total > 0.0 {
        integrate_trapezoid(&frequencies, &psd, theta_lo, theta_hi) / total
    } else {
        0.0
    };
    out.insert("IAF_Hz".into(), iaf);
    out.insert("IndAlpha_PSD".into(), ind_alpha);
    out.insert("IndTheta_PSD".into(), ind_theta);
    out
}

pub const SPECTRAL_RATIO_NAMES: [&str; 8] = [
    "Ratio_Theta_Delta",
    "Ratio_Alpha_Theta",
    "Ratio_Alpha_Delta",
    "Ratio_Beta_Alpha",
    "Ratio_Beta_ThetaAlpha",
    "Ratio_Gamma_AlphaBeta",
    "Ratio_Gamma_Beta",
    "Ratio_Beta2_Beta1",
];

pub fn spectral_ratios_from_bandpowers(bp: &BTreeMap<String, f64>) -> BTreeMap<String, f64> {
    let g = |k: &str| bp.get(k).copied().filter(|v| v.is_finite()).unwrap_or(0.0);
    let delta = g("Delta_PSD");
    let theta = g("Theta_PSD");
    let alpha = g("Alpha_PSD");
    let beta1 = g("Beta1_PSD");
    let beta2 = g("Beta2_PSD");
    let gamma1 = g("Gamma1_PSD");
    let beta = beta1 + beta2;
    let div = |num: f64, den: f64| -> f64 {
        if den > 0.0 && num.is_finite() && den.is_finite() {
            num / den
        } else {
            f64::NAN
        }
    };
    let mut out = BTreeMap::new();
    out.insert("Ratio_Theta_Delta".into(), div(theta, delta));
    out.insert("Ratio_Alpha_Theta".into(), div(alpha, theta));
    out.insert("Ratio_Alpha_Delta".into(), div(alpha, delta));
    out.insert("Ratio_Beta_Alpha".into(), div(beta, alpha));
    out.insert("Ratio_Beta_ThetaAlpha".into(), div(beta, theta + alpha));
    out.insert("Ratio_Gamma_AlphaBeta".into(), div(gamma1, alpha + beta));
    out.insert("Ratio_Gamma_Beta".into(), div(gamma1, beta));
    out.insert("Ratio_Beta2_Beta1".into(), div(beta2, beta1));
    out
}
pub fn acw_fraction(signal: &[f64], sfreq: f64, fraction:f64) -> f64 {
    if signal.is_empty() || sfreq == 0.0 {
        return f64::NAN;
    }
    let mean = signal.iter().sum::<f64>() / signal.len() as f64;
    let centered: Vec<f64> = signal.iter().map(|value| value - mean).collect();
    let variance = centered.iter().map(|value| value * value).sum::<f64>();
    if variance == 0.0 {
        return f64::NAN;
    }
    for lag in 1..signal.len() {
        let autocorrelation = centered[..centered.len() - lag]
            .iter()
            .zip(&centered[lag..])
            .map(|(left, right)| left * right)
            .sum::<f64>()
            / variance;
        if autocorrelation <= fraction {
            return lag as f64 / sfreq;
        }
    }
    f64::NAN
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_resampled_epoch_preserves_fft_grid() {
        let signal: Vec<f64> = (0..132).map(|i| (i as f64 * 0.3).sin()).collect();
        let (freq, psd) = welch_median_nperseg(&signal, 132.0, 250);
        assert_eq!(freq.len(), 126);
        assert_eq!(psd.len(), 126);
        assert!(psd.iter().all(|v| v.is_finite()));
        assert!(welch_median_nperseg(&[], 250.0, 250).0.is_empty());
        assert!(welch_median_nperseg(&signal, 250.0, 0).0.is_empty());
    }

    #[test]
    fn one_second_irasa_does_not_panic() {
        let signal: Vec<f64> = (0..250).map(|i| (i as f64 * 0.3).sin()).collect();
        let result = crate::eeg::spectral::irasa_features(&signal, 250.0);
        assert!(!result.is_empty());
        assert!(result.values().all(|v| v.is_finite()));
    }

    #[test]
    fn sine_power_peaks_in_alpha() {
        let sfreq = 250.0;
        let signal: Vec<f64> = (0..3750)
            .map(|index| (2.0 * std::f64::consts::PI * 10.0 * index as f64 / sfreq).sin())
            .collect();
        let powers = bandpowers(&signal, sfreq);
        assert!(powers["Alpha_PSD"] > powers["Delta_PSD"]);
    }

    #[test]
    fn individual_alpha_and_ratios_work() {
        let sfreq = 250.0;
        let signal: Vec<f64> = (0..3750)
            .map(|index| (2.0 * std::f64::consts::PI * 10.0 * index as f64 / sfreq).sin())
            .collect();
        let iaf = individual_alpha_features(&signal, sfreq, "welch", 1.0, false, 3.0, true, 7.0, 14.0);
        assert!((iaf["IAF_Hz"] - 10.0).abs() < 0.5, "got {}", iaf["IAF_Hz"]);
        assert!(iaf["IndAlpha_PSD"] > 0.7, "got {}", iaf["IndAlpha_PSD"]);

        let mut bp = BTreeMap::new();
        bp.insert("Delta_PSD".into(), 0.2);
        bp.insert("Theta_PSD".into(), 0.1);
        bp.insert("Alpha_PSD".into(), 0.4);
        bp.insert("Beta1_PSD".into(), 0.1);
        bp.insert("Beta2_PSD".into(), 0.1);
        bp.insert("Gamma1_PSD".into(), 0.1);
        let ratios = spectral_ratios_from_bandpowers(&bp);
        assert!((ratios["Ratio_Alpha_Theta"] - 4.0).abs() < 1e-12);
        assert!((ratios["Ratio_Beta_Alpha"] - 0.5).abs() < 1e-12);
        assert!((ratios["Ratio_Beta2_Beta1"] - 1.0).abs() < 1e-12);
    }
}
