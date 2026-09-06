require "test_helper"

class SaasFlowTest < ActionDispatch::IntegrationTest
  setup do
    @token = SecureRandom.uuid
    @conversation = AgentConversation.start!(adapter: "openai", session_token: @token)
    @input = { "sku" => "TEA-GRN", "quantity" => 60 }
    @approval = @conversation.agent_approvals.create!(public_id: SecureRandom.uuid, message_id: "assistant-saved", tool_call_id: "call-saved",
      tool_name: "create_replenishment_order", input: @input, data_revision: InventoryCatalog.new.revision)
    @part = { "type" => "tool-create_replenishment_order", "state" => "approval-responded", "toolCallId" => "call-saved",
              "input" => @input, "approval" => { "id" => @approval.public_id, "approved" => true } }
    @message = { "id" => "assistant-saved", "role" => "assistant", "parts" => [@part] }
    events = [event(:start, message_id: "assistant-saved"), event(:start_step),
      event(:tool_input_available, tool_call_id: "call-saved", tool_name: "create_replenishment_order", input: @input),
      event(:tool_approval_request, approval_id: @approval.public_id, tool_call_id: "call-saved"),
      event(:finish_step), event(:finish, finish_reason: :tool_calls)]
    @conversation.save_events!(events)
  end

  test "approval wait has no write; approval commits once and dashboard reads same DB; replay is inert" do
    before = ReplenishmentOrder.count
    assert_equal "pending", @approval.reload.status
    respond_to_approval
    assert_response :success
    assert_includes response.body, '"type":"tool-output-available"'
    assert_equal before + 1, ReplenishmentOrder.count
    assert_equal 60, ReplenishmentOrder.last.quantity
    get "/demo/dashboard"
    assert_equal ReplenishmentOrder.last.id, response.parsed_body.fetch("orders").first.fetch("id")
    respond_to_approval
    assert_response :success
    assert_equal before + 1, ReplenishmentOrder.count
    get "/demo/conversations/#{@conversation.public_id}", headers: { "X-Demo-Session" => @token }
    part = response.parsed_body.fetch("messages").last.fetch("parts").find { |p| p["toolCallId"] == "call-saved" }
    assert_equal "output-available", part.fetch("state")
    assert_equal true, part.dig("approval", "approved")
    assert_equal ReplenishmentOrder.last.id, part.dig("output", "order", "id")
  end

  test "denial, tampered input, and another session cannot write" do
    before = ReplenishmentOrder.count
    respond_to_approval(token: SecureRandom.uuid)
    assert_equal before, ReplenishmentOrder.count
    assert_equal "pending", @approval.reload.status
    changed = @message.deep_dup
    changed["parts"][0]["input"]["quantity"] = 100
    respond_to_approval(message: changed)
    assert_equal "pending", @approval.reload.status
    denied = @message.deep_dup
    denied["parts"][0]["approval"]["approved"] = false
    respond_to_approval(message: denied)
    assert_includes response.body, '"type":"tool-output-denied"'
    assert_equal "denied", @approval.reload.status
    respond_to_approval
    assert_equal before, ReplenishmentOrder.count
  end

  test "confirmed reset changes revision, clears orders, preserves conversation audit, and rejects old approval" do
    old = InventoryCatalog.new.revision
    get "/demo/dashboard"
    assert response.parsed_body.fetch("demo_data")
    post "/demo/reset", params: { confirmed: false }, as: :json
    assert_response :unprocessable_entity
    post "/demo/reset", params: { confirmed: true }, as: :json
    assert_response :success
    assert_equal 4, response.parsed_body.fetch("inventory").size
    assert_not_equal old, response.parsed_body.fetch("revision")
    assert AgentConversation.exists?(@conversation.id)
    respond_to_approval
    assert_equal "stale", @approval.reload.status
    assert_equal 0, ReplenishmentOrder.count
    assert_includes response.body, '"type":"tool-output-denied"'
  end

  test "external inventory change invalidates pending approval" do
    InventoryItem.find_by!(sku: "TEA-GRN").increment!(:stock_on_hand)
    respond_to_approval
    assert_equal "stale", @approval.reload.status
  end

  private

  def respond_to_approval(token: @token, message: @message)
    post "/chat/openai", params: { id: @conversation.public_id, messages: [message] }, headers: { "X-Demo-Session" => token }, as: :json
  end

  def event(type, **attributes)
    AgentStream::UIMessage::V1::Event.new(type, **attributes)
  end
end
