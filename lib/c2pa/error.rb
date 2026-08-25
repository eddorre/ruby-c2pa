module C2PA
  class Error < StandardError; end
  class SigningError < Error; end
  class ReadError < Error; end
  class InvalidManifestError < Error; end

  # Raised when C2PA.configure is given something it cannot use.
  class InvalidSettingsError < Error; end
end
