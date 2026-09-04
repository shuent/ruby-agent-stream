require "test_helper"

class DemoConversationTest < ActiveSupport::TestCase
  test "complete run covers every successful agent event family" do
    adapter = RubyLLM::Stream::AISDK.new(
      message_id: "test-message",
      id_generator: sequential_ids
    )

    DemoConversation.new(adapter, sleeper: ->(_) {}).run(scenario: "complete")
    chunks = decoded_chunks(adapter)
    types = chunks.filter_map { |chunk| chunk["type"] }

    assert_includes types, "reset-step"
    assert_includes types, "reasoning-delta"
    assert_includes types, "text-delta"
    assert_includes types, "tool-input-delta"
    assert_includes types, "tool-input-available"
    assert_includes types, "tool-approval-request"
    assert_includes types, "tool-approval-response"
    assert_includes types, "tool-output-available"
    assert_includes types, "tool-output-error"
    assert_includes types, "tool-output-denied"
    assert_includes types, "tool-input-error"
    assert_includes types, "source-url"
    assert_includes types, "source-document"
    assert_includes types, "file"
    assert_includes types, "reasoning-file"
    assert_includes types, "data-progress"
    assert_includes types, "data-notice"
    assert_includes types, "custom"
    assert_includes types, "message-metadata"
    assert_equal "[DONE]", adapter.frames.last.delete_prefix("data: ").strip
  end

  test "error run emits an error and closes the protocol" do
    adapter = RubyLLM::Stream::AISDK.new(id_generator: sequential_ids)

    DemoConversation.new(adapter, sleeper: ->(_) {}).run(scenario: "error")
    chunks = decoded_chunks(adapter)

    assert_equal "Synthetic provider failure", chunks.find { |chunk| chunk["type"] == "error" }["errorText"]
    assert_equal "[DONE]", adapter.frames.last.delete_prefix("data: ").strip
  end

  test "abort run emits an abort reason and closes the protocol" do
    adapter = RubyLLM::Stream::AISDK.new(id_generator: sequential_ids)

    DemoConversation.new(adapter, sleeper: ->(_) {}).run(scenario: "abort")
    chunks = decoded_chunks(adapter)

    assert_equal "Synthetic agent abort", chunks.find { |chunk| chunk["type"] == "abort" }["reason"]
    assert_equal "[DONE]", adapter.frames.last.delete_prefix("data: ").strip
  end

  private

  def sequential_ids
    index = 0
    -> { "test-part-#{index += 1}" }
  end

  def decoded_chunks(adapter)
    adapter.frames.filter_map do |frame|
      payload = frame.delete_prefix("data: ").strip
      JSON.parse(payload) unless payload == "[DONE]"
    end
  end
end
