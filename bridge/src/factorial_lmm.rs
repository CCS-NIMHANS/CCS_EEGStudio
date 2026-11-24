//! Native REML Random-Intercept MixedLM & OLS GLM engine with fitted-design
//! contrasts (Benjamini-Hochberg FDR / Bonferroni), matching `statsmodels`.

use nalgebra::{DMatrix, DVector};
use serde::{Deserialize, Serialize};
use statrs::distribution::{ChiSquared, ContinuousCDF, FisherSnedecor, Normal, StudentsT};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;

#[derive(Deserialize)]
pub struct FactorialLmmJob {
    #[serde(default)]
    pub headers: Vec<String>,
    #[serde(default)]
    pub rows: Vec<Vec<String>>,
    #[serde(default)]
    pub factors: Vec<String>,
    #[serde(default)]
    pub metrics: Vec<String>,
    #[serde(rename = "subjectCol", alias = "subject_col", default)]
    pub subject_col: Option<String>,
    #[serde(rename = "excludedLevels", alias = "excluded_levels", default)]
    pub excluded_levels: HashMap<String, Vec<String>>,
    #[serde(rename = "customLevelOrder", alias = "custom_level_order", default)]
    pub custom_level_order: HashMap<String, Vec<String>>,
    #[serde(rename = "contrastFactors", alias = "contrast_factors", default)]
    pub contrast_factors: Vec<String>,
    #[serde(rename = "includeInteractions", alias = "include_interactions")]
    pub include_interactions: Option<bool>,
    #[serde(rename = "posthocMethod", alias = "posthoc_method")]
    pub posthoc_method: Option<String>,
    #[serde(rename = "preferredModel", alias = "preferred_model")]
    pub preferred_model: Option<String>,
    #[serde(alias = "outputPath", alias = "output_path", default)]
    pub output_path: Option<String>,
}

#[derive(Serialize)]
pub struct ModelEffect {
    pub term: String,
    pub f_stat: f64,
    pub p_value: f64,
    pub p_perm: Option<f64>,
    pub df_num: f64,
    pub df_denom: Option<f64>,
    pub eta_sq: Option<f64>,
}

#[derive(Serialize)]
pub struct ContrastResult {
    pub factor: String,
    pub group_a: String,
    pub group_b: String,
    pub stratum: BTreeMap<String, String>,
    pub contrast_scope: &'static str,
    pub test: &'static str,
    pub mean_diff: f64,
    pub standard_error: f64,
    pub t_stat: f64,
    pub df: Option<f64>,
    pub p_raw: f64,
    pub p_adj: f64,
    pub significant: bool,
}

#[derive(Serialize)]
pub struct CellDescriptives {
    pub values: Vec<f64>,
    pub subjects: Vec<String>,
}

#[derive(Serialize)]
pub struct MetricModelResult {
    pub metric: String,
    pub backend: &'static str,
    pub formula: String,
    pub inference_note: &'static str,
    pub model_type: &'static str,
    pub test_statistic: &'static str,
    pub factors: Vec<String>,
    pub factor_levels: BTreeMap<String, Vec<String>>,
    pub model_effects: Vec<ModelEffect>,
    pub posthoc: Vec<ContrastResult>,
    pub cell_descriptives: BTreeMap<String, CellDescriptives>,
    pub n_obs: usize,
    pub n_subjects: usize,
    pub warnings: Vec<String>,
    pub posthoc_family: String,
    pub mean_difference_direction: &'static str,
}

#[derive(Serialize)]
pub struct FactorialLmmOutput {
    pub results: Vec<MetricModelResult>,
    pub factors: Vec<String>,
}

struct ObsRow {
    sid: String,
    level_idx: Vec<usize>,
    y: f64,
}

struct TermCols {
    label: String,
    cols: Vec<usize>,
}

pub fn run_factorial_lmm(job: &FactorialLmmJob) -> Result<FactorialLmmOutput, String> {
    let posthoc_method = job.posthoc_method.as_deref().unwrap_or("fdr");
    if posthoc_method != "fdr" && posthoc_method != "bonferroni" {
        return Err(
            "N-factor fitted contrasts support FDR or Bonferroni; choose one of these corrections."
                .into(),
        );
    }
    if job.factors.is_empty() {
        return Err("Select at least one statistical factor.".into());
    }

    let col_map: HashMap<&str, usize> = job
        .headers
        .iter()
        .enumerate()
        .map(|(i, h)| (h.as_str(), i))
        .collect();

    let mut factor_cols = Vec::with_capacity(job.factors.len());
    for f in &job.factors {
        let &idx = col_map
            .get(f.as_str())
            .ok_or_else(|| format!("Factor column '{f}' not found in dataset headers."))?;
        factor_cols.push(idx);
    }
    let subj_idx = match job.subject_col.as_deref() {
        Some(sc) if !sc.is_empty() => Some(
            *col_map
                .get(sc)
                .ok_or_else(|| format!("Subject column '{sc}' not found in dataset headers."))?,
        ),
        _ => None,
    };

    let excluded_sets: Vec<BTreeSet<String>> = job
        .factors
        .iter()
        .map(|f| {
            job.excluded_levels
                .get(f)
                .map(|v| v.iter().cloned().collect())
                .unwrap_or_default()
        })
        .collect();

    let include_interactions = job.include_interactions.unwrap_or(true);
    let preferred = job.preferred_model.as_deref().unwrap_or("auto");
    let mut results = Vec::new();

    for metric in &job.metrics {
        let &metric_idx = col_map
            .get(metric.as_str())
            .ok_or_else(|| format!("Metric column '{metric}' not found in dataset headers."))?;

        if let Some(res) = analyse_metric(
            job,
            metric,
            metric_idx,
            &factor_cols,
            &excluded_sets,
            subj_idx,
            include_interactions,
            preferred,
            posthoc_method,
        )? {
            results.push(res);
        }
    }

    let output = FactorialLmmOutput {
        results,
        factors: job.factors.clone(),
    };

    if let Some(out_path) = job.output_path.as_deref() {
        let json = serde_json::to_string(&output).map_err(|e| e.to_string())?;
        fs::write(out_path, json).map_err(|e| format!("Failed writing {out_path}: {e}"))?;
    }

    Ok(output)
}

