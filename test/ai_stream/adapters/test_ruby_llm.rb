# frozen_string_literal: true

require "test_helper"
require "ai_stream/adapters/ruby_llm"

# Fixture assertions intentionally keep the complete protocol sequence visible.
# rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
class AIStreamRubyLLMAdapterTest < Minitest::Test
  def test_real_chunk_and_message_models_are_converted_and_accepted_by_stream
    sdk_events = load_fixture

    assert sdk_events.grep(RubyLLM::Chunk).any?
    assert_instance_of RubyLLM::Message, sdk_events.find(&:tool_result?)

    ids = %w[1 2]
    adapter = AIStream::Adapters::RubyLLM.new(
      sdk_events,
      message_id: "message-1",
      id_generator: -> { ids.shift }
    )
    events = adapter.to_a
    stream = AIStream::UIMessage::V1::Stream.new
    events.each { |event| stream << event }

    assert_equal(
      %i[
        start start_step reasoning_start reasoning_delta text_start text_delta
        tool_input_start tool_input_delta tool_input_delta tool_input_available
        tool_output_available text_delta reasoning_end text_end finish_step finish
      ],
      events.map(&:type)
    )
    assert_equal({ "city" => "Tokyo" }, event(events, :tool_input_available)[:input])
    assert_equal(
      { "temperature" => 24, "unit" => "celsius" },
      event(events, :tool_output_available)[:output]
    )
    assert stream.finished?
  end

  def test_invalid_streamed_arguments_become_a_protocol_error_event
    call = RubyLLM::ToolCall.new(id: "call-1", name: "weather", arguments: "{nope")
    chunk = RubyLLM::Chunk.new(role: :assistant, content: nil, tool_calls: { 0 => call })

    events = AIStream::Adapters::RubyLLM.new([chunk]).to_a

    assert_equal :tool_input_error, event(events, :tool_input_error).type
  end

  private

  def load_fixture
    JSON.parse(fixture("ruby_llm/chunks.json").read, symbolize_names: true).map do |row|
      row[:kind] == "chunk" ? build_chunk(row) : build_tool_result(row)
    end
  end

  def build_chunk(row)
    tool_calls = row[:tool_calls]&.to_h do |key, value|
      [
        key,
        RubyLLM::ToolCall.new(
          id: value[:id],
          name: value[:name],
          arguments: value[:arguments]
        )
      ]
    end
    thinking = RubyLLM::Thinking.build(**row.fetch(:thinking, {}))
    RubyLLM::Chunk.new(
      role: :assistant,
      model_id: row[:model_id],
      content: row[:content],
      thinking: thinking,
      tool_calls: tool_calls,
      input_tokens: row[:input_tokens],
      output_tokens: row[:output_tokens]
    )
  end

  def build_tool_result(row)
    RubyLLM::Message.new(
      role: :tool,
      content: RubyLLM::Content::Raw.new(row[:content]),
      tool_call_id: row[:tool_call_id]
    )
  end

  def event(events, type)
    events.find { |candidate| candidate.type == type } || flunk("missing #{type}")
  end
end
