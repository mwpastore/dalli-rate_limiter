require "spec_helper"

describe Dalli::RateLimiter do
  Then { !Dalli::RateLimiter::VERSION.nil? }

  Given(:lim) do
    Dalli::RateLimiter.new nil,
      :max_requests => 5, :period => 8, :key_prefix => RUBY_VERSION
  end

  context "with no previous attempts" do
    When(:result) { lim.exceeded? "test_key_1" }

    Then { !result }
  end

  context "with too many attempts" do
    When(:result) { 6.times { lim.exceeded? "test_key_2" } }

    Then { result && result > 0 }
  end

  context "with sleeping" do
    When { sleep 6.times { lim.exceeded? "test_key_3" } }

    When(:result) { lim.exceeded? "test_key_3" }

    Then { !result }
  end

  context "with almost too many requests" do
    When(:result) { lim.exceeded? "test_key_4", lim.max_requests }

    Then { !result }
  end

  context "with too many requests" do
    When(:result) { lim.exceeded? "test_key_5", lim.max_requests + 1 }

    Then { result && result < 0 }
  end
end
