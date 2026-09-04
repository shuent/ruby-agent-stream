require "ai_stream"

# Deterministic UI protocol producer used to exercise the transport without an
# API key. Real applications replace this class with one of AIStream::Adapters.
class DemoConversation
  Event = AIStream::UIMessage::V1::Event
  PROVIDER_METADATA = { demo: { provider: "fixture", model: "no-api" } }.freeze

  def initialize(ui_stream, sleeper: Kernel.method(:sleep))
    @ui_stream = ui_stream
    @sleeper = sleeper
  end

  def run(scenario:)
    case scenario.to_s
    when "abort" then abort_run
    when "error" then error_run
    when "slow" then slow_run
    else complete_run
    end
  end

  private

  attr_reader :ui_stream, :sleeper

  def complete_run
    emit(:start, message_id: "rails-demo-assistant", message_metadata: { traceId: "rails-fixed-001" })
    emit(:start_step)
    emit_reasoning
    emit_text
    emit_tool
    emit_structured_parts
    emit(:finish_step)
    emit(:finish, finish_reason: :tool_calls, message_metadata: { elapsedMs: 42 })
  end

  def emit_reasoning
    emit(:reasoning_start, id: "reasoning-1")
    emit(:reasoning_delta, id: "reasoning-1", delta: "Check the request and available tools. ")
    pause
    emit(:reasoning_delta, id: "reasoning-1", delta: "A weather lookup is appropriate.")
    emit(:reasoning_end, id: "reasoning-1", provider_metadata: PROVIDER_METADATA)
  end

  def emit_text
    emit(:text_start, id: "text-1")
    emit(:text_delta, id: "text-1", delta: "I will inspect Tokyo's weather. ")
    pause
    emit(:text_delta, id: "text-1", delta: "Protocol events are now streaming.")
    emit(:text_end, id: "text-1")
  end

  def emit_tool
    emit(:tool_input_start, tool_call_id: "call-weather", tool_name: "lookup_weather")
    emit(:tool_input_delta, tool_call_id: "call-weather", input_text_delta: '{"city":"')
    emit(:tool_input_delta, tool_call_id: "call-weather", input_text_delta: 'Tokyo"}')
    emit(:tool_input_available, tool_call_id: "call-weather", tool_name: "lookup_weather",
                                input: { city: "Tokyo" })
    emit(:tool_approval_request, approval_id: "approval-weather", tool_call_id: "call-weather",
                                 reason: "The fixture demonstrates approval state.")
    emit(:tool_approval_response, approval_id: "approval-weather", approved: true)
    emit(:tool_output_available, tool_call_id: "call-weather", output: { celsius: 27 }, preliminary: true)
    emit(:tool_output_available, tool_call_id: "call-weather", output: { celsius: 27, condition: "sunny" })
  end

  def emit_structured_parts
    emit(:source_url, source_id: "source-1", url: "https://example.com/weather", title: "Weather fixture")
    emit(:file, url: "data:text/plain;base64,QUkgU3RyZWFt", media_type: "text/plain")
    emit(:data, name: "progress", id: "job-1", data: { value: 100 })
    emit(:message_metadata, message_metadata: { traceId: "rails-fixed-001", phase: "complete" })
    emit(:custom, kind: "demo.trace", provider_metadata: PROVIDER_METADATA)
  end

  def error_run
    start_text_run(message_id: "rails-error", text: "A partial answer survives. ")
    emit(:error, error_text: "Synthetic provider failure")
  end

  def abort_run
    start_text_run(message_id: "rails-abort", text: "The server stopped this run. ")
    emit(:abort, reason: "Synthetic agent abort")
  end

  def slow_run
    emit(:start, message_id: "rails-slow")
    emit(:start_step)
    emit(:text_start, id: "text-slow")
    100.times do |index|
      emit(:text_delta, id: "text-slow", delta: "token-#{index} ")
      sleeper.call(0.15)
    end
    emit(:text_end, id: "text-slow")
    emit(:finish_step)
    emit(:finish, finish_reason: :stop)
  end

  def start_text_run(message_id:, text:)
    emit(:start, message_id: message_id)
    emit(:start_step)
    emit(:text_start, id: "#{message_id}-text")
    emit(:text_delta, id: "#{message_id}-text", delta: text)
    pause
    emit(:text_end, id: "#{message_id}-text")
    emit(:finish_step)
  end

  def emit(type, **attributes)
    ui_stream << Event.new(type, **attributes)
  end

  def pause
    sleeper.call(0.015)
  end
end
