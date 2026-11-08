//! Fast, native XDF 1.0 reader for continuous EEG, markers, and clock synchronization.
//! Supports arbitrary channel counts, uniform resampling, and LiveAmp generic pinout normalization.

use crate::erp_workbench::Event;
use crate::Recording;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

#[derive(Debug, Clone)]
pub struct XdfStreamInfo {
    pub id: u32,
    pub name: String,
    pub stream_type: String,
    pub channel_count: usize,
    pub nominal_rate: f64,
    pub channel_format: String,
}

#[derive(Default)]
struct StreamData {
    info: Option<XdfStreamInfo>,
    xml_header: String,
    channel_labels: Vec<String>,
    channel_units: Vec<String>,
    times: Vec<f64>,
    values: Vec<Vec<f64>>,
    events: Vec<(f64, String)>,
    clocks: Vec<(f64, f64)>,
    last_timestamp: f64,
}

impl StreamData {
    fn corrected_time(&self, time: f64) -> f64 {
        if self.clocks.is_empty() {
            return time;
        }
        if time <= self.clocks[0].0 {
            return time + self.clocks[0].1;
        }
        for i in 1..self.clocks.len() {
            let (t_prev, off_prev) = self.clocks[i - 1];
            let (t_curr, off_curr) = self.clocks[i];
            if time <= t_curr {
                let f = (time - t_prev) / (t_curr - t_prev);
                return time + off_prev + f * (off_curr - off_prev);
            }
        }
        time + self.clocks.last().unwrap().1
    }
}

pub struct XdfRecording {
    pub recording: Recording,
    pub events: Vec<Event>,
    pub stream_name: String,
    pub stream_id: u32,
}

/// Standard 32-channel BrainProducts LiveAmp electrode layout.
pub const LIVEAMP_32_LABELS: &[&str] = &[
    "Fp1", "Fz", "F3", "F7", "FT9", "FC5", "FC1", "C3", "T7", "TP9",
    "CP5", "CP1", "Pz", "P3", "P7", "O1", "Oz", "O2", "P4", "P8",
    "TP10", "CP6", "CP2", "Cz", "C4", "T8", "FT10", "FC6", "FC2", "F4",
    "F8", "Fp2",
];

/// Normalize generic amplifier channel labels like "EEG 1_1" .. "EEG 1_32" to 10-20 system.
pub fn normalize_channel_labels(labels: &[String]) -> Vec<String> {
    let generic_count = labels
        .iter()
        .filter(|l| {
            let s = l.trim().to_uppercase();
            s.starts_with("EEG 1_") || s.starts_with("EEG_") || s.starts_with("CH_") || s.starts_with("CH ")
        })
        .count();

    // If at least 16 channels are generic "EEG 1_x", normalize the first 32 to standard LiveAmp montage
    if generic_count >= 16 {
        let mut out = labels.to_vec();
        for (i, target) in LIVEAMP_32_LABELS.iter().enumerate() {
            if i < out.len() {
                out[i] = target.to_string();
            }
        }
        out
    } else {
        labels.to_vec()
    }
}

fn extract_xml_tag(xml: &str, tag: &str) -> Option<String> {
    let start_tag = format!("<{tag}>");
    let end_tag = format!("</{tag}>");
    let s = xml.find(&start_tag)?;
    let content_start = s + start_tag.len();
    let e = xml[content_start..].find(&end_tag)?;
    Some(xml[content_start..content_start + e].trim().to_string())
}

fn extract_channels_info(xml: &str, count: usize) -> (Vec<String>, Vec<String>) {
    let mut labels = Vec::with_capacity(count);
    let mut units = Vec::with_capacity(count);

    let mut cursor = 0;
    while let Some(ch_start) = xml[cursor..].find("<channel>") {
        let actual_start = cursor + ch_start + "<channel>".len();
        if let Some(ch_end) = xml[actual_start..].find("</channel>") {
            let ch_xml = &xml[actual_start..actual_start + ch_end];
            let label = extract_xml_tag(ch_xml, "label")
                .unwrap_or_else(|| format!("Ch{}", labels.len() + 1));
            let unit = extract_xml_tag(ch_xml, "unit").unwrap_or_default();
            labels.push(label);
            units.push(unit);
            cursor = actual_start + ch_end + "</channel>".len();
        } else {
            break;
        }
    }

    while labels.len() < count {
        labels.push(format!("Ch{}", labels.len() + 1));
        units.push(String::new());
    }

    labels.truncate(count);
    units.truncate(count);
    (labels, units)
}

fn unit_scale(unit: &str) -> f64 {
    let u = unit.trim().to_lowercase().replace('µ', "u").replace('μ', "u");
    match u.as_str() {
        "v" | "volt" | "volts" => 1e6,
        "mv" | "millivolt" | "millivolts" => 1e3,
        "nv" | "nanovolt" | "nanovolts" => 1e-3,
        _ => 1.0, // unspecified or uV assumed microvolts
    }
}

