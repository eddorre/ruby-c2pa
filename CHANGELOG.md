# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Thumbnails. `C2PA.configure` gains `thumbnails`, `thumbnail_size`,
  `thumbnail_format` and `thumbnail_quality`. When enabled, a thumbnail of the
  asset is embedded in its manifest, and of each ingredient supplied as a file.
  Off by default: c2pa-rs upscales to its long-edge setting, so at its default
  of 1024 a 160×120 image gets a 1024×768 thumbnail ten times its own size.
  Produced for JPEG, PNG, WebP and TIFF; other formats sign without one.

### Changed

- The native extension is built with c2pa-rs's `add_thumbnails` feature, which
  adds the `image` crate: 16 more crates, about 17 seconds on a cold compile,
  and 1.5 MB on the compiled extension.

## [0.4.0] — 2026-09-11

Adds capability on top of 0.3.0. Nothing is removed and no existing call
changes behaviour, so this is a minor release.

### Added

- Provenance chaining through ingredients. `add_ingredient` takes an optional
  `file:`. When the file carries content credentials, its manifest is embedded
  in the signed output and the ingredient points at it, so a verifier can follow
  the chain from your asset back through the original. The description-only
  form is unchanged.
- `intent: :update` on `C2PA::Manifest`, for non-editorial changes such as
  correcting metadata. The source file is the parent.
- `C2PA.configure`, for trust and verification settings. Add a private CA's
  root as a trust anchor and its certificates validate as `Trusted`; disable
  `remote_manifest_fetch` and `ocsp_fetch` for environments without network
  access. Only values you set are sent, so defaults are c2pa-rs's own.
- Reading content credentials from PDFs. `C2PA.read` now parses a PDF and
  returns its manifest if one is present. Signing a PDF remains impossible;
  c2pa-rs has no PDF writer and upstream closed the request to add one.
- `C2PA::InvalidSettingsError`, raised by `C2PA.configure` for unusable input.

### Changed

- c2pa-rs 0.90.15 → 0.90.22. The range includes security fixes: `h2` updated
  for RUSTSEC-2026-0258, `chacha20` moved off a yanked version, hardening of
  BMFF chunk-index handling and CAWG identity bindings. The lockfile ships in
  the gem, so installers get these once they upgrade.
- The native layer uses c2pa-rs's Context API rather than the deprecated
  `Builder::from_json` and `Reader::from_file`, which read settings from
  thread-local state. One shared Context is reused across calls. Signing from
  several threads concurrently is now tested.
- CI fails if a deprecated c2pa-rs API reappears.

### Documentation

- The certificate section no longer claims certificates must chain to a CA in
  the C2PA trust list, or that self-signed certificates are rejected as such.
  A private CA works; its certificates carry `signingCredential.untrusted`
  until the root is added as an anchor. The certificate profile c2pa-rs
  enforces is listed, including the Authority Key Identifier that
  `openssl x509 -req` omits by default.
- PDF is listed as read-only, with a note on what the test suite can and
  cannot show: nothing available can produce a C2PA-signed PDF, so reading one
  is untested here, though the code doing it is c2pa-rs's own.

## [0.3.0] — 2026-08-25

Runs on c2pa-rs 0.90, and fixes every defect found while building a test suite
that verifies against c2pa-rs rather than against itself.

### If you have signed files with an earlier version

**Re-sign them.** Assets signed by 0.2.1 and earlier are rejected by current
verifiers, because their `c2pa.created` action carries no `digitalSourceType`.
c2pa-rs began requiring one in 0.90, and validation happens when a file is
read, not when it is written — so files that were valid when signed became
invalid as verifiers updated around them.

Anything signed using the README's editing example never validated at all. See
`c2pa.opened` under Fixed.

### Breaking

- `c2pa.created` now requires a `digital_source_type`. c2pa-rs accepts any
  string, so a default would validate while asserting something untrue about an
  asset's origin — a camera original and generative AI output are not
  interchangeable claims. Use `C2PA::DigitalSourceTypes::UNSPECIFIED` when the
  origin is genuinely unknown.
