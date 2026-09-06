# frozen_string_literal: true

require "ruby_llm"
require "ai_stream/adapters/ruby_llm"

prompt = ARGV.join(" ")
prompt = "Write one short greeting." if prompt.empty?
sdk_events = Enumerator.new do |events|
  chat = RubyLLM.chat
  chat.after_message { |message| events << message }
  chat.ask(prompt) { |chunk| events << chunk }
end

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
AgentStream::Adapters::RubyLLM.new(sdk_events).each { |event| ui_stream << event }
