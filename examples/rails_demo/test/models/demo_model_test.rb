require "test_helper"

class DemoModelTest < ActiveSupport::TestCase
  test "returns plain provider events that an Enumerator converts for the stream" do
    provider_events = DemoModel.new(sleeper: ->(_) {}).stream(scenario: "complete")

    events = provider_events.to_a
    assert_instance_of DemoModel::ProviderEvent, events.first
    refute_kind_of AgentStream::UIMessage::V1::Event, events.first

    ui_stream = AgentStream::UIMessage::V1::Stream.new
    events.each do |provider_event|
      ui_stream << AgentStream::UIMessage::V1::Event.new(provider_event.type, **provider_event.payload)
    end
    types = decoded_chunks(ui_stream).filter_map { |chunk| chunk["type"] }

    assert_includes types, "reasoning-delta"
    assert_includes types, "tool-input-available"
    assert_includes types, "text-delta"
    assert ui_stream.finished?
    assert_equal "[DONE]", ui_stream.frames.last.delete_prefix("data: ").strip
  end

  test "provider errors are converted to protocol errors" do
    provider_events = DemoModel.new(sleeper: ->(_) {}).stream(scenario: "error")
    ui_stream = AgentStream::UIMessage::V1::Stream.new

    provider_events.each do |provider_event|
      ui_stream << AgentStream::UIMessage::V1::Event.new(provider_event.type, **provider_event.payload)
    end
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
