# spec/apidepth/sdk_spec.rb
#
# Full test suite. Also serves as the spec document for SDK ports:
# hand this file to an agent alongside the implementation and say
# "make these pass in your language."

require "spec_helper"

# =============================================================================
# NetHTTPInstrumentation
# =============================================================================

RSpec.describe Apidepth::NetHTTPInstrumentation do
  let(:collector) { instance_double(Apidepth::Collector) }

  before do
    allow(Apidepth::Collector).to receive(:instance).and_return(collector)
    allow(collector).to receive(:record)
    stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
      .to_return(status: 200, body: '{"id":"ch_abc123"}')
  end

  describe "basic capture" do
    it "records vendor, normalized endpoint, method, status, and duration" do
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(
        hash_including(vendor: "stripe", endpoint: "/v1/charges/:id", method: "GET", status: 200)
      )
    end

    it "records a non-negative duration_ms" do
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      # WebMock returns instantly; elapsed rounds to 0ms on fast hardware.
      expect(collector).to have_received(:record).with(hash_including(duration_ms: (be >= 0)))
    end

    it "records a unix timestamp" do
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(hash_including(ts: be_a(Integer)))
    end
  end

  describe "outcome tagging" do
    it "tags 2xx responses as :success" do
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(hash_including(outcome: :success))
    end

    it "tags 4xx responses as :client_error" do
      stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
        .to_return(status: 401)
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(
        hash_including(outcome: :client_error, status: 401)
      )
    end

    it "tags 5xx responses as :server_error" do
      stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
        .to_return(status: 503)
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(
        hash_including(outcome: :server_error, status: 503)
      )
    end

    it "tags unrecognized status codes as :unknown" do
      stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
        .to_return(status: 999)
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(
        hash_including(outcome: :unknown, status: 999)
      )
    end
  end

  describe "timeout capture" do
    it "records a :timeout event when Net::ReadTimeout is raised" do
      stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
        .to_raise(Net::ReadTimeout)
      expect do
        Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      end.to raise_error(Net::ReadTimeout)

      expect(collector).to have_received(:record).with(
        hash_including(
          vendor: "stripe",
          outcome: :timeout,
          status: nil,
          error_class: "Net::ReadTimeout"
        )
      )
    end

    it "records a :timeout event when Net::OpenTimeout is raised" do
      stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
        .to_raise(Net::OpenTimeout)
      expect do
        Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      end.to raise_error(Net::OpenTimeout)

      expect(collector).to have_received(:record).with(
        hash_including(outcome: :timeout, error_class: "Net::OpenTimeout")
      )
    end

    it "still re-raises the timeout so the customer's error handling fires" do
      stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
        .to_raise(Net::ReadTimeout)
      expect do
        Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      end.to raise_error(Net::ReadTimeout)
    end

    it "records a non-negative duration_ms for timeouts" do
      stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
        .to_raise(Net::ReadTimeout)
      begin
        Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      rescue StandardError
        nil
      end
      # WebMock raises immediately with no delay, so elapsed rounds to 0ms on
      # fast hardware. Accept >= 0 rather than > 0.
      expect(collector).to have_received(:record).with(
        hash_including(duration_ms: (be >= 0))
      )
    end
  end

  describe "cold_start tagging" do
    it "records cold_start: true when no keep-alive connection is open" do
      allow_any_instance_of(Net::HTTP).to receive(:started?).and_return(false)
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(hash_including(cold_start: true))
    end

    it "records cold_start: false when a keep-alive connection is already open" do
      # Net::HTTP.start establishes the connection before yielding to our
      # instrumented request method, so started? is naturally true — no stub needed.
      # Stubbing started? to true before start() runs causes a Ruby 4.0 SSL
      # consistency check to raise IOError.
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(hash_including(cold_start: false))
    end
  end

  describe "environment tagging" do
    it "tags events with the configured environment" do
      Apidepth.configuration.environment = "staging"
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(hash_including(env: "staging"))
    ensure
      Apidepth.configuration.environment = nil
    end

    it "falls back to 'unknown' when environment is not configured" do
      Apidepth.configuration.environment = nil
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).to have_received(:record).with(
        hash_including(env: "unknown")
      )
    end
  end

  describe "unknown vendors are ignored" do
    it "does not record events for unrecognized hosts" do
      stub_request(:get, "https://internal.mycompany.com/api/data").to_return(status: 200)
      Net::HTTP.get(URI("https://internal.mycompany.com/api/data"))
      expect(collector).not_to have_received(:record)
    end
  end

  describe "recursive instrumentation prevention" do
    it "does not record the collector's own outbound flush call" do
      Thread.current[:apidepth_skip] = true
      stub_request(:post, "https://collector.apidepth.io/v1/events").to_return(status: 200)
      Net::HTTP.post(URI("https://collector.apidepth.io/v1/events"), "{}", "Content-Type" => "application/json")
      expect(collector).not_to have_received(:record)
    ensure
      Thread.current[:apidepth_skip] = false
    end
  end

  describe "ignored_hosts" do
    before { Apidepth.configuration.ignored_hosts = ["api.stripe.com"] }
    after  { Apidepth.configuration.ignored_hosts = [] }

    it "does not record events for hosts on the ignore list" do
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).not_to have_received(:record)
    end
  end

  describe "disabled SDK" do
    before { Apidepth.configuration.enabled = false }
    after  { Apidepth.configuration.enabled = true }

    it "does not record any events" do
      Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      expect(collector).not_to have_received(:record)
    end
  end

  describe "SDK never crashes the host application" do
    it "propagates the real HTTP error without adding instrumentation errors" do
      stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123").to_raise(Net::OpenTimeout)
      expect do
        Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))
      end.to raise_error(Net::OpenTimeout)
    end

    it "does not raise if VendorRegistry raises unexpectedly" do
      allow(Apidepth::VendorRegistry).to receive(:identify).and_raise("registry bug")
      expect { Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123")) }.not_to raise_error
    end

    it "does not raise if Collector#record raises unexpectedly" do
      allow(collector).to receive(:record).and_raise("collector bug")
      expect { Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123")) }.not_to raise_error
    end
  end
end

# =============================================================================
# VendorRegistry
# =============================================================================

RSpec.describe Apidepth::VendorRegistry do
  describe ".identify" do
    it "identifies Stripe and normalizes a charge ID" do
      vendor, path = described_class.identify("api.stripe.com", "/v1/charges/ch_abc123DEF456")
      expect(vendor).to eq("stripe")
      expect(path).to eq("/v1/charges/:id")
    end

    it "identifies OpenAI chat completions" do
      vendor, path = described_class.identify("api.openai.com", "/v1/chat/completions")
      expect(vendor).to eq("openai")
      expect(path).to eq("/v1/chat/completions")
    end

    it "strips query strings before normalizing" do
      _, path = described_class.identify("api.stripe.com", "/v1/customers/cus_123?expand[]=subscriptions")
      expect(path).to eq("/v1/customers/:id")
    end

    it "returns nil for unknown hosts" do
      expect(described_class.identify("internal.myapp.com", "/api/v1/users")).to be_nil
    end

    it "applies the generic UUID normalizer when no vendor rule matches" do
      _, path = described_class.identify("api.stripe.com",
                                         "/v1/unknown/3f8a2b1c-4d5e-6f7a-8b9c-0d1e2f3a4b5c")
      expect(path).to include("/:uuid")
    end

    it "applies the generic :id normalizer for 4+ digit numeric segments" do
      _, path = described_class.identify("api.stripe.com", "/v1/unknown/99999")
      expect(path).to include("/:id")
    end

    it "does not normalise short numeric segments (avoids mangling /v1 etc)" do
      _, path = described_class.identify("api.stripe.com", "/v1/charges/ch_abc123")
      # Version prefix /v1 must survive intact after vendor-specific normalisation
      expect(path).to start_with("/v1")
    end

    it "applies the generic :token normalizer for long lowercase hex strings" do
      _, path = described_class.identify("api.stripe.com",
                                         "/v1/unknown/a1b2c3d4e5f6a7b8c9d0e1f2") # 24 lowercase hex chars
      expect(path).to include("/:token")
    end
  end

  describe "thread safety" do
    it "returns consistent results when replace and identify run concurrently" do
      errors = []

      identifier_threads = Array.new(10) do
        Thread.new do
          100.times do
            result = described_class.identify("api.stripe.com", "/v1/charges/ch_abc")
            errors << "unexpected nil" if result.nil?
          end
        rescue StandardError => e
          errors << e.message
        end
      end

      replacer_thread = Thread.new do
        10.times do
          described_class.replace(Apidepth::VendorRegistry::BUNDLED_BASELINE)
          sleep 0.001
        end
      end

      (identifier_threads + [replacer_thread]).each(&:join)
      expect(errors).to be_empty
    end
  end

  describe ".replace" do
    it "hot-swaps the registry and is immediately reflected in .identify" do
      new_registry = {
        "version" => "test-v1",
        "vendors" => {
          "testvendor" => {
            "hosts" => ["api.testvendor.io"],
            "patterns" => [
              { "match" => '/v1/widgets/wgt_\w+', "replace" => "/v1/widgets/:id" }
            ]
          }
        }
      }

      described_class.replace(new_registry)
      vendor, path = described_class.identify("api.testvendor.io", "/v1/widgets/wgt_abc123")
      expect(vendor).to eq("testvendor")
      expect(path).to eq("/v1/widgets/:id")
    ensure
      described_class.replace(Apidepth::VendorRegistry::BUNDLED_BASELINE)
    end

    it "updates .version" do
      described_class.replace(Apidepth::VendorRegistry::BUNDLED_BASELINE.merge("version" => "test-99"))
      expect(described_class.version).to eq("test-99")
    ensure
      described_class.replace(Apidepth::VendorRegistry::BUNDLED_BASELINE)
    end
  end

  describe "pattern validation" do
    def registry_with_pattern(match)
      {
        "version" => "test",
        "vendors" => {
          "badvendor" => {
            "hosts" => ["api.badvendor.io"],
            "patterns" => [{ "match" => match, "replace" => "/safe" }]
          }
        }
      }
    end

    after { described_class.replace(Apidepth::VendorRegistry::BUNDLED_BASELINE) }

    it "skips patterns with embedded code constructs" do
      described_class.replace(registry_with_pattern('(?{puts "pwned"})'))
      # Pattern is skipped — host is registered but no patterns match
      # so the generic normalizers run instead. The important thing: no code executed.
      expect { described_class.identify("api.badvendor.io", "/any/path") }.not_to raise_error
    end

    it "skips malformed patterns without raising" do
      described_class.replace(registry_with_pattern("[unclosed"))
      expect { described_class.identify("api.badvendor.io", "/any/path") }.not_to raise_error
    end

    it "accepts and applies well-formed patterns from a remote registry" do
      described_class.replace(registry_with_pattern('/v1/items/item_\w+'))
      _, path = described_class.identify("api.badvendor.io", "/v1/items/item_abc123")
      expect(path).to eq("/safe")
    end
  end
end

# =============================================================================
# RegistryLoader
# =============================================================================

RSpec.describe Apidepth::RegistryLoader do
  describe ".fetch_remote" do
    let(:large_body) { "x" * 512_001 }
    let(:valid_registry) { { "version" => "remote-v1", "vendors" => {} }.to_json }

    it "rejects responses larger than 512KB" do
      stub_request(:get, Apidepth::RegistryLoader::REGISTRY_URL)
        .to_return(status: 200, body: large_body)

      result = described_class.send(:fetch_remote)
      expect(result).to be_nil
    end

    it "parses and returns a valid registry response" do
      stub_request(:get, Apidepth::RegistryLoader::REGISTRY_URL)
        .to_return(status: 200, body: valid_registry, headers: { "Content-Type" => "application/json" })

      result = described_class.send(:fetch_remote)
      expect(result).to include("version" => "remote-v1")
    end

    it "returns nil on non-200 responses" do
      stub_request(:get, Apidepth::RegistryLoader::REGISTRY_URL).to_return(status: 404)
      expect(described_class.send(:fetch_remote)).to be_nil
    end

    it "returns nil on network errors without raising" do
      stub_request(:get, Apidepth::RegistryLoader::REGISTRY_URL).to_raise(Errno::ECONNREFUSED)
      expect { described_class.send(:fetch_remote) }.not_to raise_error
      expect(described_class.send(:fetch_remote)).to be_nil
    end

    it "writes a valid response to the cache path" do
      cache_path = "/tmp/apidepth_test_#{SecureRandom.hex(6)}.json"
      Apidepth.configuration.registry_cache_path = cache_path

      stub_request(:get, Apidepth::RegistryLoader::REGISTRY_URL)
        .to_return(status: 200, body: valid_registry)

      described_class.send(:fetch_remote)
      expect(File.exist?(cache_path)).to be true
      expect(JSON.parse(File.read(cache_path))).to include("version" => "remote-v1")
    ensure
      Apidepth.configuration.registry_cache_path = "/tmp/apidepth_registry.json"
      File.delete(cache_path) if cache_path && File.exist?(cache_path)
    end
  end

  describe ".load_from_disk" do
    let(:cache_path) { "/tmp/apidepth_test_#{SecureRandom.hex(6)}.json" }

    before { Apidepth.configuration.registry_cache_path = cache_path }
    after  do
      Apidepth.configuration.registry_cache_path = "/tmp/apidepth_registry.json"
      FileUtils.rm_f(cache_path)
    end

    it "returns nil when the cache file does not exist" do
      expect(described_class.send(:load_from_disk)).to be_nil
    end

    it "returns the parsed registry from a valid cache file" do
      File.write(cache_path, { "version" => "cached-v1", "vendors" => {} }.to_json)
      result = described_class.send(:load_from_disk)
      expect(result).to include("version" => "cached-v1")
    end

    it "returns nil and does not raise on invalid JSON in the cache file" do
      File.write(cache_path, "not valid json {{{{")
      expect { described_class.send(:load_from_disk) }.not_to raise_error
      expect(described_class.send(:load_from_disk)).to be_nil
    end
  end

  describe ".validate_cache_path!" do
    it "accepts a valid absolute path" do
      expect { described_class.send(:validate_cache_path!, "/tmp/apidepth.json") }.not_to raise_error
    end

    it "rejects a relative path" do
      expect do
        described_class.send(:validate_cache_path!, "tmp/apidepth.json")
      end.to raise_error(ArgumentError, /absolute path/)
    end

    it "rejects a path containing .." do
      expect do
        described_class.send(:validate_cache_path!, "/tmp/../../etc/passwd")
      end.to raise_error(ArgumentError, /traversal/)
    end

    it "rejects a non-string value" do
      expect do
        described_class.send(:validate_cache_path!, nil)
      end.to raise_error(ArgumentError, /absolute path/)
    end
  end
end

# =============================================================================
# Security validations — Collector
# =============================================================================

RSpec.describe "Apidepth::Collector security" do
  let(:collector) { Apidepth::Collector.new }

  describe "SSRF protection (validate_collector_url!)" do
    def url(str)
      URI.parse(str)
    end

    it "accepts a valid HTTPS collector URL" do
      expect do
        collector.send(:validate_collector_url!, url("https://collector.apidepth.io/v1/events"))
      end.not_to raise_error
    end

    it "rejects HTTP URLs" do
      expect do
        collector.send(:validate_collector_url!, url("http://collector.apidepth.io/v1/events"))
      end.to raise_error(ArgumentError, /HTTPS/)
    end

    it "rejects localhost" do
      expect do
        collector.send(:validate_collector_url!, url("https://localhost/v1/events"))
      end.to raise_error(ArgumentError, /private/)
    end

    it "rejects 127.x loopback" do
      expect do
        collector.send(:validate_collector_url!, url("https://127.0.0.1/v1/events"))
      end.to raise_error(ArgumentError, /private/)
    end

    it "rejects AWS metadata endpoint (169.254.x)" do
      expect do
        collector.send(:validate_collector_url!, url("https://169.254.169.254/latest/meta-data/"))
      end.to raise_error(ArgumentError, /private/)
    end

    it "rejects RFC1918 private ranges" do
      [
        "https://192.168.1.1/admin",
        "https://10.0.0.1/admin",
        "https://172.16.0.1/admin",
        "https://172.31.255.255/admin"
      ].each do |private_url|
        expect do
          collector.send(:validate_collector_url!, url(private_url))
        end.to raise_error(ArgumentError, /private/), "expected #{private_url} to be rejected"
      end
    end

    it "rejects IPv6 loopback" do
      expect do
        collector.send(:validate_collector_url!, url("https://[::1]/v1/events"))
      end.to raise_error(ArgumentError, /private/)
    end

    it "rejects IPv6 unique-local (fc00::)" do
      expect do
        collector.send(:validate_collector_url!, url("https://[fc00::1]/v1/events"))
      end.to raise_error(ArgumentError, /private/)
    end

    it "rejects IPv6 link-local (fe80::)" do
      expect do
        collector.send(:validate_collector_url!, url("https://[fe80::1]/v1/events"))
      end.to raise_error(ArgumentError, /private/)
    end

    it "rejects 0.0.0.0" do
      expect do
        collector.send(:validate_collector_url!, url("https://0.0.0.0/v1/events"))
      end.to raise_error(ArgumentError, /private/)
    end

    it "rejects decimal IP representation of 127.0.0.1 (2130706433)" do
      # Known SSRF filter bypass — 2130706433 is 127.0.0.1 as a 32-bit integer.
      # Net::HTTP resolves it at connect time; naive string checks miss it.
      expect do
        collector.send(:validate_collector_url!, url("https://2130706433/v1/events"))
      end.to raise_error(ArgumentError, /private/)
    end

    it "rejects decimal IP representation of 169.254.169.254 (2852039166)" do
      # AWS metadata endpoint as decimal integer
      expect do
        collector.send(:validate_collector_url!, url("https://2852039166/v1/events"))
      end.to raise_error(ArgumentError, /private/)
    end
  end

  describe "header injection protection (validate_api_key!)" do
    it "accepts a normal api_key" do
      expect do
        collector.send(:validate_api_key!, "sk_live_abc123")
      end.not_to raise_error
    end

    it "rejects an api_key containing a newline" do
      expect do
        collector.send(:validate_api_key!, "sk_live_abc\nX-Injected: evil")
      end.to raise_error(ArgumentError, /line-break/)
    end

    it "rejects an api_key containing a carriage return" do
      expect do
        collector.send(:validate_api_key!, "sk_live_abc\rX-Injected: evil")
      end.to raise_error(ArgumentError, /line-break/)
    end

    it "allows nil api_key without raising (nil guard is elsewhere)" do
      expect { collector.send(:validate_api_key!, nil) }.not_to raise_error
    end

    it "allows empty api_key without raising (empty guard is elsewhere)" do
      expect { collector.send(:validate_api_key!, "") }.not_to raise_error
    end
  end
end

# =============================================================================
# sanitize_log
# =============================================================================

RSpec.describe "Apidepth.sanitize_log" do
  it "strips newlines that would allow log injection" do
    result = Apidepth.sanitize_log("stripe\n[CRITICAL] Fake alert injected by attacker")
    expect(result).not_to include("\n")
    expect(result).to include("stripe")
  end

  it "strips carriage returns" do
    expect(Apidepth.sanitize_log("value\r\ninjected")).not_to include("\r")
  end

  it "strips tab characters" do
    result = Apidepth.sanitize_log("vendor\tinjected_column")
    expect(result).not_to include("\t")
    expect(result).to include("vendor")
  end

  it "truncates to 200 characters" do
    long = "a" * 300
    expect(Apidepth.sanitize_log(long).length).to eq(200)
  end

  it "handles nil gracefully" do
    expect { Apidepth.sanitize_log(nil) }.not_to raise_error
    expect(Apidepth.sanitize_log(nil)).to eq("")
  end
end

# =============================================================================
# Collector
# =============================================================================

RSpec.describe Apidepth::Collector do
  # Most tests need an api_key so send_batch proceeds past the nil/empty guard.
  # Tests that exercise nil/empty/invalid keys set their own and override this.
  before { Apidepth.configuration.api_key = "sk_test" }

  def event(overrides = {})
    { vendor: "stripe", endpoint: "/v1/charges/:id", method: "GET",
      outcome: :success, status: 200, duration_ms: 80, ts: Time.now.to_i }.merge(overrides)
  end

  describe ".instance (singleton)" do
    after { described_class.reset! }

    it "returns the same object on concurrent calls" do
      instances = Array.new(20).map { Thread.new { described_class.instance } }.map(&:value)
      expect(instances.uniq.size).to eq(1)
    end
  end

  describe ".reset!" do
    it "clears the singleton so the next call returns a new instance" do
      original = described_class.instance
      described_class.reset!
      expect(described_class.instance).not_to equal(original)
    ensure
      described_class.reset!
    end
  end

  describe "#record" do
    it "does not block — enqueues events near-instantly" do
      collector = described_class.new
      t = Time.now
      1_000.times { collector.record(event) }
      expect(Time.now - t).to be < 0.1
    end

    it "increments total_dropped when the queue is at capacity" do
      collector = described_class.new
      stub_const("Apidepth::Collector::MAX_QUEUE_SIZE", 5)
      6.times { collector.record(event) }
      expect(collector.total_dropped).to eq(1)
    end

    it "does not include api_key in the batch payload" do
      Apidepth.configuration.api_key = "sk_test_secret"
      stub = stub_request(:post, Apidepth::Collector::DEFAULT_URL)
             .with { |req| !JSON.parse(req.body).key?("api_key") }
             .to_return(status: 200)

      collector = described_class.new
      collector.record(event)
      collector.flush!

      expect(stub).to have_been_requested
    ensure
      Apidepth.configuration.api_key = nil
    end

    it "sends api_key in the Authorization header" do
      Apidepth.configuration.api_key = "sk_test_secret"
      stub = stub_request(:post, Apidepth::Collector::DEFAULT_URL)
             .with(headers: { "Authorization" => "Bearer sk_test_secret" })
             .to_return(status: 200)

      collector = described_class.new
      collector.record(event)
      collector.flush!

      expect(stub).to have_been_requested
    ensure
      Apidepth.configuration.api_key = nil
    end
  end

  describe "#flush!" do
    it "sends collected events to the collector API" do
      stub = stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_return(status: 200)
      collector = described_class.new
      collector.record(event(vendor: "openai", endpoint: "/v1/chat/completions", duration_ms: 450))
      collector.flush!
      expect(stub).to have_been_requested
    end

    it "does not raise if the collector API is unreachable" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_raise(Errno::ECONNREFUSED)
      collector = described_class.new
      collector.record(event)
      expect { collector.flush! }.not_to raise_error
    end

    it "does not raise on a non-2xx response" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_return(status: 503)
      collector = described_class.new
      collector.record(event)
      expect { collector.flush! }.not_to raise_error
    end
  end

  describe "consecutive failure tracking" do
    it "increments consecutive_failures on each failed flush" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_raise(Errno::ECONNREFUSED)
      collector = described_class.new
      3.times do
        collector.record(event)
        collector.send(:safe_flush)
      end
      expect(collector.consecutive_failures).to eq(3)
    end

    it "resets consecutive_failures after a successful flush" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL)
        .to_raise(Errno::ECONNREFUSED).then
        .to_raise(Errno::ECONNREFUSED).then
        .to_return(status: 200)

      collector = described_class.new
      3.times do
        collector.record(event)
        collector.send(:safe_flush)
      end
      expect(collector.consecutive_failures).to eq(0)
    end

    it "logs a warning at FAILURE_THRESHOLD" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_raise(Errno::ECONNREFUSED)
      logger = instance_double(Logger, warn: nil)
      allow(Apidepth).to receive(:logger).and_return(logger)

      collector = described_class.new
      Apidepth::Collector::FAILURE_THRESHOLD.times do
        collector.record(event)
        collector.send(:safe_flush)
      end

      expect(logger).to have_received(:warn).with(/#{Apidepth::Collector::FAILURE_THRESHOLD} times consecutively/)
    end
  end

  describe "on_flush_error callback" do
    after { Apidepth.configuration.on_flush_error = nil }

    it "calls the callback with the error and context" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_raise(Errno::ECONNREFUSED)
      received = []
      Apidepth.configuration.on_flush_error = ->(err, ctx) { received << [err, ctx] }

      collector = described_class.new
      collector.record(event)
      collector.send(:safe_flush)

      expect(received.size).to eq(1)
      expect(received.first[0]).to be_a(Errno::ECONNREFUSED)
      expect(received.first[1]).to include(:dropped_events, :consecutive_failures, :total_dropped)
    end

    it "does not crash the flush thread if the callback raises" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_raise(Errno::ECONNREFUSED)
      Apidepth.configuration.on_flush_error = ->(_e, _c) { raise "boom" }
      collector = described_class.new
      collector.record(event)
      expect { collector.send(:safe_flush) }.not_to raise_error
    end
  end

  describe "#stats" do
    it "returns a consistent snapshot with all expected keys" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_return(status: 200)
      collector = described_class.new
      collector.record(event)
      collector.flush!

      s = collector.stats
      expect(s.keys).to contain_exactly(:queue_size, :consecutive_failures, :total_dropped, :last_flush_at)
      expect(s[:queue_size]).to eq(0)
      expect(s[:last_flush_at]).to be_a(Time)
    end
  end

  describe "non-2xx collector response" do
    it "treats a 429 as a failure" do
      stub_request(:post, Apidepth::Collector::DEFAULT_URL).to_return(status: 429, body: "rate limited")
      collector = described_class.new
      collector.record(event)
      collector.send(:safe_flush)
      expect(collector.consecutive_failures).to eq(1)
    end

    it "does not include api_key or response body in the failure message" do
      Apidepth.configuration.api_key = "sk_secret_key"
      stub_request(:post, Apidepth::Collector::DEFAULT_URL)
        .to_return(status: 401, body: "Bearer sk_secret_key is invalid")

      logged_messages = []
      logger = instance_double(Logger, warn: nil)
      allow(logger).to receive(:warn) { |msg| logged_messages << msg }
      allow(Apidepth).to receive(:logger).and_return(logger)

      collector = described_class.new
      Apidepth::Collector::FAILURE_THRESHOLD.times do
        collector.record(event)
        collector.send(:safe_flush)
      end

      expect(logged_messages.join).not_to include("sk_secret_key")
      expect(logged_messages.join).not_to include("Bearer")
    ensure
      Apidepth.configuration.api_key = nil
    end
  end

  describe "end-to-end SSRF rejection" do
    it "flush! does not raise but records the failure when collector_url is HTTP" do
      Apidepth.configuration.collector_url = "http://collector.apidepth.io/v1/events"
      collector = described_class.new
      collector.record(event)

      expect { collector.flush! }.not_to raise_error
      expect(collector.consecutive_failures).to eq(1) # flush! rescues internally but still tracks it
    ensure
      Apidepth.configuration.collector_url = nil
    end

    it "safe_flush increments consecutive_failures when collector_url is HTTP" do
      Apidepth.configuration.collector_url = "http://collector.apidepth.io/v1/events"
      collector = described_class.new
      collector.record(event)
      collector.send(:safe_flush)

      expect(collector.consecutive_failures).to eq(1)
    ensure
      Apidepth.configuration.collector_url = nil
    end
  end

  describe "end-to-end empty api_key guard" do
    it "safe_flush does not send and does not increment failures when api_key is empty" do
      Apidepth.configuration.api_key = ""
      collector = described_class.new
      collector.record(event)
      collector.send(:safe_flush)

      expect(collector.consecutive_failures).to eq(0)
    ensure
      Apidepth.configuration.api_key = nil
    end
  end

  describe "end-to-end CRLF api_key rejection" do
    it "safe_flush increments consecutive_failures when api_key contains CRLF" do
      Apidepth.configuration.api_key = "sk_valid\r\nX-Evil: injected"
      collector = described_class.new
      collector.record(event)
      collector.send(:safe_flush)

      expect(collector.consecutive_failures).to eq(1)
    ensure
      Apidepth.configuration.api_key = nil
    end

    it "flush! does not raise when api_key contains CRLF" do
      Apidepth.configuration.api_key = "sk_valid\r\nX-Evil: injected"
      collector = described_class.new
      collector.record(event)

      expect { collector.flush! }.not_to raise_error
    ensure
      Apidepth.configuration.api_key = nil
    end
  end
end

# =============================================================================
# Configuration
# =============================================================================

RSpec.describe Apidepth::Configuration do
  it "has sensible defaults" do
    config = described_class.new
    expect(config.enabled).to be true
    expect(config.flush_interval).to eq(20)
    expect(config.registry_refresh_interval).to eq(6 * 60 * 60)
    expect(config.registry_cache_path).to eq("/tmp/apidepth_registry.json")
    expect(config.ignored_hosts).to eq([])
    expect(config.on_flush_error).to be_nil
    expect(config.collector_url).to be_nil
    expect(config.environment).to be_nil
    expect(config.sample_rate).to eq(1.0)
  end
end

# =============================================================================
# Event schema enforcement
# =============================================================================

RSpec.describe Apidepth::Event do
  describe ".build" do
    let(:valid_attrs) do
      {
        vendor: "stripe",
        endpoint: "/v1/charges/:id",
        method: "GET",
        outcome: :success,
        duration_ms: 120,
        ts: 1_000_000_000_000,
        status: 200,
        cold_start: false,
        env: "production"
      }
    end

    it "returns a frozen hash when all required fields are present" do
      event = described_class.build(valid_attrs)
      expect(event).to be_a(Hash)
      expect(event).to be_frozen
    end

    it "raises ArgumentError when a required field is missing" do
      expect do
        described_class.build(valid_attrs.reject { |k, _| k == :duration_ms })
      end.to raise_error(ArgumentError, /duration_ms/)
    end

    it "raises ArgumentError listing all missing fields" do
      expect do
        described_class.build(valid_attrs.reject { |k, _| %i[vendor outcome].include?(k) })
      end.to raise_error(ArgumentError, /vendor.*outcome|outcome.*vendor/)
    end

    it "permits optional fields like error_class" do
      expect do
        described_class.build(valid_attrs.merge(error_class: "Net::ReadTimeout"))
      end.not_to raise_error
    end
  end
end

# =============================================================================
# Sample rate
# =============================================================================

RSpec.describe "Apidepth sample rate" do
  let(:collector) { instance_double(Apidepth::Collector) }

  before do
    allow(Apidepth::Collector).to receive(:instance).and_return(collector)
    allow(collector).to receive(:record)
    stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
      .to_return(status: 200, body: "{}")
  end

  after { Apidepth.configuration.sample_rate = 1.0 }

  it "captures all events at sample_rate 1.0" do
    Apidepth.configuration.sample_rate = 1.0
    10.times { Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123")) }
    expect(collector).to have_received(:record).exactly(10).times
  end

  it "captures no events at sample_rate 0.0" do
    Apidepth.configuration.sample_rate = 0.0
    10.times { Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123")) }
    expect(collector).not_to have_received(:record)
  end

  it "captures roughly half of events at sample_rate 0.5" do
    Apidepth.configuration.sample_rate = 0.5
    received = 0
    allow(collector).to receive(:record) { received += 1 }
    100.times { Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123")) }
    # Probabilistic — verify it's neither 0 nor 100 over a large sample
    expect(received).to be_between(20, 80)
  end
end

# =============================================================================
# Millisecond timestamps
# =============================================================================

RSpec.describe "Apidepth event timestamps" do
  let(:collector) { instance_double(Apidepth::Collector) }

  before do
    allow(Apidepth::Collector).to receive(:instance).and_return(collector)
    allow(collector).to receive(:record)
    stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
      .to_return(status: 200, body: "{}")
  end

  it "records ts as milliseconds since epoch, not seconds" do
    threshold_ms = (Time.now.to_f * 1000).to_i
    captured = []
    allow(collector).to receive(:record) { |e| captured << e }

    Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))

    expect(captured).not_to be_empty
    ts = captured.first[:ts]

    # Must be at or after the threshold in milliseconds
    expect(ts).to be >= threshold_ms

    # A second-resolution timestamp (~1.7 trillion) is 13 digits.
    # A millisecond-resolution timestamp is also 13 digits but 1000x larger.
    # Verify it's clearly in millisecond range: greater than current time in seconds * 100.
    expect(ts).to be > Time.now.to_i * 100
  end
end

# =============================================================================
# SDK metadata in payload
# =============================================================================

RSpec.describe "Apidepth SDK metadata" do
  it "sdk_metadata includes name, version, ruby_version, and ruby_platform" do
    meta = Apidepth.sdk_metadata
    expect(meta[:name]).to eq("apidepth-ruby")
    expect(meta[:version]).to eq(Apidepth::VERSION)
    expect(meta[:ruby_version]).to eq(RUBY_VERSION)
    expect(meta[:ruby_platform]).to eq(RUBY_PLATFORM)
  end

  it "sdk_metadata is frozen" do
    expect(Apidepth.sdk_metadata).to be_frozen
  end

  it "sdk_metadata is included in the batch payload sent to the collector" do
    Apidepth.configuration.api_key = "sk_test"

    # Capture the request body by stubbing http_connection on the specific
    # collector instance. Avoids allow_any_instance_of which conflicts with WebMock.
    captured_body = nil
    response      = double("response", code: "200", body: "{}")
    mock_http     = double("Net::HTTP", started?: true)
    allow(mock_http).to receive(:request) { |req|
      captured_body = req.body
      response
    }

    collector = Apidepth::Collector.new
    collector.instance_variable_set(:@http, mock_http)

    collector.record(Apidepth::Event.build(
                       vendor: "stripe", endpoint: "/v1/charges/:id", method: "GET",
                       outcome: :success, duration_ms: 100, ts: (Time.now.to_f * 1000).to_i,
                       status: 200, cold_start: false, env: "test"
                     ))
    collector.flush!

    expect(captured_body).not_to be_nil
    sdk = JSON.parse(captured_body)["sdk"]
    expect(sdk["name"]).to eq("apidepth-ruby")
    expect(sdk["ruby_version"]).to eq(RUBY_VERSION)
    expect(sdk).to have_key("app_server")
  ensure
    Apidepth.configuration.api_key = nil
  end
end

# =============================================================================
# Watchdog thread
# =============================================================================

RSpec.describe "Apidepth::Collector watchdog" do
  it "restarts the flush thread if it dies" do
    # Stub BEFORE creating the collector so the watchdog thread starts
    # with the reduced interval, not the 60-second production default.
    # stub_const after thread creation would never affect an already-sleeping thread.
    stub_const("Apidepth::Collector::WATCHDOG_INTERVAL", 0.05)

    collector = Apidepth::Collector.new
    original_thread = collector.instance_variable_get(:@flush_thread)

    original_thread.kill
    original_thread.join

    # Give the watchdog time to detect the dead thread and restart it
    sleep 0.3

    new_thread = collector.instance_variable_get(:@flush_thread)
    expect(new_thread).to be_alive
    expect(new_thread).not_to equal(original_thread)
  end
end

# =============================================================================
# Persistent HTTP connection
# =============================================================================

RSpec.describe "Apidepth::Collector persistent connection" do
  # Helper: pre-populate @http so http_connection returns it without TCP setup.
  # The double responds to started? => true, which is the "already connected" path.
  def mock_connection(collector, code: "200")
    response  = double("response", code: code, body: "")
    mock_http = double("Net::HTTP", started?: true)
    allow(mock_http).to receive(:request).and_return(response)
    allow(mock_http).to receive(:finish)
    collector.instance_variable_set(:@http, mock_http)
    mock_http
  end

  describe "http_connection" do
    it "returns @http immediately when started? is true — no reconnect" do
      collector = Apidepth::Collector.new
      fake      = double("Net::HTTP", started?: true)
      collector.instance_variable_set(:@http, fake)

      expect(Net::HTTP).not_to receive(:new)
      expect(collector.send(:http_connection)).to equal(fake)
    end

    it "builds and starts a new connection when @http is nil" do
      Apidepth.configuration.api_key = "sk_test"
      collector = Apidepth::Collector.new

      fresh = double("Net::HTTP")
      allow(Net::HTTP).to receive(:new).and_return(fresh)
      %i[use_ssl= verify_mode= open_timeout= read_timeout= keep_alive_timeout=].each do |m|
        allow(fresh).to receive(m)
      end
      allow(fresh).to receive(:start).and_return(fresh)
      allow(fresh).to receive(:started?).and_return(false)

      result = collector.send(:http_connection)
      expect(result).to equal(fresh)
      expect(collector.instance_variable_get(:@http)).to equal(fresh)
    ensure
      Apidepth.configuration.api_key = nil
    end

    it "nils @http and calls finish after a non-2xx response" do
      Apidepth.configuration.api_key = "sk_test"
      collector = Apidepth::Collector.new
      mock_http = mock_connection(collector, code: "503")

      # expect finish is called to close the connection cleanly
      expect(mock_http).to have_received(:finish).exactly(0).times # not yet

      events = [Apidepth::Event.build(
        vendor: "stripe", endpoint: "/v1/charges/:id", method: "GET",
        outcome: :success, duration_ms: 80, ts: (Time.now.to_f * 1000).to_i,
        status: 200, cold_start: false, env: "test"
      )]

      expect { collector.send(:send_batch, events) }.to raise_error(/503/)
      expect(mock_http).to have_received(:finish)
      expect(collector.instance_variable_get(:@http)).to be_nil
    ensure
      Apidepth.configuration.api_key = nil
    end
  end

  it "reuses the same connection object across consecutive successful flushes" do
    Apidepth.configuration.api_key = "sk_test"
    collector = Apidepth::Collector.new
    http      = mock_connection(collector)

    event = Apidepth::Event.build(
      vendor: "stripe", endpoint: "/v1/charges/:id", method: "GET",
      outcome: :success, duration_ms: 80, ts: (Time.now.to_f * 1000).to_i,
      status: 200, cold_start: false, env: "test"
    )

    collector.record(event)
    collector.send(:safe_flush)

    collector.record(event)
    collector.send(:safe_flush)

    # @http should still be the same mock — not nil'd between successes
    expect(collector.instance_variable_get(:@http)).to equal(http)
  ensure
    Apidepth.configuration.api_key = nil
  end
end

# =============================================================================
# collector_url memoization
# =============================================================================

RSpec.describe "Apidepth::Collector URL memoization" do
  it "validates the collector_url only once across multiple flushes" do
    Apidepth.configuration.api_key = "sk_test"

    response  = double("response", code: "200", body: "{}")
    mock_http = double("Net::HTTP", started?: true, request: response)

    collector = Apidepth::Collector.new
    # Pre-set @http so http_connection returns without TCP setup on every flush
    collector.instance_variable_set(:@http, mock_http)

    call_count = 0
    allow(collector).to receive(:validate_collector_url!).and_wrap_original do |m, *args|
      call_count += 1
      m.call(*args)
    end

    event = Apidepth::Event.build(
      vendor: "stripe", endpoint: "/v1/charges/:id", method: "GET",
      outcome: :success, duration_ms: 80, ts: (Time.now.to_f * 1000).to_i,
      status: 200, cold_start: false, env: "test"
    )

    3.times do
      collector.record(event)
      collector.send(:safe_flush)
    end

    # collector_url is memoized — validate_collector_url! fires exactly once
    # regardless of how many flushes occur
    expect(call_count).to eq(1)
  ensure
    Apidepth.configuration.api_key = nil
  end
end

# =============================================================================
# private_class_method enforcement
# =============================================================================

RSpec.describe "Apidepth::RegistryLoader private class methods" do
  it "fetch_remote is not publicly callable" do
    expect do
      Apidepth::RegistryLoader.fetch_remote
    end.to raise_error(NoMethodError, /private/)
  end

  it "load_from_disk is not publicly callable" do
    expect do
      Apidepth::RegistryLoader.load_from_disk
    end.to raise_error(NoMethodError, /private/)
  end

  it "validate_cache_path! is not publicly callable" do
    expect do
      Apidepth::RegistryLoader.validate_cache_path!("/tmp/test.json")
    end.to raise_error(NoMethodError, /private/)
  end
end

# =============================================================================
# Collector.reset! teardown
# =============================================================================

RSpec.describe "Apidepth::Collector.reset! teardown" do
  it "kills the flush and watchdog threads so they don't outlive the instance" do
    collector = Apidepth::Collector.instance
    flush_thread = collector.instance_variable_get(:@flush_thread)
    watchdog_thread = collector.instance_variable_get(:@watchdog_thread)

    expect(flush_thread).to be_alive
    expect(watchdog_thread).to be_alive

    Apidepth::Collector.reset!

    # Threads are killed synchronously in teardown — give scheduler one tick
    sleep 0.05

    expect(flush_thread).not_to be_alive
    expect(watchdog_thread).not_to be_alive
  end

  it "closes the HTTP connection on reset!" do
    Apidepth.configuration.api_key = "sk_test"
    collector = Apidepth::Collector.instance

    mock_http = double("Net::HTTP", started?: true)
    allow(mock_http).to receive(:finish)
    collector.instance_variable_set(:@http, mock_http)

    Apidepth::Collector.reset!

    expect(mock_http).to have_received(:finish)
  ensure
    Apidepth.configuration.api_key = nil
  end
end

# =============================================================================
# safe_flush skips last_flush_at on empty queue
# =============================================================================

RSpec.describe "Apidepth::Collector last_flush_at semantics" do
  it "does not update last_flush_at when the queue is empty" do
    collector = Apidepth::Collector.new

    # Don't record anything — queue is empty
    collector.send(:safe_flush)

    expect(collector.last_flush_at).to be_nil
  end

  it "updates last_flush_at only after events are successfully delivered" do
    Apidepth.configuration.api_key = "sk_test"
    collector = Apidepth::Collector.new

    response  = double("response", code: "200", body: "{}")
    mock_http = double("Net::HTTP", started?: true, request: response)
    collector.instance_variable_set(:@http, mock_http)

    expect(collector.last_flush_at).to be_nil

    collector.record(Apidepth::Event.build(
                       vendor: "stripe", endpoint: "/v1/charges/:id", method: "GET",
                       outcome: :success, duration_ms: 80, ts: (Time.now.to_f * 1000).to_i,
                       status: 200, cold_start: false, env: "test"
                     ))
    collector.send(:safe_flush)

    expect(collector.last_flush_at).to be_a(Time)
  ensure
    Apidepth.configuration.api_key = nil
  end
end

# =============================================================================
# Configuration: extra_vendors
# =============================================================================

RSpec.describe Apidepth::Configuration do
  after { Apidepth.configuration.extra_vendors = {} }

  it "defaults extra_vendors to an empty hash" do
    expect(Apidepth::Configuration.new.extra_vendors).to eq({})
  end

  it "accepts a hash of vendor_name => host" do
    Apidepth.configuration.extra_vendors = { "my-api" => "api.myservice.com" }
    expect(Apidepth.configuration.extra_vendors).to eq({ "my-api" => "api.myservice.com" })
  end
end

# =============================================================================
# VendorRegistry: extra_vendors
# =============================================================================

RSpec.describe Apidepth::VendorRegistry do
  # Snapshot state before each example, restore after so extra_vendors additions
  # don't bleed across tests.
  before do
    Apidepth.configuration.extra_vendors = {}
  end

  after do
    Apidepth.configuration.extra_vendors = {}
    # Reset registry back to bundled baseline
    Apidepth::VendorRegistry.replace(Apidepth::VendorRegistry::BUNDLED_BASELINE)
  end

  describe ".load_extra_vendors" do
    it "maps a custom host to the given vendor name" do
      Apidepth::VendorRegistry.load_extra_vendors("my-api" => "api.myservice.com")
      vendor, = Apidepth::VendorRegistry.identify("api.myservice.com", "/v1/items")
      expect(vendor).to eq("my-api")
    end

    it "is a no-op for nil input" do
      expect { Apidepth::VendorRegistry.load_extra_vendors(nil) }.not_to raise_error
    end

    it "is a no-op for an empty hash" do
      expect { Apidepth::VendorRegistry.load_extra_vendors({}) }.not_to raise_error
    end

    it "does not affect existing known vendors" do
      Apidepth::VendorRegistry.load_extra_vendors("my-api" => "api.myservice.com")
      vendor, = Apidepth::VendorRegistry.identify("api.stripe.com", "/v1/charges/ch_abc")
      expect(vendor).to eq("stripe")
    end

    it "is thread-safe under concurrent writers" do
      threads = 10.times.map do |i|
        Thread.new do
          Apidepth::VendorRegistry.load_extra_vendors("vendor-#{i}" => "host#{i}.example.com")
        end
      end
      expect { threads.each(&:join) }.not_to raise_error
    end
  end

  describe ".replace" do
    it "preserves extra_vendors after a registry refresh" do
      Apidepth.configuration.extra_vendors = { "my-api" => "api.myservice.com" }

      # Simulate a registry refresh with a new document that doesn't include my-api
      new_registry = {
        "version" => "v2",
        "vendors" => {
          "stripe" => { "hosts" => ["api.stripe.com"], "patterns" => [] }
        }
      }
      Apidepth::VendorRegistry.replace(new_registry)

      vendor, = Apidepth::VendorRegistry.identify("api.myservice.com", "/v1/items")
      expect(vendor).to eq("my-api")
    end

    it "re-applies multiple extra_vendors after a registry refresh" do
      Apidepth.configuration.extra_vendors = {
        "service-a" => "api.service-a.com",
        "service-b" => "api.service-b.io"
      }

      Apidepth::VendorRegistry.replace(Apidepth::VendorRegistry::BUNDLED_BASELINE)

      vendor_a, = Apidepth::VendorRegistry.identify("api.service-a.com", "/v1/foo")
      vendor_b, = Apidepth::VendorRegistry.identify("api.service-b.io", "/v2/bar")
      expect(vendor_a).to eq("service-a")
      expect(vendor_b).to eq("service-b")
    end

    it "uses generic path normalization for extra vendors (no vendor-specific patterns)" do
      Apidepth.configuration.extra_vendors = { "my-api" => "api.myservice.com" }
      Apidepth::VendorRegistry.replace(Apidepth::VendorRegistry::BUNDLED_BASELINE)

      _, path = Apidepth::VendorRegistry.identify("api.myservice.com", "/v1/resources/12345678")
      expect(path).to eq("/v1/resources/:id")
    end

    it "updates the version" do
      new_registry = { "version" => "v99", "vendors" => {} }
      Apidepth::VendorRegistry.replace(new_registry)
      expect(Apidepth::VendorRegistry.version).to eq("v99")
    end
  end
end

# =============================================================================
# Collector: extra_vendors in batch payload
# =============================================================================

RSpec.describe "Collector#send_batch extra_vendors" do
  let(:response)  { double("response", code: "200", body: "{}") }
  let(:mock_http) { double("Net::HTTP", started?: true) }

  before do
    Apidepth.configuration.api_key = "sk_test"
    allow(mock_http).to receive(:request).and_return(response)
  end

  after do
    Apidepth.configuration.api_key = nil
    Apidepth.configuration.extra_vendors = {}
  end

  def make_event
    Apidepth::Event.build(
      vendor: "stripe", endpoint: "/v1/charges/:id", method: "GET",
      outcome: :success, duration_ms: 50, ts: (Time.now.to_f * 1000).to_i,
      status: 200, cold_start: false, env: "test"
    )
  end

  it "includes extra_vendors in the payload when configured" do
    Apidepth.configuration.extra_vendors = { "my-api" => "api.myservice.com" }
    collector = Apidepth::Collector.new
    collector.instance_variable_set(:@http, mock_http)

    collector.send(:send_batch, [make_event])

    # Capture via request spy
    captured_body = nil
    allow(mock_http).to receive(:request) { |req|
      captured_body = req.body
      response
    }
    collector.instance_variable_set(:@http, mock_http)
    collector.send(:send_batch, [make_event])

    body = JSON.parse(captured_body)
    expect(body["extra_vendors"]).to eq({ "my-api" => "api.myservice.com" })
  end

  it "omits extra_vendors key from payload when config is empty" do
    Apidepth.configuration.extra_vendors = {}
    captured_body = nil
    allow(mock_http).to receive(:request) { |req|
      captured_body = req.body
      response
    }

    collector = Apidepth::Collector.new
    collector.instance_variable_set(:@http, mock_http)
    collector.send(:send_batch, [make_event])

    body = JSON.parse(captured_body)
    expect(body).not_to have_key("extra_vendors")
  end

  it "omits extra_vendors key from payload when config is nil" do
    Apidepth.configuration.extra_vendors = nil
    captured_body = nil
    allow(mock_http).to receive(:request) { |req|
      captured_body = req.body
      response
    }

    collector = Apidepth::Collector.new
    collector.instance_variable_set(:@http, mock_http)

    # Should not raise NoMethodError on nil
    expect { collector.send(:send_batch, [make_event]) }.not_to raise_error

    body = JSON.parse(captured_body)
    expect(body).not_to have_key("extra_vendors")
  ensure
    Apidepth.configuration.extra_vendors = {}
  end
end

# =============================================================================
# Integration: full stack
# =============================================================================

RSpec.describe "Integration: full instrumentation stack", :integration do
  before do
    Apidepth.configure do |c|
      c.api_key     = "sk_test_integration"
      c.enabled     = true
      c.sample_rate = 1.0
      c.environment = "test"
    end

    stub_request(:get, "https://api.stripe.com/v1/charges/ch_abc123")
      .to_return(status: 200, body: '{"id":"ch_abc123"}')
  end

  it "captures a real outbound HTTP call and delivers it to the collector with correct shape" do
    captured_body = nil
    response      = double("response", code: "200", body: "{}")
    mock_http     = double("Net::HTTP", started?: true)
    allow(mock_http).to receive(:request) { |req|
      captured_body = req.body
      response
    }

    collector = Apidepth::Collector.instance
    collector.instance_variable_set(:@http, mock_http)

    # Make a real instrumented call — Net::HTTP.prepend is active from spec_helper
    Net::HTTP.get(URI("https://api.stripe.com/v1/charges/ch_abc123"))

    # Flush synchronously so we don't wait for the background thread
    collector.flush!

    expect(captured_body).not_to be_nil, "No batch was delivered to the collector"

    body  = JSON.parse(captured_body)
    event = body["batch"]&.find { |e| e["vendor"] == "stripe" }

    expect(event).not_to be_nil, "No stripe event in batch"
    expect(event["endpoint"]).to eq("/v1/charges/:id")
    expect(event["method"]).to eq("GET")
    expect(event["outcome"]).to eq("success")
    expect(event["status"]).to eq(200)
    expect(event["duration_ms"]).to be_a(Integer).and be >= 0
    expect(event["ts"]).to be > Time.now.to_i * 100 # milliseconds, not seconds
    expect(event["env"]).to eq("test")
    expect([true, false]).to include(event["cold_start"])

    expect(body["sdk"]["name"]).to eq("apidepth-ruby")
  end
end
