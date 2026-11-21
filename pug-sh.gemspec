# frozen_string_literal: true

require_relative "lib/pug/version"

Gem::Specification.new do |spec|
  spec.name = "pug-sh"
  spec.version = Pug::VERSION
  spec.authors = ["pug.sh"]
  spec.summary = "Open-source product analytics SDK for Ruby and Rails: server-side event tracking, " \
                 "profile identify, and analytics reads."
  spec.description = "Tracks events and identifies profiles from Rails or plain Ruby without raising: " \
                     "background threads send them in batches, and one client is thread- and fork-safe under " \
                     "Puma, Unicorn and Sidekiq. It also reads profiles, activity and insights."
  spec.homepage = "https://pug.sh/integrations/rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => "https://pug.sh/integrations/rails",
    "documentation_uri" => "https://docs.pug.sh/sdks/ruby/",
    "changelog_uri" => "https://github.com/pug-sh/sdk-ruby/releases",
    "source_code_uri" => "https://github.com/pug-sh/sdk-ruby",
    "bug_tracker_uri" => "https://github.com/pug-sh/sdk-ruby/issues"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "google-protobuf", ">= 4.30", "< 5"
  spec.add_dependency "logger", ">= 1.6"
end