struct XdfReader<R> {
    reader: R,
}

impl<R: Read> XdfReader<R> {
    fn new(reader: R) -> Self {
        Self { reader }
    }

    fn read_u8(&mut self) -> Result<u8, String> {
        let mut buf = [0u8; 1];
        self.reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
        Ok(buf[0])
    }

    fn read_u32_le(&mut self) -> Result<u32, String> {
        let mut buf = [0u8; 4];
        self.reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
        Ok(u32::from_le_bytes(buf))
    }

    fn read_u64_le(&mut self) -> Result<u64, String> {
        let mut buf = [0u8; 8];
        self.reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
        Ok(u64::from_le_bytes(buf))
    }

    fn read_f32_le(&mut self) -> Result<f32, String> {
        let mut buf = [0u8; 4];
        self.reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
        Ok(f32::from_le_bytes(buf))
    }

    fn read_f64_le(&mut self) -> Result<f64, String> {
        let mut buf = [0u8; 8];
        self.reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
        Ok(f64::from_le_bytes(buf))
    }

    fn read_var_int(&mut self) -> Result<usize, String> {
        let flag = self.read_u8()?;
        match flag {
            1 => Ok(self.read_u8()? as usize),
            4 => Ok(self.read_u32_le()? as usize),
            8 => Ok(self.read_u64_le()? as usize),
            _ => Err(format!("Invalid XDF variable-length integer flag: {flag}")),
        }
    }

    fn read_string(&mut self, len: usize) -> Result<String, String> {
        let mut buf = vec![0u8; len];
        self.reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
        Ok(String::from_utf8_lossy(&buf).to_string())
    }
}

