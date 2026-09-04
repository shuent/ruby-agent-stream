require "ruby_llm/ai_sdk"

# A deterministic stand-in for a real agent run. It deliberately emits the
# shapes that RubyLLM providers and agent/tool loops can produce, without using
# an API key or making a model request.
class DemoConversation
  PROVIDER_METADATA = {
    "ruby_llm" => { "provider" => "fixture", "model" => "no-api" }
  }.freeze

  def initialize(stream, sleeper: Kernel.method(:sleep))
    @stream = stream
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

  attr_reader :stream, :sleeper

  def complete_run
    stream.start(message_metadata: { traceId: "rails-fixed-001", phase: "started" })
    emit_reset_step
    emit_ruby_llm_chunks
    stream.finish_step

    emit_tool_results
    emit_structured_parts
    emit_tool_failures
    stream.message_metadata({ traceId: "rails-fixed-001", phase: "complete" })
    stream.finish(finish_reason: :stop, message_metadata: { elapsedMs: 42 })
  end

  def emit_reset_step
    stream.text_start(id: "discarded-text")
    stream.text_delta(id: "discarded-text", delta: "This retry is intentionally removed.")
    stream.text_end(id: "discarded-text")
    stream.reset_step
  end

  def emit_ruby_llm_chunks
    stream << assistant_chunk(thinking: "Check the request and available tools. ")
    pause
    stream << assistant_chunk(thinking: "A weather lookup is appropriate.")
    stream << assistant_chunk(content: "I will inspect Tokyo's weather. ")
    pause
    stream << assistant_chunk(content: "The RubyLLM chunks are now streaming.")

    stream << assistant_chunk(tool_calls: {
      "provider-index-0" => RubyLLM::ToolCall.new(
        id: "call-weather",
        name: "lookup_weather",
        arguments: '{"city":"'
      )
    })
    pause
    stream << assistant_chunk(tool_calls: {
      "provider-index-0" => RubyLLM::ToolCall.new(
        id: nil,
        name: nil,
        arguments: 'Tokyo","units":"celsius"}'
      )
    })
  end

  def emit_tool_results
    stream.tool_approval_request(
      approval_id: "approval-weather",
      tool_call_id: "call-weather",
      approval_descriptor: { risk: "network" },
      reason: "This fixture demonstrates approval state.",
      is_automatic: true,
      signature: "fixture-signature"
    )
    stream.tool_approval_response(
      approval_id: "approval-weather",
      approved: true,
      reason: "Allowed by the deterministic demo."
    )
    stream.tool_output_available(
      tool_call_id: "call-weather",
      output: { city: "Tokyo", celsius: 27 },
      preliminary: true
    )
    stream.tool_output_available(
      tool_call_id: "call-weather",
      output: { city: "Tokyo", celsius: 27, condition: "sunny" }
    )
  end

  def emit_structured_parts
    stream.reasoning_file(
      url: "data:text/plain;base64,cmVhc29uaW5nIHRyYWNl",
      media_type: "text/plain",
      provider_metadata: PROVIDER_METADATA
    )
    stream.source_url(
      source_id: "source-ruby-llm",
      url: "https://rubyllm.com/",
      title: "RubyLLM"
    )
    stream.source_document(
      source_id: "source-spec",
      media_type: "application/pdf",
      title: "Fixture protocol note",
      filename: "protocol-note.pdf"
    )
    stream.file(
      url: "data:text/plain;base64,UnVieUxMTSBBSVNESw==",
      media_type: "text/plain",
      provider_metadata: PROVIDER_METADATA
    )
    stream.data(name: "progress", id: "job-1", data: { value: 50, label: "halfway" })
    stream.data(name: "progress", id: "job-1", data: { value: 100, label: "done" })
    stream.data(name: "notice", data: { message: "transient callback only" }, transient: true)
    stream.custom(kind: "demo.trace", provider_metadata: PROVIDER_METADATA)
  end

  def emit_tool_failures
    stream.tool_input_available(
      tool_call_id: "call-delete",
      tool_name: "delete_file",
      input: { path: "/tmp/example" },
      dynamic: true,
      title: "Delete fixture file"
    )
    stream.tool_approval_request(
      approval_id: "approval-delete",
      tool_call_id: "call-delete",
      reason: "Destructive operation"
    )
    stream.tool_approval_response(
      approval_id: "approval-delete",
      approved: false,
      reason: "The demo always denies this operation."
    )
    stream.tool_output_denied(tool_call_id: "call-delete")

    stream.tool_input_available(
      tool_call_id: "call-failure",
      tool_name: "unstable_service",
      input: { retry: false },
      dynamic: true
    )
    stream.tool_output_error(
      tool_call_id: "call-failure",
      error_text: "Synthetic tool failure",
      dynamic: true
    )

    stream.tool_input_error(
      tool_call_id: "call-invalid",
      tool_name: "strict_tool",
      input: { count: "not-an-integer" },
      error_text: "count must be an integer",
      dynamic: true
    )
  end

  def error_run
    stream.start(message_metadata: { traceId: "rails-error-001" })
    stream << assistant_chunk(content: "A partial answer survives. ")
    pause
    stream.error(error_text: "Synthetic provider failure")
  end

  def abort_run
    stream.start(message_metadata: { traceId: "rails-abort-001" })
    stream << assistant_chunk(content: "The server stopped this agent run. ")
    pause
    stream.abort(reason: "Synthetic agent abort")
  end

  def slow_run
    stream.start(message_metadata: { traceId: "rails-slow-001" })
    100.times do |index|
      stream << assistant_chunk(content: "token-#{index} ")
      sleeper.call(0.15)
    end
    stream.finish(finish_reason: :stop)
  end

  def assistant_chunk(content: "", thinking: nil, tool_calls: nil)
    RubyLLM::Chunk.new(
      role: :assistant,
      content: content,
      thinking: thinking && RubyLLM::Thinking.new(text: thinking),
      tool_calls: tool_calls
    )
  end

  def pause
    sleeper.call(0.015)
  end
end