#[allow(clippy::too_many_arguments)]
fn analyse_metric(
    job: &FactorialLmmJob,
    metric: &str,
    metric_idx: usize,
    factor_cols: &[usize],
    excluded_sets: &[BTreeSet<String>],
    subj_idx: Option<usize>,
    include_interactions: bool,
    preferred: &str,
    posthoc_method: &str,
) -> Result<Option<MetricModelResult>, String> {
    let factors = &job.factors;
    let k = factors.len();

    // Aggregate participant-cell means: key = (sid, factor_vals) -> (sum, count)
    let mut cell_agg: BTreeMap<(String, Vec<String>), (f64, usize)> = BTreeMap::new();

    for (row_idx, row) in job.rows.iter().enumerate() {
        let Some(raw_y) = row.get(metric_idx) else {
            continue;
        };
        let Ok(y) = raw_y.trim().parse::<f64>() else {
            continue;
        };
        if !y.is_finite() {
            continue;
        }

        let mut fvals = Vec::with_capacity(k);
        let mut keep = true;
        for fi in 0..k {
            let val = row
                .get(factor_cols[fi])
                .map(|s| s.as_str())
                .unwrap_or("");
            if val.is_empty() || excluded_sets[fi].contains(val) {
                keep = false;
                break;
            }
            fvals.push(val.to_string());
        }
        if !keep {
            continue;
        }

        let sid = if let Some(sidx) = subj_idx {
            let s = row.get(sidx).map(|v| v.as_str()).unwrap_or("");
            if s.is_empty() {
                return Err("Participant IDs are missing; assign IDs before modelling.".into());
            }
            s.to_string()
        } else {
            format!("row{row_idx}")
        };

        let entry = cell_agg.entry((sid, fvals)).or_insert((0.0, 0));
        entry.0 += y;
        entry.1 += 1;
    }

    if cell_agg.len() < 3 {
        return Ok(None);
    }

    let mut level_sets: Vec<BTreeSet<String>> = vec![BTreeSet::new(); k];
    for (_, fvals) in cell_agg.keys() {
        for fi in 0..k {
            level_sets[fi].insert(fvals[fi].clone());
        }
    }
    let levels: Vec<Vec<String>> = level_sets
        .into_iter()
        .enumerate()
        .map(|(fi, mut available)| {
            let mut ordered = Vec::with_capacity(available.len());
            if let Some(custom) = job.custom_level_order.get(&factors[fi]) {
                for lv in custom {
                    if available.remove(lv) {
                        ordered.push(lv.clone());
                    }
                }
            }
            ordered.extend(available);
            ordered
        })
        .collect();
    if levels.iter().any(|lv| lv.len() < 2) {
        return Err(
            "Every model factor must have at least two included levels. Remove constant factors (including Condition for a single ERP difference)."
                .into(),
        );
    }

    let level_idx_maps: Vec<HashMap<String, usize>> = levels
        .iter()
        .map(|lv| {
            lv.iter()
                .enumerate()
                .map(|(idx, s)| (s.clone(), idx))
                .collect()
        })
        .collect();

    let mut data: Vec<ObsRow> = Vec::with_capacity(cell_agg.len());
    let mut sid_counts: HashMap<String, usize> = HashMap::new();
    for ((sid, fvals), (sum, cnt)) in &cell_agg {
        let lvl_idx: Vec<usize> = (0..k)
            .map(|fi| level_idx_maps[fi][&fvals[fi]])
            .collect();
        *sid_counts.entry(sid.clone()).or_insert(0) += 1;
        data.push(ObsRow {
            sid: sid.clone(),
            level_idx: lvl_idx,
            y: sum / (*cnt as f64),
        });
    }

    let n = data.len();
    let n_subjects = sid_counts.len();
    let repeated = sid_counts.values().any(|&c| c > 1);
    let mixed = preferred == "lmm" || (preferred == "auto" && repeated);
    if mixed && !repeated {
        return Err(
            "LMM requires repeated observations within participants. Choose GLM for independent participant values."
                .into(),
        );
    }

    // Enumerate patsy-equivalent terms (Intercept, then order-1, order-2, ..., order-k)
    let term_subsets = enumerate_term_subsets(k, include_interactions);
    let mut terms_cols: Vec<TermCols> = Vec::new();
    let mut term_specs: Vec<(String, Vec<usize>, Vec<Vec<usize>>)> = Vec::new();

    // Assign column indices matching sum-to-zero (effects/deviation) coding (level 0 is reference)
    let mut total_cols = 0usize;
    for subset in &term_subsets {
        let label = if subset.is_empty() {
            "Intercept".to_string()
        } else {
            subset
                .iter()
                .map(|&fi| factors[fi].as_str())
                .collect::<Vec<_>>()
                .join(":")
        };
        let non_ref_ranges: Vec<Vec<usize>> = subset
            .iter()
            .map(|&fi| (1..levels[fi].len()).collect())
            .collect();
        let combos = cartesian_product_usize(&non_ref_ranges);
        let n_term_cols = if subset.is_empty() { 1 } else { combos.len() };
        let cols: Vec<usize> = (total_cols..total_cols + n_term_cols).collect();
        total_cols += n_term_cols;
        terms_cols.push(TermCols {
            label: label.clone(),
            cols,
        });
        term_specs.push((label, subset.clone(), combos));
    }

    let p = total_cols;
    if n <= p {
        return Err(
            "Model design is rank deficient or saturated; reduce confounded factors or add independent participants."
                .into(),
        );
    }

    let encode_row = |lvl_idx: &[usize]| -> DVector<f64> {
        let mut v = Vec::with_capacity(p);
        for (_, subset, combos) in &term_specs {
            if subset.is_empty() {
                v.push(1.0);
            } else {
                for combo in combos {
                    let prod: f64 = subset
                        .iter()
                        .zip(combo.iter())
                        .map(|(&fi, &target_l)| {
                            if lvl_idx[fi] == target_l {
                                1.0
                            } else if lvl_idx[fi] == 0 {
                                -1.0
                            } else {
                                0.0
                            }
                        })
                        .product();
                    v.push(prod);
                }
            }
        }
        DVector::from_vec(v)
    };

    let mut x_data = vec![0.0; n * p];
    let mut y_data = vec![0.0; n];
    for (row_i, obs) in data.iter().enumerate() {
        let row_vec = encode_row(&obs.level_idx);
        for col_j in 0..p {
            x_data[col_j * n + row_i] = row_vec[col_j];
        }
        y_data[row_i] = obs.y;
    }
    let x_mat = DMatrix::from_column_slice(n, p, &x_data);
    let y_vec = DVector::from_vec(y_data);

    // Full-rank check matching numpy.linalg.matrix_rank
    let svd = x_mat.clone().svd(false, false);
    let s_max = svd.singular_values.iter().copied().fold(0.0_f64, f64::max);
    let rank_tol = (n.max(p) as f64) * f64::EPSILON * s_max;
    let rank = svd
        .singular_values
        .iter()
        .filter(|&&s| s > rank_tol)
        .count();
    if rank < p {
        return Err(
            "Model design is rank deficient or saturated; reduce confounded factors or add independent participants."
                .into(),
        );
    }

    // Group row indices by SID (sorted via BTreeMap for reproducibility)
    let mut groups_map: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
    for (i, obs) in data.iter().enumerate() {
        groups_map.entry(obs.sid.as_str()).or_default().push(i);
    }
    let groups: Vec<Vec<usize>> = groups_map.into_values().collect();

    let mut warnings_out: Vec<String> = Vec::new();
    let (beta, cov) = if mixed {
        fit_reml_random_intercept(&x_mat, &y_vec, &groups, &mut warnings_out)?
    } else if repeated {
        fit_ols_cluster(&x_mat, &y_vec, &groups)?
    } else {
        fit_ols_plain(&x_mat, &y_vec)?
    };

    // Validate covariance PSD
    if cov.iter().any(|v| !v.is_finite()) {
        return Err(
            "The fitted fixed-effect covariance is invalid; no contrasts are reported. Review model identifiability."
                .into(),
        );
    }
    let sym_cov = (&cov + cov.transpose()) * 0.5;
    let min_eig = sym_cov
        .clone()
        .symmetric_eigen()
        .eigenvalues
        .iter()
        .copied()
        .fold(f64::INFINITY, f64::min);
    if min_eig < -1e-9 {
        return Err(
            "The fitted fixed-effect covariance is invalid; no contrasts are reported. Review model identifiability."
                .into(),
        );
    }

    let use_normal = mixed || repeated;
    let df_resid = (n - p) as f64;

    // Omnibus Wald tests per term
    let mut effects = Vec::new();
    for term in &terms_cols {
        if term.label == "Intercept" || term.cols.is_empty() {
            continue;
        }
        let q = term.cols.len();
        let mut b_sub = DVector::zeros(q);
        let mut c_sub = DMatrix::zeros(q, q);
        for (a, &ca) in term.cols.iter().enumerate() {
            b_sub[a] = beta[ca];
            for (b, &cb) in term.cols.iter().enumerate() {
                c_sub[(a, b)] = sym_cov[(ca, cb)];
            }
        }
        let Some(chol) = c_sub.clone().cholesky() else {
            return Err(
                "The fitted fixed-effect covariance is singular for omnibus term testing."
                    .into(),
            );
        };
        let sol = chol.solve(&b_sub);
        let wald = b_sub.dot(&sol).max(0.0);

        let (stat, p_val, df_denom) = if use_normal {
            let chi = ChiSquared::new(q as f64).map_err(|e| e.to_string())?;
            (wald, chi.sf(wald).clamp(0.0, 1.0), None)
        } else {
            let f_stat = wald / (q as f64);
            let f_dist = FisherSnedecor::new(q as f64, df_resid).map_err(|e| e.to_string())?;
            (f_stat, f_dist.sf(f_stat).clamp(0.0, 1.0), Some(df_resid))
        };

        effects.push(ModelEffect {
            term: term.label.clone(),
            f_stat: stat,
            p_value: p_val,
            p_perm: None,
            df_num: q as f64,
            df_denom,
            eta_sq: None,
        });
    }

    // Marginal & simple-effect contrasts across all factors
    let reference_vec = |fi: usize, lvl_idx: usize, stratum: &[(usize, usize)]| -> DVector<f64> {
        let mut stratum_map = HashMap::new();
        for &(sf, sl) in stratum {
            stratum_map.insert(sf, sl);
        }
        let other_indices: Vec<usize> = (0..k).filter(|&o| o != fi).collect();
        let other_ranges: Vec<Vec<usize>> = other_indices
            .iter()
            .map(|&o| {
                if let Some(&sl) = stratum_map.get(&o) {
                    vec![sl]
                } else {
                    (0..levels[o].len()).collect()
                }
            })
            .collect();
        let grid_combos = cartesian_product_usize(&other_ranges);
        let mut acc = DVector::zeros(p);
        let mut row_lvl = vec![0usize; k];
        row_lvl[fi] = lvl_idx;
        let denom = grid_combos.len().max(1) as f64;
        for combo in &grid_combos {
            for (pos, &o) in other_indices.iter().enumerate() {
                row_lvl[o] = combo[pos];
            }
            acc += encode_row(&row_lvl);
        }
        acc / denom
    };

    let norm_dist = Normal::new(0.0, 1.0).map_err(|e| e.to_string())?;
    let t_dist = StudentsT::new(0.0, 1.0, df_resid).map_err(|e| e.to_string())?;

    let mut raw_contrasts: Vec<(
        usize,
        usize,
        usize,
        Vec<(usize, usize)>,
        f64,
        f64,
        f64,
        f64,
    )> = Vec::new();

    let active_contrast_factors: Vec<String> = factors
        .iter()
        .filter(|f| job.contrast_factors.is_empty() || job.contrast_factors.contains(*f))
        .cloned()
        .collect();

    for fi in 0..k {
        if !job.contrast_factors.is_empty() && !job.contrast_factors.contains(&factors[fi]) {
            continue;
        }
        let other: Vec<usize> = (0..k).filter(|&o| o != fi).collect();
        let mut strata: Vec<Vec<(usize, usize)>> = vec![Vec::new()];
        if !other.is_empty() {
            let ranges: Vec<Vec<usize>> = other.iter().map(|&o| (0..levels[o].len()).collect()).collect();
            for combo in cartesian_product_usize(&ranges) {
                strata.push(other.iter().copied().zip(combo).collect());
            }
        }

        for stratum in strata {
            for l1 in 0..levels[fi].len() {
                for l2 in (l1 + 1)..levels[fi].len() {
                    let mut sids_a: BTreeSet<&str> = BTreeSet::new();
                    let mut sids_b: BTreeSet<&str> = BTreeSet::new();
                    for obs in &data {
                        if stratum
                            .iter()
                            .all(|&(sf, sl)| obs.level_idx[sf] == sl)
                        {
                            if obs.level_idx[fi] == l1 {
                                sids_a.insert(obs.sid.as_str());
                            } else if obs.level_idx[fi] == l2 {
                                sids_b.insert(obs.sid.as_str());
                            }
                        }
                    }
                    if sids_a.len() < 2 || sids_b.len() < 2 {
                        continue;
                    }

                    let v = reference_vec(fi, l2, &stratum) - reference_vec(fi, l1, &stratum);
                    let estimate = v.dot(&beta);
                    let var = v.dot(&(&sym_cov * &v));
                    if !var.is_finite() || var <= 0.0 {
                        continue;
                    }
                    let se = var.sqrt();
                    let stat = estimate / se;
                    let p_raw = if use_normal {
                        2.0 * norm_dist.sf(stat.abs())
                    } else {
                        2.0 * t_dist.sf(stat.abs())
                    }
                    .clamp(0.0, 1.0);
                    raw_contrasts.push((fi, l1, l2, stratum.clone(), estimate, se, stat, p_raw));
                }
            }
        }
    }

    let p_raws: Vec<f64> = raw_contrasts.iter().map(|c| c.7).collect();
    let p_adjs = adjust_p_values(&p_raws, posthoc_method);

    let mut posthoc = Vec::with_capacity(raw_contrasts.len());
    for ((fi, l1, l2, stratum, estimate, se, stat, p_raw), p_adj) in
        raw_contrasts.into_iter().zip(p_adjs.into_iter())
    {
        let mut stratum_map = BTreeMap::new();
        for (sf, sl) in &stratum {
            stratum_map.insert(factors[*sf].clone(), levels[*sf][*sl].clone());
        }
        posthoc.push(ContrastResult {
            factor: factors[fi].clone(),
            group_a: levels[fi][l1].clone(),
            group_b: levels[fi][l2].clone(),
            contrast_scope: if stratum_map.is_empty() {
                "marginal"
            } else {
                "simple effect"
            },
            stratum: stratum_map,
            test: "fitted-model Wald contrast",
            mean_diff: estimate,
            standard_error: se,
            t_stat: stat,
            df: if use_normal { None } else { Some(df_resid) },
            p_raw,
            p_adj,
            significant: p_adj < 0.05,
        });
    }

    let mut cell_descriptives: BTreeMap<String, CellDescriptives> = BTreeMap::new();
    for obs in &data {
        let key = (0..k)
            .map(|fi| format!("{}={}", factors[fi], levels[fi][obs.level_idx[fi]]))
            .collect::<Vec<_>>()
            .join("|");
        let entry = cell_descriptives
            .entry(key)
            .or_insert_with(|| CellDescriptives {
                values: Vec::new(),
                subjects: Vec::new(),
            });
        entry.values.push(obs.y);
        entry.subjects.push(obs.sid.clone());
    }

    let mut factor_levels_map = BTreeMap::new();
    for (fi, f) in factors.iter().enumerate() {
        factor_levels_map.insert(f.clone(), levels[fi].clone());
    }

    let sep = if include_interactions { " * " } else { " + " };
    let formula = format!(
        "Y ~ {}",
        (0..k)
            .map(|i| format!("C(F{i})"))
            .collect::<Vec<_>>()
            .join(sep)
    );

    Ok(Some(MetricModelResult {
        metric: metric.to_string(),
        backend: "native_rust",
        formula,
        inference_note:
            "Random intercept only. MixedLM and cluster-covariance contrasts use asymptotic normal/Wald tests; no Satterthwaite degrees of freedom.",
        model_type: if mixed {
            "Random-intercept MixedLM (REML)"
        } else if repeated {
            "OLS GLM with participant-cluster covariance"
        } else {
            "OLS GLM"
        },
        test_statistic: if use_normal { "Wald χ²" } else { "F" },
        factors: factors.clone(),
        factor_levels: factor_levels_map,
        model_effects: effects,
        posthoc,
        cell_descriptives,
        n_obs: n,
        n_subjects,
        warnings: warnings_out,
        posthoc_family: if job.contrast_factors.is_empty() {
            "All marginal and simple-effect contrasts within this metric".to_string()
        } else {
            format!(
                "Marginal and simple-effect contrasts for {} within this metric",
                active_contrast_factors.join(", ")
            )
        },
        mean_difference_direction: "group_b minus group_a",
    }))
}

