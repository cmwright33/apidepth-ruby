# apidepth.gemspec

require_relative "lib/apidepth/version"

Gem::Specification.new do |spec|
  spec.name        = "apidepth"
  spec.version     = Apidepth::VERSION
  spec.authors     = ["Apidepth"]
  spec.email       = ["hello@apidepth.io"]
  spec.summary     = "Know if your API slowness is your code or the vendor's"
  spec.description = "Know if your API slowness is your code or the vendor's. " \
    "Apidepth instruments Net::HTTP to track real production latency to Stripe, " \
    "OpenAI, Twilio and others — then benchmarks your p95 against anonymized fleet " \
    "data so you can see if it's you, or everyone."
  spec.homepage    = "https://apidepth.io"
  spec.license     = "MIT"

  # Minimum Ruby version matches CI (3.1–3.3). Ruby 3.1 introduced:
  #   - Hash#except         — used in configuration helpers
  #   - Fiber#scheduler API — compatible with our thread model
  # Versions below 3.1 are not tested and not supported.
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/apidepth",
    "README.md",
    "LICENSE"
  ]

  spec.executables   = ["apidepth"]
  spec.require_paths = ["lib"]

  # -------------------------------------------------------------------------
  # Runtime dependencies
  # -------------------------------------------------------------------------

  # json stdlib is bundled with Ruby but can be installed as a standalone gem.
  # CVE-2026-33210 (CVSS 9.1): format string injection when allow_duplicate_key: false
  # is used to parse user-supplied documents. Patched in 2.15.2.1, 2.17.1.2, 2.19.2.
  # We don't use allow_duplicate_key ourselves, but pin to a safe floor to protect
  # users who do.
  spec.add_dependency "json", ">= 2.19.2"

  # -------------------------------------------------------------------------
  # Development dependencies
  # -------------------------------------------------------------------------
  spec.add_development_dependency "rspec",       "~> 3.13"
  spec.add_development_dependency "webmock",     "~> 3.23"
  spec.add_development_dependency "railties",    ">= 6.1"
  spec.add_development_dependency "rack",        ">= 2.2.12"   # CVE-2025-27111 fix
  spec.add_development_dependency "rubocop",     "~> 1.65"
  spec.add_development_dependency "simplecov",   "~> 0.22"

  # -------------------------------------------------------------------------
  # Gem signing
  #
  # Sign releases with your private key so customers can verify authenticity:
  #   gem cert --build hello@apidepth.io
  #   gem push apidepth-0.1.0.gem
  #
  # Customers install with:
  #   gem install apidepth -P HighSecurity
  #
  # Uncomment and set paths before publishing to RubyGems:
  # spec.signing_key = File.expand_path("~/.gem/gem-private_key.pem")
  # spec.cert_chain  = ["certs/apidepth.pem"]
  # -------------------------------------------------------------------------

  spec.metadata = {
    "homepage_uri"          => spec.homepage,
    "source_code_uri"       => "https://github.com/apidepth-io/apidepth-ruby",
    "changelog_uri"         => "https://github.com/apidepth-io/apidepth-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri"       => "https://github.com/apidepth-io/apidepth-ruby/issues",
    "rubygems_mfa_required" => "true"   # require MFA to publish — supply chain protection
  }
end
