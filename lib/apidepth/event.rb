# lib/apidepth/event.rb
#
# Lightweight schema for events queued to the Collector.
#
# WHY validate here rather than at the collector?
# An event missing duration_ms or vendor is garbage. If we let it reach
# the collector, the collector ingests it, it pollutes the time-series,
# and you find out when a customer asks why their p95 chart is broken.
# Failing loudly at Event.build time means the bug surfaces in tests
# and development, not in production data.
#
# WHY frozen hash rather than a Struct?
# JSON.generate works directly on a Hash. A Struct requires #to_h before
# serialization, adding a conversion step on every batch. The frozen hash
# gives us immutability guarantees without the overhead.

module Apidepth
  module Event
    # Fields that must be present on every event regardless of outcome.
    # error_class is optional (only present on :timeout events).
    REQUIRED = %i[vendor endpoint method outcome duration_ms ts].freeze

    # Build a validated, frozen event hash. Raises ArgumentError immediately
    # if any required field is missing so the bug surfaces at call site.
    def self.build(attrs)
      missing = REQUIRED - attrs.keys
      unless missing.empty?
        raise ArgumentError,
              "Apidepth event is missing required fields: #{missing.join(', ')}. " \
              "This is a bug in the SDK — please open an issue."
      end

      attrs.freeze
    end
  end
end
