require "minitest/autorun"
require "tmpdir"
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

  def test_manifest_actions_constants
    assert_equal "c2pa.created",   C2PA::Actions::CREATED
    assert_equal "c2pa.edited",    C2PA::Actions::EDITED
    assert_equal "c2pa.published", C2PA::Actions::PUBLISHED
  end

  def test_manifest_chaining
    manifest = C2PA::Manifest.new(title: "Test")
      .add_action(C2PA::Actions::CREATED)
      .add_action(C2PA::Actions::EDITED)

    json = JSON.parse(manifest.to_json)
    actions = json["assertions"].first["data"]["actions"]
    assert_equal 2, actions.length
    assert_equal "c2pa.created", actions[0]["action"]
    assert_equal "c2pa.edited",  actions[1]["action"]
  end

  def test_manifest_software_agent_defaults_to_gem
    manifest = C2PA::Manifest.new(title: "Test").add_action(C2PA::Actions::CREATED)
    json = JSON.parse(manifest.to_json)
    agent = json["assertions"].first["data"]["actions"].first["softwareAgent"]
    assert_equal "ruby-c2pa/#{C2PA::VERSION}", agent
  end

  def test_manifest_software_agent_can_be_overridden
    manifest = C2PA::Manifest.new(title: "Test")
      .add_action(C2PA::Actions::CREATED, software_agent: "Acme Editor/2.0")
    json = JSON.parse(manifest.to_json)
    agent = json["assertions"].first["data"]["actions"].first["softwareAgent"]
    assert_equal "Acme Editor/2.0", agent
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

  def test_manifest_add_assertion
    manifest = C2PA::Manifest.new(title: "Test")
      .add_action(C2PA::Actions::CREATED)
      .add_assertion(
        label: "stds.schema-org.CreativeWork",
        data: { "@context" => "https://schema.org", "@type" => "CreativeWork" }
      )
    json = JSON.parse(manifest.to_json)
    labels = json["assertions"].map { |a| a["label"] }
    assert_includes labels, "c2pa.actions.v2"
    assert_includes labels, "stds.schema-org.CreativeWork"
  end
end
