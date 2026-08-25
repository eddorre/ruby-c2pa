# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] — unreleased

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

[Unreleased]: https://github.com/eddorre/ruby-c2pa/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/eddorre/ruby-c2pa/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/eddorre/ruby-c2pa/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/eddorre/ruby-c2pa/releases/tag/v0.2.0
