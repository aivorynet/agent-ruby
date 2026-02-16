# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "aivory_monitor"
  spec.version       = "1.0.0"
  spec.authors       = ["AIVory"]
  spec.email         = ["support@aivory.net"]

  spec.summary       = "AIVory Monitor - Runtime exception monitoring agent for Ruby applications"
  spec.description   = "Real-time exception monitoring with AI-powered analysis for Ruby applications. Captures exceptions, stack traces, and local variables with zero performance impact."
  spec.homepage      = "https://aivory.net/monitor"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 2.7.0"

  spec.files = Dir[
    "lib/**/*",
    "LICENSE",
    "README.md"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "websocket-client-simple", "~> 0.6"

  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rubocop", "~> 1.0"
end
