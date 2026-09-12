use std::fs::File;
use std::io::Cursor;
use std::path::Path;
use std::sync::{Arc, RwLock, OnceLock};
use c2pa::{create_signer, Builder, BuilderIntent, Context, Reader, SigningAlg};
use magnus::{function, prelude::*, Error, RString, Ruby};

// ─── Helpers ─────────────────────────────────────────────────────────────────

// A Context carries the settings c2pa-rs validates against — trust anchors,
// what to verify, whether to fetch remote manifests. The older entry points
// read those from thread-local state, which is why they are deprecated: a
// threaded Ruby application could see different settings depending on which
// thread it signed from.
//
// One shared Context is built lazily and reused. It is Send + Sync, so an Arc
// is all that sharing requires, and reusing it avoids re-reading configuration
// on every call.
//
// It currently carries defaults. Exposing settings to Ruby is a separate piece
// of work; this is the seam that makes it possible.
// The one place this gem departs from c2pa-rs's defaults. c2pa-rs generates
// thumbnails when the feature is compiled in, scaling to a 1024px long edge —
// and it upscales, so a 160x120 source gets a 1024x768 "thumbnail" ten times
// its size. Off unless asked for; Config::to_json always states the choice.
const DEFAULT_SETTINGS: &str = r#"{"builder":{"thumbnail":{"enabled":false}}}"#;

fn context_slot() -> &'static RwLock<Arc<Context>> {
    static CONTEXT: OnceLock<RwLock<Arc<Context>>> = OnceLock::new();
    CONTEXT.get_or_init(|| {
        let context = Context::new()
            .with_settings(DEFAULT_SETTINGS)
            .expect("built-in default settings are valid")
            .into_shared();
        RwLock::new(context)
    })
}

fn shared_context() -> Arc<Context> {
    context_slot()
        .read()
        .expect("context lock poisoned")
        .clone()
}

// Replace the shared Context with one built from the supplied settings.
//
// c2pa-rs takes settings as JSON, so the Ruby side assembles the document and
// this only has to validate and install it. Rebuilding rather than mutating
// keeps the Context immutable once shared: signing already in flight on another
// thread continues against the settings it started with.
fn do_configure(settings_json: &str) -> Result<(), Box<dyn std::error::Error>> {
    let context = Context::new()
        .with_settings(settings_json)
        .map_err(|e| format!("Invalid settings: {}", e))?
        .into_shared();

    *context_slot().write().map_err(|_| "context lock poisoned")? = context;

    Ok(())
}

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

// Ingredients supplied as files rather than as descriptions. c2pa-rs reads the
// bytes to hash them, generate a thumbnail, and carry forward any manifest the
// file already holds; the JSON description takes precedence over anything
// derived from the stream.
//
// Expects a JSON array of {"json": "<ingredient JSON>", "format": "<mime>",
// "path": "<file>"}.
fn add_ingredient_files(
    builder: &mut Builder,
    ingredient_files_json: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let entries: serde_json::Value = serde_json::from_str(ingredient_files_json)
        .map_err(|e| format!("Invalid ingredient list: {}", e))?;
    let entries = entries
        .as_array()
        .ok_or("Invalid ingredient list: expected an array")?;

    for entry in entries {
        let field = |name: &str| -> Result<&str, String> {
            entry[name]
                .as_str()
                .ok_or_else(|| format!("Invalid ingredient list: missing '{}'", name))
        };
        let (json, format, path) = (field("json")?, field("format")?, field("path")?);

        let mut stream = File::open(path)
            .map_err(|e| format!("Cannot read ingredient '{}': {}", path, e))?;
        builder
            .add_ingredient_from_stream(json, format, &mut stream)
            .map_err(|e| format!("Cannot add ingredient '{}': {}", path, e))?;
    }

    Ok(())
}

type BoxError = Box<dyn std::error::Error>;

// The description of what to sign, shared by the file and buffer paths.
struct SigningRequest<'a> {
    cert_path: &'a str,
    key_path: &'a str,
    alg: &'a str,
    manifest_json: Option<&'a str>,
    intent: Option<&'a str>,
    ingredient_files_json: Option<&'a str>,
}

