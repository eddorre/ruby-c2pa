# Every test here must be able to fail. Before adding one, break the code it
# covers on purpose and confirm this suite catches it — see CONTRIBUTING.md.
#
# That rule exists because the original suite passed while the gem aborted the
# Ruby process on TIFF input and emitted manifests that verifiers reject. Its
# assertions compared the code to itself, so none of them could have failed.

require "minitest/autorun"
require "tmpdir"
require "tempfile"
require "fileutils"
require "c2pa"

class C2PATest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)
  CERT     = File.join(FIXTURES, "certs", "es256.pub")
  KEY      = File.join(FIXTURES, "certs", "es256.pem")

  # Deliberately not a skip. A suite that quietly passes without exercising the
  # signing path reports success while verifying nothing, which is the failure
  # this suite exists to avoid.
  def assert_certificates_present
    return if File.size?(CERT) && File.size?(KEY)

    flunk "Signing certificates missing from #{File.join(FIXTURES, 'certs')}. " \
          "Run `bundle exec rake fixtures:certs`."
  end

  # Sign a fixture and yield the path to the signed file.
  def sign_fixture(name, manifest)
    assert_certificates_present

    dir = Dir.mktmpdir
    output = File.join(dir, "signed#{File.extname(name)}")
    C2PA.sign(
      file:        File.join(FIXTURES, name),
      output:      output,
      certificate: CERT,
      key:         KEY,
      manifest:    manifest
    )
    yield output
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  DIGITAL_CAPTURE = C2PA::DigitalSourceTypes::DIGITAL_CAPTURE

  def created_manifest(title: "Test")
    C2PA::Manifest.new(title: title)
                  .add_action(C2PA::Actions::CREATED, digital_source_type: DIGITAL_CAPTURE)
  end

  # Sign a fixture and yield the active manifest exactly as c2pa-rs reads it
  # back out of the finished asset.
  #
  # Asserting against Manifest#to_json only proves the builder agrees with
  # itself. Going through the file covers JSON generation, the magnus boundary,
  # CBOR encoding and the C2PA container as well.
  def read_back(manifest, fixture: "tiny.jpg")
    sign_fixture(fixture, manifest) do |output|
      result = C2PA.read(file: output)
      yield result["manifests"].fetch(result["active_manifest"]), result
    end
  end

  # The actions recorded in a signed manifest.
  def signed_actions(active)
    active.fetch("assertions")
          .find { |assertion| assertion["label"] == "c2pa.actions.v2" }
          .fetch("data")
          .fetch("actions")
  end

  def test_version_is_a_string
    assert_instance_of String, C2PA::VERSION
  end

  def test_sdk_version_is_a_string
    assert_instance_of String, C2PA.sdk_version
  end

  def test_sign_raises_on_missing_file
    manifest = C2PA::Manifest.new(title: "Test").add_action(C2PA::Actions::CREATED, digital_source_type: DIGITAL_CAPTURE)

    assert_raises(C2PA::SigningError) do
      C2PA.sign(
        file:        "/nonexistent/file.jpg",
        output:      "/nonexistent/output.jpg",
        certificate: "/nonexistent/cert.pem",
        key:         "/nonexistent/key.pem",
        manifest:    manifest
      )
    end
  end

  def test_sign_raises_on_empty_manifest
    manifest = C2PA::Manifest.new(title: "Test")

    assert_raises(C2PA::InvalidManifestError) do
      C2PA.sign(
        file:        "/nonexistent/file.jpg",
        output:      "/nonexistent/output.jpg",
        certificate: "/nonexistent/cert.pem",
        key:         "/nonexistent/key.pem",
        manifest:    manifest
      )
    end
  end

  def test_read_raises_on_unsigned_file
    unsigned = Tempfile.new(["unsigned", ".jpg"])
    unsigned.write("\xFF\xD8\xFF\xE0") # minimal JPEG header bytes
    unsigned.close

    assert_raises(C2PA::ReadError) do
      C2PA.read(file: unsigned.path)
    end
  ensure
    unsigned&.unlink
  end

  # ─── Constant tables ───────────────────────────────────────────────────────
  #
  # No external oracle exists for these. c2pa-rs does not validate action names
  # — a bogus one signs and reads back clean — so their correctness comes from
  # the specification they were transcribed from, not from anything testable
  # here. What can be checked is what goes wrong in a hand-typed list of 25
  # strings: a duplicate, or a mistyped namespace.

  def test_action_constants_are_distinct_and_namespaced
    values = C2PA::Actions.constants.map { |name| C2PA::Actions.const_get(name) }

    assert_equal values.length, values.uniq.length, "duplicate action string"
    values.each { |value| assert_match(/\Ac2pa\.[a-zA-Z.]+\z/, value) }
  end

  # ─── Signing ───────────────────────────────────────────────────────────────

  # Kept alongside the TIFF entry in SIGNABLE_FORMATS. That one asks whether
  # TIFF works as a format; this one guards a specific crash, and names it.
  #
  # Regression: signing a TIFF used to abort the Ruby process outright.
  #
  # The culprit is `atree` 0.5.3, which produces an invalid free. macOS
  # libmalloc detects it and calls abort(), taking the interpreter with it — no
  # exception, nothing to rescue. c2pa-rs 0.78.3 declared `atree = "0.5.2"`, a
  # caret requirement, so it happily resolved 0.5.3; the fix in
  # contentauth/c2pa-rs#1940 (released in 0.78.4) changed that to an exact
  # `=0.5.2`.
  #
  # Verified to catch the regression: with `atree` forced to 0.5.3 this test
  # aborts the process on every run. Note it is the atree version that matters,
  # not the c2pa version — downgrading c2pa alone leaves a fixed atree in the
  # lockfile and the crash does not reproduce.
  #
  # A regression therefore shows up as a crashed run rather than a failed
  # assertion, since the process does not survive to report.
  def test_signs_a_tiff_without_crashing_the_process
    sign_fixture("tiny.tiff", created_manifest(title: "TIFF regression")) do |output|
      assert File.size?(output), "signed file is empty"
      result = C2PA.read(file: output)
      active = result["manifests"].fetch(result["active_manifest"])
      assert_equal "TIFF regression", active["title"]
    end
  end

  # ─── Signing algorithms ────────────────────────────────────────────────────
  #
  # alg_from_str in ext/c2pa_native/src/lib.rs maps seven names and has an
  # error branch for anything else. None of it was exercised.
  #
  # Each algorithm needs a key of the matching type, so the suite generates a
  # chain per key type (see test/fixtures/generate_certs.rb). The PS algorithms
  # share one RSA key, differing only in the digest applied at signing time.

  ALGORITHM_KEYS = {
    "es256"   => "es256",
    "es384"   => "es384",
    "es512"   => "es512",
    "ps256"   => "ps256",
    "ps384"   => "ps256",
    "ps512"   => "ps256",
    "ed25519" => "ed25519"
  }.freeze

  def certificate_for(key_name)
    [File.join(FIXTURES, "certs", "#{key_name}.pub"),
     File.join(FIXTURES, "certs", "#{key_name}.pem")]
  end

  ALGORITHM_KEYS.each do |algorithm, key_name|
    define_method("test_signs_with_#{algorithm}") do
      cert, key = certificate_for(key_name)
      unless File.size?(cert) && File.size?(key)
        flunk "Missing #{key_name} certificate. Run `bundle exec rake fixtures:certs`."
      end

      dir = Dir.mktmpdir
      output = File.join(dir, "signed.jpg")
      C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
                certificate: cert, key: key, manifest: created_manifest,
                algorithm: algorithm)

      result = C2PA.read(file: output)
      active = result["manifests"].fetch(result["active_manifest"])

      # c2pa-rs reports the algorithm capitalised, e.g. "Es256".
      assert_equal algorithm.capitalize, active.dig("signature_info", "alg"),
                   "#{algorithm} was not recorded in the signed manifest"
      assert_includes %w[Valid Trusted], result["validation_state"],
                      "#{algorithm} signed but does not validate"
    ensure
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end
  end

  def test_default_algorithm_is_es256
    read_back(created_manifest) do |active, _|
      assert_equal "Es256", active.dig("signature_info", "alg")
    end
  end

  def test_unknown_algorithm_is_rejected_and_writes_nothing
    assert_certificates_present
    dir = Dir.mktmpdir
    output = File.join(dir, "signed.jpg")

    error = assert_raises(C2PA::SigningError) do
      C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
                certificate: CERT, key: KEY, manifest: created_manifest,
                algorithm: "sha256-with-wishful-thinking")
    end

    assert_match(/unknown signing algorithm/i, error.message)
    assert_match(/es256/, error.message, "the error should name the valid options")
    refute File.exist?(output), "no file should be written for an unusable algorithm"
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def test_algorithm_mismatched_with_the_key_is_rejected
    cert, key = certificate_for("es256")
    dir = Dir.mktmpdir
    output = File.join(dir, "signed.jpg")

    # ps256 is RSA-PSS; this key is EC P-256. Signing must fail rather than
    # produce a file nobody can verify.
    assert_raises(C2PA::SigningError) do
      C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
                certificate: cert, key: key, manifest: created_manifest,
                algorithm: "ps256")
    end
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  # ─── Format coverage ───────────────────────────────────────────────────────
  #
  # Every format the README advertises as signable gets a fixture and a test.
  # Formats claimed but never exercised are how the PDF row survived: c2pa-rs
  # cannot write C2PA data to a PDF at all, and nothing caught it.
  #
  # Fixtures are synthesised by test/fixtures/generate.sh and committed, so the
  # suite needs no media tooling to run and carries no third-party content.
  #
  # They are not placeholders. C2PA writes manifests into real container
  # structures — APP11 segments, iTXt chunks, IFD entries, BMFF uuid boxes,
  # RIFF chunks, ID3 frames — so the fixtures carry real image detail, real
  # audio samples, real video frames, and real EXIF in the JPEG. 92 KB total.

  SIGNABLE_FORMATS = {
    "tiny.jpg"  => "JPEG",
    "tiny.png"  => "PNG",
    "tiny.webp" => "WebP",
    "tiny.tiff" => "TIFF",
    "tiny.avif" => "AVIF",
    "tiny.jxl"  => "JPEG XL",
    "tiny.wav"  => "WAV",
    "tiny.mp3"  => "MP3",
    "tiny.mp4"  => "MP4",
    "tiny.mov"  => "MOV (QuickTime)"
  }.freeze

  SIGNABLE_FORMATS.each do |fixture, label|
    define_method("test_signs_#{fixture.tr('.', '_')}") do
      title = "#{label} coverage"
      read_back(created_manifest(title: title), fixture: fixture) do |active, result|
        assert_equal title, active["title"], "#{label} did not round-trip its title"
        assert_includes %w[Valid Trusted], result["validation_state"],
                        "#{label} signed but does not validate"
      end
    end
  end

  # c2pa-rs has no PDF writer: pdf_io.rs returns None from get_writer and
  # NotImplemented from save_cai_store. This is true at every version, so the
  # README must not advertise PDF signing. Asserting the failure keeps the
  # documentation honest — if upstream ever adds a writer, this test fails and
  # the claim can be restored deliberately.
  def test_pdf_signing_is_not_supported
    assert_certificates_present

    Tempfile.create(["unsigned", ".pdf"]) do |pdf|
      pdf.write("%PDF-1.4\n%%EOF\n")
      pdf.flush

      error = assert_raises(C2PA::SigningError) do
        C2PA.sign(file: pdf.path, output: "#{pdf.path}.signed.pdf",
                  certificate: CERT, key: KEY, manifest: created_manifest)
      end
      assert_match(/unsupported/i, error.message)
    end
  end

  # Guards the lockfile: `Cargo.toml` allows any 0.78.x, so a regenerated lock
  # could resolve back to 0.78.3, whose loose atree requirement admits the
  # broken 0.5.3 again. Fails fast with a pointed message instead of leaving
  # someone to debug an abort with no stack.
  #
  # This is a proxy, not the real invariant — the version that actually matters
  # is atree's, which is not visible from Ruby. The TIFF test above is the
  # genuine protection; this one exists to name the cause when it trips.
  def test_linked_c2pa_rs_pins_a_known_good_atree
    major, minor, patch = C2PA.sdk_version.split(".").map(&:to_i)

    assert_operator [major, minor, patch] <=> [0, 78, 4], :>=, 0,
                    "c2pa-rs #{C2PA.sdk_version} predates the exact atree pin added in " \
                    "0.78.4 and can resolve atree 0.5.3, which aborts the process on TIFF input"
  end

  # ─── Gem metadata ──────────────────────────────────────────────────────────
  #
  # Released versions pointed homepage and source_code_uri at
  # github.com/carlosrodriguez/ruby-c2pa, which does not exist, so anyone
  # following the link from RubyGems got a 404.
  #
  # Whether a URL resolves cannot be checked without a network, and a test that
  # reaches the internet is a test that fails on a train. What is checked here
  # is internal consistency: the links agree with each other, so updating the
  # homepage cannot leave the others pointing somewhere else.

  def gemspec
    @gemspec ||= Gem::Specification.load(File.expand_path("../ruby-c2pa.gemspec", __dir__))
  end

  def test_gemspec_declares_a_homepage
    refute_nil gemspec.homepage
    assert_match(%r{\Ahttps://}, gemspec.homepage)
  end

  # The gemspec interpolates every metadata link from spec.homepage, so
  # asserting they agree with it would be a tautology — it cannot fail. The
  # real question is whether the homepage names the repository this code
  # actually lives in, and git can answer that.
  def test_gemspec_homepage_matches_the_git_remote
    remote = `git config --get remote.origin.url 2>/dev/null`.strip
    if remote.empty?
      # No remote to compare against — a tarball, or a checkout without one.
      # In CI there is always a remote, so a fallback there would mean this
      # test had quietly stopped comparing anything while still reporting
      # green. Fail rather than let that happen unnoticed.
      flunk "no git remote found, so the homepage was never checked" if ENV["CI"]

      assert_match(%r{\Ahttps://}, gemspec.homepage)
      return
    end

    expected = remote.sub(%r{\A(git@|https://)}, "")
                     .sub(":", "/")
                     .sub(%r{\.git\z}, "")
    assert_equal "https://#{expected}", gemspec.homepage,
                 "the gemspec points somewhere other than this repository"
  end

  # Every declared link must point at a file that is actually in the package,
  # or the link 404s from RubyGems exactly as the homepage used to.
  def test_gemspec_links_point_at_packaged_files
    gemspec.metadata.each do |name, url|
      next unless url.include?("/blob/main/")

      path = url.split("/blob/main/").last
      assert_includes gemspec.files, path,
                      "#{name} links to #{path}, which is not packaged"
      assert File.exist?(File.expand_path("../#{path}", __dir__)),
             "#{name} links to #{path}, which does not exist"
    end
  end

  # Trust verification must be on. c2pa-rs checks it by default, but the native
  # layer now supplies a Context, and a Context can turn it off — silently, in a
  # library whose purpose is establishing trust.
  #
  # The development certificates chain to a root nobody trusts, so a run with
  # trust checking enabled reports signingCredential.untrusted. If that status
  # disappears, trust is no longer being checked at all.
  def test_trust_verification_is_enabled
    read_back(created_manifest) do |_, result|
      codes = Array(result.dig("validation_results", "activeManifest", "failure"))
              .map { |failure| failure["code"] }
      assert_includes codes, "signingCredential.untrusted",
                      "the development certificates are untrusted, so this status must " \
                      "appear — its absence means trust checking is disabled"
    end
  end

  # ─── Trust configuration ───────────────────────────────────────────────────
  #
  # Before this existed the gem could not reach "Trusted" at all — c2pa-rs
  # checks trust by default, but only against roots it already knows, and there
  # was no way to add one. Anyone running a private PKI, which is a plausible
  # case for a content-authenticity library inside an organisation, got
  # signingCredential.untrusted with no recourse.
  #
  # Settings are global, so each test here resets them afterwards.

  # A chain whose root we keep, so it can be added as a trust anchor.
  def generate_trusted_chain(dir)
    require_relative "fixtures/generate_certs"
    key = -> { OpenSSL::PKey::EC.generate("prime256v1") }

    root_key = key.call
    root = CertificateFixtures.build("Root CA", nil, nil, root_key,
                                     CertificateFixtures::CA_EXTENSIONS)
    im_key = key.call
    im = CertificateFixtures.build(
      "Intermediate CA", root, root_key, im_key,
      CertificateFixtures::CA_EXTENSIONS.merge("authorityKeyIdentifier" => ["keyid:always", false])
    )
    ee_key = key.call
    ee = CertificateFixtures.build(
      "Signer", im, im_key, ee_key,
      CertificateFixtures::EE_EXTENSIONS.merge("authorityKeyIdentifier" => ["keyid:always", false])
    )

    chain = File.join(dir, "chain.pub")
    key_file = File.join(dir, "key.pem")
    root_file = File.join(dir, "root.pem")
    File.write(chain, ee.to_pem + im.to_pem)
    File.write(key_file, ee_key.private_to_pem)
    File.write(root_file, root.to_pem)
    [chain, key_file, root_file]
  end

  def state_signing_with(chain, key, dir, name)
    output = File.join(dir, "#{name}.jpg")
    C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
              certificate: chain, key: key, manifest: created_manifest)
    C2PA.read(file: output)["validation_state"]
  end

  def test_a_configured_trust_anchor_yields_a_trusted_result
    assert_certificates_present
    dir = Dir.mktmpdir
    chain, key, root = generate_trusted_chain(dir)

    assert_equal "Valid", state_signing_with(chain, key, dir, "before"),
                 "an unknown CA should not be trusted"

    C2PA.configure { |config| config.trust_anchors = root }

    assert_equal "Trusted", state_signing_with(chain, key, dir, "after"),
                 "adding the root as a trust anchor should produce Trusted"
  ensure
    C2PA.configure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def test_configuration_can_be_reset
    assert_certificates_present
    dir = Dir.mktmpdir
    chain, key, root = generate_trusted_chain(dir)

    C2PA.configure { |config| config.trust_anchors = root }
    assert_equal "Trusted", state_signing_with(chain, key, dir, "configured")

    C2PA.configure
    assert_equal "Valid", state_signing_with(chain, key, dir, "reset"),
                 "resetting should restore the default trust list"
  ensure
    C2PA.configure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def test_trust_anchors_accept_pem_text_as_well_as_a_path
    assert_certificates_present
    dir = Dir.mktmpdir
    chain, key, root = generate_trusted_chain(dir)

    C2PA.configure { |config| config.trust_anchors = File.read(root) }

    assert_equal "Trusted", state_signing_with(chain, key, dir, "inline")
  ensure
    C2PA.configure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def test_trust_verification_can_be_disabled
    assert_certificates_present
    C2PA.configure { |config| config.verify_trust = false }

    read_back(created_manifest) do |_, result|
      codes = Array(result.dig("validation_results", "activeManifest", "failure"))
              .map { |failure| failure["code"] }
      refute_includes codes, "signingCredential.untrusted",
                      "with trust checking off, nothing should be reported as untrusted"
    end
  ensure
    C2PA.configure
  end

  def test_an_unusable_trust_anchor_raises
    error = assert_raises(C2PA::InvalidSettingsError) do
      C2PA.configure { |config| config.trust_anchors = "/nonexistent/ca.pem" }
    end
    assert_match(/PEM text or a readable file/, error.message)
  ensure
    C2PA.configure
  end

  # Only what the caller sets is sent, so anything untouched keeps c2pa-rs's
  # default rather than being pinned to ours.
  def test_an_empty_configuration_sends_no_settings
    assert_equal "{}", C2PA::Config.new.to_json
  end

  def test_network_fetches_can_be_disabled
    config = C2PA::Config.new
    config.remote_manifest_fetch = false
    config.ocsp_fetch = false

    settings = JSON.parse(config.to_json)
    assert_equal false, settings.dig("verify", "remote_manifest_fetch")
    assert_equal false, settings.dig("verify", "ocsp_fetch")
  end

  # ─── Concurrency ───────────────────────────────────────────────────────────
  #
  # The native layer shares one c2pa-rs Context across calls. The entry points
  # it replaced read their settings from thread-local state, which is the
  # reason upstream deprecated them: a threaded application could see different
  # settings depending on which thread it signed from.
  #
  # Signing from several threads at once must produce correct, unmixed results.

  def test_signing_concurrently_produces_correct_results
    assert_certificates_present
    dir = Dir.mktmpdir

    results = 8.times.map do |i|
      Thread.new do
        output = File.join(dir, "concurrent-#{i}.jpg")
        manifest = C2PA::Manifest.new(title: "thread #{i}")
                                 .add_action(C2PA::Actions::CREATED,
                                             digital_source_type: DIGITAL_CAPTURE)
        C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
                  certificate: CERT, key: KEY, manifest: manifest)
        result = C2PA.read(file: output)
        [result["validation_state"],
         result["manifests"].fetch(result["active_manifest"])["title"]]
      end
    end.map(&:value)

    states, titles = results.transpose
    states.each { |state| assert_includes C2PA::VALID_STATES, state }
    assert_equal (0...8).map { |i| "thread #{i}" }.sort, titles.sort,
                 "titles were mixed between threads"
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  # ─── Packaging ─────────────────────────────────────────────────────────────
  #
  # 0.2.1 shipped 1.3 MB of Rust build-script output, because "ext/**/*.rs"
  # matched everything under ext/c2pa_native/target. The package contents
  # therefore depended on what had been compiled on the machine that ran
  # gem build.

  def test_the_gem_ships_no_build_artifacts
    artifacts = gemspec.files.select { |f| f.include?("/target/") }
    assert_empty artifacts, "build output must not be packaged"
  end

  def test_the_gem_ships_its_library_and_extension_sources
    %w[
      lib/c2pa.rb lib/c2pa/manifest.rb lib/c2pa/actions.rb
      lib/c2pa/digital_source_types.rb lib/c2pa/error.rb lib/c2pa/version.rb
      ext/c2pa_native/src/lib.rs ext/c2pa_native/Cargo.toml
      ext/c2pa_native/extconf.rb
    ].each do |path|
      assert_includes gemspec.files, path, "#{path} is missing from the package"
    end
  end

  # The extension is compiled at install time, so without a lockfile every
  # installer resolves the dependency tree afresh. That is how 0.2.1 shipped
  # against a broken atree and aborted the Ruby process on TIFF input.
  def test_the_gem_ships_a_lockfile_so_installs_are_reproducible
    assert_includes gemspec.files, "ext/c2pa_native/Cargo.lock"
  end

  def test_packaged_files_all_exist
    missing = gemspec.files.reject { |f| File.exist?(File.expand_path("../#{f}", __dir__)) }
    assert_empty missing, "packaged files that are not on disk"
  end

  # ─── Claim generator ───────────────────────────────────────────────────────
  #
  # Without a claim_generator_info of our own, c2pa-rs names itself, so every
  # asset this gem signed credited "c2pa-rs" and nothing identified the gem or
  # the application using it. The README even told callers to read that field
  # expecting their own application name.

  def test_signed_files_credit_the_gem_by_default
    read_back(created_manifest) do |active, _|
      info = Array(active["claim_generator_info"]).first
      assert_equal "ruby-c2pa", info["name"]
      assert_equal C2PA::VERSION, info["version"]
    end
  end

  def test_an_application_can_name_itself_as_the_generator
    manifest = C2PA::Manifest.new(title: "Test", generator_name: "Acme Editor",
                                  generator_version: "2.0")
                             .add_action(C2PA::Actions::CREATED, digital_source_type: DIGITAL_CAPTURE)

    read_back(manifest) do |active, _|
      info = Array(active["claim_generator_info"]).first
      assert_equal "Acme Editor", info["name"]
      assert_equal "2.0", info["version"]
    end
  end

  # c2pa-rs 0.78 permits exactly one entry, so the gem cannot sit alongside an
  # application as a second entry. It goes into a namespaced field instead,
  # which is how c2pa-rs records itself.
  def test_the_gem_is_still_recorded_when_an_application_names_itself
    manifest = C2PA::Manifest.new(title: "Test", generator_name: "Acme Editor")
                             .add_action(C2PA::Actions::CREATED, digital_source_type: DIGITAL_CAPTURE)

    read_back(manifest) do |active, _|
      info = Array(active["claim_generator_info"]).first
      assert_equal C2PA::VERSION, info[C2PA::Manifest::GEM_FIELD]
    end
  end

  def test_only_one_claim_generator_entry_is_emitted
    json = JSON.parse(created_manifest.to_json)
    assert_equal 1, json["claim_generator_info"].length,
                 "c2pa-rs rejects more than one entry: only 1 claim_generator_info allowed"
  end

  # ─── Editing an existing asset ─────────────────────────────────────────────
  #
  # A c2pa.opened action must reference its parent ingredient by hashed URI,
  # and that hash is computed over the ingredient assertion as c2pa-rs
  # serialises it. Ruby cannot build one — hand-written attempts fail at build
  # time with "missing field `hash`".
  #
  # Declaring the intent hands the problem to the SDK: it derives the parent
  # ingredient from the source file and wires the action to it. Without this,
  # the gem could not express an edit at all, and the README's chaining example
  # produced files that failed validation from the first release.

  def test_edit_intent_produces_a_valid_manifest
    manifest = C2PA::Manifest.new(title: "Edited photo", intent: :edit)
                             .add_action(C2PA::Actions::EDITED)

    read_back(manifest) do |_, result|
      assert_includes C2PA::VALID_STATES, result["validation_state"]
    end
  end

  def test_edit_intent_adds_an_opened_action_before_our_own
    manifest = C2PA::Manifest.new(title: "Edited photo", intent: :edit)
                             .add_action(C2PA::Actions::EDITED)
                             .add_action(C2PA::Actions::PUBLISHED)

    read_back(manifest) do |active, _|
      assert_equal %w[c2pa.opened c2pa.edited c2pa.published],
                   signed_actions(active).map { |action| action["action"] }
    end
  end

  # The reference the gem cannot construct: a URI plus a hash over the
  # ingredient. Its presence is the whole point of routing through the intent.
  def test_edit_intent_wires_the_opened_action_to_a_hashed_uri
    manifest = C2PA::Manifest.new(title: "Edited photo", intent: :edit)
                             .add_action(C2PA::Actions::EDITED)

    read_back(manifest) do |active, _|
      opened = signed_actions(active).first
      reference = opened.dig("parameters", "ingredients", 0)
      refute_nil reference, "the opened action carries no ingredient reference"
      refute_nil reference["url"],  "the reference has no URI"
      refute_nil reference["hash"], "the reference has no hash"
    end
  end

  def test_edit_intent_generates_a_parent_ingredient
    manifest = C2PA::Manifest.new(title: "Edited photo", intent: :edit)
                             .add_action(C2PA::Actions::EDITED)

    read_back(manifest) do |active, _|
      relationships = Array(active["ingredients"]).map { |i| i["relationship"] }
      assert_includes relationships, "parentOf"
    end
  end

  def test_opened_cannot_be_added_directly
    error = assert_raises(C2PA::InvalidManifestError) do
      C2PA::Manifest.new(title: "Test").add_action(C2PA::Actions::OPENED)
    end
    assert_match(/intent: :edit/, error.message, "the error should point at the supported route")
  end

  def test_unknown_intent_is_rejected
    error = assert_raises(C2PA::InvalidManifestError) do
      C2PA::Manifest.new(title: "Test", intent: :sideways)
    end
    assert_match(/unknown intent/i, error.message)
  end

  def test_omitting_the_intent_still_signs_a_creation
    read_back(created_manifest) do |active, _|
      assert_equal %w[c2pa.created], signed_actions(active).map { |a| a["action"] }
    end
  end

  # ─── Verify after signing ──────────────────────────────────────────────────
  #
  # c2pa-rs applies its rules when reading, not when writing, so signing
  # succeeds for manifests that every verifier rejects. Released versions of
  # this gem did exactly that, silently, for months.
  #
  # The guard is the structural fix: it does not depend on anyone anticipating
  # which rule will tighten next.

  # A manifest that bypasses Manifest entirely, so the guard is exercised as an
  # independent backstop rather than a restatement of the builder's rules. The
  # opened-without-ingredient shape is rejected by every c2pa-rs this gem has
  # supported, so it stays meaningful across version bumps.
  def unchecked_invalid_manifest
    raw = Object.new
    def raw.to_json
      JSON.generate("title" => "unchecked",
                    "assertions" => [{ "label" => "c2pa.actions.v2",
                                       "data" => { "actions" => [{ "action" => "c2pa.opened" }] } }])
    end
    raw
  end

  def test_signing_an_invalid_manifest_raises_and_removes_the_output
    assert_certificates_present
    dir = Dir.mktmpdir
    output = File.join(dir, "signed.jpg")

    error = assert_raises(C2PA::SigningError) do
      C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
                certificate: CERT, key: KEY, manifest: unchecked_invalid_manifest)
    end

    assert_match(/failed verification/, error.message)
    assert_match(/assertion\.action\.ingredientMismatch/, error.message,
                 "the failure codes should be named, not just the state")
    refute File.exist?(output), "an invalid signed file must not be left on disk"
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def test_verify_false_keeps_the_invalid_file_for_inspection
    assert_certificates_present
    dir = Dir.mktmpdir
    output = File.join(dir, "signed.jpg")

    C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
              certificate: CERT, key: KEY, manifest: unchecked_invalid_manifest,
              verify: false)

    assert File.exist?(output), "verify: false should leave the file alone"
    assert_equal "Invalid", C2PA.read(file: output)["validation_state"]
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def test_a_valid_manifest_passes_the_guard_and_returns_the_output_path
    assert_certificates_present
    dir = Dir.mktmpdir
    output = File.join(dir, "signed.jpg")

    returned = C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
                         certificate: CERT, key: KEY, manifest: created_manifest)

    assert_equal output, returned
    assert File.exist?(output)
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  # The development certificates are untrusted by design, so every signing test
  # here runs against state "Valid" rather than "Trusted". A guard accepting
  # only "Valid" would pass this whole suite and then reject the correctly
  # trusted files real users produce.
  def test_trusted_is_accepted_as_well_as_valid
    assert_includes C2PA::VALID_STATES, "Valid"
    assert_includes C2PA::VALID_STATES, "Trusted"
  end

  # ─── Conformance: what c2pa-rs actually enforces ───────────────────────────
  #
  # These sign manifests the builder would not produce, bypassing it entirely,
  # and record c2pa-rs's verdict. Two reasons:
  #
  # 1. Rules this gem enforces must be pinned to a rule the SDK actually has.
  #    A test asserting "the builder raises" only proves we implemented an
  #    opinion, not that the opinion is correct.
  #
  # 2. Rules the SDK does *not* enforce are recorded too, so that if upstream
  #    starts enforcing one, we find out from a failing test rather than from
  #    a user whose files stopped validating.
  #
  # Verdicts below are from c2pa-rs 0.78.8. Rules introduced in 0.90 are
  # deliberately absent — asserting them here would fail for the right reason
  # at the wrong time. They arrive with the upgrade, in #18 and #19.

  ACTIONS_LABEL = "c2pa.actions.v2".freeze
  # A c2pa.created without a digitalSourceType is malformed on 0.90, so using a
  # bare one here would report assertion.action.malformed for every case and
  # hide the rule actually being tested.
  CREATED_ACTION = {
    "action" => "c2pa.created",
    "digitalSourceType" => C2PA::DigitalSourceTypes::DIGITAL_CAPTURE
  }.freeze
  PARENT_INGREDIENT = {
    "title" => "original.jpg", "format" => "image/jpeg",
    "instance_id" => "xmp:iid:original", "relationship" => "parentOf"
  }.freeze

  # Sign a definition the builder would refuse, so c2pa-rs can rule on it.
  def failure_codes_for(actions, ingredients: nil)
    assert_certificates_present

    definition = {
      "title" => "conformance",
      "assertions" => [{ "label" => ACTIONS_LABEL, "data" => { "actions" => actions } }]
    }
    definition["ingredients"] = ingredients if ingredients

    unchecked = Object.new
    unchecked.define_singleton_method(:to_json) { JSON.generate(definition) }

    dir = Dir.mktmpdir
    output = File.join(dir, "signed.jpg")
    # verify: false — the point of this helper is to produce invalid files and
    # inspect them, which is exactly what the guard exists to prevent.
    C2PA.sign(file: File.join(FIXTURES, "tiny.jpg"), output: output,
              certificate: CERT, key: KEY, manifest: unchecked, verify: false)

    Array(C2PA.read(file: output).dig("validation_results", "activeManifest", "failure"))
      .map { |failure| failure["code"] }
      .reject { |code| code == "signingCredential.untrusted" }
      .uniq
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  ENFORCED_RULES = {
    "first action is not created or opened" => {
      actions: [{ "action" => "c2pa.edited" }],
      code:    "assertion.action.malformed"
    },
    "an action carries an empty action string" => {
      actions: [CREATED_ACTION, { "action" => "" }],
      code:    "assertion.action.malformed"
    },
    "opened without ingredient parameters" => {
      actions: [{ "action" => "c2pa.opened" }],
      code:    "assertion.action.ingredientMismatch"
    },
    "placed without ingredient parameters" => {
      actions: [CREATED_ACTION, { "action" => "c2pa.placed" }],
      code:    "assertion.action.ingredientMismatch"
    },
    "removed without ingredient parameters" => {
      actions: [CREATED_ACTION, { "action" => "c2pa.removed" }],
      code:    "assertion.action.ingredientMismatch"
    }
  }.freeze

  ENFORCED_RULES.each do |description, expectation|
    define_method("test_c2pa_rs_rejects_#{description.tr(' ', '_')}") do
      assert_includes failure_codes_for(expectation[:actions]), expectation[:code],
                      "c2pa-rs #{C2PA.sdk_version} no longer reports " \
                      "#{expectation[:code]} for #{description}"
    end
  end

  def test_a_correct_manifest_produces_no_action_failures
    assert_empty failure_codes_for([CREATED_ACTION]),
                 "a correct manifest should produce no failures beyond the untrusted test cert"
  end

  # Supplying the ingredient is not enough on its own: the opened action has to
  # reference it by hashed URI, which only the native layer can construct. This
  # is why the edit workflow is unavailable — see #11.
  def test_opened_is_rejected_even_with_a_parent_ingredient
    assert_includes failure_codes_for([{ "action" => "c2pa.opened" }],
                                      ingredients: [PARENT_INGREDIENT]),
                    "assertion.action.ingredientMismatch"
  end

  # An empty actions array does not merely fail validation — the resulting file
  # cannot be read back at all.
  def test_an_empty_actions_array_produces_an_unreadable_file
    assert_raises(C2PA::ReadError) { failure_codes_for([]) }
  end

  # ─── Conformance: rules c2pa-rs does NOT enforce ───────────────────────────
  #
  # Recorded so that a change upstream surfaces here. Each of these would be a
  # reasonable rule for the gem to enforce anyway; what must not happen is for
  # us to claim the SDK backs us up when it does not.

  # The specification says created must come first, and claim.rs says so in a
  # comment, but the check compares the actions-assertion index rather than the
  # action index — so a repeated created inside one assertion is not flagged.
  def test_created_appearing_second_is_not_flagged_upstream
    refute_includes failure_codes_for([CREATED_ACTION, CREATED_ACTION]),
                    "assertion.action.malformed",
                    "upstream now flags a repeated created; the gem can rely on it"
  end

  # c2pa-rs does not validate action names, which is why C2PA::Actions has no
  # external oracle and its test can only check for duplicates and namespacing.
  def test_unknown_action_names_are_not_flagged_upstream
    assert_empty failure_codes_for([CREATED_ACTION, { "action" => "acme.nonsense" }]),
                 "upstream now validates action names; C2PA::Actions could be checked against it"
  end

  # These two arrived with c2pa-rs 0.90. Until the bump they were recorded as
  # not-yet-enforced; the canaries fired on upgrade, which is what they were
  # for. They are now asserted as real rules.
  def test_created_without_a_digital_source_type_is_rejected
    assert_includes failure_codes_for([{ "action" => "c2pa.created" }]),
                    "assertion.action.malformed"
  end

  def test_translated_without_languages_is_rejected
    assert_includes failure_codes_for([CREATED_ACTION, { "action" => "c2pa.translated" }]),
                    "assertion.action.malformed"
  end

  # The other half: what the builder demands must actually satisfy c2pa-rs.
  def test_translated_with_languages_signs_clean
    manifest = created_manifest.add_action(
      C2PA::Actions::TRANSLATED,
      parameters: { "sourceLanguage" => "en-US", "targetLanguage" => "fr-FR" }
    )

    read_back(manifest) do |_, result|
      assert_includes C2PA::VALID_STATES, result["validation_state"]
    end
  end

  # Builder-side enforcement, so the failure arrives at the call site rather
  # than after signing.
  def test_builder_requires_a_digital_source_type_for_created
    error = assert_raises(C2PA::InvalidManifestError) do
      C2PA::Manifest.new(title: "Test").add_action(C2PA::Actions::CREATED)
    end
    assert_match(/digital_source_type/, error.message)
    assert_match(/UNSPECIFIED/, error.message, "the error should offer an honest opt-out")
  end

  def test_builder_requires_languages_for_translated
    assert_raises(C2PA::InvalidManifestError) do
      created_manifest.add_action(C2PA::Actions::TRANSLATED)
    end
  end

  def test_unspecified_source_type_is_accepted
    manifest = C2PA::Manifest.new(title: "Test")
                             .add_action(C2PA::Actions::CREATED,
                                         digital_source_type: C2PA::DigitalSourceTypes::UNSPECIFIED)

    read_back(manifest) do |_, result|
      assert_includes C2PA::VALID_STATES, result["validation_state"]
    end
  end

  # ─── Character and encoding handling ───────────────────────────────────────
  #
  # Text passes through Ruby JSON generation, the magnus boundary, and CBOR
  # encoding inside the C2PA container. Any of those could mangle it.
  #
  # Mirrors "should preserve JSON assertion characters without escaping" in
  # contentauth/c2pa-js Builder.spec.ts.

  # Built from codepoints so this file contains no literal control bytes.
  def codepoint(number) = number.chr(Encoding::UTF_8)

  def assert_title_survives(title, message)
    read_back(created_manifest(title: title)) do |active, _|
      assert_equal title, active["title"], message
    end
  end

  def test_quotes_and_backslashes_survive_signing
    assert_title_survives(%q(He said "hi" \ then \\ left), "quotes or backslashes were mangled")
  end

  def test_non_ascii_scripts_survive_signing
    assert_title_survives("Solnedgång 日没 Закат مغيب", "non-ASCII text was mangled")
  end

  def test_emoji_survive_signing
    # A ZWJ sequence is several codepoints the reader must not split or reorder.
    family = [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467].map { |c| codepoint(c) }.join
    assert_title_survives("sunset #{codepoint(0x1F305)} family #{family}", "emoji were mangled")
  end

  def test_control_characters_survive_signing
    title = "bell#{codepoint(7)} del#{codepoint(127)} vtab#{codepoint(11)}"
    assert_title_survives(title, "control characters were mangled")
  end

  # A NUL is the classic place for a Rust/C boundary to truncate a string.
  def test_embedded_nul_survives_signing
    assert_title_survives("before#{codepoint(0)}after", "text was truncated at the NUL")
  end

  def test_separators_and_bom_survive_signing
    title = "#{codepoint(0xFEFF)}line#{codepoint(0x2028)}separator"
    assert_title_survives(title, "BOM or line separator was mangled")
  end

  def test_long_title_survives_signing
    assert_title_survives("A" * 4096, "a 4 KB title did not survive")
  end

  def test_json_like_text_is_not_reinterpreted
    assert_title_survives('{"not":"json","really":[1,2]}', "JSON-looking text was reinterpreted")
  end

  def test_special_characters_in_assertion_data_survive_signing
    description = "quotes \"here\", a \\ backslash,\na newline and\ta tab"
    manifest = created_manifest.add_assertion(
      label: "stds.schema-org.CreativeWork",
      data: { "@context" => "https://schema.org", "description" => description }
    )

    read_back(manifest) do |active, _|
      creative_work = active.fetch("assertions")
                            .find { |a| a["label"] == "stds.schema-org.CreativeWork" }
      assert_equal description, creative_work.dig("data", "description")
    end
  end

  # Invalid UTF-8 is the one input that cannot round-trip. It must still fail as
  # a C2PA::Error, since the README tells callers that rescuing C2PA::Error is
  # sufficient. See #28.
  def test_invalid_utf8_raises_a_c2pa_error
    title = (+"bad").concat(255.chr).concat("byte")
    manifest = C2PA::Manifest.new(title: title).add_action(C2PA::Actions::CREATED, digital_source_type: DIGITAL_CAPTURE)

    error = assert_raises(C2PA::InvalidManifestError) { manifest.to_json }
    assert_kind_of C2PA::Error, error, "callers rescue C2PA::Error and must catch this"
    assert_match(/\\xFF/i, error.message, "the offending byte should still be identified")
  end

  # ─── Round trip: what actually lands in the signed file ────────────────────

  def test_title_survives_signing
    read_back(created_manifest(title: "Sunset over the bay")) do |active, _|
      assert_equal "Sunset over the bay", active["title"]
    end
  end

  def test_action_order_survives_signing
    manifest = created_manifest.add_action(C2PA::Actions::EDITED)
                               .add_action(C2PA::Actions::PUBLISHED)

    read_back(manifest) do |active, _|
      assert_equal %w[c2pa.created c2pa.edited c2pa.published],
                   signed_actions(active).map { |action| action["action"] }
    end
  end

  def test_default_software_agent_survives_signing
    read_back(created_manifest) do |active, _|
      assert_equal "ruby-c2pa/#{C2PA::VERSION}",
                   signed_actions(active).first["softwareAgent"]
    end
  end

  def test_custom_software_agent_survives_signing
    manifest = C2PA::Manifest.new(title: "Test")
                             .add_action(C2PA::Actions::CREATED, digital_source_type: DIGITAL_CAPTURE,
                                         software_agent: "Acme Editor/2.0")

    read_back(manifest) do |active, _|
      assert_equal "Acme Editor/2.0", signed_actions(active).first["softwareAgent"]
    end
  end

  def test_when_time_survives_signing
    manifest = C2PA::Manifest.new(title: "Test")
                             .add_action(C2PA::Actions::CREATED, digital_source_type: DIGITAL_CAPTURE,
                                         when_time: "2026-03-17T10:00:00Z")

    read_back(manifest) do |active, _|
      assert_equal "2026-03-17T10:00:00Z", signed_actions(active).first["when"]
    end
  end

  # Optional at this c2pa-rs version, but it must still survive when supplied.
  def test_digital_source_type_survives_signing
    source_type = "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
    manifest = C2PA::Manifest.new(title: "Test")
                             .add_action(C2PA::Actions::CREATED, digital_source_type: DIGITAL_CAPTURE,
                                         digital_source_type: source_type)

    read_back(manifest) do |active, _|
      assert_equal source_type, signed_actions(active).first["digitalSourceType"]
    end
  end

  def test_custom_assertion_survives_signing
    manifest = created_manifest.add_assertion(
      label: "stds.schema-org.CreativeWork",
      data: { "@context" => "https://schema.org", "@type" => "CreativeWork",
              "author" => [{ "@type" => "Person", "name" => "Jane Smith" }] }
    )

    read_back(manifest) do |active, _|
      creative_work = active.fetch("assertions")
                            .find { |a| a["label"] == "stds.schema-org.CreativeWork" }
      refute_nil creative_work, "custom assertion missing from the signed file"
      assert_equal "Jane Smith", creative_work.dig("data", "author", 0, "name")
    end
  end

  def test_ingredient_survives_signing
    manifest = created_manifest.add_ingredient(
      title:       "original.jpg",
      format:      "image/jpeg",
      instance_id: "xmp:iid:original-uuid-here"
    )

    read_back(manifest) do |active, _|
      ingredient = Array(active["ingredients"]).first
      refute_nil ingredient, "ingredient missing from the signed file"
      assert_equal "original.jpg", ingredient["title"]
      assert_equal "parentOf",     ingredient["relationship"]
    end
  end
end
