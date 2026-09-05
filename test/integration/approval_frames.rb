# frozen_string_literal: true

# Non-network fixture for the installed AI SDK contract check.
require_relative "../../lib/ai_stream"

event = AgentStream::UIMessage::V1::Event
stream = AgentStream::UIMessage::V1::Stream
history = [
  event.new(:start, message_id: "assistant-approval"), event.new(:start_step),
  event.new(:tool_input_available, tool_call_id: "call-write", tool_name: "write", input: { quantity: 3 }),
  event.new(:tool_approval_request, approval_id: "approval-write", tool_call_id: "call-write"),
  event.new(:finish_step), event.new(:finish, finish_reason: :tool_calls)
]
initial = stream.new
history.each { |item| initial << item }
responses = [true, false].to_h do |approved|
  resumed = stream.new(continuation: history)
  resumed << event.new(:start, message_id: "assistant-approval")
  resumed << event.new(:start_step)
  resumed << event.new(:tool_approval_response, approval_id: "approval-write", approved: approved)
  resumed << if approved
               event.new(:tool_output_available, tool_call_id: "call-write", output: { saved: true })
             else
               event.new(:tool_output_denied, tool_call_id: "call-write")
             end
  resumed << event.new(:finish_step)
  resumed << event.new(:finish, finish_reason: :stop)
  [approved.to_s, resumed.to_a.join]
end
puts JSON.generate(initial: initial.to_a.join, responses: responses)
