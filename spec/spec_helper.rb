# spec/spec_helper.rb

require "fileutils"
require "webmock/rspec"
require "apidepth"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    # Verify that doubled classes and methods actually exist. This catches
    # typos in method names on doubles and instance_doubles at load time.
    mocks.verify_partial_doubles        = true
    mocks.verify_doubled_constant_names = true
  end

  config.disable_monkey_patching!
  config.warnings    = true
  config.order       = :random
  Kernel.srand config.seed

  # Apply Net::HTTP instrumentation once before any test touches it.
  # In production this is wired by the Railtie; in tests we apply it directly.
  # prepend is idempotent for the same module — safe to call in before(:suite).
  config.before(:suite) do
    Net::HTTP.prepend(Apidepth::NetHTTPInstrumentation)
  end

  # Reset all SDK state between tests so nothing bleeds across examples.
  # Tests that modify VendorRegistry use their own ensure blocks.
  config.after(:each) do
    # Prevent rspec doubles set on @http from outliving their example.
    # Tests that put a mock_http on the singleton must clear it themselves,
    # but this nil-out is a safety net so teardown never calls finish on
    # an expired double.
    if (inst = Apidepth::Collector.instance_variable_get(:@instance))
      inst.instance_variable_set(:@http, nil)
    end

    # Kill old Collector threads and close the HTTP connection before clearing
    # the singleton — this is the correct teardown order.
    Apidepth::Collector.reset!

    # Wipe configuration so api_key, enabled, sample_rate, etc. never leak.
    Apidepth.instance_variable_set(:@configuration, nil)

    # sdk_metadata is frozen on first call; reset so Ruby version etc. are
    # recomputed cleanly if any test modifies the environment.
    Apidepth.instance_variable_set(:@sdk_metadata, nil)
  end
end
