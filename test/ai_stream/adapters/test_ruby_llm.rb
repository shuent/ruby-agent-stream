# frozen_string_literal: true

require "test_helper"
require "ai_stream/adapters/ruby_llm"

# Fixture assertions intentionally keep the complete protocol sequence visible.
# rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
class AgentStreamRubyLLMAdapterTest < Minitest::Test
  def test_real_chunk_and_message_models_are_converted_and_accepted_by_stream
    sdk_events = load_fixture

    assert sdk_events.grep(RubyLLM::Chunk).any?
    assert_instance_of RubyLLM::Message, sdk_events.find(&:tool_result?)

    ids = %w[1 2]
    adapter = AgentStream::Adapters::RubyLLM.new(
      sdk_events,
      message_id: "message-1",
      id_generator: -> { ids.shift }
    )
    events = adapter.to_a
    stream = AgentStream::UIMessage::V1::Stream.new
    events.each { |event| stream << event }

    assert_equal(
      %i[
        start start_step reasoning_start reasoning_delta text_start text_delta
        tool_input_start tool_input_delta tool_input_delta tool_input_available
        tool_output_available reasoning_end text_end finish_step start_step
        text_start text_delta text_end finish_step finish
      ],
      events.map(&:type)
    )
    assert_equal({ "city" => "Tokyo" }, event(events, :tool_input_available)[:input])
    assert_equal(
      { "temperature" => 24, "unit" => "celsius" },
      event(events, :tool_output_available)[:output]
    )
    assert_equal "gpt-5.4", events.last[:message_metadata]["model"]
    assert stream.finished?
  end

  def test_tool_loop_reuses_stream_key_in_a_new_step_and_aggregates_usage
    events = [
      tool_chunk("call-stock", "stock", { sku: "SKU-1" }, input_tokens: 10, output_tokens: 2),
      tool_result("call-stock", { available: 3 }),
      tool_chunk("call-sales", "sales", { sku: "SKU-1" }, input_tokens: 14, output_tokens: 3),
      tool_result("call-sales", { sold: 9 }),
      RubyLLM::Chunk.new(role: :assistant, content: "Reorder.", **model_attributes,
                         input_tokens: 18, output_tokens: 4)
    ]

    adapter_events = AgentStream::Adapters::RubyLLM.new(events).to_a
    stream = AgentStream::UIMessage::V1::Stream.new
    adapter_events.each { |event| stream << event }

    step_count = adapter_events.count { |candidate| candidate.type == :start_step }
    assert_equal 3, step_count
    tool_call_ids = adapter_events.filter_map do |candidate|
      candidate[:tool_call_id] if candidate.type == :tool_input_available
    end
    assert_equal %w[call-stock call-sales], tool_call_ids
    assert_equal(
      { "input_tokens" => 42, "output_tokens" => 9 },
      adapter_events.last[:message_metadata]["usage"]
    )
    assert stream.finished?
  end

  def test_invalid_streamed_arguments_become_a_protocol_error_event
    call = RubyLLM::ToolCall.new(id: "call-1", name: "weather", arguments: "{nope")
    chunk = RubyLLM::Chunk.new(role: :assistant, content: nil, tool_calls: { 0 => call })

    events = AgentStream::Adapters::RubyLLM.new([chunk]).to_a

    assert_equal :tool_input_error, event(events, :tool_input_error).type
  end

  def test_json_tool_result_string_and_sdk_finish_reason_are_restored
    events = [
      tool_chunk("call-stock", "stock", { sku: "SKU-1" }, input_tokens: 10, output_tokens: 2),
      RubyLLM::Message.new(role: :tool, content: JSON.generate(available: 3), tool_call_id: "call-stock"),
      RubyLLM::Chunk.new(role: :assistant, content: "Done.", finish_reason: :max_tokens, **model_attributes)
    ]

    adapter_events = AgentStream::Adapters::RubyLLM.new(events).to_a

    assert_equal({ "available" => 3 }, event(adapter_events, :tool_output_available)[:output])
    expected_reason = events.last.respond_to?(:finish_reason) ? "length" : "stop"
    assert_equal expected_reason, adapter_events.last[:finish_reason]
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
      **model_attributes(row[:model_id]),
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
      content: tool_result_content(row[:content]),
      tool_call_id: row[:tool_call_id]
    )
  end

  def tool_chunk(id, name, arguments, input_tokens:, output_tokens:)
    RubyLLM::Chunk.new(
      role: :assistant,
      **model_attributes,
      content: nil,
      tool_calls: { 0 => RubyLLM::ToolCall.new(id: id, name: name, arguments: arguments) },
      input_tokens: input_tokens,
      output_tokens: output_tokens
    )
  end

  def tool_result(id, content)
    RubyLLM::Message.new(
      role: :tool,
      content: tool_result_content(content),
      tool_call_id: id
    )
  end

  def model_attributes(model = "gpt-5.6-luna")
    { model_id: model, model: model }
  end

  def tool_result_content(content)
    return RubyLLM::Content::Raw.new(content) if defined?(RubyLLM::Content::Raw)

    JSON.generate(content)
  end

  def event(events, type)
    events.find { |candidate| candidate.type == type } || flunk("missing #{type}")
  end
end
