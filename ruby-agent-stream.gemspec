# frozen_string_literal: true

require_relative "lib/ai_stream/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-agent-stream"
  spec.version = AgentStream::VERSION
  spec.authors = ["shuent"]
  spec.email = ["shunshun.43@gmail.com"]

  spec.summary = "Stream Ruby AI SDK events to AI SDK UI clients"
  spec.description = <<~DESCRIPTION
    A provider-neutral Ruby event model, stream encoder, and adapters for the
    AI SDK UI Message Stream Protocol.
  DESCRIPTION
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "CHANGELOG.md",
    "LICENSE.txt",
    "README.md",
    "README.ja.md",
    "lib/**/*.rb",
    "sig/**/*.rbs"
  ]
  spec.require_paths = ["lib"]
end
