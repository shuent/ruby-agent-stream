# A synthetic, non-billing browser fixture. This is NOT a live model result.
# It exercises only restored useChat approval -> local SQLite -> dashboard.
# The caller explicitly installs the returned demo session in an isolated browser.
name = "browser-approval-fixture"
token = SecureRandom.uuid
conversation = AgentConversation.start!(adapter: "openai", session_token: token)
conversation.update!(messages: [{ "id" => SecureRandom.uuid, "role" => "user", "parts" => [
  { "type" => "text", "text" => "非課金のUI検証用fixtureです。TEA-GRNを60点登録する承認を確認します。実LLMの応答ではありません。" }
] }])
input = { "sku" => "TEA-GRN", "quantity" => 60 }
approval = conversation.agent_approvals.create!(public_id: SecureRandom.uuid, message_id: name,
  tool_call_id: "fixture-write", tool_name: "create_replenishment_order", input: input, data_revision: InventoryCatalog.new.revision)
event = ->(type, **args) { AgentStream::UIMessage::V1::Event.new(type, **args) }
events = [event.call(:start, message_id: name), event.call(:start_step),
  event.call(:text_start, id: "fixture-label"), event.call(:text_delta, id: "fixture-label", delta: "非課金fixtureによる承認UIの検証です。実APIの生成結果ではありません。"), event.call(:text_end, id: "fixture-label"),
  event.call(:tool_input_available, tool_call_id: "fixture-write", tool_name: "create_replenishment_order", input: input),
  event.call(:tool_approval_request, approval_id: approval.public_id, tool_call_id: "fixture-write"),
  event.call(:finish_step), event.call(:finish, finish_reason: :tool_calls)]
conversation.save_events!(events)
puts JSON.generate(session_token: token, conversation_id: conversation.public_id,
                   approval_id: approval.public_id, orders_before: ReplenishmentOrder.count, fixture: true)
