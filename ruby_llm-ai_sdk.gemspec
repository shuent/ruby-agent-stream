# frozen_string_literal: true

require_relative "lib/ruby_llm/stream/ai_sdk/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-ai_sdk"
  spec.version = RubyLLM::Stream::AISDK::VERSION
  spec.authors = ["shuent"]
  spec.email = ["shunshun.43@gmail.com"]

  spec.summary = "Stream RubyLLM responses to AI SDK useChat clients"
  spec.description = <<~DESCRIPTION
    A pure Ruby adapter that serializes RubyLLM streaming chunks and agent
    events as the AI SDK UI Message Stream Protocol.
  DESCRIPTION
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "CHANGELOG.md",
    "LICENSE.txt",
    "README.md",
    "lib/**/*.rb",
    "sig/**/*.rbs"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby_llm", "~> 1.16.0"
end
