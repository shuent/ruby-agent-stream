# frozen_string_literal: true

require "test_helper"
require "ai_stream/adapters/openai"

# Fixture assertions intentionally keep the complete protocol sequence visible.
# rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
class AgentStreamOpenAIAdapterTest < Minitest::Test
  def test_real_responses_event_models_are_converted_and_accepted_by_stream
    sdk_events = load_fixture

    assert_instance_of OpenAI::Models::Responses::ResponseCreatedEvent, sdk_events.first
    assert_instance_of OpenAI::Models::Responses::ResponseCompletedEvent, sdk_events.last

    events = AgentStream::Adapters::OpenAI.new(sdk_events).to_a
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
    assert_equal "tool-calls", events.last[:finish_reason]
    assert stream.finished?
    assert_equal "data: [DONE]\n\n", stream.frames.last
  end

  def test_invalid_function_arguments_become_a_protocol_error_event
    sdk_events = load_fixture.take(5)
    sdk_events << coerce(
      type: "response.function_call_arguments.done",
      arguments: "{nope",
      item_id: "fc_item_001",
      name: "weather",
      output_index: 1,
      sequence_number: 5
    )

    events = AgentStream::Adapters::OpenAI.new(sdk_events).to_a
    input_error = event(events, :tool_input_error)

    assert_equal "{nope", input_error[:input]
    assert_match "invalid JSON tool input", input_error[:error_text]
  end

  def test_response_stream_helper_event_is_supported
    helper = OpenAI::Helpers::Streaming::ResponseTextDeltaEvent.new(
      type: :"response.output_text.delta",
      content_index: 0,
      delta: "hello",
      item_id: "msg_1",
      logprobs: [],
      output_index: 0,
      sequence_number: 1,
      snapshot: "hello"
    )

    events = AgentStream::Adapters::OpenAI.new([helper], message_id: "message-1").to_a

    assert_equal "hello", event(events, :text_delta)[:delta]
  end

  def test_step_lifecycle_can_join_multiple_responses_into_one_ui_message
    adapter = AgentStream::Adapters::OpenAI.new(load_fixture, lifecycle: :step)
    stream = AgentStream::UIMessage::V1::Stream.new
    stream << AgentStream::UIMessage::V1::Event.new(:start, message_id: "message-1")

    events = adapter.to_a
    events.each { |event| stream << event }
    stream << AgentStream::UIMessage::V1::Event.new(:finish, finish_reason: adapter.finish_reason)

    assert_equal :start_step, events.first.type
    assert_equal %i[message_metadata finish_step], events.last(2).map(&:type)
    assert_equal "resp_fixture_001", adapter.response.id
    assert_equal :tool_calls, adapter.finish_reason
    assert stream.finished?
  end

  def test_content_lifecycle_joins_provider_calls_around_app_owned_tool_output
    adapter = AgentStream::Adapters::OpenAI.new(load_fixture, lifecycle: :content)
    stream = AgentStream::UIMessage::V1::Stream.new
    stream << AgentStream::UIMessage::V1::Event.new(:start, message_id: "message-1")
    stream << AgentStream::UIMessage::V1::Event.new(:start_step)

    events = adapter.to_a
    events.each { |event| stream << event }
    stream << AgentStream::UIMessage::V1::Event.new(
      :tool_output_available,
      tool_call_id: "call_weather_001",
      output: { temperature: 24 }
    )
    stream << AgentStream::UIMessage::V1::Event.new(:finish_step)
    stream << AgentStream::UIMessage::V1::Event.new(:start_step)

    final_adapter = AgentStream::Adapters::OpenAI.new([text_delta_helper], lifecycle: :content)
    final_adapter.each { |event| stream << event }
    stream << AgentStream::UIMessage::V1::Event.new(:finish_step)
    stream << AgentStream::UIMessage::V1::Event.new(:finish, finish_reason: final_adapter.finish_reason)

    refute_includes events.map(&:type), :start
    refute_includes events.map(&:type), :start_step
    refute_includes events.map(&:type), :finish_step
    refute_includes events.map(&:type), :finish
    assert_equal :message_metadata, events.last.type
    assert_equal :stop, final_adapter.finish_reason
    assert stream.finished?
  end

  private

  def load_fixture
    fixture("openai/responses_stream.jsonl").each_line(chomp: true).reject(&:empty?).map do |line|
      coerce(**JSON.parse(line, symbolize_names: true))
    end
  end

  def coerce(**attributes)
    OpenAI::Internal::Type::Converter.coerce(
      OpenAI::Models::Responses::ResponseStreamEvent,
      attributes
    )
  end

  def text_delta_helper
    OpenAI::Helpers::Streaming::ResponseTextDeltaEvent.new(
      type: :"response.output_text.delta",
      content_index: 0,
      delta: "done",
      item_id: "msg-final",
      logprobs: [],
      output_index: 0,
      sequence_number: 1,
      snapshot: "done"
    )
  end

  def event(events, type)
    events.find { |candidate| candidate.type == type } || flunk("missing #{type}")
  end
end
