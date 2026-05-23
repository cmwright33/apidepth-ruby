# apidepth

[![Gem Version](https://img.shields.io/gem/v/apidepth)](https://rubygems.org/gems/apidepth)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%202.7-ruby)](https://rubygems.org/gems/apidepth)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Most API monitoring tools measure latency from their servers to the vendor. That's not what your users feel. Apidepth instruments `Net::HTTP` directly — every outbound call your app makes to Stripe, OpenAI, or Twilio is timed at the socket level, from your server. Then it benchmarks your numbers against anonymized fleet data, so when Stripe is slow you can tell if it's you or everyone.

No payload capture. No credentials touch our infrastructure. No changes to your application code beyond a one-time initializer.

---

## How it works

**Real traffic, not synthetic probes.** Every outbound HTTP call your application makes to a known vendor is timed at the socket level, tagged with outcome and environment metadata, and batched to the Apidepth collector in the background. The latency number in your dashboard is the number your users feel — not a probe running from a data center somewhere else.

**Fleet benchmarking.** Because Apidepth aggregates anonymized timing data across all customers, your dashboard shows not just "your Stripe p95 is 420ms" but "the fleet median is 280ms — you may have a regional routing issue." That comparison is only possible with real traffic from real deployments, which is why no synthetic probe tool can offer it.

**Proof of Innocence.** When all endpoints to a vendor spike simultaneously, Apidepth surfaces a verdict: *isolated* (the spike is yours alone — likely your code or infrastructure) or *tracking* (the fleet sees the same thing — vendor-side). The attribution card makes it fast to tell ops "it's Stripe, not us."

**Alerts and weekly digest.** Apidepth fires alerts when vendor latency crosses your configured threshold and sends a weekly digest summarizing what changed. Monitoring without alerting is passive; this is working for you.

**Rate limit intelligence.** Apidepth tracks 429 patterns and projects quota burn-down before you hit the ceiling — with a burn-down card showing time-to-throttle at current request rate.

---

## Installation

Add to your `Gemfile`:

```ruby
gem "apidepth"
```

Run:

```
bundle install
```

---

## Quick start

Create `config/initializers/apidepth.rb`:

```ruby
Apidepth.configure do |config|
  config.api_key = ENV["APIDEPTH_API_KEY"]
end
```

That's it. The Railtie wires the instrumentation automatically. No code changes elsewhere.

Get your API key at [apidepth.io](https://apidepth.io).

---

## Configuration

All options with their defaults:

```ruby
Apidepth.configure do |config|
  # Required. Your account API key.
  config.api_key = ENV["APIDEPTH_API_KEY"]

  # Disable in test environments. Default: true.
  config.enabled = !Rails.env.test?

  # Fraction of events to capture. 1.0 = 100%, 0.1 = 10%.
  # Use a lower value if your application makes thousands of vendor
  # calls per minute and you want to reduce collector traffic.
  # Default: 1.0
  config.sample_rate = 1.0

  # Hosts to exclude from instrumentation entirely.
  # Useful for internal services or staging vendors you don't want measured.
  # Default: []
  config.ignored_hosts = ["api.internal.mycompany.com"]

  # Override the environment tag on events. Defaults to Rails.env at boot.
  # Only set this if you need something other than Rails.env — for example,
  # if you want to distinguish "production-us" from "production-eu".
  # Default: Rails.env (set automatically by the Railtie)
  config.environment = "production-us"

  # Called on every flush failure, in addition to the built-in warn log.
  # Use this to route failures to your existing error tracker.
  # Default: nil
  config.on_flush_error = ->(error, context) {
    Sentry.capture_exception(error, extra: context)
  }

  # How often (in seconds) background events are batched and sent.
  # Lower values reduce per-flush event volume; higher values reduce
  # collector traffic. Default: 20
  config.flush_interval = 20

  # Path for the local vendor registry cache. Must be an absolute path.
  # The registry is fetched from Apidepth's servers and cached here so
  # cold starts don't block on a network fetch.
  # Default: "/tmp/apidepth_registry.json"
  config.registry_cache_path = "/tmp/apidepth_registry.json"

  # Custom vendors your app calls that aren't in the global registry.
  # Key: vendor name (matches the vendor field in your dashboard).
  # Value: the hostname the SDK should watch for.
  # Tracking starts immediately at boot — no dashboard visit required.
  # Mappings sync to your dashboard automatically on the next event flush.
  # Default: {}
  config.extra_vendors = {
    "my-payments-api" => "api.payments.internal.com",
    "fulfillment"     => "fulfillment.myco.io",
  }
end
```

---

## What gets captured

Every event contains:

| Field | Description |
|-------|-------------|
| `vendor` | Vendor slug, e.g. `"stripe"`, `"openai"` |
| `endpoint` | Normalized path, e.g. `"/v1/charges/:id"` |
| `method` | HTTP verb: `"GET"`, `"POST"`, etc. |
| `status` | HTTP status code, or `nil` on timeout |
| `outcome` | `:success`, `:client_error`, `:server_error`, `:timeout`, `:unknown` |
| `duration_ms` | Wall-clock time in milliseconds, including DNS and SSL on first connection |
| `cold_start` | `true` if this request paid for SSL handshake; excluded from p95 calculations |
| `env` | Environment tag from `config.environment` or `Rails.env` |
| `ts` | Unix timestamp in milliseconds |

### What is never captured

- Request or response **bodies**
- Request or response **headers** (including Authorization)
- **Query string parameters**
- Any credential, token, or secret your application uses to authenticate with a vendor
- User identifiers or PII of any kind

Path normalization strips resource IDs before the event leaves your server. `/v1/charges/ch_3Ox4Kz2e` becomes `/v1/charges/:id`. If a vendor's path contains something that looks like user data (an email address in a path segment, for example), it may not be normalized — review your vendor's URL structure if this is a concern.

---

## Supported vendors

The bundled registry covers the following vendors out of the box. New vendors and endpoint patterns are pushed to all SDK installs via the remote registry without requiring a gem update.

| Vendor | Host |
|--------|------|
| Stripe | `api.stripe.com` |
| OpenAI | `api.openai.com` |
| Anthropic | `api.anthropic.com` |
| Twilio | `api.twilio.com` |
| Resend | `api.resend.com` |
| GitHub | `api.github.com` |

Calls to hosts not in the registry are ignored by default. Use `config.extra_vendors` to track additional hosts — internal APIs, homegrown services, or vendors not yet in the global registry. Custom vendors use generic path normalization (UUID stripping, long numeric ID stripping) rather than vendor-specific patterns.

To request a vendor be added to the global registry: [open an issue](https://github.com/apidepth/apidepth-ruby/issues).

---

## Rate limit header extraction (v0.2.0+)

When a vendor response includes rate limit quota headers, the SDK automatically extracts them and attaches three fields to the event: `rl_remaining`, `rl_limit`, and `rl_reset_at`. The collector uses these to power the burn-down projection on the Rate Limits dashboard page.

No configuration is needed. Header extraction is passive and adds no overhead when headers are absent — `RateLimitHeaders.extract` returns `nil` and the fields are omitted from the event.

### Supported headers

Headers are checked in priority order per field:

| Field | Headers (checked in order) |
|-------|---------------------------|
| remaining | `x-ratelimit-remaining-requests`, `x-ratelimit-remaining`, `ratelimit-remaining` |
| limit | `x-ratelimit-limit-requests`, `x-ratelimit-limit`, `ratelimit-limit` |
| reset_at | `x-ratelimit-reset-requests`, `x-ratelimit-reset`, `ratelimit-reset`, `retry-after` |

The `reset_at` value is normalised to epoch milliseconds regardless of vendor format:
- **Unix timestamp** (`n ≥ 1 × 10⁹`) — GitHub, HubSpot, IETF draft
- **Seconds from now** (small integer) — Stripe `Retry-After` on 429
- **Duration string** (`"1s"`, `"20ms"`, `"1m30s"`) — OpenAI, Anthropic

Vendors with no quota headers on 2xx responses (Twilio, Salesforce, Jira, Zendesk, Slack) still contribute to 429 frequency tracking — the collector counts `status = 429` events regardless of SDK version.

---

## Puma cluster mode

The Railtie handles `after_fork` automatically on Rails 7.1+ via `ActiveSupport::ForkTracker`. If you're on Rails 6.x or 7.0, add one line to `config/puma.rb` to ensure each worker gets a clean collector instance:

```ruby
# config/puma.rb
on_worker_boot { Apidepth::Collector.reset! }
```

To flush the master process queue before workers fork (recommended):

```ruby
# config/puma.rb
before_fork { Apidepth::Collector.instance.flush! }
on_worker_boot { Apidepth::Collector.reset! }
```

---

## Debugging

Check the collector's internal state from a Rails console:

```ruby
Apidepth::Collector.instance.stats
# => {
#      queue_size: 0,
#      consecutive_failures: 0,
#      total_dropped: 0,
#      last_flush_at: 2026-05-11 14:32:07 UTC
#    }
```

`last_flush_at` is only updated when events are actually delivered to the collector. If it's nil or stale, check your `api_key` and network connectivity.

`total_dropped` counts events discarded due to backpressure (queue full). A non-zero value means your flush interval is too long for your traffic volume — lower `config.flush_interval` or raise `config.sample_rate` below 1.0.

If flush errors are reaching `on_flush_error`, the error message includes the HTTP status code without echoing back credentials or response bodies.

---

## Compatibility

| | Minimum |
|-|---------|
| Ruby | 2.7 |
| Rails | 6.1 |
| Rack | 2.2.12 |

The gem uses `Module#prepend` to instrument `Net::HTTP`. Most HTTP clients in the Ruby ecosystem (`Faraday`, `HTTParty`, `RestClient`, `http.rb`) delegate to `Net::HTTP` internally and are instrumented automatically without additional configuration.

If another gem in your stack uses `alias_method` to redefine `Net::HTTP#request` after the Apidepth initializer runs, instrumentation will be silently bypassed. Symptoms: events stop appearing in your dashboard. Fix: move `require "apidepth"` or the initializer to load last. Known affected gems: none currently identified.

Fiber-based servers (Falcon, Async::HTTP): `Thread.current` locals used by Apidepth are not inherited by fibers. Instrumentation is skipped for requests running in a fiber context. Support is on the roadmap.

---

## Contributing

```
git clone https://github.com/apidepth/apidepth-ruby
cd apidepth-ruby
bundle install
bundle exec rspec
```

The test suite requires no external services — all HTTP is stubbed via WebMock.

For end-to-end verification against a live collector, use the integration test script:

```bash
COLLECTOR_URL=https://your-collector.railway.app \
API_KEY=apd_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
ruby scripts/integration_test.rb
```

This exercises the full pipeline: `Net::HTTP` instrumentation → event capture → flush → collector ingest → query API verification. It requires a running collector and a valid API key. It is separate from the unit suite and does not run in CI.

To add a vendor to the bundled registry, edit `BUNDLED_BASELINE` in `lib/apidepth/vendor_registry.rb` and add corresponding tests to `spec/apidepth/sdk_spec.rb`. Path normalization patterns should be ordered most-specific first.

---

## License

MIT. See [LICENSE](LICENSE).
