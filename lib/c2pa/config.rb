require "json"

module C2PA
  # Settings that govern how c2pa-rs validates.
  #
  # These reach the SDK through its Context, which is rebuilt whenever they
  # change. Signing already in flight on another thread continues against the
  # settings it started with.
  #
  # Defaults are c2pa-rs's own, so a gem that never calls C2PA.configure
  # behaves exactly as it did before this existed.
  class Config
    # Additional root certificates to trust, as a PEM bundle. Use this for a
    # private or enterprise CA: a certificate chaining to one of these
    # validates as "Trusted" rather than carrying signingCredential.untrusted.
    attr_accessor :trust_anchors

    # The trust list proper — normally the C2PA-recognised anchors. Setting
    # this replaces that list rather than adding to it, so prefer
    # trust_anchors unless you mean to substitute the whole thing.
    attr_accessor :trust_list

    # Explicitly allowed certificates, as a PEM bundle.
    attr_accessor :allowed_certificates

    # Whether to check certificates against the trust list at all.
    #
    # Turning this off means nothing is ever reported as untrusted, which in a
    # library for establishing provenance is rarely what you want. It exists
    # for offline and air-gapped environments.
    attr_accessor :verify_trust

    # Whether reading an asset may fetch a manifest over the network.
    # c2pa-rs defaults this to true, so reading can make an outbound request.
    attr_accessor :remote_manifest_fetch

    # Whether to check certificate revocation over OCSP, which also makes
    # network requests.
    attr_accessor :ocsp_fetch

    def initialize
      @trust_anchors = nil
      @trust_list = nil
      @allowed_certificates = nil
      @verify_trust = nil
      @remote_manifest_fetch = nil
      @ocsp_fetch = nil
    end

    # The settings document c2pa-rs expects.
    #
    # Only values that were actually set are included, so anything left alone
    # keeps the SDK's default rather than being pinned to ours.
    #
    # @return [String] JSON
    def to_json
      trust = {}
      trust["user_anchors"] = read_pem(@trust_anchors)        unless @trust_anchors.nil?
      trust["trust_anchors"] = read_pem(@trust_list)          unless @trust_list.nil?
      trust["allowed_list"] = read_pem(@allowed_certificates) unless @allowed_certificates.nil?

      verify = {}
      verify["verify_trust"] = @verify_trust                   unless @verify_trust.nil?
      verify["remote_manifest_fetch"] = @remote_manifest_fetch unless @remote_manifest_fetch.nil?
      verify["ocsp_fetch"] = @ocsp_fetch                       unless @ocsp_fetch.nil?

      settings = {}
      settings["trust"] = trust unless trust.empty?
      settings["verify"] = verify unless verify.empty?

      JSON.generate(settings)
    end

    private

    # Accept either PEM text or a path to a file containing it, since callers
    # naturally have one or the other.
    def read_pem(value)
      string = value.to_s
      return string if string.include?("BEGIN CERTIFICATE")

      unless File.exist?(string)
        raise InvalidSettingsError,
              "expected PEM text or a readable file, got #{string.inspect}"
      end

      File.read(string)
    end
  end
end
