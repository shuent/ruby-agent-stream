# frozen_string_literal: true

require "openai"
require "ai_stream/adapters/openai"

client = OpenAI::Client.new
sdk_stream = client.responses.stream(
  model: ENV.fetch("OPENAI_MODEL"),
  input: ARGV.join(" ").then { |prompt| prompt.empty? ? "Write one short greeting." : prompt }
)

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::OpenAI.new(sdk_stream).each { |event| ui_stream << event }
