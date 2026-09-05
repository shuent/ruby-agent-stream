require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  test "converts provider events and streams UI protocol frames" do
    post "/chat/no-llm-call", params: { scenario: "complete" }, as: :json

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

  test "agent endpoint replays a persisted successful response without a provider call" do
    messages = [{ "id" => "user-1", "role" => "user", "parts" => [{ "type" => "text", "text" => "在庫を確認" }] }]
    digest = AgentCacheKey.digest(adapter: "openai", messages: messages, system_prompt: AgentChat::SYSTEM_PROMPT)
    events = [
      AgentStream::UIMessage::V1::Event.new(:start, message_id: "cached"),
      AgentStream::UIMessage::V1::Event.new(:start_step),
      AgentStream::UIMessage::V1::Event.new(:text_start, id: "answer"),
      AgentStream::UIMessage::V1::Event.new(:text_delta, id: "answer", delta: "保存済みの提案"),
      AgentStream::UIMessage::V1::Event.new(:text_end, id: "answer"),
      AgentStream::UIMessage::V1::Event.new(:finish_step),
      AgentStream::UIMessage::V1::Event.new(:finish, finish_reason: :stop)
    ]
    AgentCacheEntry.create!(request_digest: digest, adapter: "openai", provider_model: AgentChat::MODEL,
                            normalized_prompt: "在庫を確認", event_log: AgentEventLog.dump(events),
                            run_metadata: JSON.generate(tool_names: %w[search_inventory review_sales], reasoning_observed: true))

    token = SecureRandom.uuid
    conversation = AgentConversation.start!(adapter: "openai", session_token: token)
    post "/chat/openai", params: { id: conversation.public_id, messages: messages }, headers: { "X-Demo-Session" => token }, as: :json

    assert_response :success
    assert_includes response.body, "保存済みの提案"
    assert_includes response.body, '"type":"data-run"'
    assert_includes response.body, '"cache_status":"hit"'
  end

  test "preflight does not reflect an unrelated origin" do
    process :options, "/chat", headers: { "Origin" => "https://attacker.example" }

    assert_response :no_content
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end
end
