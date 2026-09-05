# frozen_string_literal: true

# Run with the example's pinned RubyLLM 2.0 development bundle. No network calls.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "ai_stream/adapters/ruby_llm"
require "ai_stream"
require "minitest/autorun"

class ApprovalContractTool < RubyLLM::Tool
  description "A local-only contract fixture"
  requires_approval

  attr_reader :executions

  def execute
    @executions = (@executions || 0) + 1
    { saved: true }
  end
end

# Keep one SDK request/response contract visible in each test.
# rubocop:disable-next Metrics/MethodLength, Metrics/AbcSize
class RubyLLMResponsesContractTest < Minitest::Test
  def setup
    RubyLLM.configure { |config| config.openai_api_key = "local-contract-fixture" }
    @tool = ApprovalContractTool.new
    @chat = RubyLLM.chat(model: "gpt-5.6-luna", provider: :openai, protocol: :responses,
                         assume_model_exists: true).with_tools(@tool)
    @protocol = RubyLLM::Protocols::Responses.new(@chat.provider, @chat.model)
  end

  def test_responses_payload_and_real_parser_chunks_are_adapter_compatible
    thinking = RubyLLM::Thinking::Config.new(effort: :medium, display: :summarized)
    payload = @protocol.send(:render_payload, [], tools: @chat.tools, temperature: nil, model: @chat.model,
                                                  thinking: thinking, stream: true)
    assert_equal "responses", @protocol.send(:completion_url)
    assert_equal({ effort: "medium", summary: "auto" }, payload[:reasoning])
    assert_equal "function", payload[:tools].first[:type]
    refute payload[:store]
    assert_includes payload[:include], "reasoning.encrypted_content"

    raw = [
      { type: "response.reasoning_summary_text.delta", delta: "Check the fixture." },
      { type: "response.output_item.added", output_index: 0,
        item: { type: "function_call", call_id: "call-1", name: "approval_contract" } },
      { type: "response.function_call_arguments.delta", output_index: 0, delta: "{}" },
      { type: "response.completed", response: { model: "gpt-5.6-luna", status: "completed",
                                                output: [{ type: "function_call" }],
                                                usage: { input_tokens: 8, output_tokens: 3 } } }
    ]
    chunks = raw.map { |data| @protocol.send(:build_chunk, JSON.parse(JSON.generate(data))) }
    events = AgentStream::Adapters::RubyLLM.new(chunks).to_a
    stream = AgentStream::UIMessage::V1::Stream.new
    events.each { |event| stream << event }
    assert stream.finished?
    assert_equal "gpt-5.6-luna", events.last[:message_metadata]["model"]
    # This SDK maps completed Responses to :stop even when they contain tools.
    assert_equal "stop", events.last[:finish_reason]
    assert_equal({}, events.find { |event| event.type == :tool_input_available }[:input])
    assert_equal(1, events.count { |event| event.type == :reasoning_delta })
  end

  def test_native_approval_parks_and_runs_once_without_a_provider_call
    call = RubyLLM::ToolCall.new(id: "call-approval", name: @tool.name, arguments: {})
    @chat.add_message(role: :assistant, content: nil, tool_calls: { call.id => call })
    assert @chat.awaiting_approval?
    assert_equal [call.id], @chat.pending_approvals.map(&:id)
    @chat.run_tools
    assert_nil @tool.executions
    @chat.approve(call.id).run_tools
    assert_equal 1, @tool.executions
    assert @chat.messages.last.tool_result?
    @chat.approve(call.id).run_tools
    assert_equal 1, @tool.executions
  end
end
