require "rake/extensiontask"
require "rake/testtask"

GEMSPEC = Gem::Specification.load("ruby-c2pa.gemspec")

Rake::ExtensionTask.new("c2pa_native", GEMSPEC) do |ext|
  ext.lib_dir = "lib/c2pa"
  ext.source_pattern = "**/*.{rs,toml,rb}"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end

# The signing tests need an X.509 certificate chain and key. These are the
# public c2pa-rs development fixtures, not secrets — but a PEM private key
# committed to a content-authenticity library reads badly and trips secret
# scanning, so they are fetched into an ignored directory instead.
#
# Files signed with them carry a signingCredential.untrusted warning, which
# does not make a manifest invalid.
namespace :fixtures do
  CERT_DIR = "test/fixtures/certs".freeze
  CERT_SOURCE = "https://raw.githubusercontent.com/contentauth/c2pa-rs/main/sdk/tests/fixtures/certs".freeze
  CERT_FILES = {
    "es256.pub" => "certificate chain",
    "es256.pem" => "private key"
  }.freeze

  desc "Download the c2pa-rs development signing certificates"
  task :certs do
    require "fileutils"
    require "open-uri"

    FileUtils.mkdir_p(CERT_DIR)

    CERT_FILES.each do |name, description|
      path = File.join(CERT_DIR, name)
      next if File.size?(path)

      url = "#{CERT_SOURCE}/#{name}"
      print "Fetching #{description} (#{name})... "
      begin
        content = URI.parse(url).open(&:read)
      rescue StandardError => e
        abort "\nCould not download #{url}: #{e.class}: #{e.message}\n" \
              "The signing tests cannot run without it. See README for details."
      end

      abort "\n#{url} returned no content" if content.to_s.empty?
      File.write(path, content)
      puts "ok"
    end
  end
end

# Tests depend on the certificates, so a checkout can run `rake test` with no
# manual setup, and a missing certificate fails the run rather than quietly
# skipping the tests that do the real work.
task test: [:compile, "fixtures:certs"]
task default: :test
