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

  def test_signs_a_jpeg_and_reads_it_back
    sign_fixture("tiny.jpg", created_manifest(title: "JPEG smoke test")) do |output|
      assert File.size?(output), "signed file is empty"
      result = C2PA.read(file: output)
      active = result["manifests"].fetch(result["active_manifest"])
      assert_equal "JPEG smoke test", active["title"]
    end
  end

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
