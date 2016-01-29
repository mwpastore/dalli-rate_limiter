# coding: utf-8
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "dalli/rate_limiter/version"

Gem::Specification.new do |spec|
  spec.name          = "dalli-rate_limiter"
  spec.version       = Dalli::RateLimiter::VERSION
  spec.authors       = ["Mike Pastore"]
  spec.email         = ["mike@oobak.org"]

  spec.summary       = "Arbitrary Memcached-backed rate limiting for Ruby"
  spec.description   = spec.summary
  spec.homepage      = "https://github.com/mwpastore/dalli-rate_limiter"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^#{spec.bindir}/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = '>= 1.9.3'

  spec.add_runtime_dependency "dalli", "~> 2.7.5"
  spec.add_runtime_dependency "connection_pool", "~> 2.2.0"

  spec.add_development_dependency "bundler", "~> 1.11.0"
  spec.add_development_dependency "rake", "~> 10.5.0"
  spec.add_development_dependency "rubocop", "~> 0.35.0"
  spec.add_development_dependency "rspec", "~> 3.4.0"
  spec.add_development_dependency "rspec-given", "~> 3.8.0"
end
