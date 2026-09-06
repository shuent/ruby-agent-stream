# frozen_string_literal: true

require "test_helper"
require "ai_stream/adapters/ruby_llm"

class AdapterWeatherTool < RubyLLM::Tool
  description "Return fixture weather without network access"
  if respond_to?(:parameter)
    parameter :city, type: :string
  else
    param :city, type: :string
  end

  attr_accessor :before_execute

  def execute(city:)
    before_execute&.call
    JSON.generate(city: city, temperature: 24)
  end
end

# Keep complete protocol sequences and actual SDK objects visible in each test.
# rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
class AgentStreamRubyLLMAdapterTest < Minitest::Test
  def test_streams_text_and_thinking_but_uses_only_completed_tool_inputs
    events = AgentStream::Adapters::RubyLLM.new(load_fixture, message_id: "message-1").to_a

    assert_equal(
      %i[
        start start_step reasoning_start reasoning_delta text_start text_delta
        reasoning_end text_end tool_input_available tool_output_available
        finish_step start_step text_start text_delta text_end finish_step finish
      ], events.map(&:type)
    )
    assert_equal "message-1", events.first[:message_id]
    assert_equal({ "city" => "Tokyo" }, event(events, :tool_input_available)[:input])
    assert_equal({ "temperature" => 24, "unit" => "celsius" }, event(events, :tool_output_available)[:output])
    assert_equal "signed-thinking", event(events, :reasoning_delta)[:provider_metadata]["ruby_llm"]["thought_signature"]
    assert_equal "gpt-5.4", events.last[:message_metadata]["model"]
    assert_equal "Checking Tokyo. It is 24°C.", events.select { |e| e.type == :text_delta }.map { |e| e[:delta] }.join
    assert_protocol(events)
  end

  def test_completed_messages_define_steps_and_usage_even_without_chunks
    input = [
      sdk_message(tool_calls: calls("1"), input_tokens: 10, output_tokens: 2), tool_result("1", '{"stock":3}'),
      sdk_message(tool_calls: calls("2"), input_tokens: 14, output_tokens: 3), tool_result("2", '{"stock":9}'),
      RubyLLM::Chunk.new(role: :assistant, content: "Done", input_tokens: 18, output_tokens: 4),
      sdk_message(content: "Done", input_tokens: 18, output_tokens: 4)
    ]
    events = AgentStream::Adapters::RubyLLM.new(input).to_a

    assert_equal(3, events.count { |e| e.type == :start_step })
    assert_equal(%w[1 2], events.select { |e| e.type == :tool_input_available }.map { |e| e[:tool_call_id] })
    assert_equal({ "input_tokens" => 42, "output_tokens" => 9 }, events.last[:message_metadata]["usage"])
    assert_protocol(events)
  end

  def test_ignores_partial_tool_arguments_without_reconstructing_or_validating_them
    partial = RubyLLM::ToolCall.new(id: nil, name: nil, arguments: "{nope")
    input = [RubyLLM::Chunk.new(role: :assistant, content: nil, tool_calls: { nil => partial }),
             sdk_message(tool_calls: calls("1"))]
    events = AgentStream::Adapters::RubyLLM.new(input).to_a

    assert_equal %i[start start_step tool_input_available finish_step finish], events.map(&:type)
    assert_equal({ "city" => "Tokyo" }, event(events, :tool_input_available)[:input])
    assert_protocol(events)
  end

  def test_multiple_tool_results_stay_in_the_same_step_when_ask_stops
    input = [sdk_message(tool_calls: calls("1", "2")), tool_result("2", "second"), tool_result("1", "first")]
    events = AgentStream::Adapters::RubyLLM.new(input).to_a

    assert_equal %i[start start_step tool_input_available tool_input_available tool_output_available
                    tool_output_available finish_step finish], events.map(&:type)
    assert_equal(%w[2 1], events.select { |e| e.type == :tool_output_available }.map { |e| e[:tool_call_id] })
    assert_protocol(events)
  end

  def test_source_exception_closes_streamed_parts_without_inventing_partial_tool_inputs
    input = Enumerator.new do |out|
      out << RubyLLM::Chunk.new(role: :assistant, content: "Checking")
      raise "connection lost"
    end
    events = AgentStream::Adapters::RubyLLM.new(input).to_a

    assert_equal %i[text_end finish_step error], events.last(3).map(&:type)
    assert_equal "connection lost", events.last[:error_text]
    assert_protocol(events)
  end

  def test_source_failure_before_first_chunk_and_empty_input
    input = Enumerator.new { |_out| raise "unavailable" }
    events = AgentStream::Adapters::RubyLLM.new(input).to_a
    assert_equal %i[start start_step finish_step error], events.map(&:type)
    assert_protocol(events)
    assert_protocol(AgentStream::Adapters::RubyLLM.new([]).to_a)
  end

  def test_consumer_and_invalid_input_errors_propagate
    received = []
    adapter = AgentStream::Adapters::RubyLLM.new([RubyLLM::Chunk.new(role: :assistant, content: "Hi")])
    assert_raises(IOError) do
      adapter.each do |value|
        received << value.type
        raise IOError, "sink closed" if value.type == :text_delta
      end
    end
    assert_equal %i[start start_step text_start text_delta], received
    assert_raises(AgentStream::Adapters::UnsupportedEventError) do
      AgentStream::Adapters::RubyLLM.new([Object.new]).to_a
    end
  end

  def test_finish_reason_comes_from_the_last_completed_message
    first = sdk_message(tool_calls: calls("1"), finish_reason: :tool_calls)
    input = [first, tool_result("1", "ok"), sdk_message(finish_reason: :max_tokens)]
    events = AgentStream::Adapters::RubyLLM.new(input).to_a
    assert_equal(first.respond_to?(:finish_reason) ? "length" : "stop", events.last[:finish_reason])
    assert_protocol(events)

    input[-1] = sdk_message
    assert_equal "stop", AgentStream::Adapters::RubyLLM.new(input).to_a.last[:finish_reason]
  end

  def test_real_chat_callbacks_publish_inputs_before_execution_and_results_before_continuation
    previous_key = RubyLLM.config.openai_api_key
    RubyLLM.configure { |config| config.openai_api_key = "local-contract-fixture" }
    tool = AdapterWeatherTool.new
    chat = RubyLLM.chat(model: "gpt-5.4", provider: :openai, assume_model_exists: true).with_tools(tool)
    received = []
    tool.before_execute = -> { assert_equal :tool_input_available, received.last.type }
    requests = 0
    chat.instance_variable_get(:@provider).define_singleton_method(:complete) do |*_args, **_options, &block|
      requests += 1
      if requests == 1
        call = RubyLLM::ToolCall.new(id: "weather-1", name: tool.name, arguments: { city: "Tokyo" })
        # Some providers need not stream any tool chunks at all.
        RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { call.id => call })
      else
        raise "result was not delivered before continuation" unless received.last.type == :tool_output_available

        block.call(RubyLLM::Chunk.new(role: :assistant, content: "24°C"))
        RubyLLM::Message.new(role: :assistant, content: "24°C")
      end
    end
    source = Enumerator.new do |out|
      chat.after_message { |value| out << value }
      chat.ask("Weather in Tokyo?") { |chunk| out << chunk }
    end
    AgentStream::Adapters::RubyLLM.new(source).each { |value| received << value }

    assert_equal 2, requests
    assert_equal({ "city" => "Tokyo", "temperature" => 24 }, event(received, :tool_output_available)[:output])
    assert_equal(1, received.count { |e| e.type == :text_delta })
    assert_protocol(received)
  ensure
    RubyLLM.configure { |config| config.openai_api_key = previous_key }
  end

  private

  def assert_protocol(events)
    stream = AgentStream::UIMessage::V1::Stream.new
    events.each { |candidate| stream << candidate }
    assert stream.finished?
    assert_equal 1, stream.frames.count("data: [DONE]\n\n")
  end

  def load_fixture
    JSON.parse(fixture("ruby_llm/chunks.json").read, symbolize_names: true).map do |row|
      kind = row.delete(:kind)
      row[:tool_calls]&.transform_values! { |call| RubyLLM::ToolCall.new(**call) }
      row[:thinking] = RubyLLM::Thinking.build(**row[:thinking]) if row[:thinking]
      row[:model] = row[:model_id]
      if kind == "tool_result"
        tool_result(row[:tool_call_id], JSON.generate(row[:content]))
      else
        klass = kind == "chunk" ? RubyLLM::Chunk : RubyLLM::Message
        klass.new(role: :assistant, **row)
      end
    end
  end

  def sdk_message(content: nil, **attributes)
    RubyLLM::Message.new(role: :assistant, content: content, model_id: "gpt-5.4", model: "gpt-5.4", **attributes)
  end

  def calls(*ids)
    ids.to_h { |id| [id, RubyLLM::ToolCall.new(id: id, name: "weather", arguments: { city: "Tokyo" })] }
  end

  def tool_result(id, content)
    RubyLLM::Message.new(role: :tool, content: content, tool_call_id: id)
  end

  def event(events, type)
    events.find { |candidate| candidate.type == type } || flunk("missing #{type}")
  end
end
