# frozen_string_literal: true

require "dalli"
require "connection_pool"

require "dalli/rate_limiter/version"

module Dalli
  INVALID_KEY_CHARS = [
    0x00, 0x20,
    0x09, 0x0a,
    0x0d
  ].map(&:chr).join("").freeze

  class RateLimiter
    def initialize(dalli = nil, key_prefix = nil, options = {})
      @dalli = dalli || ConnectionPool.new { Dalli::Client.new }
      @key_prefix = key_prefix || "dalli-rate_limiter"

      @max_requests = to_ems(options[:max_requests] || 5)
      @period = to_ems(options[:period] || 8)
    end

    def is_limited?(unique_key, consumed = 1)
      timestamp_key = format_key(unique_key, "timestamp")
      allowance_key = format_key(unique_key, "allowance")

      consumed = to_ems(consumed)
      current_timestamp = to_ems(Time.now.to_f)

      @dalli.with do |dc|
        if consumed <= @max_requests
          if dc.add(allowance_key, @max_requests - consumed, @period, :raw => true)
            # Short circuit the simple case of seeing the key for the first time.
            dc.set(timestamp_key, current_timestamp, @period, :raw => true)

            return
          end
        end

        previous = dc.get_multi allowance_key, timestamp_key
        previous_allowance = previous[allowance_key].to_i || @max_requests
        previous_timestamp = previous[timestamp_key].to_i || current_timestamp

        elapsed = current_timestamp - previous_timestamp
        allowance_delta = (1.0 * elapsed * @max_requests / @period).to_i
        projected_allowance = previous_allowance + allowance_delta
        if projected_allowance > @max_requests
          projected_allowance = @max_requests
          allowance_delta = @max_requests - previous_allowance
        end

        if consumed > projected_allowance
          # Push the timestamp into the future, indicating when the allowance
          # will be "back to zero".
          penalty = (1.0 * (consumed - projected_allowance) * @period / @max_requests).to_i
          penalty_seconds = to_fs(penalty)

          dc.set(allowance_key, 0, @period + penalty_seconds.ceil, :raw => true)
          dc.add(timestamp_key, previous_timestamp, 0, :raw => true) # ensure baseline exists
          dc.incr(timestamp_key, elapsed + penalty)
          dc.touch(timestamp_key, @period + penalty_seconds.ceil)

          return penalty_seconds
        end

        allowance_delta -= consumed

        dc.add(allowance_key, previous_allowance, 0, :raw => true) # ensure baseline exists
        dc.send(allowance_delta < 0 ? :decr : :incr, allowance_key, allowance_delta.abs)
        dc.touch(allowance_key, @period)
        dc.set(timestamp_key, current_timestamp, @period, :raw => true)

        return
      end
    end

  private

    # Convert fractional units to encoded milliunits
    def to_ems(fs)
      (fs * 1_000).to_i
    end

    # Convert encoded milliunits to fractional units
    def to_fs(ems)
      1.0 * ems / 1_000
    end

    def format_key(key, attribute)
      "#@key_prefix:#{key.to_s.delete INVALID_KEY_CHARS}:#{attribute}"
    end
  end
end
