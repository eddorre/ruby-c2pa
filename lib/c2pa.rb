require "json"
require_relative "c2pa/version"
require_relative "c2pa/error"
require_relative "c2pa/actions"
require_relative "c2pa/manifest"
require "c2pa/c2pa_native"

module C2PA
  # Sign a file with a C2PA manifest.
  #
  # @param file        [String]          path to the input file
  # @param output      [String]          path for the signed output file (must not already exist)
  # @param certificate [String]          path to a PEM-encoded X.509 certificate (chain)
  # @param key         [String]          path to a PEM-encoded private key
  # @param algorithm   [String]          signing algorithm (default: "es256")
  # @param manifest    [C2PA::Manifest]  the manifest to embed
  # @return            [String]          the output path
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
  def self.sign(file:, output:, certificate:, key:, algorithm: "es256", manifest:)
    Native.sign_file(file, output, certificate, key, algorithm, manifest.to_json)
  rescue RuntimeError => e
    raise SigningError, e.message
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
end
