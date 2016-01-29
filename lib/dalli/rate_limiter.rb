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
    LOCK_TTL = 30
    LOCK_MAX_TRIES = 6

    def initialize(dalli = nil, options = {})
      @dalli = dalli || ConnectionPool.new { Dalli::Client.new }

      @key_prefix = options[:key_prefix] || "dalli-rate_limiter"
      @max_requests = to_ems(options[:max_requests] || 5)
      @period = to_ems(options[:period] || 8)
      @locking = options.key?(:locking) ? !!options[:locking] : true
    end

    def exceeded?(unique_key, to_consume = 1)
      to_consume = to_ems(to_consume)

      timestamp_key = format_key(unique_key, "timestamp")
      allowance_key = format_key(unique_key, "allowance")

      @dalli.with do |dc|
        if to_consume <= @max_requests
          if dc.add(allowance_key, @max_requests - to_consume, @period, :raw => true)
            # Short-circuit the simple case of seeing the key for the first time.
            dc.set(timestamp_key, to_ems(Time.now.to_f), @period, :raw => true)

            return nil
          end
        end

        lock = acquire_lock(dc, unique_key) if @locking

        current_timestamp = to_ems(Time.now.to_f) # obtain timestamp after locking

        previous = dc.get_multi allowance_key, timestamp_key
        previous_allowance = previous[allowance_key].to_i || @max_requests
        previous_timestamp = previous[timestamp_key].to_i || current_timestamp

        allowance_delta = (1.0 * (current_timestamp - previous_timestamp) * @max_requests / @period).to_i
        projected_allowance = previous_allowance + allowance_delta
        if projected_allowance > @max_requests
          projected_allowance = @max_requests
          allowance_delta = @max_requests - previous_allowance
        end

        if to_consume > projected_allowance
          release_lock(dc, unique_key) if lock

          # Tell the caller how long (in seconds) to wait before retrying the request.
          return to_fs((1.0 * (to_consume - projected_allowance) * @period / @max_requests).to_i)
        end

        allowance_delta -= to_consume

        dc.set(timestamp_key, current_timestamp, @period, :raw => true)
        dc.add(allowance_key, previous_allowance, 0, :raw => true) # ensure baseline exists
        dc.send(allowance_delta < 0 ? :decr : :incr, allowance_key, allowance_delta.abs)
        dc.touch(allowance_key, @period)

        release_lock(dc, unique_key) if lock

        return nil
      end
    end

    def max_requests
      to_fs(@max_requests)
    end

    private

    def acquire_lock(dc, key)
      lock_key = format_key(key, "mutex")

      (1..LOCK_MAX_TRIES).each do |tries|
        if lock = dc.add(lock_key, true, LOCK_TTL)
          return lock
        else
          sleep rand(2**tries)
        end
      end

      raise DalliError, "Unable to lock key for update"
    end

    def release_lock(dc, key)
      lock_key = format_key(key, "mutex")

      dc.delete(lock_key)
    end

    # Convert fractional units to encoded milliunits
    def to_ems(fs)
      (fs * 1_000).to_i
    end

    # Convert encoded milliunits to fractional units
    def to_fs(ems)
      1.0 * ems / 1_000
    end

    def format_key(key, attribute)
      "#{@key_prefix}:#{key.to_s.delete INVALID_KEY_CHARS}:#{attribute}"
    end
  end
end
