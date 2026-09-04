# frozen_string_literal: true

require "test_helper"

# The schema coverage is intentionally exhaustive and narrative.
# rubocop:disable-next Metrics/MethodLength, Metrics/AbcSize
class AIStreamUIMessageV1EventTest < Minitest::Test
  Event = AgentStream::UIMessage::V1::Event

  def test_serializes_protocol_names_and_normalizes_json
    event = Event.new(
      :text_delta,
      id: "text-1",
      delta: "hello",
      provider_metadata: { openai: { item_id: "item-1" } }
    )

    assert_equal({
                   "type" => "text-delta",
                   "id" => "text-1",
                   "delta" => "hello",
                   "providerMetadata" => { "openai" => { "item_id" => "item-1" } }
                 }, event.to_h)
  end

  def test_data_event_uses_dynamic_wire_type
    event = Event.new(:data, name: "weather", data: { temperature: 23 }, transient: false)

    assert_equal({
                   "type" => "data-weather",
                   "data" => { "temperature" => 23 },
                   "transient" => false
                 }, event.to_h)
  end

  def test_rejects_unknown_types_missing_fields_and_unknown_fields
    assert_raises(Event::UnknownTypeError) { Event.new(:provider_chunk) }
    assert_raises(Event::SchemaError) { Event.new(:text_delta, id: "text-1") }
    assert_raises(Event::SchemaError) do
      Event.new(:text_delta, id: "text-1", delta: "hello", provider_event: Object.new)
    end
  end

  def test_rejects_values_with_the_wrong_ruby_type
    assert_raises(Event::SchemaError) { Event.new(:text_delta, id: 1, delta: "hello") }
    assert_raises(Event::SchemaError) do
      Event.new(:tool_approval_response, approval_id: "approval-1", approved: nil)
    end
    assert_raises(Event::SchemaError) { Event.new(:finish, finish_reason: :unexpected) }
  end

  def test_rejects_non_json_values_and_invalid_provider_metadata
    assert_raises(Event::JSONCompatibilityError) { Event.new(:data, name: "bad", data: Object.new) }
    assert_raises(Event::JSONCompatibilityError) do
      Event.new(:start, message_metadata: Float::NAN)
    end
    assert_raises(Event::JSONCompatibilityError) do
      Event.new(:text_start, id: "text-1", provider_metadata: { openai: "not an object" })
    end
  end

  def test_rejects_empty_identifiers_and_invalid_custom_kinds
    assert_raises(Event::SchemaError) { Event.new(:text_start, id: "") }
    assert_raises(Event::SchemaError) { Event.new(:data, name: "", data: nil) }
    assert_raises(Event::SchemaError) { Event.new(:custom, kind: "missing-namespace") }
  end

  def test_normalizes_finish_reason_and_is_deeply_immutable
    source = { usage: { output: [1, 2] } }
    event = Event.new(:finish, finish_reason: :tool_calls, message_metadata: source)
    source[:usage][:output] << 3

    assert_equal "tool-calls", event.attributes[:finish_reason]
    assert_equal [1, 2], event.attributes[:message_metadata]["usage"]["output"]
    assert event.frozen?
    assert event.attributes.frozen?
    assert event.attributes[:message_metadata]["usage"].frozen?
  end

  def test_all_protocol_event_schemas_accept_their_minimum_shape
    events = [
      Event.new(:start),
      Event.new(:start_step),
      Event.new(:reset_step),
      Event.new(:finish_step),
      Event.new(:finish),
      Event.new(:abort),
      Event.new(:error, error_text: "boom"),
      Event.new(:message_metadata, message_metadata: {}),
      Event.new(:text_start, id: "text"),
      Event.new(:text_delta, id: "text", delta: "x"),
      Event.new(:text_end, id: "text"),
      Event.new(:reasoning_start, id: "reasoning"),
      Event.new(:reasoning_delta, id: "reasoning", delta: "x"),
      Event.new(:reasoning_end, id: "reasoning"),
      Event.new(:source_url, source_id: "url", url: "https://example.com"),
      Event.new(:source_document, source_id: "document", media_type: "text/plain", title: "Doc"),
      Event.new(:file, url: "https://example.com/a.txt", media_type: "text/plain"),
      Event.new(:reasoning_file, url: "https://example.com/r.txt", media_type: "text/plain"),
      Event.new(:data, name: "status", data: {}),
      Event.new(:custom, kind: "demo.pulse"),
      Event.new(:tool_input_start, tool_call_id: "tool", tool_name: "lookup"),
      Event.new(:tool_input_delta, tool_call_id: "tool", input_text_delta: "{}"),
      Event.new(:tool_input_available, tool_call_id: "tool", tool_name: "lookup", input: {}),
      Event.new(:tool_input_error, tool_call_id: "tool", tool_name: "lookup", input: "{", error_text: "bad"),
      Event.new(:tool_approval_request, approval_id: "approval", tool_call_id: "tool"),
      Event.new(:tool_approval_response, approval_id: "approval", approved: true),
      Event.new(:tool_output_available, tool_call_id: "tool", output: {}),
      Event.new(:tool_output_error, tool_call_id: "tool", error_text: "bad"),
      Event.new(:tool_output_denied, tool_call_id: "tool")
    ]

    assert_equal Event::SCHEMAS.size, events.size
  end
end
