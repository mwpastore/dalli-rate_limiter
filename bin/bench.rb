#!/usr/bin/env ruby

require "bundler/setup"
require "dalli/rate_limiter"

require "thread"
require "thwait"

NUM_THREADS = 100

lim = Dalli::RateLimiter.new nil,
  :key_prefix => "bench", :max_requests => 100_000, :period => 1

mutex = Mutex.new
error_count = 0

threads = NUM_THREADS.times.map do
  Thread.new do
    1_000.times do
      begin
        lim.exceeded?
      rescue
        mutex.synchronize { error_count += 1 }
      end
    end
  end
end

ThreadsWait.all_waits(*threads)

puts "errors: #{error_count}"
