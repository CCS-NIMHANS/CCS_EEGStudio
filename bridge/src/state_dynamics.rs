//! State Dynamics Analysis (SDA)
//! Port of Python StateDynamics_v02 based on
//! "EEG evidence for reproducible neural states during Buddhist Highest Yoga Tantra meditation"
//! (Sci Rep 2026, s41598-026-45893-4).

use nalgebra::{DMatrix, SymmetricEigen};
use rand::prelude::*;
use rand::rngs::StdRng;
use serde::{Deserialize, Serialize};
use statrs::distribution::{ContinuousCDF, Normal};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::Path;

fn default_featureset() -> String {
    "paper".to_string()
}
fn default_scale() -> String {
    "60s".to_string()
}
fn default_iv_threshold() -> f64 {
    0.4
}
fn default_display_band() -> String {
    "Gamma1".to_string()
}
fn default_repr_channel() -> String {
    "Fz".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    #[serde(default = "default_job_type")]
    pub job_type: String,
    pub files: Vec<String>,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default = "default_featureset")]
    pub featureset: String,
    #[serde(default = "default_scale")]
    pub scale: String,
    #[serde(default)]
    pub k: Option<usize>,
    #[serde(default = "default_iv_threshold")]
    pub iv_threshold: f64,
    #[serde(default = "default_display_band")]
    pub display_band: String,
    #[serde(default = "default_repr_channel")]
    pub repr_channel: String,
    #[serde(default)]
    pub feature_families: Option<Vec<String>>,
    #[serde(default)]
    pub rank_transform: bool,
    #[serde(default = "default_step_s")]
    pub step_s: f64,
    #[serde(default = "default_win_s")]
    pub win_s: f64,
}

