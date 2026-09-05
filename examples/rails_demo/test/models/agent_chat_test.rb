require "test_helper"

class AgentChatTest < ActiveSupport::TestCase
  test "server context includes tool results, cache skips provider, regeneration calls it, writes are never cached" do
    calls = 0
    runner = lambda do |agent|
      calls += 1
      Enumerator.new do |out|
        out << e(:start, message_id: agent.message_id)
        out << e(:start_step)
        %w[search_inventory review_sales].each do |name|
          input = { "skus" => ["TEA-GRN"] }
          output = { "items" => [{ "sku" => "TEA-GRN", "available_stock" => 9 }] }
          agent.observe_tool(name, input, output)
          out << e(:tool_input_available, tool_call_id: name, tool_name: name, input: input)
          out << e(:tool_output_available, tool_call_id: name, output: output)
        end
        out << e(:finish_step)
        out << e(:finish, finish_reason: :stop)
      end
    end
    message = { "role" => "user", "parts" => [{ "type" => "text", "text" => "cache fixture" }] }
    with_runner(runner) do
      first = AgentChat.new(adapter: "openai", messages: [message])
      first.each.to_a
      second = AgentChat.new(adapter: "openai", messages: [message])
      second.each.to_a
      assert_equal "hit", second.run.cache_status
      assert_equal 1, calls
      followup = AgentChat.new(adapter: "openai", messages: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "先ほどのSKU" }] }], conversation: first.conversation.reload)
      assert_includes followup.prior_messages.last[:content], "TEA-GRN"
      assert_includes followup.prior_messages.last[:content], "available_stock"
      followup.conversation.update!(active_run: nil)
      regenerated = AgentChat.new(adapter: "openai", messages: [message], conversation: second.conversation.reload, regenerate: true)
      regenerated.each.to_a
      assert_equal "bypass", regenerated.run.cache_status
      assert_equal 2, calls
    end
    write_message = { "role" => "user", "parts" => [{ "type" => "text", "text" => "write fixture" }] }
    waiting_runner = lambda do |agent|
      [e(:start, message_id: agent.message_id), e(:start_step),
       e(:tool_input_available, tool_call_id: "write", tool_name: "create_replenishment_order", input: { sku: "TEA-GRN", quantity: 60 }),
       agent.request_approval(call_id: "write", name: "create_replenishment_order", input: { sku: "TEA-GRN", quantity: 60 }),
       e(:finish_step), e(:finish, finish_reason: :tool_calls)]
    end
    with_runner(waiting_runner) do
      assert_no_difference "AgentCacheEntry.count" do
        AgentChat.new(adapter: "openai", messages: [write_message]).each.to_a
      end
    end
  end

  private

  def with_runner(factory)
    original = OpenaiAgentRunner.method(:new)
    OpenaiAgentRunner.define_singleton_method(:new) { |*args| factory.call(*args) }
    yield
  ensure
    OpenaiAgentRunner.define_singleton_method(:new, original)
  end

  def e(type, **attributes)
    AgentStream::UIMessage::V1::Event.new(type, **attributes)
  end
end
