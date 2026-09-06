require "test_helper"

# Real installed SDK objects and tool dispatch; only the provider boundary is fake.
class AgentRunnersTest < ActiveSupport::TestCase
  test "OpenAI runner passes keyword arguments to RubyLLM tools and returns their outputs" do
    agent = build_agent("openai")
    requests = []
    responses = Object.new
    responses.define_singleton_method(:stream) do |**payload|
      requests << payload
      output = requests.length == 1 ? [{ type: "function_call", id: "fc-1", call_id: "call-1",
        name: "search_inventory", arguments: '{"skus":["TEA-GRN"]}' }] : []
      raw = output.map { |item| { type: "response.output_item.added", item: item, output_index: 0, sequence_number: 0 } }
      raw << { type: "response.completed", response: { id: "response-#{requests.length}", output: output }, sequence_number: 1 }
      raw.map { |value| OpenAI::Internal::Type::Converter.coerce(OpenAI::Models::Responses::ResponseStreamEvent, value) }
    end
    client = Struct.new(:responses).new(responses)
    events = OpenaiAgentRunner.new(agent, client: client).each.to_a
    assert_equal 2, requests.length
    output = events.find { |event| event.type == :tool_output_available }[:output]
    assert_equal "TEA-GRN", output.fetch("items").first.fetch("sku")
    assert_equal 9, output.fetch("items").first.fetch("available_stock")
    assert_equal "call-1", requests.last[:input].first[:call_id]
    assert_equal :finish, events.last.type
  end

  test "RubyLLM counts provider requests rather than tool result messages" do
    agent = build_agent("ruby_llm")
    previous_key = RubyLLM.config.openai_api_key
    RubyLLM.configure { |config| config.openai_api_key = "non-billing-test-key" }
    chat = RubyLLM.chat(model: AgentChat::MODEL, provider: :openai, protocol: :responses, assume_model_exists: true)
    requests = 0
    chat.provider.define_singleton_method(:complete) do |messages, before_request:, **options, &block|
      before_request.each { |callback| callback.call({}) }
      requests += 1
      names = case requests
      when 1 then %w[search_inventory review_sales check_supplier_terms calculate_replenishment]
      when 2 then %w[search_inventory]
      else []
      end
      calls = names.to_h do |name|
        id = "call-#{requests}-#{name}"
        [id, RubyLLM::ToolCall.new(id: id, name: name, arguments: { skus: ["TEA-GRN"] })]
      end
      content = names.empty? ? "補充候補を確認しました。" : nil
      block.call(RubyLLM::Chunk.new(role: :assistant, content: content, tool_calls: calls, model_id: AgentChat::MODEL))
      RubyLLM::Message.new(role: :assistant, content: content, tool_calls: calls, model_id: AgentChat::MODEL)
    end
    original = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**| chat }
    events = RubyLlmAgentRunner.new(agent).each.to_a
    assert_equal 3, requests
    assert_equal 5, events.count { |event| event.type == :tool_output_available }
    assert_equal :finish, events.last.type
    stream = AgentStream::UIMessage::V1::Stream.new
    events.each { |event| stream << event }
    assert stream.finished?
  ensure
    RubyLLM.define_singleton_method(:chat, original) if original
    RubyLLM.configure { |config| config.openai_api_key = previous_key }
  end

  test "RubyLLM completed tool input remains available when native approval parks the chat" do
    agent = build_agent("ruby_llm")
    previous_key = RubyLLM.config.openai_api_key
    RubyLLM.configure { |config| config.openai_api_key = "non-billing-test-key" }
    chat = RubyLLM.chat(model: AgentChat::MODEL, provider: :openai, protocol: :responses, assume_model_exists: true)
    requests = 0
    chat.provider.define_singleton_method(:complete) do |*_, **|
      requests += 1
      raise "approval must stop continuation" if requests > 1
      call = RubyLLM::ToolCall.new(id: "order-1", name: "create_replenishment_order",
        arguments: { sku: "TEA-GRN", quantity: 60 })
      RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { call.id => call })
    end
    original = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**| chat }
    events = RubyLlmAgentRunner.new(agent).each.to_a

    assert_equal 1, requests
    assert chat.awaiting_approval?
    assert_equal %i[tool_input_available tool_approval_request finish_step finish], events.last(4).map(&:type)
    assert_equal({ "sku" => "TEA-GRN", "quantity" => 60 }, events.find { |event| event.type == :tool_input_available }[:input])
    assert_equal 1, agent.conversation.agent_approvals.count
    refute events.any? { |event| event.type == :tool_output_available }
    stream = AgentStream::UIMessage::V1::Stream.new
    events.each { |event| stream << event }
    assert stream.finished?
  ensure
    RubyLLM.define_singleton_method(:chat, original) if original
    RubyLLM.configure { |config| config.openai_api_key = previous_key }
  end

  private

  def build_agent(adapter)
    AgentChat.new(adapter: adapter, messages: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "食品の補充を調査" }] }])
  end
