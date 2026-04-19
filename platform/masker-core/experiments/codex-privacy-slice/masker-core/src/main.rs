use masker_core::{analyze_transcript, to_json, PolicyPreset};

fn main() {
    let sample = "My doctor said I have chest pain and my insurance ID is BCBS-887421.";
    let result = analyze_transcript(sample, PolicyPreset::HipaaClinicalContext);
    println!("{}", to_json(&result));
}
