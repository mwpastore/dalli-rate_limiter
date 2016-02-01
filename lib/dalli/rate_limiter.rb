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

  # Dalli::RateLimiter provides arbitrary Memcached-backed rate limiting for
  # your Ruby applications.
  #
  # @see file:README.md
  #
  # @!attribute [r] max_requests
  #   @return [Float] the maximum number of requests in a human-friendly format
  class RateLimiter
    LOCK_TTL = 30
    LOCK_MAX_TRIES = 6

    DEFAULT_OPTIONS = {
      :key_prefix => "dalli-rate_limiter",
      :max_requests => 5_000,
      :period => 8_000,
      :locking => true
    }.freeze

    private_constant :DEFAULT_OPTIONS

    # Create a new instance of Dalli::RateLimiter.
    #
    # @param dalli [nil, ConnectionPool, Dalli::Client] the Dalli::Client (or
    #   ConnectionPool of Dalli::Client) to use as a backing store for this
    #   rate limiter
    # @param options [Hash{Symbol}] configuration options for this rate limiter
    #
    # @option options [String] :key_prefix ("dalli-rate_limiter") a unique
    #   string describing this rate limiter
    # @option options [Integer, Float] :max_requests (5) maximum number of
    #   requests over the governed interval
    # @option options [Integer, Float] :period (8) number of seconds over
    #    which to enforce the maximum number of requests
    # @option options [Boolean] :locking (true) enable or disable locking
    def initialize(dalli = nil, options = {})
      @dalli = dalli || ConnectionPool.new { Dalli::Client.new }

      options = normalize_options options

      @key_prefix = options[:key_prefix]
      @max_requests = options[:max_requests]
      @period = options[:period]
      @locking = options[:locking]
    end

    def max_requests
      to_fs @max_requests
    end

    # Determine whether processing a given request would exceed the rate limit.
    #
    # @param unique_key [String] a key to use, in combination with the
    #   `:key_prefix` and any `:namespace` defined in the Dalli::Client, to
    #   distinguish the item being limited from similar items
    # @param to_consume [Integer, Float] the number of requests to consume from
    #   the allowance (used to represent a batch of requests)
    #
    # @return [-Integer] if the number to consume exceeds the maximum,
    #   and the request as given would never not exceed the limit
    # @return [Float] if processing the request as given would exceed
    #   the limit and the caller should wait so many [fractional] seconds
    #   before retrying
    # @return [nil] if the request can be processed as given without exceeding
    #   the limit (including the case where the number to consume is zero)
    def exceeded?(unique_key, to_consume = 1)
      return nil if to_consume == 0

      to_consume = to_ems(to_consume)

      return -1 if to_consume > @max_requests

      timestamp_key = format_key(unique_key, "timestamp")
      allowance_key = format_key(unique_key, "allowance")

      @dalli.with do |dc|
        if dc.add(allowance_key, @max_requests - to_consume, @period, :raw => true)
          # Short-circuit the simple case of seeing the key for the first time.
          dc.set(timestamp_key, to_ems(Time.now.to_f), @period, :raw => true)

          return nil
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

    private

    def normalize_options(options)
      options[:key_prefix] = cleanse_key options[:key_prefix] \
        if options[:key_prefix]

      options[:max_requests] = to_ems options[:max_requests].to_f \
        if options[:max_requests]

      options[:period] = to_ems options[:period].to_f \
        if options[:period]

      options[:locking] = !!options[:locking] \
        if options.key? :locking

      DEFAULT_OPTIONS.dup.merge! options
    end

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
      "#{@key_prefix}:#{cleanse_key key}:#{attribute}"
    end

    def cleanse_key(key)
      key.to_s.delete INVALID_KEY_CHARS
    end
  end
end
