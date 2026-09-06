require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  test "converts provider events and streams UI protocol frames" do
    post "/chat", params: { scenario: "complete" }, as: :json

    assert_response :success
    assert_equal "text/event-stream", response.headers["content-type"]
    assert_equal "v1", response.headers["x-vercel-ai-ui-message-stream"]
    assert_includes response.body, '"type":"reasoning-delta"'
    assert_includes response.body, '"type":"tool-input-available"'
    assert_includes response.body, '"type":"text-delta"'
    assert response.body.end_with?("data: [DONE]\n\n")
  end

  test "preflight permits a local React client" do
    process :options, "/chat/openai", headers: { "Origin" => "http://127.0.0.1:5173" }

    assert_response :no_content
    assert_equal "http://127.0.0.1:5173", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Access-Control-Allow-Methods"], "POST"
  end

  test "API-free conversation persists messages and regenerates through the runner" do
    token = SecureRandom.uuid
    conversation = AgentConversation.start!(adapter: "no-llm-call", session_token: token)
    2.times do |index|
      post "/chat/no-llm-call", params: { id: conversation.public_id,
        messages: [{ role: "user", parts: [{ type: "text", text: "在庫を確認" }] }], regenerate: index == 1 },
        headers: { "X-Demo-Session" => token }, as: :json
      assert_response :success
      assert_includes response.body, '"type":"text-delta"'
      assert_nil response.headers["X-Agent-Cache"]
      assert_equal %w[user assistant], conversation.reload.messages.map { |m| m["role"] }
    end
  end

  test "preflight does not reflect an unrelated origin" do
    process :options, "/chat", headers: { "Origin" => "https://attacker.example" }

    assert_response :no_content
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end
end
