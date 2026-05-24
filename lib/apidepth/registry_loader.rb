# lib/apidepth/registry_loader.rb

require "net/http"
require "json"
require "uri"

module Apidepth
  class RegistryLoader
    REGISTRY_URL = "https://collector.apidepth.io/v1/registry".freeze

    # Called by the Railtie after_initialize. Loads the best available
    # registry (remote → disk cache → bundled baseline already loaded by
    # VendorRegistry.initialize_registry) and starts the background
    # refresh thread.
    def self.load_and_start
      registry = fetch_remote || load_from_disk
      VendorRegistry.replace(registry) if registry
      start_refresh_thread
    end

    private

    def self.start_refresh_thread
      Thread.new do
        loop do
          sleep Apidepth.configuration.registry_refresh_interval
          registry = fetch_remote
          VendorRegistry.replace(registry) if registry
        end
      end.tap do |t|
        t.abort_on_exception = false
        t.name = "apidepth-registry"
      end
    end

    def self.fetch_remote
      Thread.current[:apidepth_skip] = true

      http = nil
      uri  = URI(REGISTRY_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = 5

      res = http.get(uri.path, "Authorization" => "Bearer #{Apidepth.configuration.api_key}")
      return nil unless res.code.to_i == 200

      # Ceiling on response size before parsing — a legitimate registry is ~10KB.
      # Parsing an unbounded body could consume significant memory if the endpoint
      # is compromised or misconfigured.
      if res.body.bytesize > 512_000
        Apidepth.logger&.warn("[Apidepth] Registry response too large (#{res.body.bytesize} bytes) — skipping")
        return nil
      end

      registry = JSON.parse(res.body)

      # Apply registry-managed customer vendors and emit developer warnings.
      # Must run before replace() so the vendor list is complete when it lands.
      apply_customer_vendors(registry)
      emit_warnings(registry)

      # Warm the disk cache so the next cold-start skips the network fetch.
      begin
        validate_cache_path!(Apidepth.configuration.registry_cache_path)
        File.write(Apidepth.configuration.registry_cache_path, res.body)
      rescue ArgumentError => e
        Apidepth.logger&.warn("[Apidepth] Invalid registry_cache_path: #{e.message}")
      rescue StandardError => e
        Apidepth.logger&.warn("[Apidepth] Could not write registry cache: #{Apidepth.sanitize_log(e.message)}")
      end

      registry
    rescue StandardError
      nil
    ensure
      begin
        http&.finish
      rescue StandardError
        nil
      end
      Thread.current[:apidepth_skip] = false
    end

    # Apply the collector-managed customer_vendors from the registry response.
    #
    # The collector is the source of truth after first declaration. Registry
    # vendors are loaded on top of locally-declared extra_vendors; registry wins
    # on any host conflict. Conflict warnings are emitted once per vendor per
    # process lifetime (see emit_warnings).
    def self.apply_customer_vendors(registry)
      remote = registry["customer_vendors"]
      return unless remote.is_a?(Hash) && !remote.empty?

      local = Apidepth.configuration.extra_vendors || {}

      # Filter to string key-value pairs before passing to load_extra_vendors.
      # The server response is trusted but load_extra_vendors calls .to_s on
      # everything — a non-string key like 42 would silently register as "42".
      clean = {}
      remote.each do |name, remote_host|
        next unless name.is_a?(String) && remote_host.is_a?(String)

        clean[name] = remote_host
        local_host = local[name]
        # Track conflicts before overwriting — emit_warnings reads this later.
        @mutex.synchronize do
          if local_host && local_host != remote_host
            @conflict_vendors ||= {}
            @conflict_vendors[name] = { local: local_host, remote: remote_host }
          end
        end
      end

      VendorRegistry.load_extra_vendors(clean)
    end

    # Emit developer-facing warnings from the registry response.
    #
    # Stale vendor warning: vendor exists in registry but no events in 7+ days.
    # Conflict warning:     local extra_vendors host differs from registry host.
    #
    # Both follow the warn-once pattern — an instance flag per vendor prevents
    # log spam in long-running processes. Warnings fire on registry fetch, not
    # on every event.
    def self.emit_warnings(registry)
      # Stale vendor warnings — sourced from the registry warnings block.
      # Only present in responses from collector v0.3+; older cached responses skip.
      warnings = registry["warnings"]
      emit_stale_warnings(warnings["stale_vendors"]) if warnings.is_a?(Hash)

      # Conflict warnings — collected by apply_customer_vendors, emitted here.
      # Fires regardless of whether the registry has a warnings block, so that
      # conflicts detected against a cached/older registry are still surfaced.
      emit_conflict_warnings
    end

    def self.emit_stale_warnings(stale)
      return unless stale.is_a?(Array)

      to_warn = []
      @mutex.synchronize do
        @warned_stale ||= {}
        stale.each do |name|
          next unless name.is_a?(String)
          next if @warned_stale[name]

          @warned_stale[name] = true
          to_warn << name
        end
      end

      to_warn.each do |name|
        Apidepth.logger&.warn(
          "[Apidepth] No events received from '#{name}' in 7+ days — " \
          "is it still declared in extra_vendors? If intentional, remove " \
          "it at www.apidepth.io."
        )
      end
    end

    def self.emit_conflict_warnings
      conflicts, = @mutex.synchronize do
        c = @conflict_vendors || {}
        @conflict_vendors = {}
        @warned_conflict ||= {}
        to_warn = c.reject { |name, _| @warned_conflict[name] }
        to_warn.each_key { |name| @warned_conflict[name] = true }
        [to_warn]
      end

      conflicts.each do |name, hosts|
        Apidepth.logger&.warn(
          "[Apidepth] extra_vendors conflict: '#{name}' is configured as " \
          "'#{hosts[:local]}' locally but the registry has '#{hosts[:remote]}' " \
          "— registry takes precedence. Update your initializer or remove " \
          "the entry from your dashboard at www.apidepth.io."
        )
      end
    end

    def self.load_from_disk
      path = Apidepth.configuration.registry_cache_path

      validate_cache_path!(path)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue ArgumentError => e
      Apidepth.logger&.warn("[Apidepth] Invalid registry_cache_path: #{e.message}")
      nil
    rescue StandardError => e
      Apidepth.logger&.warn("[Apidepth] Could not read registry cache: #{Apidepth.sanitize_log(e.message)}")
      nil
    end

    # Validates the cache path before any file operation.
    #
    # Requires an absolute path with no traversal segments. Without this, a
    # misconfigured registry_cache_path like "../../etc/cron.d/apidepth" would
    # cause us to write registry JSON into sensitive system directories.
    # The content is our controlled JSON, but the behaviour is still wrong and
    # surprising to audit.
    def self.validate_cache_path!(path)
      unless path.is_a?(String) && path.start_with?("/")
        raise ArgumentError, "registry_cache_path must be an absolute path (got #{path.inspect})"
      end

      return unless path.split("/").include?("..")

      raise ArgumentError, "registry_cache_path must not contain '..' traversal segments (got #{path.inspect})"
    end

    # Reset mutable class-level warn state under @mutex.
    # Called by tests instead of raw instance_variable_set so that state
    # changes go through the same lock used in production code paths.
    def self.reset_state!
      @mutex.synchronize do
        @conflict_vendors = {}
        @warned_stale     = {}
        @warned_conflict  = {}
      end
    end

    # Ruby's `private` keyword does not apply to `def self.method` — those remain
    # public class methods regardless of placement inside a private block.
    # private_class_method is the correct idiom.
    private_class_method :start_refresh_thread, :fetch_remote,
                         :load_from_disk, :validate_cache_path!,
                         :apply_customer_vendors, :emit_warnings,
                         :emit_stale_warnings, :emit_conflict_warnings

    # Mutex protecting @conflict_vendors, @warned_stale, and @warned_conflict.
    # Initialized at require time like VendorRegistry's own @mutex.
    @mutex = Mutex.new
  end
end
