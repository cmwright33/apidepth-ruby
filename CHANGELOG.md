# Changelog

All notable changes to this project will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **Extra vendors bidirectional sync** — `RegistryLoader` now reads `customer_vendors`
  from the `/v1/registry` response and applies them via `VendorRegistry.load_extra_vendors`
  after every successful remote fetch. The registry-sourced set takes precedence over
  locally-declared `extra_vendors`; local config continues to serve as the active set
  until the first fetch completes.

- **Conflict warnings** (`apply_customer_vendors`) — if a vendor name appears in both the
  local config and the registry with different hosts, a one-time warn-level log is emitted
  per vendor per process lifetime, identifying the local and remote hosts and noting that
  the registry takes precedence.

- **Stale vendor warnings** (`emit_stale_warnings`) — if the registry response includes
  `warnings.stale_vendors`, a one-time warn-level log is emitted per vendor per process
  lifetime when no events have been received for that vendor in 7+ days.

---

## [0.2.1] — 2026-05-21

### Added

- **Missing API key warning** — non-Rails installs (plain Ruby, Sinatra, etc.) now log a
  one-time `warn` on the first flush attempt when no `api_key` is configured, pointing to
  `www.apidepth.io` to create an account. Previously events were silently dropped with no
  feedback outside of a Rails boot-time message. The warning fires at most once per process
  (or per Puma worker after `reset!`) and does not repeat on subsequent flushes.

### Fixed

- **Load-order bug** — `VendorRegistry.initialize_registry` called `Apidepth.logger` at
  require time before the logger was defined, causing `NoMethodError` on Ruby 4.0.
  The bundled baseline now loads silently without touching the logger.

- **Empty `api_key` now skips the flush** instead of sending a broken `Authorization: Bearer `
  header and burning a consecutive-failure increment. The Railtie already warns at boot for
  nil keys; empty strings are now treated the same way.

- **`flush!` (at-exit path) now calls `on_flush_error`** and increments `consecutive_failures`
  on failure, consistent with `safe_flush`. Previously, at-exit flush failures were silently
  swallowed beyond a log warning.

- **`RegistryLoader.fetch_remote` now closes its HTTP connection** in an `ensure` block.
  Previously the connection was left open for GC to eventually close.

- **`collector_url` memoization is now documented** — changing `configuration.collector_url`
  after the first flush has no effect; this is intentional but was previously undocumented.

### Changed

- `json` dependency floor raised from `>= 2.7.2` to `>= 2.19.2` to exclude versions
  affected by **CVE-2026-33210** (CVSS 9.1 — format string injection when
  `allow_duplicate_key: false` is used to parse user-supplied input).

### Removed

- `lib/apidepth/core.rb` tombstone file deleted. It contained only a comment directing
  users to the correct require paths and served no functional purpose.

### Security

- Removed dead `respond_to?(:name=)` guards on thread naming — `Thread#name=` is available
  since Ruby 2.3 and the gem requires 2.7+.

---

## [0.1.0] — 2026-05-11

Initial release.

### Added

**Core instrumentation**
- Passive outbound HTTP capture via `Module#prepend` on `Net::HTTP` — instruments Faraday, HTTParty, RestClient, and plain `Net::HTTP` with a single hook
- Per-event tagging: vendor slug, normalized endpoint path, HTTP method, status code, outcome (`:success`, `:client_error`, `:server_error`, `:timeout`, `:unknown`), duration in milliseconds, cold-start flag, environment, millisecond-resolution Unix timestamp
- Timeout capture — `Net::ReadTimeout` and `Net::OpenTimeout` are recorded as `:timeout` events and re-raised; previously invisible in any monitoring tool
- Cold-start tagging — first request to a vendor pays for DNS + SSL handshake; this flag lets the collector exclude warmup latency from percentile calculations
- Sample rate support — `config.sample_rate` (0.0–1.0) for high-traffic applications

