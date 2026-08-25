require "json"
require_relative "c2pa/version"
require_relative "c2pa/error"
require_relative "c2pa/actions"
require_relative "c2pa/digital_source_types"
require_relative "c2pa/manifest"
require "c2pa/c2pa_native"

module C2PA
  # Validation states that mean a signed asset is good.
  #
  # "Trusted" is "Valid" plus a signing certificate that chains to a root in
  # the active trust list. Accepting only "Valid" would reject exactly the
  # production files that are most correct.
  VALID_STATES = %w[Valid Trusted].freeze

  # Sign a file with a C2PA manifest.
  #
  # @param file        [String]          path to the input file
  # @param output      [String]          path for the signed output file (must not already exist)
  # @param certificate [String]          path to a PEM-encoded X.509 certificate (chain)
  # @param key         [String]          path to a PEM-encoded private key
  # @param algorithm   [String]          signing algorithm (default: "es256")
  # @param manifest    [C2PA::Manifest]  the manifest to embed
  # @param verify      [Boolean]         read the signed file back and confirm it
  #                                      validates (default: true)
  # @return            [String]          the output path
  # @raise [C2PA::SigningError] if signing fails, or if the signed file does not validate
  #
  # @example
  #   manifest = C2PA::Manifest.new(title: "Sunset over the bay")
  #   manifest.add_action(C2PA::Actions::CREATED)
  #
  #   C2PA.sign(
  #     file:        "photo.jpg",
  #     output:      "photo_signed.jpg",
  #     certificate: "cert.pem",
  #     key:         "key.pem",
  #     manifest:    manifest
  #   )
  def self.sign(file:, output:, certificate:, key:, algorithm: "es256", manifest:, verify: true)
    manifest_json = manifest.to_json

    raise SigningError, "Source file not found: '#{file}'"             unless File.exist?(file)
    raise SigningError, "Certificate file not found: '#{certificate}'" unless File.exist?(certificate)
    raise SigningError, "Key file not found: '#{key}'"                 unless File.exist?(key)
    raise SigningError, "Output file already exists: '#{output}'"      if File.exist?(output)

    begin
      # to_json is the only thing genuinely required of a manifest, so an
      # object that provides just that still signs — as a creation.
      intent = manifest.respond_to?(:intent) ? manifest.intent&.to_s : nil
      Native.sign_file(file, output, certificate, key, algorithm, manifest_json, intent)
    rescue RuntimeError => e
      raise SigningError, e.message
    end

    verify_signed_output!(output) if verify

    output
  end

  # Read the C2PA manifest embedded in a signed file.
  #
  # @param file [String] path to the signed file
  # @return     [Hash]   parsed manifest JSON
  # @raise      [C2PA::ReadError] if the file has no valid manifest
  #
  # @example
  #   manifest = C2PA.read(file: "photo_signed.jpg")
  #   active = manifest["manifests"][manifest["active_manifest"]]
  #   puts active["title"]
  def self.read(file:)
    JSON.parse(Native.read_file(file))
  rescue RuntimeError => e
    raise ReadError, e.message
  end

  # Return the version of the underlying c2pa-rs SDK.
  #
  # @return [String]
  def self.sdk_version
    Native.sdk_version
  end

  # Read a freshly signed file back and confirm it actually validates.
  #
  # Signing reports success for manifests that verifiers reject. c2pa-rs
  # applies its rules when reading, not when writing, so without this the gem
  # hands back a path to a file that fails everywhere else — which is what
  # released versions did, for years, silently.
  #
  # The rejected file is deleted rather than left behind, so a failed sign
  # cannot leave something shippable on disk.
  #
  # @param output [String] path to the signed file
  # @raise [C2PA::SigningError] if the file does not validate
  def self.verify_signed_output!(output)
    result =
      begin
        read(file: output)
      rescue ReadError => e
        discard(output)
        raise SigningError, "signed file failed verification: could not read it back: #{e.message}"
      end

    state = result["validation_state"]
    return if VALID_STATES.include?(state)

    failures = Array(result.dig("validation_results", "activeManifest", "failure"))
               .map { |failure| "#{failure["code"]} (#{failure["explanation"]})" }
    detail = failures.empty? ? "no failure detail reported" : failures.uniq.join(", ")

    discard(output)
    raise SigningError,
          "signed file failed verification: validation_state=#{state.inspect}, #{detail}. " \
          "The output file has been removed. Pass verify: false to keep it for inspection."
  end
  private_class_method :verify_signed_output!

  # Remove a file this library created and is about to reject.
  def self.discard(path)
    File.delete(path) if File.exist?(path)
  rescue SystemCallError
    # Leaving the file behind is better than masking the original failure.
    nil
  end
  private_class_method :discard
end
