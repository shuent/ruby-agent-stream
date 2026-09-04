# frozen_string_literal: true

require "test_helper"
require "ai_stream/adapters/anthropic"

# Fixture assertions intentionally keep the complete protocol sequence visible.
# rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
class AIStreamAnthropicAdapterTest < Minitest::Test
  def test_real_messages_event_models_are_converted_and_accepted_by_stream
    sdk_events = load_fixture

    assert_instance_of Anthropic::Models::RawMessageStartEvent, sdk_events.first
    assert_instance_of Anthropic::Models::RawMessageStopEvent, sdk_events.last

    events = AgentStream::Adapters::Anthropic.new(sdk_events).to_a
    stream = AgentStream::UIMessage::V1::Stream.new
    events.each { |event| stream << event }

    assert_equal(
      %i[
        start start_step reasoning_start reasoning_delta reasoning_end
        tool_input_start tool_input_delta tool_input_delta tool_input_available
        text_start text_delta text_end finish_step finish
      ],
      events.map(&:type)
    )
    assert_equal({ "city" => "Tokyo" }, event(events, :tool_input_available)[:input])
    assert_equal(
      { "anthropic" => { "signature" => "signed-thinking" } },
      event(events, :reasoning_end)[:provider_metadata]
    )
    assert_equal "tool-calls", events.last[:finish_reason]
    assert stream.finished?
  end

  def test_high_level_helper_events_are_ignored
    helper = Anthropic::Streaming::TextEvent.new(type: :text, text: "duplicate", snapshot: "duplicate")

    events = AgentStream::Adapters::Anthropic.new([helper], message_id: "message-1").to_a

    assert_equal %i[start start_step finish_step finish], events.map(&:type)
  end

  private

  def load_fixture
    fixture("anthropic/messages_stream.jsonl").each_line(chomp: true).reject(&:empty?).map do |line|
      attributes = JSON.parse(line, symbolize_names: true)
      Anthropic::Models::RawMessageStreamEvent.new(**attributes)
    end
  end

  def event(events, type)
    events.find { |candidate| candidate.type == type } || flunk("missing #{type}")
  end
end
