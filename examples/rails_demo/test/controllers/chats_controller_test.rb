require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  test "preflight permits a local React client" do
    process :options, "/chat", headers: { "Origin" => "http://127.0.0.1:5173" }

    assert_response :no_content
    assert_equal "http://127.0.0.1:5173", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Access-Control-Allow-Methods"], "POST"
  end

  test "preflight does not reflect an unrelated origin" do
    process :options, "/chat", headers: { "Origin" => "https://attacker.example" }

    assert_response :no_content
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "unexpected failures terminate an open AI SDK stream" do
    adapter = RubyLLM::Stream::AISDK.new(message_id: "assistant-failure")
    adapter.start

    ChatsController.new.send(:terminate_failed_stream, adapter)

    assert adapter.finished?
    assert_equal "error", decoded_frames(adapter).last["type"]
    assert_equal "Agent stream failed", decoded_frames(adapter).last["errorText"]
    assert_equal "data: [DONE]\n\n", adapter.to_a.last
  end

  private

  def decoded_frames(adapter)
    adapter.to_a.filter_map do |frame|
      next if frame == "data: [DONE]\n\n"

      JSON.parse(frame.delete_prefix("data: "))
    end
  end
end
