require "json"
require_relative "c2pa/version"
require_relative "c2pa/error"
require "c2pa/c2pa_native"

module C2PA
  # Sign a file with a C2PA manifest.
  #
  # @param file        [String]  path to the input file
  # @param certificate [String]  path to a PEM-encoded X.509 certificate (chain)
  # @param key         [String]  path to a PEM-encoded private key
  # @param output      [String]  path for the signed output; defaults to in-place
  # @param algorithm   [String]  signing algorithm (default: "es256")
  # @param manifest    [Hash]    manifest definition; omit for a minimal default
  # @return            [String]  the output path
  #
  # @example In-place signing
  #   C2PA.sign(file: "photo.jpg", certificate: "cert.pem", key: "key.pem")
  #
  # @example With explicit output and manifest
  #   C2PA.sign(
  #     file:        "photo.jpg",
  #     output:      "photo_signed.jpg",
  #     certificate: "cert.pem",
  #     key:         "key.pem",
  #     algorithm:   "ps256",
  #     manifest:    { title: "My Photo", assertions: [] }
  #   )
  def self.sign(file:, certificate:, key:, output: nil, algorithm: "es256", manifest: nil)
    destination = output || file
    manifest_json = manifest ? JSON.generate(manifest) : nil

    Native.sign_file(file, destination, certificate, key, algorithm, manifest_json)
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
  #   puts manifest["title"]
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
