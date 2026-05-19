# lib/apidepth/net_http_instrumentation.rb

module Apidepth
  module NetHTTPInstrumentation
    def request(req, body = nil, &block)
      # Early exits — evaluated in order of cheapness:
      # 1. Recursion guard: we're inside our own collector flush
      # 2. SDK disabled entirely
      # 3. Host is on the customer's ignore list
      # 4. Sample rate: probabilistically skip events
      return super if Thread.current[:apidepth_skip]
      return super unless Apidepth.configuration.enabled
      return super if Apidepth.configuration.ignored_hosts.include?(address)
      return super unless sampled?

      # Snapshot connection state BEFORE calling super.
      # started? returns true if a keep-alive connection is already open.
      # cold_start events pay for DNS + SSL — that latency belongs to the
      # customer's infrastructure, not the vendor. Tag it so the collector
      # can exclude cold-start events from latency percentile calculations.
      cold_start = !started?

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        response    = super
        duration_ms = elapsed_ms(start)
        record_event(req, response, duration_ms, cold_start: cold_start)
        response
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        # Timeouts are the leading indicator of vendor degradation — they
        # appear before the vendor acknowledges an incident. We record them
        # and always re-raise so the customer's error handling is unaffected.
        duration_ms = elapsed_ms(start)
        record_timeout(req, duration_ms, e.class.name, cold_start: cold_start)
        raise
      end
    end

    private

    def elapsed_ms(start)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
    end

    # Environment is set once at Railtie boot (or by the customer in configure).
    # Reading it here is a single attr_accessor access — no method dispatch,
    # no defined?() check, no Rails.env call on every outbound HTTP request.
    def resolve_env
      Apidepth.configuration.environment || "unknown"
    end

    # Probabilistic sampling. At sample_rate 1.0 (default), always returns true.
    # At 0.5, roughly half of events are captured. At 0.0, nothing is captured.
    # The comparison is cheap — the rand call only happens when rate < 1.0.
    def sampled?
      rate = Apidepth.configuration.sample_rate
      rate >= 1.0 || rand < rate
    end

    def record_event(req, response, duration_ms, cold_start:)
      vendor, normalized_path = Apidepth::VendorRegistry.identify(address, req.path)
      return unless vendor

      status  = response.code.to_i
      outcome = case status
                when 200..299 then :success
                when 400..499 then :client_error
                when 500..599 then :server_error
                else               :unknown
                end

      now_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      rl = Apidepth::RateLimitHeaders.extract(response, now_ms)

      Apidepth::Collector.instance.record(
        Apidepth::Event.build(
          {
            vendor: vendor,
            endpoint: normalized_path,
            method: req.method,
            status: status,
            outcome: outcome,
            duration_ms: duration_ms,
            cold_start: cold_start,
            env: resolve_env,
            ts: now_ms
          }.merge(rl || {})
        )
      )
    rescue StandardError
      nil
    end

    def record_timeout(req, duration_ms, error_class, cold_start:)
      vendor, normalized_path = Apidepth::VendorRegistry.identify(address, req.path)
      return unless vendor

      Apidepth::Collector.instance.record(
        Apidepth::Event.build(
          vendor: vendor,
          endpoint: normalized_path,
          method: req.method,
          status: nil,
          outcome: :timeout,
          error_class: error_class,
          duration_ms: duration_ms,
          cold_start: cold_start,
          env: resolve_env,
          ts: Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
        )
      )
    rescue StandardError
      nil
    end
  end
end