**Vendor registry**
- Bundled baseline covering Stripe, OpenAI, Anthropic, Twilio, Resend, GitHub
- Remote registry hot-swap — vendor patterns fetched from Apidepth servers every 6 hours, applied without gem update or process restart
- Three-tier fallback: remote fetch → disk cache → bundled baseline
- Path normalization strips resource IDs before events leave your server (`/v1/charges/ch_abc` → `/v1/charges/:id`)
- Generic normalizers for UUIDs, numeric IDs, and long hex tokens not covered by vendor-specific rules

**Collector**
- Thread-safe singleton with class-level mutex — no duplicate flush threads on concurrent boot
- Persistent HTTP connection to the collector — single SSL handshake per process lifetime, not per flush
- Background flush thread batching up to 100 events every 20 seconds
- Watchdog thread — detects flush thread death and restarts it; logs a warning with instructions to file an issue
- `reset!` — kills background threads and closes the HTTP connection cleanly before clearing the singleton; safe to call in Puma `on_worker_boot`
- Backpressure — events silently dropped when queue exceeds 5,000; `total_dropped` counter tracks discards
- `stats` method — exposes `queue_size`, `consecutive_failures`, `total_dropped`, `last_flush_at` for health checks and dashboards
- `last_flush_at` only updated on actual event delivery, not on empty-queue flush ticks
- `on_flush_error` callback — route flush failures to Sentry, Honeybadger, Bugsnag, or any error tracker
- Consecutive failure tracking — warn-level log after 3 consecutive failures with actionable message

**Event schema**
- `Event.build` validates required fields at creation time — bugs surface in tests, not in production data
- Frozen hash output — immutable after creation, serializes directly via `JSON.generate`
- SDK metadata in every batch payload — Ruby version, platform, Rails version, app server

**Rails integration**
- Railtie wires instrumentation automatically after all initializers run
- Sets `config.environment` from `Rails.env` at boot — `resolve_env` is a cheap attribute read on the hot path, not a `defined?` check per request
- Nil `api_key` produces a warn-level log at boot rather than silent 401 failures at flush time
- `at_exit` flush — drains queue on graceful shutdown (SIGTERM)
- `ActiveSupport::ForkTracker` integration for Puma cluster mode on Rails 7.1+
- Warn-level log when Puma is detected but `ForkTracker` is unavailable (Rails < 7.1)

**Security**
- SSRF protection — `collector_url` must use HTTPS; private IP ranges, loopback, link-local, and decimal IP representations (e.g. `2130706433` = `127.0.0.1`) are rejected
- HTTP header injection guard — CRLF in `api_key` raises `ArgumentError` before the Authorization header is set
- Log injection sanitization — untrusted strings from the remote registry are stripped of `\r`, `\n`, `\t` before logging
- Path traversal validation on `registry_cache_path` — absolute paths only, no `..` segments
- Remote registry pattern validation — embedded code constructs and malformed regex patterns in registry responses are rejected with a warning
- Registry response size limit — responses over 512KB are rejected before parsing
- Explicit `OpenSSL::SSL::VERIFY_PEER` on all outbound connections — no reliance on platform defaults
- `private_class_method` on `RegistryLoader` internal methods — not part of the public API
- Error messages never include `api_key`, response bodies, or Authorization headers

**Testing**
- 116 RSpec examples covering unit, integration, security, and concurrency behavior
- WebMock for all HTTP stubs — no live network required
- Integration test exercises the full stack from `Net::HTTP.get` through instrumentation, event schema, collector, and batch delivery
- Test suite runnable with `bundle exec rspec` after `bundle install`

### Compatibility

- Ruby 2.7+
- Rails 6.1+
- Rack 2.2.12+ (CVE-2025-27111)

---

[Unreleased]: https://github.com/apidepth/apidepth-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/apidepth/apidepth-ruby/releases/tag/v0.1.0
