# Contributing

## Running the tests

```bash
bundle install
bundle exec rake test
```

That compiles the native extension, generates signing certificates, and runs
the suite. A clean checkout needs no manual setup and no network access.

Regenerating the media fixtures is the one thing that needs extra tooling, and
only if you are changing them:

```bash
brew install ffmpeg webp jpeg-xl exiftool   # macOS
./test/fixtures/generate.sh
```

## The testing rule

**Every test must be shown to fail.** Break the code it covers on purpose,
confirm the test catches it, put the evidence in the pull request.

This is not a general principle borrowed from somewhere. It comes from this
repository's own history. Version 0.2.1 shipped with a green test suite, and
that suite passed while the gem:

- aborted the Ruby process on any TIFF input
- emitted manifests that modern verifiers reject
- advertised PDF signing, which c2pa-rs cannot do at any version
- documented an editing workflow that has never produced a valid file

The suite passed because its assertions compared the code to itself:

```ruby
assert_equal "c2pa.created", C2PA::Actions::CREATED   # a literal equals itself
assert_equal "c2pa.created", actions[0]["action"]     # JSON contains what we put in
```

Ten tests, and not one of them could have failed for any of those defects. A
test that cannot fail is decoration.

### How to check

Change the implementation so the behaviour under test is wrong, run the suite,
confirm the right test fails, then restore:

```ruby
# lib/c2pa/manifest.rb
"title" => @title.reverse,   # deliberately wrong
```

```bash
bundle exec ruby -Ilib -Itest test/c2pa_test.rb
git checkout -- lib/c2pa/manifest.rb
```

Then state it in the pull request:

> Verified by reversing the title in `Manifest#to_json`: 19 failures, against 0
> for the unmutated suite.

A broad mutation like that trips many tests, which is fine. A narrow one that
trips exactly the test you just wrote is better evidence, because it shows the
test is specific as well as present.

Mutating the Rust in `ext/c2pa_native/` counts double — it proves the test
reaches through the FFI boundary rather than stopping at Ruby.

### Two traps, both hit while building this suite

**A mutation that does not do what you think.** A NUL-handling test appeared to
survive a mutation that stripped NUL bytes, which would have meant the test was
worthless. The mutation was wrong — a shell escape that deleted backslash-zero
rather than an actual NUL. Written correctly, the test failed immediately.
Prefer editing the file directly over shell substitution, and check the mutated
source before trusting the result.

**A harness that only fails one way.** For tests that assert on an external
verdict rather than on our own code, mutate in both directions. A harness made
to report no failures and a harness made to report spurious ones fail different
tests; checking only one leaves the other half unverified.

## Where there is no oracle

Most assertions can be checked against c2pa-rs, by signing a file and reading
back its verdict. Some cannot, and those must say so rather than pretend:

- **Action names** — c2pa-rs does not validate them. `acme.nonsense` signs and
  reads back clean, so `C2PA::Actions` can only be checked for duplicates and a
  correct namespace.
- **Digital source types** — any string is accepted, so the constants are only
  as good as the IPTC vocabulary they were transcribed from.

Where a rule is enforced more strictly here than by c2pa-rs, label it as a
deliberate divergence and add a test that fails when upstream changes its mind.
The gem may be stricter than the SDK; it may not claim the SDK agrees.

## Working on an issue

Issues are grouped into sprints by label and tracked against a release
milestone. Each carries acceptance criteria and a verification command.

```bash
git checkout -b fix/42-short-description
# ...
gh pr create --milestone "<milestone>" --label "<sprint label>"
```

Reference the issue with `Closes #42` so it closes on merge. CI runs the suite
on Linux and macOS for every pull request; both must pass.

macOS is not redundant in that matrix. The invalid free behind the TIFF crash
was surfaced by macOS libmalloc, which aborts on a bad free where glibc may
corrupt the heap silently.