fn build_signer(cert_path: &str, key_path: &str, alg_str: &str) -> Result<Box<dyn c2pa::Signer + Send + Sync>, BoxError> {
    let cert = std::fs::read(cert_path)
        .map_err(|e| format!("Cannot read certificate '{}': {}", cert_path, e))?;
    let key = std::fs::read(key_path)
        .map_err(|e| format!("Cannot read key '{}': {}", key_path, e))?;

    let alg = alg_from_str(alg_str)?;
    create_signer::from_keys(&cert, &key, alg, None)
        .map_err(|e| format!("Failed to create signer: {}", e).into())
}

// A Builder carrying the manifest, intent and ingredients, ready to sign.
// `fallback_title` is used only when no manifest JSON was supplied.
fn build_builder(request: &SigningRequest, fallback_title: &str) -> Result<Builder, BoxError> {
    let default_json = format!(r#"{{"title": "{}"}}"#, fallback_title.replace('"', "\\\""));
    let json = request.manifest_json.unwrap_or(&default_json);

    let mut builder = Builder::from_shared_context(&shared_context())
        .with_definition(json)
        .map_err(|e| format!("Invalid manifest JSON: {}", e))?;

    if let Some(intent) = request.intent {
        builder.set_intent(intent_from_str(intent)?);
    }

    if let Some(files) = request.ingredient_files_json {
        add_ingredient_files(&mut builder, files)?;
    }

    Ok(builder)
}

fn do_sign_file(source_path: &str, dest_path: &str, request: &SigningRequest) -> Result<(), BoxError> {
    let signer = build_signer(request.cert_path, request.key_path, request.alg)?;

    let title = Path::new(source_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown");
    let mut builder = build_builder(request, title)?;

    builder
        .sign_file(&*signer, source_path, dest_path)
        .map_err(|e| format!("Signing failed: {}", e))?;

    Ok(())
}

// Sign bytes held in memory. The source is read through a Cursor, and the
// destination has to be one too: c2pa-rs writes the asset and then seeks back
// to hash it and patch the manifest in, so a write-only sink will not do.
fn do_sign_buffer(data: &[u8], format: &str, request: &SigningRequest) -> Result<Vec<u8>, BoxError> {
    let signer = build_signer(request.cert_path, request.key_path, request.alg)?;
    let mut builder = build_builder(request, "buffer")?;

    let mut source = Cursor::new(data);
    let mut dest = Cursor::new(Vec::new());
    builder
        .sign(&*signer, format, &mut source, &mut dest)
        .map_err(|e| format!("Signing failed: {}", e))?;

    Ok(dest.into_inner())
}

fn do_read_buffer(data: &[u8], format: &str) -> Result<String, BoxError> {
    let reader = Reader::from_shared_context(&shared_context())
        .with_stream(format, Cursor::new(data))
        .map_err(|e| format!("Failed to read manifest from buffer: {}", e))?;
    Ok(reader.json())
}

fn do_read_file(path: &str) -> Result<String, Box<dyn std::error::Error>> {
    let reader = Reader::from_shared_context(&shared_context())
        .with_file(path)
        .map_err(|e| format!("Failed to read manifest from '{}': {}", path, e))?;
    Ok(reader.json())
}

// ─── Running without the GVL ──────────────────────────────────────────────────
//
// Signing and reading are CPU-bound Rust with no need of the interpreter, so
// they run with Ruby's global VM lock released and other Ruby threads make
// progress meanwhile. magnus does not wrap rb_thread_call_without_gvl, hence
// the trampoline: the closure travels through the void pointer, its result
// travels back the same way, and nothing inside may touch Ruby.
//
// A panic must not unwind across the extern "C" frame (Rust aborts if it
// does), so it is caught on the far side and resumed once the lock is held.

type NoGvlSlot<F, R> = (Option<F>, Option<std::thread::Result<R>>);

unsafe extern "C" fn no_gvl_trampoline<F, R>(arg: *mut std::ffi::c_void) -> *mut std::ffi::c_void
where
    F: FnOnce() -> R,
{
    let slot = &mut *(arg as *mut NoGvlSlot<F, R>);
    let f = slot.0.take().expect("closure taken twice");
    slot.1 = Some(std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)));
    std::ptr::null_mut()
}

