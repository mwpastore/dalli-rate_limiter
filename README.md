# Dalli::RateLimiter

[![Build Status](https://travis-ci.org/mwpastore/dalli-rate_limiter.svg?branch=master)](https://travis-ci.org/mwpastore/dalli-rate_limiter)
[![Gem Version](https://badge.fury.io/rb/dalli-rate_limiter.svg)](https://badge.fury.io/rb/dalli-rate_limiter)
[![Dependency Status](https://gemnasium.com/mwpastore/dalli-rate_limiter.svg)](https://gemnasium.com/mwpastore/dalli-rate_limiter)

**Dalli::RateLimiter** provides arbitrary [Memcached][6]-backed rate limiting
for your Ruby applications. You may be using an application-level rate limiter
such as [Rack::Ratelimit][1], [Rack::Throttle][2], or [Rack::Attack][3], or
something higher up in your stack (like an NGINX zone or HAproxy stick-table).
This is not intended to be a replacement for any of those functions. Your
application may not even be a web service and yet you find yourself needing to
limit (or throttle) certain types of operations.

This library allows you to impose specific rate limits on specific functions at
whatever granularity you desire. For example, you have a function in your Ruby
web application that allows users to change their username, but you want to
limit these requests to two per hour per user. Or your command-line Ruby
application makes API calls over HTTP, but you must adhere to a strict rate
limit imposed by the provider for a certain endpoint. It wouldn't make sense to
apply these limits at the application level&mdash;it would be much easier to
tightly integrate a check within your business logic.

**Dalli::RateLimiter** leverages the excellent [Dalli][4] gem for fast and
efficient (and thread-safe) Memcached access. It uses an allowance counter and
floating timestamp to implement a sliding window for each unique key, enforcing
a limit of _m_ requests over a period of _n_ seconds. If you're familiar with
[Sidekiq][10] (which is another excellent piece of software, written by the
same person who wrote Dalli), it is similar to the Window style of the
Sidekiq::Limiter class, although the invocation syntax differs slightly (see
[Block Form](#block-form) below for an example of the differences).

It supports arbitrary unit quantities of consumption for partial operations or
for operations that logically count as more than one request (i.e. batched
requests). It leverages Memcached's compare-and-set method&mdash;which uses an
opportunistic locking scheme&mdash;in combination with a back-off algorithm to
mitigate race conditions while ensuring that limits are enforced under high
levels of concurrency with a high degree of confidence. Math operations are
performed with floating-point precision.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'dalli-rate_limiter', '~> 0.3.0'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install dalli-rate_limiter

## Basic Usage

```ruby
def do_foo
  lim = Dalli::RateLimiter.new

  if lim.exceeded?
    fail "Sorry, can't foo right now. Try again later!"
  end

  # Do foo...
end

def do_bar
  lim = Dalli::RateLimiter.new

  lim.without_exceeding do
    # Do bar...
  end
end
```

**Dalli::RateLimiter** will, by default, use a Dalli::Client instance with the
default options. If `MEMCACHE_SERVERS` is set in your environment, or if your
Memcached instance is running on localhost, port 11211, this is the quickest
way to get started. Alternatively, you can pass in your own single-threaded
Dalli::Client instance&mdash;or your own multi-threaded ConnectionPool instance
(see [Compatibility](#compatibility) below)&mdash;as the first argument to
customize the connection settings. Pass in `nil` to force the default behavior.

The library itself defaults to five (5) requests per eight (8) seconds, but
these can easily be changed with the `:max_requests` and `:period` options.
Locking can be fine-tuned by setting the `:lock_timeout` option. A
`:key_prefix` option can be specified as well; note that this will be used in
combination with any `:namespace` option defined in the Dalli::Client.

The **Dalli::RateLimiter** instance itself is not stateful (in that it doesn't
track the state of the things being limited, only the parameters of the limit
itself), so it can be instantiated as needed (e.g. in a function definition) or
in a more global scope (e.g. in a Rails initializer). It does not mutate any of
its own attributes or allow its attributes to be mutated so it should be safe
to share between threads.

The main instance method, `#exceeded?` will return `false` if the request is
free to proceed. If the limit has been exceeded, it will return a positive
floating point value that represents the fractional number of seconds that the
caller should wait until retrying the request. Assuming no other requests were
process during that time, the retried request will be free to proceed at that
point. When invoking this method, please be sure to pass in a key that is
unique (in combination with the `:key_prefix` option described above) to the
thing you are trying to limit. An optional second argument specifies the number
of requests to "consume" from the allowance; this defaults to one (1).

Please note that if the number of requests is greater than the maximum number
of requests, the limit will never not be exceeded. Consider a limit of 50
requests per minute: no amount of waiting would ever allow for a batch of 51
requests! `#exceeded?` returns `-1` in this event. To help detect this edge
case proactively, a public getter method `#max_requests` is available.

An alternative block-form syntax is available using the `#without_exceeding`
method. This method will call `sleep` on your behalf until the block can be
executed without exceeding the limit, and then yield to the block. This is
useful in situations where you want to avoid writing your own sleep-while loop.
You can limit how long the method will sleep by passing in a `:wait_timeout`
option; please note that the total wait time includes any time spent acquiring
the lock.

## Advanced Usage

```ruby
require "connection_pool"

dalli = ConnectionPool.new(:size => 5, :timeout => 3) do
  Dalli::Client.new nil, :namespace => "myapp", :threadsafe => false
end

USERNAME_LIMIT = Dalli::RateLimiter.new dalli,
  :key_prefix => "username-limit", :max_requests => 2, :period => 3_600

WIDGETS_LIMIT = Dalli::RateLimiter.new dalli,
  :key_prefix => "widgets-limit", :max_requests => 10, :period => 60

def change_username(user_id, new_username)
  if USERNAME_LIMIT.exceeded?(user_id) # user-specific limit on changing usernames
    halt 422, "Sorry! Only two username changes allowed per hour."
  end

  # Change username...
rescue Dalli::RateLimiter::LockError
  # Unable to acquire a lock before lock timeout...
end

def add_widgets(some_widgets)
  if some_widgets.length > WIDGETS_LIMIT.max_requests
    halt 400, "Too many widgets!"
  end

  if time = WIDGETS_LIMIT.exceeded?(nil, some_widgets.length) # global limit on adding widgets
    halt 422, "Sorry! Unable to process request. " \
      "Please wait at least #{time} seconds before trying again."
  end

  # Add widgets...
rescue Dalli::RateLimiter::LockError
  # Unable to acquire a lock before lock timeout...
end
```

## Block Form

This alternative syntax will sleep (as necessary) until the request can be
processed without exceeding the limit. An optional wait timout can be specified
to prevent the method from sleeping forever. Rewriting the `add_widgets` method
from above:

```ruby
def add_widgets(some_widgets)
  if some_widgets.length > WIDGETS_LIMIT.max_requests
    halt 400, "Too many widgets!"
  end

  WIDGETS_LIMIT.without_exceeding(nil, some_widgets.length, :wait_timeout => 30) do
    # Add widgets...
  end
rescue Dalli::RateLimiter::LimitError
  halt 422, "Sorry! Request timed out. Please try again later."
rescue Dalli::RateLimiter::LockError
  # Unable to acquire a lock before lock timeout...
end
```

This feature was originally requested for parity with Sidekiq::Limiter, so
here's an example adapted from Sidekiq::Limiter.window's [documentation][9]:

```ruby
def perform(user_id)
  user_throttle = Dalli::RateLimiter.new nil,
    :key_prefix => "stripe", :max_requests => 5, :period => 1

  user_throttle.without_exceeding(user_id, 1, :wait_timeout => 5) do
    # call stripe with user's account creds
  end
rescue Dalli::RateLimiter::LimitError
  # Unable to execute block before wait timeout...
rescue Dalli::RateLimiter::LockError
  # Unable to acquire a lock before lock timeout...
end
```

You have the flexibility to set the `:key_prefix` to `nil` and pass in
`"stripe:#{user_id}"` as the first argument to `#without_exceeding`, with same
end results. Or, likewise, you could set `:key_prefix` to `"stripe:#{user_id}"`
and pass in `nil` as the first argument to `#without_exceeding`. Sometimes it
makes sense to share an instance between method calls, or indeed between
different methods, and sometimes it doesn't. Please note that if `:key_prefix`
and the first argument to `#without_exceeding` (or `#exceeded?`) are both
`nil`, Dalli::Client will abort with an ArgumentError ("key cannot be blank").

## Compatibility

**Dalli::RateLimiter** is compatible with Ruby 1.9.3 and greater and has been
tested with frozen string literals under Ruby 2.3.0. It has also been tested
under Rubinius 2.15 and 3.14, and JRuby 1.7 (in 1.9.3 execution mode) and 9K.

If you are sharing a **Dalli::RateLimiter** instance between multiple threads
and performance is a concern, you might consider adding the
[connection_pool][5] gem to your project and passing in a ConnectionPool
instance (wrapping Dalli::Client) as the first argument to the constructor.
Make sure your pool has enough slots (`:size`) for these operations; I aim for
one slot per thread plus one or two for overhead in my applications. You might
also consider adding the [kgio][7] gem to your project to [give Dalli a 10-20%
performance boost][8].

## Caveats

A rate-limiting system is only as good as its backing store, and it should be
noted that a Memcached ring can lose members or indeed its entire working set
(in the event of a flush operation) at the drop of a hat. Mission-critical use
cases, where repeated operations absolutely, positively have to be restricted,
should probably seek solutions elsewhere. If you have already have Redis in
your stack, you might consider a Redis-based rate limiter (such as
Sidekiq::Limiter). Redis has better mechanisms for locking and updating keys,
it doesn't lose its working set on restart, and polling can be reduced or
eliminated through use of its built-in Lua scripting.

The limiting algorithm&mdash;which was overhauled for the 0.2.0 release to
greatly reduce the number of round-trips to Memcached&mdash;seems to work well,
but it is far from battle-tested. Simple benchmarking against a local Memcached
instance shows zero lock timeouts with the default settings and 200 threads
banging away at the same limit concurrently for an extended period of time.
(Testing performed on a 2012 MacBook Pro with an Intel i7-3615QM processor and
16 GB RAM; benchmarking scripts available in the `bin` subdirectory of this
repository.) I do plan on performing additional testing with a few more client
cores against a production (or production-like) Memcached ring at some point in
the near future and will update these results at that time.

As noted above, this is not a replacement for an application-level rate limit,
and if your application faces the web, you should probably definitely have
something else in your stack to handle e.g. a casual DoS.

## Documentation

This README is fairly comprehensive, but additional information about the
class and its methods is available in [YARD][11].

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run
`rake spec` to run the tests. You can also run `bin/console` for an interactive
prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To
release a new version, update the version number in `version.rb`, and then run
`bundle exec rake release`, which will create a git tag for the version, push
git commits and tags, and push the `.gem` file to
[rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/mwpastore/dalli-rate_limiter.

## License

The gem is available as open source under the terms of the [MIT
License](http://opensource.org/licenses/MIT).

[1]: https://github.com/jeremy/rack-ratelimit "Rate::Ratelimit"
[2]: https://github.com/bendiken/rack-throttle "Rack::Throttle"
[3]: https://github.com/kickstarter/rack-attack "Rack::Attack"
[4]: https://github.com/petergoldstein/dalli "Dalli"
[5]: https://github.com/mperham/connection_pool "ConnectionPool"
[6]: http://memcached.org "Memcached"
[7]: http://bogomips.org/kgio "kgio"
[8]: https://github.com/petergoldstein/dalli/blob/master/Performance.md "Dalli Performance"
[9]: https://github.com/mperham/sidekiq/wiki/Ent-Rate-Limiting#window "Sidekiq::Limiter.window"
[10]: http://sidekiq.org "Sidekiq"
[11]: http://www.rubydoc.info/github/mwpastore/dalli-rate_limiter/master/Dalli/RateLimiter "Dalli::RateLimiter on RubyDoc.info"
