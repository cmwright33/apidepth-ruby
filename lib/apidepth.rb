# lib/apidepth.rb
#
# Main entry point. Require order matters:
#   1. version       — no dependencies
#   2. configuration — no dependencies
#   3. vendor_registry — no dependencies, boots from BUNDLED_BASELINE immediately
#   4. rate_limit_headers — no dependencies; used by net_http_instrumentation
#   5. net_http_instrumentation — depends on vendor_registry + collector (via lazy reference)
#   5. collector     — depends on configuration
#   6. registry_loader — depends on collector + vendor_registry
#   7. railtie       — depends on all of the above; only loaded in a Rails context

require "logger"
require "apidepth/version"
require "apidepth/configuration"
require "apidepth/event"
require "apidepth/vendor_registry"
require "apidepth/rate_limit_headers"
require "apidepth/net_http_instrumentation"
require "apidepth/collector"
require "apidepth/registry_loader"
require "apidepth/railtie" if defined?(Rails::Railtie)

module Apidepth
  class << self
    attr_writer :logger

    def logger
      @logger ||= Logger.new($stdout)
    end

    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # Computed once and frozen. Included in every batch payload so the collector
    # can correlate data quality issues with specific SDK versions, Ruby runtimes,
    # and app servers without needing the customer to file a support ticket.
    def sdk_metadata
      @sdk_metadata ||= {
        name: "apidepth-ruby",
        version: VERSION,
        ruby_version: RUBY_VERSION,
        ruby_platform: RUBY_PLATFORM,
        rails_version: (defined?(Rails) ? Rails.version : nil),
        app_server: detect_app_server
      }.compact.freeze
    end

    def detect_app_server
      return "puma"      if defined?(Puma)
      return "unicorn"   if defined?(Unicorn)
      return "passenger" if defined?(PhusionPassenger)

      "unknown"
    end

    # Strips line-break characters from untrusted strings before they reach
    # log output. Prevents log injection (CVE-2025-27111 class of attack).
    def sanitize_log(str)
      str.to_s.gsub(/[\r\n\t]/, " ").slice(0, 200)
    end
  end
end