fn without_gvl<F, R>(f: F) -> R
where
    F: FnOnce() -> R,
{
    let mut slot: NoGvlSlot<F, R> = (Some(f), None);

    // RUBY_UBF_IO is a macro, not a symbol, so bindgen has no name for it. It
    // is the sentinel (rb_unblock_function_t *)-1, which tells Ruby to use
    // its own IO unblocker: a Thread#kill or Timeout aimed at this thread
    // interrupts a blocking syscall (a remote manifest fetch, say) rather
    // than waiting for the call to finish. Option<fn> has the null niche, so
    // a non-null bit pattern is a valid Some that Ruby compares by value and
    // never calls.
    let ubf: rb_sys::rb_unblock_function_t = unsafe { std::mem::transmute(-1isize) };

    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(no_gvl_trampoline::<F, R>),
            &mut slot as *mut NoGvlSlot<F, R> as *mut std::ffi::c_void,
            ubf,
            std::ptr::null_mut(),
        );
    }

    match slot.1.expect("closure did not run") {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

// ─── Ruby-facing functions ────────────────────────────────────────────────────

fn runtime_error(e: BoxError) -> Error {
    Error::new(
        Ruby::get().expect("called from Ruby thread").exception_runtime_error(),
        e.to_string(),
    )
}

fn sign_file(
    source: String,
    dest: String,
    cert: String,
    key: String,
    alg: Option<String>,
    manifest_json: Option<String>,
    intent: Option<String>,
    ingredient_files: Option<String>,
) -> Result<String, Error> {
    let request = SigningRequest {
        cert_path: &cert,
        key_path: &key,
        alg: alg.as_deref().unwrap_or("es256"),
        manifest_json: manifest_json.as_deref(),
        intent: intent.as_deref(),
        ingredient_files_json: ingredient_files.as_deref(),
    };

    without_gvl(|| do_sign_file(&source, &dest, &request)).map_err(runtime_error)?;
    Ok(dest)
}

// Takes an RString rather than a String so the bytes arrive untouched: a
// String argument would be transcoded to UTF-8, which is wrong for a JPEG.
// The slice is copied out at once, since Ruby may move or free the backing
// store the moment control returns to it.
fn sign_buffer(
    ruby: &Ruby,
    data: RString,
    format: String,
    cert: String,
    key: String,
    alg: Option<String>,
    manifest_json: Option<String>,
    intent: Option<String>,
    ingredient_files: Option<String>,
) -> Result<RString, Error> {
    let bytes = unsafe { data.as_slice() }.to_vec();
    let request = SigningRequest {
        cert_path: &cert,
        key_path: &key,
        alg: alg.as_deref().unwrap_or("es256"),
        manifest_json: manifest_json.as_deref(),
        intent: intent.as_deref(),
        ingredient_files_json: ingredient_files.as_deref(),
    };

    let signed = without_gvl(|| do_sign_buffer(&bytes, &format, &request)).map_err(runtime_error)?;
    Ok(ruby.str_from_slice(&signed))
}

fn read_file(path: String) -> Result<String, Error> {
    without_gvl(|| do_read_file(&path)).map_err(runtime_error)
}

// c2pa-rs sniffs the container from the leading bytes and lets the hint win
// only when it agrees; the hint carries the decision alone when sniffing
// fails, as it does for SVG.
fn read_buffer(data: RString, format: Option<String>) -> Result<String, Error> {
    let bytes = unsafe { data.as_slice() }.to_vec();
    let format = format.as_deref().unwrap_or("application/octet-stream");
    without_gvl(|| do_read_buffer(&bytes, format)).map_err(runtime_error)
}

fn configure(settings_json: String) -> Result<(), Error> {
    do_configure(&settings_json).map_err(runtime_error)
}

fn sdk_version() -> String {
    c2pa::VERSION.to_string()
}

// ─── Extension entry point ────────────────────────────────────────────────────

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let c2pa = ruby.define_module("C2PA")?;
    let native = c2pa.define_module("Native")?;

    native.define_singleton_method("sign_file", function!(sign_file, 8))?;
    native.define_singleton_method("sign_buffer", function!(sign_buffer, 8))?;
    native.define_singleton_method("read_file", function!(read_file, 1))?;
    native.define_singleton_method("read_buffer", function!(read_buffer, 2))?;
    native.define_singleton_method("configure", function!(configure, 1))?;
    native.define_singleton_method("sdk_version", function!(sdk_version, 0))?;

    Ok(())
}
