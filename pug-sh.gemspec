# frozen_string_literal: true

require_relative "lib/pug/version"

Gem::Specification.new do |spec|
  spec.name = "pug-sh"
  spec.version = Pug::VERSION
  spec.authors = ["pug.sh"]
  spec.summary = "Pug server-side SDK for Ruby — event tracking, profile identify, and analytics reads."
  spec.homepage = "https://pug.sh"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => "https://pug.sh",
    "source_code_uri" => "https://github.com/pug-sh/sdk-ruby",
    "bug_tracker_uri" => "https://github.com/pug-sh/sdk-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "google-protobuf", ">= 4.30", "< 5"
  spec.add_dependency "logger", ">= 1.6"
end
