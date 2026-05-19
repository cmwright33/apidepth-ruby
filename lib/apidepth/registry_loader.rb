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

    # Ruby's `private` keyword does not apply to `def self.method` — those remain
    # public class methods regardless of placement inside a private block.
    # private_class_method is the correct idiom.
    private_class_method :start_refresh_thread, :fetch_remote,
                         :load_from_disk, :validate_cache_path!
  end
end
