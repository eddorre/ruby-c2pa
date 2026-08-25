require_relative "lib/c2pa/version"

Gem::Specification.new do |spec|
  spec.name          = "ruby-c2pa"
  spec.version       = C2PA::VERSION
  spec.authors       = [`git config user.name`.strip]
  spec.email         = [`git config user.email`.strip]
  spec.summary          = "Ruby bindings for the c2pa content authenticity library"
  spec.description      = "Embed and verify C2PA content provenance and authenticity credentials in images, video, and audio files. Ruby bindings for the official Rust c2pa-rs library."
  spec.license          = "MIT"
  spec.homepage         = "https://github.com/eddorre/ruby-c2pa"

  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  # changelog_uri is added in #21, when CHANGELOG.md exists. Linking to a file
  # that is not there yet would repeat the defect this change fixes.
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/README.md"

  # Listed explicitly rather than globbed. "ext/**/*.rs" swept in whatever
  # happened to be under ext/c2pa_native/target, so the package contents
  # depended on what had been compiled on the machine that ran `gem build` —
  # 1.3 MB of dependency build-script output shipped in 0.2.1.
  #
  # Cargo.lock is included deliberately. The extension is compiled at install
  # time, so without it every installer resolves the dependency tree afresh.
  # That is how 0.2.1 shipped against a broken atree and aborted the Ruby
  # process on TIFF input.
  spec.files = [
    "LICENSE",
    "README.md",
    "CONTRIBUTING.md",
    "Rakefile",
    "ruby-c2pa.gemspec",
    "ext/c2pa_native/Cargo.toml",
    "ext/c2pa_native/Cargo.lock",
    "ext/c2pa_native/extconf.rb",
    *Dir["ext/c2pa_native/src/**/*.rs"],
    *Dir["lib/**/*.rb"]
  ].sort
  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/c2pa_native/extconf.rb"]

  spec.required_ruby_version = ">= 3.0"

  spec.add_dependency "rb_sys", "~> 0.9"

  spec.add_development_dependency "rake-compiler", "~> 1.2"
  spec.add_development_dependency "minitest",      "~> 5.0"
  spec.add_development_dependency "rake",          "~> 13.0"
end
