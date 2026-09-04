# frozen_string_literal: true

require "test_helper"

# Protocol conformance benefits from complete, narrative event sequences.
# rubocop:disable-next Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
class RubyLLMStreamAISDKTest < Minitest::Test
  AISDK = RubyLLM::Stream::AISDK

  def setup
    sequence = 0
    @stream = AISDK.new(message_id: "message-1", id_generator: -> { sequence += 1 })
  end

  def test_version_and_protocol_headers
    refute_nil AISDK::VERSION
    assert_equal "text/event-stream", AISDK.headers["content-type"]
    assert_equal "no-cache", @stream.headers["cache-control"]
    assert_equal "keep-alive", @stream.headers["connection"]
    assert_equal "v1", @stream.headers["x-vercel-ai-ui-message-stream"]
    assert_equal "no", @stream.headers["x-accel-buffering"]
    refute_same AISDK::HEADERS, AISDK.headers
  end

  def test_text_chunk_lazy_starts_and_finishes_a_valid_stream
    @stream << chunk(content: "Hel")
    @stream.write(chunk(content: "lo"))
    @stream.finish(finish_reason: :stop, message_metadata: { usage: { output: 2 } })

    assert_equal [
      { "type" => "start", "messageId" => "message-1" },
      { "type" => "start-step" },
      { "type" => "text-start", "id" => "text-1" },
      { "type" => "text-delta", "id" => "text-1", "delta" => "Hel" },
      { "type" => "text-delta", "id" => "text-1", "delta" => "lo" },
      { "type" => "text-end", "id" => "text-1" },
      { "type" => "finish-step" },
      { "type" => "finish", "finishReason" => "stop", "messageMetadata" => { "usage" => { "output" => 2 } } }
    ], events(@stream)
    assert_equal "data: [DONE]\n\n", @stream.frames.last
  end

  def test_reasoning_chunk_keeps_thought_signature_as_provider_metadata
    @stream.write(chunk(thinking: RubyLLM::Thinking.new(text: "think", signature: "sig")))
    @stream.finish

    reasoning = events(@stream).select { |event| event["type"].start_with?("reasoning-") }
    assert_equal(%w[reasoning-start reasoning-delta reasoning-end], reasoning.map { |event| event["type"] })
    assert_equal({ "rubyLLM" => { "thoughtSignature" => "sig" } }, reasoning.first["providerMetadata"])
    assert_equal "think", reasoning[1]["delta"]
  end

  def test_content_text_and_url_attachment_map_without_object_inspection
    content = RubyLLM::Content.new("caption", ["https://example.com/image.png"])
    @stream.write(chunk(content: content)).finish

    all = events(@stream)
    assert_equal "caption", all.find { |event| event["type"] == "text-delta" }["delta"]
    file_event = all.find { |event| event["type"] == "file" }
    assert_equal "https://example.com/image.png", file_event["url"]
    assert_equal "image/png", file_event["mediaType"]
    refute(@stream.frames.any? { |frame| frame.include?("#<RubyLLM::Content") })
  end

  def test_raw_string_content_is_text_and_unsupported_content_is_explicitly_rejected
    @stream.write(chunk(content: RubyLLM::Content::Raw.new("raw text")))
    delta = events(@stream).find { |event| event["type"] == "text-delta" }
    assert_equal "raw text", delta["delta"]

    raw_object = RubyLLM::Content::Raw.new({ type: "provider-block" })
    error = assert_raises(AISDK::ProtocolError) { AISDK.new.write(chunk(content: raw_object)) }
    assert_match(/cannot be mapped to text/, error.message)

    error = assert_raises(AISDK::ProtocolError) { AISDK.new.write(chunk(content: 123)) }
    assert_match(/cannot be mapped to text/, error.message)
  end

  def test_non_url_content_attachment_is_rejected_before_text_is_emitted
    attachment = RubyLLM::Attachment.new(StringIO.new("not an image"), filename: "local.png")
    content = RubyLLM::Content.new("caption", [attachment])
    stream = AISDK.new

    error = assert_raises(AISDK::ProtocolError) { stream.write(chunk(content: content)) }
    assert_match(/only URL/, error.message)
    refute(events(stream).any? { |event| event["type"] == "text-delta" })
  end

  def test_streamed_and_structured_tool_inputs_are_flushed_at_step_end
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: "call-1", name: "weather", arguments: '{"city":'),
                          1 => tool_call(id: "call-2", name: "clock", arguments: { zone: "UTC" })
                        }))
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: nil, name: nil, arguments: '"Tokyo"}')
                        }))
    @stream.finish_step

    all = events(@stream)
    available = all.select { |event| event["type"] == "tool-input-available" }
    assert_equal({ "city" => "Tokyo" }, available.find { |event| event["toolCallId"] == "call-1" }["input"])
    assert_equal({ "zone" => "UTC" }, available.find { |event| event["toolCallId"] == "call-2" }["input"])
    assert_operator(all.index { |event| event["type"] == "tool-input-delta" }, :<,
                    all.index { |event| event["type"] == "tool-input-available" })
  end

  def test_tool_fragments_without_stream_key_use_latest_invocation
    @stream.write(chunk(tool_calls: { nil => tool_call(id: "call-1", name: "lookup", arguments: "") }))
    @stream.write(chunk(tool_calls: { nil => tool_call(id: nil, name: nil, arguments: '{"q":"x"}') }))
    @stream.finish

    available = events(@stream).find { |event| event["type"] == "tool-input-available" }
    assert_equal "call-1", available["toolCallId"]
    assert_equal({ "q" => "x" }, available["input"])
  end

  def test_repeated_tool_id_and_name_are_treated_as_continuation
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: "call-1", name: "lookup", arguments: '{"q":')
                        }))
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: "call-1", name: "lookup", arguments: '"Ruby"}')
                        }))
    @stream.finish

    tool_events = events(@stream).select { |event| event["toolCallId"] == "call-1" }
    start_count = tool_events.count { |event| event["type"] == "tool-input-start" }
    delta_count = tool_events.count { |event| event["type"] == "tool-input-delta" }
    assert_equal 1, start_count
    assert_equal 2, delta_count
    available = tool_events.find { |event| event["type"] == "tool-input-available" }
    assert_equal({ "q" => "Ruby" }, available["input"])
  end

  def test_repeated_tool_id_rejects_changed_name_and_ambiguous_stream_key
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: "call-1", name: "lookup", arguments: "")
                        }))
    assert_raises(AISDK::ProtocolError) do
      @stream.write(chunk(tool_calls: {
                            0 => tool_call(id: "call-1", name: "different", arguments: "{}")
                          }))
    end

    assert_raises(AISDK::ProtocolError) do
      @stream.write(chunk(tool_calls: {
                            0 => tool_call(id: "call-2", name: "lookup", arguments: "{}")
                          }))
    end
  end

  def test_invalid_tool_json_becomes_tool_input_error
    @stream.write(chunk(tool_calls: { 0 => tool_call(id: "bad", name: "broken", arguments: "{") }))
    @stream.finish

    error = events(@stream).find { |event| event["type"] == "tool-input-error" }
    assert_equal "bad", error["toolCallId"]
    assert_equal "{", error["input"]
    assert_match(/invalid JSON tool input/, error["errorText"])
  end

  def test_tool_result_message_maps_to_output
    @stream.tool_input_available(tool_call_id: "call-1", tool_name: "weather", input: { city: "Tokyo" })
    message = RubyLLM::Message.new(role: :tool, content: '{"temperature":23}', tool_call_id: "call-1")
    @stream.write_message(message)

    output = events(@stream).last
    assert_equal "tool-output-available", output["type"]
    assert_equal "call-1", output["toolCallId"]
    assert_equal '{"temperature":23}', output["output"]
  end

  def test_tool_result_message_flushes_streamed_input_before_output
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: "call-1", name: "weather", arguments: '{"city":')
                        }))
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: nil, name: nil, arguments: '"Tokyo"}')
                        }))

    message = RubyLLM::Message.new(role: :tool, content: '{"temperature":23}', tool_call_id: "call-1")
    @stream.write_message(message)

    tool_events = events(@stream).select { |event| event["toolCallId"] == "call-1" }
    event_types = tool_events.map { |event| event["type"] }
    assert_equal %w[tool-input-start tool-input-delta tool-input-delta tool-input-available
                    tool-output-available], event_types
    assert_equal({ "city" => "Tokyo" }, tool_events[-2]["input"])
    assert_equal '{"temperature":23}', tool_events.last["output"]
  end

  def test_first_parallel_tool_result_flushes_every_input_once
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: "call-1", name: "weather", arguments: '{"city":"Tokyo"}'),
                          1 => tool_call(id: "call-2", name: "clock", arguments: '{"zone":"UTC"}')
                        }))

    @stream.write_message(RubyLLM::Message.new(role: :tool, content: "23 C", tool_call_id: "call-1"))
    @stream.write_message(RubyLLM::Message.new(role: :tool, content: "06:00", tool_call_id: "call-2"))

    tool_events = events(@stream).select { |event| event["type"].start_with?("tool-") }
    available = tool_events.select { |event| event["type"] == "tool-input-available" }
    outputs = tool_events.select { |event| event["type"] == "tool-output-available" }
    available_ids = available.map { |event| event["toolCallId"] }
    output_ids = outputs.map { |event| event["toolCallId"] }
    assert_equal %w[call-1 call-2], available_ids
    assert_equal %w[call-1 call-2], output_ids
    last_input = tool_events.rindex { |event| event["type"] == "tool-input-available" }
    first_output = tool_events.index { |event| event["type"] == "tool-output-available" }
    assert_operator last_input, :<, first_output
  end

  def test_tool_result_can_follow_invalid_streamed_input
    @stream.write(chunk(tool_calls: {
                          0 => tool_call(id: "call-1", name: "provider_tool", arguments: "{")
                        }))
    message = RubyLLM::Message.new(role: :tool, content: "provider result", tool_call_id: "call-1")

    @stream.write_message(message)

    tool_events = events(@stream).select { |event| event["toolCallId"] == "call-1" }
    event_types = tool_events.map { |event| event["type"] }
    assert_equal %w[tool-input-start tool-input-delta tool-input-error tool-output-available],
                 event_types
    assert_match(/invalid JSON tool input/, tool_events[-2]["errorText"])
  end

  def test_all_non_tool_typed_events_have_current_shapes
    @stream.start(message_metadata: { trace: "one" })
    @stream.start_step
    @stream.message_metadata(stage: "running")
    @stream.text_start(id: "t", provider_metadata: { openai: { itemId: "i" } })
    @stream.text_delta(id: "t", delta: "hello")
    @stream.text_end(id: "t")
    @stream.reasoning_start(id: "r")
    @stream.reasoning_delta(id: "r", delta: "why")
    @stream.reasoning_end(id: "r")
    @stream.source_url(source_id: "s1", url: "https://example.com", title: "Example")
    @stream.source_document(source_id: "s2", media_type: "application/pdf", title: "Paper", filename: "p.pdf")
    @stream.file(url: "https://example.com/a.png", media_type: "image/png")
    @stream.reasoning_file(url: "https://example.com/reason.txt", media_type: "text/plain")
    @stream.data(name: "status", data: { phase: 1 }, id: "d", transient: false)
    @stream.custom(kind: "demo.pulse", provider_metadata: { demo: { value: true } })
    @stream.finish(finish_reason: :unknown)

    by_type = events(@stream).to_h { |event| [event["type"], event] }
    assert_equal({ "stage" => "running" }, by_type["message-metadata"]["messageMetadata"])
    assert_equal "https://example.com", by_type["source-url"]["url"]
    assert_equal "application/pdf", by_type["source-document"]["mediaType"]
    assert_equal "image/png", by_type["file"]["mediaType"]
    assert_equal "text/plain", by_type["reasoning-file"]["mediaType"]
    assert_equal false, by_type["data-status"]["transient"]
    assert_equal "demo.pulse", by_type["custom"]["kind"]
    assert_equal "other", by_type["finish"]["finishReason"]
  end

  def test_complete_tool_lifecycle_including_approval_and_preliminary_output
    @stream.tool_input_start(tool_call_id: "tool-1", tool_name: "publish", provider_executed: false,
                             tool_metadata: { risk: "write" }, dynamic: true, title: "Publish")
    @stream.tool_input_delta(tool_call_id: "tool-1", input_text_delta: '{"draft":true}')
    @stream.tool_input_available(tool_call_id: "tool-1", tool_name: "publish", input: { draft: true })
    @stream.tool_approval_request(approval_id: "approval-1", tool_call_id: "tool-1",
                                  approval_descriptor: { scope: "post" }, reason: "External write",
                                  is_automatic: false, signature: "signed")
    @stream.tool_approval_response(approval_id: "approval-1", approved: true, provider_executed: false)
    @stream.tool_output_available(tool_call_id: "tool-1", output: { progress: 50 }, preliminary: true)
    @stream.tool_output_available(tool_call_id: "tool-1", output: { published: true }, preliminary: false)

    all = events(@stream)
    assert_equal(%w[
                   start start-step tool-input-start tool-input-delta tool-input-available
                   tool-approval-request tool-approval-response tool-output-available tool-output-available
                 ], all.map { |event| event["type"] })
    assert_equal false, all[2]["providerExecuted"]
    assert_equal true, all[2]["dynamic"]
    assert_equal false, all[5]["isAutomatic"]
    assert_equal true, all[-2]["preliminary"]
    assert_equal false, all[-1]["preliminary"]
  end

  def test_tool_error_and_denied_variants
    @stream.tool_input_error(tool_call_id: "input-error", tool_name: "parse", input: "bad",
                             error_text: "invalid", dynamic: false)
    @stream.tool_input_available(tool_call_id: "output-error", tool_name: "fail", input: {})
    @stream.tool_output_error(tool_call_id: "output-error", error_text: "boom")
    @stream.tool_input_available(tool_call_id: "denied", tool_name: "delete", input: {})
    @stream.tool_output_denied(tool_call_id: "denied")

    by_id = events(@stream).filter { |event| event["toolCallId"] }.to_h { |event| [event["toolCallId"], event] }
    assert_equal "tool-input-error", by_id["input-error"]["type"]
    assert_equal false, by_id["input-error"]["dynamic"]
    assert_equal "tool-output-error", by_id["output-error"]["type"]
    assert_equal "tool-output-denied", by_id["denied"]["type"]
  end

  def test_tool_output_waits_for_approval_response
    @stream.tool_input_available(tool_call_id: "tool-1", tool_name: "delete", input: {})
    @stream.tool_approval_request(approval_id: "approval-1", tool_call_id: "tool-1")
    assert_raises(AISDK::ProtocolError) do
      @stream.tool_output_available(tool_call_id: "tool-1", output: "too early")
    end

    @stream.tool_approval_response(approval_id: "approval-1", approved: false)
    assert_raises(AISDK::ProtocolError) do
      @stream.tool_output_available(tool_call_id: "tool-1", output: "forbidden")
    end
    @stream.tool_output_denied(tool_call_id: "tool-1")
  end

  def test_reset_step_discards_open_server_state
    @stream.text_start(id: "discard")
    @stream.tool_input_start(tool_call_id: "discard-tool", tool_name: "x")
    @stream.reset_step
    @stream.text_start(id: "new")
    @stream.text_delta(id: "new", delta: "kept")
    @stream.finish

    types = events(@stream).map { |event| event["type"] }
    assert_includes types, "reset-step"
    refute(events(@stream).any? do |event|
      event["type"] == "tool-input-available" && event["toolCallId"] == "discard-tool"
    end)
  end

  def test_invalid_sequences_raise_clear_protocol_errors
    assert_raises(AISDK::ProtocolError) { @stream.text_delta(id: "missing", delta: "x") }

    fresh = AISDK.new
    assert_raises(AISDK::ProtocolError) { fresh.tool_output_available(tool_call_id: "missing", output: {}) }
    assert_raises(AISDK::ProtocolError) { fresh.tool_approval_response(approval_id: "missing", approved: true) }
    assert_raises(AISDK::ProtocolError) { AISDK.new.finish_step }
  end

  def test_non_json_values_and_invalid_metadata_are_rejected
    assert_raises(AISDK::JSONCompatibilityError) { @stream.data(name: "bad", data: Object.new) }
    assert_raises(AISDK::JSONCompatibilityError) { @stream.message_metadata(Float::NAN) }
    assert_raises(AISDK::JSONCompatibilityError) do
      @stream.text_start(id: "x", provider_metadata: %w[not an object])
    end
    assert_raises(AISDK::JSONCompatibilityError) do
      @stream.text_start(id: "x", provider_metadata: { provider: "not an object" })
    end
  end

  def test_finish_and_terminal_events_reject_subsequent_writes
    @stream.finish
    assert @stream.finished?
    assert_raises(AISDK::FinishedError) { @stream.finish }
    assert_raises(AISDK::FinishedError) { @stream.write(chunk(content: "late")) }

    aborted = AISDK.new
    aborted.abort(reason: "client disconnected")
    assert_equal "abort", events(aborted)[-1]["type"]
    assert_raises(AISDK::FinishedError) { aborted.start }

    failed = AISDK.new
    failed.error(error_text: "provider unavailable")
    assert_equal "error", events(failed)[-1]["type"]
  end

  def test_io_sink_and_rack_enumeration
    io = StringIO.new
    stream = AISDK.new(io)
    stream.write(chunk(content: "hello")).finish
    assert_empty stream.frames
    assert_includes io.string, 'data: {"type":"text-delta"'
    assert io.string.end_with?("data: [DONE]\n\n")

    @stream.write(chunk(content: "hello")).finish
    assert_equal @stream.frames, @stream.each.to_a
    assert_equal @stream.frames, @stream.to_a
    yielded = []
    each_result = @stream.each { |frame| yielded << frame }
    assert_same @stream, each_result
    assert_equal @stream.frames, yielded

    writes = []
    sink = Object.new
    sink.define_singleton_method(:write) { |frame| writes << frame }
    AISDK.new(sink).write(chunk(content: "structural sink")).finish
    assert(writes.any? { |frame| frame.include?("structural sink") })
  end

  private

  def events(stream)
    stream.frames.filter_map do |frame|
      payload = frame.delete_prefix("data: ").delete_suffix("\n\n")
      JSON.parse(payload) unless payload == "[DONE]"
    end
  end

  def chunk(content: "", thinking: nil, tool_calls: nil)
    RubyLLM::Chunk.new(role: :assistant, content: content, thinking: thinking, tool_calls: tool_calls)
  end

  def tool_call(id:, name:, arguments:)
    RubyLLM::ToolCall.new(id: id, name: name, arguments: arguments)
  end
end
