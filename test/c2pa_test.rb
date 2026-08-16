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

  def created_manifest(title: "Test")
    C2PA::Manifest.new(title: title).add_action(C2PA::Actions::CREATED)
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
    manifest = C2PA::Manifest.new(title: "Test").add_action(C2PA::Actions::CREATED)

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
                             .add_action(C2PA::Actions::CREATED,
                                         software_agent: "Acme Editor/2.0")

    read_back(manifest) do |active, _|
      assert_equal "Acme Editor/2.0", signed_actions(active).first["softwareAgent"]
    end
  end

  def test_when_time_survives_signing
    manifest = C2PA::Manifest.new(title: "Test")
                             .add_action(C2PA::Actions::CREATED,
                                         when_time: "2026-03-17T10:00:00Z")

    read_back(manifest) do |active, _|
      assert_equal "2026-03-17T10:00:00Z", signed_actions(active).first["when"]
    end
  end

  # Optional at this c2pa-rs version, but it must still survive when supplied.
  def test_digital_source_type_survives_signing
    source_type = "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
    manifest = C2PA::Manifest.new(title: "Test")
                             .add_action(C2PA::Actions::CREATED,
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
