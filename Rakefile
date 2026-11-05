require "rb_sys/extensiontask"
require "rake/testtask"

GEMSPEC = Gem::Specification.load("ruby-c2pa.gemspec")

# Precompiled gems are built for these platforms by the release workflow, so
# installing on them needs no Rust toolchain. Any other platform falls back to
# the source gem and compiles at install time, as every release did before.
#
# macOS is absent because openssl-src fails to build OpenSSL under the osxcross
# toolchain rb-sys-dock uses for Darwin targets.
CROSS_PLATFORMS = %w[
  x86_64-linux
  x86_64-linux-musl
  aarch64-linux
  aarch64-linux-musl
].freeze

RbSys::ExtensionTask.new("c2pa_native", GEMSPEC) do |ext|
  ext.lib_dir = "lib/c2pa"
  ext.cross_compile = true
  ext.cross_platform = CROSS_PLATFORMS
end

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end

# The signing tests need an X.509 certificate chain and key per algorithm.
# These are generated locally rather than downloaded: it needs no network, it
# covers every algorithm the gem accepts rather than only ES256, and it keeps
# third-party material out of the repository entirely.
#
# The generated chains are rooted in a CA created here, so signed assets carry
# a signingCredential.untrusted warning. That does not make a manifest invalid.
#
# They are written to an ignored directory rather than committed: a PEM private
# key in a content-authenticity repository reads badly and trips secret
# scanning, and regenerating them costs a fraction of a second.
namespace :fixtures do
  desc "Generate the signing certificates used by the test suite"
  task :certs do
    require_relative "test/fixtures/generate_certs"
    CertificateFixtures.generate_all
  end

  desc "Regenerate the signing certificates, replacing any that exist"
  task :certs_force do
    require_relative "test/fixtures/generate_certs"
    CertificateFixtures.generate_all(force: true)
  end
end

# Tests depend on the certificates, so a checkout can run `rake test` with no
# manual setup, and a missing certificate fails the run rather than quietly
# skipping the tests that do the real work.
task test: [:compile, "fixtures:certs"]
task default: :test