fn default_job_type() -> String {
    "state_dynamics".to_string()
}
fn default_step_s() -> f64 {
    2.5
}
fn default_win_s() -> f64 {
    5.0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StateDynamicsResult {
    pub feature_set: String,
    pub scale: String,
    pub chosen_k: usize,
    pub iv_threshold: f64,
    pub display_band: String,
    pub repr_channel: String,
    pub silhouette_scores: BTreeMap<usize, f64>,
    pub available_scales: Vec<String>,
    pub available_families: Vec<String>,
    pub metrics: Vec<String>,
    pub rois: Vec<String>,
    pub recordings: Vec<RecordingTimeline>,
    pub states: Vec<StateSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingTimeline {
    pub key: String,
    pub label: String,
    pub file: String,
    pub n_windows: usize,
    pub duration_s: f64,
    pub windows: Vec<WindowPoint>,
    pub events: Vec<EventMarker>,
    pub cut_points: BTreeMap<String, Vec<usize>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowPoint {
    pub win_idx: usize,
    pub t_start: f64,
    pub t_center: f64,
    pub stage_idx: usize,
    pub state_label: String,
    pub state_color: String,
    pub band_mean: f64,
    pub band_ci95: f64,
    pub repr_chan: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventMarker {
    pub onset_s: f64,
    pub label: String,
    pub marker_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StateSummary {
    pub label: String,
    pub color: String,
    pub n_stages: usize,
    pub total_time_s: f64,
    pub duration_min: f64,
    pub percent_time: f64,
    pub median_stage_s: f64,
    pub time_per_recording: BTreeMap<String, f64>,
    pub top_features: Vec<String>,
    pub centroid_z: Vec<Vec<f64>>, // [n_metrics, n_rois]
    pub sig_dots: Vec<Vec<bool>>,   // [n_metrics, n_rois]
    pub iv_values: Vec<Vec<f64>>,  // [n_metrics, n_rois]
}

pub const PALETTE: &[&str] = &[
    "#0072B2", "#E69F00", "#009E73", "#D55E00", "#56B4E9", "#CC79A7", "#F0E442", "#999999",
];

pub fn default_rois() -> Vec<(&'static str, &'static [&'static str])> {
    vec![
        ("Prefrontal", &["Fp1", "Fp2", "FP1", "FP2"]),
        ("Frontal_L", &["F3", "F7", "FC5"]),
        ("Frontal_M", &["Fz", "FC1", "FC2", "FZ"]),
        ("Frontal_R", &["F4", "F8", "FC6"]),
        ("Central_L", &["C3", "CP1"]),
        ("Central_M", &["Cz", "CZ"]),
        ("Central_R", &["C4", "CP2"]),
        ("Temporal_L", &["T7", "FT9", "TP9", "CP5", "T3"]),
        ("Temporal_R", &["T8", "FT10", "TP10", "CP6", "T4"]),
        ("Parietal", &["Pz", "P3", "P4", "P7", "P8", "PZ"]),
        ("Occipital", &["O1", "Oz", "O2", "OZ"]),
    ]
}

pub const PSD_BANDS: &[&str] = &["Delta", "Theta", "Alpha", "Beta1", "Beta2", "Gamma1"];
pub const COH_BANDS: &[&str] = &["Theta", "Alpha", "Beta1", "Beta2", "Gamma1"];
pub const MIC_BANDS: &[&str] = &["Theta", "Alpha", "Beta1", "Beta2", "Gamma1"];

pub fn classify_col(c: &str) -> (String, String, bool) {
    const BANDS7: &[&str] = &["Delta", "Theta", "ThetaAlpha", "Alpha", "Beta1", "Beta2", "Gamma1"];
    if let Some(rest) = c.strip_prefix("conn_mic_") {
        return ("MIC".into(), rest.into(), false);
    }
    if let Some(rest) = c.strip_prefix("conn_coh_") {
        return ("Coh".into(), rest.into(), false);
    }
    if c == "ACW" {
        return ("ACW".into(), "ACW".into(), false);
    }
    if let Some(rest) = c.strip_suffix("_nonlinear") {
        return ("Nonlinear".into(), rest.into(), false);
    }
    for &(suf, fb, fp) in &[
        ("_PSD", "PSD", "PSD"),
        ("_FOOOF", "FOOOF_band", "FOOOF_param"),
        ("_Irasa", "IRASA_band", "IRASA_param"),
    ] {
        if let Some(rest) = c.strip_suffix(suf) {
            let is_band = BANDS7.contains(&rest);
            let fam = if is_band { fb } else { fp };
            return (fam.into(), rest.into(), is_band);
        }
    }
    ("Other".into(), c.into(), false)
}

pub struct FeatureDef {
    pub ftype: String,
    pub name: String,
    pub roi: String,
    pub fname: String,
}

/// Compute segment cost matrix: cost[i, j] = within-segment sum of squares of X[i:j]
pub fn seg_cost(x: &DMatrix<f64>) -> DMatrix<f64> {
    let n = x.nrows();
    let d = x.ncols();
    let mut s = DMatrix::<f64>::zeros(n + 1, d);
    let mut q = vec![0.0; n + 1];

    for i in 0..n {
        let mut row_sq = 0.0;
        for j in 0..d {
            let val = x[(i, j)];
            s[(i + 1, j)] = s[(i, j)] + val;
            row_sq += val * val;
        }
        q[i + 1] = q[i] + row_sq;
    }

    let mut cost = DMatrix::<f64>::from_element(n + 1, n + 1, f64::INFINITY);
    for i in 0..n {
        for j in (i + 1)..=n {
            let len = (j - i) as f64;
            let dq = q[j] - q[i];
            let mut dot = 0.0;
            for c in 0..d {
                let diff = s[(j, c)] - s[(i, c)];
                dot += diff * diff;
            }
            let c = (dq - dot / len).max(0.0);
            cost[(i, j)] = c;
        }
    }
    cost
}

/// DP segmentation minimizing SSE for all k = 1..kmax
pub fn dp_segmentation(
    cost: &DMatrix<f64>,
    kmax: usize,
    min_len: usize,
) -> (Vec<f64>, DMatrix<usize>) {
    let n = cost.nrows() - 1;
    let mut d = vec![f64::INFINITY; n + 1];
    d[0] = 0.0;

    let mut sse = vec![f64::NAN; kmax + 1];
    let mut back = DMatrix::<usize>::zeros(kmax + 1, n + 1);

    for k in 1..=kmax {
        let mut d_next = vec![f64::INFINITY; n + 1];
        for j in 1..=n {
            let mut best_val = f64::INFINITY;
            let mut best_i = 0;
            for i in 0..j {
                if j - i >= min_len {
                    let c = cost[(i, j)];
                    if c.is_finite() {
                        let total = d[i] + c;
                        if total < best_val {
                            best_val = total;
                            best_i = i;
                        }
                    }
                }
            }
            d_next[j] = best_val;
            back[(k, j)] = best_i;
        }
        d = d_next;
        sse[k] = d[n];
    }

    (sse, back)
}

pub fn cuts_from_back(back: &DMatrix<usize>, k: usize, n: usize) -> Vec<usize> {
    let mut cuts = vec![n];
    let mut j = n;
    for kk in (1..=k).rev() {
        j = back[(kk, j)];
        cuts.push(j);
    }
    cuts.reverse();
    cuts
}

/// PCA on already standardized data (z-scored).
/// Returns scores (n_samples x n_comp), explained variance ratio (n_comp), and loadings (n_features x n_comp).
pub fn pca_fit(z: &DMatrix<f64>, n_comp: usize) -> (DMatrix<f64>, Vec<f64>, DMatrix<f64>) {
    let n = z.nrows();
    let d = z.ncols();
    let n_comp = n_comp.min(n - 1).min(d);

    // Center columns
    let mut zc = z.clone();
    for c in 0..d {
        let mut sum = 0.0;
        for r in 0..n {
            sum += zc[(r, c)];
        }
        let mean = sum / n as f64;
        for r in 0..n {
            zc[(r, c)] -= mean;
        }
    }

    if d <= n {
        // Covariance matrix = Zc^T * Zc / (n - 1)
        let cov = (zc.transpose() * &zc) / ((n - 1) as f64);
        let eigen = SymmetricEigen::new(cov);
        let mut idx: Vec<usize> = (0..d).collect();
        idx.sort_by(|&a, &b| eigen.eigenvalues[b].partial_cmp(&eigen.eigenvalues[a]).unwrap());

        let total_var: f64 = eigen.eigenvalues.iter().filter(|v| **v > 0.0).sum();
        let mut evr = Vec::with_capacity(n_comp);
        let mut v_mat = DMatrix::<f64>::zeros(d, n_comp);

        for c in 0..n_comp {
            let i = idx[c];
            let val = eigen.eigenvalues[i].max(0.0);
            evr.push(if total_var > 0.0 { val / total_var } else { 0.0 });
            for r in 0..d {
                v_mat[(r, c)] = eigen.eigenvectors[(r, i)];
            }
        }

        let scores = &zc * &v_mat;
        (scores, evr, v_mat)
    } else {
        // Gram matrix = Zc * Zc^T / (n - 1)
        let gram = (&zc * zc.transpose()) / ((n - 1) as f64);
        let eigen = SymmetricEigen::new(gram);
        let mut idx: Vec<usize> = (0..n).collect();
        idx.sort_by(|&a, &b| eigen.eigenvalues[b].partial_cmp(&eigen.eigenvalues[a]).unwrap());

        let total_var: f64 = eigen.eigenvalues.iter().filter(|v| **v > 0.0).sum();
        let mut evr = Vec::with_capacity(n_comp);
        let mut u_mat = DMatrix::<f64>::zeros(n, n_comp);

        for c in 0..n_comp {
            let i = idx[c];
            let val = eigen.eigenvalues[i].max(0.0);
            evr.push(if total_var > 0.0 { val / total_var } else { 0.0 });
            let scale = if val > 0.0 { ((n - 1) as f64 * val).sqrt() } else { 0.0 };
            for r in 0..n {
                u_mat[(r, c)] = eigen.eigenvectors[(r, i)] * scale;
            }
        }
        let loadings = DMatrix::<f64>::zeros(d, n_comp);
        (u_mat, evr, loadings)
    }
}

/// Compute percentile edges (10 bins / 9 deciles) per feature
pub fn decile_edges(z: &DMatrix<f64>) -> Vec<Vec<f64>> {
    let n = z.nrows();
    let d = z.ncols();
    let qs = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9];
    let mut edges = Vec::with_capacity(d);

    for j in 0..d {
        let mut col: Vec<f64> = (0..n).map(|r| z[(r, j)]).collect();
        col.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let mut feat_edges = Vec::new();
        for &q in &qs {
            let idx = ((n - 1) as f64 * q).round() as usize;
            let val = col[idx];
            let prev = feat_edges.last().copied().unwrap_or(f64::NAN);
            if feat_edges.is_empty() || (val - prev).abs() > 1e-12 {
                feat_edges.push(val);
            }
        }
        edges.push(feat_edges);
    }
    edges
}

/// Information Value (IV) for each feature given a boolean in_stage mask
pub fn information_value(
    z: &DMatrix<f64>,
    in_stage: &[bool],
    edges: &[Vec<f64>],
    smooth: f64,
) -> Vec<f64> {
    let n = z.nrows();
    let d = z.ncols();
    let mut iv = vec![0.0; d];

    for j in 0..d {
        let edge = &edges[j];
        let n_bins = edge.len() + 1;
        let mut ce = vec![smooth; n_bins];
        let mut cn = vec![smooth; n_bins];

        for r in 0..n {
            let val = z[(r, j)];
            let bin = match edge.binary_search_by(|e| e.partial_cmp(&val).unwrap_or(std::cmp::Ordering::Equal)) {
                Ok(idx) => idx + 1,
                Err(idx) => idx,
            };
            let b = bin.min(n_bins - 1);
            if in_stage[r] {
                ce[b] += 1.0;
            } else {
                cn[b] += 1.0;
            }
        }

        let sum_e: f64 = ce.iter().sum();
        let sum_n: f64 = cn.iter().sum();
        let mut feat_iv = 0.0;
        for b in 0..n_bins {
            let pe = ce[b] / sum_e;
            let pn = cn[b] / sum_n;
            feat_iv += (pe - pn) * (pe / pn).ln();
        }
        iv[j] = feat_iv.min(1.0);
    }
    iv
}

/// K-Means++ clustering implementation with multiple initializations
pub fn kmeans_fit(
    data: &DMatrix<f64>,
    k: usize,
    n_init: usize,
    max_iter: usize,
    seed: u64,
) -> (Vec<usize>, f64, DMatrix<f64>) {
    let n = data.nrows();
    let d = data.ncols();
    if k == 1 {
        let mut centroid = DMatrix::<f64>::zeros(1, d);
        for c in 0..d {
            let sum: f64 = (0..n).map(|r| data[(r, c)]).sum();
            centroid[(0, c)] = sum / n as f64;
        }
        let mut sse = 0.0;
        for r in 0..n {
            for c in 0..d {
                let diff = data[(r, c)] - centroid[(0, c)];
                sse += diff * diff;
            }
        }
        return (vec![0; n], sse, centroid);
    }

    let mut rng = StdRng::seed_from_u64(seed);
    let mut best_labels = vec![0; n];
    let mut best_sse = f64::INFINITY;
    let mut best_centroids = DMatrix::<f64>::zeros(k, d);

    for _ in 0..n_init {
        let mut centroids = DMatrix::<f64>::zeros(k, d);
        // Step 1: choose first center uniformly at random
        let first_idx = rng.gen_range(0..n);
        for c in 0..d {
            centroids[(0, c)] = data[(first_idx, c)];
        }

        let mut min_dists_sq = vec![f64::INFINITY; n];
        for r in 0..n {
            let mut dist_sq = 0.0;
            for c in 0..d {
                let diff = data[(r, c)] - centroids[(0, c)];
                dist_sq += diff * diff;
            }
            min_dists_sq[r] = dist_sq;
        }

        // Step 2: choose subsequent centers with probability proportional to dist_sq
        for c_idx in 1..k {
            let total_weight: f64 = min_dists_sq.iter().sum();
            let mut r_val = rng.gen::<f64>() * total_weight;
            let mut chosen = 0;
            for r in 0..n {
                r_val -= min_dists_sq[r];
                if r_val <= 0.0 {
                    chosen = r;
                    break;
                }
            }
            for c in 0..d {
                centroids[(c_idx, c)] = data[(chosen, c)];
            }
            for r in 0..n {
                let mut dist_sq = 0.0;
                for c in 0..d {
                    let diff = data[(r, c)] - centroids[(c_idx, c)];
                    dist_sq += diff * diff;
                }
                if dist_sq < min_dists_sq[r] {
                    min_dists_sq[r] = dist_sq;
                }
            }
        }

        // Step 3: Lloyd iterations
        let mut labels = vec![0; n];
        let mut counts = vec![0usize; k];

        for _iter in 0..max_iter {
            let mut changed = false;
            for r in 0..n {
                let mut min_d = f64::INFINITY;
                let mut best_k = 0;
                for ki in 0..k {
                    let mut dist = 0.0;
                    for c in 0..d {
                        let diff = data[(r, c)] - centroids[(ki, c)];
                        dist += diff * diff;
                    }
                    if dist < min_d {
                        min_d = dist;
                        best_k = ki;
                    }
                }
                if labels[r] != best_k {
                    labels[r] = best_k;
                    changed = true;
                }
            }

            if !changed && _iter > 0 {
                break;
            }

            // Update centroids
            let mut new_centroids = DMatrix::<f64>::zeros(k, d);
            counts.fill(0);
            for r in 0..n {
                let l = labels[r];
                counts[l] += 1;
                for c in 0..d {
                    new_centroids[(l, c)] += data[(r, c)];
                }
            }
            for ki in 0..k {
                if counts[ki] > 0 {
                    for c in 0..d {
                        new_centroids[(ki, c)] /= counts[ki] as f64;
                    }
                } else {
                    // Empty cluster fallback: pick random data point
                    let rnd = rng.gen_range(0..n);
                    for c in 0..d {
                        new_centroids[(ki, c)] = data[(rnd, c)];
                    }
                }
            }
            centroids = new_centroids;
        }

        // Calculate SSE
        let mut sse = 0.0;
        for r in 0..n {
            let l = labels[r];
            for c in 0..d {
                let diff = data[(r, c)] - centroids[(l, c)];
                sse += diff * diff;
            }
        }

        if sse < best_sse {
            best_sse = sse;
            best_labels = labels;
            best_centroids = centroids;
        }
    }

    (best_labels, best_sse, best_centroids)
}

/// Compute silhouette score for a clustering
pub fn silhouette_score(data: &DMatrix<f64>, labels: &[usize], k: usize) -> f64 {
    let n = data.nrows();
    let d = data.ncols();
    if k <= 1 || k >= n {
        return 0.0;
    }

    let mut cluster_sizes = vec![0usize; k];
    for &l in labels {
        cluster_sizes[l] += 1;
    }

    // Pairwise squared distances can be precomputed or computed on the fly
    let mut total_s = 0.0;
    for i in 0..n {
        let ci = labels[i];
        if cluster_sizes[ci] <= 1 {
            continue;
        }

        let mut dist_to_clusters = vec![0.0; k];
        for j in 0..n {
            let mut dist_sq = 0.0;
            for c in 0..d {
                let diff = data[(i, c)] - data[(j, c)];
                dist_sq += diff * diff;
            }
            dist_to_clusters[labels[j]] += dist_sq.sqrt();
        }

        let a = dist_to_clusters[ci] / (cluster_sizes[ci] - 1) as f64;
        let mut b = f64::INFINITY;
        for ki in 0..k {
            if ki != ci && cluster_sizes[ki] > 0 {
                let mean_dist = dist_to_clusters[ki] / cluster_sizes[ki] as f64;
                if mean_dist < b {
                    b = mean_dist;
                }
            }
        }

        let s = (b - a) / a.max(b);
        total_s += s;
    }

    total_s / n as f64
}

/// Mann-Whitney U test (two-sided, asymptotic with tie correction)
/// Returns (U, rank_biserial_r, p_value)
pub fn mann_whitney_u(xa: &[f64], xb: &[f64]) -> (f64, f64, f64) {
    let na = xa.len();
    let nb = xb.len();
    if na < 2 || nb < 2 {
        return (0.0, 0.0, 1.0);
    }

    // Combine and sort (value, group: 0 for a, 1 for b)
    let mut combined: Vec<(f64, u8)> = Vec::with_capacity(na + nb);
    for &v in xa {
        combined.push((v, 0));
    }
    for &v in xb {
        combined.push((v, 1));
    }
    combined.sort_by(|x, y| x.0.partial_cmp(&y.0).unwrap_or(std::cmp::Ordering::Equal));

    let n_tot = na + nb;
    let mut r_a = 0.0;
    let mut tie_sum = 0.0;

    let mut i = 0;
    while i < n_tot {
        let mut j = i + 1;
        while j < n_tot && (combined[j].0 - combined[i].0).abs() < 1e-12 {
            j += 1;
        }
        let tie_len = (j - i) as f64;
        if tie_len > 1.0 {
            tie_sum += tie_len * tie_len * tie_len - tie_len;
        }
        // Average rank is (i + 1 + j) / 2.0
        let avg_rank = (i + 1 + j) as f64 / 2.0;
        for k in i..j {
            if combined[k].1 == 0 {
                r_a += avg_rank;
            }
        }
        i = j;
    }

    let u_a = r_a - (na * (na + 1)) as f64 / 2.0;
    let r = 2.0 * u_a / (na * nb) as f64 - 1.0;

    let mean_u = (na * nb) as f64 / 2.0;
    let var_u = ((na * nb) as f64 / (12.0 * n_tot as f64 * (n_tot - 1) as f64))
        * ((n_tot * n_tot * n_tot - n_tot) as f64 - tie_sum);
    let sd_u = var_u.max(1e-12).sqrt();
    let z = (u_a - mean_u) / sd_u;

    let normal = Normal::new(0.0, 1.0).unwrap();
    let p = 2.0 * (1.0 - normal.cdf(z.abs())).max(0.0).min(1.0);

    (u_a, r, p)
}

/// Run full State Dynamics pipeline
pub fn run(job: &Job) -> Result<StateDynamicsResult, String> {
    if job.files.is_empty() {
        return Err("No input feature files provided for State Dynamics analysis".into());
    }

    let rois_def = default_rois();
    let roi_names: Vec<String> = rois_def.iter().map(|(r, _)| r.to_string()).collect();

    // Map channel names to ROI index
    let mut chan_to_roi: HashMap<String, usize> = HashMap::new();
    for (r_idx, (_, chs)) in rois_def.iter().enumerate() {
        for &ch in *chs {
            chan_to_roi.insert(ch.to_uppercase(), r_idx);
        }
    }

    // Load feature tables
    let mut raw_windows: Vec<Vec<f64>> = Vec::new();
    let mut feat_defs: Vec<FeatureDef> = Vec::new();

    struct RecData {
        key: String,
        label: String,
        file: String,
        win_count: usize,
        t_start: Vec<f64>,
        t_center: Vec<f64>,
        events: Vec<EventMarker>,
        band_mean: Vec<f64>,
        band_ci95: Vec<f64>,
        repr_chan: Vec<f64>,
    }

    let mut rec_data_list = Vec::new();

    for (file_idx, file_path) in job.files.iter().enumerate() {
        let content = fs::read_to_string(file_path)
            .map_err(|e| format!("Failed to read {}: {}", file_path, e))?;
        let mut lines = content.lines();
        let header_line = lines.next().ok_or("Empty feature file")?;
        let header: Vec<String> = header_line.split(',').map(|s| s.trim().to_string()).collect();

        let chan_col = header.iter().position(|h| h == "Chan").ok_or("Missing Chan column")?;
        let epoch_col = header.iter().position(|h| h == "Epoch").ok_or("Missing Epoch column")?;
        let tstart_col = header.iter().position(|h| h == "epoch_start_s").ok_or("Missing epoch_start_s")?;
        let tend_col = header.iter().position(|h| h == "epoch_end_s");
        let ev_col = header.iter().position(|h| h == "event_markers");

        // Parse rows grouped by epoch
        struct Row {
            chan: String,
            epoch: usize,
            t_start: f64,
            t_end: f64,
            markers: String,
            vals: HashMap<String, f64>,
        }

        let mut rows_by_epoch: BTreeMap<usize, Vec<Row>> = BTreeMap::new();
        for line in lines {
            if line.trim().is_empty() {
                continue;
            }
            let parts: Vec<&str> = line.split(',').collect();
            if parts.len() < header.len() {
                continue;
            }
            let chan = parts[chan_col].trim().to_string();
            let epoch = parts[epoch_col].trim().parse::<usize>().unwrap_or(0);
            let t_start = parts[tstart_col].trim().parse::<f64>().unwrap_or(0.0);
            let t_end = tend_col.and_then(|c| parts[c].trim().parse::<f64>().ok()).unwrap_or(t_start + job.win_s);
            let markers = ev_col.map(|c| parts[c].trim().to_string()).unwrap_or_default();

            let mut vals = HashMap::new();
            for (idx, h) in header.iter().enumerate() {
                if idx != chan_col && idx != epoch_col && idx != tstart_col && Some(idx) != tend_col && Some(idx) != ev_col {
                    if let Ok(num) = parts[idx].trim().parse::<f64>() {
                        vals.insert(h.clone(), num);
                    }
                }
            }

            rows_by_epoch.entry(epoch).or_default().push(Row {
                chan,
                epoch,
                t_start,
                t_end,
                markers,
                vals,
            });
        }

        let n_win = rows_by_epoch.len();
        let key = format!("R{}", file_idx + 1);
        let label = job.labels.get(file_idx).cloned().unwrap_or_else(|| {
            Path::new(file_path)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(&key)
                .replace(".features", "")
        });

        let mut t_start_vec = Vec::with_capacity(n_win);
        let mut t_center_vec = Vec::with_capacity(n_win);
        let mut events_map: BTreeMap<(i64, String), String> = BTreeMap::new();
        let mut band_mean_vec = Vec::with_capacity(n_win);
        let mut band_ci95_vec = Vec::with_capacity(n_win);
        let mut repr_chan_vec = Vec::with_capacity(n_win);

        let disp_band_col = format!("{}_PSD", job.display_band);

        for (_epoch_num, ch_rows) in rows_by_epoch {
            let t_s = ch_rows.first().map(|r| r.t_start).unwrap_or(0.0);
            t_start_vec.push(t_s);
            t_center_vec.push(t_s + job.win_s / 2.0);

            // Extract events if present
            for r in &ch_rows {
                if !r.markers.is_empty() && r.markers != "[]" && r.markers != "\"[]\"" {
                    if let Ok(parsed_events) = serde_json::from_str::<serde_json::Value>(&r.markers) {
                        if let Some(arr) = parsed_events.as_array() {
                            for ev in arr {
                                let onset = ev["onset_s"].as_f64().unwrap_or(0.0);
                                let lbl = ev["label"].as_str().unwrap_or("").to_string();
                                let ty = ev["type"].as_str().unwrap_or("").to_string();
                                if !lbl.is_empty() {
                                    events_map.insert(((onset * 1000.0).round() as i64, lbl), ty);
                                }
                            }
                        }
                    }
                }
            }

            // Time course band calculation
            let mut psd_vals: Vec<f64> = Vec::new();
            let mut repr_val = 0.0;
            for r in &ch_rows {
                if let Some(&v) = r.vals.get(&disp_band_col) {
                    psd_vals.push(v);
                    if r.chan.eq_ignore_ascii_case(&job.repr_channel) {
                        repr_val = v;
                    }
                }
            }

            if !psd_vals.is_empty() {
                let mean: f64 = psd_vals.iter().sum::<f64>() / psd_vals.len() as f64;
                let var: f64 = psd_vals.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>()
                    / (psd_vals.len() - 1).max(1) as f64;
                let ci95 = 1.96 * var.sqrt() / (psd_vals.len() as f64).sqrt();
                band_mean_vec.push(mean);
                band_ci95_vec.push(ci95);
                repr_chan_vec.push(repr_val);
            } else {
                band_mean_vec.push(0.0);
                band_ci95_vec.push(0.0);
                repr_chan_vec.push(0.0);
            }

            // Build features for this window
            let mut win_features = Vec::new();
            let is_first_win = raw_windows.is_empty();

            if job.featureset == "paper" {
                // 1. PSD for 6 bands
                for &b in PSD_BANDS {
                    let col = format!("{}_PSD", b);
                    let mut roi_sums = vec![0.0; roi_names.len()];
                    let mut roi_counts = vec![0usize; roi_names.len()];
                    for r in &ch_rows {
                        if let Some(&roi_idx) = chan_to_roi.get(&r.chan.to_uppercase()) {
                            if let Some(&v) = r.vals.get(&col) {
                                roi_sums[roi_idx] += v.max(1e-10).log10();
                                roi_counts[roi_idx] += 1;
                            }
                        }
                    }
                    for ri in 0..roi_names.len() {
                        let avg = if roi_counts[ri] > 0 { roi_sums[ri] / roi_counts[ri] as f64 } else { 0.0 };
                        win_features.push(avg);
                        if is_first_win {
                            feat_defs.push(FeatureDef {
                                ftype: "PSD".into(),
                                name: b.into(),
                                roi: roi_names[ri].clone(),
                                fname: format!("PSD|{}|{}", b, roi_names[ri]),
                            });
                        }
                    }
                }

                // 2. Ratios (8 ratios)
                let ratios = [
                    ("Theta/Delta", vec!["Theta"], vec!["Delta"]),
                    ("Alpha/Theta", vec!["Alpha"], vec!["Theta"]),
                    ("Alpha/Delta", vec!["Alpha"], vec!["Delta"]),
                    ("Beta/Alpha", vec!["Beta1", "Beta2"], vec!["Alpha"]),
                    ("Beta/(Theta+Alpha)", vec!["Beta1", "Beta2"], vec!["Theta", "Alpha"]),
                    ("Gamma/(Alpha+Beta)", vec!["Gamma1"], vec!["Alpha", "Beta1", "Beta2"]),
                    ("Gamma/Beta", vec!["Gamma1"], vec!["Beta1", "Beta2"]),
                    ("Beta2/Beta1", vec!["Beta2"], vec!["Beta1"]),
                ];

                for (rn, num_bands, den_bands) in ratios {
                    let mut roi_sums = vec![0.0; roi_names.len()];
                    let mut roi_counts = vec![0usize; roi_names.len()];
                    for r in &ch_rows {
                        if let Some(&roi_idx) = chan_to_roi.get(&r.chan.to_uppercase()) {
                            let mut num_sum = 0.0;
                            for &nb in &num_bands {
                                if let Some(&v) = r.vals.get(&format!("{}_PSD", nb)) {
                                    num_sum += v;
                                }
                            }
                            let mut den_sum = 0.0;
                            for &db in &den_bands {
                                if let Some(&v) = r.vals.get(&format!("{}_PSD", db)) {
                                    den_sum += v;
                                }
                            }
                            if num_sum > 0.0 && den_sum > 0.0 {
                                roi_sums[roi_idx] += (num_sum / den_sum).log10();
                                roi_counts[roi_idx] += 1;
                            }
                        }
                    }
                    for ri in 0..roi_names.len() {
                        let avg = if roi_counts[ri] > 0 { roi_sums[ri] / roi_counts[ri] as f64 } else { 0.0 };
                        win_features.push(avg);
                        if is_first_win {
                            feat_defs.push(FeatureDef {
                                ftype: "Ratio".into(),
                                name: rn.into(),
                                roi: roi_names[ri].clone(),
                                fname: format!("Ratio|{}|{}", rn, roi_names[ri]),
                            });
                        }
                    }
                }

                // 3. Coherence for 5 bands
                for &b in COH_BANDS {
                    let col = format!("conn_coh_{}", b);
                    let mut roi_sums = vec![0.0; roi_names.len()];
                    let mut roi_counts = vec![0usize; roi_names.len()];
                    for r in &ch_rows {
                        if let Some(&roi_idx) = chan_to_roi.get(&r.chan.to_uppercase()) {
                            if let Some(&v) = r.vals.get(&col) {
                                roi_sums[roi_idx] += v;
                                roi_counts[roi_idx] += 1;
                            }
                        }
                    }
                    for ri in 0..roi_names.len() {
                        let avg = if roi_counts[ri] > 0 { roi_sums[ri] / roi_counts[ri] as f64 } else { 0.0 };
                        win_features.push(avg);
                        if is_first_win {
                            feat_defs.push(FeatureDef {
                                ftype: "Coh".into(),
                                name: b.into(),
                                roi: roi_names[ri].clone(),
                                fname: format!("Coh|{}|{}", b, roi_names[ri]),
                            });
                        }
                    }
                }

                // 4. MIC for 5 bands (global median)
                for &b in MIC_BANDS {
                    let col = format!("conn_mic_{}", b);
                    let mut vals: Vec<f64> = ch_rows.iter().filter_map(|r| r.vals.get(&col).copied()).collect();
                    vals.sort_by(|x, y| x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal));
                    let med = if !vals.is_empty() {
                        vals[vals.len() / 2]
                    } else {
                        0.0
                    };
                    win_features.push(med);
                    if is_first_win {
                        feat_defs.push(FeatureDef {
                            ftype: "MIC".into(),
                            name: b.into(),
                            roi: "Global".into(),
                            fname: format!("MIC|{}|Global", b),
                        });
                    }
                }
            } else {
                // Full feature set
                let non_feature_cols: HashSet<&str> = [
                    "Chan", "Epoch", "epoch_label", "filename", "subjid", "sessn", "condn", "bin_idx",
                    "bin_start_s", "bin_end_s", "mode", "epoch_start_s", "epoch_end_s",
                    "connectivity_settings", "event_markers",
                ].into_iter().collect();

                let feature_cols: Vec<&String> = header.iter().filter(|c| !non_feature_cols.contains(c.as_str())).collect();
                for &col in &feature_cols {
                    let (family, short_name, is_band) = classify_col(col);

                    if family == "MIC" {
                        let mut vals: Vec<f64> = ch_rows.iter().filter_map(|r| r.vals.get(col).copied()).collect();
                        vals.sort_by(|x, y| x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal));
                        let med = if !vals.is_empty() { vals[vals.len() / 2] } else { 0.0 };
                        win_features.push(med);
                        if is_first_win {
                            feat_defs.push(FeatureDef {
                                ftype: family,
                                name: short_name.clone(),
                                roi: "Global".into(),
                                fname: format!("MIC|{}|Global", short_name),
                            });
                        }
                    } else {
                        let mut roi_sums = vec![0.0; roi_names.len()];
                        let mut roi_counts = vec![0usize; roi_names.len()];
                        for r in &ch_rows {
                            if let Some(&roi_idx) = chan_to_roi.get(&r.chan.to_uppercase()) {
                                if let Some(&v) = r.vals.get(col) {
                                    if v.is_finite() {
                                        let transformed = if is_band { v.max(1e-3).log10() } else { v };
                                        roi_sums[roi_idx] += transformed;
                                        roi_counts[roi_idx] += 1;
                                    }
                                }
                            }
                        }
                        for ri in 0..roi_names.len() {
                            let avg = if roi_counts[ri] > 0 { roi_sums[ri] / roi_counts[ri] as f64 } else { f64::NAN };
                            win_features.push(avg);
                            if is_first_win {
                                feat_defs.push(FeatureDef {
                                    ftype: family.clone(),
                                    name: short_name.clone(),
                                    roi: roi_names[ri].clone(),
                                    fname: format!("{}|{}|{}", family, short_name, roi_names[ri]),
                                });
                            }
                        }
                    }
                }
            }

            raw_windows.push(win_features);
        }

        let events: Vec<EventMarker> = events_map
            .into_iter()
            .map(|((t_ms, lbl), ty)| EventMarker {
                onset_s: t_ms as f64 / 1000.0,
                label: lbl,
                marker_type: ty,
            })
            .collect();

        rec_data_list.push(RecData {
            key,
            label,
            file: file_path.clone(),
            win_count: n_win,
            t_start: t_start_vec,
            t_center: t_center_vec,
            events,
            band_mean: band_mean_vec,
            band_ci95: band_ci95_vec,
            repr_chan: repr_chan_vec,
        });
    }

    let n_total_windows = raw_windows.len();
    let n_feat = feat_defs.len();
    if n_total_windows == 0 || n_feat == 0 {
        return Err("No valid feature windows found in recordings".into());
    }

    // Convert raw windows to DMatrix and impute NaNs with column medians
    let mut x_mat = DMatrix::<f64>::zeros(n_total_windows, n_feat);
    for c in 0..n_feat {
        let mut vals: Vec<f64> = (0..n_total_windows)
            .map(|r| raw_windows[r][c])
            .filter(|v| v.is_finite())
            .collect();
        vals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let med = if !vals.is_empty() { vals[vals.len() / 2] } else { 0.0 };
        for r in 0..n_total_windows {
            let v = raw_windows[r][c];
            x_mat[(r, c)] = if v.is_finite() { v } else { med };
        }
    }

    // Available families in order of discovery
    let mut available_families: Vec<String> = Vec::new();
    let mut fam_seen = HashSet::new();
    for f in &feat_defs {
        if fam_seen.insert(f.ftype.clone()) {
            available_families.push(f.ftype.clone());
        }
    }

    // Filter by requested feature_families if provided and non-empty
    let (feat_defs, x_mat, n_feat) = if let Some(ref req_fam) = job.feature_families {
        let req_set: HashSet<&str> = req_fam.iter().map(|s| s.as_str()).collect();
        let keep_indices: Vec<usize> = feat_defs
            .iter()
            .enumerate()
            .filter(|(_, f)| req_set.contains(f.ftype.as_str()))
            .map(|(i, _)| i)
            .collect();
        if !keep_indices.is_empty() && keep_indices.len() < feat_defs.len() {
            let new_defs: Vec<FeatureDef> = keep_indices
                .iter()
                .map(|&i| FeatureDef {
                    ftype: feat_defs[i].ftype.clone(),
                    name: feat_defs[i].name.clone(),
                    roi: feat_defs[i].roi.clone(),
                    fname: feat_defs[i].fname.clone(),
                })
                .collect();
            let mut new_x = DMatrix::<f64>::zeros(n_total_windows, keep_indices.len());
            for (new_c, &old_c) in keep_indices.iter().enumerate() {
                for r in 0..n_total_windows {
                    new_x[(r, new_c)] = x_mat[(r, old_c)];
                }
            }
            let new_n = keep_indices.len();
            (new_defs, new_x, new_n)
        } else {
            (feat_defs, x_mat, n_feat)
        }
    } else {
        (feat_defs, x_mat, n_feat)
    };

    // Z-score across all pooled windows
    let mut z_mat = DMatrix::<f64>::zeros(n_total_windows, n_feat);
    for c in 0..n_feat {
        let mut sum = 0.0;
        for r in 0..n_total_windows {
            sum += x_mat[(r, c)];
        }
        let mean = sum / n_total_windows as f64;
        let mut var = 0.0;
        for r in 0..n_total_windows {
            let diff = x_mat[(r, c)] - mean;
            var += diff * diff;
        }
        let sd = (var / (n_total_windows - 1).max(1) as f64).sqrt().max(1e-12);
        for r in 0..n_total_windows {
            let z = (x_mat[(r, c)] - mean) / sd;
            z_mat[(r, c)] = z.clamp(-5.0, 5.0);
        }
    }

    // PCA to 15 PCs for SDA
    let n_pc = 15.min(n_feat).min(n_total_windows - 1);
    let (mut pcs, _evr, _load) = pca_fit(&z_mat, n_pc);

    if job.rank_transform {
        for c in 0..pcs.ncols() {
            let mut col_vals: Vec<(usize, f64)> = (0..n_total_windows).map(|r| (r, pcs[(r, c)])).collect();
            col_vals.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
            let normal = Normal::new(0.0, 1.0).unwrap();
            for (rank, &(orig_r, _)) in col_vals.iter().enumerate() {
                let p = (rank as f64 + 0.5) / n_total_windows as f64;
                pcs[(orig_r, c)] = normal.inverse_cdf(p);
            }
        }
    }

    // Segmentation for each recording
    let standard_scales = ["auto", "300s", "120s", "60s", "30s", "15s"];
    let mut rec_segs: BTreeMap<String, BTreeMap<String, Vec<usize>>> = BTreeMap::new();

    let mut start_row = 0;
    for rec in &rec_data_list {
        let n = rec.win_count;
        let end_row = start_row + n;
        let rec_pcs = pcs.rows(start_row, n).into_owned();
        start_row = end_row;

        let total_t_s = n as f64 * job.step_s;
        let kmax = (n / 2).clamp(1, 240);
        let cost = seg_cost(&rec_pcs);
        let (_sse, back) = dp_segmentation(&cost, kmax, 2);

        let mut scale_cuts = BTreeMap::new();
        // Fixed scale durations
        for dur in [300, 120, 60, 30, 15] {
            let k = ((total_t_s / dur as f64).round() as usize).clamp(1, kmax);
            let cuts = cuts_from_back(&back, k, n);
            scale_cuts.insert(format!("{}s", dur), cuts);
        }
        // Auto scale (default to 60s or k=round(T/60) if not sweeping surrogates)
        let auto_k = ((total_t_s / 60.0).round() as usize).clamp(1, kmax);
        let auto_cuts = cuts_from_back(&back, auto_k, n);
        scale_cuts.insert("auto".into(), auto_cuts);

        rec_segs.insert(rec.key.clone(), scale_cuts);
    }

    // Select segmentation for chosen scale
    let selected_scale = &job.scale;
    struct Stage {
        rec_idx: usize,
        stage_idx: usize,
        win_a: usize,
        win_b: usize,
        global_win_a: usize,
        global_win_b: usize,
        dur_s: f64,
    }

    let mut stages = Vec::new();
    let mut stage_assignments = vec![0usize; n_total_windows];

    let mut g_offset = 0;
    for (rec_idx, rec) in rec_data_list.iter().enumerate() {
        let cuts = rec_segs[&rec.key]
            .get(selected_scale)
            .or_else(|| rec_segs[&rec.key].get("60s"))
            .unwrap();

        for s_idx in 0..(cuts.len() - 1) {
            let a = cuts[s_idx];
            let b = cuts[s_idx + 1];
            let global_a = g_offset + a;
            let global_b = g_offset + b;
            let gid = stages.len();

            for w in global_a..global_b {
                stage_assignments[w] = gid;
            }

            stages.push(Stage {
                rec_idx,
                stage_idx: s_idx,
                win_a: a,
                win_b: b,
                global_win_a: global_a,
                global_win_b: global_b,
                dur_s: (b - a) as f64 * job.step_s,
            });
        }
        g_offset += rec.win_count;
    }

    let n_stages = stages.len();
    if n_stages < 2 {
        return Err("Fewer than 2 stages detected at the chosen scale".into());
    }

    // Build stage vectors: medZ + Information Value
    let deciles = decile_edges(&z_mat);
    let mut med_z = DMatrix::<f64>::zeros(n_stages, n_feat);
    let mut iv_mat = DMatrix::<f64>::zeros(n_stages, n_feat);

    for (s_id, st) in stages.iter().enumerate() {
        let win_len = st.global_win_b - st.global_win_a;
        for c in 0..n_feat {
            let mut vals: Vec<f64> = (st.global_win_a..st.global_win_b).map(|w| z_mat[(w, c)]).collect();
            vals.sort_by(|x, y| x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal));
            med_z[(s_id, c)] = vals[win_len / 2];
        }

        let mut in_stage_mask = vec![false; n_total_windows];
        for w in st.global_win_a..st.global_win_b {
            in_stage_mask[w] = true;
        }
        let iv = information_value(&z_mat, &in_stage_mask, &deciles, 0.5);
        for c in 0..n_feat {
            iv_mat[(s_id, c)] = iv[c];
        }
    }

    // Stage feature vectors: concatenate medZ and IV (2 * n_feat)
    let mut stage_v = DMatrix::<f64>::zeros(n_stages, n_feat * 2);
    for s_id in 0..n_stages {
        for c in 0..n_feat {
            stage_v[(s_id, c)] = med_z[(s_id, c)];
            stage_v[(s_id, n_feat + c)] = iv_mat[(s_id, c)];
        }
    }

    // PCA of stage vectors to 10 components
    let stage_pc_count = 10.min(n_stages - 1).min(n_feat * 2);
    let (stage_vp, _, _) = pca_fit(&stage_v, stage_pc_count);

    // K-Means clustering for k = 2..8 and compute silhouette scores
    let mut sil_map = BTreeMap::new();
    let mut clusterings = BTreeMap::new();

    let max_k = 8.min(n_stages - 1);
    let mut best_sil = -1.0;
    let mut sil_best_k = 2;

    for k_val in 2..=max_k {
        let (lab, _sse, _) = kmeans_fit(&stage_vp, k_val, 100, 300, 1);
        let s = silhouette_score(&stage_vp, &lab, k_val);
        sil_map.insert(k_val, s);
        clusterings.insert(k_val, lab);
        if s > best_sil {
            best_sil = s;
            sil_best_k = k_val;
        }
    }

    let chosen_k = job.k.unwrap_or(sil_best_k).clamp(2, max_k);
    let stage_cluster_labels = &clusterings[&chosen_k];

    // Order clusters by total time duration covered (A = highest time)
    let mut cluster_durations = vec![0.0; chosen_k];
    for (s_id, &c_lab) in stage_cluster_labels.iter().enumerate() {
        cluster_durations[c_lab] += stages[s_id].dur_s;
    }

    let mut cluster_rank: Vec<usize> = (0..chosen_k).collect();
    cluster_rank.sort_by(|&a, &b| cluster_durations[b].partial_cmp(&cluster_durations[a]).unwrap());

    let mut old_to_letter = vec!['A'; chosen_k];
    for (rank, &orig_c) in cluster_rank.iter().enumerate() {
        old_to_letter[orig_c] = (b'A' + rank as u8) as char;
    }

    let mut stage_letters = Vec::with_capacity(n_stages);
    for &c_lab in stage_cluster_labels {
        stage_letters.push(old_to_letter[c_lab]);
    }

    let mut window_letters = Vec::with_capacity(n_total_windows);
    for &st_id in &stage_assignments {
        window_letters.push(stage_letters[st_id]);
    }

    // Cluster centroids and Mann-Whitney U tests
    let letters: Vec<char> = (0..chosen_k).map(|i| (b'A' + i as u8) as char).collect();
    let total_all_time: f64 = stages.iter().map(|s| s.dur_s).sum();

    // Map feature definitions to 2D grid: metric (PSD Delta, etc.) x ROI (Prefrontal..Occipital, Global)
    let mut metric_keys: Vec<String> = Vec::new();
    let mut metric_seen = HashSet::new();
    for f in &feat_defs {
        let m = format!("{}|{}", f.ftype, f.name);
        if metric_seen.insert(m.clone()) {
            metric_keys.push(m);
        }
    }

    let mut all_rois = roi_names.clone();
    all_rois.push("Global".into());

    let mut feat_to_row_col: HashMap<String, (usize, usize)> = HashMap::new();
    for f in &feat_defs {
        let m = format!("{}|{}", f.ftype, f.name);
        if let (Some(r_idx), Some(c_idx)) = (metric_keys.iter().position(|x| x == &m), all_rois.iter().position(|x| x == &f.roi)) {
            feat_to_row_col.insert(f.fname.clone(), (r_idx, c_idx));
        }
    }

    let mut state_summaries = Vec::new();
    let n_bonf_tests = (chosen_k * n_feat) as f64;

    for (letter_idx, &let_char) in letters.iter().enumerate() {
        let color = PALETTE[letter_idx % PALETTE.len()].to_string();
        let st_mask: Vec<bool> = stage_letters.iter().map(|&c| c == let_char).collect();
        let win_mask: Vec<bool> = window_letters.iter().map(|&c| c == let_char).collect();

        let n_st: usize = st_mask.iter().filter(|&&v| v).count();
        let tot_time: f64 = stages.iter().zip(&st_mask).filter(|(_, &m)| m).map(|(s, _)| s.dur_s).sum();
        let pct_time = if total_all_time > 0.0 { 100.0 * tot_time / total_all_time } else { 0.0 };

        let mut st_durs: Vec<f64> = stages.iter().zip(&st_mask).filter(|(_, &m)| m).map(|(s, _)| s.dur_s).collect();
        st_durs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let med_dur = if !st_durs.is_empty() { st_durs[st_durs.len() / 2] } else { 0.0 };

        let mut time_per_rec = BTreeMap::new();
        for rec in &rec_data_list {
            let dur: f64 = stages
                .iter()
                .zip(&st_mask)
                .filter(|(s, &m)| m && rec_data_list[s.rec_idx].key == rec.key)
                .map(|(s, _)| s.dur_s)
                .sum();
            time_per_rec.insert(rec.key.clone(), dur);
        }

        // Centroid z-scores and IV means for each feature
        let mut feat_centroid = vec![0.0; n_feat];
        let mut feat_iv = vec![0.0; n_feat];
        let mut feat_sig = vec![false; n_feat];

        for c in 0..n_feat {
            let mut sum_z = 0.0;
            let mut sum_iv = 0.0;
            let mut cnt = 0;
            for s_id in 0..n_stages {
                if st_mask[s_id] {
                    sum_z += med_z[(s_id, c)];
                    sum_iv += iv_mat[(s_id, c)];
                    cnt += 1;
                }
            }
            if cnt > 0 {
                feat_centroid[c] = sum_z / cnt as f64;
                feat_iv[c] = sum_iv / cnt as f64;
            }

            // Mann-Whitney U test vs rest of windows
            let mut xa = Vec::new();
            let mut xb = Vec::new();
            for w in 0..n_total_windows {
                if win_mask[w] {
                    xa.push(z_mat[(w, c)]);
                } else {
                    xb.push(z_mat[(w, c)]);
                }
            }
            let (_u, r, p) = mann_whitney_u(&xa, &xb);
            let p_bonf = (p * n_bonf_tests).min(1.0);
            if (p_bonf < 0.01 && r.abs() >= 0.5) || feat_iv[c] >= job.iv_threshold {
                feat_sig[c] = true;
            }
        }

        // Top distinguishing features
        let mut feat_rank: Vec<usize> = (0..n_feat).collect();
        feat_rank.sort_by(|&a, &b| feat_centroid[b].abs().partial_cmp(&feat_centroid[a].abs()).unwrap());
        let top_feats: Vec<String> = feat_rank
            .iter()
            .take(6)
            .map(|&i| format!("{}({:+0.1})", feat_defs[i].fname, feat_centroid[i]))
            .collect();

        // 2D grids [n_metrics, n_rois]
        let mut grid_z = vec![vec![0.0; all_rois.len()]; metric_keys.len()];
        let mut grid_sig = vec![vec![false; all_rois.len()]; metric_keys.len()];
        let mut grid_iv = vec![vec![0.0; all_rois.len()]; metric_keys.len()];

        for (c, f) in feat_defs.iter().enumerate() {
            if let Some(&(r_idx, c_idx)) = feat_to_row_col.get(&f.fname) {
                grid_z[r_idx][c_idx] = feat_centroid[c];
                grid_sig[r_idx][c_idx] = feat_sig[c];
                grid_iv[r_idx][c_idx] = feat_iv[c];
            }
        }

        state_summaries.push(StateSummary {
            label: let_char.to_string(),
            color,
            n_stages: n_st,
            total_time_s: tot_time,
            duration_min: tot_time / 60.0,
            percent_time: pct_time,
            median_stage_s: med_dur,
            time_per_recording: time_per_rec,
            top_features: top_feats,
            centroid_z: grid_z,
            sig_dots: grid_sig,
            iv_values: grid_iv,
        });
    }

    // Assemble final recording timelines
    let mut recordings = Vec::new();
    let mut g_win_idx = 0;

    for (_rec_idx, rec) in rec_data_list.iter().enumerate() {
        let mut win_points = Vec::with_capacity(rec.win_count);
        for w in 0..rec.win_count {
            let st_id = stage_assignments[g_win_idx];
            let st_let = stage_letters[st_id];
            let color = PALETTE[((st_let as u8 - b'A') as usize) % PALETTE.len()].to_string();

            win_points.push(WindowPoint {
                win_idx: w,
                t_start: rec.t_start[w],
                t_center: rec.t_center[w],
                stage_idx: stages[st_id].stage_idx,
                state_label: st_let.to_string(),
                state_color: color,
                band_mean: rec.band_mean[w],
                band_ci95: rec.band_ci95[w],
                repr_chan: rec.repr_chan[w],
            });
            g_win_idx += 1;
        }

        recordings.push(RecordingTimeline {
            key: rec.key.clone(),
            label: rec.label.clone(),
            file: rec.file.clone(),
            n_windows: rec.win_count,
            duration_s: rec.win_count as f64 * job.step_s,
            windows: win_points,
            events: rec.events.clone(),
            cut_points: rec_segs[&rec.key].clone(),
        });
    }

    Ok(StateDynamicsResult {
        feature_set: job.featureset.clone(),
        scale: selected_scale.clone(),
        chosen_k,
        iv_threshold: job.iv_threshold,
        display_band: job.display_band.clone(),
        repr_channel: job.repr_channel.clone(),
        silhouette_scores: sil_map,
        available_scales: standard_scales.iter().map(|&s| s.to_string()).collect(),
        available_families,
        metrics: metric_keys,
        rois: all_rois,
        recordings,
        states: state_summaries,
    })
}
