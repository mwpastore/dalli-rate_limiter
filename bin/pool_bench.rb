#!/usr/bin/env ruby

require "connection_pool"

require_relative "bench"

dalli = ConnectionPool.new(:size => Bench::NUM_THREADS + 1) do
  Dalli::Client.new nil, :threadsafe => false
end

Bench.new(dalli).bench
