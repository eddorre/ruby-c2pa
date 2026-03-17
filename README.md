# ruby-c2pa

A Ruby gem for signing and reading [C2PA](https://c2pa.org) content credentials in media files. Built on top of the official [c2pa-rs](https://github.com/contentauth/c2pa-rs) Rust library via FFI.

## What is C2PA?

C2PA (Coalition for Content Provenance and Authenticity) is an open technical standard for attaching cryptographically signed provenance metadata to media files. It lets you prove:

- Who created or edited a file
- What tools were used
- When and where it was created
- Whether the content has been tampered with since signing

It is backed by Adobe, Microsoft, Google, the BBC, and others, and is increasingly required by platforms and publishers to establish trust in digital media — particularly in an era of AI-generated content.

## Why Rust bindings?

The C2PA specification is complex and security-sensitive. The reference implementation is [c2pa-rs](https://github.com/contentauth/c2pa-rs), an official Rust library maintained by the Content Authenticity Initiative. Rather than re-implementing the specification in Ruby (which would risk diverging from the spec or introducing security bugs), this gem wraps c2pa-rs directly.

The binding layer is a thin Rust library that exposes a C-compatible API (`extern "C"` functions), which Ruby loads at runtime using the [ffi](https://github.com/ffi/ffi) gem. This means:

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

C2PA signing requires an X.509 certificate and private key in PEM format. For testing you can generate a self-signed pair:

```bash
# Generate a private key (ES256 = ECDSA with P-256)
openssl ecparam -name prime256v1 -genkey -noout -out creator.key

# Generate a self-signed certificate
openssl req -new -x509 -key creator.key -out creator.pem -days 365 \
  -subj "/CN=My Name/O=My Organization"
```

For production use, obtain a certificate from a CA that is trusted by the C2PA ecosystem. The certificate file should contain the full chain (end-entity certificate first, then any intermediates), but should **not** include the root CA.

The supported signing algorithms are: `es256`, `es384`, `es512`, `ps256`, `ps384`, `ps512`, `ed25519`.

## Usage

### Signing a file

```ruby
require "c2pa"

# Sign in place (overwrites the original file)
C2PA.sign(
  file:        "video.mp4",
  certificate: "creator.pem",
  key:         "creator.key"
)

# Sign to a new file
C2PA.sign(
  file:        "video.mp4",
  output:      "video_signed.mp4",
  certificate: "creator.pem",
  key:         "creator.key"
)

# Specify a signing algorithm (default is "es256")
C2PA.sign(
  file:        "photo.jpg",
  certificate: "creator.pem",
  key:         "creator.key",
  algorithm:   "ps256"
)
```

### Providing a manifest

If you omit `manifest:`, a minimal one is generated using the filename as the title. You can provide your own:

```ruby
C2PA.sign(
  file:        "photo.jpg",
  certificate: "creator.pem",
  key:         "creator.key",
  manifest: {
    title: "Sunset over the bay",
    assertions: [
      {
        label: "stds.schema-org.CreativeWork",
        data: {
          "@context": "https://schema.org",
          "@type":    "CreativeWork",
          "author": [{ "@type": "Person", "name": "Jane Smith" }]
        }
      }
    ]
  }
)
```

The manifest hash is serialized to JSON and passed directly to c2pa-rs. See the [C2PA specification](https://c2pa.org/specifications/specifications/2.1/specs/C2PA_Specification.html) and [c2pa-rs manifest documentation](https://opensource.contentauthenticity.org/docs/rust-sdk/) for the full list of supported fields and assertion types.

### Reading a manifest

```ruby
manifest = C2PA.read(file: "photo_signed.jpg")

puts manifest["title"]
puts manifest["claim_generator"]
```

### Checking the SDK version

```ruby
puts C2PA.sdk_version  # => "0.78.2"
```

### Error handling

All errors inherit from `C2PA::Error`, so you can rescue broadly or narrowly:

```ruby
begin
  C2PA.sign(file: "photo.jpg", certificate: "cert.pem", key: "key.pem")
rescue C2PA::SigningError => e
  puts "Signing failed: #{e.message}"
rescue C2PA::ReadError => e
  puts "Could not read manifest: #{e.message}"
rescue C2PA::Error => e
  puts "C2PA error: #{e.message}"
end
```

## Supported file formats

Signing and reading are supported for any format supported by c2pa-rs, including:

| Format | MIME type |
|--------|-----------|
| JPEG | `image/jpeg` |
| PNG | `image/png` |
| WebP | `image/webp` |
| TIFF | `image/tiff` |
| AVIF | `image/avif` |
| MP4 / M4V | `video/mp4` |
| MOV | `video/quicktime` |
| MP3 | `audio/mpeg` |
| WAV | `audio/wav` |
| PDF | `application/pdf` |

The format is detected automatically from the file extension.

## How it works

```
Ruby (C2PA.sign)
    │
    │  ffi gem — passes strings as C pointers
    ▼
Rust (c2pa_sign_file)
    │
    │  calls c2pa-rs Builder API
    ▼
c2pa-rs — embeds signed manifest into the file
```

The Rust layer (`ext/c2pa_native/src/lib.rs`) exposes four functions with a C-compatible ABI:

| Function | Description |
|----------|-------------|
| `c2pa_sign_file` | Sign a file and write the result |
| `c2pa_read_file` | Read and return the manifest JSON |
| `c2pa_last_error` | Return the last error message |
| `c2pa_free_string` | Free a string allocated by Rust |

Errors are stored in Rust thread-local storage and surfaced to Ruby as typed exceptions.

## License

MIT
