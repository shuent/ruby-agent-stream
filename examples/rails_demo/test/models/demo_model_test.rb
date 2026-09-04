require "test_helper"
require "ai_stream/adapters/openai"

class DemoModelTest < ActiveSupport::TestCase
  test "returns real SDK events that the OpenAI adapter can stream" do
    provider_events = DemoModel.new(sleeper: ->(_) {}).responses_stream(scenario: "complete")

    events = provider_events.to_a
    assert_instance_of OpenAI::Models::Responses::ResponseCreatedEvent, events.first
    assert_instance_of OpenAI::Models::Responses::ResponseCompletedEvent, events.last

    ui_stream = AIStream::UIMessage::V1::Stream.new
    AIStream::Adapters::OpenAI.new(events).each { |event| ui_stream << event }
    types = decoded_chunks(ui_stream).filter_map { |chunk| chunk["type"] }

    assert_includes types, "reasoning-delta"
    assert_includes types, "tool-input-available"
    assert_includes types, "text-delta"
    assert ui_stream.finished?
    assert_equal "[DONE]", ui_stream.frames.last.delete_prefix("data: ").strip
  end

  test "provider errors are converted to protocol errors" do
    provider_events = DemoModel.new(sleeper: ->(_) {}).responses_stream(scenario: "error")
    ui_stream = AIStream::UIMessage::V1::Stream.new

    AIStream::Adapters::OpenAI.new(provider_events).each { |event| ui_stream << event }
    error = decoded_chunks(ui_stream).find { |chunk| chunk["type"] == "error" }

    assert_equal "Synthetic provider failure", error["errorText"]
    assert ui_stream.finished?
  end

  private

  def decoded_chunks(ui_stream)
    ui_stream.frames.filter_map do |frame|
      payload = frame.delete_prefix("data: ").strip
      JSON.parse(payload) unless payload == "[DONE]"
    end
  end
end
