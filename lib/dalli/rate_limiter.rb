# frozen_string_literal: true

require "dalli"
require "dalli/rate_limiter/version"

module Dalli
  # Dalli::RateLimiter provides arbitrary Memcached-backed rate limiting for
  # your Ruby applications.
  #
  # @see file:README.md
  #
  # @!attribute [r] max_requests
  #   @return [Float] the maximum number of requests
  class RateLimiter
    LockError = Class.new RuntimeError
    LimitError = Class.new RuntimeError

    DEFAULT_OPTIONS = {
      :key_prefix => "dalli-rate_limiter",
      :max_requests => 5,
      :period => 8,
      :lock_timeout => 30
    }.freeze

    attr_reader :max_requests

    # Create a new instance of Dalli::RateLimiter.
    #
    # @param dalli [ConnectionPool, Dalli::Client] the Dalli::Client (or
    #   ConnectionPool of Dalli::Client) to use as a backing store for this
    #   rate limiter
    # @param options [Hash] configuration options for this rate limiter
    #
    # @option options [String, #to_s] :key_prefix ("dalli-rate_limiter") a
    #   unique string describing this rate limiter
    # @option options [Integer, Float] :max_requests (5) maximum number of
    #   requests over the governed interval
    # @option options [Integer, Float] :period (8) number of seconds over
    #    which to enforce the maximum number of requests
    # @option options [Integer, Float] :lock_timeout (30) maximum number of
    #    seconds to wait for the lock to become available
    def initialize(dalli = nil, options = {})
      @pool = dalli || Dalli::Client.new

      options = normalize_options options

      @key_prefix = options[:key_prefix]
      @max_requests = options[:max_requests]
      @period = options[:period]
      @lock_timeout = options[:lock_timeout]
    end

    # Determine whether processing a given request would exceed the rate limit.
    #
    # @param unique_key [String, #to_s] a key to use, in combination with the
    #   optional `:key_prefix` and any `:namespace` defined in the
    #   Dalli::Client, to distinguish the item being limited from similar items
    # @param to_consume [Integer, Float] the number of requests to consume from
    #   the allowance (used to represent a partial request or a batch of
    #   requests)
    #
    # @return [false] if the request can be processed as given without
    #   exceeding the limit (including the case where the number to consume is
    #   zero)
    # @return [Float] if processing the request as given would exceed
    #   the limit and the caller should wait so many (fractional) seconds
    #   before retrying
    # @return [-1] if the number to consume exceeds the maximum, and the
    #   request as given would never not exceed the limit
    #
    # @raise [LockError] if a lock cannot be obtained before `@lock_timeout`
    def exceeded?(unique_key = nil, to_consume = 1)
      to_consume = to_consume.to_f

      return false if to_consume <= 0
      return -1 if to_consume > max_requests

      key = [@key_prefix, unique_key].compact.join(":")

      try = 1
      total_time = 0
      while true # rubocop:disable Style/InfiniteLoop, Lint/LiteralInCondition
        @pool.with do |dc|
          result = dc.cas!(key, @period) do |previous_value|
            wait, value = compute(previous_value, to_consume)
            return wait if wait > 0 # caller must wait
            value
          end

          return false if result # caller can proceed
        end

        time = rand * Math.sqrt(try / Math::E)
        raise LockError, "Unable to lock key for update" \
          if time + total_time > @lock_timeout
        sleep time

        try += 1
        total_time += time
      end
    end

    # Execute a block without exceeding the rate limit.
    #
    # @param (see #exceeded?)
    # @param options [Hash] configuration options
    #
    # @option options [Integer] :wait_timeout maximum number of seconds to wait
    #   before yielding
    #
    # @yield block to execute within limit
    #
    # @raise [LimitError] if the block cannot be yielded to within
    #  `:wait_timeout` seconds without going over the limit
    # @raise (see #exceeded?)
    #
    # @return the return value of the passed block
    def without_exceeding(unique_key = nil, to_consume = 1, options = {})
      options[:wait_timeout] = options[:wait_timeout].to_f \
        if options[:wait_timeout]

      start_time = Time.now.to_f
      while time = exceeded?(unique_key, to_consume)
        raise LimitError, "Unable to yield without exceeding limit" \
          if time < 0 || options[:wait_timeout] && time + Time.now.to_f - start_time > options[:wait_timeout]
        sleep time
      end

      yield
    end

    private

    def compute(previous_value, to_consume)
      current_timestamp = Time.now.to_f

      previous_value ||= {}
      previous_allowance = previous_value[:allowance] || @max_requests
      previous_timestamp = previous_value[:timestamp] || current_timestamp

      allowance_delta = (current_timestamp - previous_timestamp) * @max_requests / @period
      projected_allowance = previous_allowance + allowance_delta
      if projected_allowance > @max_requests
        projected_allowance = @max_requests
        allowance_delta = @max_requests - previous_allowance
      end

      if to_consume > projected_allowance
        # Determine how long the caller must wait (in seconds) before retrying.
        wait = (to_consume - projected_allowance) * @period / @max_requests
      else
        value = {
          :allowance => previous_allowance + allowance_delta - to_consume,
          :timestamp => current_timestamp
        }
      end

      [wait || 0, value || previous_value]
    end

    def normalize_options(options)
      normalized_options = {}

      normalized_options[:key_prefix] = options[:key_prefix].to_s \
        if options.key? :key_prefix

      normalized_options[:max_requests] = options[:max_requests].to_f \
        if options[:max_requests] && options[:max_requests].to_f > 0

      normalized_options[:period] = options[:period].to_f \
        if options[:period] && options[:period].to_f > 0

      normalized_options[:lock_timeout] = options[:lock_timeout].to_f \
        if options[:lock_timeout] && options[:lock_timeout].to_f >= 0

      DEFAULT_OPTIONS.merge normalized_options
    end
  end
end
