# frozen_string_literal: true

require "anthropic"
require "ai_stream/adapters/anthropic"

prompt = ARGV.join(" ")
prompt = "Write one short greeting." if prompt.empty?
client = Anthropic::Client.new
sdk_stream = client.messages.stream(
  model: ENV.fetch("ANTHROPIC_MODEL"),
  max_tokens: 512,
  messages: [{ role: :user, content: prompt }]
)

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::Anthropic.new(sdk_stream).each { |event| ui_stream << event }
