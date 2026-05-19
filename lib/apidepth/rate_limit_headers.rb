# lib/apidepth/rate_limit_headers.rb
#
# Extracts rate limit quota state from HTTP response headers and normalises
# them into three canonical fields:
#
#   rl_remaining  — requests left in the current window (integer)
#   rl_limit      — total quota for the window (integer)
#   rl_reset_at   — when the window resets, as epoch milliseconds (integer)
#
# Returns nil when no recognised headers are present so the caller can omit
# the fields from the event rather than sending nulls for every request.
#
# WHY in the SDK rather than the collector?
# Headers are only visible at the HTTP call site. By the time the event
# reaches the collector, only the status code and duration are known.
# Header extraction must happen here, inline with instrumentation.
#
# Header coverage (checked in priority order per field):
#
#   OpenAI / Anthropic:
#     x-ratelimit-remaining-requests, x-ratelimit-limit-requests
#     x-ratelimit-reset-requests  (OpenAI duration format: "1s", "20ms", "1m30s")
#
#   GitHub:
#     x-ratelimit-remaining, x-ratelimit-limit
#     x-ratelimit-reset  (Unix timestamp seconds)
#
#   IETF RateLimit draft / HubSpot / Fastly / others:
#     ratelimit-remaining, ratelimit-limit, ratelimit-reset
#
#   Stripe / generic 429 fallback:
#     retry-after  (seconds from now; only meaningful on 429 responses)

module Apidepth
  module RateLimitHeaders
    # Ordered header names per field — first match wins.
    REMAINING_HEADERS = %w[
      x-ratelimit-remaining-requests
      x-ratelimit-remaining
      ratelimit-remaining
    ].freeze

    LIMIT_HEADERS = %w[
      x-ratelimit-limit-requests
      x-ratelimit-limit
      ratelimit-limit
    ].freeze

    RESET_HEADERS = %w[
      x-ratelimit-reset-requests
      x-ratelimit-reset
      ratelimit-reset
      retry-after
    ].freeze

    # Extract rate limit fields from a Net::HTTP::Response.
    # Returns a Hash with :rl_remaining, :rl_limit, :rl_reset_at keys,
    # or nil if none of the recognised headers are present.
    def self.extract(response, now_ms)
      remaining = find_integer(response, REMAINING_HEADERS)
      limit     = find_integer(response, LIMIT_HEADERS)
      reset_at  = find_reset_ms(response, RESET_HEADERS, now_ms)

      return nil if remaining.nil? && limit.nil? && reset_at.nil?

      { rl_remaining: remaining, rl_limit: limit, rl_reset_at: reset_at }.compact
    end

    # --- private helpers ---

    def self.find_integer(response, headers)
      headers.each do |name|
        val = response[name]
        next unless val

        n = val.strip.to_i
        return n if n >= 0
      end
      nil
    end
    private_class_method :find_integer

    def self.find_reset_ms(response, headers, now_ms)
      headers.each do |name|
        val = response[name]
        next unless val

        ms = normalize_reset_ms(val.strip, now_ms)
        return ms if ms
      end
      nil
    end
    private_class_method :find_reset_ms

    # Normalise a rate limit reset value to epoch milliseconds.
    #
    # Handles three formats:
    #   Unix timestamp  — integer > 1_000_000_000 (e.g. "1716000000")
    #   Seconds-from-now — small integer (e.g. "30" from Retry-After)
    #   OpenAI duration — string like "1s", "20ms", "1m30s", "2h"
    def self.normalize_reset_ms(str, now_ms)
      # Pure numeric
      if str.match?(/\A\d+(?:\.\d+)?\z/)
        n = str.to_f
        return n >= 1_000_000_000 ? (n * 1_000).to_i : now_ms + (n * 1_000).to_i
      end

      # Duration string (OpenAI / Anthropic style)
      duration_ms = parse_duration_ms(str)
      duration_ms ? now_ms + duration_ms : nil
    end
    private_class_method :normalize_reset_ms

    # Parse an OpenAI-style duration string to milliseconds.
    # Handles: "1s" => 1000, "20ms" => 20, "1m30s" => 90000, "2h" => 7200000
    def self.parse_duration_ms(str)
      total = 0
      found = false
      str.scan(/(\d+(?:\.\d+)?)(h|m(?!s)|s|ms)/) do |val, unit|
        found = true
        total += case unit
                 when "h"  then (val.to_f * 3_600_000).to_i
                 when "m"  then (val.to_f * 60_000).to_i
                 when "s"  then (val.to_f * 1_000).to_i
                 when "ms" then val.to_f.to_i
                 else 0
                 end
      end
      found && total.positive? ? total : nil
    end
    private_class_method :parse_duration_ms
  end
end