pub fn load_xdf(path: &Path) -> Result<XdfRecording, String> {
    let file = File::open(path).map_err(|e| format!("Cannot open XDF file {}: {e}", path.display()))?;
    let file_len = file.metadata().map_err(|e| e.to_string())?.len();
    let mut reader = BufReader::with_capacity(1024 * 1024, file);

    let mut magic = [0u8; 4];
    reader.read_exact(&mut magic).map_err(|e| e.to_string())?;
    if &magic != b"XDF:" {
        return Err("Not a valid XDF file (missing 'XDF:' magic header)".into());
    }

    let mut streams: BTreeMap<u32, StreamData> = BTreeMap::new();
    let mut pos: u64 = 4;

    while pos < file_len {
        let mut len_flag_buf = [0u8; 1];
        if reader.read_exact(&mut len_flag_buf).is_err() {
            break;
        }
        pos += 1;
        let len_flag = len_flag_buf[0];
        let chunk_size = match len_flag {
            1 => {
                let mut b = [0u8; 1];
                reader.read_exact(&mut b).map_err(|e| e.to_string())?;
                pos += 1;
                b[0] as u64
            }
            4 => {
                let mut b = [0u8; 4];
                reader.read_exact(&mut b).map_err(|e| e.to_string())?;
                pos += 4;
                u32::from_le_bytes(b) as u64
            }
            8 => {
                let mut b = [0u8; 8];
                reader.read_exact(&mut b).map_err(|e| e.to_string())?;
                pos += 8;
                u64::from_le_bytes(b)
            }
            _ => return Err(format!("Invalid XDF chunk length flag: {len_flag}")),
        };

        if chunk_size < 2 || pos + chunk_size > file_len + 1 {
            return Err("Truncated XDF chunk".into());
        }

        let mut tag_buf = [0u8; 2];
        reader.read_exact(&mut tag_buf).map_err(|e| e.to_string())?;
        let tag = u16::from_le_bytes(tag_buf);
        let payload_size = (chunk_size - 2) as usize;

        match tag {
            2 => {
                // StreamHeader
                let mut chunk_reader = XdfReader::new((&mut reader).take(payload_size as u64));
                let stream_id = chunk_reader.read_u32_le()?;
                let xml = chunk_reader.read_string(payload_size - 4)?;

                let name = extract_xml_tag(&xml, "name").unwrap_or_default();
                let stream_type = extract_xml_tag(&xml, "type").unwrap_or_default();
                let channel_count: usize = extract_xml_tag(&xml, "channel_count")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0);
                let nominal_rate: f64 = extract_xml_tag(&xml, "nominal_srate")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0.0);
                let channel_format = extract_xml_tag(&xml, "channel_format")
                    .unwrap_or_else(|| "float32".into());

                let (labels, units) = extract_channels_info(&xml, channel_count);

                let info = XdfStreamInfo {
                    id: stream_id,
                    name,
                    stream_type,
                    channel_count,
                    nominal_rate,
                    channel_format,
                };

                let stream = streams.entry(stream_id).or_default();
                stream.info = Some(info);
                stream.xml_header = xml;
                stream.channel_labels = labels;
                stream.channel_units = units;
            }
            3 => {
                // Samples chunk
                let mut chunk_reader = XdfReader::new((&mut reader).take(payload_size as u64));
                let stream_id = chunk_reader.read_u32_le()?;
                let stream = streams.entry(stream_id).or_default();

                if let Some(info) = &stream.info {
                    let num_samples = chunk_reader.read_var_int()?;
                    let is_string = info.channel_format == "string";
                    let is_event_stream = is_string || info.nominal_rate == 0.0;
                    let count = info.channel_count;

                    for _ in 0..num_samples {
                        let flag = chunk_reader.read_u8()?;
                        let time = match flag {
                            8 => chunk_reader.read_f64_le()?,
                            0 => {
                                stream.last_timestamp
                                    + if info.nominal_rate > 0.0 {
                                        1.0 / info.nominal_rate
                                    } else {
                                        0.0
                                    }
                            }
                            _ => return Err(format!("Invalid XDF timestamp flag: {flag}")),
                        };
                        stream.last_timestamp = time;

                        if is_string {
                            let mut labels = Vec::with_capacity(count);
                            for _ in 0..count {
                                let str_len = chunk_reader.read_var_int()?;
                                labels.push(chunk_reader.read_string(str_len)?);
                            }
                            stream.events.push((time, labels.join(" | ")));
                        } else if is_event_stream {
                            let mut vals = Vec::with_capacity(count);
                            for _ in 0..count {
                                let val = read_numeric_sample(&mut chunk_reader, &info.channel_format)?;
                                vals.push(val.to_string());
                            }
                            stream.events.push((time, vals.join(" | ")));
                        } else {
                            let mut vals = Vec::with_capacity(count);
                            for _ in 0..count {
                                vals.push(read_numeric_sample(&mut chunk_reader, &info.channel_format)?);
                            }
                            stream.times.push(time);
                            stream.values.push(vals);
                        }
                    }
                }
            }
            4 => {
                // ClockOffset
                let mut chunk_reader = XdfReader::new((&mut reader).take(payload_size as u64));
                let stream_id = chunk_reader.read_u32_le()?;
                let collection_time = chunk_reader.read_f64_le()?;
                let offset_value = chunk_reader.read_f64_le()?;
                let stream = streams.entry(stream_id).or_default();
                stream.clocks.push((collection_time, offset_value));
            }
            _ => {
                // Skip FileHeader, Boundary, StreamFooter or other chunk tags
                reader.seek_relative(payload_size as i64).map_err(|e| e.to_string())?;
            }
        }
        pos += chunk_size;
    }

    // Select primary numeric EEG stream
    let mut numeric_streams: Vec<(u32, &StreamData)> = streams
        .iter()
        .filter(|(_, s)| {
            if let Some(info) = &s.info {
                info.nominal_rate > 0.0 && info.channel_format != "string" && !s.times.is_empty()
            } else {
                false
            }
        })
        .map(|(id, s)| (*id, s))
        .collect();

    if numeric_streams.is_empty() {
        return Err("XDF file contains no numeric continuous data stream".into());
    }

    let eeg_stream_idx = if numeric_streams.len() == 1 {
        0
    } else {
        numeric_streams
            .iter()
            .position(|(_, s)| {
                s.info
                    .as_ref()
                    .map(|i| i.stream_type.eq_ignore_ascii_case("eeg"))
                    .unwrap_or(false)
            })
            .unwrap_or(0)
    };

    let (eeg_id, eeg_stream) = numeric_streams.remove(eeg_stream_idx);
    let info = eeg_stream.info.as_ref().unwrap();

    if eeg_stream.times.len() < 2 {
        return Err("XDF EEG stream has fewer than two samples".into());
    }

    // Correct timestamps with clock sync
    let corrected_times: Vec<f64> = eeg_stream
        .times
        .iter()
        .map(|&t| eeg_stream.corrected_time(t))
        .collect();

    let t_start = corrected_times[0];
    let t_end = *corrected_times.last().unwrap();
    let duration = t_end - t_start;
    let n_samples = corrected_times.len();

    let rate = if duration > 0.0 {
        (n_samples - 1) as f64 / duration
    } else {
        info.nominal_rate
    };

    if !rate.is_finite() || rate <= 0.0 {
        return Err("Invalid sampling rate calculated from XDF timestamps".into());
    }

    // Check monotonic timestamps
    for i in 1..corrected_times.len() {
        if corrected_times[i] <= corrected_times[i - 1] {
            return Err("XDF stream contains non-monotonic timestamps".into());
        }
    }

    // Build channel scaling factors
    let scales: Vec<f64> = (0..info.channel_count)
        .map(|c| {
            if c < eeg_stream.channel_units.len() {
                unit_scale(&eeg_stream.channel_units[c])
            } else {
                1.0
            }
        })
        .collect();

    // Uniform resampling to regular grid
    let mut channels: Vec<Vec<f32>> = vec![vec![0.0f32; n_samples]; info.channel_count];
    let mut left = 0;

    for i in 0..n_samples {
        let t_target = t_start + i as f64 / rate;
        while left + 1 < n_samples - 1 && corrected_times[left + 1] < t_target {
            left += 1;
        }
        let t0 = corrected_times[left];
        let t1 = corrected_times[left + 1];
        let frac = if t1 > t0 {
            ((t_target - t0) / (t1 - t0)).clamp(0.0, 1.0)
        } else {
            0.0
        };

        for c in 0..info.channel_count {
            let v0 = eeg_stream.values[left][c];
            let v1 = eeg_stream.values[left + 1][c];
            let val = (v0 * (1.0 - frac) + v1 * frac) * scales[c];
            channels[c][i] = val as f32;
        }
    }

    // Normalize generic channel names (e.g. EEG 1_1 -> Fp1, EEG 1_2 -> Fz)
    let labels = normalize_channel_labels(&eeg_stream.channel_labels);

    // Extract all markers/events from other streams
    let mut all_events: Vec<Event> = Vec::new();
    let mut event_idx = 1;

    for (_id, stream) in &streams {
        for (raw_t, desc) in &stream.events {
            let corr_t = stream.corrected_time(*raw_t);
            let onset_s = corr_t - t_start;
            if onset_s >= 0.0 && onset_s <= duration {
                all_events.push(Event {
                    label: desc.trim().to_string(),
                    onset: onset_s,
                    duration: 0.0,
                    index: event_idx,
                });
                event_idx += 1;
            }
        }
    }

    all_events.sort_by(|a, b| a.onset.total_cmp(&b.onset));

    Ok(XdfRecording {
        recording: Recording {
            rate,
            labels,
            channels,
            source_epoch_samples: None,
            epoch_labels: None,
        },
        events: all_events,
        stream_name: info.name.clone(),
        stream_id: eeg_id,
    })
}