fn fit_ols_plain(x: &DMatrix<f64>, y: &DVector<f64>) -> Result<(DVector<f64>, DMatrix<f64>), String> {
    let n = x.nrows();
    let p = x.ncols();
    let xtx = x.transpose() * x;
    let chol = xtx
        .cholesky()
        .ok_or("OLS design normal equations are singular.")?;
    let xty = x.transpose() * y;
    let beta = chol.solve(&xty);
    let xtx_inv = chol.inverse();
    let resid = y - x * &beta;
    let sigma2 = resid.dot(&resid) / ((n - p) as f64);
    Ok((beta, xtx_inv * sigma2))
}

fn fit_ols_cluster(
    x: &DMatrix<f64>,
    y: &DVector<f64>,
    groups: &[Vec<usize>],
) -> Result<(DVector<f64>, DMatrix<f64>), String> {
    let n = x.nrows();
    let p = x.ncols();
    let g_count = groups.len();
    if g_count < 2 {
        return Err("Cluster-robust OLS requires at least two participants.".into());
    }
    let xtx = x.transpose() * x;
    let chol = xtx
        .cholesky()
        .ok_or("OLS design normal equations are singular.")?;
    let xty = x.transpose() * y;
    let beta = chol.solve(&xty);
    let xtx_inv = chol.inverse();
    let resid = y - x * &beta;

    let mut meat = DMatrix::<f64>::zeros(p, p);
    for idxs in groups {
        let mut score = DVector::<f64>::zeros(p);
        for &row_i in idxs {
            let ri = resid[row_i];
            for col_j in 0..p {
                score[col_j] += x[(row_i, col_j)] * ri;
            }
        }
        meat += &score * score.transpose();
    }
    let g = g_count as f64;
    let nf = n as f64;
    let pf = p as f64;
    let scale = (g / (g - 1.0)) * ((nf - 1.0) / (nf - pf));
    let cov = &xtx_inv * meat * &xtx_inv * scale;
    Ok((beta, cov))
}

