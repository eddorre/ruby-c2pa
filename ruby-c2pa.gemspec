require_relative "lib/c2pa/version"

Gem::Specification.new do |spec|
  spec.name          = "ruby-c2pa"
  spec.version       = C2PA::VERSION
  spec.authors       = [`git config user.name`.strip]
  spec.email         = [`git config user.email`.strip]
  spec.summary          = "Ruby bindings for the c2pa content authenticity library"
  spec.description      = "Embed and verify C2PA content provenance and authenticity credentials in images, video, and audio files. Ruby bindings for the official Rust c2pa-rs library."
  spec.license          = "MIT"
  spec.homepage         = "https://github.com/carlosrodriguez/ruby-c2pa"
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files         = Dir["lib/**/*.rb", "ext/**/*.{rs,toml,rb}", "Rakefile", "*.gemspec", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/c2pa_native/extconf.rb"]

  spec.required_ruby_version = ">= 3.0"

  spec.add_dependency "rb_sys", "~> 0.9"

  spec.add_development_dependency "rake-compiler", "~> 1.2"
  spec.add_development_dependency "minitest",      "~> 5.0"
  spec.add_development_dependency "rake",          "~> 13.0"
end
