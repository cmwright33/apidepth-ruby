# config/initializers/apidepth.rb
#
# Copy this file to config/initializers/apidepth.rb in your Rails app.
# Set APIDEPTH_API_KEY in your environment (credentials, dotenv, etc.).
# Only config.api_key is required — all other options show their defaults.

Apidepth.configure do |config|
  # Required. Your account API key from https://apidepth.io/dashboard/api-keys
  config.api_key = ENV.fetch("APIDEPTH_API_KEY", nil)

  # Disable in test and CI environments (default: true).
  config.enabled = !Rails.env.test?

  # Fraction of events to capture. Lower this if you make thousands of
  # vendor calls per minute and want to reduce collector traffic.
  # config.sample_rate = 1.0

  # Hosts to exclude from instrumentation entirely.
  # config.ignored_hosts = ["api.internal.mycompany.com"]

  # Custom vendors not in the global registry. Key = vendor name shown in
  # the dashboard; value = the hostname to watch. Synced to your account
  # automatically on the next event flush.
  # config.extra_vendors = {
  #   "my-payments-api" => "api.payments.internal.com",
  # }

  # Route flush errors to your error tracker.
  # config.on_flush_error = ->(error, context) { Sentry.capture_exception(error, extra: context) }

  # How often (in seconds) events are batched and sent. Default: 20.
  # config.flush_interval = 20
end