end

class OpenaiAgentRunnerProtocolTest < ActiveSupport::TestCase
  test "multiple tools finish in their step before the next response" do
    calls = [call("1", "search_inventory"), call("2", "review_sales")]
    events, requests = run_responses([completed(calls, "first")], [text_delta, completed([], "second")])
    assert_equal 2, requests.size
    assert requests.all? { |request| request[:store] == true }
    assert_equal "first", requests.last[:previous_response_id]
    assert_equal %w[1 2], requests.last[:input].map { |item| item[:call_id] }
    assert_equal 1, events.count { |event| event.type == :start }
    assert_equal 2, events.count { |event| event.type == :start_step }
    assert_equal 2, events.count { |event| event.type == :tool_output_available }
    last_output = events.rindex { |event| event.type == :tool_output_available }
    assert_operator last_output, :<, events.index { |event| event.type == :finish_step }
    assert_equal "stop", events.last[:finish_reason]
    assert_protocol(events)
  end

  test "approval stops provider calls and retains pending approval" do
    order = call("order", "create_replenishment_order", '{"sku":"TEA-GRN","quantity":60}')
    events, requests = run_responses([completed([order])])
    assert_equal 1, requests.size
    assert_equal 1, events.count { |event| event.type == :tool_approval_request }
    assert_equal "tool-calls", events.last[:finish_reason]
    assert_protocol(events)
  end

  test "failed and incomplete responses do not execute tools or query again" do
    %w[failed incomplete].each do |status|
      terminal = { type: "response.#{status}", sequence_number: 2,
        response: { id: "bad", status: status, output: [call("1", "search_inventory")],
          error: { code: "server_error", message: "provider failed" },
          incomplete_details: { reason: "max_output_tokens" } } }
      events, requests = run_responses([text_delta, terminal])
      assert_equal 1, requests.size
      assert_equal :error, events.last.type
      assert_equal 0, events.count { |event| event.type == :tool_output_available }
      assert_protocol(events)
    end
  end

  test "source exception and missing completion close open text with one error" do
    source = Enumerator.new do |out|
      out << coerce(text_delta)
      raise "connection lost"
    end
    [source, [coerce(text_delta)]].each do |stream|
      events, = run_responses(stream)
      assert_equal :error, events.last.type
      assert_equal 1, events.count { |event| event.type == :text_end }
      assert_protocol(events)
    end
  end

  test "step limit stops with an error after tool outputs" do
    streams = AgentChat::MAX_STEPS.times.map { |index| [completed([call(index.to_s, "search_inventory")])] }
    events, requests = run_responses(*streams)
    assert_equal AgentChat::MAX_STEPS, requests.size
    assert_equal :error, events.last.type
    assert_match "exceeded", events.last[:error_text]
    assert_protocol(events)
  end

  test "real SDK fixture preserves reasoning text and response usage" do
    fixture_path = Rails.root.join("test/fixtures/files/openai/responses_stream.jsonl")
    raw = fixture_path.each_line.map { |line| JSON.parse(line, symbolize_names: true) }
    events, = run_responses(raw)
    assert_equal "I should check the weather.", events.find { |event| event.type == :reasoning_delta }[:delta]
    assert_equal "It is 24°C.", events.find { |event| event.type == :text_delta }[:delta]
    metadata = events.find { |event| event.type == :message_metadata }[:message_metadata]
    assert_equal "resp_fixture_001", metadata.fetch("response_id")
    assert_equal 20, metadata.dig("usage", "total_tokens")
    assert_protocol(events)
  end

  test "tool exceptions and invalid arguments end once without another request" do
    [call("bad", "missing_tool"), call("bad", "search_inventory", "{broken")].each do |tool|
      events, requests = run_responses([completed([tool])])
      assert_equal 1, requests.size
      assert_equal :error, events.last.type
      assert_protocol(events)
    end
  end

  test "source IO failure is converted but consumer IO failure propagates" do
    source = Enumerator.new do |out|
      out << coerce(text_delta)
      raise IOError, "provider disconnected"
    end
    events, = run_responses(source)
    assert_equal "provider disconnected", events.last[:error_text]
    assert_protocol(events)
    agent = AgentChat.new(adapter: "openai", messages: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "調査" }] }])
    calls = 0
    assert_raises(IOError) do
      OpenaiAgentRunner.new(agent, client: nil).each do |_event|
        calls += 1
        raise IOError, "browser disconnected"
      end
    end
    assert_equal 1, calls
  end

  test "real runner approval history continues without another provider request" do
    agent = AgentChat.new(adapter: "openai", messages: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "登録" }] }])
    order = call("order", "create_replenishment_order", '{"sku":"TEA-GRN","quantity":60}')
    api = Object.new
    requests = 0
    sdk_events = [coerce(completed([order]))]
    api.define_singleton_method(:stream) do |**|
      requests += 1
      sdk_events
    end
    client = Struct.new(:responses).new(api)
    original = OpenaiAgentRunner.method(:new)
    OpenaiAgentRunner.define_singleton_method(:new) { |value| original.call(value, client: client) }
    waiting = agent.each.to_a
    assert_equal "awaiting_approval", agent.run.reload.status
    assert_protocol(waiting)
    message = agent.conversation.reload.messages.last.deep_dup
    part = message.fetch("parts").find { |value| value["type"] == "tool-create_replenishment_order" }
    part["state"] = "approval-responded"
    part.fetch("approval")["approved"] = true
    continuation = AgentChat.new(adapter: "openai", messages: [message], conversation: agent.conversation)
    before = ReplenishmentOrder.count
    events = continuation.each.to_a
    assert_equal before + 1, ReplenishmentOrder.count
    assert_equal 1, requests
    assert_equal waiting.first[:message_id], events.first[:message_id]
    stream = AgentStream::UIMessage::V1::Stream.new(continuation: waiting)
    events.each { |event| stream << event }
    assert stream.finished?
  ensure
    OpenaiAgentRunner.define_singleton_method(:new, original) if original
  end

  private

  def run_responses(*streams)
    agent = AgentChat.new(adapter: "openai", messages: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "調査" }] }])
    requests = []
    responses = Object.new
    responses.define_singleton_method(:stream) do |**request|
      requests << request
      streams.fetch(requests.size - 1)
    end
    streams.map! { |stream| stream.is_a?(Array) ? stream.map { |raw| raw.is_a?(Hash) ? coerce(raw) : raw } : stream }
    [OpenaiAgentRunner.new(agent, client: Struct.new(:responses).new(responses)).each.to_a, requests]
  end

  def call(id, name, arguments = '{"skus":["TEA-GRN"]}')
    { type: "function_call", id: "fc-#{id}", call_id: id, name: name, arguments: arguments }
  end

  def completed(output, id = "response-1")
    { type: "response.completed", sequence_number: 2, response: { id: id, status: "completed", output: output } }
  end

  def text_delta
    { type: "response.output_text.delta", item_id: "text", content_index: 0, output_index: 0,
      sequence_number: 1, delta: "hello", logprobs: [] }
  end

  def coerce(value)
    OpenAI::Internal::Type::Converter.coerce(OpenAI::Models::Responses::ResponseStreamEvent, value)
  end

  def assert_protocol(events)
    stream = AgentStream::UIMessage::V1::Stream.new
    events.each { |event| stream << event }
    assert stream.finished?
    assert_equal 1, stream.frames.count("data: [DONE]\n\n")
  end
end
