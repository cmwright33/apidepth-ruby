#!/usr/bin/env ruby
# frozen_string_literal: true

#
# End-to-end integration test for the apidepth Ruby gem.
#
# Exercises the full pipeline:
#   Net::HTTP instrumentation → event capture → flush → collector ingest → query
#
# The script makes a real outbound HTTPS call to api.stripe.com (expecting a 401)
# so the gem captures a genuine event from a real TCP round-trip, then flushes to
# the collector and verifies the event was recorded via the collector's query API.
#
# Usage:
#   COLLECTOR_URL=https://apidepth-collector-qa.up.railway.app \
#   API_KEY=apd_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
#   /usr/local/opt/ruby@3.2/bin/ruby scripts/integration_test.rb
#
# Note: COLLECTOR_URL is the base URL. The gem's collector_url config is set
# to COLLECTOR_URL/v1/events (the full ingest endpoint) internally.
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

require "bundler/setup"
require "apidepth"
require "net/http"
require "uri"
require "json"

# Outside Rails the Railtie never runs, so we must wire up the instrumentation
# manually. In a real Rails app this is handled automatically by the Railtie.
Net::HTTP.prepend(Apidepth::NetHTTPInstrumentation)

# Base URL for query API calls (vendors, endpoints, latency).
COLLECTOR_URL = ENV.fetch("COLLECTOR_URL", "").chomp("/")
API_KEY       = ENV.fetch("API_KEY", "")
# The gem's collector_url config is the full ingest endpoint, not just the base.
EVENTS_URL    = "#{COLLECTOR_URL}/v1/events"
# Use a per-run env tag so results are isolated from previous runs
ENV_TAG       = "integration-#{Process.pid}"

PASS = "\033[32m✓\033[0m"
FAIL = "\033[31m✗\033[0m"

def check(label, passed, detail = nil)
  icon = passed ? PASS : FAIL
  suffix = detail ? "  (#{detail})" : ""
  puts "  #{icon}  #{label}#{suffix}"
  passed
end

def collector_get(path, params = {})
  uri = URI("#{COLLECTOR_URL}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{API_KEY}"
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 10) do |http|
    http.request(req)
  end
end

if COLLECTOR_URL.empty? || API_KEY.empty?
  warn "Usage: COLLECTOR_URL=https://... API_KEY=apd_... ruby scripts/integration_test.rb"
  exit 1
end

puts "\nGem integration test → #{COLLECTOR_URL}"
puts "  env=#{ENV_TAG}"

failures = 0

# ── Configure ─────────────────────────────────────────────────────────────────
puts "\n[ Configure ]"
Apidepth.configure do |config|
  config.api_key       = API_KEY
  config.collector_url = EVENTS_URL
  config.environment   = ENV_TAG
  config.enabled       = true
end
failures += 1 unless check("Gem configured with collector URL and API key",
                           Apidepth.configuration.api_key == API_KEY)

# ── Instrumented outbound call ─────────────────────────────────────────────────
# Stripe returns 401 for an unauthenticated request — we just need a real
# round-trip so the gem captures a genuine event via Net::HTTP instrumentation.
puts "\n[ Instrumentation ]"
begin
  Net::HTTP.get_response(URI("https://api.stripe.com/v1/charges"))
  failures += 1 unless check("Outbound call to api.stripe.com completed (401 expected)", true)
rescue StandardError => e
  failures += 1
  check("Outbound call to api.stripe.com completed", false, e.message)
end

# ── Flush ──────────────────────────────────────────────────────────────────────
puts "\n[ Flush ]"
begin
  Apidepth::Collector.instance.flush!
  failures += 1 unless check("flush! delivered events without raising", true)
rescue StandardError => e
  failures += 1
  check("flush! delivered events without raising", false, e.message)
end

# ── Verify via collector API ───────────────────────────────────────────────────
puts "\n[ Verify ]"

begin
  r = collector_get("/v1/vendors")
  vendors = JSON.parse(r.body).fetch("vendors", [])
  failures += 1 unless check(
    "vendor 'stripe' appears in GET /v1/vendors",
    vendors.include?("stripe"),
    vendors.include?("stripe") ? nil : "got #{vendors.inspect}"
  )
rescue StandardError => e
  failures += 1
  check("GET /v1/vendors", false, e.message)
end

begin
  # The collector's /v1/endpoints defaults env="production" if not provided.
  # Pass the gem's actual configured environment so the query matches.
  gem_env = Apidepth.configuration.environment
  r = collector_get("/v1/endpoints", vendor: "stripe", env: gem_env)
  ok = r.code.to_i == 200
  endpoints = ok ? JSON.parse(r.body).fetch("endpoints", []) : []
  failures += 1 unless check(
    "endpoint recorded in GET /v1/endpoints?vendor=stripe&env=#{gem_env}",
    ok && !endpoints.empty?,
    if ok
      endpoints.empty? ? "endpoints list is empty" : nil
    else
      "status #{r.code}"
    end
  )
rescue StandardError => e
  failures += 1
  check("GET /v1/endpoints", false, e.message)
end

# ── Stats sanity check ─────────────────────────────────────────────────────────
# stats keys: queue_size, consecutive_failures, total_dropped, last_flush_at
puts "\n[ SDK stats ]"
stats = Apidepth::Collector.instance.stats
failures += 1 unless check(
  "queue drained after flush (queue_size == 0)",
  stats[:queue_size].zero?,
  "queue_size=#{stats[:queue_size]}"
)
failures += 1 unless check(
  "consecutive_failures is 0",
  stats[:consecutive_failures].zero?,
  "consecutive_failures=#{stats[:consecutive_failures]} total_dropped=#{stats[:total_dropped]}"
)

# ── Result ─────────────────────────────────────────────────────────────────────
puts
if failures.zero?
  puts "#{PASS} All checks passed"
  exit 0
else
  puts "#{FAIL} #{failures} check(s) failed"
  exit 1
end
