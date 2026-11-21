use flate2::read::GzDecoder;
use nalgebra::DMatrix;
use rayon::prelude::*;
use serde::Deserialize;
use std::collections::HashMap;

use super::montage::STANDARD_1005_POS;
use super::xpikan::xpikan_inverse_operator;

#[derive(Deserialize)]
struct RoiData {
    name: String,
    indices: Vec<usize>,
}

#[derive(Deserialize)]
struct FsaverageData {
    channels: Vec<String>,
    leadfield: Vec<Vec<f64>>,
    rois: Vec<RoiData>,
}

pub fn convert_to_source_space(
    channels: &[Vec<f64>],
    labels: &[String],
    snr: f64,
) -> Result<(Vec<Vec<f64>>, Vec<String>), String> {
    if channels.is_empty() || channels[0].is_empty() {
        return Err("Input channel data is empty".to_string());
    }
    convert_with_model(channels, labels, snr, "mne", "")
}

fn spherical_fallback_coords(l: &DMatrix<f64>) -> Vec<[f64; 3]> {
    let m = l.nrows();
    let gram = l * l.transpose();
    let eig = gram.symmetric_eigen();
    let mut order: Vec<usize> = (0..eig.eigenvalues.len()).collect();
    order.sort_by(|&a, &b| eig.eigenvalues[b].total_cmp(&eig.eigenvalues[a]));
    (0..m)
        .map(|i| {
            let x = if !order.is_empty() { eig.eigenvectors[(i, order[0])] } else { 1.0 };
            let y = if order.len() > 1 { eig.eigenvectors[(i, order[1])] } else { 0.0 };
            let z = if order.len() > 2 { eig.eigenvectors[(i, order[2])] } else { 0.0 };
            let n = (x * x + y * y + z * z).sqrt();
            if n > 1e-9 {
                [x / n, y / n, z / n]
            } else {
                let theta = 2.0 * std::f64::consts::PI * (i as f64 / m.max(1) as f64);
                [theta.cos(), theta.sin(), 0.25]
            }
        })
        .collect()
}

pub fn inverse_operator(
    l: &DMatrix<f64>,
    data: &DMatrix<f64>,
    snr: f64,
    method: &str,
) -> Result<DMatrix<f64>, String> {
    inverse_operator_with_coords(l, data, snr, method, None)
}

