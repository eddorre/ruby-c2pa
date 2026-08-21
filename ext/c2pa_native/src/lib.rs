use std::path::Path;
use c2pa::{create_signer, Builder, BuilderIntent, Reader, SigningAlg};
use magnus::{function, prelude::*, Error, Ruby};

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn alg_from_str(alg: &str) -> Result<SigningAlg, String> {
    match alg.to_lowercase().as_str() {
        "ps256" => Ok(SigningAlg::Ps256),
        "ps384" => Ok(SigningAlg::Ps384),
        "ps512" => Ok(SigningAlg::Ps512),
        "es256" => Ok(SigningAlg::Es256),
        "es384" => Ok(SigningAlg::Es384),
        "es512" => Ok(SigningAlg::Es512),
        "ed25519" => Ok(SigningAlg::Ed25519),
        _ => Err(format!(
            "Unknown signing algorithm: '{}'. Valid options: ps256, ps384, ps512, es256, es384, es512, ed25519",
            alg
        )),
    }
}

// ─── Core logic ──────────────────────────────────────────────────────────────

// A c2pa.opened action has to reference its parent ingredient by hashed URI,
// and that hash is computed over the ingredient assertion as c2pa-rs
// serialises it. Ruby cannot construct one. Declaring the intent instead lets
// the SDK derive the parent ingredient from the source and wire the action to
// it, which is the only way the edit workflow can be expressed.
fn intent_from_str(intent: &str) -> Result<BuilderIntent, String> {
    match intent.to_lowercase().as_str() {
        "edit" => Ok(BuilderIntent::Edit),
        "update" => Ok(BuilderIntent::Update),
        _ => Err(format!(
            "Unknown intent: '{}'. Valid options: edit, update",
            intent
        )),
    }
}

fn do_sign_file(
    source_path: &str,
    dest_path: &str,
    cert_path: &str,
    key_path: &str,
    alg_str: &str,
    manifest_json: Option<&str>,
    intent_str: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let cert = std::fs::read(cert_path)
        .map_err(|e| format!("Cannot read certificate '{}': {}", cert_path, e))?;
    let key = std::fs::read(key_path)
        .map_err(|e| format!("Cannot read key '{}': {}", key_path, e))?;

    let alg = alg_from_str(alg_str)?;
    let signer = create_signer::from_keys(&cert, &key, alg, None)
        .map_err(|e| format!("Failed to create signer: {}", e))?;

    let title = Path::new(source_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .replace('"', "\\\"");
    let default_json = format!(r#"{{"title": "{}"}}"#, title);
    let json = manifest_json.unwrap_or(&default_json);

    let mut builder = Builder::from_json(json)
        .map_err(|e| format!("Invalid manifest JSON: {}", e))?;

    if let Some(intent) = intent_str {
        builder.set_intent(intent_from_str(intent)?);
    }

    builder.sign_file(&*signer, source_path, dest_path)
        .map_err(|e| format!("Signing failed: {}", e))?;

    Ok(())
}

fn do_read_file(path: &str) -> Result<String, Box<dyn std::error::Error>> {
    let reader = Reader::from_file(path)
        .map_err(|e| format!("Failed to read manifest from '{}': {}", path, e))?;
    Ok(reader.json())
}

// ─── Ruby-facing functions ────────────────────────────────────────────────────

fn sign_file(
    source: String,
    dest: String,
    cert: String,
    key: String,
    alg: Option<String>,
    manifest_json: Option<String>,
    intent: Option<String>,
) -> Result<String, Error> {
    let alg_str = alg.as_deref().unwrap_or("es256");

    do_sign_file(&source, &dest, &cert, &key, alg_str, manifest_json.as_deref(), intent.as_deref())
        .map_err(|e| Error::new(Ruby::get().expect("called from Ruby thread").exception_runtime_error(), e.to_string()))?;

    Ok(dest)
}

fn read_file(path: String) -> Result<String, Error> {
    do_read_file(&path)
        .map_err(|e| Error::new(Ruby::get().expect("called from Ruby thread").exception_runtime_error(), e.to_string()))
}

fn sdk_version() -> String {
    c2pa::VERSION.to_string()
}

// ─── Extension entry point ────────────────────────────────────────────────────

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let c2pa = ruby.define_module("C2PA")?;
    let native = c2pa.define_module("Native")?;

    native.define_singleton_method("sign_file", function!(sign_file, 7))?;
    native.define_singleton_method("read_file", function!(read_file, 1))?;
    native.define_singleton_method("sdk_version", function!(sdk_version, 0))?;

    Ok(())
}
