# lib/apidepth/railtie.rb

module Apidepth
  class Railtie < Rails::Railtie
    # -------------------------------------------------------------------------
    # 1. Validate config early — loud warning beats silent 401s at flush time
    # -------------------------------------------------------------------------
    initializer "apidepth.validate_config", after: :load_config_initializers do
      if Apidepth.configuration.api_key.nil?
        Rails.logger.warn(
          "[Apidepth] No API key configured — events will not be delivered. " \
          "Visit www.apidepth.io to create an account and get your key, " \
          "then add `config.api_key = ENV['APIDEPTH_API_KEY']` to config/initializers/apidepth.rb"
        )
      end
    end

    # -------------------------------------------------------------------------
    # 2. Instrument Net::HTTP and load the remote vendor registry.
    #    Runs after all initializers so any gem that reopens Net::HTTP is settled.
    # -------------------------------------------------------------------------
    initializer "apidepth.instrument", after: :load_config_initializers do
      Apidepth.logger = Rails.logger

      # Freeze environment once so NetHTTPInstrumentation#resolve_env is a
      # single attr_accessor read rather than a defined?/Rails.env call on
      # every outbound HTTP request.
      Apidepth.configuration.environment ||= Rails.env.to_s

      Net::HTTP.prepend(Apidepth::NetHTTPInstrumentation)
      Apidepth::VendorRegistry.load_extra_vendors(Apidepth.configuration.extra_vendors)
      Apidepth::RegistryLoader.load_and_start

      if Rails.env.development?
        Rails.logger.debug(
          "[Apidepth] Instrumentation active — " \
          "registry=#{Apidepth::VendorRegistry.version} " \
          "vendors=#{Apidepth::VendorRegistry.vendor_count}"
        )
      end
    end

    # -------------------------------------------------------------------------
    # 3. Flush queue on graceful shutdown.
    #    at_exit fires on SIGTERM → graceful Puma/Unicorn shutdown.
    #    flush! rescues internally so a network error at shutdown is not fatal.
    # -------------------------------------------------------------------------
    config.after_initialize do
      at_exit { Apidepth::Collector.instance.flush! }
    end

    # -------------------------------------------------------------------------
    # 4. Fork safety for Puma cluster mode / Spring.
    #
    #    after_fork: reset the Collector singleton so each worker gets a fresh
    #    instance with its own flush thread. The master's flush thread is not
    #    copied by fork() — without reset!, the worker's first call to
    #    Collector.instance returns the master's stale object with no thread.
    #
    #    before_fork: NOT handled here — no clean Rails API exists for it.
    #    Add this to config/puma.rb to flush the master's queue before forking:
    #
    #      before_fork { Apidepth::Collector.instance.flush! }
    #
    #    ActiveSupport::ForkTracker is available in Rails 7.1+.
    # -------------------------------------------------------------------------
    config.after_initialize do
      if defined?(ActiveSupport::ForkTracker)
        ActiveSupport::ForkTracker.after_fork { Apidepth::Collector.reset! }
      elsif defined?(Puma)
        # ActiveSupport::ForkTracker requires Rails 7.1+. Without it, forked
        # Puma workers inherit the master's stale Collector singleton with no
        # flush thread. Events recorded in workers will never be sent.
        # Upgrade to Rails 7.1+ or add to config/puma.rb:
        #   on_worker_boot { Apidepth::Collector.reset! }
        Rails.logger.warn(
          "[Apidepth] Puma detected but ActiveSupport::ForkTracker is unavailable " \
          "(requires Rails 7.1+). Workers in cluster mode will not flush events. " \
          "Add `on_worker_boot { Apidepth::Collector.reset! }` to config/puma.rb"
        )
      end
    end
  end
end