fn read_numeric_sample<R: Read>(reader: &mut XdfReader<R>, format: &str) -> Result<f64, String> {
    match format {
        "float32" => Ok(reader.read_f32_le()? as f64),
        "double64" => Ok(reader.read_f64_le()?),
        "int8" => {
            let b = reader.read_u8()?;
            Ok((b as i8) as f64)
        }
        "int16" => {
            let mut b = [0u8; 2];
            reader.reader.read_exact(&mut b).map_err(|e| e.to_string())?;
            Ok(i16::from_le_bytes(b) as f64)
        }
        "int32" => {
            let mut b = [0u8; 4];
            reader.reader.read_exact(&mut b).map_err(|e| e.to_string())?;
            Ok(i32::from_le_bytes(b) as f64)
        }
        "int64" => {
            let mut b = [0u8; 8];
            reader.reader.read_exact(&mut b).map_err(|e| e.to_string())?;
            Ok(i64::from_le_bytes(b) as f64)
        }
        _ => Err(format!("Unsupported numeric XDF channel format: {format}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_shitija_delna() {
        let p = Path::new("/Users/arunsasidharan/EEGdata/Shitija/delna/sub-P001_ses-S001_task-Default_run-001_eeg.xdf");
        if !p.exists() {
            return;
        }
        let res = load_xdf(p).expect("Failed to load delna XDF");
        assert_eq!(res.recording.channels.len(), 36);
        assert!(res.recording.rate > 249.0 && res.recording.rate < 251.0);
        assert_eq!(res.recording.labels[0], "Fp1");
        assert_eq!(res.recording.labels[1], "Fz");
        assert_eq!(res.events.len(), 616);
    }

    #[test]
    fn test_load_shitija_pallabi_and_normalize() {
        let p = Path::new("/Users/arunsasidharan/EEGdata/Shitija/pallabi/sub-P001_ses-S001_task-Default_run-001_eeg.xdf");
        if !p.exists() {
            return;
        }
        let res = load_xdf(p).expect("Failed to load pallabi XDF");
        assert_eq!(res.recording.channels.len(), 35);
        // Generic channels 1..32 should be normalized to standard 10-20
        assert_eq!(res.recording.labels[0], "Fp1");
        assert_eq!(res.recording.labels[1], "Fz");
        assert_eq!(res.recording.labels[23], "Cz");
        assert_eq!(res.events.len(), 610);
    }
}
