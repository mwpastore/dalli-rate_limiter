#!/usr/bin/env ruby

require "bundler/setup"
require "dalli/rate_limiter"

require "thread"
require "thwait"

class Bench
  NUM_THREADS = 100

  def initialize(dalli = nil)
    @mutex = Mutex.new
    @limit = Dalli::RateLimiter.new dalli,
      :key_prefix => "bench", :max_requests => 100_000, :period => 1
  end

  def bench
    error_count = 0

    threads = Array.new(NUM_THREADS) do
      Thread.new do
        1_000.times do
          begin
            @limit.exceeded?
          rescue
            @mutex.synchronize { error_count += 1 }
          end
        end
      end
    end

    ThreadsWait.all_waits(*threads)

    puts "errors: #{error_count}"
  end
end

if $0 == __FILE__
  Bench.new.bench
end
