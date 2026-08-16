# Generate the signing certificates used by the test suite.
#
# Every algorithm the gem accepts needs a key of the matching type, so the
# suite generates its own rather than depending on someone else's fixtures.
# Ruby's OpenSSL binding is used instead of the openssl CLI because macOS ships
# LibreSSL, which cannot generate Ed25519 keys.
#
# The certificates are development material: the chains are rooted in a CA
# generated here, so signed assets carry a signingCredential.untrusted warning.
# That warning does not make a manifest invalid.
#
# c2pa-rs enforces a certificate profile (crypto/cose/certificate_profile.rs).
# An end-entity certificate is rejected unless it carries, at minimum:
#
#   * Basic Constraints CA:FALSE, critical
#   * Key Usage with digitalSignature or nonRepudiation, critical
#   * Extended Key Usage naming an allowed purpose, critical, and never "any"
#   * Subject Key Identifier
#   * Authority Key Identifier          <- easy to miss; openssl x509 -req
#                                          omits it and the cert is rejected
#   * no unhandled critical extensions

require "openssl"
require "fileutils"

module CertificateFixtures
  DIR = File.expand_path("certs", __dir__)

  SUBJECT = "/O=ruby-c2pa test suite/OU=FOR TESTING ONLY".freeze
  LIFETIME = 10 * 365 * 24 * 60 * 60 # seconds

  # One key type per row; the PS algorithms share a single RSA key, since they
  # differ only in the digest used at signing time.
  KEY_TYPES = {
    "es256"   => -> { OpenSSL::PKey::EC.generate("prime256v1") },
    "es384"   => -> { OpenSSL::PKey::EC.generate("secp384r1") },
    "es512"   => -> { OpenSSL::PKey::EC.generate("secp521r1") },
    "ps256"   => -> { OpenSSL::PKey::RSA.new(2048) },
    "ed25519" => -> { OpenSSL::PKey.generate_key("ED25519") }
  }.freeze

  # Algorithms the gem accepts, mapped to the key they can be used with.
  ALGORITHMS = {
    "es256" => "es256", "es384" => "es384", "es512" => "es512",
    "ps256" => "ps256", "ps384" => "ps256", "ps512" => "ps256",
    "ed25519" => "ed25519"
  }.freeze

  module_function

  # Ed25519 signs directly and rejects a digest; everything else needs one.
  def digest_for(key)
    key.oid == "ED25519" ? nil : OpenSSL::Digest.new("SHA256")
  end

  def build(name, issuer_cert, issuer_key, key, extensions)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2 # X.509 v3
    cert.serial = OpenSSL::BN.rand(64)
    cert.subject = OpenSSL::X509::Name.parse("#{SUBJECT}/CN=#{name}")
    cert.issuer = issuer_cert ? issuer_cert.subject : cert.subject
    cert.public_key = key
    cert.not_before = Time.now - 86_400
    cert.not_after = Time.now + LIFETIME

    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = issuer_cert || cert
    extensions.each { |ext, (value, critical)| cert.add_extension(factory.create_extension(ext, value, critical)) }

    cert.sign(issuer_key || key, digest_for(issuer_key || key))
    cert
  end

  CA_EXTENSIONS = {
    "basicConstraints" => ["CA:TRUE", true],
    "keyUsage" => ["digitalSignature,keyCertSign,cRLSign", true],
    "subjectKeyIdentifier" => ["hash", false]
  }.freeze

  EE_EXTENSIONS = {
    "basicConstraints" => ["CA:FALSE", true],
    "keyUsage" => ["digitalSignature,nonRepudiation", true],
    "extendedKeyUsage" => ["emailProtection", true],
    "subjectKeyIdentifier" => ["hash", false]
  }.freeze

  # A root, an intermediate and an end-entity, mirroring how production chains
  # are shaped. The chain file omits the root, as c2pa-rs expects.
  def generate(name, key_factory)
    root_key = key_factory.call
    root = build("Root CA", nil, nil, root_key, CA_EXTENSIONS)

    im_key = key_factory.call
    im = build("Intermediate CA", root, root_key, im_key,
               CA_EXTENSIONS.merge("authorityKeyIdentifier" => ["keyid:always", false]))

    ee_key = key_factory.call
    ee = build("Signer", im, im_key, ee_key,
               EE_EXTENSIONS.merge("authorityKeyIdentifier" => ["keyid:always", false]))

    FileUtils.mkdir_p(DIR)
    File.write(File.join(DIR, "#{name}.pub"), ee.to_pem + im.to_pem)
    File.write(File.join(DIR, "#{name}.pem"), ee_key.private_to_pem)
  end

  def generate_all(force: false)
    KEY_TYPES.each do |name, factory|
      chain = File.join(DIR, "#{name}.pub")
      key = File.join(DIR, "#{name}.pem")
      next if !force && File.size?(chain) && File.size?(key)

      print "  #{name}... "
      generate(name, factory)
      puts "ok"
    end
  end
end
