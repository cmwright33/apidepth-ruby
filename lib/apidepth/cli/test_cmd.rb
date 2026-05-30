# lib/apidepth/cli/test_cmd.rb
#
# Implements `bundle exec apidepth test`.
#
# Fires a synthetic event to the collector with `"test": true` in the payload.
# The collector writes this to `test_events`, not the main events table.
# Hard 5-second timeout. Per-failure-mode error messages with concrete next steps.

require "net/http"
require "uri"
require "json"
require "apidepth/version"

module Apidepth
  module CLI
    module TestCmd
      DEFAULT_COLLECTOR_URL = "https://collector.apidepth.io".freeze
      TIMEOUT_SECONDS = 5

      def self.run(argv = ARGV)
        api_key, collector_url = _load_config(argv)

        unless api_key
          warn "No API key configured."
          warn "Run `bundle exec apidepth setup` or set APIDEPTH_API_KEY."
          exit 1
        end

        base_url = (collector_url || DEFAULT_COLLECTOR_URL).chomp("/")
        $stdout.print "Sending test event to collector... "

        begin
          elapsed = _send_test_event(api_key, base_url)
          $stdout.puts "✓ received in #{elapsed}ms"
          $stdout.puts "Visit your dashboard: https://apidepth.io/dashboard"
        rescue TestError => e
          $stdout.puts "✗"
          warn "\n#{e.message}"
          warn e.hint if e.hint
          exit 1
        end
      end

      class TestError < StandardError
        attr_reader :hint

        def initialize(msg, hint: nil)
          super(msg)
          @hint = hint
        end
      end

      def self._load_config(_argv)
        # Try the SDK configuration first, fall back to environment variable
        begin
          require "apidepth"
          cfg = Apidepth.configuration
          api_key = cfg.api_key || ENV.fetch("APIDEPTH_API_KEY", nil)
          collector_url = cfg.collector_url || ENV.fetch("APIDEPTH_COLLECTOR_URL", nil)
        rescue StandardError
          api_key = ENV.fetch("APIDEPTH_API_KEY", nil)
          collector_url = ENV.fetch("APIDEPTH_COLLECTOR_URL", nil)
        end
        [api_key, collector_url]
      end

      def self._send_test_event(api_key, base_url)
        uri = URI.parse("#{base_url}/v1/events")
        payload = {
          batch: [
            {
              vendor: "apidepth-test",
              endpoint: "/test",
              method: "GET",
              status: 200,
              outcome: "success",
              duration_ms: 1,
              cold_start: false,
              env: "test",
              ts: (Time.now.to_f * 1000).to_i,
              test: true
            }
          ],
          sdk: { name: "apidepth-ruby", version: Apidepth::VERSION }
        }.to_json

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = TIMEOUT_SECONDS
        http.open_timeout = TIMEOUT_SECONDS

        request = Net::HTTP::Post.new(uri.path.empty? ? "/" : uri.path)
        request["Content-Type"]  = "application/json"
        request["Authorization"] = "Bearer #{api_key}"
        request.body = payload

        # Bypass our own instrumentation
        Thread.current[:apidepth_skip] = true
        response = http.request(request)
        Thread.current[:apidepth_skip] = false

        case response.code.to_i
        when 200, 201, 204
          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
        when 401, 403
          raise TestError.new(
            "API key not recognised (HTTP #{response.code}).",
            hint: "Check the key in your initializer matches your dashboard at https://apidepth.io/dashboard/api-keys"
          )
        else
          raise TestError.new(
            "Collector returned HTTP #{response.code}.",
            hint: "Check https://status.apidepth.io for service status."
          )
        end
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise TestError.new(
          "No response after #{TIMEOUT_SECONDS} seconds.",
          hint: "Check for a firewall blocking outbound port 443."
        )
      rescue OpenSSL::SSL::SSLError => e
        raise TestError.new(
          "SSL certificate verification failed: #{e.message}",
          hint: "Check your Ruby SSL configuration."
        )
      rescue Errno::ECONNREFUSED, SocketError => e
        raise TestError.new(
          "Could not reach #{uri.host}: #{e.message}",
          hint: "Check outbound HTTPS (port 443) is allowed from this environment."
        )
      end
    end
  end
end
