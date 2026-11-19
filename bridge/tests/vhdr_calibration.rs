use ccs_algorithm::eeg::vhdr_loader::load_vhdr;
#[test]
fn brainvision_resolution_and_voltage_units_apply_once() {
    for orientation in ["MULTIPLEXED", "VECTORIZED"] {
        let root=std::env::temp_dir().join(format!("ccs-vhdr-{}-{orientation}",std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("x.vhdr"),format!("BrainVision Data Exchange Header File Version 1.0\n[Common Infos]\nDataFile=x.eeg\nDataFormat=BINARY\nDataOrientation={orientation}\nNumberOfChannels=2\nSamplingInterval=1000\n[Binary Infos]\nBinaryFormat=IEEE_FLOAT_32\n[Channel Infos]\nCh1=Fz,,0.0488281,µV\nCh2=Pz,,0.001,mV\n")).unwrap();
        let values:[f32;4]=if orientation=="MULTIPLEXED" {[100.,-2.,200.,3.]}else{[100.,200.,-2.,3.]};
        let bytes:Vec<u8>=values.iter().flat_map(|v|v.to_le_bytes()).collect();
        std::fs::write(root.join("x.eeg"),bytes).unwrap();
        let rec=load_vhdr(&root.join("x.vhdr")).unwrap();
        assert!((rec.channels[0][0]-4.88281).abs()<1e-5);
        assert!((rec.channels[0][1]-9.76562).abs()<1e-5);
        assert_eq!(rec.channels[1],vec![-2.,3.]);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn brainvision_recovers_from_renamed_datafile_typo() {
    let root = std::env::temp_dir().join(format!("ccs-vhdr-typo-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    // Filename has TKG01 while internal DataFile= still says TK01 (typo from rename)
    let vhdr = root.join("Sub01_TKG01_7_Microphenomenology.vhdr");
    let eeg = root.join("Sub01_TKG01_7_Microphenomenology.eeg");
    std::fs::write(
        &vhdr,
        "BrainVision Data Exchange Header File Version 1.0\n[Common Infos]\nDataFile=Sub01_TK01_7_Microphenomenology.eeg\nDataFormat=BINARY\nDataOrientation=MULTIPLEXED\nNumberOfChannels=2\nSamplingInterval=2000\n[Binary Infos]\nBinaryFormat=IEEE_FLOAT_32\n[Channel Infos]\nCh1=Fz,,0.5,µV\nCh2=Cz,,0.5,µV\n",
    )
    .unwrap();
    let values: [f32; 4] = [2.0, 4.0, 6.0, 8.0];
    let bytes: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    std::fs::write(&eeg, bytes).unwrap();
    let rec = load_vhdr(&vhdr).unwrap();
    assert_eq!(rec.labels, vec!["Fz", "Cz"]);
    assert_eq!(rec.channels[0], vec![1.0, 3.0]);
    assert_eq!(rec.channels[1], vec![2.0, 4.0]);
    std::fs::remove_dir_all(root).unwrap();
}
