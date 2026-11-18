# 5. Synced Video/Audio & Neural Speech Tracking

[← Batch & Group Statistics](Batch-and-Group-Statistics.md) · [Wiki Home](Home.md)

---

## Visual Flow

```mermaid
flowchart LR
  A["Open EEG Recording<br/>(VHDR / EDF / XDF / FIF)"] --> B["Resolve EEG Start Time<br/>(.vmrk New Segment / Metadata / Filename)"]
  V["Add Video(s) or WAV Audio<br/>(MP4, MOV, M2T, WAV, MP3)"] --> C["Probe Media Timestamps<br/>(ffprobe creation_time / Filename / mtime)"]
  B --> D["Align Segments on EEG Timeline<br/>+ Fine-Tune Sync Offset (±1 s)"]
  C --> D
  D --> E["Extract Audio + Speech Envelope<br/>Plot Waveform & Envelope + Synced Cursor"]
  E --> F["Neural Speech Tracking (Rust)<br/>Forward TRF · XCorr · Delta/Theta Coh · Decoder"]
```

---

## Key Features

- **Multi-Video & Standalone Audio Sync:** Load one or multiple timestamped video files or standalone `.wav`/audio recordings from the **Video / Audio** button in the top bar.
- **Audio Waveform & Envelope Extraction:** Automatically extracts mono 16 kHz audio from video (`ffmpeg`) and computes min/max waveform bins + smoothed 12 Hz speech envelope in Rust (`extract_audio_envelope`).
- **Neural Speech Tracking:** Click **Neural Speech Tracking** inside the synced media panel to run 5-fold cross-validated ridge **Temporal Response Function (TRF)** forward encoding, peak cross-correlation lag, delta/theta speech-brain coherence, and multi-channel **backward stimulus-reconstruction decoding**.
