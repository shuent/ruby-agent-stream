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

  private

  def build_agent(adapter)
    AgentChat.new(adapter: adapter, messages: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "食品の補充を調査" }] }])
  end
end