- `C2PA.sign` now reads the signed file back and raises `C2PA::SigningError` if
  it does not validate, deleting the output. Pass `verify: false` to keep it.
  Code that previously produced invalid files now fails instead of succeeding
  quietly.
- `add_action(C2PA::Actions::OPENED)` now raises. The action must reference its
  parent ingredient by hashed URI, which cannot be built from Ruby. Pass
  `intent: :edit` to `C2PA::Manifest.new` instead.
- `c2pa.translated` now requires `sourceLanguage` and `targetLanguage`
  parameters, as RFC 5646 codes.
- Invalid UTF-8 in a manifest now raises `C2PA::InvalidManifestError` rather
  than `JSON::GeneratorError`, so `rescue C2PA::Error` catches it as the README
  has always claimed.

### Fixed

- **Signing a TIFF aborted the Ruby process.** An invalid free in `atree`
  0.5.3, pulled transitively by c2pa-rs 0.78.3. No exception was raised, so it
  could not be rescued; in a web process it took down the worker. Fixed
  upstream in c2pa-rs 0.78.4, one day before 0.2.1 was published.
- **`c2pa.opened` produced files that never validated.** The README documented
  adding the action directly, which cannot work. Editing is now supported
  through `intent: :edit`, which lets c2pa-rs derive the parent ingredient from
  the source and wire the action to it.
- **Signed files credited `c2pa-rs` as the claim generator.** They now credit
  `ruby-c2pa`, and an application can name itself with `generator_name:`.
- **The gemspec homepage pointed at a repository that does not exist**, so the
  link from RubyGems returned 404.
- **The gem shipped 1.3 MB of Rust build artifacts**, and its contents varied
  with whatever had been compiled on the machine that built it.
- **`Cargo.lock` was never packaged.** The extension compiles at install time,
  so every installer resolved dependencies afresh — which is how 0.2.1 shipped
  against the broken `atree` even though the repository pinned it.
- **PDF was advertised as signable.** c2pa-rs has no PDF writer at any version;
  signing one raises, and the documentation now says so.

### Added

- `C2PA::DigitalSourceTypes` — the IPTC vocabulary, plus `UNSPECIFIED` for
  declining to claim an origin rather than guessing.
- `intent: :edit` on `C2PA::Manifest`, for signing an asset derived from
  another one.
- `generator_name:` and `generator_version:`, for naming your application as
  the claim generator.
- `verify:` on `C2PA.sign`, defaulting to `true`.
- Continuous integration on Linux and macOS. macOS is not redundant: the
  invalid free behind the TIFF crash was surfaced by macOS libmalloc, where
  glibc may corrupt the heap silently.
- `CONTRIBUTING.md`, recording the rule that every test must be shown to fail
  before it is merged.

### Changed

- c2pa-rs 0.78.3 → 0.90.15.
- Verified format support: JPEG, PNG, WebP, TIFF, AVIF, JPEG XL, MP4, MOV, MP3,
  WAV. Each has a fixture and a signing test. MOV, MP3 and JPEG XL were
  previously undocumented; PDF was documented and never worked.
- All seven signing algorithms are exercised — es256, es384, es512, ps256,
  ps384, ps512, ed25519 — each against a key of the matching type.
- The test suite went from 10 tests that compared the code to itself to 85 that
  sign real files and assert on what c2pa-rs reads back.

## [0.2.1] — 2026-03-17

Tagged retroactively. See the v0.2.1 tag for the defects it shipped with.

## [0.2.0] — 2026-03-17

Tagged retroactively.

[Unreleased]: https://github.com/eddorre/ruby-c2pa/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/eddorre/ruby-c2pa/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/eddorre/ruby-c2pa/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/eddorre/ruby-c2pa/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/eddorre/ruby-c2pa/releases/tag/v0.2.0