/// Fixed-orientation inverse operators; optional 3D sensor coordinates for XPIKAN.
pub fn inverse_operator_with_coords(
    l: &DMatrix<f64>,
    data: &DMatrix<f64>,
    snr: f64,
    method: &str,
    sensor_coords: Option<&[[f64; 3]]>,
) -> Result<DMatrix<f64>, String> {
    if !snr.is_finite() || snr <= 0.0 {
        return Err("SNR must be positive".into());
    }
    let m = l.nrows();
    let gram = l * l.transpose();
    let alpha = gram.trace() / m as f64 / (snr * snr);
    if method == "lcmv" {
        let mut centered = data.clone();
        for r in 0..m {
            let mean = data.row(r).iter().sum::<f64>() / data.ncols() as f64;
            for c in 0..data.ncols() {
                centered[(r, c)] -= mean;
            }
        }
        let cov = &centered * centered.transpose() / (data.ncols().saturating_sub(1).max(1) as f64);
        let reg = cov.trace() / m as f64 * 0.05;
        let inv = (cov + DMatrix::identity(m, m) * reg)
            .try_inverse()
            .ok_or("LCMV covariance is singular")?;
        let mut w = l.transpose() * inv;
        for r in 0..w.nrows() {
            let gain = (w.row(r) * l.column(r))[(0, 0)];
            if gain <= 0.0 {
                return Err("LCMV source has zero gain".into());
            }
            w.row_mut(r).scale_mut(1.0 / gain);
        }
        return Ok(w);
    }
    if method == "xpikan" {
        let owned_coords;
        let coords = match sensor_coords {
            Some(c) if c.len() == m => c,
            _ => {
                owned_coords = spherical_fallback_coords(l);
                &owned_coords
            }
        };
        return xpikan_inverse_operator(l, data, snr, coords);
    }
    if method == "eloreta" {
        // Exact Low-Resolution Brain Electromagnetic Tomography (Pascual-Marqui, 2007;
        // MNE-Python fixed-orientation eLORETA formulation):
        // 1. Average-reference center the leadfield: L_c = H * L, H = I - (1/m) 1 1^T.
        // 2. Iteratively solve w_i = sqrt(L_{c,i}^T * M * L_{c,i}), where
        //    M = (L_c W^{-1} L_c^T + alpha_k H)^+ on the (m-1)-dim avg-ref subspace
        //    and alpha_k = tr(L_c W^{-1} L_c^T) / (m * snr^2) keeps SNR exact.
        // 3. Uses two allocation-free GEMMs per iteration (G_w = L_s L_s^T, Q = M L_c)
        //    and symmetric eigendecomposition on the tiny m x m Gram matrix.
        let p = l.ncols();
        if m < 2 || p == 0 {
            return Err("eLORETA requires at least 2 channels and 1 source".into());
        }
        // Center columns of L (average reference operator H = I - 11^T / m)
        let mut lc = l.clone();
        for c in 0..p {
            let col_mean = lc.column(c).iter().sum::<f64>() / (m as f64);
            for r in 0..m {
                lc[(r, c)] -= col_mean;
            }
        }
        // Centering matrix H
        let h_mat = DMatrix::from_fn(m, m, |r, c| {
            if r == c { 1.0 - 1.0 / (m as f64) } else { -1.0 / (m as f64) }
        });

        let mut inv_w = vec![1.0_f64; p]; // stores w_i^{-1}
        let mut l_scaled = DMatrix::zeros(m, p);
        let mut q_mat = DMatrix::zeros(m, p);
        let inv_snr2 = 1.0 / (snr * snr);

        for _iter in 0..25 {
            // Normalize inv_w so mean(inv_w) == 1 (stabilizes trace & regularization scale)
            let mean_inv_w = inv_w.iter().sum::<f64>() / (p as f64);
            if mean_inv_w > 0.0 && mean_inv_w.is_finite() {
                for v in &mut inv_w {
                    *v /= mean_inv_w;
                }
            }
            for c in 0..p {
                let s = inv_w[c].max(1e-18).sqrt();
                for r in 0..m {
                    l_scaled[(r, c)] = lc[(r, c)] * s;
                }
            }
            let gw = &l_scaled * l_scaled.transpose();
            let tr = gw.trace();
            if !tr.is_finite() || tr <= 0.0 {
                return Err("eLORETA Gram matrix has non-positive trace".into());
            }
            let alpha_k = (tr / (m as f64)) * inv_snr2;
            let reg_gw = gw + &h_mat * alpha_k;
            // Pseudoinverse on the average-referenced subspace via symmetric eigen
            let eig = reg_gw.symmetric_eigen();
            let max_ev = eig
                .eigenvalues
                .iter()
                .copied()
                .fold(0.0_f64, f64::max);
            if max_ev <= 0.0 || !max_ev.is_finite() {
                return Err("eLORETA Gram matrix is singular".into());
            }
            let tol = max_ev * 1e-12;
            let mut m_pinv = DMatrix::zeros(m, m);
            for k in 0..m {
                let ev = eig.eigenvalues[k];
                if ev > tol {
                    let v = eig.eigenvectors.column(k);
                    m_pinv += (&v * v.transpose()) * (1.0 / ev);
                }
            }
            // Enforce H M H symmetry on avg-ref subspace
            let m_op = &h_mat * &m_pinv * &h_mat;
            q_mat = &m_op * &lc;

            let mut max_rel = 0.0_f64;
            for c in 0..p {
                let mut quad = 0.0_f64;
                for r in 0..m {
                    quad += lc[(r, c)] * q_mat[(r, c)];
                }
                let w_new = quad.max(1e-18).sqrt();
                let inv_w_new = 1.0 / w_new;
                let rel = (inv_w_new - inv_w[c]).abs() / inv_w[c].max(1e-18);
                if rel > max_rel {
                    max_rel = rel;
                }
                inv_w[c] = inv_w_new;
            }
            if max_rel < 1e-5 {
                break;
            }
        }
        // Final inverse operator K = W^{-1} L_c^T M = W^{-1} Q^T
        let mut w_op = q_mat.transpose();
        for i in 0..p {
            w_op.row_mut(i).scale_mut(inv_w[i]);
        }
        return Ok(w_op);
    }
    if !["mne", "dspm", "sloreta"].contains(&method) {
        return Err(format!("Unknown inverse method: {method}"));
    }
    let inv = (gram + DMatrix::identity(m, m) * alpha)
        .try_inverse()
        .ok_or("Leadfield inverse is singular")?;
    let mut w = l.transpose() * inv;
    if method != "mne" {
        for r in 0..w.nrows() {
            let variance = if method == "dspm" {
                w.row(r).norm_squared()
            } else {
                (w.row(r) * l.column(r))[(0, 0)]
            };
            if variance > 0.0 {
                w.row_mut(r).scale_mut(1.0 / variance.sqrt());
            }
        }
    }
    Ok(w)
}