struct GroupSufficientStats {
    rows: Vec<usize>,
    n_g: f64,
    xtx_g: DMatrix<f64>,
    xty_g: DVector<f64>,
    sx_g: DVector<f64>,
    sy_g: f64,
}

fn fit_reml_random_intercept(
    x: &DMatrix<f64>,
    y: &DVector<f64>,
    groups: &[Vec<usize>],
    warnings: &mut Vec<String>,
) -> Result<(DVector<f64>, DMatrix<f64>), String> {
    let n = x.nrows();
    let p = x.ncols();
    let df_reml = (n - p) as f64;

    let mut g_stats = Vec::with_capacity(groups.len());
    for idxs in groups {
        let m = idxs.len();
        let mut xtx_g = DMatrix::zeros(p, p);
        let mut xty_g = DVector::zeros(p);
        let mut sx_g = DVector::zeros(p);
        let mut sy_g = 0.0;
        for &r in idxs {
            let yi = y[r];
            sy_g += yi;
            for c1 in 0..p {
                let x1 = x[(r, c1)];
                sx_g[c1] += x1;
                xty_g[c1] += x1 * yi;
                for c2 in c1..p {
                    let prod = x1 * x[(r, c2)];
                    xtx_g[(c1, c2)] += prod;
                    if c2 != c1 {
                        xtx_g[(c2, c1)] += prod;
                    }
                }
            }
        }
        g_stats.push(GroupSufficientStats {
            rows: idxs.clone(),
            n_g: m as f64,
            xtx_g,
            xty_g,
            sx_g,
            sy_g,
        });
    }

    let eval_reml = |tau: f64| -> Option<(f64, DVector<f64>, DMatrix<f64>, f64)> {
        if !tau.is_finite() || tau < 0.0 {
            return None;
        }
        let mut a_mat = DMatrix::zeros(p, p);
        let mut b_vec = DVector::zeros(p);
        let mut log_det_v = 0.0;

        for gs in &g_stats {
            let denom = 1.0 + gs.n_g * tau;
            if denom <= 0.0 {
                return None;
            }
            let wg = tau / denom;
            log_det_v += denom.ln();
            a_mat += &gs.xtx_g - (&gs.sx_g * gs.sx_g.transpose()) * wg;
            b_vec += &gs.xty_g - &gs.sx_g * (wg * gs.sy_g);
        }

        let chol = a_mat.cholesky()?;
        let beta = chol.solve(&b_vec);
        let l_mat = chol.l();
        let log_det_a = 2.0 * (0..p).map(|i| l_mat[(i, i)].ln()).sum::<f64>();

        let mut q_rss = 0.0;
        for gs in &g_stats {
            let wg = tau / (1.0 + gs.n_g * tau);
            let mut sum_r = 0.0;
            let mut sum_r2 = 0.0;
            for &row_i in &gs.rows {
                let mut xb = 0.0;
                for col_j in 0..p {
                    xb += x[(row_i, col_j)] * beta[col_j];
                }
                let r = y[row_i] - xb;
                sum_r += r;
                sum_r2 += r * r;
            }
            q_rss += (sum_r2 - wg * sum_r * sum_r).max(0.0);
        }

        let sigma_e2 = (q_rss / df_reml).max(1e-30);
        let obj = 0.5 * (log_det_v + log_det_a + df_reml * sigma_e2.ln());
        if !obj.is_finite() {
            return None;
        }
        Some((obj, beta, chol.inverse(), sigma_e2))
    };

    // Global 1D log-grid scan plus boundary tau = 0
    let mut best_k: Option<usize> = None;
    let mut best_grid_val = f64::INFINITY;
    let n_grid = 140usize;
    let log_lo = -8.0_f64;
    let log_hi = 6.0_f64;
    for k_i in 0..=n_grid {
        let log_t = log_lo + (k_i as f64) * ((log_hi - log_lo) / (n_grid as f64));
        let tau = 10.0_f64.powf(log_t);
        if let Some((obj, _, _, _)) = eval_reml(tau) {
            if obj < best_grid_val {
                best_grid_val = obj;
                best_k = Some(k_i);
            }
        }
    }

    let mut best_fit = eval_reml(0.0);
    if let Some(bk) = best_k {
        let mut lo = if bk == 0 {
            -12.0
        } else {
            log_lo + ((bk - 1) as f64) * ((log_hi - log_lo) / (n_grid as f64))
        };
        let mut hi = if bk == n_grid {
            9.0
        } else {
            log_lo + ((bk + 1) as f64) * ((log_hi - log_lo) / (n_grid as f64))
        };

        let gr = (5.0_f64.sqrt() - 1.0) / 2.0;
        let mut c = hi - gr * (hi - lo);
        let mut d = lo + gr * (hi - lo);
        let mut fc = eval_reml(10.0_f64.powf(c))
            .map(|r| r.0)
            .unwrap_or(f64::INFINITY);
        let mut fd = eval_reml(10.0_f64.powf(d))
            .map(|r| r.0)
            .unwrap_or(f64::INFINITY);

        for _ in 0..85 {
            if (hi - lo).abs() < 1e-11 {
                break;
            }
            if fc < fd {
                hi = d;
                d = c;
                fd = fc;
                c = hi - gr * (hi - lo);
                fc = eval_reml(10.0_f64.powf(c))
                    .map(|r| r.0)
                    .unwrap_or(f64::INFINITY);
            } else {
                lo = c;
                c = d;
                fc = fd;
                d = lo + gr * (hi - lo);
                fd = eval_reml(10.0_f64.powf(d))
                    .map(|r| r.0)
                    .unwrap_or(f64::INFINITY);
            }
        }

        let opt_tau = 10.0_f64.powf(0.5 * (lo + hi));
        if let Some(opt_res) = eval_reml(opt_tau) {
            match &best_fit {
                Some(zero_res) => {
                    if opt_res.0 < zero_res.0 && opt_tau >= 1e-8 {
                        best_fit = Some(opt_res);
                    } else {
                        warnings.push(
                            "MixedLM random-intercept variance converged near the boundary (0.0)."
                                .into(),
                        );
                    }
                }
                None => best_fit = Some(opt_res),
            }
        }
    }

    let (_, beta, a_inv, sigma_e2) = best_fit.ok_or(
        "MixedLM did not converge. No significance is reported; review model balance, factor structure and participant counts.",
    )?;

    Ok((beta, a_inv * sigma_e2))
}

