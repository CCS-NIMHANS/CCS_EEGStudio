//! CCS EEG Studio Bridge Engine
//! Uses `ccs_algorithm` SDK crate as core extraction & preprocessing backend.

pub use ccs_algorithm::eeg::*;
pub use ccs_algorithm::{cardiac, coupled, sqi};

pub mod fieldtrip_loader;
mod mat_v5;
pub mod microstates;
pub mod mne_fif;
pub mod stats;
pub mod xdf_loader;

pub mod erp_math;
pub mod erp_workbench;
pub mod ersp_itc;
pub mod speech_tracking;

pub mod recording_metadata;

pub mod microstate_syntax;
pub mod state_dynamics;

/// Loads an EDF/EDF+ recording directly into float microvolt channels.
pub fn load_edf(path: &std::path::Path) -> Result<Recording, String> {
    let err = |e: Box<dyn std::fmt::Display>| e.to_string();
    let b = std::fs::read(path).map_err(|e| e.to_string())?;
    if b.len() < 256 {
        return Err("EDF header too short".into());
    }
    let text = |o: usize, n: usize| String::from_utf8_lossy(&b[o..o + n]).trim().to_string();
    let hb: usize = text(184, 8).parse().map_err(|e| err(Box::new(e)))?;
    let records: i32 = text(236, 8).parse().unwrap_or(-1);
    let secs: f64 = text(244, 8).replace(',', ".").parse().map_err(|e| err(Box::new(e)))?;
    let ns: usize = text(252, 4).parse().map_err(|e| err(Box::new(e)))?;
    let mut o = 256;
    let fields = |o: usize, w: usize| -> Vec<String> {
        (0..ns)
            .map(|i| {
                String::from_utf8_lossy(&b[o + i * w..o + (i + 1) * w])
                    .trim()
                    .to_string()
            })
            .collect()
    };
    let labels = fields(o, 16);
    o += ns * 16;
    o += ns * 80;
    let dims = fields(o, 8);
    o += ns * 8;
    let nums = |o: usize| -> Vec<f64> {
        fields(o, 8)
            .iter()
            .map(|x| x.replace(',', ".").parse().unwrap_or(0.0))
            .collect()
    };
    let pmin = nums(o);
    o += ns * 8;
    let pmax = nums(o);
    o += ns * 8;
    let dmin = nums(o);
    o += ns * 8;
    let dmax = nums(o);
    o += ns * 8;
    o += ns * 80;
    let spr: Vec<usize> = fields(o, 8)
        .iter()
        .map(|x| x.parse().unwrap_or(0))
        .collect();
    let per: usize = spr.iter().sum();
    let rec = if records > 0 {
        records as usize
    } else {
        (b.len() - hb) / (2 * per)
    };
    let keep: Vec<usize> = (0..ns)
        .filter(|i| {
            spr[*i] > 0
                && !labels[*i].to_lowercase().contains("annotation")
                && !labels[*i].to_lowercase().contains("status")
        })
        .collect();
    let first = keep.first().ok_or("EDF has no signals")?;
    let rate = spr[*first] as f64 / secs;
    let mut out: Vec<Vec<f32>> = keep.iter().map(|i| vec![0.0; rec * spr[*i]]).collect();
    let mut cursor = hb;
    for r in 0..rec {
        for c in 0..ns {
            let gain = (pmax[c] - pmin[c]) / (dmax[c] - dmin[c]);
            for s in 0..spr[c] {
                let d = i16::from_le_bytes([b[cursor], b[cursor + 1]]) as f64;
                cursor += 2;
                if let Some(k) = keep.iter().position(|i| *i == c) {
                    let mut v = d * gain + pmin[c] - gain * dmin[c];
                    if dims[c].eq_ignore_ascii_case("v") {
                        v *= 1e6
                    }
                    out[k][r * spr[c] + s] = v as f32
                }
            }
        }
    }
    let min = out.iter().map(Vec::len).min().unwrap();
    for x in &mut out {
        x.truncate(min)
    }
    Ok(Recording {
        rate,
        labels: keep.iter().map(|i| labels[*i].clone()).collect(),
        channels: out,
        source_epoch_samples: None,
        epoch_labels: None,
    })
}
