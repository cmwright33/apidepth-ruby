# lib/apidepth/collector.rb

require "net/http"
require "json"
require "uri"

module Apidepth
  class Collector
    MAX_BATCH_SIZE    = 100
    MAX_QUEUE_SIZE    = 5_000
    FAILURE_THRESHOLD = 3
    WATCHDOG_INTERVAL = 60

    DEFAULT_URL = "https://collector.apidepth.io/v1/events"

    @instance_mutex = Mutex.new

    def self.instance
      @instance_mutex.synchronize { @instance ||= new }
    end

    # Tear down the existing Collector cleanly before clearing the singleton.
    # Without teardown, every reset! leaks a flush thread and a watchdog thread.
    # This matters in Puma cluster mode — on_worker_boot calls reset! per worker.
    def self.reset!
      @instance_mutex.synchronize do
        @instance&.send(:teardown)
        @instance = nil
      end
    end

    attr_reader :consecutive_failures, :total_dropped, :last_flush_at

    def initialize
      @queue                = Queue.new
      @stats_mutex          = Mutex.new
      @send_mutex           = Mutex.new
      @consecutive_failures = 0
      @total_dropped        = 0
      @last_flush_at        = nil
      @http                 = nil
      @cached_url           = nil

      start_flush_thread
      start_watchdog_thread
    end

    def record(event)
      if @queue.size >= MAX_QUEUE_SIZE
        @stats_mutex.synchronize { @total_dropped += 1 }
        return
      end
      @queue.push(event)
    end

    def flush!
      events = drain_queue
      return if events.empty?

      send_batch(events)

      # Mirror safe_flush's stats update so last_flush_at reflects at_exit
      # delivery, not just background flushes.
      @stats_mutex.synchronize do
        @consecutive_failures = 0
        @last_flush_at        = Time.now
      end
    rescue StandardError => e
      failures = @stats_mutex.synchronize { @consecutive_failures += 1 }

      begin
        Apidepth.configuration.on_flush_error&.call(e, {
          dropped_events:       events&.size || 0,
          consecutive_failures: failures,
          total_dropped:        @total_dropped
        })
      rescue StandardError
        nil
      end

      Apidepth.logger&.warn("[Apidepth] Final flush failed: #{e.class}: #{e.message}")
    end

    def stats
      @stats_mutex.synchronize do
        {
          queue_size:           @queue.size,
          consecutive_failures: @consecutive_failures,
          total_dropped:        @total_dropped,
          last_flush_at:        @last_flush_at
        }
      end
    end

    private

    def start_flush_thread
      @flush_thread = Thread.new do
        loop do
          sleep Apidepth.configuration.flush_interval
          safe_flush
        end
      end
      @flush_thread.abort_on_exception = false
      @flush_thread.name = "apidepth-flush"
    end

    def start_watchdog_thread
      @watchdog_thread = Thread.new do
        loop do
          sleep WATCHDOG_INTERVAL
          next if @flush_thread&.alive?

          Apidepth.logger&.warn(
            "[Apidepth] Flush thread died unexpectedly — restarting. " \
            "If this recurs, open an issue with your Ruby and Rails versions."
          )
          start_flush_thread
        end
      end
      @watchdog_thread.abort_on_exception = false
      @watchdog_thread.name = "apidepth-watchdog"
    end

    # Kill background threads and close the HTTP connection.
    # Called by reset! before the singleton is cleared.
    # Uses kill without join — threads are daemon-style and release their
    # resources as soon as they die. No join needed to unblock reset!.
    def teardown
      [@flush_thread, @watchdog_thread].compact.each do |t|
        t.kill rescue nil
      end
      close_http_connection
    end

    def safe_flush
      events = drain_queue

      # Nothing to send — skip entirely. Crucially, don't update last_flush_at:
      # that timestamp signals "data was delivered", not "the loop ticked".
      return if events.empty?

      send_batch(events)

      @stats_mutex.synchronize do
        @consecutive_failures = 0
        @last_flush_at        = Time.now
      end

    rescue StandardError => e
      failures = @stats_mutex.synchronize { @consecutive_failures += 1 }

      begin
        Apidepth.configuration.on_flush_error&.call(e, {
          dropped_events:       events&.size || 0,
          consecutive_failures: failures,
          total_dropped:        @total_dropped
        })
      rescue StandardError
        nil
      end

      if failures >= FAILURE_THRESHOLD
        Apidepth.logger&.warn(
          "[Apidepth] Flush has failed #{failures} times consecutively. " \
          "Events are being dropped. Check your API key and network connectivity. " \
          "Last error: #{e.class}: #{e.message}"
        )
      end
    end

    def drain_queue
      events = []
      while events.size < MAX_BATCH_SIZE
        events << @queue.pop(true)
      end
      events
    rescue ThreadError
      events
    end

    # Memoized on first flush. Intentional: collector_url is a boot-time setting.
    # Changing configuration.collector_url after the first flush has no effect.
    def collector_url
      @cached_url ||= begin
        url = URI.parse(Apidepth.configuration.collector_url || DEFAULT_URL)
        validate_collector_url!(url)
        url
      end
    end

    # Returns the persistent HTTP connection.
    # Only ever called under @send_mutex — no concurrent access.
    # Reconnects automatically when the connection has been closed or errored.
    def http_connection
      return @http if @http&.started?

      url = collector_url
      @http = Net::HTTP.new(url.host, url.port)
      @http.use_ssl            = true
      @http.verify_mode        = OpenSSL::SSL::VERIFY_PEER
      @http.open_timeout       = 3
      @http.read_timeout       = 5
      @http.keep_alive_timeout = 30
      @http.start
      @http
    rescue StandardError
      close_http_connection
      raise
    end

    def close_http_connection
      @http&.finish rescue nil
      @http = nil
    end

    def send_batch(events)
      return if events.empty?

      key = Apidepth.configuration.api_key
      # Nil or empty key: Railtie already warned at boot — skip silently rather
      # than sending a broken "Bearer " header and burning a failure increment.
      return if key.nil? || key.empty?

      validate_api_key!(key)

      extra = Apidepth.configuration.extra_vendors
      payload = {
        batch:         events,
        sdk:           Apidepth.sdk_metadata,
        extra_vendors: (extra.nil? || extra.empty?) ? nil : extra,
      }.compact

      Thread.current[:apidepth_skip] = true

      @send_mutex.synchronize do
        url  = collector_url
        http = http_connection

        req                  = Net::HTTP::Post.new(url.path.empty? ? "/" : url.path)
        req["Content-Type"]  = "application/json"
        req["Authorization"] = "Bearer #{key}"
        req.body             = JSON.generate(payload)

        response = http.request(req)

        unless (200..299).cover?(response.code.to_i)
          close_http_connection  # server closed the connection or rejected us
          raise "Collector returned HTTP #{response.code} — verify your api_key and collector_url"
        end
      end

    ensure
      Thread.current[:apidepth_skip] = false
    end

    PRIVATE_HOST_PATTERN = /
      \Alocalhost\z          |
      \A127\.                |
      \A0\.0\.0\.0\z         |
      \A169\.254\.           |
      \A10\.                 |
      \A172\.(1[6-9]|2\d|3[01])\. |
      \A192\.168\.           |
      \A\[?::1\]?\z          |
      \A\[?fc                |
      \A\[?fe80:
    /xi.freeze

    def validate_collector_url!(url)
      unless url.scheme == "https"
        raise ArgumentError,
          "Apidepth collector_url must use HTTPS (got #{url.scheme.inspect}). " \
          "HTTP connections are rejected to prevent SSRF and credential exposure."
      end

      host = url.host.to_s.downcase

      if host.match?(/\A\d+\z/)
        int = host.to_i
        if int > 0 && int <= 0xFFFFFFFF
          host = [int >> 24, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF].join(".")
        end
      end

      if host.empty? || PRIVATE_HOST_PATTERN.match?(host)
        raise ArgumentError,
          "Apidepth collector_url must not target private, loopback, or link-local " \
          "addresses (got #{url.host.inspect})."
      end
    end

    def validate_api_key!(key)
      return if key.nil? || key.empty?
      if key.match?(/[\r\n]/)
        raise ArgumentError,
          "Apidepth api_key contains illegal line-break characters. " \
          "This may indicate header injection — check your APIDEPTH_API_KEY value."
      end
    end
  end
end
