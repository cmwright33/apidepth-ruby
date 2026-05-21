# apidepth.gemspec

require_relative "lib/apidepth/version"

Gem::Specification.new do |spec|
  spec.name        = "apidepth"
  spec.version     = Apidepth::VERSION
  spec.authors     = ["Apidepth"]
  spec.email       = ["hello@apidepth.io"]
  spec.summary     = "Know if your API slowness is your code or the vendor's"
  spec.description = <<~DESC
    Know if your API slowness is your code or the vendor's. Apidepth instruments
    Net::HTTP to track real production latency to Stripe, OpenAI, Twilio and others
    — then benchmarks your p95 against anonymized fleet data so you can see if it's
    you, or everyone.
  DESC
  spec.homepage    = "https://apidepth.io"
  spec.license     = "MIT"

  # Minimum Ruby version. We use:
  #   - Module#prepend       (2.0+) — Net::HTTP instrumentation
  #   - safe navigation &.  (2.3+) — logger calls
  #   - Pattern matching     (n/a) — not used
  # Ruby 2.7 gives us numbered block params and better warning suppression.
  # Support for < 2.7 is not tested and not guaranteed.
  spec.required_ruby_version = ">= 2.7.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE"
  ]

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
    "source_code_uri"       => "https://github.com/apidepth/apidepth-ruby",
    "changelog_uri"         => "https://github.com/apidepth/apidepth-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri"       => "https://github.com/apidepth/apidepth-ruby/issues",
    "rubygems_mfa_required" => "true"   # require MFA to publish — supply chain protection
  }
end
