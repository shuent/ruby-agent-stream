# frozen_string_literal: true

require "ai_stream"

Event = AgentStream::UIMessage::V1::Event

events = [
  Event.new(:start, message_id: "assistant-1"),
  Event.new(:start_step),
  Event.new(:text_start, id: "text-1"),
  Event.new(:text_delta, id: "text-1", delta: "Hello"),
  Event.new(:text_end, id: "text-1"),
  Event.new(:finish_step),
  Event.new(:finish, finish_reason: :stop)
]

ui_stream = AgentStream::UIMessage::V1::Stream.new($stdout)
events.to_enum.each { |event| ui_stream << event }
