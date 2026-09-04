require "test_helper"

class DemoConversationTest < ActiveSupport::TestCase
  test "complete run uses only validated events and closes the protocol" do
    ui_stream = AIStream::UIMessage::V1::Stream.new

    DemoConversation.new(ui_stream, sleeper: ->(_) {}).run(scenario: "complete")
    chunks = decoded_chunks(ui_stream)
    types = chunks.filter_map { |chunk| chunk["type"] }

    assert_includes types, "reasoning-delta"
    assert_includes types, "text-delta"
    assert_includes types, "tool-input-delta"
    assert_includes types, "tool-input-available"
    assert_includes types, "tool-approval-request"
    assert_includes types, "tool-output-available"
    assert_includes types, "source-url"
    assert_includes types, "file"
    assert_includes types, "data-progress"
    assert_includes types, "custom"
    assert ui_stream.finished?
    assert_equal "[DONE]", ui_stream.frames.last.delete_prefix("data: ").strip
  end

  test "error run emits an error and closes the protocol" do
    ui_stream = AIStream::UIMessage::V1::Stream.new

    DemoConversation.new(ui_stream, sleeper: ->(_) {}).run(scenario: "error")
    chunks = decoded_chunks(ui_stream)

    assert_equal "Synthetic provider failure", chunks.find { |chunk| chunk["type"] == "error" }["errorText"]
    assert ui_stream.finished?
  end

  test "abort run emits an abort reason and closes the protocol" do
    ui_stream = AIStream::UIMessage::V1::Stream.new

    DemoConversation.new(ui_stream, sleeper: ->(_) {}).run(scenario: "abort")
    chunks = decoded_chunks(ui_stream)

    assert_equal "Synthetic agent abort", chunks.find { |chunk| chunk["type"] == "abort" }["reason"]
    assert ui_stream.finished?
  end

  private

  def decoded_chunks(ui_stream)
    ui_stream.frames.filter_map do |frame|
      payload = frame.delete_prefix("data: ").strip
      JSON.parse(payload) unless payload == "[DONE]"
    end
  end
end
