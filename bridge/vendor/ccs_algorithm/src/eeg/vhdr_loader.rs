use crate::eeg::Recording;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

enum Bm {
    I16,
    U16,
    I32,
    F32,
}

pub fn load_vhdr(path: &Path) -> Result<Recording, String> {
    let content = fs::read_to_string(path)
        .map_err(|e| format!("Failed reading .vhdr header {}: {}", path.display(), e))?;

    let mut data_file = String::new();
    let mut orientation = String::from("MULTIPLEXED");
    let mut binary_format = String::from("IEEE_FLOAT_32");
    let mut num_channels = 0usize;
    let mut sampling_interval_us = 0.0f64;

    let mut channel_names = HashMap::new();
    let mut channel_resolutions = HashMap::new();

    let mut section = String::new();

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].trim().to_string();
            continue;
        }
        if let Some(idx) = line.find('=') {
            let k = line[..idx].trim();
            let v = line[idx + 1..].trim();
            match section.as_str() {
                "Common Infos" => {
                    if k.eq_ignore_ascii_case("DataFile") {
                        data_file = v.to_string();
                    } else if k.eq_ignore_ascii_case("DataOrientation") {
                        orientation = v.to_uppercase();
                    } else if k.eq_ignore_ascii_case("NumberOfChannels") {
                        num_channels = v.parse().unwrap_or(0);
                    } else if k.eq_ignore_ascii_case("SamplingInterval") {
                        sampling_interval_us = v.parse().unwrap_or(0.0);
                    }
                }
                "Binary Infos" => {
                    if k.eq_ignore_ascii_case("BinaryFormat") {
                        binary_format = v.to_uppercase();
                    }
                }
                "Channel Infos" => {
                    if k.to_lowercase().starts_with("ch") {
                        if let Ok(ch_idx) = k[2..].parse::<usize>() {
                            let parts: Vec<&str> = v.split(',').collect();
                            let name = if !parts.is_empty() && !parts[0].trim().is_empty() {
                                parts[0].trim().to_string()
                            } else {
                                format!("Ch{}", ch_idx)
                            };
                            channel_names.insert(ch_idx, name);
                            let res = if parts.len() >= 3 && !parts[2].trim().is_empty() {
                                parts[2].trim().parse::<f32>().unwrap_or(1.0)
                            } else {
                                1.0
                            };
                            let unit = parts.get(3).map(|u| u.trim().to_lowercase().replace('μ', "µ")).unwrap_or_else(|| "µv".into());
                            let factor = match unit.as_str() { "v" => 1e6, "mv" => 1e3, "nv" => 0.001, _ => 1.0 };
                            channel_resolutions.insert(ch_idx, res * factor);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    if sampling_interval_us <= 0.0 {
        return Err(format!(
            "Invalid SamplingInterval {} in .vhdr",
            sampling_interval_us
        ));
    }
    let rate = 1_000_000.0 / sampling_interval_us;
    if num_channels == 0 {
        return Err("NumberOfChannels is 0 in .vhdr".to_string());
    }

    let mut labels = Vec::with_capacity(num_channels);
    let mut resolutions = Vec::with_capacity(num_channels);
    for i in 1..=num_channels {
        labels.push(
            channel_names
                .get(&i)
                .cloned()
                .unwrap_or_else(|| format!("Ch{}", i)),
        );
        resolutions.push(channel_resolutions.get(&i).cloned().unwrap_or(1.0));
    }

    let parent = path.parent().unwrap_or_else(|| Path::new(""));
    let data_path = resolve_companion_data_file(path, parent, &data_file)?;

    let bytes = fs::read(&data_path).map_err(|e| {
        format!(
            "Failed reading EEG data file {}: {}",
            data_path.display(),
            e
        )
    })?;

    let bytes_per_sample = match binary_format.as_str() {
        "INT_16" | "UINT_16" => 2,
        "INT_32" => 4,
        _ => 4, // IEEE_FLOAT_32
    };

    let bm = match binary_format.as_str() {
        "INT_16" => Bm::I16,
        "UINT_16" => Bm::U16,
        "INT_32" => Bm::I32,
        _ => Bm::F32,
    };

    let total_samples = bytes.len() / (num_channels * bytes_per_sample);
    if total_samples == 0 {
        return Err(format!(
            "Data file {} contains 0 complete samples",
            data_path.display()
        ));
    }

    let mut channels = vec![vec![0.0f32; total_samples]; num_channels];

    if orientation == "VECTORIZED" {
        for c in 0..num_channels {
            let res = resolutions[c];
            let ch_slice = &mut channels[c];
            for s in 0..total_samples {
                let offset = (c * total_samples + s) * bytes_per_sample;
                if offset + bytes_per_sample <= bytes.len() {
                    let v = match bm {
                        Bm::I16 => i16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f32,
                        Bm::U16 => u16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f32,
                        Bm::I32 => i32::from_le_bytes([
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                            bytes[offset + 3],
                        ]) as f32,
                        Bm::F32 => f32::from_le_bytes([
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                            bytes[offset + 3],
                        ]),
                    };
                    ch_slice[s] = v * res;
                }
            }
        }
    } else {
        // MULTIPLEXED
        let mut offset = 0;
        for s in 0..total_samples {
            for c in 0..num_channels {
                if offset + bytes_per_sample <= bytes.len() {
                    let v = match bm {
                        Bm::I16 => i16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f32,
                        Bm::U16 => u16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f32,
                        Bm::I32 => i32::from_le_bytes([
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                            bytes[offset + 3],
                        ]) as f32,
                        Bm::F32 => f32::from_le_bytes([
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                            bytes[offset + 3],
                        ]),
                    };
                    channels[c][s] = v * resolutions[c];
                    offset += bytes_per_sample;
                }
            }
        }
    }

    Ok(Recording {
        rate,
        labels,
        channels,
        source_epoch_samples: None,
        epoch_labels: None,
    })
}

fn levenshtein_ci(a: &str, b: &str) -> usize {
    let s: Vec<char> = a.to_lowercase().chars().collect();
    let t: Vec<char> = b.to_lowercase().chars().collect();
    if s == t {
        return 0;
    }
    if s.is_empty() {
        return t.len();
    }
    if t.is_empty() {
        return s.len();
    }
    let mut prev: Vec<usize> = (0..=t.len()).collect();
    let mut curr = vec![0usize; t.len() + 1];
    for (i, &sc) in s.iter().enumerate() {
        curr[0] = i + 1;
        for (j, &tc) in t.iter().enumerate() {
            let cost = if sc == tc { 0 } else { 1 };
            curr[j + 1] = (curr[j] + 1).min(prev[j + 1] + 1).min(prev[j] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[t.len()]
}

fn resolve_companion_data_file(
    vhdr_path: &Path,
    parent: &Path,
    declared_data_file: &str,
) -> Result<std::path::PathBuf, String> {
    let declared_base = declared_data_file
        .rsplit(&['/', '\\'][..])
        .next()
        .unwrap_or(declared_data_file)
        .trim();

    if !declared_base.is_empty() {
        let direct = parent.join(declared_base);
        if direct.exists() {
            return Ok(direct);
        }
    }

    let search_dir = if parent.as_os_str().is_empty() {
        Path::new(".")
    } else {
        parent
    };

    let mut siblings: Vec<std::path::PathBuf> = Vec::new();
    let mut vhdr_count = 0usize;
    if let Ok(entries) = fs::read_dir(search_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if !p.is_file() {
                continue;
            }
            let name = p
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("");
            if name.starts_with("._") {
                continue;
            }
            let low = name.to_lowercase();
            if low.ends_with(".vhdr") {
                vhdr_count += 1;
            } else if low.ends_with(".eeg") || low.ends_with(".dat") {
                siblings.push(p);
            }
        }
    }
    siblings.sort();

    // Case-insensitive exact match for declared basename
    if !declared_base.is_empty() {
        let low_decl = declared_base.to_lowercase();
        if let Some(hit) = siblings.iter().find(|p| {
            p.file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|n| n.to_lowercase() == low_decl)
        }) {
            return Ok(hit.clone());
        }
    }

    // 1. Case-insensitive same-stem sibling (<stem>.eeg or <stem>.dat)
    let stem = vhdr_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    for ext in ["eeg", "dat"] {
        let expected = format!("{}.{}", stem, ext).to_lowercase();
        if let Some(hit) = siblings.iter().find(|p| {
            p.file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|n| n.to_lowercase() == expected)
        }) {
            if !declared_base.is_empty() {
                eprintln!(
                    "Warning: BrainVision header {} referenced missing DataFile='{}'; auto-resolved to '{}'",
                    vhdr_path.display(),
                    declared_base,
                    hit.file_name().and_then(|s| s.to_str()).unwrap_or("")
                );
            }
            return Ok(hit.clone());
        }
    }

    // 2. Unique close Levenshtein typo match among same-folder .eeg/.dat files
    if !siblings.is_empty() {
        let query = if !declared_base.is_empty() {
            declared_base.to_string()
        } else {
            format!("{}.eeg", stem)
        };
        let mut scored: Vec<(usize, &std::path::PathBuf, usize)> = siblings
            .iter()
            .map(|p| {
                let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
                let dist = levenshtein_ci(&query, name);
                let min_len = query.chars().count().min(name.chars().count());
                (dist, p, min_len)
            })
            .collect();
        scored.sort_by_key(|a| a.0);
        let (best_dist, best_path, best_len) = scored[0];
        let max_allowed = ((best_len + 3) / 4).max(2).min(5);
        let unique_gap = scored.len() == 1 || scored[1].0.saturating_sub(best_dist) >= 2;
        if best_dist <= max_allowed && unique_gap {
            eprintln!(
                "Warning: BrainVision header {} referenced missing DataFile='{}'; auto-resolved by fuzzy match (distance {}) to '{}'",
                vhdr_path.display(),
                if declared_base.is_empty() { "(unspecified)" } else { declared_base },
                best_dist,
                best_path.file_name().and_then(|s| s.to_str()).unwrap_or("")
            );
            return Ok(best_path.clone());
        }
    }

    // 3. Unique companion .eeg/.dat when folder has a single recording
    if siblings.len() == 1 && vhdr_count <= 1 {
        let hit = &siblings[0];
        eprintln!(
            "Warning: BrainVision header {} referenced missing DataFile='{}'; auto-resolved to unique companion '{}'",
            vhdr_path.display(),
            if declared_base.is_empty() { "(unspecified)" } else { declared_base },
            hit.file_name().and_then(|s| s.to_str()).unwrap_or("")
        );
        return Ok(hit.clone());
    }

    let names: Vec<&str> = siblings
        .iter()
        .filter_map(|p| p.file_name().and_then(|s| s.to_str()))
        .collect();
    let hint = if names.is_empty() {
        format!("No .eeg or .dat files found in {}.", search_dir.display())
    } else {
        format!(
            "Sibling files in folder: {}. Update DataFile= inside the .vhdr header if renamed.",
            names.join(", ")
        )
    };
    Err(format!(
        "BrainVision DataFile='{}' referenced inside {} was not found. {}",
        if declared_base.is_empty() { "(unspecified)" } else { declared_base },
        vhdr_path.display(),
        hint
    ))
}
