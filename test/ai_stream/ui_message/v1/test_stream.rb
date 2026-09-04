# frozen_string_literal: true

require "test_helper"

# Protocol conformance benefits from complete event sequences.
# rubocop:disable-next Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
class AIStreamUIMessageV1StreamTest < Minitest::Test
  Event = AIStream::UIMessage::V1::Event
  Stream = AIStream::UIMessage::V1::Stream

  def setup
    @stream = Stream.new
  end

  def test_headers
    assert_equal "text/event-stream", Stream.headers["content-type"]
    assert_equal "v1", @stream.headers["x-vercel-ai-ui-message-stream"]
    refute_same Stream::HEADERS, Stream.headers
  end

  def test_text_sequence_is_encoded_as_sse_and_terminated
    push(:start, message_id: "message-1")
    push(:start_step)
    push(:text_start, id: "text-1")
    push(:text_delta, id: "text-1", delta: "hello")
    push(:text_end, id: "text-1")
    push(:finish_step)
    push(:finish, finish_reason: :stop)

    types = events.map { |event| event.fetch("type") }
    assert_equal %w[start start-step text-start text-delta text-end finish-step finish], types
    assert_equal "data: [DONE]\n\n", @stream.frames.last
    assert @stream.started?
    assert @stream.finished?
  end

  def test_input_mutation_api_is_only_left_shift
    refute_respond_to @stream, :write
    assert_raises(ArgumentError) { @stream << Object.new }
  end

  def test_rejects_invalid_message_and_part_sequences_without_emitting
    assert_raises(Stream::ProtocolError) { push(:start_step) }
    assert_empty @stream.frames

    push(:start)
    push(:start_step)
    assert_raises(Stream::ProtocolError) { push(:text_delta, id: "missing", delta: "x") }
    push(:text_start, id: "text-1")
    assert_raises(Stream::ProtocolError) { push(:reasoning_delta, id: "text-1", delta: "x") }
    assert_raises(Stream::ProtocolError) { push(:finish_step) }
  end

  def test_reset_step_discards_open_state
    push(:start)
    push(:start_step)
    push(:text_start, id: "discard")
    push(:tool_input_start, tool_call_id: "discard-tool", tool_name: "lookup")
    push(:reset_step)
    push(:text_start, id: "kept")
    push(:text_end, id: "kept")
    push(:finish_step)
    push(:finish)

    assert @stream.finished?
  end

  def test_complete_tool_lifecycle
    push(:start)
    push(:start_step)
    push(:tool_input_start, tool_call_id: "tool-1", tool_name: "publish")
    push(:tool_input_delta, tool_call_id: "tool-1", input_text_delta: "{}")
    push(:tool_input_available, tool_call_id: "tool-1", tool_name: "publish", input: {})
    push(:tool_approval_request, approval_id: "approval-1", tool_call_id: "tool-1")
    push(:tool_approval_response, approval_id: "approval-1", approved: true)
    push(:tool_output_available, tool_call_id: "tool-1", output: { progress: 50 }, preliminary: true)
    push(:tool_output_available, tool_call_id: "tool-1", output: { published: true })
    push(:finish_step)
    push(:finish)

    tool_types = events.filter_map { |event| event["type"] if event["type"].start_with?("tool-") }
    assert_equal %w[
      tool-input-start tool-input-delta tool-input-available tool-approval-request
      tool-approval-response tool-output-available tool-output-available
    ], tool_types
  end

  def test_rejects_incomplete_and_invalid_tool_sequences
    push(:start)
    push(:start_step)
    push(:tool_input_start, tool_call_id: "tool-1", tool_name: "lookup")
    assert_raises(Stream::ProtocolError) { push(:finish_step) }
    assert_raises(Stream::ProtocolError) do
      push(:tool_input_available, tool_call_id: "tool-1", tool_name: "different", input: {})
    end
    push(:tool_input_available, tool_call_id: "tool-1", tool_name: "lookup", input: {})
    assert_raises(Stream::ProtocolError) do
      push(:tool_approval_response, approval_id: "missing", approved: true)
    end
  end

  def test_terminal_event_rejects_subsequent_input
    push(:start)
    push(:finish)

    assert_raises(Stream::FinishedError) { push(:start) }
  end

  def test_sink_mode_writes_frames_and_buffer_mode_is_enumerable
    output = StringIO.new
    stream = Stream.new(output)
    stream << Event.new(:start)
    stream << Event.new(:finish)

    assert_empty stream.frames
    assert output.string.end_with?("data: [DONE]\n\n")

    push(:start)
    push(:finish)
    assert_equal @stream.frames, @stream.each.to_a
    assert_equal @stream.frames, @stream.to_a
  end

  private

  def push(type, **attributes)
    @stream << Event.new(type, **attributes)
  end

  def events
    @stream.frames.filter_map do |frame|
      payload = frame.delete_prefix("data: ").delete_suffix("\n\n")
      JSON.parse(payload) unless payload == "[DONE]"
    end
  end
end
