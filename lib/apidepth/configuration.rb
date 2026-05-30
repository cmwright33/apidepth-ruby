# lib/apidepth/configuration.rb

require "set"
require "uri"

module Apidepth
  class Configuration
    # Always ignored regardless of user config. Covers unambiguous loopback
    # addresses — we deliberately avoid wildcard patterns like *.internal here
    # because silently swallowing traffic the developer wants to see is worse
    # than showing mystery vendors. The setup subcommand prompts for custom
    # patterns interactively.
    HARD_IGNORED_HOSTS = %w[localhost 127.0.0.1 0.0.0.0 ::1].freeze

    attr_accessor :api_key,
                  :enabled,
                  :flush_interval,
                  :registry_refresh_interval,
                  :registry_cache_path,
                  :on_flush_error,
                  :environment,      # e.g. "production" — set by Railtie from Rails.env
                  :sample_rate,      # Float 0.0–1.0, default 1.0 (100% of events captured)
                  :extra_vendors     # Hash of vendor_name => host, e.g. { "my-api" => "api.myservice.com" }

    attr_reader :ignored_hosts, :collector_url

    def initialize
      @enabled                   = true
      @flush_interval            = 20
      @registry_refresh_interval = 6 * 60 * 60
      @registry_cache_path       = "/tmp/apidepth_registry.json"
      @collector_url             = nil
      @_user_hosts               = []
      @on_flush_error            = nil
      @environment               = nil   # Railtie sets this to Rails.env at boot
      @sample_rate               = 1.0   # capture everything by default
      @extra_vendors             = {}    # customer-defined host mappings
      _rebuild_ignored_hosts
    end

    def collector_url=(url)
      @collector_url = url
      _rebuild_ignored_hosts
    end

    def ignored_hosts=(hosts)
      @_user_hosts = Array(hosts || [])
      _rebuild_ignored_hosts
    end

    # Returns true if +host+ should be skipped. Supports glob wildcards
    # (* matches any sequence, ? matches one character) so customers can
    # ignore entire internal domains: "*.internal", "*.svc.cluster.local".
    def ignored_host?(host)
      @_exact_ignored.include?(host) ||
        @_glob_ignored.any? { |pat| File.fnmatch(pat, host) }
    end

    private

    def _rebuild_ignored_hosts
      all = HARD_IGNORED_HOSTS.dup + (@_user_hosts || [])
      if @collector_url
        begin
          h = URI.parse(@collector_url).host
          all << h if h
        rescue URI::InvalidURIError
          nil
        end
      end
      @_exact_ignored = all.reject { |p| p.include?("*") || p.include?("?") }.to_set
      @_glob_ignored  = all.select { |p| p.include?("*") || p.include?("?") }
      @ignored_hosts  = Set.new(all)
    end
  end
end
