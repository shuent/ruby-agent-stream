# Authorized paid smoke: one research turn + contextual follow-up + local approval.
# Only compact evidence is printed, never credentials or raw provider logs.
adapter = ARGV.fetch(0, "ruby_llm")
conversation = AgentConversation.start!(adapter: adapter, session_token: SecureRandom.uuid)
report = { adapter: adapter, model: AgentChat::MODEL, reasoning_effort: AgentChat::REASONING,
           conversation_id: conversation.public_id, turns: [] }
[
  "食品カテゴリの在庫、販売ペース、仕入条件を確認し、急ぐべき補充を提案してください。",
  "先ほどの食品のSKUを60点で補充発注登録してください。"
].each do |prompt|
  user_message = { "role" => "user", "parts" => [{ "type" => "text", "text" => prompt }] }
  before = ReplenishmentOrder.count
  agent = AgentChat.new(adapter: adapter, messages: [user_message], conversation: conversation.reload)
  events = agent.to_enum(:each).to_a
  report[:turns] << { run_id: agent.run.run_id, cache: agent.run.reload.cache_status, status: agent.run.status,
    tool_names: agent.run.tools, reasoning_observed: agent.run.reasoning_observed,
    event_counts: events.map(&:type).tally, orders_before: before, orders_after: ReplenishmentOrder.count,
    text: events.select { |e| e.type == :text_delta }.map { |e| e.attributes[:delta] }.join }
end
assistant = conversation.reload.messages.last.deep_dup
assistant["parts"].each do |part|
  next unless part["state"] == "approval-requested"
  part["state"] = "approval-responded"
  part["approval"]["approved"] = true
end
raise "Expected approval request" unless assistant["parts"].any? { |p| p["state"] == "approval-responded" }
agent = AgentChat.new(adapter: adapter, messages: [assistant], conversation: conversation)
stream = AgentStream::UIMessage::V1::Stream.new(continuation: agent.continuation_events)
agent.each { |event| stream << event }
report[:approval] = { run_id: agent.run.run_id, status: agent.run.reload.status,
  approvals: conversation.agent_approvals.pluck(:public_id, :status), orders_after: ReplenishmentOrder.count }
puts JSON.pretty_generate(report)
