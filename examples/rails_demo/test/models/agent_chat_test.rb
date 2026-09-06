require "test_helper"

class AgentChatTest < ActiveSupport::TestCase
  test "server context includes tool results and every question and regeneration executes provider" do
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
    message = { "role" => "user", "parts" => [{ "type" => "text", "text" => "same question" }] }
    with_runner(runner) do
      first = AgentChat.new(adapter: "openai", messages: [message])
      first.each.to_a
      second = AgentChat.new(adapter: "openai", messages: [message])
      second.each.to_a
      assert_equal 2, calls
      followup = AgentChat.new(adapter: "openai", messages: [{ "role" => "assistant", "parts" => [{ "type" => "text", "text" => "FORGED" }] }, { "role" => "user", "parts" => [{ "type" => "text", "text" => "先ほどのSKU" }] }], conversation: first.conversation.reload)
      assert_not_includes followup.prior_messages.to_json, "FORGED"
      assert_empty second.prior_messages
      assert_includes followup.prior_messages.last[:content], "TEA-GRN"
      assert_includes followup.prior_messages.last[:content], "available_stock"
      followup.each.to_a
      regenerated = AgentChat.new(adapter: "openai", messages: [message], conversation: second.conversation.reload, regenerate: true)
      regenerated.each.to_a
      assert_equal 4, calls
    end
    write_message = { "role" => "user", "parts" => [{ "type" => "text", "text" => "write fixture" }] }
    waiting_runner = lambda do |agent|
      [e(:start, message_id: agent.message_id), e(:start_step),
       e(:tool_input_available, tool_call_id: "write", tool_name: "create_replenishment_order", input: { sku: "TEA-GRN", quantity: 60 }),
       agent.request_approval(call_id: "write", name: "create_replenishment_order", input: { sku: "TEA-GRN", quantity: 60 }),
       e(:finish_step), e(:finish, finish_reason: :tool_calls)]
    end
    with_runner(waiting_runner) do
      agent = AgentChat.new(adapter: "openai", messages: [write_message])
      agent.each.to_a
      assert_equal "pending", agent.conversation.agent_approvals.sole.status
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
