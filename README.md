# ruby-c2pa

A Ruby gem for signing and reading [C2PA](https://c2pa.org) content credentials in media files. Built on top of the official [c2pa-rs](https://github.com/contentauth/c2pa-rs) Rust library via a native extension.

## What is C2PA?

C2PA (Coalition for Content Provenance and Authenticity) is an open technical standard for attaching cryptographically signed provenance metadata to media files. It lets you prove:

- Who created or edited a file
- What tools were used
- When and where it was created
- Whether the content has been tampered with since signing

It is backed by Adobe, Microsoft, Google, the BBC, and others, and is increasingly required by platforms and publishers to establish trust in digital media — particularly in an era of AI-generated content.

## Why Rust bindings?

The C2PA specification is complex and security-sensitive. The reference implementation is [c2pa-rs](https://github.com/contentauth/c2pa-rs), an official Rust library maintained by the Content Authenticity Initiative. Rather than re-implementing the specification in Ruby (which would risk diverging from the spec or introducing security bugs), this gem wraps c2pa-rs directly.

The binding layer is a native Ruby extension written in Rust using [magnus](https://github.com/matsadler/magnus), which compiles directly into a `.bundle`/`.so` that Ruby loads like any other native extension. This means:

- **Correctness** — you get the reference implementation, not a reimplementation
- **Security** — cryptographic signing and manifest validation are handled by audited Rust code
- **Performance** — signing large video files happens in native code with no Ruby overhead
- **Spec compliance** — as c2pa-rs is updated to track the spec, you get those updates by bumping the Rust dependency

## Requirements

- Ruby >= 3.0
- Rust and Cargo (to compile the native library)
- OpenSSL (usually already present on macOS and Linux)

### Installing Rust

The compilation happens automatically during `gem install`, but Rust must be present on your system first.

The recommended way is via [mise](https://mise.jdx.dev), which can manage both Ruby and Rust in one place:

```bash
mise use --global rust@latest
```

Or via the official [rustup](https://rustup.rs) installer:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

## Installation

Add to your Gemfile:

```ruby
gem "ruby-c2pa"
```

Then run:

```bash
bundle install
```

The native Rust library is compiled automatically during installation. This takes a few minutes the first time as it downloads and compiles the c2pa-rs dependency tree.

## Preparing your certificate and key

C2PA signing requires an X.509 certificate chain and private key in PEM format.
The certificate file contains the end-entity certificate first, then any
intermediates, and must **not** include the root.

c2pa-rs enforces a certificate profile. An end-entity certificate is rejected
unless it carries all of:

- Basic Constraints `CA:FALSE`, critical
- Key Usage with `digitalSignature` or `nonRepudiation`, critical
- an Extended Key Usage that is present and not `any`, critical
- a Subject Key Identifier
- an **Authority Key Identifier**

The last one is easy to miss — `openssl x509 -req` omits it by default, and the
certificate is then rejected with nothing more specific than
`the certificate is invalid`.

### Whose CA?

A certificate from a CA in the C2PA trust list validates as `Trusted` with no
configuration.

A certificate from your own CA validates as `Valid` and carries
`signingCredential.untrusted` — which does **not** make the manifest invalid.
To have it treated as trusted, add your root as a trust anchor; see
[Configuring trust](#configuring-trust).

### Development and testing

The test suite generates its own certificates for every supported algorithm:

```bash
bundle exec rake fixtures:certs
```

They land in `test/fixtures/certs/` and are not committed. See
[`test/fixtures/generate_certs.rb`](test/fixtures/generate_certs.rb) for a
worked example of building a chain c2pa-rs accepts.

The supported signing algorithms are: `es256`, `es384`, `es512`, `ps256`, `ps384`, `ps512`, `ed25519`.

## Usage

### Building a manifest

Every signed file requires a `C2PA::Manifest` with at least one action. Actions describe what happened to the asset and are drawn from the `C2PA::Actions` constants, which cover the full vocabulary defined in the C2PA specification.

```ruby
require "c2pa"

manifest = C2PA::Manifest.new(title: "Sunset over the bay")
manifest.add_action(
  C2PA::Actions::CREATED,
  digital_source_type: C2PA::DigitalSourceTypes::DIGITAL_CAPTURE
)
```

`c2pa.created` must declare how the asset came into being. c2pa-rs rejects a
manifest without it, and accepts any string you supply — so a wrong value
validates while asserting something untrue. The gem therefore requires you to
choose rather than defaulting on your behalf:

| Constant | Use for |
|----------|---------|
| `DIGITAL_CAPTURE` | a camera original |
| `TRAINED_ALGORITHMIC_MEDIA` | generative AI output |
| `COMPOSITE_WITH_TRAINED_ALGORITHMIC_MEDIA` | edited using generative AI |
| `SCREEN_CAPTURE` | a screenshot |
| `HUMAN_EDITS` | human-edited media |
| `UNSPECIFIED` | the origin is genuinely unknown |

`C2PA::DigitalSourceTypes::ALL` lists them all. Reach for `UNSPECIFIED` when you
do not know — it is what c2pa-rs uses in its own fixtures, and it is honest in a
way that guessing is not.

This requirement arrived in c2pa-rs 0.90. Manifests signed by releases before
0.3.0 omit the field and are rejected by current verifiers.

Actions can be chained:

```ruby
manifest = C2PA::Manifest.new(title: "Sunset over the bay")
  .add_action(C2PA::Actions::CREATED,
              digital_source_type: C2PA::DigitalSourceTypes::DIGITAL_CAPTURE)
  .add_action(C2PA::Actions::PUBLISHED)
```

### Editing an existing asset

When the file you are signing derives from another one, declare the intent
rather than adding `c2pa.opened` yourself:

```ruby
manifest = C2PA::Manifest.new(title: "Edited photo", intent: :edit)
  .add_action(C2PA::Actions::EDITED)
  .add_action(C2PA::Actions::PUBLISHED)
```

c2pa-rs derives the parent ingredient from the source file and adds a
`c2pa.opened` action tied to it, so the signed manifest records
`c2pa.opened`, `c2pa.edited`, `c2pa.published` and a `parentOf` ingredient.

`c2pa.opened` cannot be added by hand. The specification requires it to
reference its parent ingredient by hashed URI, and that hash is computed over
the ingredient as c2pa-rs serialises it — so `add_action(C2PA::Actions::OPENED)`
raises and points here. Earlier releases of this gem documented adding it
directly; manifests built that way never validated.

Each action accepts optional fields from the C2PA specification:

```ruby
manifest.add_action(
  C2PA::Actions::CREATED,
  when_time:           "2026-03-17T10:00:00Z",   # ISO 8601 timestamp
  software_agent:      "Acme Editor/2.0",          # defaults to "ruby-c2pa/<version>"
  digital_source_type: "https://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia",
  changed:             ["region_of_interest"],
  parameters:          { "description" => "Generated by AI" }
)
```

### Available actions

All actions defined in the C2PA specification are available as constants on `C2PA::Actions`:

| Constant | Value |
|----------|-------|
| `C2PA::Actions::CREATED` | `c2pa.created` |
| `C2PA::Actions::OPENED` | `c2pa.opened` |
| `C2PA::Actions::EDITED` | `c2pa.edited` |
| `C2PA::Actions::EDITED_METADATA` | `c2pa.edited.metadata` |
| `C2PA::Actions::ADJUSTED_COLOR` | `c2pa.adjustedColor` |
| `C2PA::Actions::CHANGED_SPEED` | `c2pa.changedSpeed` |
| `C2PA::Actions::CONVERTED` | `c2pa.converted` |
| `C2PA::Actions::CROPPED` | `c2pa.cropped` |
| `C2PA::Actions::DELETED` | `c2pa.deleted` |
| `C2PA::Actions::DRAWING` | `c2pa.drawing` |
| `C2PA::Actions::DUBBED` | `c2pa.dubbed` |
| `C2PA::Actions::ENHANCED` | `c2pa.enhanced` |
| `C2PA::Actions::FILTERED` | `c2pa.filtered` |
| `C2PA::Actions::ORIENTATION` | `c2pa.orientation` |
| `C2PA::Actions::PLACED` | `c2pa.placed` |
| `C2PA::Actions::PUBLISHED` | `c2pa.published` |
| `C2PA::Actions::REDACTED` | `c2pa.redacted` |
| `C2PA::Actions::REMOVED` | `c2pa.removed` |
| `C2PA::Actions::REPACKAGED` | `c2pa.repackaged` |
| `C2PA::Actions::RESIZED` | `c2pa.resized` |
| `C2PA::Actions::TRANSLATED` | `c2pa.translated` |
| `C2PA::Actions::TRANSCODED` | `c2pa.transcoded` |
| `C2PA::Actions::TRIMMED` | `c2pa.trimmed` |
| `C2PA::Actions::UNKNOWN` | `c2pa.unknown` |
| `C2PA::Actions::WATERMARKED` | `c2pa.watermarked` |

### Adding other assertions

Use `add_assertion` for any assertion type beyond actions, such as schema.org metadata or AI training preferences:

```ruby
manifest.add_assertion(
  label: "stds.schema-org.CreativeWork",
  data: {
    "@context" => "https://schema.org",
    "@type"    => "CreativeWork",
    "author"   => [{ "@type" => "Person", "name" => "Jane Smith" }]
  }
)
```

### Adding ingredients

Ingredients record the source assets a file was derived from:

```ruby
manifest.add_ingredient(
  title:        "Original photo",
  format:       "image/jpeg",
  instance_id:  "xmp:iid:original-uuid-here"
)
```

### Signing a file

The `output` path must not already exist — `C2PA.sign` will raise a `C2PA::SigningError` if the file is already there.

```ruby
manifest = C2PA::Manifest.new(title: "Sunset over the bay")
  .add_action(C2PA::Actions::CREATED,
              digital_source_type: C2PA::DigitalSourceTypes::DIGITAL_CAPTURE)

C2PA.sign(
  file:        "photo.jpg",
  output:      "photo_signed.jpg",
  certificate: "test_cert.pem",
  key:         "test_key.pem",
  manifest:    manifest
)
```

`C2PA.sign` reads the signed file back and confirms it validates before
returning. If it does not, the output file is deleted and a
`C2PA::SigningError` is raised naming the failure codes.

This matters because c2pa-rs applies its rules when *reading*, not when
writing. Signing reports success for manifests that every verifier rejects,
which is exactly what earlier versions of this gem did — silently, for months.
The check costs one extra read of the output.

Turn it off with `verify: false` if you want the file kept for inspection:

```ruby
C2PA.sign(
  file:        "photo.jpg",
  output:      "photo_signed.jpg",
  certificate: "cert.pem",
  key:         "key.pem",
  manifest:    manifest,
  verify:      false
)
```

Specify a different signing algorithm with `algorithm:` (default is `"es256"`):

```ruby
C2PA.sign(
  file:        "photo.jpg",
  output:      "photo_signed.jpg",
  certificate: "cert.pem",
  key:         "key.pem",
  algorithm:   "ps256",
  manifest:    manifest
)
```

### Reading a manifest

```ruby
result = C2PA.read(file: "photo_signed.jpg")

active = result["manifests"][result["active_manifest"]]
puts active["title"]
puts active["claim_generator_info"].first["name"]   # => "ruby-c2pa"
```

### Naming your application

Signed files credit `ruby-c2pa` by default. To credit your own application
instead:

```ruby
manifest = C2PA::Manifest.new(
  title:             "Sunset over the bay",
  generator_name:    "Acme Editor",
  generator_version: "2.0"
).add_action(
  C2PA::Actions::CREATED,
  digital_source_type: C2PA::DigitalSourceTypes::DIGITAL_CAPTURE
)
```

The signed manifest then reads:

```json
{
  "name": "Acme Editor",
  "version": "2.0",
  "org.rubygems.ruby_c2pa": "0.3.0",
  "org.contentauth.c2pa_rs": "0.78.8"
}
```

c2pa-rs permits exactly one claim generator entry, so your application replaces
the gem as the name rather than preceding it. The gem is recorded in a
namespaced field alongside it, which is how c2pa-rs records itself.

Releases before 0.3.0 credited `c2pa-rs` and named neither the gem nor the
calling application.

### Checking the SDK version

```ruby
puts C2PA.sdk_version  # => "0.78.3"  (depends on the c2pa-rs version bundled with the gem)
```

### Error handling

All errors inherit from `C2PA::Error`, so you can rescue broadly or narrowly:

```ruby
begin
  C2PA.sign(file: "photo.jpg", output: "photo_signed.jpg", certificate: "cert.pem", key: "key.pem", manifest: manifest)
rescue C2PA::InvalidManifestError => e
  puts "Manifest is invalid: #{e.message}"
rescue C2PA::SigningError => e
  puts "Signing failed: #{e.message}"
end

begin
  C2PA.read(file: "photo_signed.jpg")
rescue C2PA::ReadError => e
  puts "Could not read manifest: #{e.message}"
end

# Or rescue any C2PA error broadly
begin
  C2PA.sign(file: "photo.jpg", output: "photo_signed.jpg", certificate: "cert.pem", key: "key.pem", manifest: manifest)
rescue C2PA::Error => e
  puts "C2PA error: #{e.message}"
end
```

## Configuring trust

c2pa-rs checks the signing certificate against a trust list, and reports
`Trusted` when it chains to a root that list contains. That happens by default,
so a certificate from a CA in the C2PA trust list needs no configuration.

For a private or enterprise CA, add its root:

```ruby
C2PA.configure do |config|
  config.trust_anchors = "ca/root.pem"   # a path, or the PEM text itself
end
```

Files signed by a certificate chaining to it then validate as `Trusted` rather
than carrying `signingCredential.untrusted`.

### Offline and air-gapped environments

Reading an asset may fetch a remote manifest over the network, and revocation
checking may contact an OCSP responder. Both can be turned off:

```ruby
C2PA.configure do |config|
  config.remote_manifest_fetch = false
  config.ocsp_fetch            = false
end
```

### Everything configurable

| Setting | Default | Purpose |
|---------|---------|---------|
| `trust_anchors` | none | additional roots to trust, as PEM |
| `trust_list` | C2PA list | replaces the trust list rather than adding to it |
| `allowed_certificates` | none | explicitly allowed certificates, as PEM |
| `verify_trust` | `true` | whether trust is checked at all |
| `remote_manifest_fetch` | `true` | whether reading may fetch over the network |
| `ocsp_fetch` | `false` | whether revocation is checked over OCSP |

Settings are global and apply to subsequent calls. Only values you set are
sent, so anything left alone keeps c2pa-rs's own default. `C2PA.configure` with
no block resets everything.

Turning `verify_trust` off means nothing is ever reported as untrusted, which
in a library for establishing provenance is rarely what you want. It exists for
environments that cannot reach a trust list at all.

## Supported file formats

Each format below has a fixture and a signing test in the suite: the file is
signed, read back, and asserted to validate.

| Format | MIME type |
|--------|-----------|
| JPEG | `image/jpeg` |
| PNG | `image/png` |
| WebP | `image/webp` |
| TIFF | `image/tiff` |
| AVIF | `image/avif` |
| JPEG XL | `image/jxl` |
| MP4 | `video/mp4` |
| MOV | `video/quicktime` |
| MP3 | `audio/mpeg` |
| WAV | `audio/wav` |

The format is detected automatically from the file extension.

JPEG XL must be in the ISOBMFF container form. A bare codestream has no boxes
to hold a manifest, and c2pa-rs rejects it.

### Not supported

**PDF cannot be signed.** c2pa-rs can read C2PA data out of a PDF but has no
writer for it — `get_writer` returns `None` and `save_cai_store` returns
`NotImplemented` — so `C2PA.sign` raises `C2PA::SigningError` with
`type is unsupported`. This is true at every c2pa-rs version. Earlier releases
of this gem listed PDF as supported; that was never correct.

### Test fixtures

The media fixtures are generated by
[`test/fixtures/generate.sh`](test/fixtures/generate.sh) from ffmpeg's built-in
sources, so they carry no third-party content and no licence obligations. They
are deliberately real files rather than placeholders — 160×120 images with
actual detail, real audio samples, real video frames, and EXIF metadata on the
JPEG — because C2PA writes into container structures that an empty file would
not exercise. All ten total 92 KB.

Regenerating them needs `ffmpeg`, `cjxl` and `exiftool`; running the tests does
not.

Signing certificates are generated on demand, one chain per key type, so every
supported algorithm is covered:

```bash
bundle exec rake fixtures:certs
```

`rake test` does this for you. The certificates are not committed — they are
development material, and regenerating costs a fraction of a second. Ruby's
OpenSSL binding is used rather than the `openssl` command because macOS ships
LibreSSL, which cannot generate Ed25519 keys.

## How it works

```
Ruby (C2PA.sign)
    │
    │  native extension (magnus)
    ▼
Rust (C2PA::Native.sign_file)
    │
    │  calls c2pa-rs Builder API
    ▼
c2pa-rs — embeds signed manifest into the file
```

The Rust extension (`ext/c2pa_native/src/lib.rs`) defines `C2PA::Native` with three methods:

| Method | Description |
|--------|-------------|
| `C2PA::Native.sign_file` | Sign a file and write the result |
| `C2PA::Native.read_file` | Read and return the manifest JSON |
| `C2PA::Native.sdk_version` | Return the c2pa-rs version string |

Input validation (missing files, invalid manifests) is handled in Ruby before calling into Rust. Errors from the native layer are caught and re-raised as typed `C2PA::Error` subclasses.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: every test must be
shown to fail before it is merged. The suite that shipped with 0.2.1 passed
while the gem crashed the Ruby process on TIFF input, so a green run is only
worth what its assertions can catch.

## License

MIT
