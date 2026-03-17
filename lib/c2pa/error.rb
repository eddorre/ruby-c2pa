module C2PA
  class Error < StandardError; end
  class SigningError < Error; end
  class ReadError < Error; end
  class InvalidManifestError < Error; end
end
