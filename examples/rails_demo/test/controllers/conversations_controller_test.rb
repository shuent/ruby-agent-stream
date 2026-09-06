require "test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  test "list and restore only this browser's conversations; new conversations are empty" do
    token = SecureRandom.uuid
    headers = { "X-Demo-Session" => token }
    other = AgentConversation.start!(adapter: "openai", session_token: SecureRandom.uuid)
    post "/demo/conversations", params: { adapter: "openai" }, headers: headers, as: :json
    assert_response :success
    first = response.parsed_body.fetch("id")
    saved = AgentConversation.for_session!(first, token)
    messages = [{ "id" => "u1", "role" => "user", "parts" => [{ "type" => "text", "text" => "食品の在庫を確認" }] },
      { "id" => "a1", "role" => "assistant", "parts" => [{ "type" => "tool-search_inventory", "state" => "output-available", "output" => { "sku" => "TEA-GRN" } }] }]
    saved.update!(messages: messages)
    post "/demo/conversations", params: { adapter: "ruby_llm" }, headers: headers, as: :json
    assert_empty response.parsed_body.fetch("messages")
    get "/demo/conversations", headers: headers
    assert_equal [first], response.parsed_body.map { |c| c.fetch("id") }
    assert_equal "食品の在庫を確認", response.parsed_body.last.fetch("title")
    assert_not response.parsed_body.first.key?("messages")
    get "/demo/conversations/#{first}", headers: headers
    assert_equal messages, response.parsed_body.fetch("messages")
    get "/demo/conversations/#{other.public_id}", headers: headers
    assert_response :unprocessable_entity
    get "/demo/conversations"
    assert_response :unprocessable_entity
    assert_equal messages, saved.reload.messages
  end
end
