# Dalli::RateLimiter

**Dalli::RateLimiter** provides arbitrary [Memcached][6]-backed rate limiting
for your Ruby applications. You may be using an application-level rate limiter
such as [Rack::Ratelimit][1], [Rack::Throttle][2], or [Rack::Attack][3], or
something higher up in your stack (like an Nginx zone or HAproxy stick-table).
This is not intended to be a replacement for any of those functions. Your
application may not even be a web service and yet you find yourself needing to
throttle certain types of operations.

This library allows you to impose specific rate limits on specific functions at
whatever granularity you desire. For example, you have a function in your Ruby
web application that allows users to change their username, but you want to
limit these requests to two per hour per user. Or your command-line Ruby
application makes API calls over HTTP, but you must adhere to a strict rate
limit imposed by the provider for a certain endpoint. It wouldn't make sense to
apply these limits at the application level&mdash;it would be much easier to
tightly integrate a check within your business logic.

**Dalli::RateLimiter** leverages the excellent [Dalli][4] and
[ConnectionPool][5] gems for fast and efficient Memcached access and
thread-safe connection pooling. It uses an allowance counter and floating
timestamp to implement a sliding window for each unique key, enforcing a limit
of _m_ requests over a period of _n_ seconds. It supports arbitrary unit
quantities of consumption for operations that logically count as more than one
request (i.e. batched requests). A simple mutex locking scheme (enabled by
default) is used to mitigate race conditions and ensure that the limit is
enforced under most cirumstances (see [Caveats](#caveats) below).  Math
operations are performed with three decimal places of precision but the results
are stored in Memcached as integers.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'dalli-rate_limiter', '~> 0.1.0'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install dalli-rate_limiter

## Basic Usage

```ruby
lim = Dalli::RateLimiter.new

if lim.exceeded? "foo"
  fail "Sorry, can't foo right now. Try again later!"
else
  # ..
end
```

**Dalli::RateLimiter** will, by default, create a ConnectionPool with the
default options, using a block that yields Dalli::Client instances with the
default options. If `MEMCACHE_SERVERS` is set in your environment, or if your
Memcached instance is running on localhost, port 11211, this is the quickest
way to get started. Alternatively, you can pass in your own single-threaded
Dalli::Client instance&mdash;or your own multi-threaded ConnectionPool instance
(wrapping Dalli::Client)&mdash;as the first argument to customize the
connection settings. Pass in `nil` to force the default behavior.

The library itself defaults to five (5) requests per eight (8) seconds, but
these can easily be changed with the `:max_requests` and `:period` options.
Locking can be disabled by setting the `:locking` option to `false` (see
[Caveats](#caveats) below). A `:key_prefix` option can be specified as well;
note that this will be used in combination with any `:namespace` option defined
in the Dalli::Client.

The **Dalli::RateLimiter** instance itself is not stateful, so it can be
instantiated as needed (e.g. in a function definition) or in a more global
scope (e.g. in a Rails initializer). It does not mutate any of its own
attributes so it should be safe to share between threads; in this case, you
will definitely want to use either the default ConnectionPool or your own (as
opposed to a single-threaded Dalli::Client instance).

The main instance method, `#exceeded?` will return a falsy value if the request
is free to proceed. If the limit has been exceeded, it will return a floating
point value that represents the fractional number of seconds that the caller
should wait until retrying the request. Assuming no other requests were process
during that time, the retried request will be free to proceed at that point.
When invoking this method, please be sure to pass in a key that is unique (in
combination with the `:key_prefix` option described above) to the thing you are
trying to limit. An optional second argument specifies the number of requests
to "consume" from the allowance; this defaults to one (1). Please note that if
the number of requests is greater than the maximum number of requests, it will
never not be limited. Consider a limit of 50 requests per minute: no amount of
waiting would allow for a batch of 51 requests! To help check for this, a
public getter method `#max_requests` is available.

## Advanced Usage

```ruby
dalli = ConnectionPool.new(:size => 5, :timeout => 3) {
  Dalli::Client.new(nil, :namespace => "myapp")
}

lim1 = Dalli::RateLimiter.new dalli,
  :key_prefix => "username-throttle", :max_requests => 2, :period => 3_600

lim2 = Dalli::RateLimiter.new dalli,
  :key_prefix => "widgets-throttle", :max_requests => 10, :period => 60

def change_username(user_id, new_username)
  if lim1.exceeded? user_id
    halt 422, "Sorry! Only two username changes allowed per hour."
  end

  # ..
end

def add_widgets(foo_id, some_widgets)
  if some_widgets.length > lim2.max_requests
    halt 400, "Too many widgets!"
  end

  if time = lim2.exceeded? foo_id, some_widgets.length
    halt 422, "Sorry! Unable to process request. " \
      "Please wait at least #{time} seconds before trying again."
  end

  # ..
end
```

## Caveats

A rate-limiting system is only as good as its backing store, and it should be
noted that a Memcached ring can lose members or indeed its entire working set
at the drop of a hat. Mission-critical use cases, where operations absolutely,
positively have to be idempotent, should probably seek solutions elsewhere.

The limiting algorithm seems to work well but it is far from battle-tested. I
tried to use atomic operations where possible to mitigate race conditions, but
still had to implement a locking scheme, which might slow down operations and
lead to timeouts and exceptions if a lock can't be acquired for some reason.
Locking can be disabled but this will increase the chances that a determined
attacker figures out a way to defeat the limit.

I will likely be revisiting the algorithm in the future, but at the moment it
is in the unfortunate state of "good enough".

As noted above, this is not a replacement for an application-level rate limit,
and if your application faces the web, you should probably definitely have
something else in your stack to handle e.g. a casual DoS.

Make sure your ConnectionPool has enough slots for these operations. I aim for
one slot per thread plus one or two for overhead in my applications.

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