fn enumerate_term_subsets(k: usize, include_interactions: bool) -> Vec<Vec<usize>> {
    let mut out = vec![Vec::new()];
    let max_order = if include_interactions { k } else { 1 };
    for order in 1..=max_order {
        let mut cur = Vec::with_capacity(order);
        fn rec(start: usize, k: usize, order: usize, cur: &mut Vec<usize>, out: &mut Vec<Vec<usize>>) {
            if cur.len() == order {
                out.push(cur.clone());
                return;
            }
            for i in start..k {
                cur.push(i);
                rec(i + 1, k, order, cur, out);
                cur.pop();
            }
        }
        rec(0, k, order, &mut cur, &mut out);
    }
    out
}

fn cartesian_product_usize(ranges: &[Vec<usize>]) -> Vec<Vec<usize>> {
    let mut out = vec![Vec::new()];
    for r in ranges {
        let mut next = Vec::with_capacity(out.len() * r.len().max(1));
        for prefix in &out {
            for &v in r {
                let mut item = prefix.clone();
                item.push(v);
                next.push(item);
            }
        }
        out = next;
    }
    out
}

fn adjust_p_values(p_raw: &[f64], method: &str) -> Vec<f64> {
    let m = p_raw.len();
    if m == 0 {
        return Vec::new();
    }
    if method == "bonferroni" {
        return p_raw.iter().map(|&p| (p * (m as f64)).clamp(0.0, 1.0)).collect();
    }
    // Benjamini-Hochberg FDR step-up
    let mut order: Vec<usize> = (0..m).collect();
    order.sort_by(|&a, &b| p_raw[a].total_cmp(&p_raw[b]));
    let mut adj_sorted = vec![0.0_f64; m];
    let mut min_so_far = 1.0_f64;
    for rank_rev in (0..m).rev() {
        let idx = order[rank_rev];
        let scaled = p_raw[idx] * (m as f64) / ((rank_rev + 1) as f64);
        min_so_far = min_so_far.min(scaled).clamp(0.0, 1.0);
        adj_sorted[rank_rev] = min_so_far;
    }
    let mut out = vec![0.0_f64; m];
    for (pos, &orig_idx) in order.iter().enumerate() {
        out[orig_idx] = adj_sorted[pos];
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fits_ols_glm_between_subjects() {
        let headers = vec!["subject".into(), "group".into(), "val".into()];
        let mut rows = Vec::new();
        let ctrl_vals = [1.0, 1.2, 0.8, 1.1, 0.9, 1.3, 0.7, 1.0];
        let trt_vals = [3.1, 2.9, 3.2, 2.8, 3.0, 3.3, 2.7, 3.0];
        for (i, v) in ctrl_vals.iter().enumerate() {
            rows.push(vec![format!("C{i}"), "CON".into(), format!("{v}")]);
        }
        for (i, v) in trt_vals.iter().enumerate() {
            rows.push(vec![format!("T{i}"), "TRT".into(), format!("{v}")]);
        }

        let job = FactorialLmmJob {
            headers,
            rows,
            factors: vec!["group".into()],
            metrics: vec!["val".into()],
            subject_col: Some("subject".into()),
            excluded_levels: HashMap::new(),
            custom_level_order: HashMap::new(),
            contrast_factors: Vec::new(),
            include_interactions: Some(true),
            posthoc_method: Some("fdr".into()),
            preferred_model: Some("auto".into()),
            output_path: None,
        };

        let out = run_factorial_lmm(&job).expect("OLS GLM should succeed");
        assert_eq!(out.results.len(), 1);
        let r = &out.results[0];
        assert_eq!(r.model_type, "OLS GLM");
        assert_eq!(r.n_obs, 16);
        assert_eq!(r.n_subjects, 16);
        assert_eq!(r.model_effects.len(), 1);
        assert!(r.model_effects[0].p_value < 1e-8);
        assert_eq!(r.posthoc.len(), 1);
        assert!((r.posthoc[0].mean_diff - 2.0).abs() < 1e-6);
        assert!(r.posthoc[0].significant);
    }

    #[test]
    fn fits_reml_mixedlm_repeated_measures() {
        let headers = vec!["sid".into(), "group".into(), "cond".into(), "y".into()];
        let mut rows = Vec::new();
        // 10 CON, 10 ADV across 2 conditions with subject random intercept & Condition effect +2
        for i in 0..20 {
            let grp = if i < 10 { "CON" } else { "ADV" };
            let re = ((i % 5) as f64 - 2.0) * 1.5;
            let noise = if i % 2 == 0 { 0.1 } else { -0.1 };
            let grp_eff = if grp == "ADV" { 1.5 } else { 0.0 };
            rows.push(vec![
                format!("S{i:02}"),
                grp.into(),
                "Freq".into(),
                format!("{}", 1.0 + grp_eff + re + noise),
            ]);
            rows.push(vec![
                format!("S{i:02}"),
                grp.into(),
                "Rare".into(),
                format!("{}", 3.0 + grp_eff + re - noise),
            ]);
        }

        let job = FactorialLmmJob {
            headers,
            rows,
            factors: vec!["group".into(), "cond".into()],
            metrics: vec!["y".into()],
            subject_col: Some("sid".into()),
            excluded_levels: HashMap::new(),
            custom_level_order: HashMap::new(),
            contrast_factors: Vec::new(),
            include_interactions: Some(true),
            posthoc_method: Some("fdr".into()),
            preferred_model: Some("auto".into()),
            output_path: None,
        };

        let out = run_factorial_lmm(&job).expect("REML MixedLM should succeed");
        let r = &out.results[0];
        assert_eq!(r.model_type, "Random-intercept MixedLM (REML)");
        assert_eq!(r.test_statistic, "Wald χ²");
        assert_eq!(r.n_obs, 40);
        assert_eq!(r.n_subjects, 20);
        let cond_eff = r
            .model_effects
            .iter()
            .find(|e| e.term == "cond")
            .expect("cond effect");
        assert!(cond_eff.p_value < 1e-6);
        let marg_cond = r
            .posthoc
            .iter()
            .find(|c| c.factor == "cond" && c.stratum.is_empty())
            .expect("marginal cond contrast");
        assert!((marg_cond.mean_diff - 2.0).abs() < 1e-4);
    }

    #[test]
    fn respects_custom_level_order_and_type3_invariance() {
        let headers = vec!["sid".into(), "group".into(), "Session".into(), "y".into()];
        let groups = ["ADV", "CON", "INT", "NOV"];
        let mut rows = Vec::new();
        for (gi, &grp) in groups.iter().enumerate() {
            for si in 0..8 {
                let sid = format!("{grp}_{si:02}");
                let re = ((si % 4) as f64 - 1.5) * 0.4;
                let noise = if si % 2 == 0 { 0.08 } else { -0.08 };
                let (v03, v05) = if grp == "CON" {
                    (3.0 + re + noise, 0.5 + re - noise)
                } else {
                    let base = 1.0 + (gi as f64) * 0.1;
                    (base + re + noise, base + re - noise)
                };
                rows.push(vec![sid.clone(), grp.into(), "03".into(), format!("{v03}")]);
                rows.push(vec![sid, grp.into(), "05".into(), format!("{v05}")]);
            }
        }

        let mut order_adv_first = HashMap::new();
        order_adv_first.insert(
            "group".into(),
            vec!["ADV".into(), "CON".into(), "INT".into(), "NOV".into()],
        );
        let mut order_con_first = HashMap::new();
        order_con_first.insert(
            "group".into(),
            vec!["CON".into(), "NOV".into(), "INT".into(), "ADV".into()],
        );

        let make_job = |order| FactorialLmmJob {
            headers: headers.clone(),
            rows: rows.clone(),
            factors: vec!["group".into(), "Session".into()],
            metrics: vec!["y".into()],
            subject_col: Some("sid".into()),
            excluded_levels: HashMap::new(),
            custom_level_order: order,
            contrast_factors: Vec::new(),
            include_interactions: Some(true),
            posthoc_method: Some("fdr".into()),
            preferred_model: Some("auto".into()),
            output_path: None,
        };

        let out1 = run_factorial_lmm(&make_job(order_adv_first)).expect("run 1");
        let out2 = run_factorial_lmm(&make_job(order_con_first)).expect("run 2");
        let r1 = &out1.results[0];
        let r2 = &out2.results[0];

        assert_eq!(
            r2.factor_levels.get("group").expect("group levels"),
            &vec!["CON", "NOV", "INT", "ADV"]
        );

        let eff1 = r1
            .model_effects
            .iter()
            .find(|e| e.term == "Session")
            .expect("Session effect 1");
        let eff2 = r2
            .model_effects
            .iter()
            .find(|e| e.term == "Session")
            .expect("Session effect 2");
        assert!(
            (eff1.f_stat - eff2.f_stat).abs() <= 1e-5 * eff1.f_stat.max(1.0),
            "eff1=({}, p={}) eff2=({}, p={})",
            eff1.f_stat,
            eff1.p_value,
            eff2.f_stat,
            eff2.p_value
        );
        assert!((eff1.p_value - eff2.p_value).abs() < 1e-6);
        assert!(eff1.p_value < 0.01);
    }

    #[test]
    fn respects_contrast_factors_scope() {
        let headers = vec!["sid".into(), "group".into(), "cond".into(), "y".into()];
        let mut rows = Vec::new();
        for i in 0..20 {
            let grp = if i < 10 { "CON" } else { "ADV" };
            let re = ((i % 5) as f64 - 2.0) * 0.5;
            let noise = if i % 2 == 0 { 0.1 } else { -0.1 };
            let grp_eff = if grp == "ADV" { 2.0 } else { 0.0 };
            rows.push(vec![
                format!("S{i:02}"),
                grp.into(),
                "Freq".into(),
                format!("{}", 1.0 + grp_eff + re + noise),
            ]);
            rows.push(vec![
                format!("S{i:02}"),
                grp.into(),
                "Rare".into(),
                format!("{}", 3.0 + grp_eff + re - noise),
            ]);
        }

        let job = FactorialLmmJob {
            headers,
            rows,
            factors: vec!["group".into(), "cond".into()],
            metrics: vec!["y".into()],
            subject_col: Some("sid".into()),
            excluded_levels: HashMap::new(),
            custom_level_order: HashMap::new(),
            contrast_factors: vec!["group".into()],
            include_interactions: Some(true),
            posthoc_method: Some("fdr".into()),
            preferred_model: Some("auto".into()),
            output_path: None,
        };

        let out = run_factorial_lmm(&job).expect("contrast scope job should succeed");
        let r = &out.results[0];
        assert!(r.model_effects.iter().any(|e| e.term == "cond"));
        assert!(r.model_effects.iter().any(|e| e.term == "group:cond"));
        assert!(!r.posthoc.is_empty());
        assert!(r.posthoc.iter().all(|c| c.factor == "group"));
        assert!(r.posthoc_family.contains("group"));
    }
}
