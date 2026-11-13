//! Lossless f64 prefix checkpoints used only by interactive preprocessing.
//! Every key includes the preceding enabled stages and their effective parameters.
use std::{fs, io::{Read, Write, BufReader, BufWriter}, path::PathBuf};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use super::Recording;

#[derive(Serialize, Deserialize)]
struct Header {
    key: String, rate: f64, labels: Vec<String>, epoch_samples: Option<usize>,
    epoch_labels: Option<Vec<String>>, lengths: Vec<usize>, warnings: Vec<String>, extra: Value,
}
pub struct PrefixCache { root: Option<PathBuf>, prefix: String, pub hits: Vec<String> }
impl PrefixCache {
    pub fn new(root: Option<&str>, labels: &[String], excluded: &[String]) -> Self {
        Self { root: root.map(PathBuf::from), hits: Vec::new(), prefix: serde_json::json!(["preview-f64-v3", labels, excluded]).to_string() }
    }
    pub fn add(&mut self, name: &str, parameters: Value) {
        self.prefix.push_str(&serde_json::json!([name, parameters]).to_string());
    }
    pub fn enabled(&self) -> bool { self.root.is_some() }
    pub fn apply<F>(&mut self, name: &str, parameters: Value, data: &mut Vec<Vec<f64>>, rec: &mut Recording, warnings: &mut Vec<String>, work: F) -> Result<Value, String>
    where F: FnOnce(&mut Vec<Vec<f64>>, &mut Recording, &mut Vec<String>) -> Result<Value, String> {
        self.add(name, parameters);
        let path = self.root.as_ref().map(|root| root.join(format!("{:016x}.checkpoint", stable_hash(self.prefix.as_bytes()))));
        if let Some(path) = &path {
            if let Ok((header, samples)) = read_checkpoint(path, &self.prefix) {
                self.hits.push(name.to_string());
                *data = samples; rec.rate = header.rate; rec.labels = header.labels;
                rec.source_epoch_samples = header.epoch_samples; rec.epoch_labels = header.epoch_labels;
                warnings.extend(header.warnings);
                eprintln!("PROGRESS 10 Restored cached {name}; fitting not repeated");
                return Ok(header.extra);
            }
        }
        let start = warnings.len();
        let extra = work(data, rec, warnings)?;
        // Failed/skipped stages must be retried, not frozen in a successful cache entry.
        let failed = warnings[start..].iter().any(|s| s.contains("skipped") || s.contains("not completed"));
        if failed { self.root = None; }
        if !failed {
            if let Some(path) = path {
                let header = Header { key: self.prefix.clone(), rate: rec.rate, labels: rec.labels.clone(), epoch_samples: rec.source_epoch_samples,
                    epoch_labels: rec.epoch_labels.clone(), lengths: data.iter().map(Vec::len).collect(), warnings: warnings[start..].to_vec(), extra: extra.clone() };
                if let Err(e) = write_checkpoint(&path, &header, data) { eprintln!("PROGRESS 10 Cache write unavailable: {e}"); }
            }
        }
        Ok(extra)
    }
}
fn stable_hash(bytes: &[u8]) -> u64 { bytes.iter().fold(0xcbf29ce484222325, |h,b| (h ^ *b as u64).wrapping_mul(0x100000001b3)) }
fn read_checkpoint(path: &std::path::Path, key: &str) -> Result<(Header, Vec<Vec<f64>>), String> {
    let mut file = BufReader::new(fs::File::open(path).map_err(|e| e.to_string())?);
    let mut len = [0u8;8]; file.read_exact(&mut len).map_err(|e|e.to_string())?;
    let len = u64::from_le_bytes(len) as usize;
    if len > 512 * 1024 * 1024 { return Err("Invalid checkpoint header".into()); }
    let mut bytes = vec![0u8;len]; file.read_exact(&mut bytes).map_err(|e|e.to_string())?;
    let header: Header = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    if header.key != key || header.lengths.len() != header.labels.len() { return Err("Checkpoint key mismatch".into()); }
    let mut data = Vec::new();
    for &length in &header.lengths {
        let mut bytes = vec![0u8; length.checked_mul(8).ok_or("Checkpoint length overflow")?];
        file.read_exact(&mut bytes).map_err(|e|e.to_string())?;
        data.push(bytes.chunks_exact(8).map(|b| f64::from_le_bytes(b.try_into().unwrap())).collect());
    }
    Ok((header,data))
}
fn write_checkpoint(path: &std::path::Path, header: &Header, data: &[Vec<f64>]) -> Result<(),String> {
    fs::create_dir_all(path.parent().unwrap()).map_err(|e|e.to_string())?;
    let temp = path.with_extension(format!("writing-{}",std::process::id()));
    let mut file = BufWriter::new(fs::File::create(&temp).map_err(|e|e.to_string())?);
    let bytes = serde_json::to_vec(header).map_err(|e|e.to_string())?;
    file.write_all(&(bytes.len() as u64).to_le_bytes()).map_err(|e|e.to_string())?;
    file.write_all(&bytes).map_err(|e|e.to_string())?;
    for channel in data { for v in channel { file.write_all(&v.to_le_bytes()).map_err(|e|e.to_string())?; } }
    file.flush().map_err(|e|e.to_string())?; drop(file);
    fs::rename(&temp,path).map_err(|e|e.to_string())
}
