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

task test: :compile
task default: :test