pub fn convert_with_model(
    channels: &[Vec<f64>],
    labels: &[String],
    snr: f64,
    method: &str,
    model_path: &str,
) -> Result<(Vec<Vec<f64>>, Vec<String>), String> {
    if channels.is_empty()
        || channels[0].is_empty()
        || channels.len() != labels.len()
        || channels
            .iter()
            .any(|c| c.len() != channels[0].len() || c.iter().any(|v| !v.is_finite()))
    {
        return Err("Invalid source input dimensions or nonfinite data".into());
    }
    let samples = channels[0].len();

    eprintln!("PROGRESS 10 Loading canonical fsaverage leadfield model...");
    let compressed = include_bytes!("../resources/fsaverage_1005_roi.json.gz");
    let model: FsaverageData = if model_path.is_empty() {
        serde_json::from_reader(GzDecoder::new(&compressed[..]))
    } else {
        let file = std::fs::File::open(model_path).map_err(|e| format!("Forward model: {e}"))?;
        if model_path.ends_with(".gz") {
            serde_json::from_reader(GzDecoder::new(file))
        } else {
            serde_json::from_reader(file)
        }
    }
    .map_err(|e| format!("Forward model JSON: {e}"))?;
    if model.channels.is_empty()
        || model.leadfield.len() != model.channels.len()
        || model.leadfield[0].is_empty()
        || model
            .leadfield
            .iter()
            .any(|r| r.len() != model.leadfield[0].len() || r.iter().any(|v| !v.is_finite()))
        || model.rois.is_empty()
        || model.rois.iter().any(|r| {
            r.indices.is_empty() || r.indices.iter().any(|&i| i >= model.leadfield[0].len())
        })
    {
        return Err("Invalid forward model dimensions or atlas source indices".into());
    }

    let canon_lookup: HashMap<String, usize> = model
        .channels
        .iter()
        .enumerate()
        .map(|(i, name)| (name.to_lowercase().replace('.', "").replace('-', ""), i))
        .collect();

    let mut matched_rec_idx = Vec::new();
    let mut matched_canon_idx = Vec::new();
    for (i, label) in labels.iter().enumerate() {
        let norm = label.to_lowercase().replace('.', "").replace('-', "");
        if let Some(&c_idx) = canon_lookup.get(&norm) {
            matched_rec_idx.push(i);
            matched_canon_idx.push(c_idx);
        }
    }

    let m = matched_rec_idx.len();
    if m < 4 {
        return Err(format!(
            "Only found {} matched 10-05 channels out of {}. Need at least 4 for source localization.",
            m, labels.len()
        ));
    }

    eprintln!(
        "PROGRESS 20 Constructing forward leadfield for {} matched channels...",
        m
    );
    let n_sources = model.leadfield[0].len();
    let l_mat = DMatrix::from_fn(m, n_sources, |r, c| {
        model.leadfield[matched_canon_idx[r]][c]
    });

    eprintln!("PROGRESS 40 Computing regularized inverse operator (MNE / minimum norm)...");
    let data = DMatrix::from_fn(m, samples, |r, c| channels[matched_rec_idx[r]][c]);
    let matched_coords: Vec<[f64; 3]> = matched_rec_idx
        .iter()
        .enumerate()
        .map(|(k, &idx)| {
            let upper = labels[idx].to_uppercase();
            if let Some(&pos) = STANDARD_1005_POS.get(upper.as_str()) {
                pos
            } else {
                let theta = 2.0 * std::f64::consts::PI * (k as f64 / m.max(1) as f64);
                [0.08 * theta.cos(), 0.08 * theta.sin(), 0.03]
            }
        })
        .collect();
    let w_mat = inverse_operator_with_coords(&l_mat, &data, snr, method, Some(&matched_coords))?;

    eprintln!(
        "PROGRESS 60 Projecting {} samples to {} cortical dipoles...",
        samples, n_sources
    );
    let x_data: Vec<Vec<f64>> = matched_rec_idx
        .iter()
        .map(|&idx| channels[idx].clone())
        .collect();

    eprintln!("PROGRESS 80 Extracting atlas ROI time courses (mean-flip alignment)...");
    let n_rois = model.rois.len();
    let roi_channels: Vec<Vec<f64>> = (0..n_rois)
        .into_par_iter()
        .map(|r_idx| {
            let roi = &model.rois[r_idx];
            let k = roi.indices.len();
            if k == 0 {
                return vec![0.0f64; samples];
            }

            let mut w_roi = DMatrix::zeros(k, m);
            for (row_idx, &dipole_idx) in roi.indices.iter().enumerate() {
                for col_idx in 0..m {
                    w_roi[(row_idx, col_idx)] = w_mat[(dipole_idx, col_idx)];
                }
            }

            let mut s_roi = vec![vec![0.0f64; samples]; k];
            for row_idx in 0..k {
                for s in 0..samples {
                    let mut sum = 0.0;
                    for col_idx in 0..m {
                        sum += w_roi[(row_idx, col_idx)] * x_data[col_idx][s];
                    }
                    s_roi[row_idx][s] = sum;
                }
            }

            let mut mean_tc = vec![0.0f64; samples];
            for s in 0..samples {
                let sum: f64 = (0..k).map(|row_idx| s_roi[row_idx][s]).sum();
                mean_tc[s] = sum / (k as f64);
            }

            let mut flips = vec![1.0f64; k];
            for row_idx in 0..k {
                let dot: f64 = (0..samples).map(|s| s_roi[row_idx][s] * mean_tc[s]).sum();
                if dot < 0.0 {
                    flips[row_idx] = -1.0;
                }
            }

            let mut roi_tc = vec![0.0f64; samples];
            for s in 0..samples {
                let sum: f64 = (0..k)
                    .map(|row_idx| flips[row_idx] * s_roi[row_idx][s])
                    .sum();
                roi_tc[s] = (sum / (k as f64))
                    * if method == "mne" || method == "lcmv" || method == "eloreta" {
                        10000.0
                    } else {
                        1.0
                    };
            }
            roi_tc
        })
        .collect();

    let roi_labels: Vec<String> = model.rois.iter().map(|r| r.name.clone()).collect();
    eprintln!("PROGRESS 100 Source localization complete (atlas ROIs extracted).");

    Ok((roi_channels, roi_labels))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_source_space_amplitude() {
        let labels = vec![
            "Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8", "T3", "C3", "Cz", "C4", "T4", "T5", "P3",
            "Pz", "P4", "T6", "O1", "O2",
        ]
        .into_iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();

        let samples = 1000;
        let mut channels = Vec::new();
        for (i, _) in labels.iter().enumerate() {
            let ch = (0..samples)
                .map(|s| 50.0 * ((s as f64) * 0.1 + (i as f64)).sin())
                .collect();
            channels.push(ch);
        }

        let (rois, roi_labels) = convert_to_source_space(&channels, &labels, 3.0).unwrap();
        assert_eq!(rois.len(), 68);
        assert_eq!(roi_labels.len(), 68);

        let max_val = rois
            .iter()
            .flat_map(|ch| ch.iter())
            .cloned()
            .fold(0.0f64, |a, b| a.max(b.abs()));
        println!("MAX ROI AMPLITUDE: {}", max_val);
    }

    #[test]
    fn xpikan_inverse_localizes_synthetic_dipole_cleanly() {
        // 16 sensors on unit sphere, 12 synthetic orthogonal-ish dipole columns
        let m = 16_usize;
        let n_dip = 12_usize;
        let coords: Vec<[f64; 3]> = (0..m)
            .map(|i| {
                let phi = 2.0 * std::f64::consts::PI * (i as f64 / m as f64);
                let z = ((i % 4) as f64 - 1.5) * 0.45;
                let r_xy = (1.0 - z * z).max(0.1).sqrt();
                [r_xy * phi.cos(), r_xy * phi.sin(), z]
            })
            .collect();
        let dip_pos: Vec<[f64; 3]> = (0..n_dip)
            .map(|d| {
                let phi = 2.0 * std::f64::consts::PI * (d as f64 / n_dip as f64);
                [0.65 * phi.cos(), 0.65 * phi.sin(), if d % 2 == 0 { 0.35 } else { -0.35 }]
            })
            .collect();
        let l = DMatrix::from_fn(m, n_dip, |r, c| {
            let dx = coords[r][0] - dip_pos[c][0];
            let dy = coords[r][1] - dip_pos[c][1];
            let dz = coords[r][2] - dip_pos[c][2];
            let d2 = (dx * dx + dy * dy + dz * dz).max(0.05);
            (coords[r][0] * dip_pos[c][0] + coords[r][1] * dip_pos[c][1] + coords[r][2] * dip_pos[c][2])
                / (d2 * d2.sqrt())
        });

        let target_dip = 4_usize;
        let n_samp = 120_usize;
        let data = DMatrix::from_fn(m, n_samp, |r, t| {
            let s = (2.0 * std::f64::consts::PI * 10.0 * t as f64 / 200.0).sin();
            l[(r, target_dip)] * 10.0 * s
        });

        let w = inverse_operator_with_coords(&l, &data, 5.0, "xpikan", Some(&coords)).unwrap();
        assert_eq!(w.nrows(), n_dip);
        assert_eq!(w.ncols(), m);
        assert!(w.iter().all(|v| v.is_finite()));

        let s_est = &w * &data;
        let powers: Vec<f64> = (0..n_dip).map(|d| s_est.row(d).norm_squared()).collect();
        let peak_dip = powers
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.total_cmp(b.1))
            .unwrap()
            .0;
        assert_eq!(
            peak_dip, target_dip,
            "XPIKAN localized peak dipole to {peak_dip} instead of {target_dip}: powers={powers:?}"
        );

        let eeg: Vec<Vec<f64>> = (0..m).map(|r| data.row(r).iter().copied().collect()).collect();
        let labels: Vec<String> = vec![
            "Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8", "C3", "Cz", "C4", "P3", "Pz", "P4", "T7", "O1", "O2",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        let (rois, roi_labels) = convert_with_model(&eeg, &labels, 3.0, "xpikan", "").unwrap();
        assert_eq!(rois.len(), 68);
        assert_eq!(roi_labels.len(), 68);
        assert!(rois.iter().flat_map(|c| c.iter()).all(|v| v.is_finite()));
    }

    #[test]
    fn eloreta_inverse_localizes_synthetic_dipole_cleanly() {
        let m = 16_usize;
        let n_dip = 12_usize;
        let coords: Vec<[f64; 3]> = (0..m)
            .map(|i| {
                let phi = 2.0 * std::f64::consts::PI * (i as f64 / m as f64);
                let z = ((i % 4) as f64 - 1.5) * 0.45;
                let r_xy = (1.0 - z * z).max(0.1).sqrt();
                [r_xy * phi.cos(), r_xy * phi.sin(), z]
            })
            .collect();
        let dip_pos: Vec<[f64; 3]> = (0..n_dip)
            .map(|d| {
                let phi = 2.0 * std::f64::consts::PI * (d as f64 / n_dip as f64);
                [0.65 * phi.cos(), 0.65 * phi.sin(), if d % 2 == 0 { 0.35 } else { -0.35 }]
            })
            .collect();
        let l = DMatrix::from_fn(m, n_dip, |r, c| {
            let dx = coords[r][0] - dip_pos[c][0];
            let dy = coords[r][1] - dip_pos[c][1];
            let dz = coords[r][2] - dip_pos[c][2];
            let d2 = (dx * dx + dy * dy + dz * dz).max(0.05);
            (coords[r][0] * dip_pos[c][0] + coords[r][1] * dip_pos[c][1] + coords[r][2] * dip_pos[c][2])
                / (d2 * d2.sqrt())
        });
        let target_dip = 4_usize;
        let n_samp = 80_usize;
        let data = DMatrix::from_fn(m, n_samp, |r, t| {
            let s = (2.0 * std::f64::consts::PI * 10.0 * t as f64 / 200.0).sin();
            l[(r, target_dip)] * 10.0 * s
        });
        // Verify zero-localization-error property across every single synthetic dipole
        let w = inverse_operator_with_coords(&l, &data, 5.0, "eloreta", Some(&coords)).unwrap();
        assert_eq!(w.nrows(), n_dip);
        assert_eq!(w.ncols(), m);
        assert!(w.iter().all(|v| v.is_finite()));
        for d_true in 0..n_dip {
            let d_sig = DMatrix::from_fn(m, 16, |r, t| {
                let s = (2.0 * std::f64::consts::PI * 10.0 * t as f64 / 200.0).sin();
                l[(r, d_true)] * 10.0 * s
            });
            let s_est = &w * &d_sig;
            let powers: Vec<f64> = (0..n_dip).map(|d| s_est.row(d).norm_squared()).collect();
            let peak_dip = powers
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.total_cmp(b.1))
                .unwrap()
                .0;
            assert_eq!(peak_dip, d_true, "eLORETA dipole {d_true} localized to {peak_dip}");
        }

        let eeg: Vec<Vec<f64>> = (0..m).map(|r| data.row(r).iter().copied().collect()).collect();
        let labels: Vec<String> = vec![
            "Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8", "C3", "Cz", "C4", "P3", "Pz", "P4", "T7", "O1", "O2",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        let (rois, roi_labels) = convert_with_model(&eeg, &labels, 3.0, "eloreta", "").unwrap();
        assert_eq!(rois.len(), 68);
        assert_eq!(roi_labels.len(), 68);
        assert!(rois.iter().flat_map(|c| c.iter()).all(|v| v.is_finite()));
    }
}
