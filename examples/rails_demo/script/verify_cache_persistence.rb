# Non-billing, two-process SQLite cache check. Both modes replace the provider boundary.
mode = ARGV.fetch(0)
message = { "role" => "user", "parts" => [{ "type" => "text", "text" => "non-billing cache persistence fixture v1" }] }
event = ->(type, **data) { AgentStream::UIMessage::V1::Event.new(type, **data) }
OpenaiAgentRunner.define_singleton_method(:new) do |agent|
  raise "unexpected provider call on cache read" unless mode == "write"
  [event.call(:start, message_id: agent.message_id), event.call(:start_step),
   event.call(:text_start, id: "fixture"), event.call(:text_delta, id: "fixture", delta: "Non-billing persistence fixture"),
   event.call(:text_end, id: "fixture"), event.call(:finish_step), event.call(:finish, finish_reason: :stop)]
end
agent = AgentChat.new(adapter: "openai", messages: [message])
agent.each.to_a
expected = mode == "write" ? "miss" : "hit"
raise "unexpected cache status" unless agent.run.cache_status == expected
puts JSON.generate(mode: mode, process_id: Process.pid, cache_status: agent.run.cache_status, status: agent.run.status, provider_api_calls: 0)
agent.cache_entry.destroy! if mode == "read"
