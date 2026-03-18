require "minitest/autorun"
require "c2pa"

class C2PATest < Minitest::Test
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
