use ccs_eeg_engine::state_dynamics::*;
use std::path::Path;

#[test]
fn test_state_dynamics_parity() {
    let dir = Path::new("/Users/arunsasidharan/EEGdata/ThukdamStudy/20261110_Gyudmed_Monastery/Analysis_v01");
    if !dir.exists() {
        eprintln!("Feature directory not found, skipping parity test");
        return;
    }

    let files = vec![
        dir.join("1_Pilot_Tukdam_10.07.2026_PreMedRest-epo_clean.features.csv").to_string_lossy().to_string(),
        dir.join("1_Pilot_Tukdam_10.11.2026_PostMedRest-epo_clean.features.csv").to_string_lossy().to_string(),
        dir.join("2_Pilot_Tukdam_10.11.2026_Meditation-epo_clean.features.csv").to_string_lossy().to_string(),
        dir.join("4_Pilot_Tukdam_10.11.2026_5Minute_rest-epo_clean.features.csv").to_string_lossy().to_string(),
        dir.join("5_Pilot_Tukdam_10.11.2026_EO_EC_AT_VP-epo_clean.features.csv").to_string_lossy().to_string(),
        dir.join("6_Pilot_Tukdam_10.11.2026_EM_VT-epo_clean.features.csv").to_string_lossy().to_string(),
        dir.join("7_Pilot_Tukdam_10.11.2026_RE-epo_clean.features.csv").to_string_lossy().to_string(),
    ];

    if files.iter().any(|f| !Path::new(f).exists()) {
        eprintln!("Some files missing, skipping test");
        return;
    }

    let job = Job {
        job_type: "state_dynamics".into(),
        files,
        labels: vec![
            "10.07 PreMedRest".into(),
            "10.11 PostMedRest".into(),
            "10.11 Meditation".into(),
            "10.11 5Minute_rest".into(),
            "10.11 EO_EC_AT_VP".into(),
            "10.11 EM_VT".into(),
            "10.11 RE".into(),
        ],
        featureset: "paper".into(),
        feature_families: None,
        scale: "60s".into(),
        k: Some(6),
        iv_threshold: 0.4,
        display_band: "Gamma1".into(),
        repr_channel: "Fz".into(),
        rank_transform: false,
        step_s: 2.5,
        win_s: 5.0,
    };

    let res = run(&job).expect("State dynamics should run successfully");
    println!("State dynamics result: chosen_k = {}", res.chosen_k);
    for (k, sil) in &res.silhouette_scores {
        println!("k = {}: silhouette = {:.4}", k, sil);
    }
    for st in &res.states {
        println!(
            "State {}: {} stages, {:.1} min ({:.1}%)",
            st.label, st.n_stages, st.duration_min, st.percent_time
        );
    }

    assert_eq!(res.recordings.len(), 7);
    assert_eq!(res.states.len(), 6);
    let total_stages: usize = res.states.iter().map(|s| s.n_stages).sum();
    println!("Total stages across all states: {}", total_stages);
    assert!(total_stages > 100);
}
